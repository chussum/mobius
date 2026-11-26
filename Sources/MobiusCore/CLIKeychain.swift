import Foundation
import Security

/// `security` 실행 결과.
public enum SecurityCLIResult: Equatable, Sendable {
    case exited(status: Int32, stdout: Data, stderr: Data)
    case timedOut
    case launchFailed
}

/// `security` 실행기(주입식). 테스트는 실패·시간 초과를 흉내 내는 실행기를 넣는다.
public protocol SecurityCLIRunning: Sendable {
    func run(_ arguments: [String], stdin: Data?, timeout: TimeInterval) -> SecurityCLIResult
}

/// 실제 프로세스로 `security` 를 실행한다. **제한 시간이 지나면 프로세스를 끝내고 timedOut** 을
/// 돌려준다 — 기존 `SystemKeychain` CLI 경로는 종료를 무한정 기다려서, 승인창 대기에 걸리면
/// 첫 어댑터인 agy 가 Claude·Codex 대사와 CLI 출력까지 멈춘다(설계 4.1).
public struct ProcessSecurityRunner: SecurityCLIRunning {
    public let executable: URL
    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/security")) {
        self.executable = executable
    }

    public func run(_ arguments: [String], stdin: Data?, timeout: TimeInterval) -> SecurityCLIResult {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        p.standardInput = inPipe ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return .launchFailed }
        // 출력은 별도 큐에서 끝까지 읽는다 — 파이프 버퍼가 차서 프로세스가 끝나지 못하는 일을 막는다.
        let readers = DispatchGroup()
        let box = OutputBox()
        DispatchQueue.global(qos: .utility).async(group: readers) {
            box.setOut(out.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            box.setErr(err.fileHandleForReading.readDataToEndOfFile())
        }
        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
            _ = readers.wait(timeout: .now() + 0.5)
            return .timedOut
        }
        _ = readers.wait(timeout: .now() + 2)
        return .exited(status: p.terminationStatus, stdout: box.out, stderr: box.err)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var o = Data(), e = Data()
        var out: Data { lock.withLock { o } }
        var err: Data { lock.withLock { e } }
        func setOut(_ d: Data) { lock.withLock { o = d } }
        func setErr(_ d: Data) { lock.withLock { e = d } }
    }
}

public enum CLIKeychainError: Error, Equatable {
    /// 제한 시간 초과. 쓰기였다면 **결과를 모른다**(항목이 바뀌었을 수도 있다).
    case timedOut
    case failed(status: Int32)
    case launchFailed
    /// `security -i` 한 줄 제한(4,096바이트)을 넘거나 개행·비UTF-8 이 섞여 보내지 않았다.
    case valueNotSendable
    /// 이 클라이언트는 삭제하지 않는다(로그아웃을 흉내 내지 않는다 — 설계 4.1).
    case unsupported
}

/// 키체인 항목 속성 조회 결과 (값은 요청하지 않는다).
public enum KeychainAttributeResult: Equatable, Sendable {
    case found(modified: Date?)
    case notFound
    /// 키체인 잠김(`errSecInteractionNotAllowed`) 등 — 호출자는 "변화 없음"으로 다룬다(설계 4.2).
    case unavailable
}

/// 속성 조회기(주입식). 기본값은 SecItemCopyMatching(kSecReturnAttributes, 인증 UI 금지).
public typealias KeychainAttributeReader = @Sendable (_ service: String, _ account: String) -> KeychainAttributeResult

/// **값 읽기·쓰기를 `security` CLI 로만** 하는 키체인 클라이언트(agy 전용, 설계 4.1).
///
/// `SystemKeychain` 과 달리 CLI 가 실패해도 네이티브 API(`SecItemUpdate`/`SecItemAdd`/
/// `SecItemCopyMatching` 값 읽기)로 **떨어지지 않는다**:
/// - 네이티브 쓰기는 항목 파티션을 Mobius 의 cdhash 로 재도장해, agy 의 `security` 읽기가
///   암호창을 띄우게 만든다(실패 기록 12).
/// - 네이티브 값 읽기는 제한 시간 없이 암호형 승인창을 기다린다.
/// 모든 호출에 제한 시간(기본 5초)을 둔다. 속성 조회만 네이티브다(값을 요청하지 않으므로
/// 파티션·승인창과 무관하고, 인증 UI 를 금지해 멈추지 않는다).
public final class CLIKeychain: KeychainClient, @unchecked Sendable {
    let runner: SecurityCLIRunning
    let timeout: TimeInterval
    let attributeReader: KeychainAttributeReader

    public init(runner: SecurityCLIRunning = ProcessSecurityRunner(), timeout: TimeInterval = 5,
                attributeReader: @escaping KeychainAttributeReader = CLIKeychain.nativeAttributes) {
        self.runner = runner
        self.timeout = timeout
        self.attributeReader = attributeReader
    }

    /// 값 읽기. 항목이 없으면 nil. 실패·시간 초과는 throw.
    public func read(service: String, account: String) throws -> Data? {
        switch runner.run(["find-generic-password", "-s", service, "-a", account, "-w"],
                          stdin: nil, timeout: timeout) {
        case .timedOut: throw CLIKeychainError.timedOut
        case .launchFailed: throw CLIKeychainError.launchFailed
        case let .exited(status, stdout, _):
            if status == 44 { return nil } // errSecItemNotFound
            guard status == 0 else { throw CLIKeychainError.failed(status: status) }
            var data = stdout
            if data.last == UInt8(ascii: "\n") { data.removeLast() }
            // `-w` 의 16진수 변환 함정(값에 비출력 바이트가 있을 때) — agy 값(base64)은 해당하지
            // 않지만 기존 판별 경로를 그대로 따른다(설계 4.1).
            guard SystemKeychain.isHexShaped(data) else { return data }
            if case let .exited(0, _, dump) = runner.run(
                ["find-generic-password", "-s", service, "-a", account, "-g"],
                stdin: nil, timeout: timeout),
               let decoded = SystemKeychain.binaryPasswordFromSecurityDump(
                   String(decoding: dump, as: UTF8.self)) {
                return decoded
            }
            return data
        }
    }

    /// 값 쓰기. `security -i` 의 표준 입력으로만 보낸다(비밀이 argv 에 남지 않는다).
    /// 한 줄 제한을 넘는 값은 **보내지 않고** throw 한다 — `-i` 는 넘는 명령을 잘라서 쓰고 exit 1 을
    /// 낸다(실측, `SystemKeychain.interactiveCommandLimit`). argv 경로나 네이티브로 떨어지지 않는다.
    public func write(service: String, account: String, data: Data) throws {
        guard let text = String(data: data, encoding: .utf8),
              SystemKeychain.fitsInteractiveCommand(service: service, account: account, value: text)
        else { throw CLIKeychainError.valueNotSendable }
        let cmd = SystemKeychain.interactiveWriteCommand(service: service, account: account, value: text)
        switch runner.run(["-i"], stdin: Data(cmd.utf8), timeout: timeout) {
        case .timedOut: throw CLIKeychainError.timedOut
        case .launchFailed: throw CLIKeychainError.launchFailed
        case let .exited(status, _, _):
            guard status == 0 else { throw CLIKeychainError.failed(status: status) }
        }
    }

    public func delete(service: String, account: String) throws {
        throw CLIKeychainError.unsupported
    }

    public func attributes(service: String, account: String) -> KeychainAttributeResult {
        attributeReader(service, account)
    }

    /// SecItemCopyMatching 으로 속성만 조회한다. 값을 요청하지 않고 인증 UI 를 금지한다.
    public static let nativeAttributes: KeychainAttributeReader = { service, account in
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            let attrs = out as? [String: Any]
            return .found(modified: attrs?[kSecAttrModificationDate as String] as? Date)
        case errSecItemNotFound: return .notFound
        default: return .unavailable
        }
    }
}
