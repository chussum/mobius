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

    func testMoveFallbackKeepsPrimaryPinned() throws {
        let store = try AccountStore(env: env, keychain: kc)
        _ = try store.upsertProfile(nickname: "primary", snapshot: snap(email: "a@x.com"))
        _ = try store.upsertProfile(nickname: "fb1", snapshot: snap(email: "b@x.com"))
        _ = try store.upsertProfile(nickname: "fb2", snapshot: snap(email: "c@x.com"))
        try store.moveFallback(fromIndex: 2, toIndex: 1) // fb2를 fb1 앞으로
        XCTAssertEqual(store.file.accounts.map(\.nickname), ["primary", "fb2", "fb1"])
        XCTAssertThrowsError(try store.moveFallback(fromIndex: 0, toIndex: 1)) // primary 이동 금지
    }

    func testSetPrimaryPromotesAndDemotesOldPrimary() throws {
        let store = try AccountStore(env: env, keychain: kc)
        _ = try store.upsertProfile(nickname: "primary", snapshot: snap(email: "a@x.com"))
        let fb1 = try store.upsertProfile(nickname: "fb1", snapshot: snap(email: "b@x.com"))
        _ = try store.upsertProfile(nickname: "fb2", snapshot: snap(email: "c@x.com"))
        try store.setAutoSwitchedFromPrimary(true)

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

    func testRemoveDeletesSecret() throws {
        let store = try AccountStore(env: env, keychain: kc)
        let p = try store.upsertProfile(nickname: "x", snapshot: snap(email: "p@x.com"))
        try store.remove(p.id)
        XCTAssertNil(try store.secret(for: p.id))
        XCTAssertTrue(store.file.accounts.isEmpty)
        XCTAssertNil(store.file.activeAccountID)
    }
}
