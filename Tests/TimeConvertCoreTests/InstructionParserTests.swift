import XCTest
@testable import TimeConvertCore

final class InstructionParserTests: XCTestCase {
    private let fixedNow: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        return calendar.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 17,
            hour: 12,
            minute: 0,
            second: 0
        ))!
    }()

    func testParsesExplicitDateTimeWithLocalSource() throws {
        let parser = InstructionParser(
            localTimeZone: TimeZone(identifier: "Pacific/Auckland")!,
            now: fixedNow
        )

        let instruction = try parser.parse("convert 2026-04-17 09:30 from local to America/New_York")

        XCTAssertEqual(instruction.fromTimeZone, "Pacific/Auckland")
        XCTAssertEqual(instruction.toTimeZone, "America/New_York")
        XCTAssertEqual(instruction.dateTime, "2026-04-17 09:30:00")
    }

    func testParsesCityAliasesAndTimeOnly() throws {
        let parser = InstructionParser(
            localTimeZone: TimeZone(identifier: "Pacific/Auckland")!,
            now: fixedNow
        )

        let instruction = try parser.parse("9am tomorrow from Auckland to Tokyo")

        XCTAssertEqual(instruction.fromTimeZone, "Pacific/Auckland")
        XCTAssertEqual(instruction.toTimeZone, "Asia/Tokyo")
        XCTAssertEqual(instruction.dateTime, "2026-04-18 09:00:00")
    }

    func testParsesUTCToLocal() throws {
        let parser = InstructionParser(
            localTimeZone: TimeZone(identifier: "Pacific/Auckland")!,
            now: fixedNow
        )

        let instruction = try parser.parse("2026-04-17 14:00 from UTC to local")

        XCTAssertEqual(instruction.fromTimeZone, "UTC")
        XCTAssertEqual(instruction.toTimeZone, "Pacific/Auckland")
        XCTAssertEqual(instruction.dateTime, "2026-04-17 14:00:00")
    }

    func testInfersLondonToLocalFromSomeoneInLondonInMyTimezone() throws {
        let parser = InstructionParser(
            localTimeZone: TimeZone(identifier: "Pacific/Auckland")!,
            now: fixedNow
        )

        let instruction = try parser.parse("3pm this saturday for someone in london in my timezone")

        XCTAssertEqual(instruction.fromTimeZone, "Europe/London")
        XCTAssertEqual(instruction.toTimeZone, "Pacific/Auckland")
        XCTAssertEqual(instruction.dateTime, "2026-04-18 15:00:00")
    }

    func testInfersLocalToLondonFromSomeoneInLondonFromLocal() throws {
        let parser = InstructionParser(
            localTimeZone: TimeZone(identifier: "Pacific/Auckland")!,
            now: fixedNow
        )

        let instruction = try parser.parse("3pm this saturday for someone in london from local")

        XCTAssertEqual(instruction.fromTimeZone, "Pacific/Auckland")
        XCTAssertEqual(instruction.toTimeZone, "Europe/London")
        XCTAssertEqual(instruction.dateTime, "2026-04-18 15:00:00")
    }

    func testInfersLondonToLocalFromTimeInLondonToLocal() throws {
        let parser = InstructionParser(
            localTimeZone: TimeZone(identifier: "Pacific/Auckland")!,
            now: fixedNow
        )

        let instruction = try parser.parse("from 3pm this saturday in london to local")

        XCTAssertEqual(instruction.fromTimeZone, "Europe/London")
        XCTAssertEqual(instruction.toTimeZone, "Pacific/Auckland")
        XCTAssertEqual(instruction.dateTime, "2026-04-18 15:00:00")
    }
}
