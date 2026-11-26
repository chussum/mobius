import Foundation

public enum AntigravityConfigError: Error, Equatable {
    /// 저장된 값이 실측 형태가 아니다 — 라이브에 쓰기 전에 거부한다.
    case unrecognizedSecret
    /// 라이브 값의 형식(접두사·최상위 키)이 설치할 값과 다르다 — agy 업데이트로 형식이 바뀌었을 수
    /// 있으므로 전환을 멈춘다(설계 5절).
    case liveFormatChanged
    /// 이전 쓰기가 시간을 넘겨 라이브 상태를 모른다. 값을 읽어 확인할 때까지 쓰지 않는다(설계 4.1).
    case liveStateUnknown
    /// 값이 바뀐 것을 봤지만 읽기에 실패해 재시도를 기다리는 중이다(설계 4.2-3).
    case valueReadBackingOff
    /// 쓰기 직전에 읽은 라이브 값이 기대한 값이 아니다(그사이 agy 로그인 등). 쓰지 않았다.
    case liveChangedBeforeWrite
}

/// Antigravity CLI(`agy`) 자격증명 어댑터. 자격증명은 로그인 키체인 generic password
/// (서비스 `gemini`, 계정 `antigravity`) 하나뿐이고, 값 안에 계정 이메일이 들어 있다.
///
/// - secret data = 키체인 값 문자열 바이트 그대로(`go-keyring-base64:…`). Codex 가 auth.json
///   원본을 통째로 저장하는 것과 같은 원칙이다(설계 4.1).
/// - 값 읽기·쓰기는 `CLIKeychain`(security CLI 전용, 5초 제한)만 쓴다.
/// - `liveEmail()` 은 틱마다 불리므로 **속성(mdat)만** 보고, 바뀌었을 때만 값을 읽는다(설계 4.2).
public final class AntigravityConfigIO: ProviderConfigIO, LiveFingerprintReporting,
                                        LiveValueChangeReporting, GuardedLiveWriting,
                                        @unchecked Sendable {
    let keychain: CLIKeychain
    let service: String
    let account: String
    let clock: @Sendable () -> Date

    /// 값 읽기 실패 뒤 같은 mdat 을 다시 시도하기까지의 간격(설계 4.2-3).
    public static let failedReadRetry: TimeInterval = 5 * 60
    /// "모름" 상태의 확인 읽기 간격: 1분 뒤 처음, 실패하면 5분, 15분(설계 4.1).
    public static let unknownCheckSchedule: [TimeInterval] = [60, 5 * 60, 15 * 60]

    private let lock = NSLock()
    // 4.2 변화 감지 캐시 — "값을 다시 읽을지"를 정하는 데만 쓴다(신원 대조에는 쓰지 않는다).
    private var hasCache = false
    private var cachedMdat: Date?
    private var cachedEmail: String?
    private var failedMdat: Date?
    private var failedRetryAt: Date = .distantPast
    // 라이브 지문(마지막으로 읽은 값의 SHA-256, 로그아웃이면 nil)
    private var fingerprint: Data?
    private var changedValue: Data?
    // "모름" 상태(시간을 넘긴 쓰기 뒤)
    private var unknown = false
    private var unknownAttempts = 0
    private var unknownNextCheck: Date = .distantPast
    /// 쓰기 실패 횟수 — 읽기가 시작된 뒤 쓰기가 실패했는지 가려내는 데 쓴다.
    private var writeFailures = 0

    public init(keychain: CLIKeychain = CLIKeychain(),
                service: String = AntigravitySecret.keychainService,
                account: String = AntigravitySecret.keychainAccount,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.keychain = keychain
        self.service = service
        self.account = account
        self.clock = clock
    }

    public var provider: Provider { .antigravity }
    public var identityIsInSecret: Bool { true }
    public var rollsBackFailedSwitch: Bool { false }

    /// 라이브 상태를 모르는가(시간을 넘긴 쓰기 뒤 확인 전). 카드에 "계정 상태 확인 중"을 보이고,
    /// 그동안 agy 항목에 다른 쓰기와 자동 전환을 하지 않는다.
    public var isLiveStateUnknown: Bool { lock.withLock { unknown } }

    public var liveFingerprint: Data? { lock.withLock { fingerprint } }

    public func takeChangedLiveValue() -> Data? {
        lock.withLock { defer { changedValue = nil }; return changedValue }
    }

    public func email(fromSecret data: Data) -> String? { AntigravitySecret.parse(data)?.email }
    public func recognizesSecret(_ data: Data) -> Bool { AntigravitySecret.recognizes(data) }

    // MARK: 값 읽기 (모든 경로가 이 함수 하나 — 설계 4.1 마지막 항목)

    /// 라이브 값 바이트(형태 검증 전). 항목이 없으면 nil. 읽기 실패·시간 초과는 throw.
    /// 성공하면 지문을 갱신하고 "모름" 상태를 푼다.
    ///
    /// "모름" 상태의 확인 일정(1분→5분→15분)은 **이 함수에서** 지킨다 — 변화 감지(`liveEmail`)뿐
    /// 아니라 수동 전환의 되저장, 팝오버·자동 전환의 작업 시작 확인도 모두 이 함수를 지나므로,
    /// 예정 시각 전에는 읽지 않고 `liveStateUnknown` 을 던진다(리뷰 1회차 Codex P2-4).
    public func readLiveSecretData() throws -> Data? {
        let now = clock()
        let (checkingUnknown, epoch): (Bool, Int) = try lock.withLock {
            guard unknown else { return (false, writeFailures) }
            guard now >= unknownNextCheck else { throw AntigravityConfigError.liveStateUnknown }
            return (true, writeFailures)
        }
        let value: Data?
        do {
            value = try keychain.read(service: service, account: account)
        } catch {
            guard checkingUnknown else { throw error }
            lock.withLock {
                // 읽는 사이에 다른 확인 읽기가 "모름"을 풀었거나 새 쓰기가 실패했으면, 이 실패는 지금의
                // 일정과 무관하다 — 새 실패의 일정(1분 뒤 첫 확인)을 덮지 않는다(리뷰 3회차 Codex P2-2).
                guard unknown, writeFailures == epoch else { return }
                unknownAttempts += 1
                let schedule = Self.unknownCheckSchedule
                unknownNextCheck = now.addingTimeInterval(schedule[min(unknownAttempts, schedule.count - 1)])
            }
            throw AntigravityConfigError.liveStateUnknown
        }
        // 읽는 사이에 쓰기가 실패해 "모름"이 새로 켜졌으면, 이 값은 그 쓰기 **전의** 값일 수 있다 —
        // 지문을 바꾸거나 "모름"을 풀지 않는다(리뷰 2회차 Codex P2-1). 확인 일정도 건드리지 않는다
        // (새 실패의 일정이 기준이다 — 리뷰 3회차 Codex P2-2).
        let fresh = lock.withLock { () -> Bool in
            guard writeFailures == epoch else { return false }
            noteReadLocked(value)
            return true
        }
        guard fresh else { throw AntigravityConfigError.liveStateUnknown }
        return value
    }

    private func noteReadLocked(_ value: Data?) {
        let fp = value.map(AntigravitySecret.fingerprint)
        if fp != fingerprint, let value { changedValue = value }
        fingerprint = fp
        unknown = false
        unknownAttempts = 0
    }

    // MARK: 변화 감지 (설계 4.2)

    public func liveEmail() throws -> String? {
        let now = clock()
        // "모름" 상태: mdat 과 상관없이 값을 읽어 확인한다. 간격을 늘려 승인창을 쌓지 않는다.
        if isLiveStateUnknown {
            // 예정 시각 전이면 읽지 않고, 읽기에 실패하면 다음 간격으로 미룬다(readLiveSecretData).
            let value = try readLiveSecretData()   // 성공하면 unknown 해제
            return updateCache(value: value, mdat: attributeMdat())
        }

        switch keychain.attributes(service: service, account: account) {
        case .unavailable:
            // 키체인 잠김 등 — "변화 없음"으로 본다(값 읽기를 시도하지 않는다).
            return lock.withLock { hasCache ? cachedEmail : nil }
        case .notFound:
            lock.withLock {
                hasCache = true; cachedMdat = nil; cachedEmail = nil
                failedMdat = nil
                fingerprint = nil
            }
            return nil
        case .found(let mdat):
            let cached: (hit: Bool, email: String?, backingOff: Bool) = lock.withLock {
                if hasCache, cachedMdat == mdat { return (true, cachedEmail, false) }
                if let failedMdat, failedMdat == mdat, now < failedRetryAt { return (false, nil, true) }
                return (false, nil, false)
            }
            if cached.hit { return cached.email }
            if cached.backingOff { throw AntigravityConfigError.valueReadBackingOff }
            do {
                let value = try readLiveSecretData()
                return updateCache(value: value, mdat: mdat)
            } catch {
                lock.withLock {
                    failedMdat = mdat
                    failedRetryAt = now.addingTimeInterval(Self.failedReadRetry)
                }
                throw error
            }
        }
    }

    private func attributeMdat() -> Date? {
        if case .found(let m) = keychain.attributes(service: service, account: account) { return m }
        return nil
    }

    /// 읽은 값으로 캐시를 갱신하고 이메일을 돌려준다. 형태 검증에 실패한 값은 "없는 것"(nil)이다 —
    /// 따로 읽은 이메일로 대신하지 않는다(설계 4.1).
    private func updateCache(value: Data?, mdat: Date?) -> String? {
        let email = value.flatMap { AntigravitySecret.parse($0)?.email }
        lock.withLock {
            hasCache = true
            cachedMdat = value == nil ? nil : mdat
            cachedEmail = email
            failedMdat = nil
        }
        return email
    }

    public func liveIdentity() throws -> ProviderIdentity? {
        guard let value = try readLiveSecretData(),
              let cred = AntigravitySecret.parse(value) else { return nil }
        return ProviderIdentity(emailAddress: cred.email, organizationName: "", tierDescription: "")
    }

    public func readStableLiveSecretData(gap: Duration) async -> (data: Data, email: String)? {
        guard let d1 = try? readLiveSecretData() else { return nil }
        try? await Task.sleep(for: gap)
        guard let d2 = try? readLiveSecretData(), d1 == d2,
              let email = AntigravitySecret.parse(d2)?.email else { return nil }
        return (d2, email)
    }

    // MARK: 쓰기 (설계 4.1 · 4.5)

    /// 저장된 값을 라이브 키체인 항목에 쓴다. **되돌리지 않는다**(설계 4.5).
    /// - 형태 검증을 통과한 값만 쓴다.
    /// - 라이브 값이 있으면 형식(접두사·최상위 키)이 같은지 먼저 본다.
    /// - 시간 초과든 다른 실패든 쓰기가 실패하면 항목이 바뀌지 않았다고 가정하지 않고 "모름"으로
    ///   둔다 — 값을 읽어 확인할 때까지 다른 쓰기와 자동 전환을 하지 않는다.
    public func writeLiveSecretData(_ data: Data) throws {
        try write(data, requiringLiveFingerprint: nil)
    }

    /// 쓰기 직전에 읽은 라이브 값의 지문이 `expected` 와 같을 때만 쓴다. 자동 전환은 기대 상태를
    /// 확인한 뒤에도 이 읽기와 쓰기 사이의 값을 그 기대값으로 다시 검증한다 — 형식만 보면 그사이 끝난
    /// 새 agy 로그인을 덮는다(리뷰 1회차 Codex P1-3). 다르면 `liveChangedBeforeWrite`.
    public func writeLiveSecretData(_ data: Data, ifLiveFingerprint expected: Data?) throws {
        try write(data, requiringLiveFingerprint: .some(expected))
    }

    public func writeLiveSecretData(_ data: Data, ifLiveFingerprint expected: Data?,
                                    stillValid: () -> Bool) throws {
        try write(data, requiringLiveFingerprint: .some(expected), stillValid: stillValid)
    }

    private func write(_ data: Data, requiringLiveFingerprint expected: Data??,
                       stillValid: () -> Bool = { true }) throws {
        guard !isLiveStateUnknown else { throw AntigravityConfigError.liveStateUnknown }
        guard recognizesSecret(data) else { throw AntigravityConfigError.unrecognizedSecret }
        let live = try readLiveSecretData()
        if case .some(let want) = expected, live.map(AntigravitySecret.fingerprint) != want {
            throw AntigravityConfigError.liveChangedBeforeWrite
        }
        // 마지막 읽기 뒤, 실제 쓰기 바로 앞에서 다시 본다(설정·활성 리비전·대상 등록).
        guard stillValid() else { throw AntigravityConfigError.liveChangedBeforeWrite }
        guard !isLiveStateUnknown else { throw AntigravityConfigError.liveStateUnknown }
        if let live, !AntigravitySecret.sameShape(live, data) {
            throw AntigravityConfigError.liveFormatChanged
        }
        do {
            try keychain.write(service: service, account: account, data: data)
        } catch CLIKeychainError.valueNotSendable {
            throw CLIKeychainError.valueNotSendable   // 보내지 않았다 — 항목은 그대로다
        } catch {
            let now = clock()
            lock.withLock {
                writeFailures += 1
                unknown = true
                unknownAttempts = 0
                unknownNextCheck = now.addingTimeInterval(Self.unknownCheckSchedule[0])
                hasCache = false
            }
            throw error
        }
        // Mobius 자신이 쓴 뒤에는 캐시를 비운다(다음 liveEmail 이 값을 읽는다). 지문은 방금 쓴
        // 값으로 맞춘다 — 자기 쓰기를 "외부 변경"으로 다시 세지 않게.
        lock.withLock {
            hasCache = false
            fingerprint = AntigravitySecret.fingerprint(data)
            changedValue = nil
        }
    }
}
