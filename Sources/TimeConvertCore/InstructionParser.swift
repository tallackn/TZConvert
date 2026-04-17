import Foundation

public enum InstructionParseError: Error, LocalizedError {
    case emptyInstruction
    case missingFromTimeZone
    case missingToTimeZone
    case missingDateTime
    case unknownTimeZone(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInstruction:
            return "Give me a conversion instruction, for example: convert 2026-04-17 09:30 from local to America/New_York"
        case .missingFromTimeZone:
            return "I could not find the source time zone. Try adding `from local` or `from Europe/London`."
        case .missingToTimeZone:
            return "I could not find the destination time zone. Try adding `to UTC` or `to Asia/Tokyo`."
        case .missingDateTime:
            return "I could not find a time or datetime. Try `2026-04-17 09:30`, `9:30am today`, or `14:00 tomorrow`."
        case .unknownTimeZone(let value):
            return "I could not map `\(value)` to an IANA time zone. Use a value like `America/New_York`, `Europe/London`, `UTC`, or `local`."
        }
    }
}

public final class InstructionParser {
    private let calendar: Calendar
    private let localTimeZone: TimeZone
    private let now: Date

    private let outputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public init(
        calendar: Calendar = Calendar(identifier: .gregorian),
        localTimeZone: TimeZone = .current,
        now: Date = Date()
    ) {
        var calendar = calendar
        calendar.timeZone = localTimeZone
        self.calendar = calendar
        self.localTimeZone = localTimeZone
        self.now = now
    }

    public func parse(_ input: String) throws -> ConversionInstruction {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw InstructionParseError.emptyInstruction
        }

        let timeZones = try inferTimeZones(in: source)
        let fromTimeZone = try resolveTimeZone(timeZones.from)
        let toTimeZone = try resolveTimeZone(timeZones.to)
        let dateTime = try parseDateTime(source, fromTimeZoneIdentifier: fromTimeZone)

        return ConversionInstruction(
            sourceText: source,
            fromTimeZone: fromTimeZone,
            toTimeZone: toTimeZone,
            dateTime: dateTime
        )
    }

    private func inferTimeZones(in source: String) throws -> (from: String, to: String) {
        let explicitFrom = captureTimeZone(after: "from", in: source, rejectDateTimeLikeValue: true)
        let explicitTo = captureTimeZone(after: "to", in: source)
        let personZone = capturePersonTimeZone(in: source)
        let contextualInZone = captureContextualInTimeZone(in: source)
        let wantsLocalTarget = mentionsLocalTarget(in: source)

        if let explicitFrom, let explicitTo {
            return (explicitFrom, explicitTo)
        }

        if let explicitFrom, let personZone {
            return (explicitFrom, personZone)
        }

        if let contextualInZone, let explicitTo {
            return (contextualInZone, explicitTo)
        }

        if let personZone, wantsLocalTarget {
            return (personZone, "local")
        }

        if explicitFrom != nil {
            throw InstructionParseError.missingToTimeZone
        }

        if explicitTo != nil {
            throw InstructionParseError.missingFromTimeZone
        }

        if personZone != nil {
            throw InstructionParseError.missingFromTimeZone
        }

        throw InstructionParseError.missingFromTimeZone
    }

    private func captureTimeZone(after keyword: String, in source: String) -> String? {
        captureTimeZone(after: keyword, in: source, rejectDateTimeLikeValue: false)
    }

    private func captureTimeZone(
        after keyword: String,
        in source: String,
        rejectDateTimeLikeValue: Bool
    ) -> String? {
        let stopWords = ["from", "to", "at", "on", "for", "into", "as", "please", "convert"]
        let pattern = "(?i)\\b\(keyword)\\b\\s+([A-Za-z0-9_+\\-/ ]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let captureRange = Range(match.range(at: 1), in: source) else {
            return nil
        }

        var words = String(source[captureRange])
            .replacingOccurrences(of: " into ", with: " to ", options: .caseInsensitive)
            .split(separator: " ")
            .map(String.init)

        while let last = words.last, stopWords.contains(last.lowercased()) {
            words.removeLast()
        }

        if let nextStopIndex = words.firstIndex(where: { stopWords.contains($0.lowercased()) }) {
            words = Array(words[..<nextStopIndex])
        }

        let value = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if rejectDateTimeLikeValue, looksLikeDateTime(value) {
            return nil
        }
        return value.isEmpty ? nil : value
    }

    private func capturePersonTimeZone(in source: String) -> String? {
        capture(
            pattern: #"(?i)\bfor\s+(?:someone|somebody|a person|them|him|her)?\s*in\s+([A-Za-z_+\-/ ]+?)(?=\s+\bin my time\s?zone\b|\s+\bmy time\s?zone\b|\s+\bfrom\b|\s+\bto\b|$)"#,
            in: source
        )
    }

    private func captureContextualInTimeZone(in source: String) -> String? {
        capture(
            pattern: #"(?i)\bin\s+([A-Za-z_+\-/ ]+?)\s+\bto\b"#,
            in: source
        )
    }

    private func capture(pattern: String, in source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let captureRange = Range(match.range(at: 1), in: source) else {
            return nil
        }

        let value = String(source[captureRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,"))
        return value.isEmpty ? nil : value
    }

    private func mentionsLocalTarget(in source: String) -> Bool {
        let lowercased = source.lowercased()
        return lowercased.contains("in my timezone")
            || lowercased.contains("in my time zone")
            || lowercased.contains("to my timezone")
            || lowercased.contains("to my time zone")
            || lowercased.contains("to local")
    }

    private func looksLikeDateTime(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        if lowercased.contains("am") || lowercased.contains("pm") {
            return true
        }
        if lowercased.contains("today")
            || lowercased.contains("tomorrow")
            || lowercased.contains("yesterday")
            || lowercased.contains("this ") {
            return true
        }
        return value.range(of: #"\d"#, options: .regularExpression) != nil
    }

    private func resolveTimeZone(_ rawValue: String) throws -> String {
        let cleaned = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,"))

        let lowered = cleaned.lowercased()
        if ["local", "here", "system", "me", "my timezone", "my time zone"].contains(lowered) {
            return localTimeZone.identifier
        }
        if lowered == "utc" || lowered == "zulu" {
            return "UTC"
        }
        if lowered == "gmt" {
            return "Etc/GMT"
        }

        if TimeZone(identifier: cleaned) != nil {
            return cleaned
        }

        let slashy = cleaned.replacingOccurrences(of: " ", with: "_")
        if TimeZone(identifier: slashy) != nil {
            return slashy
        }

        let aliases: [String: String] = [
            "new york": "America/New_York",
            "nyc": "America/New_York",
            "los angeles": "America/Los_Angeles",
            "la": "America/Los_Angeles",
            "san francisco": "America/Los_Angeles",
            "london": "Europe/London",
            "paris": "Europe/Paris",
            "berlin": "Europe/Berlin",
            "tokyo": "Asia/Tokyo",
            "singapore": "Asia/Singapore",
            "sydney": "Australia/Sydney",
            "melbourne": "Australia/Melbourne",
            "auckland": "Pacific/Auckland",
            "wellington": "Pacific/Auckland",
            "nz": "Pacific/Auckland",
            "new zealand": "Pacific/Auckland",
            "pacific": "America/Los_Angeles",
            "eastern": "America/New_York",
            "central": "America/Chicago",
            "mountain": "America/Denver"
        ]

        if let alias = aliases[lowered] {
            return alias
        }

        throw InstructionParseError.unknownTimeZone(rawValue)
    }

    private func parseDateTime(_ source: String, fromTimeZoneIdentifier: String) throws -> String {
        var fromCalendar = calendar
        if let fromTimeZone = TimeZone(identifier: fromTimeZoneIdentifier) {
            fromCalendar.timeZone = fromTimeZone
        }

        if let explicit = parseExplicitDateTime(source, calendar: fromCalendar) {
            return explicit
        }

        if containsRelativeDay(in: source),
           let timeOnly = parseTimeOnly(source, calendar: fromCalendar) {
            return timeOnly
        }

        if let detected = parseWithDataDetector(source, calendar: fromCalendar) {
            return detected
        }

        if let timeOnly = parseTimeOnly(source, calendar: fromCalendar) {
            return timeOnly
        }

        throw InstructionParseError.missingDateTime
    }

    private func containsRelativeDay(in source: String) -> Bool {
        let lowercased = source.lowercased()
        return lowercased.contains("today")
            || lowercased.contains("tomorrow")
            || lowercased.contains("yesterday")
            || weekdayOffset(in: lowercased, calendar: calendar) != nil
    }

    private func parseExplicitDateTime(_ source: String, calendar: Calendar) -> String? {
        let patterns = [
            #"(\d{4}-\d{2}-\d{2})[ T](\d{1,2}:\d{2}(?::\d{2})?)"#,
            #"(\d{4}/\d{2}/\d{2})[ T](\d{1,2}:\d{2}(?::\d{2})?)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)),
                  let dateRange = Range(match.range(at: 1), in: source),
                  let timeRange = Range(match.range(at: 2), in: source) else {
                continue
            }

            let date = String(source[dateRange]).replacingOccurrences(of: "/", with: "-")
            var time = String(source[timeRange])
            if time.split(separator: ":").count == 2 {
                time += ":00"
            }
            return normalize("\(date) \(time)", calendar: calendar)
        }

        return nil
    }

    private func parseWithDataDetector(_ source: String, calendar: Calendar) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = detector.matches(in: source, range: range).first,
              let date = match.date else {
            return nil
        }

        outputFormatter.timeZone = calendar.timeZone
        return outputFormatter.string(from: date)
    }

    private func parseTimeOnly(_ source: String, calendar: Calendar) -> String? {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let colonPattern = #"(?i)\b(\d{1,2}):(\d{2})\s*(am|pm)?\b"#
        let meridiemPattern = #"(?i)\b(\d{1,2})\s*(am|pm)\b"#

        let parsedTime: (hour: Int, minute: Int, meridiem: String?)
        if let regex = try? NSRegularExpression(pattern: colonPattern),
           let match = regex.firstMatch(in: source, range: range),
           let hourRange = Range(match.range(at: 1), in: source),
           let minuteRange = Range(match.range(at: 2), in: source) {
            let meridiem = Range(match.range(at: 3), in: source).map { String(source[$0]).lowercased() }
            parsedTime = (
                hour: Int(source[hourRange]) ?? 0,
                minute: Int(source[minuteRange]) ?? 0,
                meridiem: meridiem
            )
        } else if let regex = try? NSRegularExpression(pattern: meridiemPattern),
                  let match = regex.firstMatch(in: source, range: range),
                  let hourRange = Range(match.range(at: 1), in: source),
                  let meridiemRange = Range(match.range(at: 2), in: source) {
            parsedTime = (
                hour: Int(source[hourRange]) ?? 0,
                minute: 0,
                meridiem: String(source[meridiemRange]).lowercased()
            )
        } else {
            return nil
        }

        var hour = parsedTime.hour
        let minute = parsedTime.minute
        if let meridiem = parsedTime.meridiem {
            if meridiem == "pm", hour < 12 {
                hour += 12
            }
            if meridiem == "am", hour == 12 {
                hour = 0
            }
        }

        guard (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }

        var dayOffset = 0
        let lowercased = source.lowercased()
        if lowercased.contains("tomorrow") {
            dayOffset = 1
        } else if lowercased.contains("yesterday") {
            dayOffset = -1
        } else if let offset = weekdayOffset(in: lowercased, calendar: calendar) {
            dayOffset = offset
        }

        guard let baseDate = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let date = calendar.date(from: components) else {
            return nil
        }
        outputFormatter.timeZone = calendar.timeZone
        return outputFormatter.string(from: date)
    }

    private func weekdayOffset(in lowercasedSource: String, calendar: Calendar) -> Int? {
        let weekdays = [
            "sunday": 1,
            "monday": 2,
            "tuesday": 3,
            "wednesday": 4,
            "thursday": 5,
            "friday": 6,
            "saturday": 7
        ]

        guard let match = weekdays.first(where: { lowercasedSource.contains($0.key) }) else {
            return nil
        }

        let currentWeekday = calendar.component(.weekday, from: now)
        var offset = (match.value - currentWeekday + 7) % 7
        if lowercasedSource.contains("next \(match.key)"), offset == 0 {
            offset = 7
        }
        return offset
    }

    private func normalize(_ value: String, calendar: Calendar) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        if let date = formatter.date(from: value) {
            outputFormatter.timeZone = calendar.timeZone
            return outputFormatter.string(from: date)
        }
        return nil
    }
}
