import Foundation
import Security

/// Minimal Keychain wrapper for the OpenAI API key.
enum KeychainStore {
    private static let service = "dev.local.transcriber"
    private static let account = "openai-api-key"
    private static let accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    struct Client: Sendable {
        var add: @Sendable ([String: Any]) -> OSStatus
        var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
        var copyMatching: @Sendable ([String: Any], UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var delete: @Sendable ([String: Any]) -> OSStatus

        static let live = Client(
            add: { SecItemAdd($0 as CFDictionary, nil) },
            update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
            copyMatching: { SecItemCopyMatching($0 as CFDictionary, $1) },
            delete: { SecItemDelete($0 as CFDictionary) }
        )
    }

    enum StoreError: LocalizedError, Equatable {
        case emptyKey
        case invalidStoredData
        case addFailed(OSStatus)
        case updateFailed(OSStatus)
        case readFailed(OSStatus)
        case deleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .emptyKey:
                "Enter an OpenAI API key before saving."
            case .invalidStoredData:
                "The saved OpenAI API key could not be read from Keychain."
            case .addFailed(let status):
                "Couldn't save the OpenAI API key to Keychain (OSStatus \(status))."
            case .updateFailed(let status):
                "Couldn't update the OpenAI API key in Keychain (OSStatus \(status))."
            case .readFailed(let status):
                "Couldn't read the OpenAI API key from Keychain (OSStatus \(status))."
            case .deleteFailed(let status):
                "Couldn't remove the OpenAI API key from Keychain (OSStatus \(status))."
            }
        }
    }

    static func saveAPIKey(_ key: String, client: Client = .live) throws {
        try saveAPIKey(key, service: service, account: account, client: client)
    }

    static func saveAPIKey(
        _ key: String,
        service: String,
        account: String,
        client: Client = .live
    ) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyKey }

        let lookup = lookupQuery(service: service, account: account)
        let update = updateAttributes(for: trimmed)
        let updateStatus = client.update(lookup, update)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw StoreError.updateFailed(updateStatus)
        }

        let addStatus = client.add(addQuery(for: trimmed, service: service, account: account))
        if addStatus == errSecDuplicateItem {
            let retryStatus = client.update(lookup, update)
            guard retryStatus == errSecSuccess else {
                throw StoreError.updateFailed(retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw StoreError.addFailed(addStatus)
        }
    }

    static func loadAPIKey() -> String? {
        try? readAPIKey()
    }

    static func readAPIKey(client: Client = .live) throws -> String? {
        try readAPIKey(service: service, account: account, client: client)
    }

    static func readAPIKey(
        service: String,
        account: String,
        client: Client = .live
    ) throws -> String? {
        let query = readQuery(service: service, account: account)
        var item: CFTypeRef?
        let status = client.copyMatching(query, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8),
                  !key.isEmpty
            else { throw StoreError.invalidStoredData }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.readFailed(status)
        }
    }

    static func deleteAPIKey(client: Client = .live) throws {
        try deleteAPIKey(service: service, account: account, client: client)
    }

    static func deleteAPIKey(
        service: String,
        account: String,
        client: Client = .live
    ) throws {
        let status = client.delete(lookupQuery(service: service, account: account))
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw StoreError.deleteFailed(status)
        }
    }

    static var hasAPIKey: Bool { loadAPIKey() != nil }

    static func lookupQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func addQuery(for key: String, service: String, account: String) -> [String: Any] {
        var query = lookupQuery(service: service, account: account)
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = accessible
        return query
    }

    static func updateAttributes(for key: String) -> [String: Any] {
        [
            kSecValueData as String: Data(key.utf8)
        ]
    }

    static func readQuery(service: String, account: String) -> [String: Any] {
        var query = lookupQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}
