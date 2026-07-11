import Foundation
import Security

public enum SecureValueStoreError: Error, Equatable, LocalizedError, Sendable {
    case notFound
    case keychainFailure(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "A required secure value was not found."
        case .keychainFailure:
            return "The secure value store could not complete the request."
        }
    }
}

public protocol SecureValueStore: Sendable {
    func set(_ value: String, for reference: UUID) throws
    func value(for reference: UUID) throws -> String
    func deleteValue(for reference: UUID) throws
}

public final class KeychainStore: SecureValueStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.davidhermansson.MenubarNumbers") {
        self.service = service
    }

    public func set(_ value: String, for reference: UUID) throws {
        let account = reference.uuidString
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw error(for: addStatus) }
            return
        }

        guard updateStatus == errSecSuccess else { throw error(for: updateStatus) }
    }

    public func value(for reference: UUID) throws -> String {
        var query = baseQuery(account: reference.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw error(for: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecureValueStoreError.keychainFailure(status: errSecDecode)
        }
        return value
    }

    public func deleteValue(for reference: UUID) throws {
        let status = SecItemDelete(baseQuery(account: reference.uuidString) as CFDictionary)
        guard status == errSecSuccess else { throw error(for: status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func error(for status: OSStatus) -> SecureValueStoreError {
        status == errSecItemNotFound ? .notFound : .keychainFailure(status: status)
    }
}

/// Thread-safe fake suitable for previews and unit tests; it never uses Keychain.
public final class InMemorySecureValueStore: SecureValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]

    public init() {}

    public func set(_ value: String, for reference: UUID) throws {
        lock.withLock { values[reference] = value }
    }

    public func value(for reference: UUID) throws -> String {
        try lock.withLock {
            guard let value = values[reference] else { throw SecureValueStoreError.notFound }
            return value
        }
    }

    public func deleteValue(for reference: UUID) throws {
        try lock.withLock {
            guard values.removeValue(forKey: reference) != nil else { throw SecureValueStoreError.notFound }
        }
    }
}
