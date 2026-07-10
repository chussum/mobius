import Foundation

public struct RateLimitInfo: Codable, Equatable, Sendable {
    public var resetsAt: Date
    public var recordedAt: Date
    public init(resetsAt: Date, recordedAt: Date) {
        self.resetsAt = resetsAt
        self.recordedAt = recordedAt
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

    public init(id: UUID, nickname: String, emailAddress: String,
                organizationName: String, tierDescription: String,
                needsReauth: Bool = false, rateLimit: RateLimitInfo? = nil,
                hasDesktopSnapshot: Bool = false) {
        self.id = id; self.nickname = nickname; self.emailAddress = emailAddress
        self.organizationName = organizationName; self.tierDescription = tierDescription
        self.needsReauth = needsReauth; self.rateLimit = rateLimit
        self.hasDesktopSnapshot = hasDesktopSnapshot
    }

    /// 지금 한도에 걸려 있는가 (리셋 시각 전인가)
    public func isLimited(now: Date) -> Bool {
        guard let rl = rateLimit else { return false }
        return now < rl.resetsAt
    }
}

/// accounts.json 전체. accounts[0] = primary(고정), 1... = fallback 우선순위.
public struct AccountsFile: Codable, Equatable, Sendable {
    public var accounts: [AccountProfile]
    public var activeAccountID: UUID?
    public var autoSwitchEnabled: Bool        // CLI 자동 fallback (기본 켬)
    public var desktopSyncEnabled: Bool       // 수동 전환 시 Desktop 동시 전환
    public var desktopAutoSwitchEnabled: Bool // 자동 전환 시에도 Desktop 동시 전환 (기본 끔)

    public init(accounts: [AccountProfile] = [], activeAccountID: UUID? = nil,
                autoSwitchEnabled: Bool = true, desktopSyncEnabled: Bool = true,
                desktopAutoSwitchEnabled: Bool = false) {
        self.accounts = accounts; self.activeAccountID = activeAccountID
        self.autoSwitchEnabled = autoSwitchEnabled; self.desktopSyncEnabled = desktopSyncEnabled
        self.desktopAutoSwitchEnabled = desktopAutoSwitchEnabled
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
