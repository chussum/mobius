import XCTest
@testable import MobiusCore

private final class MockRefresher: TokenRefresher, @unchecked Sendable {
    var result: Result<RefreshedTokens, Error>
    private(set) var callCount = 0
    init(_ r: Result<RefreshedTokens, Error>) { result = r }
    func refresh(refreshToken: String, scopes: [String], now: Date) async throws -> RefreshedTokens {
        callCount += 1
        return try result.get()
    }
}

final class FallbackAuthCheckerTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var kc: InMemoryKeychain!; var store: AccountStore!
    var active: AccountProfile!; var fallback: AccountProfile!
    // rte 미래(살아있음) / 과거(로컬 만료) 판정 기준시각
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let futureRteMs = 1_900_000_000_000     // ≈2030 (now 이후)
    let pastRteMs = 1_500_000_000_000        // ≈2017 ms (now 이전, ms 판별 임계 1e12 초과)

    func snap(email: String, rt: String, rteMs: Int, hasRefresh: Bool = true) -> CredentialsSnapshot {
        let oauth = hasRefresh
            ? #"{"accessToken":"AT","refreshToken":"\#(rt)","expiresAt":1,"refreshTokenExpiresAt":\#(rteMs),"scopes":["user:inference","user:profile"],"subscriptionType":"max"}"#
            : #"{"accessToken":"AT"}"#
        let blob = Data(#"{"claudeAiOauth":\#(oauth)}"#.utf8)
        return CredentialsSnapshot(keychainBlob: blob, credentialsFileData: blob,
            oauthAccountJSON: Data(#"{"emailAddress":"\#(email)","organizationName":"O"}"#.utf8))
    }

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mobius-fac-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        try FileManager.default.createDirectory(at: env.claudeDir, withIntermediateDirectories: true)
        kc = InMemoryKeychain()
        store = try AccountStore(env: env, keychain: kc)
        active = try store.upsertProfile(nickname: "active", snapshot: snap(email: "a@x.com", rt: "ART", rteMs: futureRteMs))
        fallback = try store.upsertProfile(nickname: "fallback", snapshot: snap(email: "f@x.com", rt: "FRT", rteMs: futureRteMs))
        try store.setActive(active.id)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func reauth(_ id: UUID) -> Bool {
        store.file.accounts.first { $0.id == id }?.needsReauth ?? false
    }

    func testRefreshSuccessStoresNewTokenAndClearsReauth() async throws {
        try store.setNeedsReauth(fallback.id, true) // 잘못 남은 딱지가 해제되는지도 확인
        let tokens = RefreshedTokens(accessToken: "NAT", refreshToken: "NRT",
                                     expiresAtMs: 123, refreshTokenExpiresAtMs: futureRteMs + 1, scopes: nil)
        let mock = MockRefresher(.success(tokens))
        let checker = FallbackAuthChecker(store: store, refresher: mock)
        let r = await checker.check(fallback.id, activeAccountID: active.id, now: now)
        XCTAssertEqual(r, .refreshedAlive)
        XCTAssertEqual(mock.callCount, 1)
        XCTAssertEqual(CredentialBlob.refreshToken(from: try XCTUnwrap(store.secret(for: fallback.id)).keychainBlob), "NRT")
        XCTAssertFalse(reauth(fallback.id)) // 살아있음 → 해제
    }

    func testInvalidGrantMarksReauth() async throws {
        let mock = MockRefresher(.failure(TokenRefresherError.invalidGrant))
        let r = await FallbackAuthChecker(store: store, refresher: mock).check(fallback.id, activeAccountID: active.id, now: now)
        XCTAssertEqual(r, .dead)
        XCTAssertTrue(reauth(fallback.id))
    }

    func testLocallyDeadSkipsNetwork() async throws {
        // refreshTokenExpiresAt 과거 → 네트워크 호출 없이 죽음 판정
        try store.setSecret(snap(email: "f@x.com", rt: "FRT", rteMs: pastRteMs), for: fallback.id)
        let mock = MockRefresher(.failure(TokenRefresherError.invalidGrant))
        let r = await FallbackAuthChecker(store: store, refresher: mock).check(fallback.id, activeAccountID: active.id, now: now)
        XCTAssertEqual(r, .locallyDead)
        XCTAssertEqual(mock.callCount, 0)         // 네트워크 0
        XCTAssertTrue(reauth(fallback.id))
    }

    func testActiveAccountNeverRefreshed() async throws {
        let mock = MockRefresher(.failure(TokenRefresherError.invalidGrant))
        let r = await FallbackAuthChecker(store: store, refresher: mock).check(active.id, activeAccountID: active.id, now: now)
        XCTAssertEqual(r, .notFallback)
        XCTAssertEqual(mock.callCount, 0)
        XCTAssertFalse(reauth(active.id))         // 활성은 절대 마킹 안 함
    }

    func testTransientDoesNotMarkReauth() async throws {
        let mock = MockRefresher(.failure(TokenRefresherError.transient))
        let r = await FallbackAuthChecker(store: store, refresher: mock).check(fallback.id, activeAccountID: active.id, now: now)
        XCTAssertEqual(r, .transient)
        XCTAssertFalse(reauth(fallback.id))       // 일시적 오류로 죽음 단정 금지
    }

    func testMissingRefreshTokenMarksReauth() async throws {
        try store.setSecret(snap(email: "f@x.com", rt: "-", rteMs: futureRteMs, hasRefresh: false), for: fallback.id)
        let mock = MockRefresher(.failure(TokenRefresherError.transient))
        let r = await FallbackAuthChecker(store: store, refresher: mock).check(fallback.id, activeAccountID: active.id, now: now)
        XCTAssertEqual(r, .noRefreshToken)
        XCTAssertEqual(mock.callCount, 0)
        XCTAssertTrue(reauth(fallback.id))
    }
}
