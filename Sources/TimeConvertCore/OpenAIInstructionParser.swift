import Foundation

public enum OpenAIParserError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case httpStatus(Int, String)
    case missingStructuredOutput
    case incompleteParse(ConversionInstruction)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is not configured. Run `tzconvert --set-openai-key` to store it in macOS Keychain, or export OPENAI_API_KEY for this shell."
        case .invalidURL:
            return "Could not build the OpenAI request URL."
        case .httpStatus(let status, let body):
            return "OpenAI returned HTTP \(status): \(body)"
        case .missingStructuredOutput:
            return "OpenAI did not return the expected structured timezone conversion fields."
        case .incompleteParse:
            return "OpenAI could not infer the full timezone conversion. Try including the time, source timezone, and destination timezone."
        }
    }
}

public final class OpenAIInstructionParser {
    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let session: URLSession
    private let localTimeZone: TimeZone
    private let now: Date
    private let debugHandler: ((OpenAIDebugEvent) -> Void)?

    public convenience init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        localTimeZone: TimeZone = .current,
        now: Date = Date(),
        debugHandler: ((OpenAIDebugEvent) -> Void)? = nil
    ) throws {
        let environmentAPIKey = environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedAPIKey = try KeychainSecretStore().loadOpenAIAPIKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = [environmentAPIKey, storedAPIKey].compactMap({ $0 }).first(where: { !$0.isEmpty }),
              !apiKey.isEmpty else {
            throw OpenAIParserError.missingAPIKey
        }

        self.init(
            apiKey: apiKey,
            model: environment["OPENAI_MODEL"] ?? "gpt-5.4-nano",
            localTimeZone: localTimeZone,
            now: now,
            debugHandler: debugHandler
        )
    }

    public init(
        apiKey: String,
        model: String = "gpt-5.4-nano",
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        session: URLSession = .shared,
        localTimeZone: TimeZone = .current,
        now: Date = Date(),
        debugHandler: ((OpenAIDebugEvent) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
        self.localTimeZone = localTimeZone
        self.now = now
        self.debugHandler = debugHandler
    }

    public func parse(_ input: String) async throws -> ConversionInstruction {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw InstructionParseError.emptyInstruction
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestBody = try JSONEncoder().encode(makeRequestBody(for: source))
        request.httpBody = requestBody
        emitDebug(label: "OpenAI parse request", requestBody: requestBody)

        let (data, response) = try await data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIParserError.missingStructuredOutput
        }
        emitDebug(
            label: "OpenAI parse response",
            responseStatus: httpResponse.statusCode,
            responseBody: data
        )
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIParserError.httpStatus(httpResponse.statusCode, body)
        }

        let responseBody = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let outputText = responseBody.outputText,
              let outputData = outputText.data(using: .utf8) else {
            throw OpenAIParserError.missingStructuredOutput
        }

        let parsed = try JSONDecoder().decode(ParsedInstruction.self, from: outputData)
        let rawInstruction = ConversionInstruction(
            sourceText: source,
            fromTimeZone: parsed.fromTimeZone,
            toTimeZone: parsed.toTimeZone,
            dateTime: parsed.dateTime
        )
        let directionCorrectedInstruction = correctDirectionIfNeeded(rawInstruction)
        let instruction = correctRelativeFieldsIfNeeded(directionCorrectedInstruction)
        if instruction != rawInstruction {
            emitDebug(
                label: "OpenAI parse corrected locally",
                responseBody: Data(correctedInstructionDebugJSON(raw: rawInstruction, corrected: instruction).utf8)
            )
        }

        guard !instruction.fromTimeZone.isEmpty,
              !instruction.toTimeZone.isEmpty,
              !instruction.dateTime.isEmpty else {
            throw OpenAIParserError.incompleteParse(instruction)
        }

        return instruction
    }

    private func emitDebug(
        label: String,
        requestBody: Data? = nil,
        responseStatus: Int? = nil,
        responseBody: Data? = nil
    ) {
        guard let debugHandler else {
            return
        }

        debugHandler(OpenAIDebugEvent(
            label: label,
            requestBody: requestBody.flatMap { String(data: $0, encoding: .utf8) },
            responseStatus: responseStatus,
            responseBody: responseBody.flatMap { String(data: $0, encoding: .utf8) }
        ))
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { [session] in
                try await session.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw URLError(.timedOut)
            }

            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return result
        }
    }

    private func makeRequestBody(for source: String) -> OpenAIRequest {
        let localNow = makeDateFormatter("yyyy-MM-dd HH:mm:ss").string(from: now)
        let dateFacts = makeRelativeDateFacts(for: source)

        return OpenAIRequest(
            model: model,
            input: [
                OpenAIInput(
                    role: "system",
                    content: """
                    Extract TimeAPI conversion inputs.
                    Context: local=\(localTimeZone.identifier); now=\(localNow); dates=\(dateFacts).
                    Return schema JSON only.
                    Rules: IANA zones. dateTime is the source wall time as yyyy-MM-dd HH:mm:ss. local/here/my timezone=\(localTimeZone.identifier). Use listed dates exactly. "time/date in PLACE in my timezone" means PLACE -> local. "for someone in PLACE in my timezone" means PLACE -> local. "from local" means local -> named place. One non-local place plus local phrase means non-local -> local.
                    """
                ),
                OpenAIInput(role: "user", content: "Request: \"\"\"\n\(source)\n\"\"\"")
            ],
            text: OpenAIText(format: .timezoneConversionSchema),
            temperature: 0,
            maxOutputTokens: 80
        )
    }

    private func makeDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = localTimeZone
        formatter.dateFormat = format
        return formatter
    }

    private func makeRelativeDateFacts(for source: String) -> String {
        let lowercased = source.lowercased()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = localTimeZone

        var facts: [String] = []
        if lowercased.contains("today") {
            facts.append("today=\(makeDateFormatter("yyyy-MM-dd").string(from: now))")
        }
        if lowercased.contains("tomorrow"),
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            facts.append("tomorrow=\(makeDateFormatter("yyyy-MM-dd").string(from: tomorrow))")
        }

        let formatter = makeDateFormatter("yyyy-MM-dd")
        let weekdays: [(name: String, value: Int)] = [
            ("sunday", 1),
            ("monday", 2),
            ("tuesday", 3),
            ("wednesday", 4),
            ("thursday", 5),
            ("friday", 6),
            ("saturday", 7)
        ]

        let currentWeekday = calendar.component(.weekday, from: now)
        for weekday in weekdays {
            for qualifier in ["this", "next"] where lowercased.contains("\(qualifier) \(weekday.name)") {
                var daysUntilTarget = (weekday.value - currentWeekday + 7) % 7
                if qualifier == "next", daysUntilTarget < 7 {
                    daysUntilTarget += 7
                }
                if let date = calendar.date(byAdding: .day, value: daysUntilTarget, to: now) {
                    facts.append("\(qualifier) \(weekday.name)=\(formatter.string(from: date))")
                }
            }
        }

        return facts.isEmpty ? "none" : facts.joined(separator: ", ")
    }

    private func correctedInstructionDebugJSON(raw: ConversionInstruction, corrected: ConversionInstruction) -> String {
        """
        {
          "rawOpenAI": {
            "fromTimeZone": "\(raw.fromTimeZone)",
            "toTimeZone": "\(raw.toTimeZone)",
            "dateTime": "\(raw.dateTime)"
          },
          "corrected": {
            "fromTimeZone": "\(corrected.fromTimeZone)",
            "toTimeZone": "\(corrected.toTimeZone)",
            "dateTime": "\(corrected.dateTime)"
          }
        }
        """
    }

    private func correctDirectionIfNeeded(_ instruction: ConversionInstruction) -> ConversionInstruction {
        let lowercased = instruction.sourceText.lowercased()
        guard mentionsLocalTarget(in: lowercased),
              !lowercased.contains("from local"),
              !lowercased.contains("from my timezone"),
              !lowercased.contains("from my time zone") else {
            return instruction
        }

        let mentionedZones = Set(knownPlaceTimeZones.compactMap { place, timeZone in
            lowercased.contains(place) ? timeZone : nil
        }).filter { $0 != localTimeZone.identifier }

        guard mentionedZones.count == 1,
              let nonLocalTimeZone = mentionedZones.first else {
            return instruction
        }

        guard instruction.fromTimeZone != nonLocalTimeZone ||
              instruction.toTimeZone != localTimeZone.identifier else {
            return instruction
        }

        return ConversionInstruction(
            sourceText: instruction.sourceText,
            fromTimeZone: nonLocalTimeZone,
            toTimeZone: localTimeZone.identifier,
            dateTime: instruction.dateTime,
            dstAmbiguity: instruction.dstAmbiguity
        )
    }

    private var knownPlaceTimeZones: [String: String] {
        [
            "new york": "America/New_York",
            "nyc": "America/New_York",
            "los angeles": "America/Los_Angeles",
            "san francisco": "America/Los_Angeles",
            "london": "Europe/London",
            "istanbul": "Europe/Istanbul",
            "paris": "Europe/Paris",
            "berlin": "Europe/Berlin",
            "tokyo": "Asia/Tokyo",
            "singapore": "Asia/Singapore",
            "sydney": "Australia/Sydney",
            "melbourne": "Australia/Melbourne",
            "auckland": "Pacific/Auckland",
            "wellington": "Pacific/Auckland"
        ]
    }

    private func mentionsLocalTarget(in lowercased: String) -> Bool {
        lowercased.contains("in my timezone")
            || lowercased.contains("in my time zone")
            || lowercased.contains("to my timezone")
            || lowercased.contains("to my time zone")
            || lowercased.contains("to local")
    }

    private func correctRelativeFieldsIfNeeded(_ instruction: ConversionInstruction) -> ConversionInstruction {
        guard let sourceTimeZone = TimeZone(identifier: instruction.fromTimeZone),
              let parsedDate = parseDateTime(instruction.dateTime, timeZone: sourceTimeZone) else {
            return instruction
        }

        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = sourceTimeZone
        var correctedComponents = sourceCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsedDate)
        correctedComponents.calendar = sourceCalendar
        correctedComponents.timeZone = sourceTimeZone

        var changed = false

        if let relativeWeekday = mentionedRelativeWeekday(in: instruction.sourceText),
           let targetWeekday = relativeWeekday.weekday {
            var localCalendar = Calendar(identifier: .gregorian)
            localCalendar.timeZone = localTimeZone
            let currentWeekday = localCalendar.component(.weekday, from: now)
            var daysUntilTarget = (targetWeekday - currentWeekday + 7) % 7
            if relativeWeekday.qualifier == "next", daysUntilTarget < 7 {
                daysUntilTarget += 7
            }
            if let targetDate = localCalendar.date(byAdding: .day, value: daysUntilTarget, to: now) {
                let targetDateComponents = localCalendar.dateComponents([.year, .month, .day], from: targetDate)
                let parsedDateComponents = sourceCalendar.dateComponents([.year, .month, .day], from: parsedDate)
                if parsedDateComponents.year != targetDateComponents.year ||
                    parsedDateComponents.month != targetDateComponents.month ||
                    parsedDateComponents.day != targetDateComponents.day {
                    correctedComponents.year = targetDateComponents.year
                    correctedComponents.month = targetDateComponents.month
                    correctedComponents.day = targetDateComponents.day
                    changed = true
                }
            }
        }

        if let clockTime = mentionedClockTime(in: instruction.sourceText),
           correctedComponents.hour != clockTime.hour || correctedComponents.minute != clockTime.minute {
            correctedComponents.hour = clockTime.hour
            correctedComponents.minute = clockTime.minute
            correctedComponents.second = 0
            changed = true
        }

        guard changed else {
            return instruction
        }

        guard let correctedDate = sourceCalendar.date(from: correctedComponents) else {
            return instruction
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = sourceCalendar
        formatter.timeZone = sourceTimeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return ConversionInstruction(
            sourceText: instruction.sourceText,
            fromTimeZone: instruction.fromTimeZone,
            toTimeZone: instruction.toTimeZone,
            dateTime: formatter.string(from: correctedDate),
            dstAmbiguity: instruction.dstAmbiguity
        )
    }

    private func mentionedRelativeWeekday(in source: String) -> (qualifier: String, weekday: Int?)? {
        let lowercased = source.lowercased()
        let weekdays: [(name: String, value: Int)] = [
            ("sunday", 1),
            ("monday", 2),
            ("tuesday", 3),
            ("wednesday", 4),
            ("thursday", 5),
            ("friday", 6),
            ("saturday", 7)
        ]

        for weekday in weekdays {
            if lowercased.contains("next \(weekday.name)") {
                return ("next", weekday.value)
            }
            if lowercased.contains("this \(weekday.name)") {
                return ("this", weekday.value)
            }
        }
        return nil
    }

    private func mentionedClockTime(in source: String) -> (hour: Int, minute: Int)? {
        let lowercased = source.lowercased()

        if let match = firstMatch(
            pattern: #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#,
            in: lowercased
        ) {
            guard let hourText = capture(1, in: match, source: lowercased),
                  var hour = Int(hourText) else {
                return nil
            }
            let minute = capture(2, in: match, source: lowercased).flatMap(Int.init) ?? 0
            let meridiem = capture(3, in: match, source: lowercased)

            if meridiem == "pm", hour < 12 {
                hour += 12
            }
            if meridiem == "am", hour == 12 {
                hour = 0
            }

            guard (0...23).contains(hour), (0...59).contains(minute) else {
                return nil
            }
            return (hour, minute)
        }

        if let match = firstMatch(pattern: #"\b([01]?\d|2[0-3]):([0-5]\d)\b"#, in: lowercased),
           let hourText = capture(1, in: match, source: lowercased),
           let minuteText = capture(2, in: match, source: lowercased),
           let hour = Int(hourText),
           let minute = Int(minuteText) {
            return (hour, minute)
        }

        return nil
    }

    private func firstMatch(pattern: String, in source: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.firstMatch(in: source, range: range)
    }

    private func capture(_ index: Int, in match: NSTextCheckingResult, source: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: source) else {
            return nil
        }
        return String(source[swiftRange])
    }

    private func parseDateTime(_ value: String, timeZone: TimeZone) -> Date? {
        let normalized = value
            .replacingOccurrences(of: "T", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return date
            }
        }

        return nil
    }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let input: [OpenAIInput]
    let text: OpenAIText
    let temperature: Double
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case text
        case temperature
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct OpenAIInput: Encodable {
    let role: String
    let content: String
}

private struct OpenAIText: Encodable {
    let format: OpenAITextFormat
}

private struct OpenAITextFormat: Encodable {
    let type: String
    let name: String
    let strict: Bool
    let schema: JSONValue

    static let timezoneConversionSchema = OpenAITextFormat(
        type: "json_schema",
        name: "timezone_conversion",
        strict: true,
        schema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([
                .string("fromTimeZone"),
                .string("toTimeZone"),
                .string("dateTime")
            ]),
            "properties": .object([
                "fromTimeZone": .object([
                    "type": .string("string"),
                    "description": .string("Source timezone as an IANA timezone identifier.")
                ]),
                "toTimeZone": .object([
                    "type": .string("string"),
                    "description": .string("Destination timezone as an IANA timezone identifier.")
                ]),
                "dateTime": .object([
                    "type": .string("string"),
                    "description": .string("Source datetime in the source timezone, formatted as yyyy-MM-dd HH:mm:ss.")
                ])
            ])
        ])
    )
}

private enum JSONValue: Encodable {
    case string(String)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let object):
            try container.encode(object)
        }
    }
}

private struct OpenAIResponse: Decodable {
    let output: [OpenAIOutput]

    var outputText: String? {
        for item in output {
            guard item.type == "message" else {
                continue
            }
            if let text = item.content?.compactMap(\.text).first {
                return text
            }
        }
        return nil
    }
}

private struct OpenAIOutput: Decodable {
    let type: String
    let content: [OpenAIContent]?
}

private struct OpenAIContent: Decodable {
    let type: String
    let text: String?
    let refusal: String?
}

private struct ParsedInstruction: Decodable {
    let fromTimeZone: String
    let toTimeZone: String
    let dateTime: String
}
