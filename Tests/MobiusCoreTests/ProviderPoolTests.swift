import XCTest
@testable import MobiusCore

/// 프로바이더별 풀 분리(M1)의 스펙: 레거시 마이그레이션, 풀 독립성, 그룹 내 재배열.
final class ProviderPoolTests: XCTestCase {

    func profile(_ nickname: String, _ provider: Provider, email: String? = nil) -> AccountProfile {
        AccountProfile(id: UUID(), provider: provider, nickname: nickname,
                       emailAddress: email ?? "\(nickname)@x.com",
                       organizationName: "", tierDescription: "")
    }

    // MARK: 레거시 마이그레이션

    /// 실제 배포 중인 v1 accounts.json 형태(최상위 activeAccountID/autoSwitchedFromPrimary,
    /// 프로필에 provider 없음)가 Claude 풀로 무손실 흡수되는지.
    func testLegacyV1FileMigratesIntoClaudePool() throws {
        let id = UUID()
        let legacy = """
        {"accounts": [{"id": "\(id.uuidString)", "nickname": "work",
          "emailAddress": "w@x.com", "organizationName": "Org",
          "tierDescription": "Max 20x", "needsReauth": false, "hasDesktopSnapshot": true}],
         "activeAccountID": "\(id.uuidString)", "autoSwitchEnabled": true,
         "autoSwitchedFromPrimary": true, "desktopSyncEnabled": true,
         "desktopAutoSwitchEnabled": false}
        """
        let file = try JSONDecoder().decode(AccountsFile.self, from: Data(legacy.utf8))
        XCTAssertEqual(file.accounts[0].provider, .claude)
        XCTAssertEqual(file.activeByProvider, [.claude: id])
        XCTAssertTrue(file.isAutoSwitchedFromPrimary(.claude))
        XCTAssertFalse(file.isAutoSwitchedFromPrimary(.codex))
        XCTAssertTrue(file.isAutoSwitchEnabled(.claude)) // 구 전역 키 → 양쪽 풀 적용
        XCTAssertTrue(file.isAutoSwitchEnabled(.codex))
        XCTAssertNil(file.active(of: .codex))
        // Claude 경계 뷰도 동일하게 보인다
        XCTAssertEqual(file.activeAccountID, id)
        XCTAssertTrue(file.autoSwitchedFromPrimary)
    }

    func testV2RoundtripWithBothPools() throws {
        let c = profile("claude1", .claude)
        let x = profile("codex1", .codex)
        var file = AccountsFile(accounts: [c, x])
        file.activeByProvider = [.claude: c.id, .codex: x.id]
        file.autoSwitchedByProvider = [.codex: true]
        let back = try JSONDecoder().decode(AccountsFile.self,
                                            from: try JSONEncoder().encode(file))
        XCTAssertEqual(back, file)
    }

    // MARK: 풀 접근자

    func testPoolAccessorsAreProviderScoped() {
        let c1 = profile("c1", .claude); let c2 = profile("c2", .claude)
        let x1 = profile("x1", .codex); let x2 = profile("x2", .codex)
        var file = AccountsFile(accounts: [c1, x1, c2, x2]) // 섞인 순서
        file.activeByProvider = [.claude: c2.id, .codex: x1.id]

        XCTAssertEqual(file.accounts(of: .claude).map(\.nickname), ["c1", "c2"])
        XCTAssertEqual(file.accounts(of: .codex).map(\.nickname), ["x1", "x2"])
        XCTAssertEqual(file.primary(of: .claude)?.id, c1.id)
        XCTAssertEqual(file.primary(of: .codex)?.id, x1.id)
        XCTAssertEqual(file.active(of: .claude)?.id, c2.id)
        XCTAssertEqual(file.active(of: .codex)?.id, x1.id)
        // 타 프로바이더 계정 id가 활성으로 걸려 있으면 무시된다 (방어)
        file.activeByProvider[.codex] = c1.id
        XCTAssertNil(file.active(of: .codex))
    }

    // MARK: AccountStore — (provider, email) 매칭과 풀별 상태

    func makeStore() throws -> AccountStore {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-pool-\(UUID().uuidString)")
        let env = MobiusEnvironment(home: tmp, localUser: "tester")
        return try AccountStore(env: env, keychain: InMemoryKeychain())
    }

    func upsert(_ store: AccountStore, _ nickname: String, _ provider: Provider,
                email: String) throws -> AccountProfile {
        try store.upsertProfile(
            nickname: nickname, provider: provider,
            identity: ProviderIdentity(emailAddress: email, organizationName: "",
                                       tierDescription: "Pro"),
            secretData: Data("secret-\(nickname)".utf8))
    }

    func testSameEmailOnDifferentProvidersAreSeparateProfiles() throws {
        let store = try makeStore()
        let c = try upsert(store, "c", .claude, email: "same@x.com")
        let x = try upsert(store, "x", .codex, email: "same@x.com")
        XCTAssertEqual(store.file.accounts.count, 2)
        XCTAssertNotEqual(c.id, x.id)
        // 같은 (provider, email) 재등록은 갱신
        let x2 = try upsert(store, "x-renamed", .codex, email: "same@x.com")
        XCTAssertEqual(x2.id, x.id)
        XCTAssertEqual(store.file.accounts.count, 2)
    }

    func testFirstAccountPerPoolAutoActivatesIndependently() throws {
        let store = try makeStore()
        let c = try upsert(store, "c", .claude, email: "c@x.com")
        XCTAssertEqual(store.file.activeByProvider[.claude], c.id)
        let x = try upsert(store, "x", .codex, email: "x@x.com")
        // codex 첫 계정 자동 활성 — claude 활성은 건드리지 않는다
        XCTAssertEqual(store.file.activeByProvider[.codex], x.id)
        XCTAssertEqual(store.file.activeByProvider[.claude], c.id)
        // 두 번째 codex 계정은 활성을 뺏지 않는다
        let x2 = try upsert(store, "x2", .codex, email: "x2@x.com")
        XCTAssertEqual(store.file.activeByProvider[.codex], x.id)
        XCTAssertNotEqual(store.file.activeByProvider[.codex], x2.id)
    }

    func testMoveFallbackScopedToProviderKeepsInterleavedOrder() throws {
        let store = try makeStore()
        _ = try upsert(store, "c1", .claude, email: "c1@x")
        _ = try upsert(store, "x1", .codex, email: "x1@x")
        _ = try upsert(store, "c2", .claude, email: "c2@x")
        _ = try upsert(store, "x2", .codex, email: "x2@x")
        _ = try upsert(store, "x3", .codex, email: "x3@x")
        // codex 풀 내 fallback 재배열: x3을 x2 앞으로 (풀 내 인덱스 2→1)
        try store.moveFallback(provider: .codex, fromIndex: 2, toIndex: 1)
        XCTAssertEqual(store.file.accounts(of: .codex).map(\.nickname), ["x1", "x3", "x2"])
        // claude 계정들의 순서와 전체 배열 내 위치(인터리브)는 불변
        XCTAssertEqual(store.file.accounts(of: .claude).map(\.nickname), ["c1", "c2"])
        XCTAssertEqual(store.file.accounts.map(\.nickname), ["c1", "x1", "c2", "x3", "x2"])
        // 풀 primary(인덱스 0) 이동 금지
        XCTAssertThrowsError(try store.moveFallback(provider: .codex, fromIndex: 0, toIndex: 1))
    }

    func testSetPrimaryScopedToProviderGroup() throws {
        let store = try makeStore()
        _ = try upsert(store, "c1", .claude, email: "c1@x")
        _ = try upsert(store, "x1", .codex, email: "x1@x")
        let x2 = try upsert(store, "x2", .codex, email: "x2@x")
        try store.setAutoSwitchedFromPrimary(true, provider: .codex)
        try store.setAutoSwitchedFromPrimary(true, provider: .claude)

        try store.setPrimary(x2.id)
        XCTAssertEqual(store.file.accounts(of: .codex).map(\.nickname), ["x2", "x1"])
        XCTAssertEqual(store.file.primary(of: .claude)?.nickname, "c1") // 타 풀 불변
        XCTAssertFalse(store.file.isAutoSwitchedFromPrimary(.codex))    // 자기 풀 리셋
        XCTAssertTrue(store.file.isAutoSwitchedFromPrimary(.claude))    // 타 풀 유지
    }

    func testRemoveFixesOwnPoolActiveOnly() throws {
        let store = try makeStore()
        let c = try upsert(store, "c", .claude, email: "c@x")
        let x1 = try upsert(store, "x1", .codex, email: "x1@x")
        let x2 = try upsert(store, "x2", .codex, email: "x2@x")
        try store.remove(x1.id) // codex 활성 제거 → 남은 codex 계정으로
        XCTAssertEqual(store.file.activeByProvider[.codex], x2.id)
        XCTAssertEqual(store.file.activeByProvider[.claude], c.id)
        try store.remove(x2.id) // 마지막 codex 계정 제거 → codex 활성 없음
        XCTAssertNil(store.file.activeByProvider[.codex])
        XCTAssertEqual(store.file.activeByProvider[.claude], c.id)
    }

    // MARK: AutoSwitchEngine — 풀 독립

    func testEngineOnlySeesOwnProviderPool() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let c1 = profile("c1", .claude); let c2 = profile("c2", .claude)
        let x1 = profile("x1", .codex); let x2 = profile("x2", .codex)
        var file = AccountsFile(accounts: [c1, c2, x1, x2])
        file.activeByProvider = [.claude: c1.id, .codex: x1.id]

        let hit = RateLimitHit(resetsAt: now.addingTimeInterval(3600))
        // codex 엔진: codex 활성 소진 → 다음 codex 계정으로 (claude 계정은 후보가 아니다)
        XCTAssertEqual(AutoSwitchEngine(provider: .codex).onRateLimitHit(file: file, hit: hit, now: now),
                       .switchTo(x2.id, reason: .activeExhausted))
        // claude 엔진은 같은 상황에서 claude 풀만 본다
        XCTAssertEqual(AutoSwitchEngine(provider: .claude).onRateLimitHit(file: file, hit: hit, now: now),
                       .switchTo(c2.id, reason: .activeExhausted))
    }

    func testEngineTickRecoversPrimaryPerPool() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let x1 = profile("x1", .codex); let x2 = profile("x2", .codex)
        var file = AccountsFile(accounts: [x1, x2])
        // codex: 자동 전환으로 x2 활성, x1(primary)은 리셋 지남
        file.activeByProvider = [.codex: x2.id]
        file.autoSwitchedByProvider = [.codex: true]
        XCTAssertEqual(AutoSwitchEngine(provider: .codex).onTick(file: file, now: now),
                       .switchTo(x1.id, reason: .primaryRecovered))
        // claude 엔진은 codex 상태에 반응하지 않는다 (claude 풀 비어 있음)
        XCTAssertEqual(AutoSwitchEngine(provider: .claude).onTick(file: file, now: now), .none)
    }
}
