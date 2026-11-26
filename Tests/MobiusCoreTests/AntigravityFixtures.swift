import Foundation
@testable import MobiusCore

/// `security` CLI 를 메모리에서 흉내 내는 실행기. `find-generic-password -w/-g` 와
/// `security -i` 의 `add-generic-password -U -s … -a … -w …` 만 해석한다.
/// 속성 조회(`attributeReader`)도 같은 저장소를 본다 — mdat 은 실측처럼 1초 해상도다.
final class FakeSecurity: SecurityCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var mdat: [String: Date] = [:]
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var calls: [[String]] = []
    private(set) var writes = 0
    private(set) var valueReads = 0
    private(set) var attributeReads = 0
    /// 다음 값 읽기/쓰기에 이 결과를 그대로 돌려준다(1회 소모).
    var nextReadResult: SecurityCLIResult?
    var nextWriteResult: SecurityCLIResult?
    /// 쓰기를 실패로 돌려주되 항목은 바꾼다(시간 초과 뒤 실제로는 쓰인 경우).
    var writeAppliesEvenWhenFailing = false

    private func key(_ s: String, _ a: String) -> String { s + "\u{0}" + a }

    func set(_ data: Data?, service: String = AntigravitySecret.keychainService,
             account: String = AntigravitySecret.keychainAccount) {
        lock.withLock {
            items[key(service, account)] = data
            mdat[key(service, account)] = data == nil ? nil
                : Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        }
    }

    func value(service: String = AntigravitySecret.keychainService,
               account: String = AntigravitySecret.keychainAccount) -> Data? {
        lock.withLock { items[key(service, account)] }
    }

    /// 값 읽기가 값을 얻은 **뒤, 돌려주기 전에** 한 번 부른다(읽는 사이에 다른 일이 끝나는 경합 재현).
    /// 부르기 전에 비운다(1회 소모).
    var afterValueReadOnce: (() -> Void)?

    func run(_ arguments: [String], stdin: Data?, timeout: TimeInterval) -> SecurityCLIResult {
        lock.lock()
        calls.append(arguments)
        if arguments.first == "find-generic-password" {
            valueReads += 1
            if let r = nextReadResult { nextReadResult = nil; lock.unlock(); return r }
            let s = arguments[arguments.firstIndex(of: "-s")! + 1]
            let a = arguments[arguments.firstIndex(of: "-a")! + 1]
            let v = items[key(s, a)]
            let hook = afterValueReadOnce
            afterValueReadOnce = nil
            lock.unlock()
            hook?()
            guard let v else { return .exited(status: 44, stdout: Data(), stderr: Data()) }
            return .exited(status: 0, stdout: v + Data("\n".utf8), stderr: Data())
        }
        if arguments == ["-i"], let stdin {
            writes += 1
            let forced = nextWriteResult
            nextWriteResult = nil
            let apply = forced == nil || writeAppliesEvenWhenFailing
            if apply, let (s, a, v) = Self.parseInteractive(String(decoding: stdin, as: UTF8.self)) {
                items[key(s, a)] = Data(v.utf8)
                mdat[key(s, a)] = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
            }
            lock.unlock()
            return forced ?? .exited(status: 0, stdout: Data(), stderr: Data())
        }
        lock.unlock()
        return .exited(status: 1, stdout: Data(), stderr: Data())
    }

    lazy var attributeReader: KeychainAttributeReader = { [unowned self] service, account in
        self.lock.withLock {
            self.attributeReads += 1
            let k = self.key(service, account)
            guard self.items[k] != nil else { return .notFound }
            return .found(modified: self.mdat[k])
        }
    }

    static func parseInteractive(_ cmd: String) -> (String, String, String)? {
        let q = #""((?:[^"\\]|\\.)*)""#
        let pattern = "add-generic-password -U -s \(q) -a \(q) -w \(q)"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) else { return nil }
        func group(_ i: Int) -> String {
            String(cmd[Range(m.range(at: i), in: cmd)!])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return (group(1), group(2), group(3))
    }

    func makeIO(timeout: TimeInterval = 5) -> AntigravityConfigIO {
        let kc = CLIKeychain(runner: self, timeout: timeout, attributeReader: attributeReader)
        return AntigravityConfigIO(keychain: kc, clock: { [unowned self] in self.now })
    }
}

/// `delete` 가 `release` 신호를 받을 때까지 멈추는 키체인(구버전 항목 정리가 오래 걸리는 경우).
/// 처음 한 번만 멈춘다.
final class StallingDeleteKeychain: KeychainClient, @unchecked Sendable {
    private let inner = InMemoryKeychain()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stalled = false
    func read(service: String, account: String) throws -> Data? { try inner.read(service: service, account: account) }
    func write(service: String, account: String, data: Data) throws {
        try inner.write(service: service, account: account, data: data)
    }
    func delete(service: String, account: String) throws {
        let first = lock.withLock { () -> Bool in defer { stalled = true }; return !stalled }
        if first { entered.signal(); _ = release.wait(timeout: .now() + 10) }
        try inner.delete(service: service, account: account)
    }
}

/// `stallNextRead` 를 켜면 다음 `read` 가 `release` 신호까지 멈추는 키체인(구버전 항목 조회가 승인창 등으로
/// 오래 걸리는 경우). 읽은 횟수를 센다.
final class StallingReadKeychain: KeychainClient, @unchecked Sendable {
    private let inner = InMemoryKeychain()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _reads = 0
    private var _stall = false
    var reads: Int { lock.withLock { _reads } }
    var stallNextRead: Bool {
        get { lock.withLock { _stall } }
        set { lock.withLock { _stall = newValue } }
    }
    func read(service: String, account: String) throws -> Data? {
        let stall = lock.withLock { () -> Bool in _reads += 1; defer { _stall = false }; return _stall }
        if stall { entered.signal(); _ = release.wait(timeout: .now() + 10) }
        return try inner.read(service: service, account: account)
    }
    func write(service: String, account: String, data: Data) throws {
        try inner.write(service: service, account: account, data: data)
    }
    private var _deletes = 0
    var deletes: Int { lock.withLock { _deletes } }
    func delete(service: String, account: String) throws {
        lock.withLock { _deletes += 1 }
        try inner.delete(service: service, account: account)
    }
}

/// 테스트 클로저 사이에서 주고받는 플래그.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool { lock.withLock { v } }
    func set(_ new: Bool) { lock.withLock { v = new } }
}

enum AgyFixtures {
    static func secret(_ email: String, refresh: String = "rt", access: String = "at",
                       expiry: String = "2026-11-19T23:11:25.245645+09:00") -> Data {
        AntigravitySecret.make(email: email, accessToken: access, refreshToken: refresh, expiry: expiry)
    }

    static func tempEnv() -> MobiusEnvironment {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-agy-\(UUID().uuidString)")
        return MobiusEnvironment(home: tmp, localUser: "tester")
    }

    /// fetchAvailableModels 응답 JSON. 값이 nil 이면 remainingFraction 키를 뺀다(값 모름).
    static func quotaJSON(_ models: [(id: String, fraction: Double?, reset: String?)]) -> Data {
        var dict: [String: Any] = [:]
        for m in models {
            var quota: [String: Any] = [:]
            if let f = m.fraction { quota["remainingFraction"] = f }
            if let r = m.reset { quota["resetTime"] = r }
            dict[m.id] = ["displayName": m.id.uppercased(), "quotaInfo": quota]
        }
        return try! JSONSerialization.data(withJSONObject: ["models": dict, "defaultAgentModelId": "x"])
    }

    static func report(_ models: [(id: String, fraction: Double?, reset: String?)],
                       now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> AntigravityQuotaReport {
        AntigravityQuotaReport.parse(quotaJSON(models), now: now)!
    }
}
