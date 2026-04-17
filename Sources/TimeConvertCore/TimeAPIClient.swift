import Foundation

public enum TimeAPIError: Error, LocalizedError {
    case invalidURL
    case httpStatus(Int, String)
    case emptyResponse
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not build the TimeAPI request URL."
        case .httpStatus(let status, let body):
            return "TimeAPI returned HTTP \(status): \(body)"
        case .emptyResponse:
            return "TimeAPI returned an empty response."
        case .timeout:
            return "TimeAPI request timed out."
        }
    }
}

public final class TimeAPIClient {
    private let endpoint: URL
    private let session: URLSession

    public init(
        endpoint: URL = URL(string: "https://timeapi.io/api/Conversion/ConvertTimeZone")!,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    public func convert(_ instruction: ConversionInstruction) async throws -> ConversionResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(TimeAPIRequest(instruction: instruction))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await performRequest(request)
        } catch let error as URLError where error.code == .timedOut {
            throw TimeAPIError.timeout
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TimeAPIError.emptyResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TimeAPIError.httpStatus(httpResponse.statusCode, body)
        }
        return try JSONDecoder().decode(ConversionResponse.self, from: data)
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
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
}

private struct TimeAPIRequest: Encodable {
    let fromTimeZone: String
    let dateTime: String
    let toTimeZone: String
    let dstAmbiguity: String

    init(instruction: ConversionInstruction) {
        self.fromTimeZone = instruction.fromTimeZone
        self.dateTime = instruction.dateTime
        self.toTimeZone = instruction.toTimeZone
        self.dstAmbiguity = instruction.dstAmbiguity
    }
}
