import Foundation

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
}

public struct AccountProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var nickname: String
    public var emailAddress: String
    public var organizationName: String
    public var tierDescription: String      // 표시용 예: "Max 20x", "Team"
    public var needsReauth: Bool
    public var rateLimit: RateLimitInfo?
    public var hasDesktopSnapshot: Bool     // 마일스톤 2에서 사용
    /// 사용자가 이 계정을 직접(수동) 골랐는가. true면 모델 전용 한도(Fable 등)로는
    /// 자동 전환해 밀어내지 않는다 — "1회 자동 전환 후 내가 되돌리면 머문다"는 규칙.
    /// 계정 자체 한도(5시간/주간)가 차면 이 핀은 무시된다(진짜 사용 불가이므로).
    public var userPinned: Bool

    public init(id: UUID, nickname: String, emailAddress: String,
                organizationName: String, tierDescription: String,
                needsReauth: Bool = false, rateLimit: RateLimitInfo? = nil,
                hasDesktopSnapshot: Bool = false, userPinned: Bool = false) {
        self.id = id; self.nickname = nickname; self.emailAddress = emailAddress
        self.organizationName = organizationName; self.tierDescription = tierDescription
        self.needsReauth = needsReauth; self.rateLimit = rateLimit
        self.hasDesktopSnapshot = hasDesktopSnapshot; self.userPinned = userPinned
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

/// accounts.json 전체. accounts[0] = primary(고정), 1... = fallback 우선순위.
public struct AccountsFile: Codable, Equatable, Sendable {
    public var accounts: [AccountProfile]
    public var activeAccountID: UUID?
    public var autoSwitchEnabled: Bool        // CLI 자동 fallback (기본 켬)
    public var desktopSyncEnabled: Bool       // 수동 전환 시 Desktop 동시 전환
    public var desktopAutoSwitchEnabled: Bool // 자동 전환 시에도 Desktop 동시 전환 (기본 끔)
    /// 현재 fallback 활성 상태가 "자동 전환"의 결과인가. 수동 전환/외부 로그인은 false —
    /// onTick의 primary 자동 복귀는 이 플래그가 true일 때만 일어난다 (수동 전환 자동 회귀 방지).
    public var autoSwitchedFromPrimary: Bool

    public init(accounts: [AccountProfile] = [], activeAccountID: UUID? = nil,
                autoSwitchEnabled: Bool = true, desktopSyncEnabled: Bool = true,
                desktopAutoSwitchEnabled: Bool = false, autoSwitchedFromPrimary: Bool = false) {
        self.accounts = accounts; self.activeAccountID = activeAccountID
        self.autoSwitchEnabled = autoSwitchEnabled; self.desktopSyncEnabled = desktopSyncEnabled
        self.desktopAutoSwitchEnabled = desktopAutoSwitchEnabled
        self.autoSwitchedFromPrimary = autoSwitchedFromPrimary
    }

    /// 하위호환 디코딩 — 구버전 accounts.json에 없는 필드는 기본값으로 채운다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([AccountProfile].self, forKey: .accounts) ?? []
        activeAccountID = try c.decodeIfPresent(UUID.self, forKey: .activeAccountID)
        autoSwitchEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoSwitchEnabled) ?? true
        desktopSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .desktopSyncEnabled) ?? true
        desktopAutoSwitchEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .desktopAutoSwitchEnabled) ?? false
        autoSwitchedFromPrimary =
            try c.decodeIfPresent(Bool.self, forKey: .autoSwitchedFromPrimary) ?? false
    }

    public var primary: AccountProfile? { accounts.first }
    public var active: AccountProfile? { accounts.first { $0.id == activeAccountID } }
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
