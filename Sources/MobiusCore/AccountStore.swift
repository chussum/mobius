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
        guard let data = try? Data(contentsOf: env.accountsFile) else {
            self.file = AccountsFile()
            return
        }
        do {
            self.file = try JSONDecoder().decode(AccountsFile.self, from: data)
        } catch {
            // 방어: 디코드 실패 시 원본을 백업해 둔다 — 빈 스토어로 시작한 앱이 이후 저장으로
            // 원본을 덮어써도 계정 데이터가 영구 유실되지 않도록(복구 가능).
            let backup = env.accountsFile.deletingLastPathComponent()
                .appendingPathComponent("accounts.corrupt.json")
            try? data.write(to: backup, options: .atomic)
            throw error
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

    /// (provider, email)로 기존 프로필을 찾아 갱신하거나 새로 만든다.
    /// 그 프로바이더의 첫 계정은 자동 활성.
    @discardableResult
    public func upsertProfile(nickname: String, provider: Provider,
                              identity: ProviderIdentity, secretData: Data) throws -> AccountProfile {
        lock.lock(); defer { lock.unlock() }
        var profile: AccountProfile
        if let idx = file.accounts.firstIndex(where: {
            $0.provider == provider && $0.emailAddress == identity.emailAddress
        }) {
            file.accounts[idx].nickname = nickname
            file.accounts[idx].organizationName = identity.organizationName
            file.accounts[idx].tierDescription = identity.tierDescription
            file.accounts[idx].needsReauth = false
            profile = file.accounts[idx]
        } else {
            profile = AccountProfile(id: UUID(), provider: provider, nickname: nickname,
                                     emailAddress: identity.emailAddress,
                                     organizationName: identity.organizationName,
                                     tierDescription: identity.tierDescription)
            file.accounts.append(profile)
            if file.activeByProvider[provider] == nil {
                file.activeByProvider[provider] = profile.id
            }
        }
        try setSecretData(secretData, for: profile.id)
        try save()
        return profile
    }

    /// Claude 편의 경로 — 스냅샷에서 신원을 추출해 등록한다 (CLI capture·LoginFlow용).
    @discardableResult
    public func upsertProfile(nickname: String, snapshot: CredentialsSnapshot) throws -> AccountProfile {
        guard let oauthJSON = snapshot.oauthAccountJSON,
              let block = try JSONSerialization.jsonObject(with: oauthJSON) as? [String: Any],
              let identity = ClaudeConfigIO.identity(fromOAuthBlock: block) else {
            throw AccountStoreError.snapshotMissingEmail
        }
        return try upsertProfile(nickname: nickname, provider: .claude, identity: identity,
                                 secretData: try JSONEncoder().encode(snapshot))
    }

    // MARK: 비밀 스냅샷 (0700 파일 — Claude Code의 .credentials.json과 동일 보안 수준)
    // 내용물은 프로바이더가 정한 직렬화 바이트 (ProviderConfigIO 참조). 스토어는 해석하지 않는다.

    public func secretData(for id: UUID) throws -> Data? {
        // 1순위: 파일. 승인창 없음.
        if let data = try? Data(contentsOf: env.secretFile(for: id)) {
            return data
        }
        // 2순위: 구버전 Keychain 항목(Claude 시절) → 발견 시 파일로 이관하고 Keychain 항목 제거
        //        (한 번만 승인창이 뜨고, 이후로는 파일에서 읽어 다시 뜨지 않는다).
        if let data = ((try? keychain.read(service: Self.secretService(for: id),
                                           account: Self.secretAccount)) ?? nil) {
            _ = try JSONDecoder().decode(CredentialsSnapshot.self, from: data) // 형식 검증
            try? writeSecretFile(data, for: id)
            try? keychain.delete(service: Self.secretService(for: id),
                                 account: Self.secretAccount)
            return data
        }
        return nil
    }

    public func setSecretData(_ data: Data, for id: UUID) throws {
        try writeSecretFile(data, for: id)
        // 혹시 남아 있을 수 있는 구버전 Keychain 항목은 정리 (승인창 재발 방지)
        try? keychain.delete(service: Self.secretService(for: id), account: Self.secretAccount)
    }

    /// Claude 편의 경로 — 기존 비밀 파일 포맷(CredentialsSnapshot JSON) 그대로.
    public func secret(for id: UUID) throws -> CredentialsSnapshot? {
        guard let data = try secretData(for: id) else { return nil }
        return try JSONDecoder().decode(CredentialsSnapshot.self, from: data)
    }

    public func setSecret(_ snapshot: CredentialsSnapshot, for id: UUID) throws {
        try setSecretData(try JSONEncoder().encode(snapshot), for: id)
    }

    private func writeSecretFile(_ data: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: env.secretsDir,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = env.secretFile(for: id)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: 상태 변경

    /// 지정 계정을 자기 프로바이더 풀의 활성으로 표시한다.
    public func setActive(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let profile = file.accounts.first(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        file.activeByProvider[profile.provider] = id
        try save()
    }

    /// provider 기본값 없음 — 풀을 바꾸는 연산은 대상 풀을 항상 명시한다 (오라우팅 방지).
    public func setAutoSwitch(_ enabled: Bool, provider: Provider) throws {
        lock.lock(); defer { lock.unlock() }
        file.autoSwitchByProvider[provider] = enabled
        try save()
    }

    public func setDesktopSync(_ enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        file.desktopSyncEnabled = enabled
        try save()
    }

    /// 현재 fallback 활성이 자동 전환의 결과인지 기록 — 파일로 영속되므로
    /// CLI 전환(별 프로세스)·앱 재시작 후에도 onTick 복귀 판단이 올바르다.
    /// provider 기본값 없음 — 풀을 바꾸는 연산은 대상 풀을 항상 명시한다 (오라우팅 방지).
    public func setAutoSwitchedFromPrimary(_ flagged: Bool, provider: Provider) throws {
        lock.lock(); defer { lock.unlock() }
        file.autoSwitchedByProvider[provider] = flagged
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

    /// fallback(프로바이더 풀 내 인덱스 1 이상)끼리만 재배열. primary(0)는 고정.
    /// 인덱스는 해당 프로바이더 계정 목록 기준이다.
    public func moveFallback(provider: Provider, fromIndex: Int, toIndex: Int) throws {
        lock.lock(); defer { lock.unlock() }
        var group = file.accounts.filter { $0.provider == provider }
        guard fromIndex >= 1, toIndex >= 1,
              fromIndex < group.count, toIndex < group.count else {
            throw AccountStoreError.cannotMovePrimary
        }
        let item = group.remove(at: fromIndex)
        group.insert(item, at: toIndex)
        replaceGroup(provider, with: group)
        try save()
    }

    /// 프로바이더 그룹을 재배열 결과로 치환한다 — 전체 배열에서 그 프로바이더가 차지하던
    /// 위치들은 유지하고 내용만 새 순서로 채운다 (타 프로바이더 계정 순서 불변).
    private func replaceGroup(_ provider: Provider, with group: [AccountProfile]) {
        var it = group.makeIterator()
        file.accounts = file.accounts.map { $0.provider == provider ? it.next()! : $0 }
    }

    /// 재로그인 필요 마킹/해제. 변화 없으면 저장하지 않는다.
    public func setNeedsReauth(_ id: UUID, _ flag: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard let idx = file.accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        guard file.accounts[idx].needsReauth != flag else { return }
        file.accounts[idx].needsReauth = flag
        try save()
    }

    /// 지정 계정에만 사용자 핀을 세운다(같은 프로바이더 풀의 나머지는 해제). 수동 전환 시 호출 —
    /// 모델 전용 한도(Fable 등)로 이 계정을 자동으로 밀어내지 않게 한다.
    /// ★ 핀 해제는 반드시 같은 풀로 한정한다 — 전역 clear는 Codex 계정을 수동 전환할 때
    ///   사용자가 골라둔 Claude 계정의 핀까지 풀어 modelScoped 한도에서 의도치 않은 자동 전환을
    ///   유발한다(풀은 독립이므로 핀도 풀별 독립이어야 한다).
    public func setUserPinned(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let provider = file.accounts.first(where: { $0.id == id })?.provider else {
            throw AccountStoreError.unknownAccount
        }
        var changed = false
        for i in file.accounts.indices where file.accounts[i].provider == provider {
            let want = file.accounts[i].id == id
            if file.accounts[i].userPinned != want { file.accounts[i].userPinned = want; changed = true }
        }
        if changed { try save() }
    }

    /// 지정 계정을 자기 프로바이더 풀의 primary(첫 자리)로 승격. 기존 primary는 첫
    /// fallback으로 내려간다. primary 기준이 바뀌므로 그 풀의 autoSwitchedFromPrimary는
    /// 리셋 — 옛 primary 체제에서의 자동 복귀 예약이 새 primary로 오귀속되지 않도록.
    public func setPrimary(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let profile = file.accounts.first(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        var group = file.accounts.filter { $0.provider == profile.provider }
        guard group.first?.id != id else { return } // 이미 primary — 변경 없음
        group.removeAll { $0.id == id }
        group.insert(profile, at: 0)
        replaceGroup(profile.provider, with: group)
        file.autoSwitchedByProvider[profile.provider] = false
        try save()
    }

    public func remove(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let profile = file.accounts.first(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        file.accounts.removeAll { $0.id == id }
        if file.activeByProvider[profile.provider] == id {
            file.activeByProvider[profile.provider] =
                file.accounts.first { $0.provider == profile.provider }?.id
        }
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
