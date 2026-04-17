import Foundation

public struct ConversionInstruction: Equatable {
    public let sourceText: String
    public let fromTimeZone: String
    public let toTimeZone: String
    public let dateTime: String
    public let dstAmbiguity: String

    public init(
        sourceText: String,
        fromTimeZone: String,
        toTimeZone: String,
        dateTime: String,
        dstAmbiguity: String = ""
    ) {
        self.sourceText = sourceText
        self.fromTimeZone = fromTimeZone
        self.toTimeZone = toTimeZone
        self.dateTime = dateTime
        self.dstAmbiguity = dstAmbiguity
    }
}

public struct ConversionResponse: Codable {
    public let fromTimeZone: String?
    public let fromTimezone: String?
    public let toTimeZone: String?
    public let fromDateTime: String?
    public let originalDateTime: String?
    public let convertedDateTime: String?
    public let conversionResult: ConversionResult?
}

public struct ConversionResult: Codable {
    public let year: Int?
    public let month: Int?
    public let day: Int?
    public let hour: Int?
    public let minute: Int?
    public let seconds: Int?
    public let milliSeconds: Int?
    public let dateTime: String?
    public let date: String?
    public let time: String?
    public let dstActive: Bool?
}
