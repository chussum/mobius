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
        // ★ SecItemUpdate/SecItemAdd로 쓰면 macOS가 항목의 파티션 리스트를 이 앱의
        //   cdhash로 도장 찍는다(re-stamp). 그러면 claude CLI와 Desktop 내장 Claude Code가
        //   /usr/bin/security로 이 항목을 읽을 때마다 키체인 암호창이 뜨고, '항상 허용'도
        //   다음 쓰기에서 무효가 된다 (2026-07-11 실측 — CLAUDE.md 실패 기록 12).
        //   → 쓰기를 security CLI(-i, stdin 경유라 비밀이 argv에 안 남음)로 우회하면
        //   파티션이 apple-tool: 로 찍혀 claude 생태계 전체와 호환된다.
        if let text = String(data: data, encoding: .utf8), !text.contains("\n"),
           writeViaSecurityCLI(service: service, account: account, value: text) {
            return
        }
        // 폴백: 개행 포함/비UTF-8/CLI 실패 시 네이티브 경로 (파티션 도장은 감수)
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

    /// `security -i`(대화형 stdin)로 add-generic-password -U 실행. 성공 시 true.
    /// 비밀 값은 stdin으로만 전달되어 프로세스 인자(ps)에 노출되지 않는다.
    private func writeViaSecurityCLI(service: String, account: String, value: String) -> Bool {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let cmd = "add-generic-password -U -s \"\(esc(service))\" -a \"\(esc(account))\" -w \"\(esc(value))\"\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        stdin.fileHandleForWriting.write(Data(cmd.utf8))
        stdin.fileHandleForWriting.closeFile()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// 테스트용. failNextWrite/failWritesForService로 스왑 도중 실패(롤백 경로)를 재현한다.
public final class InMemoryKeychain: KeychainClient, @unchecked Sendable {
    private var store: [String: Data] = [:]
    private let lock = NSLock()
    public var failNextWrite = false
    /// 이 service로의 **첫 매칭 write 1회만** 실패시킨다 (매칭 시 소모되어 nil로 초기화).
    /// 1회 소모형이라 같은 service로의 후속 write(예: 롤백)는 통과한다.
    public var failWritesForService: String?

    public init() {}
    private func key(_ s: String, _ a: String) -> String { s + "\u{0}" + a }

    public func read(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return store[key(service, account)]
    }

    public func write(service: String, account: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failNextWrite { failNextWrite = false; throw KeychainError.injectedFailure }
        if failWritesForService == service {
            failWritesForService = nil
            throw KeychainError.injectedFailure
        }
        store[key(service, account)] = data
    }

    public func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        store[key(service, account)] = nil
    }
}
