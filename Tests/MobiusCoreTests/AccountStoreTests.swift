import XCTest
@testable import MobiusCore

final class AccountStoreTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var kc: InMemoryKeychain!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-store-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        kc = InMemoryKeychain()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func snap(email: String) -> CredentialsSnapshot {
        CredentialsSnapshot(
            keychainBlob: Data("blob-\(email)".utf8),
            credentialsFileData: Data("file-\(email)".utf8),
            oauthAccountJSON: Data(
                #"{"emailAddress":"\#(email)","organizationName":"Org","organizationRateLimitTier":"default_claude_max_20x"}"#.utf8))
    }

    func testUpsertNewAndDuplicateEmail() throws {
        let store = try AccountStore(env: env, keychain: kc)
        let p1 = try store.upsertProfile(nickname: "personal", snapshot: snap(email: "p@x.com"))
        XCTAssertEqual(store.file.accounts.count, 1)
        XCTAssertEqual(p1.emailAddress, "p@x.com")
        XCTAssertEqual(store.file.activeAccountID, p1.id) // 첫 계정은 자동 활성

        // 같은 이메일 재캡처 → 새 프로필이 아니라 갱신
        let p1b = try store.upsertProfile(nickname: "personal", snapshot: snap(email: "p@x.com"))
        XCTAssertEqual(store.file.accounts.count, 1)
        XCTAssertEqual(p1b.id, p1.id)
        XCTAssertEqual(try store.secret(for: p1.id)?.keychainBlob, Data("blob-p@x.com".utf8))
    }

    func testPersistenceRoundtrip() throws {
        let store = try AccountStore(env: env, keychain: kc)
        let p = try store.upsertProfile(nickname: "personal", snapshot: snap(email: "p@x.com"))
        _ = try store.upsertProfile(nickname: "work", snapshot: snap(email: "w@x.com"))
        // 새 인스턴스로 다시 로드
        let store2 = try AccountStore(env: env, keychain: kc)
        XCTAssertEqual(store2.file.accounts.map(\.nickname), ["personal", "work"])
        XCTAssertEqual(store2.file.activeAccountID, p.id)
    }

    func testSetAutoSwitchPerProviderPersists() throws {
        let store = try AccountStore(env: env, keychain: kc)
        try store.setAutoSwitch(false, provider: .codex)
        // 새 인스턴스로 다시 로드해도 풀별 상태 유지 — 타 풀은 기본 켬
        let store2 = try AccountStore(env: env, keychain: kc)
        XCTAssertFalse(store2.file.isAutoSwitchEnabled(.codex))
        XCTAssertTrue(store2.file.isAutoSwitchEnabled(.claude))
    }

    func testMoveFallbackKeepsPrimaryPinned() throws {
        let store = try AccountStore(env: env, keychain: kc)
        _ = try store.upsertProfile(nickname: "primary", snapshot: snap(email: "a@x.com"))
        _ = try store.upsertProfile(nickname: "fb1", snapshot: snap(email: "b@x.com"))
        _ = try store.upsertProfile(nickname: "fb2", snapshot: snap(email: "c@x.com"))
        try store.moveFallback(provider: .claude, fromIndex: 2, toIndex: 1) // fb2를 fb1 앞으로
        XCTAssertEqual(store.file.accounts.map(\.nickname), ["primary", "fb2", "fb1"])
        XCTAssertThrowsError( // primary 이동 금지
            try store.moveFallback(provider: .claude, fromIndex: 0, toIndex: 1))
    }

    func testSetUserPinnedIsScopedToProviderPool() throws {
        let store = try AccountStore(env: env, keychain: kc)
        let claudeA = try store.upsertProfile(nickname: "cA", snapshot: snap(email: "a@x.com"))
        _ = try store.upsertProfile(nickname: "cB", snapshot: snap(email: "b@x.com"))
        let codex = try store.upsertProfile(
            nickname: "x", provider: .codex,
            identity: ProviderIdentity(emailAddress: "x@o.com", organizationName: "",
                                       tierDescription: "Pro"),
            secretData: Data("codex".utf8))
        func pinned(_ id: UUID) -> Bool { store.file.accounts.first { $0.id == id }!.userPinned }

        // Claude 풀에서 A를 핀
        try store.setUserPinned(claudeA.id)
        XCTAssertTrue(pinned(claudeA.id))

        // Codex 계정을 수동 전환(핀)해도 다른 풀(Claude)의 핀은 유지돼야 한다 (구코드=전역 clear면 깨짐)
        try store.setUserPinned(codex.id)
        XCTAssertTrue(pinned(claudeA.id), "Codex 핀이 Claude 풀의 핀을 풀면 안 된다")
        XCTAssertTrue(pinned(codex.id))

        // 같은 풀 내 배타성은 유지 — cB를 핀하면 cA는 풀리고 Codex 핀은 그대로
        let cB = store.file.accounts.first { $0.nickname == "cB" }!
        try store.setUserPinned(cB.id)
        XCTAssertFalse(pinned(claudeA.id))
        XCTAssertTrue(pinned(cB.id))
        XCTAssertTrue(pinned(codex.id), "Codex 핀은 계속 유지")

        XCTAssertThrowsError(try store.setUserPinned(UUID())) // 미등록 계정
    }

    func testSetPrimaryPromotesAndDemotesOldPrimary() throws {
        let store = try AccountStore(env: env, keychain: kc)
        _ = try store.upsertProfile(nickname: "primary", snapshot: snap(email: "a@x.com"))
        let fb1 = try store.upsertProfile(nickname: "fb1", snapshot: snap(email: "b@x.com"))
        _ = try store.upsertProfile(nickname: "fb2", snapshot: snap(email: "c@x.com"))
        try store.setAutoSwitchedFromPrimary(true, provider: .claude)

        try store.setPrimary(fb1.id) // fb1 승격 → 기존 primary는 첫 fallback으로
        XCTAssertEqual(store.file.accounts.map(\.nickname), ["fb1", "primary", "fb2"])
        XCTAssertFalse(store.file.autoSwitchedFromPrimary) // primary 기준 변경 → 복귀 예약 리셋

        try store.setPrimary(fb1.id) // 이미 primary — 변경 없음
        XCTAssertEqual(store.file.accounts.map(\.nickname), ["fb1", "primary", "fb2"])
        XCTAssertThrowsError(try store.setPrimary(UUID())) // 미등록 계정

        // 영속 확인 — 새 인스턴스로 로드해도 순서 유지
        let store2 = try AccountStore(env: env, keychain: kc)
        XCTAssertEqual(store2.file.accounts.map(\.nickname), ["fb1", "primary", "fb2"])
    }

    func testSetNeedsReauthPersistsAndClearsOnRelogin() throws {
        let store = try AccountStore(env: env, keychain: kc)
        let p = try store.upsertProfile(nickname: "x", snapshot: snap(email: "p@x.com"))
        try store.setNeedsReauth(p.id, true)
        XCTAssertTrue(store.file.accounts[0].needsReauth)
        // 새 인스턴스로 로드해도 유지
        XCTAssertTrue(try AccountStore(env: env, keychain: kc).file.accounts[0].needsReauth)
        // 같은 이메일 재로그인(upsert) → 자동 해제
        _ = try store.upsertProfile(nickname: "x", snapshot: snap(email: "p@x.com"))
        XCTAssertFalse(store.file.accounts[0].needsReauth)
        XCTAssertThrowsError(try store.setNeedsReauth(UUID(), true)) // 미등록 계정
    }

    func testDecodesOldFileWithoutNewFields() throws {
        // 하위 호환: modelScoped/userPinned 키가 없는 구버전 accounts.json도 깨지지 않아야 한다.
        // (다른 사용자가 앱을 업데이트해도 계정 목록 유실 방지 — 실측 사고 재발 방지)
        let old = """
        {"accounts":[{"id":"39327A8E-494D-4FF4-B216-D3D314173500","nickname":"fore.st",\
        "emailAddress":"f@x.com","organizationName":"Raven","tierDescription":"Max",\
        "needsReauth":false,"hasDesktopSnapshot":false,\
        "rateLimit":{"resetsAt":700000000,"recordedAt":699999000}}],\
        "activeAccountID":"39327A8E-494D-4FF4-B216-D3D314173500","autoSwitchEnabled":true,\
        "desktopSyncEnabled":false,"desktopAutoSwitchEnabled":false,"autoSwitchedFromPrimary":false}
        """
        let f = try JSONDecoder().decode(AccountsFile.self, from: Data(old.utf8))
        XCTAssertEqual(f.accounts.count, 1)
        XCTAssertEqual(f.accounts[0].nickname, "fore.st")
        XCTAssertFalse(f.accounts[0].userPinned)          // 기본값
        XCTAssertEqual(f.accounts[0].rateLimit?.modelScoped, false) // 기본값
    }

    func testCorruptFileIsBackedUpNotLost() throws {
        try fm.createDirectory(at: env.appSupportDir, withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: env.accountsFile)
        XCTAssertThrowsError(try AccountStore(env: env, keychain: kc)) // 손상 → throw
        let backup = env.appSupportDir.appendingPathComponent("accounts.corrupt.json")
        XCTAssertTrue(fm.fileExists(atPath: backup.path)) // 원본 백업됨(유실 방지)
    }

    let fm = FileManager.default

    func testRemoveDeletesSecret() throws {
        let store = try AccountStore(env: env, keychain: kc)
        let p = try store.upsertProfile(nickname: "x", snapshot: snap(email: "p@x.com"))
        try store.remove(p.id)
        XCTAssertNil(try store.secret(for: p.id))
        XCTAssertTrue(store.file.accounts.isEmpty)
        XCTAssertNil(store.file.activeAccountID)
    }

    // MARK: credential lock (Codex 토큰 자동 갱신 ↔ 전환 상호 배제)

    /// 같은 id의 withCredentialLock은 상호 배제된다 — 락 없이는 read-modify-write가 레이스로
    /// 카운트를 잃는다. 락이 직렬화하므로 유실이 없어야 한다.
    func testCredentialLockProvidesMutualExclusion() throws {
        final class Box: @unchecked Sendable { var n = 0 }
        let store = try AccountStore(env: env, keychain: kc)
        let id = UUID()
        let box = Box()
        let iterations = 2000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            store.withCredentialLock(id) { box.n += 1 }
        }
        XCTAssertEqual(box.n, iterations)   // 직렬화 → 유실 0
    }

    /// 동시 store + read가 credential lock 안에서 돌면, 리더는 항상 **정합한 완전 스냅샷**만
    /// 관측한다(찢긴 바이트 없음) — 회전본 저장이 진행 중인 스냅샷을 전환이 반쪽으로 읽는 레이스 방지.
    func testCredentialLockSerializesConcurrentStoreAndRead() throws {
        let store = try AccountStore(env: env, keychain: kc)
        let p = try store.upsertProfile(
            nickname: "cx", provider: .codex,
            identity: ProviderIdentity(emailAddress: "x@o.com", organizationName: "",
                                       tierDescription: "Pro"),
            secretData: CodexFixtures.authJSON(email: "x@o.com", accessToken: "at-0"))
        let codexIO = CodexConfigIO(env: env)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if i % 2 == 0 {
                let bytes = CodexFixtures.authJSON(email: "x@o.com", accessToken: "at-\(i)")
                store.withCredentialLock(p.id) { try? store.setSecretData(bytes, for: p.id) }
            } else {
                let observed: Data? = store.withCredentialLock(p.id) {
                    try? store.secretData(for: p.id)
                }
                if let data = observed {
                    XCTAssertEqual(CodexConfigIO.email(fromAuthJSON: data), "x@o.com")
                    XCTAssertTrue(codexIO.recognizesSecret(data))
                }
            }
        }
        let final = try XCTUnwrap(store.secretData(for: p.id))
        XCTAssertEqual(CodexConfigIO.email(fromAuthJSON: final), "x@o.com")
    }

    /// setSecretData는 덮어쓰기 전 기존 스냅샷을 .bak으로 보존한다(회전 저장 복구 여지).
    func testSetSecretDataKeepsBak() throws {
        let store = try AccountStore(env: env, keychain: kc)
        let p = try store.upsertProfile(
            nickname: "cx", provider: .codex,
            identity: ProviderIdentity(emailAddress: "x@o.com", organizationName: "",
                                       tierDescription: "Pro"),
            secretData: Data("v1".utf8))
        try store.setSecretData(Data("v2".utf8), for: p.id)   // v1 → .bak, v2가 현재
        XCTAssertEqual(try store.secretData(for: p.id), Data("v2".utf8))
        let bak = env.secretFile(for: p.id).appendingPathExtension("bak")
        XCTAssertEqual(try Data(contentsOf: bak), Data("v1".utf8))
    }
}
