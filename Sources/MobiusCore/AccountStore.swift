import Foundation

public enum AccountStoreError: Error, Equatable {
    case snapshotMissingEmail
    case cannotMovePrimary
    case unknownAccount
}

/// accounts.json(메타데이터) + 앱 Keychain(비밀 스냅샷) 영속화.
public final class AccountStore: @unchecked Sendable {
    public private(set) var file: AccountsFile
    let env: MobiusEnvironment
    let keychain: KeychainClient
    private let lock = NSLock()

    static let secretAccount = "snapshot"
    static func secretService(for id: UUID) -> String { "Mobius-account-\(id.uuidString)" }

    public init(env: MobiusEnvironment, keychain: KeychainClient) throws {
        self.env = env
        self.keychain = keychain
        if let data = try? Data(contentsOf: env.accountsFile) {
            self.file = try JSONDecoder().decode(AccountsFile.self, from: data)
        } else {
            self.file = AccountsFile()
        }
    }

    public func save() throws {
        let data = try JSONEncoder().encode(file)
        try FileManager.default.createDirectory(at: env.appSupportDir,
                                                withIntermediateDirectories: true)
        try data.write(to: env.accountsFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: env.accountsFile.path)
    }

    // MARK: 프로필

    /// 스냅샷의 email로 기존 프로필을 찾아 갱신하거나 새로 만든다. 첫 계정은 자동 활성.
    @discardableResult
    public func upsertProfile(nickname: String, snapshot: CredentialsSnapshot) throws -> AccountProfile {
        lock.lock(); defer { lock.unlock() }
        guard let oauthJSON = snapshot.oauthAccountJSON,
              let block = try JSONSerialization.jsonObject(with: oauthJSON) as? [String: Any],
              let email = block["emailAddress"] as? String else {
            throw AccountStoreError.snapshotMissingEmail
        }
        let org = block["organizationName"] as? String ?? ""
        let tier = Self.tierDescription(from: block)

        var profile: AccountProfile
        if let idx = file.accounts.firstIndex(where: { $0.emailAddress == email }) {
            file.accounts[idx].nickname = nickname
            file.accounts[idx].organizationName = org
            file.accounts[idx].tierDescription = tier
            file.accounts[idx].needsReauth = false
            profile = file.accounts[idx]
        } else {
            profile = AccountProfile(id: UUID(), nickname: nickname, emailAddress: email,
                                     organizationName: org, tierDescription: tier)
            file.accounts.append(profile)
            if file.activeAccountID == nil { file.activeAccountID = profile.id }
        }
        try setSecret(snapshot, for: profile.id)
        try save()
        return profile
    }

    static func tierDescription(from block: [String: Any]) -> String {
        let tier = (block["organizationRateLimitTier"] as? String)
            ?? (block["organizationType"] as? String) ?? ""
        // "default_claude_max_20x" → "Max 20x" 정도의 사람이 읽는 문자열로
        return tier.replacingOccurrences(of: "default_", with: "")
            .replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    // MARK: 비밀 스냅샷 (앱 Keychain)

    public func secret(for id: UUID) throws -> CredentialsSnapshot? {
        guard let data = try keychain.read(service: Self.secretService(for: id),
                                           account: Self.secretAccount) else { return nil }
        return try JSONDecoder().decode(CredentialsSnapshot.self, from: data)
    }

    public func setSecret(_ snapshot: CredentialsSnapshot, for id: UUID) throws {
        let data = try JSONEncoder().encode(snapshot)
        try keychain.write(service: Self.secretService(for: id),
                           account: Self.secretAccount, data: data)
    }

    // MARK: 상태 변경

    public func setActive(_ id: UUID?) throws {
        lock.lock(); defer { lock.unlock() }
        file.activeAccountID = id
        try save()
    }

    public func setAutoSwitch(_ enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        file.autoSwitchEnabled = enabled
        try save()
    }

    public func setDesktopSync(_ enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        file.desktopSyncEnabled = enabled
        try save()
    }

    /// 디스크에서 다시 읽은 상태로 교체 (CLI 등 외부 프로세스 변경 반영용)
    public func replaceFile(with newFile: AccountsFile) throws {
        lock.lock(); defer { lock.unlock() }
        file = newFile
    }

    /// fallback(인덱스 1 이상)끼리만 재배열. primary(0)는 고정.
    public func moveFallback(fromIndex: Int, toIndex: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard fromIndex >= 1, toIndex >= 1,
              fromIndex < file.accounts.count, toIndex < file.accounts.count else {
            throw AccountStoreError.cannotMovePrimary
        }
        let item = file.accounts.remove(at: fromIndex)
        file.accounts.insert(item, at: toIndex)
        try save()
    }

    public func remove(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard file.accounts.contains(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        file.accounts.removeAll { $0.id == id }
        if file.activeAccountID == id { file.activeAccountID = file.accounts.first?.id }
        try keychain.delete(service: Self.secretService(for: id), account: Self.secretAccount)
        try save()
    }

    public func update(_ id: UUID, _ mutate: (inout AccountProfile) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard let idx = file.accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        mutate(&file.accounts[idx])
        try save()
    }
}
