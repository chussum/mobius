import XCTest
@testable import MobiusCore

final class SwitcherTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var kc: InMemoryKeychain!
    var store: AccountStore!; var io: ClaudeConfigIO!; var switcher: Switcher!
    var personal: AccountProfile!; var work: AccountProfile!

    func snap(email: String, tok: String) -> CredentialsSnapshot {
        CredentialsSnapshot(
            keychainBlob: Data(#"{"tok":"\#(tok)"}"#.utf8),
            credentialsFileData: Data(#"{"tok":"\#(tok)"}"#.utf8),
            oauthAccountJSON: Data(#"{"emailAddress":"\#(email)","organizationName":"O"}"#.utf8))
    }

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-sw-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        try FileManager.default.createDirectory(at: env.claudeDir, withIntermediateDirectories: true)
        kc = InMemoryKeychain()
        store = try AccountStore(env: env, keychain: kc)
        io = ClaudeConfigIO(env: env, keychain: kc)
        switcher = Switcher(env: env, keychain: kc, store: store, io: io)
        personal = try store.upsertProfile(nickname: "personal", snapshot: snap(email: "p@x.com", tok: "P0"))
        work = try store.upsertProfile(nickname: "work", snapshot: snap(email: "w@x.com", tok: "W0"))
        try io.writeLiveSnapshot(snap(email: "p@x.com", tok: "P0")) // 현재 personal 로그인 상태
        try store.setActive(personal.id)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testSwitchWritesTargetAndResavesCurrent() throws {
        // CLI가 refresh 토큰을 갱신했다고 가정: 라이브에는 P1
        try io.writeLiveSnapshot(snap(email: "p@x.com", tok: "P1"))
        try switcher.switchTo(work.id)
        // 라이브는 work
        XCTAssertEqual(try io.liveEmail(), "w@x.com")
        XCTAssertEqual(store.file.activeAccountID, work.id)
        // personal 프로필에는 최신 P1이 되저장됨
        XCTAssertEqual(try store.secret(for: personal.id)?.keychainBlob,
                       Data(#"{"tok":"P1"}"#.utf8))
    }

    func testRollbackOnFailure() throws {
        // 대상 기록 단계에서만 실패 주입: 되저장은 Mobius-account-* 서비스라 통과하고,
        // 라이브 서비스로의 첫 write(대상 기록)가 실패 → catch의 롤백 write가 실행된다.
        // failWritesForService는 1회 소모형이라 롤백 write 자체는 통과한다.
        kc.failWritesForService = env.claudeKeychainService
        XCTAssertThrowsError(try switcher.switchTo(work.id))
        XCTAssertEqual(try io.liveEmail(), "p@x.com") // 복구됨
        XCTAssertEqual(store.file.activeAccountID, personal.id)
        // 롤백이 실제로 실행됨: 라이브 Keychain 항목이 원래 blob으로 되돌아옴
        XCTAssertEqual(try kc.read(service: env.claudeKeychainService,
                                   account: env.claudeKeychainAccount),
                       Data(#"{"tok":"P0"}"#.utf8))
    }

    func testSwitchToUnknownAccountThrows() throws {
        XCTAssertThrowsError(try switcher.switchTo(UUID())) { error in
            XCTAssertEqual(error as? SwitcherError, .unknownAccount)
        }
    }

    func testReconcileDetectsExternalLogin() async throws {
        // 사용자가 앱 밖에서 work로 직접 재로그인한 상황
        try io.writeLiveSnapshot(snap(email: "w@x.com", tok: "W-ext"))
        try await switcher.reconcile()
        XCTAssertEqual(store.file.activeAccountID, work.id)
        // 외부 로그인으로 생긴 최신 토큰이 프로필에 흡수됨
        XCTAssertEqual(try store.secret(for: work.id)?.keychainBlob,
                       Data(#"{"tok":"W-ext"}"#.utf8))
    }

    func testReconcileUnknownEmailDoesNothing() async throws {
        try io.writeLiveSnapshot(snap(email: "stranger@x.com", tok: "S"))
        try await switcher.reconcile()
        XCTAssertEqual(store.file.activeAccountID, personal.id) // 그대로
    }

    // MARK: refreshActiveSnapshotIfStable — 신선도 계약(반환값)
    // 호출자는 true를 "저장 secret이 이번 사이클 기준 신선"으로 읽고 라이브 재읽기를 생략한다.
    // 따라서 세 경로(가드 실패 / 성공 / 저장 throw)가 각각 정직하게 보고되는지 못 박는다.

    func testRefreshActiveSnapshotReturnsFalseOnEmailMismatch() async throws {
        // 라이브가 등록되지 않은 이메일 → 첫 가드에서 탈락 (쓰기 없음).
        try io.writeLiveSnapshot(snap(email: "stranger@x.com", tok: "S"))
        let wrote = await switcher.refreshActiveSnapshotIfStable()
        XCTAssertFalse(wrote)
    }

    func testRefreshActiveSnapshotReturnsTrueOnSuccessfulWrite() async throws {
        // claude가 라이브 토큰을 P1으로 갱신한 상태 — 활성 계정이라 스냅샷에 반영돼야 한다.
        try io.writeLiveSnapshot(snap(email: "p@x.com", tok: "P1"))
        let wrote = await switcher.refreshActiveSnapshotIfStable()
        XCTAssertTrue(wrote)
        XCTAssertEqual(try store.secret(for: personal.id)?.keychainBlob,
                       Data(#"{"tok":"P1"}"#.utf8))
    }

    func testRefreshActiveSnapshotReturnsFalseWhenStoreWriteThrows() async throws {
        // 모든 가드는 통과시키고 **저장만** 실패시킨다: secrets 디렉토리 자리에 일반 파일을
        // 놓으면 writeSecretFile의 createDirectory가 throw한다. 구 `try?` 구현은 이 실패를
        // 삼켜 true(신선)로 보고했을 경로 — 그게 이 테스트가 지키는 지점이다.
        try io.writeLiveSnapshot(snap(email: "p@x.com", tok: "P1"))
        try FileManager.default.removeItem(at: env.secretsDir)
        try Data("not a directory".utf8).write(to: env.secretsDir)

        let wrote = await switcher.refreshActiveSnapshotIfStable()
        XCTAssertFalse(wrote)
    }
}
