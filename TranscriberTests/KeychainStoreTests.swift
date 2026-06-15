import Foundation
import Security
import Testing
@testable import Transcriber

struct KeychainStoreTests {
    @Test func saveUpdatesExistingKeyWithoutDeleting() throws {
        let spy = KeychainSpy(updateStatus: errSecSuccess)

        try KeychainStore.saveAPIKey(
            " first-value \n",
            service: "test-service",
            account: "test-account",
            client: spy.client()
        )

        #expect(spy.updateCalls.count == 1)
        #expect(spy.addCalls.isEmpty)
        #expect(spy.deleteCalls.isEmpty)
        let data = try #require(spy.updateCalls.first?.attributes[kSecValueData as String] as? Data)
        #expect(String(data: data, encoding: .utf8) == "first-value")
        #expect(spy.updateCalls.first?.attributes[kSecAttrAccessible as String] == nil)
    }

    @Test func saveAddsNewKeyWithDeviceLocalUnlockedAccessibility() throws {
        let spy = KeychainSpy(updateStatus: errSecItemNotFound, addStatus: errSecSuccess)

        try KeychainStore.saveAPIKey(
            "new-value",
            service: "test-service",
            account: "test-account",
            client: spy.client()
        )

        #expect(spy.updateCalls.count == 1)
        #expect(spy.addCalls.count == 1)
        #expect(spy.deleteCalls.isEmpty)
        let addQuery = try #require(spy.addCalls.first)
        let data = try #require(addQuery[kSecValueData as String] as? Data)
        #expect(String(data: data, encoding: .utf8) == "new-value")
        let accessibility = try #require(addQuery[kSecAttrAccessible as String] as? String)
        #expect(accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func blankSaveThrowsWithoutTouchingKeychain() {
        let spy = KeychainSpy()

        expectError(KeychainStore.StoreError.emptyKey) {
            try KeychainStore.saveAPIKey(
                " \n\t",
                service: "test-service",
                account: "test-account",
                client: spy.client()
            )
        }

        #expect(spy.updateCalls.isEmpty)
        #expect(spy.addCalls.isEmpty)
        #expect(spy.deleteCalls.isEmpty)
    }

    @Test func readReturnsStoredKeyAndSurfacesKeychainErrors() throws {
        let spy = KeychainSpy(
            copyStatus: errSecSuccess,
            copiedData: Data("stored-value".utf8)
        )

        let key = try KeychainStore.readAPIKey(
            service: "test-service",
            account: "test-account",
            client: spy.client()
        )

        #expect(key == "stored-value")

        let failingSpy = KeychainSpy(copyStatus: errSecInteractionNotAllowed)
        expectError(KeychainStore.StoreError.readFailed(errSecInteractionNotAllowed)) {
            _ = try KeychainStore.readAPIKey(
                service: "test-service",
                account: "test-account",
                client: failingSpy.client()
            )
        }
    }

    @Test func deleteTreatsMissingAsSuccessAndSurfacesFailures() throws {
        let missingSpy = KeychainSpy(deleteStatus: errSecItemNotFound)
        try KeychainStore.deleteAPIKey(
            service: "test-service",
            account: "test-account",
            client: missingSpy.client()
        )
        #expect(missingSpy.deleteCalls.count == 1)

        let failingSpy = KeychainSpy(deleteStatus: errSecInteractionNotAllowed)
        expectError(KeychainStore.StoreError.deleteFailed(errSecInteractionNotAllowed)) {
            try KeychainStore.deleteAPIKey(
                service: "test-service",
                account: "test-account",
                client: failingSpy.client()
            )
        }
    }

    private func expectError(
        _ expected: KeychainStore.StoreError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected \(expected), but operation succeeded.")
        } catch let error as KeychainStore.StoreError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), but got \(error).")
        }
    }
}

private final class KeychainSpy: @unchecked Sendable {
    struct UpdateCall {
        let query: [String: Any]
        let attributes: [String: Any]
    }

    var addCalls: [[String: Any]] = []
    var updateCalls: [UpdateCall] = []
    var copyCalls: [[String: Any]] = []
    var deleteCalls: [[String: Any]] = []

    private let updateStatus: OSStatus
    private let addStatus: OSStatus
    private let copyStatus: OSStatus
    private let deleteStatus: OSStatus
    private let copiedData: Data?

    init(
        updateStatus: OSStatus = errSecItemNotFound,
        addStatus: OSStatus = errSecSuccess,
        copyStatus: OSStatus = errSecItemNotFound,
        deleteStatus: OSStatus = errSecSuccess,
        copiedData: Data? = nil
    ) {
        self.updateStatus = updateStatus
        self.addStatus = addStatus
        self.copyStatus = copyStatus
        self.deleteStatus = deleteStatus
        self.copiedData = copiedData
    }

    func client() -> KeychainStore.Client {
        KeychainStore.Client(
            add: { query in
                self.addCalls.append(query)
                return self.addStatus
            },
            update: { query, attributes in
                self.updateCalls.append(UpdateCall(query: query, attributes: attributes))
                return self.updateStatus
            },
            copyMatching: { query, item in
                self.copyCalls.append(query)
                if let copiedData = self.copiedData {
                    item?.pointee = copiedData as CFData
                }
                return self.copyStatus
            },
            delete: { query in
                self.deleteCalls.append(query)
                return self.deleteStatus
            }
        )
    }
}
