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
        // ★ 네이티브 읽기도 파티션 리스트(apple-tool:)에 안 맞아 암호창을 띄운다 —
        //   쓰기와 대칭으로 security CLI 경유. 값은 stdout 파이프로만 전달된다.
        //   (Desktop이 띄운 security도 통과하는 것을 실측으로 확인 — 실패 기록 12)
        switch readViaSecurityCLI(service: service, account: account) {
        case .found(let data): return data
        case .notFound: return nil
        case .error: break // CLI 이상 시에만 네이티브 폴백 (드묾 — 암호창 가능성 감수)
        }
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

    private enum CLIReadResult { case found(Data), notFound, error }

    /// `security find-generic-password -w`로 값 읽기. 종료코드 44 = 항목 없음.
    private func readViaSecurityCLI(service: String, account: String) -> CLIReadResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .error }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        switch p.terminationStatus {
        case 0:
            var data = out
            if data.last == UInt8(ascii: "\n") { data.removeLast() } // -w가 붙이는 개행 1개 제거
            return .found(data)
        case 44: return .notFound // errSecItemNotFound
        default: return .error
        }
    }

    /// `security -i`가 한 번에 읽는 명령 한 줄의 상한(바이트, 개행 제외).
    /// ★ 실측 2026-08-10: 4,096 B까지는 정상이지만 **4,097 B부터는 명령이 잘린 채
    ///   그대로 실행되어** 항목에 truncated 값이 기록되고 exit 1이 난다
    ///   (원본 "ORIGINAL-INTACT-VALUE" → 4,096 B 경계에서 잘린 쓰레기 값으로 덮어써짐).
    ///   즉 "실패하면 원본이 남는다"가 아니라 **실패가 곧 손상**이므로,
    ///   보내기 전에 길이를 미리 판정해 아예 시도하지 않는다.
    static let interactiveCommandLimit = 4096

    static func escapeForInteractive(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `security -i`에 보낼 명령 한 줄(개행 포함). 길이 판정과 실제 전송이 같은
    /// 문자열을 쓰도록 순수 함수로 분리한다 — 어긋나면 가드가 무의미해진다.
    static func interactiveWriteCommand(service: String, account: String,
                                        value: String) -> String {
        let s = escapeForInteractive(service)
        let a = escapeForInteractive(account)
        let v = escapeForInteractive(value)
        return "add-generic-password -U -s \"\(s)\" -a \"\(a)\" -w \"\(v)\"\n"
    }

    /// 이 payload를 `security -i`로 안전하게 보낼 수 있는가.
    /// 개행이 섞이면 명령이 두 줄로 쪼개지므로 그것도 여기서 함께 막는다.
    static func fitsInteractiveCommand(service: String, account: String,
                                       value: String) -> Bool {
        if value.contains("\n") { return false }
        let command = interactiveWriteCommand(service: service, account: account,
                                              value: value)
        // 개행 1바이트는 상한 밖이다 (실측: 개행 제외 4,096 B까지 통과).
        return command.utf8.count - 1 <= interactiveCommandLimit
    }

    public func write(service: String, account: String, data: Data) throws {
        // ★ SecItemUpdate/SecItemAdd로 쓰면 macOS가 항목의 파티션 리스트를 이 앱의
        //   cdhash로 도장 찍는다(re-stamp). 그러면 claude CLI와 Desktop 내장 Claude Code가
        //   /usr/bin/security로 이 항목을 읽을 때마다 키체인 암호창이 뜨고, '항상 허용'도
        //   다음 쓰기에서 무효가 된다 (2026-07-11 실측 — CLAUDE.md 실패 기록 12).
        //   → 쓰기를 security CLI(-i, stdin 경유라 비밀이 argv에 안 남음)로 우회하면
        //   파티션이 apple-tool: 로 찍혀 claude 생태계 전체와 호환된다.
        if let text = String(data: data, encoding: .utf8),
           Self.fitsInteractiveCommand(service: service, account: account, value: text),
           writeViaSecurityCLI(service: service, account: account, value: text) {
            return
        }
        // ★ payload가 `security -i` 한 줄 한계를 넘는 계정이 실재한다 — MCP 플러그인
        //   OAuth 등록이 쌓이면 자격증명 blob이 486 B에서 8 KB로 불어난다(실측).
        //   여기서 네이티브로 떨어지면 전환할 때마다 파티션이 깨져 실패 기록 12가
        //   그대로 재현되므로, **같은 security 바이너리를 argv(-X 16진수)로** 호출한다.
        //   도장은 그대로 apple-tool: 로 찍히고, 대가는 값이 잠깐 ps에 보이는 것뿐이다
        //   (claude CLI 자신도 큰 payload엔 같은 형식을 쓴다).
        if writeViaSecurityArgv(service: service, account: account, data: data) {
            return
        }
        // 폴백: security 자체를 못 쓰는 경우에만 네이티브 (파티션 도장은 감수)
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
    /// **호출 전에 반드시 `fitsInteractiveCommand`로 길이를 확인할 것** — 한계를
    /// 넘으면 실패가 아니라 손상이다(잘린 값이 기록된다).
    private func writeViaSecurityCLI(service: String, account: String, value: String) -> Bool {
        let cmd = Self.interactiveWriteCommand(service: service, account: account,
                                               value: value)
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

    /// `security add-generic-password -U … -X <hex>` (argv 경유). `-i` 한 줄 한계를
    /// 넘는 payload 전용 우회로. 16진수라 이스케이프가 필요 없고 개행·비UTF-8
    /// 바이트도 그대로 실을 수 있어, CLI 경로의 제약을 전부 우회한다.
    /// 트레이드오프: 실행되는 짧은 순간 값이 `ps`에 보인다. 그래도 네이티브로
    /// 떨어져 파티션을 깨뜨리는 것보다 낫다 — 파티션이 깨지면 claude CLI와
    /// Desktop이 이후 **모든** 읽기에서 키체인 암호창을 띄운다.
    private func writeViaSecurityArgv(service: String, account: String, data: Data) -> Bool {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["add-generic-password", "-U",
                       "-s", service, "-a", account, "-X", hex]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
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
