import Foundation

public struct OpenAIDebugEvent: Sendable {
    public let label: String
    public let requestBody: String?
    public let responseStatus: Int?
    public let responseBody: String?

    public init(
        label: String,
        requestBody: String? = nil,
        responseStatus: Int? = nil,
        responseBody: String? = nil
    ) {
        self.label = label
        self.requestBody = requestBody
        self.responseStatus = responseStatus
        self.responseBody = responseBody
    }
}
