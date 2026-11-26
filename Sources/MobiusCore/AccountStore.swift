import Foundation

public enum AccountStoreError: Error, Equatable {
    case snapshotMissingEmail
    case cannotMovePrimary
    case unknownAccount
    /// accounts.json 을 읽지 못한(파일은 있다) 스토어 — 다시 읽기에 성공할 때까지 저장하지 않는다.
    case savesBlockedAfterLoadFailure
}

/// accounts.json(메타데이터) + 앱 Keychain(비밀 스냅샷) 영속화.
public final class AccountStore: @unchecked Sendable {
    /// 현재 상태. 읽기도 잠금 안에서 사본을 꺼낸다 — Antigravity 전환이 메인 밖에서 `setActive`
    /// 로 구조체 전체를 바꾸는 동안 메인 액터의 틱·UI 가 같은 값을 읽기 때문이다(리뷰 1회차 Codex
    /// P1-5). 그 잠금은 **저장 직렬화 잠금(`lock`)과 다른 `stateLock`** 이다 — 저장은 디스크 읽기·쓰기를
    /// 하는 동안 `lock` 을 쥐므로, 같은 잠금으로 읽으면 메인 액터가 그 I/O 를 기다린다(리뷰 2회차
    /// Codex P1-4, 실패 기록 20 과 같은 구조).
    /// - `_file` 을 바꾸는 쪽은 `lock` 과 `stateLock` 을 **둘 다** 쥔다(`adoptLocked`).
    /// - `lock` 을 쥔 내부 코드는 `_file` 을 직접 읽어도 된다(그동안 다른 쓰기가 없다).
    /// - 그 밖의 읽기는 `stateLock` 만 쥔다. 잠금 순서는 `lock` → `stateLock`.
    public var file: AccountsFile { stateLock.withLock { _file } }
    private var _file: AccountsFile
    let env: MobiusEnvironment
    let keychain: KeychainClient
    /// 저장(읽고-고치고-쓰기)을 직렬화한다. 이 잠금 안에서는 키체인을 부르지 않는다.
    private let lock = NSLock()
    /// 메모리 상태(`_file`, 세대, 지문, 플래그)를 지킨다. 짧게만 쥔다 — 그 안에서 I/O 를 하지 않는다.
    private let stateLock = NSLock()
    /// 비밀 스냅샷(파일) 읽기/쓰기 직렬화 — 메타데이터 `lock`과 별개다(upsertProfile이 `lock`을
    /// 쥔 채 setSecretData를 호출하므로 같은 락이면 데드락). read/backup/write 시퀀스를 원자로 묶어
    /// 동시 store + read가 찢긴 바이트를 보지 않게 한다.
    private let secretLock = NSLock()
    /// 계정별 credential lock (UUID-keyed mutex). refresher의 read-snapshot→refresh→(recheck-active)
    /// →store 시퀀스와 Switcher.switchTo(id)가 **같은 id에 대해 둘 다** 이 락 안에서 돌아, 전환이
    /// 회전 직전(pre-rotation) 스냅샷을 라이브에 설치하는 레이스를 막는다(Codex 토큰 자동 갱신).
    private var credentialLocks: [UUID: NSLock] = [:]
    private let credentialLocksGuard = NSLock()
    /// 계정별 구버전 키체인 이관 잠금(`secretData`) — 같은 계정의 겹친 이관만 합친다.
    private var legacyMigrationLocks: [UUID: NSLock] = [:]

    /// 프로바이더별 **활성 세대 번호**(메모리). 활성 값이 바뀔 때마다 1 늘린다 — 자기 저장,
    /// 디스크에서 다시 읽은 활성 값이나 활성 리비전의 변화, 라이브 지문의 변화를 모두 포함한다.
    /// 같은 계정으로 돌아온 왕복도 세대를 바꾼다(설계 4.7 「기준값과 활성 세대」).
    private var generations: [Provider: Int] = [:]
    private var notedFingerprints: [Provider: Data?] = [:]
    /// 구버전 저장 뒤 Antigravity 계정을 복원했는가 — 앱이 사용자에게 한 번 알리고 내린다.
    public var restoredAfterLegacySave: Bool { stateLock.withLock { _restoredAfterLegacySave } }
    private var _restoredAfterLegacySave = false
    /// accounts.json 이 **있는데** 읽지 못한 오류(권한, I/O, 디코드). 값이 있는 동안 모든 저장을 거부한다 —
    /// 빈 목록이나 낡은 메모리로 기존 파일을 덮지 않게(리뷰 2회차 Codex P1-1, 실패 기록 13). 다시 읽기에
    /// 성공하면(`reloadFromDisk`) 내린다.
    public var loadFailure: Error? { stateLock.withLock { _loadFailure } }
    /// 읽기 실패의 종류 — 앱 알림이 빠져나갈 길을 다르게 안내한다(리뷰 3회차 Claude P3-2).
    public enum LoadFailureKind: Equatable, Sendable {
        /// 권한·I/O — 파일 권한을 고치면 풀린다.
        case unreadable
        /// 내용을 해석하지 못함(손상, 또는 더 새 버전의 형식) — 원본은 `backup` 에 있다. 파일을 고치거나
        /// 지우면(지우면 계정 목록은 비고 secret 파일은 남는다) 풀린다. 백업이 지금 파일과 같은 내용으로
        /// 있지 않으면(쓰기 실패 — 디스크 가득 참 등) nil 이다 — 그때 원본은 유일한 사본이다(리뷰 4회차 Codex P2).
        case corrupt(backup: URL?)
    }
    public var loadFailureKind: LoadFailureKind? {
        guard let error = loadFailure else { return nil }
        guard error is DecodingError else { return .unreadable }
        let backup = Self.corruptBackupURL(env: env)
        guard let original = try? Data(contentsOf: env.accountsFile),
              (try? Data(contentsOf: backup)) == original else { return .corrupt(backup: nil) }
        return .corrupt(backup: backup)
    }

    static func corruptBackupURL(env: MobiusEnvironment) -> URL {
        env.accountsFile.deletingLastPathComponent().appendingPathComponent("accounts.corrupt.json")
    }
    private var _loadFailure: Error?

    static let secretAccount = "snapshot"
    static func secretService(for id: UUID) -> String { "Mobius-account-\(id.uuidString)" }

    public init(env: MobiusEnvironment, keychain: KeychainClient) throws {
        self.env = env
        self.keychain = keychain
        let (loaded, restored) = try Self.load(env: env, memory: nil)
        self._file = loaded ?? AccountsFile()
        self._restoredAfterLegacySave = restored
    }

    /// 시작 때 읽기에 실패한 스토어(앱의 폴백). 빈 상태로 시작하되 **저장을 거부한다** —
    /// 다시 읽기(`reloadFromDisk`)에 성공할 때까지(리뷰 2회차 Codex P1-1).
    public init(env: MobiusEnvironment, keychain: KeychainClient, afterLoadFailure error: Error) {
        self.env = env
        self.keychain = keychain
        self._file = AccountsFile()
        self._loadFailure = error
    }

    /// 디스크를 읽지 않고 주어진 상태로 시작한다(테스트·도구용). **저장을 허용하므로 로드 실패의 폴백으로
    /// 쓰지 않는다** — 그때는 `init(env:keychain:afterLoadFailure:)` 를 쓴다(리뷰 3회차 Codex P3).
    public init(env: MobiusEnvironment, keychain: KeychainClient, file: AccountsFile) {
        self.env = env
        self.keychain = keychain
        self._file = file
    }

    // MARK: 디스크 읽기와 구버전 저장 뒤 복원 (설계 4.4-4)

    /// accounts.json 을 읽는다. 파일이 없으면 nil. 디코드 실패면 원본을 백업하고 throw.
    /// 구버전이 저장한 파일(`extraProviderAccounts` 키 없음)이면 **복원 함수 하나**를 거친다 —
    /// 앱 시작, `reloadFromDisk`, `mutateFresh`, CLI 가 모두 이 경로를 쓴다(설계 4.4-4, 6회차 P1-1).
    static func load(env: MobiusEnvironment,
                     memory: AccountsFile?) throws -> (AccountsFile?, restored: Bool) {
        // 파일이 **없을 때만** nil. 있는데 읽지 못하면(권한, I/O) throw — nil 로 삼키면
        // `mutateFresh` 가 메모리 사본으로 전체 파일을 덮어써 다른 프로세스의 변경을 지운다
        // (리뷰 1회차 Codex P1-2). "없음"은 `fileExists` 가 아니라 **읽기 오류의 종류**로 판정한다 —
        // `fileExists` 는 상위 디렉터리를 탐색할 수 없을 때도 false 라서, 권한 오류를 없음으로 삼킨다
        // (리뷰 5회차 Codex P1-1).
        let data: Data
        do {
            data = try Data(contentsOf: env.accountsFile)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (nil, false)
        }
        let decoded: AccountsFile
        do {
            decoded = try JSONDecoder().decode(AccountsFile.self, from: data)
        } catch {
            // 방어: 디코드 실패 시 원본을 백업해 둔다 — 빈 스토어로 시작한 앱이 이후 저장으로
            // 원본을 덮어써도 계정 데이터가 영구 유실되지 않도록(복구 가능).
            // 저장을 막은 동안 15초마다 다시 읽으므로, 같은 내용이면 다시 쓰지 않는다.
            let backup = corruptBackupURL(env: env)
            if (try? Data(contentsOf: backup)) != data { try? data.write(to: backup, options: .atomic) }
            throw error
        }
        guard AccountsFile.lacksExtraProviderKey(data) else { return (decoded, false) }
        let (restored, did) = restoringAfterLegacySave(decoded, memory: memory, env: env)
        return (restored, did)
    }

    /// 구버전이 저장한 파일에서 Antigravity 계정을 되살린다(순수에 가까운 함수 — secrets 디렉터리만 읽는다).
    /// - Claude·Codex 는 디스크 값 그대로.
    /// - Antigravity 프로필과 순서는 **메모리 값**(앱이 떠 있는 동안 — primary 가 바뀌지 않게).
    ///   메모리에 없으면 `secrets/` 의 프로필 없는 파일 가운데 Antigravity 형태인 것을 수정 시각 순으로.
    ///   `*.bak` 과 `.removed` 표시가 있는 UUID 는 건너뛰고, 같은 이메일은 한 번만.
    /// - Antigravity 자동 전환 설정은 **꺼짐**(사용자가 끈 설정이 다시 켜지지 않게 — 5회차 P1-5).
    /// - Antigravity 활성은 비워 둔다 — 라이브를 읽는 reconcile 이 채운다.
    /// 반환의 Bool 은 "복원한 Antigravity 계정이 있는가"(사용자 알림용).
    public static func restoringAfterLegacySave(_ disk: AccountsFile, memory: AccountsFile?,
                                                env: MobiusEnvironment) -> (AccountsFile, Bool) {
        var out = disk
        let restoredProvider = Provider.antigravity
        // 메모리에서 가져오는 프로필에도 `.removed` 표시를 적용한다 — 다른 인스턴스가 지운 계정이
        // 앱 메모리에 남아 있다가 되살아나지 않게(리뷰 1회차 Codex P2-5).
        let removed = removalMarkedIDs(env: env)
        var restored: [AccountProfile] = (memory?.accounts(of: restoredProvider) ?? [])
            .filter { !removed.contains($0.id) }
        var ids = Set(out.accounts.map(\.id)).union(restored.map(\.id))
        var emails = Set(restored.map(\.emailAddress))
        for (id, data) in orphanSecrets(env: env, knownIDs: ids) {
            guard let cred = AntigravitySecret.parse(data), !emails.contains(cred.email) else { continue }
            restored.append(AccountProfile(
                id: id, provider: restoredProvider,
                nickname: String(cred.email.split(separator: "@").first ?? "account"),
                emailAddress: cred.email, organizationName: "", tierDescription: ""))
            ids.insert(id); emails.insert(cred.email)
        }
        out.accounts.removeAll { $0.provider == restoredProvider }
        out.accounts.append(contentsOf: restored)
        out.activeByProvider[restoredProvider] = nil
        out.autoSwitchedByProvider[restoredProvider] = nil
        out.autoSwitchByProvider[restoredProvider] = false
        return (out, !restored.isEmpty)
    }

    /// `secrets/` 의 프로필 없는 secret 파일(UUID 이름, `.bak` 제외, `.removed` 표시 제외) —
    /// 파일 수정 시각 순.
    /// `secrets/<uuid>.removed` 표시가 있는 UUID.
    static func removalMarkedIDs(env: MobiusEnvironment) -> Set<UUID> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: env.secretsDir.path)
        else { return [] }
        return Set(names.compactMap { name -> UUID? in
            guard name.hasSuffix(".removed") else { return nil }
            return UUID(uuidString: String(name.dropLast(".removed".count)))
        })
    }

    static func orphanSecrets(env: MobiusEnvironment, knownIDs: Set<UUID>) -> [(UUID, Data)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: env.secretsDir.path) else { return [] }
        let removed = removalMarkedIDs(env: env)
        var found: [(UUID, Date, Data)] = []
        for name in names where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(".json".count))),
                  !knownIDs.contains(id), !removed.contains(id) else { continue }
            let url = env.secretFile(for: id)
            guard let data = try? Data(contentsOf: url) else { continue }
            let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            found.append((id, mtime, data))
        }
        return found.sorted { $0.1 < $1.1 }.map { ($0.0, $0.2) }
    }

    /// 디스크에서 다시 읽는다(CLI 등 외부 프로세스 변경 반영). 구버전 저장 뒤면 메모리의
    /// Antigravity 프로필 순서로 복원한다. 활성 값이나 활성 리비전이 달라졌으면 세대를 늘린다.
    /// 읽기에 실패하면(파일은 있다) throw 하고 **저장을 막는다** — 다음 다시 읽기가 성공할 때까지
    /// (리뷰 2회차 Codex P1-1). 파일이 없으면 메모리를 그대로 두고 막음을 푼다.
    public func reloadFromDisk() throws {
        lock.lock(); defer { lock.unlock() }
        let loaded: AccountsFile?, restored: Bool
        do {
            (loaded, restored) = try Self.load(env: env, memory: _file)
        } catch {
            stateLock.withLock { _loadFailure = error }
            throw error
        }
        stateLock.withLock {
            _loadFailure = nil
            if restored { _restoredAfterLegacySave = true }
        }
        guard let loaded else { return }
        adoptLocked(loaded)
    }

    /// 디스크의 현재 파일을 (같은 복원 함수를 거쳐) 읽기만 한다. 메모리는 바꾸지 않는다 —
    /// 자동 전환이 쓰기 직전에 다른 프로세스의 활성 리비전·설정 변경을 확인하는 데 쓴다(설계 4.7).
    /// 파일이 없으면 nil. 읽기에 실패하면(파일은 있다) nil 을 돌려주고 **저장을 막는다** — `commit(fresh:)` 와
    /// 같은 규칙이다. 확인만 멈추면 뒤이은 비-fresh 저장이 메모리 사본으로 다른 프로세스의 변경을 덮는다
    /// (리뷰 4회차 Codex P1-3·Claude P3-2). 성공해도 막음을 풀지는 않는다 — 메모리를 바꾸지 않으므로
    /// 메모리가 디스크를 나타낸다는 근거가 아니다(풀기는 `reloadFromDisk`).
    public func peekDisk() -> AccountsFile? {
        let memory = file
        do {
            return try Self.load(env: env, memory: memory).0
        } catch {
            // 실패 기록은 저장 직렬화 잠금(`lock`) 안에서 한다 — 저장 차단 검사를 이미 통과한 저장이 진행 중이면
            // 그 저장이 끝난 뒤에 기록되고, 기록 뒤에 시작하는 저장은 모두 막힌다. 기록이 저장의 검사와 쓰기
            // 사이에 끼지 않는다(리뷰 5회차 Codex P1-2). 읽기 자체는 잠금 밖이라 정상 경로는 저장을 기다리지 않는다.
            lock.withLock { stateLock.withLock { _loadFailure = error } }
            return nil
        }
    }

    /// 메모리의 활성 값만 바꾼다 — **파일에 저장하지 않는다**. 구버전 저장 직후 CLI 읽기 전용 명령이
    /// 라이브 신원을 보여 줄 때만 쓴다(`Switcher.reflectLiveActiveWithoutSaving`).
    public func setActiveInMemoryOnly(_ id: UUID?, provider: Provider) {
        lock.withLock {
            var next = _file
            next.activeByProvider[provider] = id
            adoptLocked(next)
        }
    }

    /// 앱이 복원 알림을 보낸 뒤 내린다.
    public func acknowledgeLegacyRestore() {
        stateLock.withLock { _restoredAfterLegacySave = false }
    }

    /// 디스크에서 다시 읽은 상태로 교체 (테스트·호환용 — 앱은 `reloadFromDisk` 를 쓴다)
    public func replaceFile(with newFile: AccountsFile) throws {
        lock.lock(); defer { lock.unlock() }
        adoptLocked(newFile)
    }

    /// `lock` 을 쥔 채 부른다. 메모리 교체와 세대 갱신은 `stateLock` 안에서 한 번에 한다.
    private func adoptLocked(_ next: AccountsFile) {
        stateLock.withLock {
            for p in Provider.allCases where _file.activeByProvider[p] != next.activeByProvider[p]
                || _file.activeRevision(p) != next.activeRevision(p) {
                generations[p, default: 0] += 1
            }
            _file = next
        }
    }

    // MARK: 활성 세대

    public func activeGeneration(of provider: Provider) -> Int {
        stateLock.withLock { generations[provider] ?? 0 }
    }

    /// 라이브 값의 지문을 알린다. 직전에 알린 지문과 다르면(같은 이메일 재로그인, 로그아웃 등)
    /// 활성 세대를 늘린다. 처음 알리는 지문은 기준만 잡는다. 반환: 알린 뒤의 세대 번호.
    @discardableResult
    public func noteLiveFingerprint(_ fingerprint: Data?, provider: Provider) -> Int {
        stateLock.withLock {
            if let previous = notedFingerprints[provider], previous != fingerprint {
                generations[provider, default: 0] += 1
            }
            notedFingerprints[provider] = .some(fingerprint)
            return generations[provider] ?? 0
        }
    }

    // MARK: 저장

    public func save() throws {
        lock.lock(); defer { lock.unlock() }
        try ensureSavesAllowed()
        try write(_file)
    }

    private func ensureSavesAllowed() throws {
        if stateLock.withLock({ _loadFailure != nil }) {
            throw AccountStoreError.savesBlockedAfterLoadFailure
        }
    }

    private func write(_ f: AccountsFile) throws {
        let data = try JSONEncoder().encode(f)
        try FileManager.default.createDirectory(at: env.appSupportDir,
                                                withIntermediateDirectories: true)
        // 커밋 시점은 원자 교체(rename)다. 그 뒤의 권한 설정 실패는 저장 실패로 보지 않는다
        // (설계 4.5) — 이미 바뀐 파일을 "실패"로 보고하면 호출자가 메모리를 되돌려 어긋난다.
        try data.write(to: env.accountsFile, options: .atomic)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: env.accountsFile.path)
        } catch {
            NSLog("Mobius: accounts.json 권한 설정 실패(저장은 완료): \(error)")
        }
    }

    /// 모든 변경의 단일 경로. 변경을 새 사본에 적용해 **저장에 성공한 뒤에만** 메모리를 바꾼다 —
    /// 저장이 실패하면 메모리도 그대로다(설계 4.5 「setActive 는 저장이 실패하면 메모리의 활성
    /// 값도 되돌린다」). 활성 값이 바뀐 풀은 활성 리비전을 1 늘린다.
    ///
    /// - Parameter fresh: true 면 저장 직전에 **디스크의 파일을 다시 읽어** 그 위에 변경만 얹는다
    ///   (`mutateFresh`). Antigravity 프로필과 풀 상태를 바꾸는 모든 저장이 이 경로다 — 앱과 CLI 가
    ///   각자 메모리의 전체 목록을 저장하는 경합의 창을 줄인다(설계 3절, 없애지는 못한다).
    @discardableResult
    private func commit<T>(fresh: Bool, _ body: (inout AccountsFile) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try ensureSavesAllowed()
        var base = _file
        if fresh {
            let loaded: AccountsFile?, restored: Bool
            do {
                (loaded, restored) = try Self.load(env: env, memory: _file)
            } catch {
                // 저장 중 확인한 읽기 오류도 다시 읽기에 성공할 때까지 저장을 막는다 — 이 호출만 멈추면
                // 다음 비-fresh 저장이 메모리 사본으로 다른 프로세스의 변경을 덮는다(리뷰 3회차 Codex P1-1).
                stateLock.withLock { _loadFailure = error }
                throw error
            }
            if let loaded {
                if restored { stateLock.withLock { _restoredAfterLegacySave = true } }
                base = loaded
            }
        }
        var next = base
        let result = try body(&next)
        for p in Provider.allCases where base.activeByProvider[p] != next.activeByProvider[p] {
            next.activeRevisionByProvider[p] = base.activeRevision(p) + 1
        }
        try write(next)
        adoptLocked(next)
        return result
    }

    /// 프로바이더 단위 변경: Antigravity 면 디스크를 다시 읽어 얹는다.
    @discardableResult
    private func commit<T>(_ provider: Provider?, _ body: (inout AccountsFile) throws -> T) throws -> T {
        try commit(fresh: provider == .antigravity, body)
    }

    /// 디스크의 최신 파일 위에 변경을 얹어 저장한다(설계 3절 `mutateFresh`).
    @discardableResult
    public func mutateFresh<T>(_ body: (inout AccountsFile) throws -> T) throws -> T {
        try commit(fresh: true, body)
    }

    private func provider(of id: UUID) -> Provider? {
        file.accounts.first { $0.id == id }?.provider
    }

    // MARK: 프로필

    /// (provider, 계정 열쇠)로 기존 프로필을 찾아 갱신하거나 새로 만든다. 열쇠는 이메일 + 조직이다 —
    /// 같은 이메일이라도 조직이 다르면 **다른 프로필**이 된다(`AccountKey`, 실패 기록 23).
    /// 그 프로바이더의 첫 계정은 자동 활성.
    @discardableResult
    public func upsertProfile(nickname: String, provider: Provider,
                              identity: ProviderIdentity, secretData: Data) throws -> AccountProfile {
        // 구버전 키체인 항목 정리는 저장 잠금을 놓은 **뒤에** 한다 — 키체인 호출이 멈추면 다른 저장
        // (메인 액터의 설정 저장 등)이 그만큼 기다리게 된다(리뷰 2회차 Codex P1-4).
        let profile = try commit(provider) { file -> AccountProfile in
            var profile: AccountProfile
            if let idx = file.firstIndex(provider: provider, matching: identity.key) {
                file.accounts[idx].nickname = nickname
                file.accounts[idx].organizationName = identity.organizationName
                file.accounts[idx].tierDescription = identity.tierDescription
                file.accounts[idx].needsReauth = false
                if !identity.organizationUuid.isEmpty {
                    // 조직을 모르던 구버전 프로필이 이메일로 맞았으면 이번 신원의 조직을 채운다 —
                    // 다음부터는 같은 이메일의 다른 조직이 이 프로필을 잡지 못한다.
                    file.accounts[idx].organizationUuid = identity.organizationUuid
                }
                profile = file.accounts[idx]
            } else {
                profile = AccountProfile(id: UUID(), provider: provider, nickname: nickname,
                                         emailAddress: identity.emailAddress,
                                         organizationName: identity.organizationName,
                                         tierDescription: identity.tierDescription,
                                         organizationUuid: identity.organizationUuid)
                file.accounts.append(profile)
                if file.activeByProvider[provider] == nil {
                    file.activeByProvider[provider] = profile.id
                }
            }
            try writeSecretSnapshot(secretData, for: profile.id)
            return profile
        }
        cleanUpLegacyKeychainItem(for: profile.id, provider: provider)
        return profile
    }

    /// Claude 편의 경로 — 스냅샷에서 신원을 추출해 등록한다 (CLI capture·LoginFlow용).
    @discardableResult
    public func upsertProfile(nickname: String, snapshot: CredentialsSnapshot) throws -> AccountProfile {
        guard let identity = ClaudeConfigIO.identity(fromSnapshot: snapshot) else {
            throw AccountStoreError.snapshotMissingEmail
        }
        return try upsertProfile(nickname: nickname, provider: .claude, identity: identity,
                                 secretData: try JSONEncoder().encode(snapshot))
    }

    // MARK: 비밀 스냅샷 (0700 파일 — Claude Code의 .credentials.json과 동일 보안 수준)
    // 내용물은 프로바이더가 정한 직렬화 바이트 (ProviderConfigIO 참조). 스토어는 해석하지 않는다.

    public func secretData(for id: UUID) throws -> Data? {
        // 1순위: 파일. 승인창 없음. 잠금은 파일 읽기 동안만 쥔다.
        if let data = secretLock.withLock({ try? Data(contentsOf: env.secretFile(for: id)) }) {
            return data
        }
        // 2순위: 구버전 Keychain 항목(Claude 시절) → 발견 시 파일로 이관하고 Keychain 항목 제거
        //        (한 번만 승인창이 뜨고, 이후로는 파일에서 읽어 다시 뜨지 않는다).
        // ★ 구버전 항목은 **등록된 Claude 계정**의 스냅샷뿐이다 — 다른 프로바이더 계정과 등록되지 않은 ID
        //   (그사이 지운 agy 후보)는 키체인을 찾지 않는다(리뷰 3회차 Codex P1-4, 4회차 Codex P1-4: 시간 제한
        //   없는 키체인 읽기에 메인 액터가 묶이지 않게).
        // ★ 키체인 읽기·삭제는 저장 잠금(`lock`, `secretLock`)을 쥐지 않고 한다 — 승인창 등으로 멈춰도 다른
        //   계정의 비밀 읽기와 저장이 기다리지 않게(리뷰 3회차 Codex P1-4·Claude P3-3). 같은 계정의 이관만
        //   계정별 잠금으로 합친다 — 겹친 호출이 키체인을 두 번 읽어 승인창이 두 번 뜨지 않게(4회차 Claude P3-3).
        guard provider(of: id) == .claude else { return nil }
        return try legacyMigrationLock(for: id).withLock { () throws -> Data? in
            // 앞선 이관이 끝났으면 그 파일을 읽는다.
            if let data = secretLock.withLock({ try? Data(contentsOf: env.secretFile(for: id)) }) {
                return data
            }
            guard let data = ((try? keychain.read(service: Self.secretService(for: id),
                                                  account: Self.secretAccount)) ?? nil) else { return nil }
            _ = try JSONDecoder().decode(CredentialsSnapshot.self, from: data) // 형식 검증
            // 그사이 새 스냅샷이 저장됐으면 그 파일을 우선한다(구버전 값으로 덮지 않는다).
            let current: Data? = secretLock.withLock {
                if let existing = try? Data(contentsOf: env.secretFile(for: id)) { return existing }
                try? writeSecretFile(data, for: id)
                return nil
            }
            cleanUpLegacyKeychainItem(for: id, provider: .claude)
            return current ?? data
        }
    }

    public func setSecretData(_ data: Data, for id: UUID) throws {
        try writeSecretSnapshot(data, for: id)
        cleanUpLegacyKeychainItem(for: id, provider: provider(of: id))
    }

    /// 혹시 남아 있을 수 있는 구버전 Keychain 항목은 정리 (승인창 재발 방지). 어떤 잠금도 쥐지 않고
    /// 부른다 — 키체인 호출이 멈춰도 메타데이터 읽기·저장과 비밀 파일 읽기가 기다리지 않게.
    /// 구버전 항목은 Claude 스냅샷뿐이므로 다른 프로바이더는 `security delete` 를 띄우지 않는다
    /// (리뷰 4회차 Claude P3-4).
    private func cleanUpLegacyKeychainItem(for id: UUID, provider: Provider?) {
        guard provider == .claude else { return }
        try? keychain.delete(service: Self.secretService(for: id), account: Self.secretAccount)
    }

    private func legacyMigrationLock(for id: UUID) -> NSLock {
        credentialLocksGuard.lock(); defer { credentialLocksGuard.unlock() }
        if let existing = legacyMigrationLocks[id] { return existing }
        let l = NSLock()
        legacyMigrationLocks[id] = l
        return l
    }

    /// 비밀 스냅샷 파일만 쓴다(직전 값은 `.bak`).
    private func writeSecretSnapshot(_ data: Data, for id: UUID) throws {
        secretLock.lock(); defer { secretLock.unlock() }
        // 덮어쓰기 전 기존 스냅샷을 .bak으로 보존 — 회전 토큰 저장 중 프로세스가 죽거나 새 바이트가
        // (검증을 통과했더라도) 문제가 있을 때 직전 스냅샷으로 복구할 여지를 남긴다.
        let url = env.secretFile(for: id)
        if let existing = try? Data(contentsOf: url) {
            let bak = url.appendingPathExtension("bak")
            try? existing.write(to: bak, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bak.path)
        }
        try writeSecretFile(data, for: id)   // 원자(temp→rename) + 0600
    }

    /// 계정별 credential lock으로 body를 감싼다 (동기 — await를 가로지르지 않는 짧은 구간만).
    /// refresher 저장 시퀀스와 Switcher.switchTo가 같은 id에서 상호 배제되어, 전환이 회전 직전
    /// 스냅샷을 라이브에 설치하지 못하게 한다. 락 순서: credential lock → (store lock / secret lock).
    @discardableResult
    public func withCredentialLock<T>(_ id: UUID, _ body: () throws -> T) rethrows -> T {
        let l = credentialLock(for: id)
        l.lock(); defer { l.unlock() }
        return try body()
    }

    private func credentialLock(for id: UUID) -> NSLock {
        credentialLocksGuard.lock(); defer { credentialLocksGuard.unlock() }
        if let existing = credentialLocks[id] { return existing }
        let l = NSLock()
        credentialLocks[id] = l
        return l
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

    /// 지정 계정을 자기 프로바이더 풀의 활성으로 표시한다. 저장이 실패하면 메모리도 그대로다.
    /// 반환: 이 저장이 활성 값을 **실제로 바꿨는가**(저장 직전 기준 — Antigravity 는 디스크를 다시 읽은
    /// 값 기준). 대사가 "라이브를 따라 활성을 바꿨다"를 보고하는 데 쓴다(리뷰 2회차 Claude P3-1).
    @discardableResult
    public func setActive(_ id: UUID) throws -> Bool {
        try setActiveReportingPrevious(id).changed
    }

    /// `setActive` 와 같고, 저장 직전의 활성 값도 돌려준다 — 대사가 "비어 있던 활성을 채운 것"(구버전 저장 뒤
    /// 복원)과 "다른 계정에서 바꾼 것"을 가르는 데 쓴다(리뷰 4회차 Codex P3·Claude P3-1).
    @discardableResult
    public func setActiveReportingPrevious(_ id: UUID) throws -> (changed: Bool, previous: UUID?) {
        try commit(provider(of: id)) { file in
            guard let profile = file.accounts.first(where: { $0.id == id }) else {
                throw AccountStoreError.unknownAccount
            }
            let previous = file.activeByProvider[profile.provider]
            file.activeByProvider[profile.provider] = id
            return (previous != id, previous)
        }
    }

    /// provider 기본값 없음 — 풀을 바꾸는 연산은 대상 풀을 항상 명시한다 (오라우팅 방지).
    public func setAutoSwitch(_ enabled: Bool, provider: Provider) throws {
        try commit(provider) { $0.autoSwitchByProvider[provider] = enabled }
    }

    public func setDesktopSync(_ enabled: Bool) throws {
        try commit(nil) { $0.desktopSyncEnabled = enabled }
    }

    /// 현재 fallback 활성이 자동 전환의 결과인지 기록 — 파일로 영속되므로
    /// CLI 전환(별 프로세스)·앱 재시작 후에도 onTick 복귀 판단이 올바르다.
    /// provider 기본값 없음 — 풀을 바꾸는 연산은 대상 풀을 항상 명시한다 (오라우팅 방지).
    public func setAutoSwitchedFromPrimary(_ flagged: Bool, provider: Provider) throws {
        try commit(provider) { $0.autoSwitchedByProvider[provider] = flagged }
    }

    public func setDesktopAutoSwitch(_ enabled: Bool) throws {
        try commit(nil) { $0.desktopAutoSwitchEnabled = enabled }
    }

    /// fallback(프로바이더 풀 내 인덱스 1 이상)끼리만 재배열. primary(0)는 고정.
    /// 인덱스는 해당 프로바이더 계정 목록 기준이다.
    public func moveFallback(provider: Provider, fromIndex: Int, toIndex: Int) throws {
        try commit(provider) { file in
            var group = file.accounts.filter { $0.provider == provider }
            guard fromIndex >= 1, toIndex >= 1,
                  fromIndex < group.count, toIndex < group.count else {
                throw AccountStoreError.cannotMovePrimary
            }
            let item = group.remove(at: fromIndex)
            group.insert(item, at: toIndex)
            Self.replaceGroup(&file, provider, with: group)
        }
    }

    /// 프로바이더 그룹을 재배열 결과로 치환한다 — 전체 배열에서 그 프로바이더가 차지하던
    /// 위치들은 유지하고 내용만 새 순서로 채운다 (타 프로바이더 계정 순서 불변).
    private static func replaceGroup(_ file: inout AccountsFile, _ provider: Provider,
                                     with group: [AccountProfile]) {
        var it = group.makeIterator()
        file.accounts = file.accounts.map { $0.provider == provider ? it.next()! : $0 }
    }

    /// 재로그인 필요 마킹/해제. 변화 없으면 저장하지 않는다.
    public func setNeedsReauth(_ id: UUID, _ flag: Bool) throws {
        guard let current = file.accounts.first(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        guard current.needsReauth != flag else { return }
        try update(id) { $0.needsReauth = flag }
    }

    /// 임계값 선제 경고(advisory) 마킹/해제. **변화 없으면 저장하지 않는다** —
    /// setNeedsReauth와 같은 모양(락·조회·동등성 스킵·변경·저장)을 그대로 따른다.
    /// ★ 동등성 스킵은 미세 최적화가 아니라 필수다: 이 setter는 5분 폴링마다 호출되므로
    ///   무조건 쓰면 accounts.json이 앱이 켜져 있는 내내 다시 쓰인다.
    public func setAdvisory(_ id: UUID, _ record: AdvisoryRecord?) throws {
        guard let current = file.accounts.first(where: { $0.id == id }) else {
            throw AccountStoreError.unknownAccount
        }
        guard current.advisory != record else { return }
        try update(id) { $0.advisory = record }
    }

    /// 지정 계정에만 사용자 핀을 세운다(같은 프로바이더 풀의 나머지는 해제). 수동 전환 시 호출 —
    /// 모델 전용 한도(Fable 등)로 이 계정을 자동으로 밀어내지 않게 한다.
    /// ★ 핀 해제는 반드시 같은 풀로 한정한다 — 전역 clear는 Codex 계정을 수동 전환할 때
    ///   사용자가 골라둔 Claude 계정의 핀까지 풀어 modelScoped 한도에서 의도치 않은 자동 전환을
    ///   유발한다(풀은 독립이므로 핀도 풀별 독립이어야 한다).
    /// ★ pinnedAt은 **매 호출 갱신한다 — 이미 핀된 계정을 다시 핀해도 마찬가지.** 핀 플래그만으로는
    ///   "임계값 경고를 보고 나서 일부러 이 계정으로 돌아왔다"와 "몇 시간 전에 그냥 눌러뒀다"를
    ///   구분할 수 없다. advisory 전환은 pinnedAt이 advisory.detectedAt보다 **나중일 때만** 거부되므로,
    ///   갱신을 빠뜨리면 옛 핀이 새 경고까지 영구히 거부해 선제 전환이 죽는다.
    public func setUserPinned(_ id: UUID, at now: Date = Date()) throws {
        guard let provider = provider(of: id) else { throw AccountStoreError.unknownAccount }
        try commit(provider) { file in
            for i in file.accounts.indices where file.accounts[i].provider == provider {
                let want = file.accounts[i].id == id
                // 대상은 항상 now로 스탬프(재핀도 갱신), 나머지는 플래그·타임스탬프를 함께 해제.
                file.accounts[i].userPinned = want
                file.accounts[i].pinnedAt = want ? now : nil
            }
        }
    }

    /// 지정 계정을 자기 프로바이더 풀의 primary(첫 자리)로 승격. 기존 primary는 첫
    /// fallback으로 내려간다. primary 기준이 바뀌므로 그 풀의 autoSwitchedFromPrimary는
    /// 리셋 — 옛 primary 체제에서의 자동 복귀 예약이 새 primary로 오귀속되지 않도록.
    public func setPrimary(_ id: UUID) throws {
        guard let provider = provider(of: id) else { throw AccountStoreError.unknownAccount }
        try commit(provider) { file in
            guard let profile = file.accounts.first(where: { $0.id == id }) else {
                throw AccountStoreError.unknownAccount
            }
            var group = file.accounts.filter { $0.provider == profile.provider }
            guard group.first?.id != id else { return } // 이미 primary — 변경 없음
            group.removeAll { $0.id == id }
            group.insert(profile, at: 0)
            Self.replaceGroup(&file, profile.provider, with: group)
            file.autoSwitchedByProvider[profile.provider] = false
        }
    }

    /// 삭제 표시 파일 — 구버전이 저장한 뒤에도 "지운 계정"이 복원으로 되살아나지 않게 한다(설계 4.4-4).
    func removalMarker(for id: UUID) -> URL {
        env.secretsDir.appendingPathComponent("\(id.uuidString).removed")
    }

    public func remove(_ id: UUID) throws {
        guard let provider = provider(of: id) else { throw AccountStoreError.unknownAccount }
        // 이 호출이 새로 만든 표시만 실패 때 거둔다 — 다른 인스턴스가 먼저 지우며 남긴 표시는 건드리지 않는다
        // (리뷰 5회차 Codex P2-1).
        var createdMarker = false
        if !provider.isLegacyArrayCompatible,
           !FileManager.default.fileExists(atPath: removalMarker(for: id).path) {
            // secret 을 지우기 **전에** 표시를 쓴다 — 지우다 실패해 남은 secret 도 복원되지 않게.
            try FileManager.default.createDirectory(at: env.secretsDir,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: removalMarker(for: id), options: .atomic)
            createdMarker = true
        }
        do {
            try commit(provider) { file in
                // 디스크를 다시 읽은 사본(Antigravity)에 대상이 없으면 이미 지워진 것이다 — 다른 인스턴스가 지웠거나,
                // 구버전 저장 뒤 복원이 방금 쓴 표시를 보고 뺐다. 실패로 보지 않고 삭제를 마저 끝낸다
                // (리뷰 5회차 Claude P2-1·Codex P2-1).
                guard let profile = file.accounts.first(where: { $0.id == id }) else { return }
                file.accounts.removeAll { $0.id == id }
                if file.activeByProvider[profile.provider] == id {
                    file.activeByProvider[profile.provider] =
                        file.accounts.first { $0.provider == profile.provider }?.id
                }
            }
        } catch {
            // 삭제가 저장되지 않았으면(저장 거부 등) 표시도 거둔다 — 남은 계정이 다음 복원에서 빠지지 않게
            // (리뷰 4회차 Codex P2 의 같은 흐름).
            if createdMarker { try? FileManager.default.removeItem(at: removalMarker(for: id)) }
            throw error
        }
        try? FileManager.default.removeItem(at: env.secretFile(for: id))
        try? FileManager.default.removeItem(at: env.secretFile(for: id).appendingPathExtension("bak"))
        cleanUpLegacyKeychainItem(for: id, provider: provider)
    }

    public func update(_ id: UUID, _ mutate: (inout AccountProfile) -> Void) throws {
        try commit(provider(of: id)) { file in
            guard let idx = file.accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountStoreError.unknownAccount
            }
            mutate(&file.accounts[idx])
        }
    }
}
