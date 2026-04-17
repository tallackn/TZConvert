import Foundation
import Security

public enum KeychainSecretError: Error, LocalizedError {
    case emptySecret
    case unexpectedData
    case osStatus(OSStatus)
    case commandTimedOut

    public var errorDescription: String? {
        switch self {
        case .emptySecret:
            return "The secret was empty, so it was not stored."
        case .unexpectedData:
            return "The Keychain item was present but was not readable as text."
        case .osStatus(let status):
            return "Keychain operation failed with OSStatus \(status)."
        case .commandTimedOut:
            return "Keychain operation timed out."
        }
    }
}

public final class KeychainSecretStore {
    private let service: String
    private let account: String

    public init(
        service: String = "tzconvert.openai",
        account: String = "OPENAI_API_KEY"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOpenAIAPIKey() throws -> String? {
        let output = try runSecurityCommand([
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w"
        ])
        guard let value = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value
    }

    public func saveOpenAIAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeychainSecretError.emptySecret
        }

        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            guard updateStatus == errSecSuccess else {
                throw KeychainSecretError.osStatus(updateStatus)
            }
        }

        let addStatus = SecItemAdd(addQuery(data: data) as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainSecretError.osStatus(addStatus)
        }
    }

    public func deleteOpenAIAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }

        throw KeychainSecretError.osStatus(status)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func readQuery() -> [String: Any] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private func addQuery(data: Data) -> [String: Any] {
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return query
    }

    private func runSecurityCommand(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()
        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            throw KeychainSecretError.commandTimedOut
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
            return output
        }

        return Data()
    }
}
