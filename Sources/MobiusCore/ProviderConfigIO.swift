import Foundation

/// 프로바이더 계정의 표시용 신원. 등록/adopt 시 프로필 메타데이터가 된다.
public struct ProviderIdentity: Equatable, Sendable {
    public var emailAddress: String
    public var organizationName: String
    public var tierDescription: String
    /// 조직 UUID — 같은 이메일의 다른 조직을 구분한다(`AccountKey`). 조직 개념이 없으면 "".
    public var organizationUuid: String

    public init(emailAddress: String, organizationName: String, tierDescription: String,
                organizationUuid: String = "") {
        self.emailAddress = emailAddress
        self.organizationName = organizationName
        self.tierDescription = tierDescription
        self.organizationUuid = organizationUuid
    }

    public var key: AccountKey {
        AccountKey(emailAddress: emailAddress, organizationUuid: organizationUuid)
    }
}

/// 프로바이더별 라이브 자격증명 읽기/쓰기의 공통 계약. Switcher가 이 프로토콜만 보고
/// 전환/되저장/adopt/reconcile을 수행한다.
///
/// secret data는 프로바이더가 정한 직렬화 바이트다 — Claude는 CredentialsSnapshot JSON,
/// Codex는 auth.json 원본 바이트. AccountStore의 계정별 비밀 파일에 그대로 저장되고,
/// writeLiveSecretData가 같은 바이트를 받아 라이브에 반영한다 (해석은 어댑터만 한다).
public protocol ProviderConfigIO: Sendable {
    var provider: Provider { get }

    /// 현재 로그인 스냅샷의 직렬화 바이트. 로그아웃 상태면 nil.
    func readLiveSecretData() throws -> Data?

    /// 계정 식별 이메일. 주기 틱마다 호출되므로 승인창/네트워크 없는 값싼 경로여야 한다.
    func liveEmail() throws -> String?

    /// 계정 열쇠(이메일 + 조직). `liveEmail`과 같은 값싼 경로여야 한다. 조직 개념이 없는
    /// 프로바이더는 기본 구현(이메일만)으로 충분하다. **프로필 대조는 이메일이 아니라 이 값으로**
    /// 한다 — 한 이메일이 여러 조직에 속할 수 있다(실패 기록 23).
    func liveAccountKey() throws -> AccountKey?

    /// 표시용 메타데이터를 포함한 신원 (등록/adopt 시). 로그아웃 상태면 nil.
    func liveIdentity() throws -> ProviderIdentity?

    /// 라이브 신원 쪽의 지문. `liveAccountKey`와 같은 값싼 경로(승인창 없음)여야 한다. reconcile·adopt가 저장을
    /// 거부한 라이브가 그대로인지 볼 때 쓴다(`Switcher`). 로그아웃 상태면 nil.
    func liveIdentityFingerprint() throws -> Data?

    /// 라이브 상태(비밀+이메일)를 간격을 두고 두 번 읽어 값이 일치할 때만 반환한다.
    /// 로그인/전환/토큰 리프레시 도중의 불일치 상태를 배제한다 (mtime 신호는 쓰지 않는다 —
    /// 두 프로바이더 모두 자격증명 파일이 "바쁜 파일"임이 실측됐다).
    func readStableLiveSecretData(gap: Duration) async -> (data: Data, email: String)?

    /// 저장된 secret data를 라이브에 반영한다. 원자적이어야 하며 실패 시 throw.
    func writeLiveSecretData(_ data: Data) throws

    /// 주어진 secret 바이트가 이 프로바이더의 자격증명 형태인가. 구버전 바이너리가
    /// accounts.json을 저장하며 per-account `provider`를 드롭해도(구 구조체엔 필드 없음)
    /// secret 파일은 그대로 남으므로, secret 형태가 진짜 provider의 authority다 —
    /// Switcher.healMisassignedProviders가 소실된 provider를 이걸로 재도출한다.
    func recognizesSecret(_ data: Data) -> Bool

    /// 라이브에서 읽은 secret을 프로필에 저장해도 되는가 — 토큰과 신원이 **같은 로그인**의 것이고,
    /// 로그아웃·재로그인 도중의 빈 상태가 아닌가. false면 되저장·reconcile·adopt가 이번 판정을
    /// 미룬다(다음 틱에 다시 본다). Claude는 토큰(Keychain)과 신원(~/.claude.json)을 따로 읽어
    /// 짝짓기 때문에 필요하다(실패 기록 24). 신원이 토큰 안에 있는 프로바이더는 기본 구현으로 충분하다.
    func canStoreLiveSecret(_ data: Data) -> Bool

    /// 저장할 수 없는 라이브 secret이 **로그인이 없는 상태**(빈 토큰 등)라서 거부된 것인가. reconcile·adopt가
    /// 거부한 라이브를 얼마 동안 다시 읽지 않을지 정할 때 쓴다(`Switcher`). 기본 false.
    func liveSecretLacksLogin(_ data: Data) -> Bool

    /// 저장할 수 없는 라이브 secret(`canStoreLiveSecret`이 false)의 **토큰**이 `stored`(어느 프로필의
    /// 저장본)와 같은 계정의 것으로 보이면, 토큰은 라이브의 것을 쓰고 신원은 `stored`의 것을 쓴 secret을
    /// 돌려준다. 아니면 nil. Claude에서 신원만 옛 조직으로 되돌려진 경우를 보정하는 데 쓴다(실패 기록 24).
    func liveSecret(_ live: Data, reattributedTo stored: Data) -> Data?

    /// 라이브 토큰이 `stored`(어느 프로필의 저장본, 없으면 nil)를 가진 계정의 것**일 수 있는가**.
    /// 보정할 주인이 하나뿐인지 셀 때 쓴다 — 저장본이 빈 토큰이거나 섞여 있거나 조직 종류를 모르면
    /// "모른다"이므로 true다. 모호함은 저장본의 건강 상태가 아니라 주인일 수 있는 프로필 수로 정한다.
    func liveToken(_ live: Data, couldBelongTo stored: Data?) -> Bool

    /// 저장 secret 자체가 서로 다른 계정의 토큰과 신원을 섞어 들고 있는가. 전환은 이런 secret을 라이브에
    /// 설치하지 않는다 — 설치하면 사용자가 고른 카드와 다른 조직으로 로그인된다.
    func secretIsMixed(_ data: Data) -> Bool
    /// secret 바이트 **자체에서** 꺼낸 계정 이메일. 신원이 바이트 안에 있는 프로바이더(Codex·
    /// Antigravity)는 값을 주고, 바이트에 신원이 없는 Claude 는 nil 을 준다(`~/.claude.json` 으로
    /// 대조). Switcher 는 이 값이 있으면 **저장하거나 설치하는 바이트의 이메일**로 프로필을
    /// 고르고 대조한다 — 값과 이메일을 따로 읽는 틈(실패 기록 1·2)을 없앤다(설계 4.1).
    func email(fromSecret data: Data) -> String?

    /// 신원이 secret 바이트 안에 있는가. true 면 바이트에서 이메일을 못 꺼낸 값은 "신원 없음"이고,
    /// 따로 읽은 이메일(`liveEmail`)로 대신하지 않는다.
    var identityIsInSecret: Bool { get }

    /// 라이브 쓰기가 실패했을 때 이전 값으로 되돌리는가. Antigravity 는 되돌리지 않는다 —
    /// `security` CLI 로는 비교와 되돌리기를 원자적으로 묶을 수 없어, 되돌리는 사이에 끝난
    /// 새 agy 로그인을 덮을 수 있다(설계 4.5).
    var rollsBackFailedSwitch: Bool { get }
}

extension ProviderConfigIO {
    /// 기본: 항상 저장 가능 — Codex auth.json은 신원(JWT)이 토큰과 한 파일에 있어 어긋날 수 없다.
    public func canStoreLiveSecret(_ data: Data) -> Bool { true }
    public func liveSecretLacksLogin(_ data: Data) -> Bool { false }

    /// 기본: 보정 없음 — 신원이 토큰과 한 파일에 있는 프로바이더는 어긋날 일이 없다.
    public func liveSecret(_ live: Data, reattributedTo stored: Data) -> Data? { nil }

    /// 기본: 모른다(true) — 보정을 쓰지 않는 프로바이더에서는 불리지 않는다.
    public func liveToken(_ live: Data, couldBelongTo stored: Data?) -> Bool { true }

    /// 기본: 섞일 수 없다.
    public func secretIsMixed(_ data: Data) -> Bool { false }

    public func readStableLiveSecretData() async -> (data: Data, email: String)? {
        await readStableLiveSecretData(gap: .milliseconds(700))
    }

    /// 기본: 이메일만 (조직 미상). Claude처럼 조직이 있는 프로바이더가 덮어쓴다.
    public func liveAccountKey() throws -> AccountKey? {
        try liveEmail().map { AccountKey(emailAddress: $0) }
    }

    /// 기본: 계정 열쇠. 저장을 거부하지 않는 프로바이더(`canStoreLiveSecret` 기본 구현)에서는 쓰이지 않는다.
    public func liveIdentityFingerprint() throws -> Data? {
        try liveAccountKey().map { Data("\($0.emailAddress)\u{0}\($0.organizationUuid)".utf8) }
    }
    public var identityIsInSecret: Bool { false }
    public var rollsBackFailedSwitch: Bool { true }
}

/// 라이브 값의 지문(해시)을 알려 주는 어댑터. 같은 이메일로 다시 로그인하거나 로그아웃해
/// 라이브 바이트가 바뀌면 활성 세대를 늘리는 데 쓴다(설계 4.7 「기준값과 활성 세대」).
/// nil = 로그아웃 상태 또는 아직 값을 읽지 않음.
public protocol LiveFingerprintReporting {
    var liveFingerprint: Data? { get }
}

/// 쓰기 직전에 읽은 라이브 값이 기대한 지문일 때만 쓰는 어댑터(설계 4.7 「비동기 경합」).
/// 기대 지문이 다르거나, 그 읽기 **뒤에** 부르는 `stillValid` 가 false 면 쓰지 않고 throw 한다 —
/// 마지막 읽기가 걸리는 동안 바뀐 설정·대상 등록을 쓰기 바로 앞에서 다시 본다(리뷰 2회차 Codex P1-3).
public protocol GuardedLiveWriting {
    func writeLiveSecretData(_ data: Data, ifLiveFingerprint expected: Data?,
                             stillValid: () -> Bool) throws
}

/// 변화 감지 중에 새로 읽은 라이브 값을 넘겨주는 어댑터(설계 4.2 「활성 계정 스냅샷 갱신」).
/// 한 번 넘기면 비운다.
public protocol LiveValueChangeReporting {
    func takeChangedLiveValue() -> Data?
}

/// 원자적 파일 쓰기 + 퍼미션 — 자격증명류 파일의 공통 쓰기 경로.
func writeAtomic(_ data: Data, to url: URL, mode: Int16) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

/// epoch 초/밀리초 겸용 해석 — 1e12 초과면 밀리초로 본다
/// (실측: Codex resets_at은 초, Claude expiresAt은 밀리초).
func dateFromEpochSecondsOrMillis(_ raw: Double) -> Date {
    Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
}
