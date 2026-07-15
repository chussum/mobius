import XCTest
@testable import MobiusCore

/// Switcher의 Codex 경로: auth.json 스왑 전환, adopt 자동 등록, 외부 로그인 reconcile.
/// Claude 풀과의 격리(전환·활성이 서로를 건드리지 않음)도 함께 검증한다.
final class CodexSwitcherTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var kc: InMemoryKeychain!
    var store: AccountStore!; var io: ClaudeConfigIO!; var codexIO: CodexConfigIO!
    var switcher: Switcher!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-cxsw-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        try FileManager.default.createDirectory(at: env.codexDir, withIntermediateDirectories: true)
        kc = InMemoryKeychain()
        store = try AccountStore(env: env, keychain: kc)
        io = ClaudeConfigIO(env: env, keychain: kc)
        codexIO = CodexConfigIO(env: env)
        switcher = Switcher(env: env, keychain: kc, store: store, io: io, extraIOs: [codexIO])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func registerCodex(_ nickname: String, email: String, data: Data) throws -> AccountProfile {
        try store.upsertProfile(
            nickname: nickname, provider: .codex,
            identity: ProviderIdentity(emailAddress: email, organizationName: "",
                                       tierDescription: "Pro"),
            secretData: data)
    }

    func claudeSnap(email: String, tok: String) -> CredentialsSnapshot {
        CredentialsSnapshot(
            keychainBlob: Data(#"{"tok":"\#(tok)"}"#.utf8),
            credentialsFileData: Data(#"{"tok":"\#(tok)"}"#.utf8),
            oauthAccountJSON: Data(#"{"emailAddress":"\#(email)","organizationName":"O"}"#.utf8))
    }

    func testSwitchToCodexSwapsAuthJSONAndResavesCurrent() throws {
        let authA = CodexFixtures.authJSON(email: "a@corp.com")
        let authB = CodexFixtures.authJSON(email: "b@gmail.com")
        let a = try registerCodex("a", email: "a@corp.com", data: authA)
        let b = try registerCodex("b", email: "b@gmail.com", data: authB)
        // 라이브는 a — 단, 전환 직전에 codex가 리프레시한 최신 바이트라고 가정
        let authARefreshed = CodexFixtures.authJSON(email: "a@corp.com", accessToken: "at-refreshed")
        try codexIO.writeLiveSecretData(authARefreshed)
        try store.setActive(a.id)

        try switcher.switchTo(b.id)

        // auth.json이 b의 바이트로 통째 교체됨
        XCTAssertEqual(try Data(contentsOf: env.codexAuthFile), authB)
        XCTAssertEqual(try codexIO.liveEmail(), "b@gmail.com")
        XCTAssertEqual(store.file.activeByProvider[.codex], b.id)
        // 전환 직전의 최신(리프레시된) 바이트가 a 프로필에 되저장됨
        XCTAssertEqual(try store.secretData(for: a.id), authARefreshed)
    }

    func testCodexSwitchDoesNotTouchClaudePool() throws {
        // claude 로그인 상태 + 프로필 등록
        let cSnap = claudeSnap(email: "c@x.com", tok: "C0")
        let c = try store.upsertProfile(nickname: "c", snapshot: cSnap)
        try io.writeLiveSnapshot(cSnap)
        try store.setActive(c.id)
        // codex 두 계정 등록, a 활성
        let a = try registerCodex("a", email: "a@corp.com",
                                  data: CodexFixtures.authJSON(email: "a@corp.com"))
        try codexIO.writeLiveSecretData(CodexFixtures.authJSON(email: "a@corp.com"))
        try store.setActive(a.id)
        let b = try registerCodex("b", email: "b@gmail.com",
                                  data: CodexFixtures.authJSON(email: "b@gmail.com"))

        try switcher.switchTo(b.id)

        // claude 라이브·활성은 그대로
        XCTAssertEqual(try io.liveEmail(), "c@x.com")
        XCTAssertEqual(store.file.activeByProvider[.claude], c.id)
        XCTAssertEqual(store.file.activeByProvider[.codex], b.id)
    }

    func testAdoptRegistersLiveCodexAccount() async throws {
        let auth = CodexFixtures.authJSON(email: "dev@corp.com", plan: "pro")
        try codexIO.writeLiveSecretData(auth)

        let adopted = try await switcher.adoptLiveAccountIfUnregistered()

        let profile = try XCTUnwrap(adopted)
        XCTAssertEqual(profile.provider, .codex)
        XCTAssertEqual(profile.nickname, "dev")           // 이메일 로컬 파트
        XCTAssertEqual(profile.emailAddress, "dev@corp.com")
        XCTAssertEqual(profile.tierDescription, "Pro")    // JWT plan_type
        XCTAssertEqual(store.file.activeByProvider[.codex], profile.id)
        XCTAssertEqual(try store.secretData(for: profile.id), auth) // 바이트 보존
        // 재실행 시 중복 등록 없음
        let again = try await switcher.adoptLiveAccountIfUnregistered()
        XCTAssertNil(again)
        XCTAssertEqual(store.file.accounts.count, 1)
    }

    func testReconcileDetectsExternalCodexLogin() async throws {
        let authA = CodexFixtures.authJSON(email: "a@corp.com")
        let authB = CodexFixtures.authJSON(email: "b@gmail.com")
        let a = try registerCodex("a", email: "a@corp.com", data: authA)
        let b = try registerCodex("b", email: "b@gmail.com", data: authB)
        try codexIO.writeLiveSecretData(authA)
        try store.setActive(a.id)
        try store.setAutoSwitchedFromPrimary(true, provider: .codex)

        // 사용자가 앱 밖에서 codex logout && codex login으로 b에 로그인 (토큰 갱신됨)
        let authBExternal = CodexFixtures.authJSON(email: "b@gmail.com", accessToken: "at-ext")
        try codexIO.writeLiveSecretData(authBExternal)
        try await switcher.reconcile()

        XCTAssertEqual(store.file.activeByProvider[.codex], b.id)
        XCTAssertEqual(try store.secretData(for: b.id), authBExternal) // 최신 토큰 흡수
        // 외부 로그인 = 수동 상태 — 자동 복귀 예약 해제
        XCTAssertFalse(store.file.isAutoSwitchedFromPrimary(.codex))
    }

    func testReconcileUnknownCodexAccountDoesNothing() async throws {
        let a = try registerCodex("a", email: "a@corp.com",
                                  data: CodexFixtures.authJSON(email: "a@corp.com"))
        try codexIO.writeLiveSecretData(CodexFixtures.authJSON(email: "a@corp.com"))
        try store.setActive(a.id)

        try codexIO.writeLiveSecretData(CodexFixtures.authJSON(email: "stranger@x.com"))
        try await switcher.reconcile()
        XCTAssertEqual(store.file.activeByProvider[.codex], a.id) // 그대로
    }

    /// 구버전 바이너리가 accounts.json을 저장하며 per-account provider를 드롭 → 신버전이
    /// Codex 계정을 Claude로 흡수 → secret authority로 재도출해 되돌린다 (감지+복구+경고 근거).
    func testHealRestoresProviderLostByOldBinarySave() throws {
        let codex = try registerCodex("cx", email: "cx@corp.com",
                                      data: CodexFixtures.authJSON(email: "cx@corp.com"))
        let claude = try store.upsertProfile(nickname: "cl",
                                             snapshot: claudeSnap(email: "cl@x.com", tok: "t1"))

        // 구버전 저장 시뮬레이션: per-account "provider" 키 드롭(구 구조체엔 필드 없음).
        let url = env.accountsFile
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var accts = root["accounts"] as! [[String: Any]]
        for i in accts.indices { accts[i].removeValue(forKey: "provider") }
        root["accounts"] = accts
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        // 신버전 재로드 → provider 없는 계정은 ?? .claude 로 흡수 (재현 전제)
        let store2 = try AccountStore(env: env, keychain: kc)
        XCTAssertEqual(store2.file.accounts.first { $0.id == codex.id }?.provider, .claude)
        let switcher2 = Switcher(env: env, keychain: kc, store: store2, io: io, extraIOs: [codexIO])

        let fixed = try switcher2.healMisassignedProviders()

        XCTAssertEqual(fixed.count, 1)
        XCTAssertEqual(fixed.first?.id, codex.id)
        XCTAssertEqual(fixed.first?.from, .claude)
        XCTAssertEqual(fixed.first?.to, .codex)
        // Codex는 복구, Claude는 그대로(오정정 없음)
        XCTAssertEqual(store2.file.accounts.first { $0.id == codex.id }?.provider, .codex)
        XCTAssertEqual(store2.file.accounts.first { $0.id == claude.id }?.provider, .claude)

        // 영속 + 멱등: 다시 로드/heal해도 복구 유지, 추가 변경 없음
        let store3 = try AccountStore(env: env, keychain: kc)
        XCTAssertEqual(store3.file.accounts.first { $0.id == codex.id }?.provider, .codex)
        let again = try Switcher(env: env, keychain: kc, store: store3, io: io,
                                 extraIOs: [codexIO]).healMisassignedProviders()
        XCTAssertTrue(again.isEmpty)
    }

    /// 완전 다운그레이드: 구버전이 per-account provider뿐 아니라 **루트 activeByProvider까지**
    /// 드롭한 진짜 v1 재저장 형태. heal은 **provider만** 되돌리고 active는 채우지 않으며(라이브
    /// 미상 — 임의 active는 오라우팅/오전환 위험, 적대적 리뷰), **라이브를 읽는 reconcile**이
    /// 실제 활성을 채운다 — heal + 레거시 디코드 + reconcile 조합 검증.
    func testFullDowngradeHealRestoresProviderAndReconcileFillsActive() async throws {
        let cx1 = try registerCodex("cx1", email: "cx1@corp.com",
                                    data: CodexFixtures.authJSON(email: "cx1@corp.com"))
        let cx2 = try registerCodex("cx2", email: "cx2@gmail.com",
                                    data: CodexFixtures.authJSON(email: "cx2@gmail.com"))
        let claude = try store.upsertProfile(nickname: "cl",
                                             snapshot: claudeSnap(email: "cl@x.com", tok: "t1"))

        // 진짜 v1 재저장: per-account provider + 루트 풀별 키 전부 드롭.
        // (activeAccountID(legacy)는 남겨 둔다 — v1도 이 키는 썼다.)
        let url = env.accountsFile
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var accts = root["accounts"] as! [[String: Any]]
        for i in accts.indices { accts[i].removeValue(forKey: "provider") }
        root["accounts"] = accts
        for k in ["activeByProvider", "autoSwitchByProvider",
                  "autoSwitchedByProvider"] { root.removeValue(forKey: k) }
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        // 신버전 재로드: Codex 계정은 ?? .claude 흡수, Codex 풀 active는 비어 있어야(재현 전제)
        let store2 = try AccountStore(env: env, keychain: kc)
        XCTAssertEqual(store2.file.accounts.first { $0.id == cx1.id }?.provider, .claude)
        XCTAssertNil(store2.file.activeByProvider[.codex])
        let switcher2 = Switcher(env: env, keychain: kc, store: store2, io: io, extraIOs: [codexIO])

        // heal: provider는 되돌리되 active는 채우지 않는다(라이브 미상 — reconcile의 몫)
        let fixed = try switcher2.healMisassignedProviders()
        XCTAssertEqual(fixed.count, 2)
        XCTAssertEqual(store2.file.accounts.first { $0.id == cx1.id }?.provider, .codex)
        XCTAssertEqual(store2.file.accounts.first { $0.id == cx2.id }?.provider, .codex)
        XCTAssertNil(store2.file.activeByProvider[.codex])              // ★ heal은 active를 찍지 않음
        XCTAssertEqual(store2.file.activeByProvider[.claude], claude.id) // Claude 풀은 legacy로 복원됨

        // 라이브를 읽는 reconcile이 실제 활성(cx2)을 채운다
        try codexIO.writeLiveSecretData(CodexFixtures.authJSON(email: "cx2@gmail.com"))
        try await switcher2.reconcile()
        XCTAssertEqual(store2.file.activeByProvider[.codex], cx2.id)

        // 영속: 다시 로드해도 유지
        let store3 = try AccountStore(env: env, keychain: kc)
        XCTAssertEqual(store3.file.activeByProvider[.codex], cx2.id)
    }
}
