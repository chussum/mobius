import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case injectedFailure // 테스트용
}

public protocol KeychainClient: AnyObject, Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, data: Data) throws
    func delete(service: String, account: String) throws
}

public final class SystemKeychain: KeychainClient, @unchecked Sendable {
    public init() {}

    private func baseQuery(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return data
    }

    public func write(service: String, account: String, data: Data) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(service, account) as CFDictionary,
                                   update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(service, account)
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// 테스트용. failNextWrite로 스왑 도중 실패(롤백 경로)를 재현한다.
public final class InMemoryKeychain: KeychainClient, @unchecked Sendable {
    private var store: [String: Data] = [:]
    private let lock = NSLock()
    public var failNextWrite = false

    public init() {}
    private func key(_ s: String, _ a: String) -> String { s + "\u{0}" + a }

    public func read(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return store[key(service, account)]
    }

    public func write(service: String, account: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failNextWrite { failNextWrite = false; throw KeychainError.injectedFailure }
        store[key(service, account)] = data
    }

    public func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        store[key(service, account)] = nil
    }
}
