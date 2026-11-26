import XCTest
@testable import MobiusCore

/// 설계 4.4-6 다운그레이드 호환, 4.4-4 복원 함수(네 진입점), 활성 리비전·세대, 저장 실패 시 메모리.
final class AntigravityStoreCompatTests: XCTestCase {
    var env: MobiusEnvironment!
    let kc = InMemoryKeychain()

    override func setUp() {
        env = AgyFixtures.tempEnv()
    }

    private func codexIdentity(_ email: String) -> ProviderIdentity {
        ProviderIdentity(emailAddress: email, organizationName: "", tierDescription: "Plus")
    }
    private func agyIdentity(_ email: String) -> ProviderIdentity {
        ProviderIdentity(emailAddress: email, organizationName: "", tierDescription: "")
    }

    /// Claude 1 + Codex 2 + Antigravity 2 로 채운 스토어.
    private func populated() throws -> (AccountStore, [AccountProfile]) {
        let store = try AccountStore(env: env, keychain: kc)
        let c = try store.upsertProfile(nickname: "cl", snapshot: CredentialsSnapshot(
            keychainBlob: Data("{}".utf8), credentialsFileData: Data("{}".utf8),
            oauthAccountJSON: try JSONSerialization.data(withJSONObject: ["emailAddress": "cl@x.com"])))
        let x1 = try store.upsertProfile(nickname: "x1", provider: .codex, identity: codexIdentity("x1@c.com"),
                                         secretData: CodexFixtures.authJSON(email: "x1@c.com"))
        let x2 = try store.upsertProfile(nickname: "x2", provider: .codex, identity: codexIdentity("x2@c.com"),
                                         secretData: CodexFixtures.authJSON(email: "x2@c.com"))
        let g1 = try store.upsertProfile(nickname: "g1", provider: .antigravity, identity: agyIdentity("g1@gmail.com"),
                                         secretData: AgyFixtures.secret("g1@gmail.com"))
        let g2 = try store.upsertProfile(nickname: "g2", provider: .antigravity, identity: agyIdentity("g2@gmail.com"),
                                         secretData: AgyFixtures.secret("g2@gmail.com"))
        try store.setActive(x2.id)
        try store.setActive(g2.id)
        try store.setAutoSwitch(true, provider: .antigravity)
        return (store, [c, x1, x2, g1, g2])
    }

    // (a) 0.5.3 형식 파일을 새 버전이 읽는다
    func testReadsV053File() throws {
        let c = V053AccountProfile(id: UUID(), provider: .claude, nickname: "c", emailAddress: "c@x.com",
                                   organizationName: "", tierDescription: "")
        let x = V053AccountProfile(id: UUID(), provider: .codex, nickname: "x", emailAddress: "x@c.com",
                                   organizationName: "", tierDescription: "")
        var old = V053AccountsFile(accounts: [c, x], activeAccountID: c.id)
        old.activeByProvider[.codex] = x.id
        try FileManager.default.createDirectory(at: env.appSupportDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: env.accountsFile)
        let store = try AccountStore(env: env, keychain: kc)
        XCTAssertEqual(store.file.accounts.map(\.id), [c.id, x.id])
        XCTAssertEqual(store.file.activeByProvider[.codex], x.id)
        XCTAssertFalse(store.file.isAutoSwitchEnabled(.antigravity), "기록 없는 Antigravity 풀은 꺼짐")
        XCTAssertTrue(store.file.isAutoSwitchEnabled(.codex))
        XCTAssertFalse(store.restoredAfterLegacySave, "복원할 Antigravity 계정이 없으면 알리지 않는다")
    }

    // (b) 새 버전이 쓴 파일을 0.5.3 디코더가 읽고 Claude·Codex 의 ID·순서·활성·풀 구분이 그대로다
    func testV053DecoderReadsNewFile() throws {
        let (store, p) = try populated()
        let data = try Data(contentsOf: env.accountsFile)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual((root["accounts"] as! [[String: Any]]).compactMap { $0["provider"] as? String },
                       ["claude", "codex", "codex"], "구버전이 읽는 배열에는 claude·codex 만")
        XCTAssertEqual((root["extraProviderAccounts"] as! [[String: Any]]).count, 2)
        let old = try JSONDecoder().decode(V053AccountsFile.self, from: data)
        XCTAssertEqual(old.accounts.map(\.id), [p[0].id, p[1].id, p[2].id])
        XCTAssertEqual(old.accounts.map(\.provider), [.claude, .codex, .codex])
        XCTAssertEqual(old.activeByProvider[.claude], p[0].id)
        XCTAssertEqual(old.activeByProvider[.codex], p[2].id)
        XCTAssertEqual(store.file.accounts(of: .antigravity).count, 2)
    }

    /// 같은 이메일의 두 Claude 조직(organizationUuid, v0.5.4 #25) + Codex 1 + Antigravity 1.
    private func populatedWithOrganizations() throws -> (AccountStore, [AccountProfile]) {
        let store = try AccountStore(env: env, keychain: kc)
        func claude(_ nick: String, org: String, name: String, tier: String) throws -> AccountProfile {
            try store.upsertProfile(nickname: nick, provider: .claude,
                                    identity: ProviderIdentity(emailAddress: "leo@x.com", organizationName: name,
                                                               tierDescription: tier, organizationUuid: org),
                                    secretData: Data("{}".utf8))
        }
        let team = try claude("leo", org: "org-team", name: "Acme", tier: "Team")
        let max = try claude("leo-max", org: "org-personal", name: "leo@x.com's Organization", tier: "Max 20x")
        let x = try store.upsertProfile(nickname: "x1", provider: .codex, identity: codexIdentity("x1@c.com"),
                                        secretData: CodexFixtures.authJSON(email: "x1@c.com"))
        let g = try store.upsertProfile(nickname: "g1", provider: .antigravity, identity: agyIdentity("g1@gmail.com"),
                                        secretData: AgyFixtures.secret("g1@gmail.com"))
        try store.setActive(max.id)
        return (store, [team, max, x, g])
    }

    // (b') 최신 릴리스(v0.5.4 = v0.5.5 모델)의 디코더가 새 파일을 읽고, 같은 이메일의 두 조직이 organizationUuid 로
    //      구분된 채 남는다(사용자 설치본이 v0.5.5 다).
    func testV054DecoderReadsNewFileWithOrganizations() throws {
        let (_, p) = try populatedWithOrganizations()
        let old = try JSONDecoder().decode(V054AccountsFile.self, from: Data(contentsOf: env.accountsFile))
        XCTAssertEqual(old.accounts.map(\.id), [p[0].id, p[1].id, p[2].id], "구버전 배열에는 claude·codex 만")
        XCTAssertEqual(old.accounts.map(\.organizationUuid), ["org-team", "org-personal", ""])
        XCTAssertEqual(old.firstAccount(provider: .claude,
                                        matching: V054AccountKey(emailAddress: "leo@x.com",
                                                                 organizationUuid: "org-team"))?.id, p[0].id)
        XCTAssertEqual(old.activeByProvider[.claude], p[1].id)
    }

    // (c') v0.5.4 가 다시 저장한 파일을 새 버전이 읽어도, 새 버전이 다시 저장해도 organizationUuid 가 남는다
    //      (이 브랜치를 v0.5.3 기준으로 띄우면 저장 때 그 필드를 버려 계정 구분이 깨졌다).
    func testOrganizationUuidSurvivesV054SaveAndNewRoundTrip() throws {
        let (_, p) = try populatedWithOrganizations()
        let legacy = try JSONDecoder().decode(V054AccountsFile.self, from: Data(contentsOf: env.accountsFile))
        try JSONEncoder().encode(legacy).write(to: env.accountsFile)   // v0.5.4 저장
        let fresh = try AccountStore(env: env, keychain: kc)
        XCTAssertTrue(fresh.restoredAfterLegacySave)
        XCTAssertEqual(fresh.file.accounts(of: .claude).map(\.organizationUuid), ["org-team", "org-personal"])
        XCTAssertEqual(fresh.file.accounts(of: .antigravity).map(\.id), [p[3].id], "Antigravity 는 secret 에서 복원")
        try fresh.setAutoSwitch(false, provider: .claude)               // 새 버전 저장
        let again = try JSONDecoder().decode(V054AccountsFile.self, from: Data(contentsOf: env.accountsFile))
        XCTAssertEqual(again.accounts.map(\.organizationUuid), ["org-team", "org-personal", ""])
        XCTAssertEqual(try AccountStore(env: env, keychain: kc).file.accounts(of: .claude).map(\.organizationUuid),
                       ["org-team", "org-personal"])
    }

    // (c) (b) 를 구버전이 다시 저장한 파일에서 새 버전이 secret 으로 복원하고 중복이 없다
    func testRestoresAfterLegacySaveFromSecrets() throws {
        let (store, p) = try populated()
        let legacy = try JSONDecoder().decode(V053AccountsFile.self, from: Data(contentsOf: env.accountsFile))
        try JSONEncoder().encode(legacy).write(to: env.accountsFile)   // 구버전 저장
        let lacks = AccountsFile.lacksExtraProviderKey(try Data(contentsOf: env.accountsFile))
        XCTAssertTrue(lacks)

        // 진입점 1: 앱 시작·CLI makeContext (= AccountStore.init)
        let fresh = try AccountStore(env: env, keychain: kc)
        XCTAssertTrue(fresh.restoredAfterLegacySave)
        let agy = fresh.file.accounts(of: .antigravity)
        XCTAssertEqual(Set(agy.map(\.emailAddress)), ["g1@gmail.com", "g2@gmail.com"])
        XCTAssertEqual(Set(agy.map(\.id)), Set([p[3].id, p[4].id]), "UUID 는 secret 파일 이름 그대로")
        XCTAssertEqual(fresh.file.accounts.count, 5, "중복이 생기지 않는다")
        XCTAssertFalse(fresh.file.isAutoSwitchEnabled(.antigravity), "자동 전환은 꺼짐으로(사용자가 끈 값이 되살아나지 않게)")
        XCTAssertNil(fresh.file.activeByProvider[.antigravity], "활성은 라이브 reconcile 이 채운다")
        XCTAssertEqual(fresh.file.activeByProvider[.codex], p[2].id)

        // 진입점 2: 앱이 떠 있는 동안 reload — 메모리 순서(primary 보존)
        try store.setPrimary(p[4].id)                       // 메모리: g2 가 primary
        try JSONEncoder().encode(legacy).write(to: env.accountsFile)
        try store.reloadFromDisk()
        XCTAssertEqual(store.file.accounts(of: .antigravity).map(\.id), [p[4].id, p[3].id])
        XCTAssertFalse(store.file.isAutoSwitchEnabled(.antigravity))
        XCTAssertTrue(store.restoredAfterLegacySave)

        // 진입점 3: mutateFresh — 디스크를 다시 읽어 그 위에 변경만 얹는다
        try JSONEncoder().encode(legacy).write(to: env.accountsFile)
        try store.mutateFresh { f in f.desktopSyncEnabled = false }
        XCTAssertEqual(store.file.accounts(of: .antigravity).map(\.id), [p[4].id, p[3].id])
        XCTAssertFalse(store.file.isAutoSwitchEnabled(.antigravity))
        XCTAssertFalse(AccountsFile.lacksExtraProviderKey(try Data(contentsOf: env.accountsFile)),
                       "새 버전 저장은 extraProviderAccounts 를 항상 쓴다")

        // 진입점 4: peekDisk(자동 전환의 디스크 확인)도 같은 함수를 지난다
        try JSONEncoder().encode(legacy).write(to: env.accountsFile)
        XCTAssertEqual(store.peekDisk()?.accounts(of: .antigravity).map(\.id), [p[4].id, p[3].id])
    }

    func testDeletedAccountIsNotRestored() throws {
        let (store, p) = try populated()
        try store.remove(p[3].id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.removalMarker(for: p[3].id).path))
        // secret 삭제가 실패해 파일이 남았다고 해도
        try store.setSecretData(AgyFixtures.secret("g1@gmail.com"), for: p[3].id)
        let legacy = try JSONDecoder().decode(V053AccountsFile.self, from: Data(contentsOf: env.accountsFile))
        try JSONEncoder().encode(legacy).write(to: env.accountsFile)
        let fresh = try AccountStore(env: env, keychain: kc)
        XCTAssertEqual(fresh.file.accounts(of: .antigravity).map(\.id), [p[4].id])
    }

    /// 리뷰 1회차 Codex P2-5: 메모리에서 가져오는 Antigravity 프로필에도 `.removed` 표시를 적용한다.
    func testInMemoryRestoreHonorsRemovalMarker() throws {
        let (app, p) = try populated()
        // 다른 새 버전 인스턴스(CLI)가 g1 을 지운다 — 앱 메모리에는 g1 이 남아 있다
        let other = try AccountStore(env: env, keychain: kc)
        try other.remove(p[3].id)
        XCTAssertEqual(app.file.accounts(of: .antigravity).count, 2)
        // 앱이 갱신하기 전에 구버전이 목록을 저장한다
        let legacy = try JSONDecoder().decode(V053AccountsFile.self, from: Data(contentsOf: env.accountsFile))
        try JSONEncoder().encode(legacy).write(to: env.accountsFile)
        try app.reloadFromDisk()
        XCTAssertEqual(app.file.accounts(of: .antigravity).map(\.id), [p[4].id], "지운 계정이 되살아나지 않는다")
        try JSONEncoder().encode(legacy).write(to: env.accountsFile)
        try app.mutateFresh { f in f.desktopSyncEnabled = false }
        XCTAssertEqual(app.file.accounts(of: .antigravity).map(\.id), [p[4].id])
    }

    /// 리뷰 1회차 Codex P1-2: 디스크 읽기가 실패하면(파일은 있다) 메모리 사본으로 덮어쓰지 않는다.
    func testMutateFreshDoesNotOverwriteWhenDiskReadFails() throws {
        let (app, _) = try populated()
        // 다른 프로세스가 Codex 계정을 추가했다
        let other = try AccountStore(env: env, keychain: kc)
        let x3 = try other.upsertProfile(nickname: "x3", provider: .codex, identity: codexIdentity("x3@c.com"),
                                         secretData: CodexFixtures.authJSON(email: "x3@c.com"))
        // 앱의 최신 파일 읽기만 실패한다(원자 교체는 디렉터리 권한이라 성공할 수 있다)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.accountsFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: env.accountsFile.path) }
        XCTAssertThrowsError(try app.mutateFresh { f in f.desktopSyncEnabled = false })
        XCTAssertThrowsError(try app.reloadFromDisk())
        XCTAssertNil(app.peekDisk())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.accountsFile.path)
        let disk = try AccountStore(env: env, keychain: kc)
        XCTAssertTrue(disk.file.accounts.contains { $0.id == x3.id }, "다른 프로세스가 더한 계정이 남아 있다")
    }

    /// 리뷰 2회차 Codex P1-1: 시작 때 읽지 못한(파일은 있다) 스토어는 다시 읽기에 성공할 때까지
    /// 어떤 저장도 하지 않는다 — 빈 목록으로 기존 Claude·Codex 목록을 덮지 않게(실패 기록 13).
    func testStoreThatFailedToLoadRefusesSavesUntilReloadSucceeds() throws {
        let (_, p) = try populated()
        let before = try Data(contentsOf: env.accountsFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.accountsFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: env.accountsFile.path) }
        let loadError: Error
        do { _ = try AccountStore(env: env, keychain: kc); XCTFail("읽기 실패는 throw"); return }
        catch { loadError = error }
        let app = AccountStore(env: env, keychain: kc, afterLoadFailure: loadError)
        XCTAssertNotNil(app.loadFailure)
        // 첫 틱의 자동 등록(Codex), 설정 저장, save() 모두 거부한다
        XCTAssertThrowsError(try app.upsertProfile(nickname: "x9", provider: .codex,
                                                   identity: codexIdentity("x9@c.com"),
                                                   secretData: CodexFixtures.authJSON(email: "x9@c.com"))) {
            XCTAssertEqual($0 as? AccountStoreError, .savesBlockedAfterLoadFailure)
        }
        XCTAssertThrowsError(try app.setAutoSwitch(false, provider: .claude))
        XCTAssertThrowsError(try app.save())
        XCTAssertThrowsError(try app.reloadFromDisk(), "아직 읽지 못한다")
        XCTAssertNotNil(app.loadFailure)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.accountsFile.path)
        XCTAssertEqual(try Data(contentsOf: env.accountsFile), before, "파일을 건드리지 않았다")
        // 다시 읽기에 성공하면 저장이 풀린다
        try app.reloadFromDisk()
        XCTAssertNil(app.loadFailure)
        XCTAssertEqual(Set(app.file.accounts.map(\.id)), Set(p.map(\.id)))
        try app.setAutoSwitch(false, provider: .claude)
    }

    /// 리뷰 2회차 Codex P1-1: 떠 있는 동안 다시 읽기에 실패해도(파일은 있다) 저장을 멈춘다.
    func testReloadFailureBlocksSavesUntilNextSuccessfulReload() throws {
        let (app, _) = try populated()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.accountsFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: env.accountsFile.path) }
        XCTAssertThrowsError(try app.reloadFromDisk())
        XCTAssertThrowsError(try app.setAutoSwitch(false, provider: .claude), "비-fresh 저장도 막는다")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.accountsFile.path)
        try app.reloadFromDisk()
        try app.setAutoSwitch(false, provider: .claude)
    }

    /// 리뷰 3회차 Codex P1-1: 저장 중(`mutateFresh`) 디스크 읽기에 실패해도 그 뒤의 저장을 막는다 —
    /// 그 호출만 멈추고 다음 비-fresh 저장이 메모리 사본으로 덮으면 다른 프로세스의 계정이 사라진다.
    func testReadFailureDuringFreshCommitBlocksLaterSaves() throws {
        let (app, _) = try populated()
        let other = try AccountStore(env: env, keychain: kc)
        let x3 = try other.upsertProfile(nickname: "x3", provider: .codex, identity: codexIdentity("x3@c.com"),
                                         secretData: CodexFixtures.authJSON(email: "x3@c.com"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.accountsFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: env.accountsFile.path) }
        XCTAssertThrowsError(try app.mutateFresh { f in f.desktopSyncEnabled = false })
        XCTAssertNotNil(app.loadFailure)
        XCTAssertThrowsError(try app.setAutoSwitch(false, provider: .claude)) {
            XCTAssertEqual($0 as? AccountStoreError, .savesBlockedAfterLoadFailure)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.accountsFile.path)
        XCTAssertTrue(try AccountStore(env: env, keychain: kc).file.accounts.contains { $0.id == x3.id })
    }

    /// 리뷰 3회차 Claude P3-2: 읽기 실패의 종류(권한·I/O 대 내용 손상)를 가려 알림 문구를 나눈다.
    func testLoadFailureKindDistinguishesCorruption() throws {
        _ = try populated()
        try Data("{not json".utf8).write(to: env.accountsFile)
        var loadError: Error?
        do { _ = try AccountStore(env: env, keychain: kc) } catch { loadError = error }
        let corrupt = AccountStore(env: env, keychain: kc, afterLoadFailure: try XCTUnwrap(loadError))
        XCTAssertEqual(corrupt.loadFailureKind, .corrupt(backup: env.accountsFile.deletingLastPathComponent()
            .appendingPathComponent("accounts.corrupt.json")))
        let unreadable = AccountStore(env: env, keychain: kc, afterLoadFailure: CocoaError(.fileReadNoPermission))
        XCTAssertEqual(unreadable.loadFailureKind, .unreadable)
        XCTAssertNil(AccountStore(env: env, keychain: kc, file: AccountsFile()).loadFailureKind)
    }

    /// 리뷰 3회차 Codex P1-4·Claude P3-3: 비밀 파일이 없는 계정의 구버전 키체인 조회가 멈춰도
    /// 다른 계정의 비밀 읽기와 저장은 기다리지 않는다. Antigravity 계정은 구버전 이관을 아예 하지 않는다.
    func testLegacyKeychainReadDoesNotHoldSecretLock() throws {
        let stalling = StallingReadKeychain()
        let store = try AccountStore(env: env, keychain: stalling)
        let g = try store.upsertProfile(nickname: "g1", provider: .antigravity, identity: agyIdentity("g1@gmail.com"),
                                        secretData: AgyFixtures.secret("g1@gmail.com"))
        let x = try store.upsertProfile(nickname: "x1", provider: .codex, identity: codexIdentity("x1@c.com"),
                                        secretData: CodexFixtures.authJSON(email: "x1@c.com"))
        let c = try store.upsertProfile(nickname: "c", snapshot: CredentialsSnapshot(
            keychainBlob: Data("{}".utf8), credentialsFileData: Data("{}".utf8),
            oauthAccountJSON: try JSONSerialization.data(withJSONObject: ["emailAddress": "c@x.com"])))
        try FileManager.default.removeItem(at: env.secretFile(for: g.id))
        try FileManager.default.removeItem(at: env.secretFile(for: c.id))
        // Antigravity: 구버전 이관을 하지 않으므로 키체인을 부르지 않고 바로 nil
        let reads = stalling.reads
        XCTAssertNil(try store.secretData(for: g.id))
        XCTAssertEqual(stalling.reads, reads, "Antigravity 는 구버전 키체인을 읽지 않는다")
        // Claude 계정의 구버전 조회가 멈춘 동안 다른 계정의 비밀 읽기와 등록이 끝나야 한다
        stalling.stallNextRead = true
        let legacyDone = expectation(description: "구버전 조회 완료")
        DispatchQueue.global().async { _ = try? store.secretData(for: c.id); legacyDone.fulfill() }
        XCTAssertEqual(stalling.entered.wait(timeout: .now() + 5), .success)
        let others = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? store.secretData(for: x.id)
            _ = try? store.upsertProfile(nickname: "x2", provider: .codex, identity: self.codexIdentity("x2@c.com"),
                                         secretData: CodexFixtures.authJSON(email: "x2@c.com"))
            others.signal()
        }
        let result = others.wait(timeout: .now() + 2)
        stalling.release.signal()
        wait(for: [legacyDone], timeout: 5)
        XCTAssertEqual(result, .success, "구버전 키체인 대기에 묶이지 않는다")
    }

    /// 리뷰 4회차 Codex P1-4: 프로필이 없는 ID(그사이 지운 agy 후보)는 구버전 키체인을 찾지 않는다 —
    /// 메인 액터가 시간 제한 없는 키체인 읽기에 묶이지 않게.
    func testUnknownIDDoesNotReadLegacyKeychain() throws {
        let stalling = StallingReadKeychain()
        let store = try AccountStore(env: env, keychain: stalling)
        let reads = stalling.reads
        XCTAssertNil(try store.secretData(for: UUID()))
        XCTAssertEqual(stalling.reads, reads, "등록되지 않은 ID 는 키체인을 읽지 않는다")
    }

    /// 리뷰 4회차 Claude P3-4: 구버전 항목 정리(`security delete`)도 Claude 계정만 한다.
    func testLegacyCleanupOnlyForClaude() throws {
        let stalling = StallingReadKeychain()
        let store = try AccountStore(env: env, keychain: stalling)
        let g = try store.upsertProfile(nickname: "g1", provider: .antigravity, identity: agyIdentity("g1@gmail.com"),
                                        secretData: AgyFixtures.secret("g1@gmail.com"))
        try store.setSecretData(AgyFixtures.secret("g1@gmail.com", refresh: "rt2"), for: g.id)
        _ = try store.upsertProfile(nickname: "x1", provider: .codex, identity: codexIdentity("x1@c.com"),
                                    secretData: CodexFixtures.authJSON(email: "x1@c.com"))
        XCTAssertEqual(stalling.deletes, 0, "Antigravity·Codex 는 구버전 항목을 지우러 가지 않는다")
        _ = try store.upsertProfile(nickname: "c", snapshot: CredentialsSnapshot(
            keychainBlob: Data("{}".utf8), credentialsFileData: Data("{}".utf8),
            oauthAccountJSON: try JSONSerialization.data(withJSONObject: ["emailAddress": "c@x.com"])))
        XCTAssertEqual(stalling.deletes, 1, "Claude 는 지금처럼 정리한다")
    }

    /// 리뷰 4회차 Claude P3-3: 같은 계정의 구버전 이관이 겹치면 키체인은 한 번만 읽는다(승인창 한 번).
    func testConcurrentLegacyMigrationReadsKeychainOnce() throws {
        let stalling = StallingReadKeychain()
        let store = try AccountStore(env: env, keychain: stalling)
        let snapshot = CredentialsSnapshot(
            keychainBlob: Data("{}".utf8), credentialsFileData: Data("{}".utf8),
            oauthAccountJSON: try JSONSerialization.data(withJSONObject: ["emailAddress": "c@x.com"]))
        let c = try store.upsertProfile(nickname: "c", snapshot: snapshot)
        try FileManager.default.removeItem(at: env.secretFile(for: c.id))
        try stalling.write(service: AccountStore.secretService(for: c.id), account: AccountStore.secretAccount,
                           data: try JSONEncoder().encode(snapshot))
        let reads = stalling.reads
        stalling.stallNextRead = true
        let first = expectation(description: "첫 이관")
        DispatchQueue.global().async { XCTAssertNotNil(try? store.secretData(for: c.id)); first.fulfill() }
        XCTAssertEqual(stalling.entered.wait(timeout: .now() + 5), .success)
        let second = expectation(description: "겹친 이관")
        DispatchQueue.global().async { XCTAssertNotNil(try? store.secretData(for: c.id)); second.fulfill() }
        Thread.sleep(forTimeInterval: 0.3)
        stalling.release.signal()
        wait(for: [first, second], timeout: 5)
        XCTAssertEqual(stalling.reads - reads, 1, "겹친 호출은 첫 이관의 파일을 읽는다")
    }

    /// 리뷰 4회차 Codex P1-3·Claude P3-2: 전환 직전 확인(`peekDisk`)의 읽기 오류도 다시 읽기에 성공할
    /// 때까지 저장을 막는다. 파일이 없는 것은 오류가 아니다.
    func testPeekDiskReadFailureBlocksLaterSaves() throws {
        let (app, _) = try populated()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.accountsFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: env.accountsFile.path) }
        XCTAssertNil(app.peekDisk())
        XCTAssertNotNil(app.loadFailure)
        XCTAssertThrowsError(try app.setAutoSwitch(false, provider: .claude)) {
            XCTAssertEqual($0 as? AccountStoreError, .savesBlockedAfterLoadFailure)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.accountsFile.path)
        try app.reloadFromDisk()
        XCTAssertNil(app.loadFailure)
        try FileManager.default.removeItem(at: env.accountsFile)
        XCTAssertNil(app.peekDisk())
        XCTAssertNil(app.loadFailure, "파일이 없으면 저장을 막지 않는다")
    }

    /// 리뷰 5회차 Codex P1-1: 상위 디렉터리를 탐색할 수 없는 것은 "파일 없음"이 아니라 읽기 오류다 —
    /// `fileExists` 는 이때도 false 라서, 확인만 멈추고 저장 차단이 걸리지 않았다.
    func testUnsearchableParentDirIsReadFailureNotMissingFile() throws {
        let (app, _) = try populated()
        let dir = env.accountsFile.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        XCTAssertNil(app.peekDisk())
        XCTAssertNotNil(app.loadFailure, "탐색 권한 오류는 저장을 막는다")
        XCTAssertThrowsError(try app.setAutoSwitch(false, provider: .claude)) {
            XCTAssertEqual($0 as? AccountStoreError, .savesBlockedAfterLoadFailure)
        }
        XCTAssertThrowsError(try AccountStore(env: env, keychain: kc), "시작 때도 빈 스토어로 뜨지 않는다")
    }

    /// 리뷰 5회차 Codex P1-2: 읽기 실패의 기록은 진행 중인 저장과 같은 순서로 직렬화된다 — 저장 차단 검사를
    /// 통과한 저장이 끝난 **뒤에** 실패가 기록되고, 그 뒤의 저장은 막힌다(기록이 저장 한가운데 끼지 않는다).
    func testPeekDiskFailureIsRecordedAfterInFlightSave() throws {
        let (app, profiles) = try populated()
        let c = profiles[0]
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.accountsFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: env.accountsFile.path) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let saved = expectation(description: "진행 중인 저장")
        DispatchQueue.global().async {
            try? app.update(c.id) { _ in entered.signal(); _ = release.wait(timeout: .now() + 10) }
            saved.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.accountsFile.path)
        let peeked = DispatchSemaphore(value: 0)
        let result = LockedFlag(true)
        DispatchQueue.global().async { result.set(app.peekDisk() == nil); peeked.signal() }
        let early = peeked.wait(timeout: .now() + 0.3)
        release.signal()
        wait(for: [saved], timeout: 5)
        if early == .timedOut { XCTAssertEqual(peeked.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(early, .timedOut, "진행 중인 저장이 끝나기 전에는 실패를 기록하지 않는다")
        XCTAssertTrue(result.value)
        XCTAssertNotNil(app.loadFailure)
        XCTAssertThrowsError(try app.setAutoSwitch(false, provider: .claude))
    }

    /// 리뷰 5회차 Claude P2-1: 구버전 저장 직후(앱이 메모리에서 Antigravity 계정을 복원한 상태)에도 삭제가 된다.
    func testRemoveAfterLegacySaveSucceeds() throws {
        let (app, profiles) = try populated()
        let g1 = profiles[3]
        let legacy = try JSONDecoder().decode(V053AccountsFile.self, from: Data(contentsOf: env.accountsFile))
        try JSONEncoder().encode(legacy).write(to: env.accountsFile)
        try app.reloadFromDisk()
        XCTAssertTrue(app.file.accounts.contains { $0.id == g1.id })
        try app.remove(g1.id)
        XCTAssertFalse(app.file.accounts.contains { $0.id == g1.id })
        try app.reloadFromDisk()
        XCTAssertFalse(app.file.accounts.contains { $0.id == g1.id }, "다시 읽어도 되살아나지 않는다")
        XCTAssertFalse(try AccountStore(env: env, keychain: kc).file.accounts.contains { $0.id == g1.id })
    }

    /// 리뷰 5회차 Codex P2-1: 다른 인스턴스가 이미 지운 계정을 다시 지워도(그 인스턴스가 아직 기억한다)
    /// 그 인스턴스가 남긴 `.removed` 표시를 지우지 않는다 — 저장이 막혀 실패한 경우에도.
    func testRemoveKeepsMarkerWrittenByOtherInstance() throws {
        let (app, profiles) = try populated()
        let g1 = profiles[3]
        let stale = try AccountStore(env: env, keychain: kc)   // g1 을 기억하는 다른 인스턴스
        try app.remove(g1.id)
        let marker = env.secretsDir.appendingPathComponent("\(g1.id.uuidString).removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        // 저장이 막힌 실패: 남의 표시는 그대로
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.accountsFile.path)
        XCTAssertThrowsError(try stale.remove(g1.id))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.accountsFile.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "실패한 삭제가 남의 표시를 거두지 않는다")
        // 이미 지워진 계정: 실패하지 않고 표시도 남는다
        let stale2 = AccountStore(env: env, keychain: kc, file: stale.file)
        XCTAssertNoThrow(try stale2.remove(g1.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(try AccountStore(env: env, keychain: kc).file.accounts.contains { $0.id == g1.id })
    }

    /// 리뷰 4회차 Codex P2(같은 흐름): 삭제가 저장되지 않으면 `.removed` 표시와 secret 을 남기지 않거나
    /// 지우지 않는다 — 남은 계정이 다음 복원에서 빠지거나 자격증명을 잃지 않게.
    func testFailedRemoveKeepsSecretAndLeavesNoMarker() throws {
        let (app, profiles) = try populated()
        let g1 = profiles[3]
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.accountsFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: env.accountsFile.path) }
        XCTAssertThrowsError(try app.remove(g1.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: env.secretsDir.appendingPathComponent("\(g1.id.uuidString).removed").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.secretFile(for: g1.id).path))
        XCTAssertTrue(app.file.accounts.contains { $0.id == g1.id })
    }

    /// 리뷰 4회차 Codex P2: 손상 백업을 쓰지 못했으면 알림이 백업이 있다고 안내하지 않게 `backup` 을 비운다.
    func testCorruptKindHasNoBackupWhenBackupWriteFails() throws {
        _ = try populated()
        try FileManager.default.createDirectory(at: AccountStore.corruptBackupURL(env: env),
                                                withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: env.accountsFile)
        var loadError: Error?
        do { _ = try AccountStore(env: env, keychain: kc) } catch { loadError = error }
        let corrupt = AccountStore(env: env, keychain: kc, afterLoadFailure: try XCTUnwrap(loadError))
        XCTAssertEqual(corrupt.loadFailureKind, .corrupt(backup: nil))
    }

    /// 리뷰 2회차 Codex P1-4: 저장 중 키체인 호출이 멈춰도 `file` 읽기와 다른 저장은 기다리지 않는다.
    func testKeychainStallDoesNotBlockReadsOrOtherSaves() throws {
        let blocking = StallingDeleteKeychain()
        let store = try AccountStore(env: env, keychain: blocking)
        let done = expectation(description: "등록 완료")
        // 구버전 항목 정리는 Claude 계정만 한다(리뷰 4회차 Claude P3-4) — Claude 등록으로 정리를 멈춰 세운다.
        let snapshot = CredentialsSnapshot(
            keychainBlob: Data("{}".utf8), credentialsFileData: Data("{}".utf8),
            oauthAccountJSON: try JSONSerialization.data(withJSONObject: ["emailAddress": "cl@x.com"]))
        DispatchQueue.global().async {
            _ = try? store.upsertProfile(nickname: "cl", snapshot: snapshot)
            done.fulfill()
        }
        XCTAssertEqual(blocking.entered.wait(timeout: .now() + 5), .success, "등록이 키체인 정리에 들어갔다")
        // 키체인 정리가 멈춘 동안 메인에서 읽기와 다른 저장이 끝나야 한다
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = store.file
            _ = store.activeGeneration(of: .antigravity)
            try? store.setAutoSwitch(false, provider: .claude)
            readDone.signal()
        }
        let result = readDone.wait(timeout: .now() + 2)
        blocking.release.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, .success, "읽기·저장이 키체인 대기에 묶이지 않는다")
        XCTAssertEqual(store.file.accounts(of: .claude).map(\.emailAddress), ["cl@x.com"])
    }

    func testMissingFileStillStartsEmpty() throws {
        let store = try AccountStore(env: env, keychain: kc)
        XCTAssertTrue(store.file.accounts.isEmpty)
        try store.mutateFresh { f in f.desktopSyncEnabled = false }
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.accountsFile.path))
    }

    func testOrphanSecretsInFileWithKeyAreNotRestored() throws {
        let (_, p) = try populated()
        // 키가 있는 파일에서 보이는 고아 secret 은 삭제 실패의 흔적 — 복원하지 않는다
        let stray = UUID()
        try AgyFixtures.secret("stray@gmail.com").write(to: env.secretFile(for: stray))
        let fresh = try AccountStore(env: env, keychain: kc)
        XCTAssertEqual(Set(fresh.file.accounts(of: .antigravity).map(\.id)), Set([p[3].id, p[4].id]))
        XCTAssertFalse(fresh.restoredAfterLegacySave)
    }

    // (d) 모르는 provider 항목과 맵 키가 왕복 뒤에도 남는다
    func testUnknownProviderEntriesAndMapKeysSurvive() throws {
        let futureID = UUID().uuidString
        let json = """
        {"accounts": [{"id": "\(UUID().uuidString)", "provider": "claude", "nickname": "c", "emailAddress": "c@x"},
                      {"id": "\(futureID)", "provider": "future", "nickname": "f", "emailAddress": "f@x", "x": [1,2]}],
         "extraProviderAccounts": [{"id": "\(UUID().uuidString)", "provider": "nova", "nickname": "n", "emailAddress": "n@x"}],
         "activeByProvider": {"future": "\(futureID)"},
         "autoSwitchByProvider": {"nova": true},
         "activeRevisionByProvider": {"future": 7}}
        """
        let file = try JSONDecoder().decode(AccountsFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.accounts.count, 1)
        let round = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as! [String: Any]
        let accounts = round["accounts"] as! [[String: Any]]
        // 리뷰 1회차 Codex P1-1: accounts 에 있던 모르는 항목도 accounts 에 다시 쓰면 구버전 디코더가
        // 배열 전체를 거부한다 → extraProviderAccounts 로 옮겨 보존한다(설계 4.4-1·3).
        XCTAssertEqual(accounts.compactMap { $0["provider"] as? String }, ["claude"])
        let extra = round["extraProviderAccounts"] as! [[String: Any]]
        XCTAssertEqual(Set(extra.compactMap { $0["provider"] as? String }), ["nova", "future"])
        XCTAssertEqual(extra.first { $0["provider"] as? String == "future" }?["x"] as? [Int], [1, 2],
                       "원본 JSON 그대로")
        XCTAssertEqual((round["activeByProvider"] as! [String: String])["future"], futureID)
        XCTAssertEqual((round["autoSwitchByProvider"] as! [String: Bool])["nova"], true)
        XCTAssertEqual((round["activeRevisionByProvider"] as! [String: Int])["future"], 7)
        // 0.5.3 디코더가 왕복한 파일을 읽는다
        let legacy = try JSONDecoder().decode(V053AccountsFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(legacy.accounts.map(\.emailAddress), ["c@x"])
        // 다시 읽어 두 번 왕복해도 항목이 늘거나 사라지지 않는다
        let again = try JSONDecoder().decode(AccountsFile.self, from: JSONEncoder().encode(file))
        let round2 = try JSONSerialization.jsonObject(with: JSONEncoder().encode(again)) as! [String: Any]
        XCTAssertEqual((round2["extraProviderAccounts"] as! [[String: Any]]).count, 2)
    }

    func testKnownProviderCorruptionStillThrows() {
        let corrupt = #"{"accounts": [{"id": "not-a-uuid", "provider": "codex", "nickname": "x", "emailAddress": "e"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AccountsFile.self, from: Data(corrupt.utf8)))
        let corruptExtra = #"{"accounts": [], "extraProviderAccounts": [{"id": 1, "provider": "antigravity"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AccountsFile.self, from: Data(corruptExtra.utf8)))
    }

    func testLegacyGlobalAutoSwitchKeyFollowsProviderDefaults() throws {
        let on = try JSONDecoder().decode(AccountsFile.self, from: Data(#"{"autoSwitchEnabled": true}"#.utf8))
        XCTAssertTrue(on.isAutoSwitchEnabled(.claude))
        XCTAssertFalse(on.isAutoSwitchEnabled(.antigravity))
        let off = try JSONDecoder().decode(AccountsFile.self, from: Data(#"{"autoSwitchEnabled": false}"#.utf8))
        XCTAssertFalse(off.isAutoSwitchEnabled(.claude))
        XCTAssertFalse(off.isAutoSwitchEnabled(.antigravity))
    }

    func testRateLimitScopeFieldsDecodeLeniently() throws {
        let old = #"{"resetsAt": 1000, "recordedAt": 900, "modelScoped": true}"#
        let rl = try JSONDecoder().decode(RateLimitInfo.self, from: Data(old.utf8))
        XCTAssertNil(rl.scopeModelIDs)
        let full = RateLimitInfo(resetsAt: Date(), recordedAt: Date(), modelScoped: true,
                                 scopeModelIDs: ["gemini-3-flash"], scopeLabel: "Gemini")
        XCTAssertEqual(try JSONDecoder().decode(RateLimitInfo.self, from: JSONEncoder().encode(full)), full)
    }

    // MARK: 활성 리비전·세대 (설계 4.7)

    func testActiveRevisionAndGenerationFollowEveryActiveChange() throws {
        let (store, p) = try populated()
        let rev0 = store.file.activeRevision(.antigravity)
        let gen0 = store.activeGeneration(of: .antigravity)
        try store.setActive(p[3].id)
        XCTAssertEqual(store.file.activeRevision(.antigravity), rev0 + 1)
        XCTAssertEqual(store.activeGeneration(of: .antigravity), gen0 + 1)
        // 같은 계정으로 돌아온 왕복도 세대를 바꾼다
        try store.setActive(p[4].id)
        try store.setActive(p[3].id)
        XCTAssertEqual(store.activeGeneration(of: .antigravity), gen0 + 3)
        // 다른 프로세스(CLI)의 변경 — 디스크 리비전이 달라지면 reload 가 세대를 늘린다
        let cli = try AccountStore(env: env, keychain: kc)
        try cli.setActive(p[4].id)
        try cli.setActive(p[3].id)   // 활성 값은 그대로지만 리비전은 2 늘었다
        let before = store.activeGeneration(of: .antigravity)
        try store.reloadFromDisk()
        XCTAssertEqual(store.activeGeneration(of: .antigravity), before + 1)
        XCTAssertEqual(store.peekDisk()?.activeRevision(.antigravity), store.file.activeRevision(.antigravity))
    }

    func testLiveFingerprintChangeBumpsGeneration() {
        let store = AccountStore(env: env, keychain: kc, file: AccountsFile())
        store.noteLiveFingerprint(Data([1]), provider: .antigravity)
        XCTAssertEqual(store.activeGeneration(of: .antigravity), 0, "처음 알리는 지문은 기준만 잡는다")
        store.noteLiveFingerprint(Data([1]), provider: .antigravity)
        XCTAssertEqual(store.activeGeneration(of: .antigravity), 0)
        store.noteLiveFingerprint(Data([2]), provider: .antigravity)   // 같은 이메일 재로그인
        XCTAssertEqual(store.activeGeneration(of: .antigravity), 1)
        store.noteLiveFingerprint(nil, provider: .antigravity)         // 로그아웃
        XCTAssertEqual(store.activeGeneration(of: .antigravity), 2)
    }

    func testSetActiveSaveFailureKeepsMemoryActive() throws {
        let (store, p) = try populated()
        let before = store.file.activeByProvider
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: env.appSupportDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.appSupportDir.path) }
        XCTAssertThrowsError(try store.setActive(p[1].id))
        XCTAssertThrowsError(try store.setActive(p[3].id))
        XCTAssertEqual(store.file.activeByProvider, before, "저장이 실패하면 메모리 활성도 그대로다")
    }

    func testMutateFreshKeepsOtherProcessChanges() throws {
        let (store, p) = try populated()
        let cli = try AccountStore(env: env, keychain: kc)
        try cli.setActive(p[1].id)                       // CLI 가 Codex 활성을 바꿈
        try store.setAutoSwitch(false, provider: .antigravity)   // 앱의 Antigravity 저장(디스크 다시 읽음)
        let disk = try AccountStore(env: env, keychain: kc)
        XCTAssertEqual(disk.file.activeByProvider[.codex], p[1].id, "다른 프로세스의 변경을 덮지 않는다")
        XCTAssertFalse(disk.file.isAutoSwitchEnabled(.antigravity))
    }
}
