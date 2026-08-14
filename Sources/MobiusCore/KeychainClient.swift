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
            // 흔한 경로(출력 가능한 JSON blob)는 hex 모양이 아니라 여기서 바로 끝난다 —
            // 아래 확인 호출이 붙지 않으므로 평소 읽기 비용은 그대로다.
            guard Self.isHexShaped(data) else { return .found(data) }
            if let decoded = readBinaryViaSecurityDump(service: service, account: account) {
                return .found(decoded)
            }
            // hex처럼 생긴 진짜 평문이거나 `-g` 실패 — 어느 쪽이든 원문 그대로가 정답.
            return .found(data)
        case 44: return .notFound // errSecItemNotFound
        default: return .error
        }
    }

    // MARK: - `-w` 출력의 hex 인코딩 판별
    //
    // ★ 실측 2026-08-10: `security find-generic-password -w`는 값에 **비출력 바이트가
    //   하나라도 있으면**(개행·탭·0x80 이상 UTF-8 바이트 전부 해당) 원본 바이트가 아니라
    //   **소문자 16진수 문자열**을 출력한다.
    //       {"a":"한"}  →  7b2261223a22ed959c227d
    //   이걸 그대로 반환하면 hex ASCII가 자격증명 blob으로 들어가 프로필에 스냅샷되고,
    //   다음 전환에서 Keychain과 .credentials.json에 되쓰여 **라이브 로그인이 조용히
    //   파괴된다** — 에러는 어디에도 안 뜬다 (CLAUDE.md 실패 기록 1과 같은 클래스).
    //   MCP OAuth 등록의 서버 이름·URL 등에 비ASCII 문자 하나만 섞여도 발동한다.
    //
    // ★ 출력 모양만으로는 판별할 수 없다 — 값이 진짜 ASCII 문자열 "deadbeef"여도 `-w`는
    //   똑같이 `deadbeef`를 준다(실측). 그래서 hex 모양일 때만 `-g`로 되물어 확정한다.
    //   `-g`는 stderr에 이진값이면 `password: 0x7B2261…`, 평문이면 `password: "deadbeef"`로
    //   **0x 접두사 유무가 갈리므로** 이것만이 확실한 신호다(실측).

    /// `-w` 출력이 hex 인코딩일 **수 있는** 모양인가 (짝수 길이 + hex 문자만).
    /// true는 확정이 아니라 "확인이 필요하다"는 뜻이다 — 위 "deadbeef" 참조.
    static func isHexShaped(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count % 2 == 0 else { return false }
        return data.allSatisfy { hexNibble($0) != nil }
    }

    private static func hexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    static func decodeHex(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = hexNibble(chars[i]), let lo = hexNibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        return out
    }

    /// `security … -g`의 stderr에서 **이진** password를 꺼낸다.
    /// 이진: `password: 0x7B2261223A22ED959C227D  "{"a":"\355\225\234"}"`
    /// 평문: `password: "deadbeef"` → 평문이면 nil (원문을 그대로 쓰라는 뜻).
    /// 값이 단일 고바이트면 뒤 인용 부분 없이 `password: 0xFF ` 로만 오므로(실측),
    /// hex 토큰은 첫 비-hex 문자에서 끊는다.
    static func binaryPasswordFromSecurityDump(_ text: String) -> Data? {
        let marker = "password: 0x"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // 접두사로 고정한다 — 평문 값 안에 같은 문자열이 들어 있어도 오독하지 않도록.
            guard line.hasPrefix(marker) else { continue }
            let hex = line.dropFirst(marker.count).prefix { hexNibble(UInt8($0.asciiValue ?? 0)) != nil }
            return decodeHex(String(hex))
        }
        return nil
    }

    /// hex 모양 출력을 만났을 때만 부르는 확인 경로. 흔한 읽기에는 실행되지 않는다.
    private func readBinaryViaSecurityDump(service: String, account: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-g"]
        let stderr = Pipe()
        p.standardOutput = FileHandle.nullDevice // 속성 덤프는 버린다
        p.standardError = stderr                 // -g는 password를 stderr로 낸다
        do { try p.run() } catch { return nil }
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return Self.binaryPasswordFromSecurityDump(String(decoding: err, as: UTF8.self))
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
        //   도장은 그대로 apple-tool: 로 찍히고, 대가는 값이 ps에 보이는 것뿐이다
        //   (claude CLI 자신도 큰 payload엔 같은 형식을 쓴다).
        //   ★ 이 경로는 "한계 초과 전용"이 **아니다** — 위 분기가 어떤 이유로든 실패하면
        //     여기로 온다(비UTF-8, 그리고 평범한 486 B blob에서의 일시적 실패 —
        //     security 강제 종료·키체인 순간 잠김·fork 실패 등). 의도한 설계다:
        //     작은 토큰이 잠깐 argv에 노출되는 것(같은 사용자 세션 한정)보다
        //     파티션이 깨져 **이후 모든 읽기에 암호창이 뜨는 것**이 훨씬 나쁘다.
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

    /// `security add-generic-password -U … -X <hex>` (argv 경유). `-i` 경로가 실패하거나
    /// 한 줄 한계를 넘을 때의 우회로 (호출 조건은 `write()`의 주석 참조).
    /// 16진수라 이스케이프가 필요 없고 개행·비UTF-8 바이트도 **쓰기는** 그대로 나간다.
    /// ★ 단 왕복은 아니다 — 비출력 바이트가 섞인 값은 `-w` 읽기가 hex로 돌아오므로
    ///   `readViaSecurityCLI`의 hex 판별 경로가 짝을 이뤄야 원본이 복원된다.
    /// 트레이드오프: 실행되는 동안 값이 `ps`에 보인다. 노출 범위는 같은 사용자 세션뿐이고
    /// (macOS가 `KERN_PROCARGS2`를 uid 너머로 막는다), 보통은 수 ms로 끝난다.
    /// ★ 다만 항상 짧지는 않다 — 로그인 키체인이 잠겨 있거나 항목 ACL이 승인창을 띄우면
    ///   `security`는 그 창을 기다리는 동안 hex 전체를 argv에 든 채 멈춰 있고,
    ///   `waitUntilExit()`에 상한이 없어 호출 스레드도 함께 막힌다(분 단위 가능).
    ///   그래도 네이티브로 떨어져 파티션을 깨뜨리는 것보다 낫다 — 파티션이 깨지면
    ///   claude CLI와 Desktop이 이후 **모든** 읽기에서 키체인 암호창을 띄운다.
    ///   (중간에 죽이지 않는 이유: 키체인 쓰기를 반쯤 끊는 위험이 대기보다 크고,
    ///   실패로 처리하면 결국 파티션을 깨는 네이티브 경로로 떨어진다.)
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
    /// service별 read 호출 횟수 (테스트 관측용). 실제 Keychain 읽기는 승인창·subprocess
    /// 비용이 있어 "정말 필요할 때만 읽는다"가 규율이므로(실패 기록 3·3b), 그 규율을
    /// 증상이 아니라 **호출 여부로 직접** 단언할 수 있게 계측한다(실패 기록 4b의 교훈).
    public private(set) var readsByService: [String: Int] = [:]

    public init() {}
    private func key(_ s: String, _ a: String) -> String { s + "\u{0}" + a }

    public func read(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        readsByService[service, default: 0] += 1
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
