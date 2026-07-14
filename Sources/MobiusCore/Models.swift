import Foundation

/// 계정이 속한 AI CLI 프로바이더. 전환·자동 fallback은 프로바이더별 풀에서 독립적으로 동작한다.
public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

public struct RateLimitInfo: Codable, Equatable, Sendable {
    public var resetsAt: Date
    public var recordedAt: Date
    /// 모델 전용 한도(예: Fable 주간)인가 — 계정 자체(5시간/주간)는 여유가 있을 수 있다.
    /// 이 경우 자동 전환은 "사용자가 그 계정을 직접 고르지 않았을 때"만 일어난다(pin 존중).
    public var modelScoped: Bool
    public init(resetsAt: Date, recordedAt: Date, modelScoped: Bool = false) {
        self.resetsAt = resetsAt
        self.recordedAt = recordedAt
        self.modelScoped = modelScoped
    }

    // 하위 호환: modelScoped 키가 없는 구버전 파일도 디코드되게 (없으면 false).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resetsAt = try c.decode(Date.self, forKey: .resetsAt)
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        modelScoped = try c.decodeIfPresent(Bool.self, forKey: .modelScoped) ?? false
    }
}

public struct AccountProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var nickname: String
    public var emailAddress: String
    public var organizationName: String
    public var tierDescription: String      // 표시용 예: "Max 20x", "Team", "Pro"
    public var needsReauth: Bool
    public var rateLimit: RateLimitInfo?
    public var hasDesktopSnapshot: Bool     // Claude 전용 (Desktop 동시 전환)
    /// 사용자가 이 계정을 직접(수동) 골랐는가. true면 모델 전용 한도(Fable 등)로는
    /// 자동 전환해 밀어내지 않는다 — "1회 자동 전환 후 내가 되돌리면 머문다"는 규칙.
    /// 계정 자체 한도(5시간/주간)가 차면 이 핀은 무시된다(진짜 사용 불가이므로).
    public var userPinned: Bool

    public init(id: UUID, provider: Provider = .claude, nickname: String, emailAddress: String,
                organizationName: String, tierDescription: String,
                needsReauth: Bool = false, rateLimit: RateLimitInfo? = nil,
                hasDesktopSnapshot: Bool = false, userPinned: Bool = false) {
        self.id = id; self.provider = provider
        self.nickname = nickname; self.emailAddress = emailAddress
        self.organizationName = organizationName; self.tierDescription = tierDescription
        self.needsReauth = needsReauth; self.rateLimit = rateLimit
        self.hasDesktopSnapshot = hasDesktopSnapshot; self.userPinned = userPinned
    }

    /// 하위호환 디코딩 — 새 키(provider, userPinned 등)가 없는 구버전 파일도 디코드되게.
    /// provider 없으면 Claude로 간주. 다른 사용자가 업데이트해도 계정 목록이 깨지지 않도록.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude
        nickname = try c.decode(String.self, forKey: .nickname)
        emailAddress = try c.decode(String.self, forKey: .emailAddress)
        organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName) ?? ""
        tierDescription = try c.decodeIfPresent(String.self, forKey: .tierDescription) ?? ""
        needsReauth = try c.decodeIfPresent(Bool.self, forKey: .needsReauth) ?? false
        rateLimit = try c.decodeIfPresent(RateLimitInfo.self, forKey: .rateLimit)
        hasDesktopSnapshot = try c.decodeIfPresent(Bool.self, forKey: .hasDesktopSnapshot) ?? false
        userPinned = try c.decodeIfPresent(Bool.self, forKey: .userPinned) ?? false
    }

    /// 지금 한도에 걸려 있는가 (리셋 시각 전인가)
    public func isLimited(now: Date) -> Bool {
        guard let rl = rateLimit else { return false }
        return now < rl.resetsAt
    }

    /// 자동 전환이 이 계정을 밀어내도 되는가. 모델 전용 한도 + 사용자 핀이면 밀어내지 않는다.
    /// (계정 자체 한도로 걸린 경우엔 modelScoped=false라 핀과 무관하게 밀어낼 수 있다.)
    public func autoSwitchMayLeave(now: Date) -> Bool {
        guard isLimited(now: now) || needsReauth else { return false }
        if let rl = rateLimit, rl.modelScoped, userPinned { return false }
        return true
    }
}

/// accounts.json 전체. 모든 프로바이더의 계정이 한 배열에 담기고, 활성/자동전환 상태는
/// 프로바이더별 풀로 독립 관리된다. 프로바이더 내 순서가 우선순위 — 그 프로바이더의
/// 첫 계정이 primary(고정), 이후가 fallback 순서.
public struct AccountsFile: Codable, Equatable, Sendable {
    public var accounts: [AccountProfile]
    /// 프로바이더별 활성 계정 id
    public var activeByProvider: [Provider: UUID]
    /// 프로바이더별: 현재 fallback 활성 상태가 "자동 전환"의 결과인가. 수동 전환/외부
    /// 로그인은 false — onTick의 primary 자동 복귀는 이 플래그가 true일 때만 일어난다
    /// (수동 전환 자동 회귀 방지).
    public var autoSwitchedByProvider: [Provider: Bool]
    /// 프로바이더별 자동 전환 on/off (없는 키는 켬 — isAutoSwitchEnabled 참조)
    public var autoSwitchByProvider: [Provider: Bool]
    public var desktopSyncEnabled: Bool       // 수동 전환 시 Desktop 동시 전환 (Claude 전용)
    public var desktopAutoSwitchEnabled: Bool // 자동 전환 시에도 Desktop 동시 전환 (기본 끔)

    public init(accounts: [AccountProfile] = [], activeAccountID: UUID? = nil,
                autoSwitchEnabled: Bool = true, desktopSyncEnabled: Bool = true,
                desktopAutoSwitchEnabled: Bool = false, autoSwitchedFromPrimary: Bool = false) {
        self.accounts = accounts
        self.activeByProvider = activeAccountID.map { [.claude: $0] } ?? [:]
        self.autoSwitchedByProvider = autoSwitchedFromPrimary ? [.claude: true] : [:]
        self.autoSwitchByProvider = autoSwitchEnabled ? [:]
            : Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, false) })
        self.desktopSyncEnabled = desktopSyncEnabled
        self.desktopAutoSwitchEnabled = desktopAutoSwitchEnabled
    }

    /// 하위호환 디코딩 — 풀 분리 이전(activeAccountID/autoSwitchedFromPrimary가 최상위
    /// 단일 값이던) accounts.json은 Claude 풀로 흡수하고, 없는 필드는 기본값으로 채운다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([AccountProfile].self, forKey: .accounts) ?? []
        if let pools = try c.decodeIfPresent([Provider: UUID].self, forKey: .activeByProvider) {
            activeByProvider = pools
        } else {
            let legacy = try c.decodeIfPresent(UUID.self, forKey: .legacyActiveAccountID)
            activeByProvider = legacy.map { [.claude: $0] } ?? [:]
        }
        if let flags = try c.decodeIfPresent([Provider: Bool].self,
                                             forKey: .autoSwitchedByProvider) {
            autoSwitchedByProvider = flags
        } else {
            let legacy = try c.decodeIfPresent(Bool.self, forKey: .legacyAutoSwitchedFromPrimary)
            autoSwitchedByProvider = legacy.map { [.claude: $0] } ?? [:]
        }
        if let flags = try c.decodeIfPresent([Provider: Bool].self, forKey: .autoSwitchByProvider) {
            autoSwitchByProvider = flags
        } else {
            // 구 전역 키는 양쪽 풀에 동일 적용
            let legacy = try c.decodeIfPresent(Bool.self, forKey: .legacyAutoSwitchEnabled) ?? true
            autoSwitchByProvider = legacy ? [:]
                : Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, false) })
        }
        desktopSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .desktopSyncEnabled) ?? true
        desktopAutoSwitchEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .desktopAutoSwitchEnabled) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case accounts, activeByProvider, autoSwitchedByProvider, autoSwitchByProvider
        case desktopSyncEnabled, desktopAutoSwitchEnabled
        case legacyActiveAccountID = "activeAccountID"
        case legacyAutoSwitchedFromPrimary = "autoSwitchedFromPrimary"
        case legacyAutoSwitchEnabled = "autoSwitchEnabled"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accounts, forKey: .accounts)
        try c.encode(activeByProvider, forKey: .activeByProvider)
        try c.encode(autoSwitchedByProvider, forKey: .autoSwitchedByProvider)
        try c.encode(autoSwitchByProvider, forKey: .autoSwitchByProvider)
        try c.encode(desktopSyncEnabled, forKey: .desktopSyncEnabled)
        try c.encode(desktopAutoSwitchEnabled, forKey: .desktopAutoSwitchEnabled)
        // 다운그레이드 완충: 풀 분리 이전 바이너리도 Claude 활성 상태는 올바르게 읽도록
        // 레거시 키를 함께 기록한다 (구버전이 저장하면 provider 필드가 소실되므로
        // 완전한 하위호환은 아님 — 신구 바이너리 혼용 금지는 문서에 기록).
        try c.encodeIfPresent(activeByProvider[.claude], forKey: .legacyActiveAccountID)
        try c.encode(isAutoSwitchedFromPrimary(.claude), forKey: .legacyAutoSwitchedFromPrimary)
        try c.encode(isAutoSwitchEnabled(.claude), forKey: .legacyAutoSwitchEnabled)
    }

    // MARK: 프로바이더별 풀

    public func accounts(of provider: Provider) -> [AccountProfile] {
        accounts.filter { $0.provider == provider }
    }

    public func primary(of provider: Provider) -> AccountProfile? {
        accounts.first { $0.provider == provider }
    }

    public func active(of provider: Provider) -> AccountProfile? {
        guard let id = activeByProvider[provider] else { return nil }
        return accounts.first { $0.id == id && $0.provider == provider }
    }

    public func isAutoSwitchedFromPrimary(_ provider: Provider) -> Bool {
        autoSwitchedByProvider[provider] ?? false
    }

    /// 풀별 자동 전환 on/off — 기록이 없는 풀은 켬(기본값)
    public func isAutoSwitchEnabled(_ provider: Provider) -> Bool {
        autoSwitchByProvider[provider] ?? true
    }

    // MARK: Claude 풀의 경계된 뷰 (Desktop 연동 등 Claude 전용 경로용)

    public var activeAccountID: UUID? {
        get { activeByProvider[.claude] }
        set { activeByProvider[.claude] = newValue }
    }
    public var autoSwitchedFromPrimary: Bool {
        get { isAutoSwitchedFromPrimary(.claude) }
        set { autoSwitchedByProvider[.claude] = newValue }
    }
    public var primary: AccountProfile? { primary(of: .claude) }
    public var active: AccountProfile? { active(of: .claude) }
}

/// Claude Code 자격증명 3곳의 원자적 스냅샷. 비밀값 — 앱 Keychain에만 저장된다.
public struct CredentialsSnapshot: Codable, Equatable, Sendable {
    public var keychainBlob: Data          // Keychain "Claude Code-credentials" 비밀값
    public var credentialsFileData: Data   // ~/.claude/.credentials.json 내용
    public var oauthAccountJSON: Data?     // ~/.claude.json 의 oauthAccount 서브트리(JSON)

    public init(keychainBlob: Data, credentialsFileData: Data, oauthAccountJSON: Data?) {
        self.keychainBlob = keychainBlob
        self.credentialsFileData = credentialsFileData
        self.oauthAccountJSON = oauthAccountJSON
    }
}
