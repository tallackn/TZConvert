import Foundation

public enum OpenAISummaryFormatterError: Error, LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is not configured. Run `tzconvert --set-openai-key` to store it in macOS Keychain, or export OPENAI_API_KEY for this shell."
        case .invalidResponse:
            return "OpenAI did not return a natural-language summary."
        case .httpStatus(let status, let body):
            return "OpenAI returned HTTP \(status): \(body)"
        }
    }
}

public final class OpenAISummaryFormatter {
    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let session: URLSession
    private let debugHandler: ((OpenAIDebugEvent) -> Void)?

    public convenience init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        debugHandler: ((OpenAIDebugEvent) -> Void)? = nil
    ) throws {
        let environmentAPIKey = environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedAPIKey = try KeychainSecretStore().loadOpenAIAPIKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = [environmentAPIKey, storedAPIKey].compactMap({ $0 }).first(where: { !$0.isEmpty }),
              !apiKey.isEmpty else {
            throw OpenAISummaryFormatterError.missingAPIKey
        }

        self.init(
            apiKey: apiKey,
            model: environment["OPENAI_MODEL"] ?? "gpt-5.4-nano",
            debugHandler: debugHandler
        )
    }

    public init(
        apiKey: String,
        model: String = "gpt-5.4-nano",
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        session: URLSession = .shared,
        debugHandler: ((OpenAIDebugEvent) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
        self.debugHandler = debugHandler
    }

    public func format(
        instruction: ConversionInstruction,
        result: String,
        response: ConversionResponse
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestBody = try JSONEncoder().encode(makeRequestBody(
            instruction: instruction,
            result: result,
            response: response
        ))
        request.httpBody = requestBody
        emitDebug(label: "OpenAI summary request", requestBody: requestBody)

        let (data, urlResponse) = try await data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw OpenAISummaryFormatterError.invalidResponse
        }
        emitDebug(
            label: "OpenAI summary response",
            responseStatus: httpResponse.statusCode,
            responseBody: data
        )
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAISummaryFormatterError.httpStatus(httpResponse.statusCode, body)
        }

        let responseBody = try JSONDecoder().decode(SummaryOpenAIResponse.self, from: data)
        guard let outputText = responseBody.outputText,
              let outputData = outputText.data(using: .utf8) else {
            throw OpenAISummaryFormatterError.invalidResponse
        }

        let summary = sanitize(try JSONDecoder().decode(FormattedSummary.self, from: outputData)
            .summary
            .trimmingCharacters(in: .whitespacesAndNewlines))
        guard !summary.isEmpty else {
            throw OpenAISummaryFormatterError.invalidResponse
        }

        return summary
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

    private func sanitize(_ summary: String) -> String {
        summary
            .replacingOccurrences(of: " in your timezone", with: "")
            .replacingOccurrences(of: " in your time zone", with: "")
            .replacingOccurrences(of: " in my timezone", with: "")
            .replacingOccurrences(of: " in my time zone", with: "")
    }

    private func makeRequestBody(
        instruction: ConversionInstruction,
        result: String,
        response: ConversionResponse
    ) throws -> SummaryOpenAIRequest {
        return SummaryOpenAIRequest(
            model: model,
            input: [
                SummaryOpenAIInput(
                    role: "system",
                    content: """
                    Write one timezone conversion sentence. Return schema JSON only.
                    Use source -> destination exactly. Match the original request's time/date style. If original uses relative weekday wording, use source weekday and destination weekday with that same relative style. Do not copy "my timezone" or "your timezone".
                    Shape: <source time/date> in <source place> will be <destination time/date> in <destination place>.
                    """
                ),
                SummaryOpenAIInput(
                    role: "user",
                    content: """
                    original: "\(instruction.sourceText)"
                    source: place=\(placeName(for: instruction.fromTimeZone)); tz=\(instruction.fromTimeZone); dt=\(instruction.dateTime); weekday=\(weekday(for: instruction.dateTime, timeZoneIdentifier: instruction.fromTimeZone))
                    destination: place=\(placeName(for: instruction.toTimeZone)); tz=\(instruction.toTimeZone); dt=\(result); weekday=\(weekday(for: result, timeZoneIdentifier: instruction.toTimeZone))
                    timeapi: \(compactTimeAPI(response))
                    """
                )
            ],
            text: SummaryOpenAIText(format: .summarySchema),
            temperature: 0,
            maxOutputTokens: 80
        )
    }

    private func compactTimeAPI(_ response: ConversionResponse) -> String {
        [
            "from=\(response.fromTimezone ?? response.fromTimeZone ?? "")",
            "fromDateTime=\(response.fromDateTime ?? response.originalDateTime ?? "")",
            "to=\(response.toTimeZone ?? "")",
            "result=\(response.convertedDateTime ?? response.conversionResult?.dateTime ?? "")"
        ].joined(separator: "; ")
    }

    private func placeName(for timeZoneIdentifier: String) -> String {
        if timeZoneIdentifier == "UTC" {
            return "UTC"
        }

        return timeZoneIdentifier
            .split(separator: "/")
            .last
            .map { String($0).replacingOccurrences(of: "_", with: " ") } ?? timeZoneIdentifier
    }

    private func weekday(for value: String, timeZoneIdentifier: String) -> String {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier),
              let date = parseDateTime(value, timeZone: timeZone) else {
            return ""
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private func parseDateTime(_ value: String, timeZone: TimeZone) -> Date? {
        let normalized = value
            .replacingOccurrences(of: "T", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"]

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

private struct SummaryOpenAIRequest: Encodable {
    let model: String
    let input: [SummaryOpenAIInput]
    let text: SummaryOpenAIText
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

private struct SummaryOpenAIInput: Encodable {
    let role: String
    let content: String
}

private struct SummaryOpenAIText: Encodable {
    let format: SummaryOpenAITextFormat
}

private struct SummaryOpenAITextFormat: Encodable {
    let type: String
    let name: String
    let strict: Bool
    let schema: SummaryJSONValue

    static let summarySchema = SummaryOpenAITextFormat(
        type: "json_schema",
        name: "timezone_summary",
        strict: true,
        schema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("summary")]),
            "properties": .object([
                "summary": .object([
                    "type": .string("string"),
                    "description": .string("One natural-language timezone conversion sentence.")
                ])
            ])
        ])
    )
}

private enum SummaryJSONValue: Encodable {
    case string(String)
    case bool(Bool)
    case array([SummaryJSONValue])
    case object([String: SummaryJSONValue])

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

private struct SummaryOpenAIResponse: Decodable {
    let output: [SummaryOpenAIOutput]

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

private struct SummaryOpenAIOutput: Decodable {
    let type: String
    let content: [SummaryOpenAIContent]?
}

private struct SummaryOpenAIContent: Decodable {
    let type: String
    let text: String?
    let refusal: String?
}

private struct FormattedSummary: Decodable {
    let summary: String
}
