import Foundation
import Darwin
import TimeConvertCore

@main
struct TZConvert {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--help") || arguments.contains("-h") {
            printHelp()
            return
        }

        if arguments.contains("--set-openai-key") {
            setOpenAIKey()
            return
        }

        if arguments.contains("--delete-openai-key") {
            deleteOpenAIKey()
            return
        }

        let explainOnly = arguments.contains("--explain")
        let verbose = arguments.contains("--verbose")
        let debug = arguments.contains("--debug")
        let instructionText = arguments
            .filter { $0 != "--explain" }
            .filter { $0 != "--verbose" }
            .filter { $0 != "--debug" }
            .joined(separator: " ")
        let debugHandler: ((OpenAIDebugEvent) -> Void)?
        if debug {
            debugHandler = printOpenAIDebugEvent
        } else {
            debugHandler = nil
        }

        do {
            printDebugPhase("Starting OpenAI parse", enabled: debug)
            let instruction = try await OpenAIInstructionParser(
                debugHandler: debugHandler
            ).parse(instructionText)
            printDebugPhase("Finished OpenAI parse", enabled: debug)

            if explainOnly {
                let summary = explainSummary(for: instruction)
                if verbose {
                    printResolvedInstruction(instruction)
                    print("")
                    print("Summary")
                    print("  \(summary)")
                } else {
                    print(summary)
                }
                return
            }

            printDebugPhase("Starting TimeAPI conversion", enabled: debug)
            let response = try await TimeAPIClient().convert(instruction)
            printDebugPhase("Finished TimeAPI conversion", enabled: debug)
            let result = bestResult(from: response)
            printDebugPhase("Starting OpenAI summary", enabled: debug)
            let summary = await formattedSummary(
                for: instruction,
                result: result,
                response: response,
                debugHandler: debugHandler
            )
            printDebugPhase("Finished OpenAI summary", enabled: debug)
            if verbose {
                printResolvedInstruction(instruction)
                print("")
                print("TimeAPI")
                printJSON(response)
                print("")
                print("Summary")
                print("  \(summary)")
            } else {
                print(summary)
            }
        } catch {
            fputs("tzconvert: \(error.localizedDescription)\n", stderr)
            fputs("Run `swift run tzconvert -- --help` for examples.\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func printDebugPhase(_ message: String, enabled: Bool) {
        guard enabled else {
            return
        }

        fputs("\n[debug] \(message)\n", stderr)
        fflush(stderr)
    }

    private static func formattedSummary(
        for instruction: ConversionInstruction,
        result: String,
        response: ConversionResponse,
        debugHandler: ((OpenAIDebugEvent) -> Void)? = nil
    ) async -> String {
        do {
            return try await OpenAISummaryFormatter(debugHandler: debugHandler).format(
                instruction: instruction,
                result: result,
                response: response
            )
        } catch {
            return conversionSummary(for: instruction, result: result)
        }
    }

    private static func printOpenAIDebugEvent(_ event: OpenAIDebugEvent) {
        fputs("\n[debug] \(event.label)\n", stderr)
        if let requestBody = event.requestBody {
            fputs(indent(prettyJSONString(requestBody) ?? requestBody), stderr)
            fputs("\n", stderr)
        }
        if let responseStatus = event.responseStatus {
            fputs("  status: \(responseStatus)\n", stderr)
        }
        if let responseBody = event.responseBody {
            fputs(indent(prettyJSONString(responseBody) ?? responseBody), stderr)
            fputs("\n", stderr)
        }
        fflush(stderr)
    }

    private static func prettyJSONString(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }

        return String(data: pretty, encoding: .utf8)
    }

    private static func indent(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }

    private static func setOpenAIKey() {
        guard let rawKey = getpass("OpenAI API key: ") else {
            fputs("tzconvert: Could not read key.\n", stderr)
            Darwin.exit(1)
        }

        do {
            try KeychainSecretStore().saveOpenAIAPIKey(String(cString: rawKey))
            print("Stored OpenAI API key in macOS Keychain.")
        } catch {
            fputs("tzconvert: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func deleteOpenAIKey() {
        do {
            try KeychainSecretStore().deleteOpenAIAPIKey()
            print("Deleted stored OpenAI API key from macOS Keychain.")
        } catch {
            fputs("tzconvert: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func printResolvedInstruction(_ instruction: ConversionInstruction) {
        print("Request")
        print("  from: \(instruction.fromTimeZone)")
        print("  to:   \(instruction.toTimeZone)")
        print("  at:   \(instruction.dateTime)")
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                print("  \(line)")
            }
        } else {
            print("  <could not encode response>")
        }
    }

    private static func bestResult(from response: ConversionResponse) -> String {
        if let convertedDateTime = response.convertedDateTime {
            return convertedDateTime
        }
        if let dateTime = response.conversionResult?.dateTime {
            return dateTime
        }
        if let date = response.conversionResult?.date,
           let time = response.conversionResult?.time {
            return "\(date) \(time)"
        }
        return "Converted, but the response did not include a displayable datetime."
    }

    private static func explainSummary(for instruction: ConversionInstruction) -> String {
        guard let convertedDate = convertedDate(for: instruction) else {
            return "I will convert \(friendlyDateTime(instruction.dateTime, timeZoneIdentifier: instruction.fromTimeZone)) in \(placeName(for: instruction.fromTimeZone)) to \(placeName(for: instruction.toTimeZone))."
        }

        return naturalLanguageSummary(
            sourceText: instruction.sourceText,
            sourceDateTime: instruction.dateTime,
            sourceTimeZoneIdentifier: instruction.fromTimeZone,
            destinationDate: convertedDate,
            destinationTimeZoneIdentifier: instruction.toTimeZone
        )
    }

    private static func conversionSummary(for instruction: ConversionInstruction, result: String) -> String {
        if let destinationDate = parseDateTime(result, timeZoneIdentifier: instruction.toTimeZone) {
            return naturalLanguageSummary(
                sourceText: instruction.sourceText,
                sourceDateTime: instruction.dateTime,
                sourceTimeZoneIdentifier: instruction.fromTimeZone,
                destinationDate: destinationDate,
                destinationTimeZoneIdentifier: instruction.toTimeZone
            )
        }

        return "\(friendlyDateTime(instruction.dateTime, timeZoneIdentifier: instruction.fromTimeZone)) in \(placeName(for: instruction.fromTimeZone)) is \(friendlyDateTime(result, timeZoneIdentifier: instruction.toTimeZone)) in \(placeName(for: instruction.toTimeZone))."
    }

    private static func naturalLanguageSummary(
        sourceText: String,
        sourceDateTime: String,
        sourceTimeZoneIdentifier: String,
        destinationDate: Date,
        destinationTimeZoneIdentifier: String
    ) -> String {
        guard let sourceDate = parseDateTime(sourceDateTime, timeZoneIdentifier: sourceTimeZoneIdentifier),
              let destinationTimeZone = TimeZone(identifier: destinationTimeZoneIdentifier) else {
            return "\(friendlyDateTime(sourceDateTime, timeZoneIdentifier: sourceTimeZoneIdentifier)) in \(placeName(for: sourceTimeZoneIdentifier)) will be \(friendlyDateTime(destinationDate, timeZone: .current)) in \(placeName(for: destinationTimeZoneIdentifier))."
        }

        let style = summaryStyle(from: sourceText)
        return "\(timePhrase(sourceDate, timeZoneIdentifier: sourceTimeZoneIdentifier, style: style.timeStyle)) \(dayPhrase(sourceDate, timeZoneIdentifier: sourceTimeZoneIdentifier, style: style.dateStyle)) in \(placeName(for: sourceTimeZoneIdentifier)) will be \(timePhrase(destinationDate, timeZone: destinationTimeZone, style: style.timeStyle)) \(dayPhrase(destinationDate, timeZone: destinationTimeZone, style: style.dateStyle)) in \(placeName(for: destinationTimeZoneIdentifier))."
    }

    private static func convertedDate(for instruction: ConversionInstruction) -> Date? {
        guard let sourceDate = parseDateTime(instruction.dateTime, timeZoneIdentifier: instruction.fromTimeZone) else {
            return nil
        }
        return sourceDate
    }

    private static func parseDateTime(_ value: String, timeZoneIdentifier: String) -> Date? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            return nil
        }

        let normalized = value
            .replacingOccurrences(of: "T", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let inputFormats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm"
        ]

        for format in inputFormats {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.calendar = Calendar(identifier: .gregorian)
            parser.timeZone = timeZone
            parser.dateFormat = format

            if let date = parser.date(from: normalized) {
                return date
            }
        }

        return nil
    }

    private static func friendlyDateTime(_ value: String, timeZoneIdentifier: String) -> String {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier),
              let date = parseDateTime(value, timeZoneIdentifier: timeZoneIdentifier) else {
            return value
        }

        return friendlyDateTime(date, timeZone: timeZone)
    }

    private static func friendlyDateTime(_ date: Date, timeZone: TimeZone) -> String {
        let output = DateFormatter()
        output.locale = Locale.current
        output.calendar = Calendar(identifier: .gregorian)
        output.timeZone = timeZone
        output.dateStyle = .medium
        output.timeStyle = .short
        return output.string(from: date)
    }

    private static func compactTime(_ date: Date, timeZoneIdentifier: String) -> String {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            return friendlyDateTime(date, timeZone: .current)
        }
        return compactTime(date, timeZone: timeZone)
    }

    private static func compactTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"

        return formatter.string(from: date)
            .replacingOccurrences(of: ":00", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    private static func twentyFourHourTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func relativeDay(_ date: Date, timeZoneIdentifier: String) -> String {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            return ""
        }
        return relativeDay(date, timeZone: timeZone)
    }

    private enum SummaryDateStyle {
        case inferred
        case relativeWeekday(String)
        case absolute(String?)
    }

    private enum SummaryTimeStyle {
        case compactTwelveHour
        case twentyFourHour
    }

    private struct SummaryStyle {
        let dateStyle: SummaryDateStyle
        let timeStyle: SummaryTimeStyle
    }

    private static func summaryStyle(from sourceText: String) -> SummaryStyle {
        SummaryStyle(
            dateStyle: dateStyle(from: sourceText),
            timeStyle: timeStyle(from: sourceText)
        )
    }

    private static func dateStyle(from sourceText: String) -> SummaryDateStyle {
        let lowercased = sourceText.lowercased()
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

        for weekday in weekdays {
            if lowercased.contains("next \(weekday)") {
                return .relativeWeekday("next")
            }
            if lowercased.contains("this \(weekday)") {
                return .relativeWeekday("this")
            }
        }

        if lowercased.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression) != nil {
            return .absolute("yyyy-MM-dd")
        }
        if lowercased.range(of: #"\b\d{1,2}/\d{1,2}/\d{4}\b"#, options: .regularExpression) != nil {
            return .absolute("dd/MM/yyyy")
        }
        if lowercased.range(of: #"\b\d{1,2}/\d{1,2}/\d{2}\b"#, options: .regularExpression) != nil {
            return .absolute("dd/MM/yy")
        }
        if lowercased.range(of: #"\b\d{1,2}-\d{1,2}-\d{4}\b"#, options: .regularExpression) != nil {
            return .absolute("dd-MM-yyyy")
        }
        if lowercased.range(of: #"\b\d{1,2}\s+(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\b"#, options: .regularExpression) != nil {
            return .absolute(nil)
        }

        return .inferred
    }

    private static func timeStyle(from sourceText: String) -> SummaryTimeStyle {
        let lowercased = sourceText.lowercased()
        if lowercased.range(of: #"\b([01]?\d|2[0-3]):[0-5]\d\b"#, options: .regularExpression) != nil,
           lowercased.range(of: #"\b\d{1,2}(:\d{2})?\s*(am|pm)\b"#, options: .regularExpression) == nil {
            return .twentyFourHour
        }

        return .compactTwelveHour
    }

    private static func timePhrase(_ date: Date, timeZoneIdentifier: String, style: SummaryTimeStyle) -> String {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            return friendlyDateTime(date, timeZone: .current)
        }
        return timePhrase(date, timeZone: timeZone, style: style)
    }

    private static func timePhrase(_ date: Date, timeZone: TimeZone, style: SummaryTimeStyle) -> String {
        switch style {
        case .compactTwelveHour:
            return compactTime(date, timeZone: timeZone)
        case .twentyFourHour:
            return twentyFourHourTime(date, timeZone: timeZone)
        }
    }

    private static func dayPhrase(_ date: Date, timeZoneIdentifier: String, style: SummaryDateStyle) -> String {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            return ""
        }
        return dayPhrase(date, timeZone: timeZone, style: style)
    }

    private static func dayPhrase(_ date: Date, timeZone: TimeZone, style: SummaryDateStyle) -> String {
        switch style {
        case .inferred:
            return relativeDay(date, timeZone: timeZone)
        case .relativeWeekday(let qualifier):
            return "\(qualifier) \(weekdayName(date, timeZone: timeZone))"
        case .absolute(let format):
            return absoluteDay(date, timeZone: timeZone, format: format)
        }
    }

    private static func relativeDay(_ date: Date, timeZone: TimeZone) -> String {
        var outputCalendar = Calendar(identifier: .gregorian)
        outputCalendar.timeZone = timeZone
        let outputComponents = outputCalendar.dateComponents([.year, .month, .day], from: date)

        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = .current
        let now = Date()

        for offset in 0..<14 {
            guard let candidate = localCalendar.date(byAdding: .day, value: offset, to: now) else {
                continue
            }
            let candidateComponents = localCalendar.dateComponents([.year, .month, .day], from: candidate)
            guard candidateComponents.year == outputComponents.year,
                  candidateComponents.month == outputComponents.month,
                  candidateComponents.day == outputComponents.day else {
                continue
            }

            let weekdayFormatter = DateFormatter()
            weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
            weekdayFormatter.calendar = outputCalendar
            weekdayFormatter.timeZone = timeZone
            weekdayFormatter.dateFormat = "EEEE"
            let weekday = weekdayFormatter.string(from: date)

            if offset == 0 {
                return "today"
            }
            if offset >= 7 {
                return "next \(weekday)"
            }
            return "this \(weekday)"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = outputCalendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func weekdayName(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private static func absoluteDay(_ date: Date, timeZone: TimeZone, format: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.timeStyle = .none
        if let format {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
        } else {
            formatter.dateStyle = .medium
        }
        return "on \(formatter.string(from: date))"
    }

    private static func placeName(for timeZoneIdentifier: String) -> String {
        if timeZoneIdentifier == "UTC" {
            return "UTC"
        }

        return timeZoneIdentifier
            .split(separator: "/")
            .last
            .map { String($0).replacingOccurrences(of: "_", with: " ") } ?? timeZoneIdentifier
    }

    private static func printHelp() {
        print("""
        tzconvert - natural-language timezone conversion through TimeAPI.io

        Usage:
          tzconvert --set-openai-key
          tzconvert "3pm this saturday for someone in london in my timezone"
          tzconvert "from 3pm this saturday in london to local"
          tzconvert "2026-04-17 09:30 from UTC to Europe/London"

        Options:
          --explain   Ask OpenAI to parse the instruction and print the resolved API inputs without calling TimeAPI.
          --verbose   Print the resolved request, raw TimeAPI result, and natural-language summary.
          --debug     Print OpenAI request and response JSON to stderr.
          --set-openai-key
                      Prompt for an OpenAI API key and store it in macOS Keychain.
          --delete-openai-key
                      Delete the stored OpenAI API key from macOS Keychain.
          --help      Show this help.

        Notes:
          - `local`, `here`, and `my timezone` resolve to this Mac's current system time zone.
          - OPENAI_API_KEY overrides the Keychain value for the current process.
          - The default parser model is gpt-5.4-nano. Set OPENAI_MODEL to override it.
        """)
    }
}
