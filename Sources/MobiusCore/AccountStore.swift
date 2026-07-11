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

    /// 디스크를 읽지 않고 주어진 상태로 시작한다 (로드 실패 시 앱의 안전 폴백용).
    public init(env: MobiusEnvironment, keychain: KeychainClient, file: AccountsFile) {
        self.env = env
        self.keychain = keychain
        self.file = file
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

    // MARK: 비밀 스냅샷 (0700 파일 — Claude Code의 .credentials.json과 동일 보안 수준)

    public func secret(for id: UUID) throws -> CredentialsSnapshot? {
        // 1순위: 파일. 승인창 없음.
        if let data = try? Data(contentsOf: env.secretFile(for: id)) {
            return try JSONDecoder().decode(CredentialsSnapshot.self, from: data)
        }
        // 2순위: 구버전 Keychain 항목 → 발견 시 파일로 이관하고 Keychain 항목 제거
        //        (한 번만 승인창이 뜨고, 이후로는 파일에서 읽어 다시 뜨지 않는다).
        if let data = ((try? keychain.read(service: Self.secretService(for: id),
                                           account: Self.secretAccount)) ?? nil) {
            let snap = try JSONDecoder().decode(CredentialsSnapshot.self, from: data)
            try? writeSecretFile(snap, for: id)
            try? keychain.delete(service: Self.secretService(for: id),
                                 account: Self.secretAccount)
            return snap
        }
        return nil
    }

    public func setSecret(_ snapshot: CredentialsSnapshot, for id: UUID) throws {
        try writeSecretFile(snapshot, for: id)
        // 혹시 남아 있을 수 있는 구버전 Keychain 항목은 정리 (승인창 재발 방지)
        try? keychain.delete(service: Self.secretService(for: id), account: Self.secretAccount)
    }

    private func writeSecretFile(_ snapshot: CredentialsSnapshot, for id: UUID) throws {
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: env.secretsDir,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = env.secretFile(for: id)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

    /// 현재 fallback 활성이 자동 전환의 결과인지 기록 — 파일로 영속되므로
    /// CLI 전환(별 프로세스)·앱 재시작 후에도 onTick 복귀 판단이 올바르다.
    public func setAutoSwitchedFromPrimary(_ flagged: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        file.autoSwitchedFromPrimary = flagged
        try save()
    }

    public func setDesktopAutoSwitch(_ enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        file.desktopAutoSwitchEnabled = enabled
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

    /// 지정 계정을 primary(인덱스 0)로 승격. 기존 primary는 첫 fallback으로 내려간다.
    /// primary 기준이 바뀌므로 autoSwitchedFromPrimary는 리셋 — 옛 primary 체제에서의
    /// 자동 복귀 예약이 새 primary로 오귀속되지 않도록.
    public func setPrimary(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let idx = file.accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        guard idx != 0 else { return } // 이미 primary — 변경 없음
        let item = file.accounts.remove(at: idx)
        file.accounts.insert(item, at: 0)
        file.autoSwitchedFromPrimary = false
        try save()
    }

    public func remove(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard file.accounts.contains(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        file.accounts.removeAll { $0.id == id }
        if file.activeAccountID == id { file.activeAccountID = file.accounts.first?.id }
        try? FileManager.default.removeItem(at: env.secretFile(for: id))
        try? keychain.delete(service: Self.secretService(for: id), account: Self.secretAccount)
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
