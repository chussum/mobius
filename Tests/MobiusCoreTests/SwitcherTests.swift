import XCTest
@testable import MobiusCore

final class SwitcherTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var kc: InMemoryKeychain!
    var store: AccountStore!; var io: ClaudeConfigIO!; var switcher: Switcher!
    var personal: AccountProfile!; var work: AccountProfile!

    func snap(email: String, tok: String, org: String = "") -> CredentialsSnapshot {
        let orgField = org.isEmpty ? "" : #","organizationUuid":"\#(org)""#
        return CredentialsSnapshot(
            keychainBlob: Data(#"{"tok":"\#(tok)"}"#.utf8),
            credentialsFileData: Data(#"{"tok":"\#(tok)"}"#.utf8),
            oauthAccountJSON: Data(#"{"emailAddress":"\#(email)","organizationName":"O"\#(orgField)}"#.utf8))
    }

    /// 실제 Claude blob 형태(refreshToken 포함) — 딱지 해제 판정이 읽는 필드가 들어 있다.
    func oauthSnap(email: String, access: String, refresh: String) -> CredentialsSnapshot {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8)
        return CredentialsSnapshot(
            keychainBlob: blob, credentialsFileData: blob,
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

    // MARK: 계정 열쇠 = 이메일 + 조직 (실패 기록 23)
    // 한 이메일이 개인 Max·회사 Team·회사 Enterprise에 동시에 속한다. 이메일만으로 대조하면
    // 두 번째 조직으로 로그인한 순간 첫 프로필이 그 조직의 토큰으로 덮어써진다.

    /// 같은 이메일의 **다른 조직**으로 밖에서 로그인해도 기존 프로필을 건드리지 않는다.
    func testReconcileDoesNotMergeDifferentOrganizationOnSameEmail() async throws {
        let team = try store.upsertProfile(nickname: "team", snapshot: snap(email: "t@x.com", tok: "T0", org: "org-team"))
        try io.writeLiveSnapshot(snap(email: "t@x.com", tok: "T0", org: "org-team"))
        try store.setActive(team.id)

        // 같은 이메일, 다른 조직(개인 Max)으로 외부 로그인
        try io.writeLiveSnapshot(snap(email: "t@x.com", tok: "M-ext", org: "org-max"))
        try await switcher.reconcile()

        XCTAssertEqual(try store.secret(for: team.id)?.keychainBlob, Data(#"{"tok":"T0"}"#.utf8),
                       "다른 조직의 토큰이 Team 프로필에 저장되면 안 된다")
        XCTAssertEqual(store.file.accounts.count, 3, "reconcile은 모르는 계정을 등록하지 않는다(adopt 몫)")
    }

    /// 같은 이메일의 두 번째 조직은 adopt가 **새 프로필**로 흡수한다 — 닉네임은 겹치지 않게.
    func testAdoptRegistersSecondOrganizationOnSameEmail() async throws {
        let team = try store.upsertProfile(nickname: "t", snapshot: snap(email: "t@x.com", tok: "T0", org: "org-team"))
        try io.writeLiveSnapshot(snap(email: "t@x.com", tok: "M0", org: "org-max"))

        let adopted = try await switcher.adoptLiveAccountIfUnregistered()
        let max = try XCTUnwrap(adopted)
        XCTAssertNotEqual(max.id, team.id)
        XCTAssertEqual(max.organizationUuid, "org-max")
        XCTAssertNotEqual(max.nickname, "t", "같은 풀에서 닉네임이 겹치면 CLI switch가 고를 수 없다")
        XCTAssertEqual(store.file.activeAccountID, max.id)
        XCTAssertEqual(try store.secret(for: team.id)?.keychainBlob, Data(#"{"tok":"T0"}"#.utf8))
        XCTAssertEqual(try store.secret(for: max.id)?.keychainBlob, Data(#"{"tok":"M0"}"#.utf8))

        // 이미 등록된 조직이면 다시 흡수하지 않는다
        let again = try await switcher.adoptLiveAccountIfUnregistered()
        XCTAssertNil(again)
    }

    /// 같은 이메일의 두 조직 사이를 전환하면 라이브 열쇠가 바뀌고, 떠나는 쪽의 최신 토큰은 **자기**
    /// 프로필에만 되저장된다.
    func testSwitchBetweenOrganizationsOnSameEmail() throws {
        let team = try store.upsertProfile(nickname: "team", snapshot: snap(email: "t@x.com", tok: "T0", org: "org-team"))
        let max = try store.upsertProfile(nickname: "max", snapshot: snap(email: "t@x.com", tok: "M0", org: "org-max"))
        try io.writeLiveSnapshot(snap(email: "t@x.com", tok: "T1", org: "org-team")) // claude가 갱신한 상태
        try store.setActive(team.id)

        try switcher.switchTo(max.id)

        XCTAssertEqual(try io.liveAccountKey(), AccountKey(emailAddress: "t@x.com", organizationUuid: "org-max"))
        XCTAssertEqual(store.file.activeAccountID, max.id)
        XCTAssertEqual(try store.secret(for: team.id)?.keychainBlob, Data(#"{"tok":"T1"}"#.utf8),
                       "떠나는 Team의 갱신 토큰은 Team 프로필에")
        XCTAssertEqual(try store.secret(for: max.id)?.keychainBlob, Data(#"{"tok":"M0"}"#.utf8),
                       "Max 프로필은 그대로")
    }

    /// 구버전 프로필(조직 미상)은 저장 스냅샷의 oauthAccount에서 조직을 채운다 — 라이브를 보지 않는다.
    func testBackfillOrganizationUUIDsFromStoredSnapshot() throws {
        // 구버전 바이너리가 만든 상태를 흉내 낸다: 스냅샷엔 조직이 있는데 프로필 필드는 비어 있다
        let legacy = try store.upsertProfile(nickname: "old", snapshot: snap(email: "o@x.com", tok: "O0", org: "org-old"))
        try store.update(legacy.id) { $0.organizationUuid = "" }
        // 라이브는 같은 이메일의 **다른** 조직 — 여기서 채우면 오귀속이다
        try io.writeLiveSnapshot(snap(email: "o@x.com", tok: "N0", org: "org-new"))

        let filled = try switcher.backfillOrganizationUUIDs()

        XCTAssertEqual(filled, [legacy.id])
        XCTAssertEqual(store.file.accounts.first { $0.id == legacy.id }?.organizationUuid, "org-old")
        // 이미 채워진 프로필과 조직 정보가 없는 스냅샷은 건드리지 않는다
        XCTAssertEqual(try switcher.backfillOrganizationUUIDs(), [])
        XCTAssertEqual(store.file.accounts.first { $0.id == personal.id }?.organizationUuid, "")
    }

    /// backfill은 조직 UUID만이 아니라 **이름·등급까지** 스냅샷 기준으로 맞춘다. 이 버그를 이미
    /// 맞은 프로필은 되저장이 비밀만 덮어쓴 탓에 라벨과 토큰이 어긋나 있을 수 있고, UUID만 찍으면
    /// "카드는 회사 조직인데 실제로는 개인 계정"인 상태가 그대로 굳는다.
    func testBackfillAlsoRealignsLabelsWithStoredSnapshot() throws {
        let oauth = #"{"emailAddress":"m@x.com","organizationName":"m@x.com's Organization","organizationUuid":"org-personal","organizationRateLimitTier":"default_claude_max_20x"}"#
        let snapshot = CredentialsSnapshot(
            keychainBlob: Data(#"{"tok":"P0"}"#.utf8),
            credentialsFileData: Data(#"{"tok":"P0"}"#.utf8),
            oauthAccountJSON: Data(oauth.utf8))
        let mislabeled = try store.upsertProfile(nickname: "mislabeled", snapshot: snapshot)
        // 구버전 되저장이 남긴 상태: 라벨은 회사 조직을 가리키는데 저장 토큰은 개인 Max의 것
        try store.update(mislabeled.id) {
            $0.organizationUuid = ""
            $0.organizationName = "Acme Team"
            $0.tierDescription = "Team"
        }

        XCTAssertEqual(try switcher.backfillOrganizationUUIDs(), [mislabeled.id])

        let healed = store.file.accounts.first { $0.id == mislabeled.id }
        XCTAssertEqual(healed?.organizationUuid, "org-personal")
        XCTAssertEqual(healed?.organizationName, "m@x.com's Organization")
        XCTAssertEqual(healed?.tierDescription, "Max 20x", "`capitalized`가 만들던 \"20X\"가 아니다")
        XCTAssertEqual(healed?.organizationLabel, "",
                       "개인 구독의 자동 생성 조직 이름은 카드에 안 띄운다")
    }

    /// 스냅샷이 이름·등급을 모르면 **덮어쓰지 않는다** — 구버전 oauthAccount에는 organizationName이
    /// 없을 수 있고, 그때 빈 값으로 밀면 어긋남은 안 줄고 멀쩡한 표시만 사라진다.
    func testBackfillKeepsExistingLabelsWhenSnapshotHasNone() throws {
        let oauth = #"{"emailAddress":"q@x.com","organizationUuid":"org-q"}"#
        let snapshot = CredentialsSnapshot(
            keychainBlob: Data(#"{"tok":"Q0"}"#.utf8),
            credentialsFileData: Data(#"{"tok":"Q0"}"#.utf8),
            oauthAccountJSON: Data(oauth.utf8))
        let sparse = try store.upsertProfile(nickname: "sparse", snapshot: snapshot)
        try store.update(sparse.id) {
            $0.organizationUuid = ""
            $0.organizationName = "Acme Team"
            $0.tierDescription = "Team"
        }

        XCTAssertEqual(try switcher.backfillOrganizationUUIDs(), [sparse.id])

        let healed = store.file.accounts.first { $0.id == sparse.id }
        XCTAssertEqual(healed?.organizationUuid, "org-q")
        XCTAssertEqual(healed?.organizationName, "Acme Team")
        XCTAssertEqual(healed?.tierDescription, "Team")
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

    // MARK: needsReauth 해제 — refresh 토큰 회전 (이슈 #14)
    // 딱지를 자동으로 내리는 경로가 usage 200 하나뿐이었고 그건 '사용량 게이지 표시' 토글에
    // 물려 있었다 → 게이지를 끄면 딱지가 일방향 래치가 된다. 라이브 스냅샷을 저장할 때
    // refresh 토큰이 실제로 교체됐으면(=재로그인/성공한 회전) 딱지를 내려 그 틈을 메운다.

    private func reauthFlag(_ id: UUID) -> Bool {
        store.file.accounts.first { $0.id == id }?.needsReauth ?? false
    }

    func testRefreshActiveSnapshotClearsReauthWhenRefreshTokenRotated() async throws {
        try io.writeLiveSnapshot(oauthSnap(email: "p@x.com", access: "A0", refresh: "R0"))
        _ = await switcher.refreshActiveSnapshotIfStable()   // 저장 스냅샷을 R0로 맞춘다
        try store.setNeedsReauth(personal.id, true)          // 그 뒤 폐기 판정을 받은 상태

        // 사용자가 CLI에서 재로그인 → 라이브 refresh 토큰이 R1으로 교체됨
        try io.writeLiveSnapshot(oauthSnap(email: "p@x.com", access: "A1", refresh: "R1"))
        let wrote = await switcher.refreshActiveSnapshotIfStable()

        XCTAssertTrue(wrote)
        XCTAssertFalse(reauthFlag(personal.id), "refresh 토큰이 교체됐으면 딱지를 내려야 한다")
    }

    func testRefreshActiveSnapshotKeepsReauthWhenTokenUnchanged() async throws {
        // ★ 회귀 가드: "저장 바이트가 바뀌면 해제"로 넓히면 여기서 딱지가 풀린다.
        //   활성 계정의 라이브 스냅샷은 5분마다 무조건 되저장되므로, 진짜 죽은 계정도
        //   같은 죽은 토큰이 계속 저장된다 → 딱지가 5분 이상 버티지 못하고 엔진이
        //   죽은 계정을 정상 후보로 취급하게 된다.
        try io.writeLiveSnapshot(oauthSnap(email: "p@x.com", access: "A0", refresh: "R0"))
        _ = await switcher.refreshActiveSnapshotIfStable()
        try store.setNeedsReauth(personal.id, true)

        // access 토큰만 바뀌고 refresh 토큰은 그대로 = 살아있다는 증거가 아니다
        try io.writeLiveSnapshot(oauthSnap(email: "p@x.com", access: "A1", refresh: "R0"))
        let wrote = await switcher.refreshActiveSnapshotIfStable()

        XCTAssertTrue(wrote)
        XCTAssertTrue(reauthFlag(personal.id), "refresh 토큰이 그대로면 딱지를 유지해야 한다")
    }

    func testReconcileClearsReauthOnExternalRelogin() async throws {
        // 딱지가 붙은 채 폴백으로 밀려난 계정(work)에 사용자가 앱 밖에서 재로그인한 상황
        try store.setSecret(oauthSnap(email: "w@x.com", access: "A0", refresh: "R0"), for: work.id)
        try store.setNeedsReauth(work.id, true)

        try io.writeLiveSnapshot(oauthSnap(email: "w@x.com", access: "A1", refresh: "R1"))
        try await switcher.reconcile()

        XCTAssertEqual(store.file.activeAccountID, work.id)
        XCTAssertFalse(reauthFlag(work.id))
    }

    func testLiveSaveSkipsPreviousSnapshotReadWhenNotFlagged() async throws {
        // 실패 기록 3b: 값싼 조건을 먼저. 딱지가 없는 정상 계정(대다수)은 이전 스냅샷을
        // 읽을 이유가 없다 — 비밀 파일이 없으면 secretData가 구버전 Keychain 항목까지
        // 찾아보므로(security subprocess), 조건 없이 읽으면 5분마다 그 비용을 낸다.
        let secretService = AccountStore.secretService(for: personal.id)
        try FileManager.default.removeItem(at: env.secretFile(for: personal.id))
        try io.writeLiveSnapshot(oauthSnap(email: "p@x.com", access: "A1", refresh: "R1"))

        var wrote = await switcher.refreshActiveSnapshotIfStable()
        XCTAssertTrue(wrote)
        XCTAssertNil(kc.readsByService[secretService], "딱지가 없으면 이전 스냅샷을 읽지 않는다")

        // 딱지가 붙으면 그때만 읽는다 — 해제 판정에 이전 토큰이 필요하므로.
        try store.setNeedsReauth(personal.id, true)
        try io.writeLiveSnapshot(oauthSnap(email: "p@x.com", access: "A2", refresh: "R2"))
        wrote = await switcher.refreshActiveSnapshotIfStable()
        XCTAssertTrue(wrote)
        XCTAssertFalse(reauthFlag(personal.id))
    }

    func testResaveOnSwitchClearsReauthOfOutgoingAccount() async throws {
        // 전환 직전 되저장 경로 — 떠나는 계정의 라이브 토큰이 그새 회전했다면 그것도 증거다.
        try io.writeLiveSnapshot(oauthSnap(email: "p@x.com", access: "A0", refresh: "R0"))
        _ = await switcher.refreshActiveSnapshotIfStable()
        try store.setNeedsReauth(personal.id, true)

        try io.writeLiveSnapshot(oauthSnap(email: "p@x.com", access: "A1", refresh: "R1"))
        try switcher.switchTo(work.id)

        XCTAssertEqual(store.file.activeAccountID, work.id)
        XCTAssertFalse(reauthFlag(personal.id))
    }

    // MARK: 토큰과 신원이 어긋난 라이브 (실패 기록 24)
    // 같은 이메일의 회사 Team과 개인 Max. 토큰(Keychain)과 oauthAccount(~/.claude.json)는 claude의
    // 서로 다른 경로가 따로 쓰므로, 한쪽 조직의 토큰이 다른 조직의 oauthAccount와 함께 놓이는 순간이 있다.

    static let teamAccount = #"{"emailAddress":"t@x.com","organizationName":"acme-team","organizationType":"claude_team","organizationRateLimitTier":"default_raven","seatTier":"team_tier_1","organizationUuid":"org-team"}"#
    static let maxAccount = #"{"emailAddress":"t@x.com","organizationName":"t@x.com's Organization","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x","seatTier":null,"organizationUuid":"org-max"}"#

    /// token: 토큰이 실제로 속한 구독("team"/"max"), account: 함께 놓인 oauthAccount.
    func orgSnap(token: String, refresh: String, account: String) -> CredentialsSnapshot {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"A-\#(refresh)","refreshToken":"\#(refresh)","subscriptionType":"\#(token)"}}"#.utf8)
        return CredentialsSnapshot(keychainBlob: blob, credentialsFileData: blob, oauthAccountJSON: Data(account.utf8))
    }

    private func storedRefresh(_ id: UUID) throws -> String? {
        CredentialBlob.refreshToken(from: try XCTUnwrap(store.secret(for: id)).keychainBlob)
    }

    /// 두 조직 프로필을 등록하고 개인 Max를 활성으로 둔다(Mobius가 Max로 전환한 직후).
    private func setUpTwoOrganizations() throws -> (team: AccountProfile, max: AccountProfile) {
        let team = try store.upsertProfile(nickname: "team", snapshot: orgSnap(token: "team", refresh: "T0", account: Self.teamAccount))
        let max = try store.upsertProfile(nickname: "max", snapshot: orgSnap(token: "max", refresh: "M0", account: Self.maxAccount))
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "M0", account: Self.maxAccount))
        try store.setActive(max.id)
        return (team, max)
    }

    /// CLI `list`·`status`(읽기 전용 대사)는 라이브를 **계정 열쇠(이메일 + 조직)** 로 골라 메모리에만 반영한다 —
    /// 이메일만 보면 같은 이메일의 다른 조직 카드를 활성으로 보인다(Antigravity 브랜치 rebase 때 합친 경로).
    func testReadOnlyDisplayPicksProfileByOrganization() async throws {
        // 라이브는 개인 Max(배열에서 Team 뒤), 디스크 활성은 Team — 이메일만 보면 첫 번째인 Team 을 고른다.
        let (team, max) = try setUpTwoOrganizations()
        try store.setActive(team.id)
        let before = try Data(contentsOf: env.accountsFile)
        let failed = await switcher.reconcileForDisplay()
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(store.file.activeByProvider[.claude], max.id, "라이브 조직(Max)의 카드를 보인다")
        XCTAssertEqual(try Data(contentsOf: env.accountsFile), before, "디스크에는 저장하지 않는다")
    }

    /// 사고 재현 ①: Max가 활성인데 Keychain에 Team 토큰이 있다(oauthAccount는 Max 그대로). 2.1.281에서는
    /// Keychain 토큰이 invalid_grant로 빈 문자열이 된 뒤 Team 토큰을 쥔 세션의 refresh가 CAS를 통과해 채울 때
    /// 생긴다. 5분 동기화가 이걸 Max 프로필에 저장하면 두 카드가 Team 사용량을 보이고 한 계보를 나눠 갖는다.
    func testActiveSyncRefusesTokenFromOtherOrganization() async throws {
        let (team, max) = try setUpTwoOrganizations()
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "T1", account: Self.maxAccount))

        let wrote = await switcher.refreshActiveSnapshotIfStable()

        XCTAssertFalse(wrote, "어긋난 라이브는 신선한 스냅샷이 아니다")
        XCTAssertEqual(try storedRefresh(max.id), "M0", "Max 프로필에 Team 토큰이 들어가면 안 된다")
        XCTAssertEqual(try storedRefresh(team.id), "T0")
    }

    /// 사고 재현 ②: 반대 방향 — Keychain은 Max 토큰인데 oauthAccount가 Team으로 되써졌다(옛 토큰을 쥔
    /// 세션의 bootstrap). reconcile이 열쇠만 보고 Team을 활성으로 옮기며 Max 토큰을 Team에 저장하던 자리다.
    func testReconcileIgnoresLiveWhoseTokenBelongsToAnotherOrganization() async throws {
        let (team, max) = try setUpTwoOrganizations()
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "M1", account: Self.teamAccount))

        try await switcher.reconcile()

        XCTAssertEqual(store.file.activeAccountID, max.id, "열쇠가 가리키는 Team은 실제 로그인이 아니다")
        XCTAssertEqual(try storedRefresh(team.id), "T0")
        XCTAssertEqual(try storedRefresh(max.id), "M0")
    }

    /// 리뷰 P2-1: 신원만 되돌려진 라이브는 새 claude 세션이 다시 bootstrap할 때까지 그대로일 수 있다. reconcile이
    /// 15초마다 같은 라이브를 다시 읽어 거부하면 그때마다 Keychain을 두 번 읽는다(`security` subprocess).
    func testReconcileDoesNotRereadKeychainForSameRejectedLive() async throws {
        let (team, max) = try setUpTwoOrganizations()
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "M1", account: Self.teamAccount))
        let service = env.claudeKeychainService
        let before = kc.readsByService[service, default: 0]

        try await switcher.reconcile()
        let afterFirst = kc.readsByService[service, default: 0]
        XCTAssertGreaterThan(afterFirst, before, "처음에는 읽어서 판정한다")

        try await switcher.reconcile()
        try await switcher.reconcile()

        XCTAssertEqual(kc.readsByService[service, default: 0], afterFirst, "거부한 라이브가 그대로면 다시 읽지 않는다")
        XCTAssertEqual(store.file.activeAccountID, max.id)
        XCTAssertEqual(try storedRefresh(team.id), "T0")
    }

    /// 거부한 뒤라도 다시 로그인하면(로그인은 oauthAccount를 다시 쓴다) 곧바로 따라간다. "라이브 이메일이 활성과
    /// 같으면 조기 반환"으로 막았다면, 같은 이메일의 다른 조직으로 앱 밖에서 로그인한 이 경우를 놓친다.
    /// ★ 이 테스트는 "재로그인하면 신원 지문이 바뀐다"를 가정한다(`profileFetchedAt`을 넣어 흉내 낸다). claude
    ///   2.1.283 실측: 같은 조직으로 `claude auth login`을 다시 하면 oauthAccount는 `profileFetchedAt`만 로그인
    ///   시각으로 바뀌고 나머지는 바이트 단위로 같다(바이너리에서도 로그인 경로가 `profileFetchedAt: Date.now()`를
    ///   쓴다). 이 필드가 빠지는 버전이 나오면, 같은 조직 재로그인은 불일치로 기억된 동안(최대
    ///   `deferredLiveRecheckInterval`) 늦게 따라간다 — 토큰은 새 계보라 손상되지 않는다.
    func testReconcileFollowsReloginAfterRejectedLive() async throws {
        let (team, _) = try setUpTwoOrganizations()
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "M1", account: Self.teamAccount))
        try await switcher.reconcile()   // 거부 — 지문을 기억한다

        let relogged = Self.teamAccount.replacingOccurrences(of: #""seatTier""#, with: #""profileFetchedAt":1,"seatTier""#)
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "T2", account: relogged))
        try await switcher.reconcile()

        XCTAssertEqual(store.file.activeAccountID, team.id)
        XCTAssertEqual(try storedRefresh(team.id), "T2")
    }

    /// 조직이 어긋난 거부는 신원 지문이 그대로면 긴 간격(`deferredLiveRecheckInterval`) 동안 다시 읽지 않는다.
    /// 그사이 claude가 같은 계보 안에서 토큰을 회전해도 판정은 바뀌지 않는다 — 다른 계보로 바뀌는 일은 CAS 규칙상
    /// 빈 토큰일 때만 생기고, 그건 아래 로그아웃 거부의 짧은 간격이 따라간다. 간격이 지나면 다시 읽는다.
    func testReconcileRechecksMismatchedLiveOnlyAfterLongInterval() async throws {
        let (team, max) = try setUpTwoOrganizations()
        switcher.loggedOutLiveRecheckInterval = 0   // 조직 불일치에는 짧은 간격이 쓰이지 않아야 한다
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "M1", account: Self.teamAccount))
        try await switcher.reconcile()   // 거부
        let service = env.claudeKeychainService
        let afterFirst = kc.readsByService[service, default: 0]

        // 같은 계보 안의 회전(M1 → M2) — 신원은 그대로다
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "M2", account: Self.teamAccount))
        let afterWrite = kc.readsByService[service, default: 0]
        try await switcher.reconcile()
        XCTAssertEqual(kc.readsByService[service, default: 0], afterWrite, "간격 안에서는 다시 읽지 않는다")
        XCTAssertEqual(afterWrite, afterFirst, "라이브 쓰기 자체는 Keychain 읽기를 일으키지 않는다")

        switcher.deferredLiveRecheckInterval = 0
        try await switcher.reconcile()
        XCTAssertGreaterThan(kc.readsByService[service, default: 0], afterWrite, "간격이 지나면 다시 읽는다")
        XCTAssertEqual(store.file.activeAccountID, max.id, "다시 읽어도 여전히 거부한다")
        XCTAssertEqual(try storedRefresh(team.id), "T0")
    }

    /// 리뷰 3회차 P2-2: 빈 토큰(로그인 없음) 거부는 짧게만 기억한다. 2.1.281에서 빈 자리는 다른 세션의 refresh가
    /// CAS로 채울 수 있고, 그때 신원은 그대로라 지문이 바뀌지 않는다. 5분을 기다리면 그동안 활성 표시가 실제
    /// 로그인과 다르고, 실제 라이브 계정이 폴백으로 취급되어 refresh 대상이 된다.
    func testReconcileFollowsTokenFilledIntoEmptySlotAfterShortInterval() async throws {
        let (team, _) = try setUpTwoOrganizations()
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "", account: Self.teamAccount))
        try await switcher.reconcile()   // 로그인 없음 — 거부
        XCTAssertNotEqual(store.file.activeAccountID, team.id)

        // Team 토큰을 쥔 세션의 refresh가 빈 자리를 채웠다(신원은 그대로)
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "T5", account: Self.teamAccount))
        try await switcher.reconcile()
        XCTAssertEqual(try storedRefresh(team.id), "T0", "짧은 간격 안에서는 아직 읽지 않는다")

        switcher.loggedOutLiveRecheckInterval = 0   // 긴 간격(기본 5분)은 그대로 둔다
        try await switcher.reconcile()
        XCTAssertEqual(store.file.activeAccountID, team.id)
        XCTAssertEqual(try storedRefresh(team.id), "T5")
    }

    /// 리뷰 3회차 P1: Mobius가 Team으로 전환한 뒤, 옛 Max 토큰을 캐시한 세션의 bootstrap이 신원을 Max로 되돌리고,
    /// 이어서 Team 토큰을 쥔 세션의 refresh가 프로필을 다시 받아 seatTier만 `"team_tier_1"`로 덮었다
    /// (organizationUuid·organizationType은 Max 그대로 — claude 2.1.281 실측). seatTier를 먼저 보던 판정은 이걸
    /// "Team 토큰 + Team 신원"으로 읽어, reconcile이 Team 토큰을 Max 프로필에 저장하고 Max를 활성으로 옮겼다.
    func testRefreshOverwrittenSeatTierDoesNotMixOrganizations() async throws {
        let (team, max) = try setUpTwoOrganizations()
        try store.setActive(team.id)
        let seatOverwritten = Self.maxAccount.replacingOccurrences(of: #""seatTier":null"#, with: #""seatTier":"team_tier_1""#)
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "T1", account: seatOverwritten))

        try await switcher.reconcile()
        XCTAssertEqual(store.file.activeAccountID, team.id, "열쇠가 가리키는 Max는 실제 로그인이 아니다")
        XCTAssertEqual(try storedRefresh(max.id), "M0", "Max 프로필에 Team 토큰이 들어가면 안 된다")

        let wrote = await switcher.refreshActiveSnapshotIfStable()
        XCTAssertTrue(wrote, "토큰은 활성 Team 프로필의 계보라 보정해 저장한다")
        XCTAssertEqual(try storedRefresh(team.id), "T1")
        XCTAssertEqual(try storedRefresh(max.id), "M0")
    }

    /// 리뷰 3회차 P2-1: adopt도 거부한 라이브를 기억한다. 등록하지 않은 조직의 신원에 다른 종류의 토큰이 놓인
    /// 상태(예: 죽은 로그인의 카드를 지운 뒤)가 이어지는 동안 15초마다 Keychain을 두 번 읽지 않는다.
    func testAdoptDoesNotRereadKeychainForSameRejectedLive() async throws {
        _ = try setUpTwoOrganizations()
        let unregistered = Self.teamAccount.replacingOccurrences(of: "org-team", with: "org-other")
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "M1", account: unregistered))
        let service = env.claudeKeychainService
        let before = kc.readsByService[service, default: 0]

        let first = try await switcher.adoptLiveAccountIfUnregistered()
        XCTAssertNil(first, "섞인 라이브는 새 프로필로 흡수하지 않는다")
        let afterFirst = kc.readsByService[service, default: 0]
        XCTAssertGreaterThan(afterFirst, before)
        let accountCount = store.file.accounts.count

        _ = try await switcher.adoptLiveAccountIfUnregistered()
        _ = try await switcher.adoptLiveAccountIfUnregistered()
        XCTAssertEqual(kc.readsByService[service, default: 0], afterFirst, "거부한 라이브가 그대로면 다시 읽지 않는다")
        XCTAssertEqual(store.file.accounts.count, accountCount, "새 프로필이 생기지 않는다")
    }

    /// 보정(리뷰 P2-3): 옛 토큰을 캐시한 세션의 bootstrap이 oauthAccount만 Team으로 되돌렸다. Keychain의
    /// Max 토큰은 Mobius가 설치한 활성 프로필의 계보이므로, 동기화를 멈추지 않고 Max 프로필에 저장한다.
    /// 신원은 Max 저장본의 것을 쓴다 — 라이브의 oauthAccount는 되돌려진 옛 조직이다.
    func testActiveSyncReattributesTokenWhenOnlyAccountInfoWasReverted() async throws {
        let (team, max) = try setUpTwoOrganizations()
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "M1", account: Self.teamAccount))

        let wrote = await switcher.refreshActiveSnapshotIfStable()

        XCTAssertTrue(wrote)
        XCTAssertEqual(try storedRefresh(max.id), "M1", "회전된 Max 계보를 잃지 않는다")
        let maxSnap = try XCTUnwrap(store.secret(for: max.id))
        XCTAssertEqual(ClaudeConfigIO.identity(fromSnapshot: maxSnap)?.organizationUuid, "org-max")
        XCTAssertEqual(try storedRefresh(team.id), "T0")
        XCTAssertEqual(store.file.activeAccountID, max.id)
    }

    /// 같은 보정이 전환 직전 되저장에도 적용된다 — 떠나는 활성 프로필의 최신 계보를 챙긴 뒤 전환한다.
    func testSwitchResavesReattributedTokenIntoLeavingActive() throws {
        let (team, max) = try setUpTwoOrganizations()
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "M1", account: Self.teamAccount))

        try switcher.switchTo(team.id)

        XCTAssertEqual(try storedRefresh(max.id), "M1")
        XCTAssertEqual(ClaudeConfigIO.identity(fromSnapshot: try XCTUnwrap(store.secret(for: max.id)))?.organizationUuid,
                       "org-max")
        XCTAssertEqual(try storedRefresh(team.id), "T0")
        XCTAssertEqual(try io.liveAccountKey(), AccountKey(emailAddress: "t@x.com", organizationUuid: "org-team"))
    }

    /// 주인이 하나로 정해지지 않으면 보정하지 않는다 — 같은 이메일에 좌석형 조직이 둘이면 Team 토큰이
    /// 어느 쪽 것인지 종류만으로는 모른다.
    func testReattributionRefusesWhenTwoSeatProfilesCouldOwnTheToken() async throws {
        let teamB = #"{"emailAddress":"t@x.com","organizationName":"other-team","organizationType":"claude_team","seatTier":"team_tier_1","organizationUuid":"org-team-b"}"#
        let (team, _) = try setUpTwoOrganizations()
        let other = try store.upsertProfile(nickname: "team-b", snapshot: orgSnap(token: "team", refresh: "B0", account: teamB))
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "T0", account: Self.teamAccount))
        try store.setActive(team.id)
        // oauthAccount만 개인 Max로 되돌려진 상태 — 토큰은 Team 계열인데 Team 프로필이 둘이다
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "T1", account: Self.maxAccount))

        let wrote = await switcher.refreshActiveSnapshotIfStable()

        XCTAssertFalse(wrote)
        XCTAssertEqual(try storedRefresh(team.id), "T0")
        XCTAssertEqual(try storedRefresh(other.id), "B0")
    }

    /// 리뷰 2회차 P2-3: 다른 좌석형 프로필의 저장본이 빈 토큰이어도 주인 후보로 센다 — 건강한 저장본만
    /// 세면 Team B의 새 토큰이 활성 Team A에 붙어 Team A의 계보가 덮인다.
    func testReattributionCountsOwnersWhoseStoredSnapshotIsUnhealthy() async throws {
        let teamB = #"{"emailAddress":"t@x.com","organizationName":"other-team","organizationType":"claude_team","seatTier":"team_tier_1","organizationUuid":"org-team-b"}"#
        let (team, _) = try setUpTwoOrganizations()
        let other = try store.upsertProfile(nickname: "team-b", snapshot: orgSnap(token: "team", refresh: "", account: teamB))
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "T0", account: Self.teamAccount))
        try store.setActive(team.id)
        // Team B에 새로 로그인한 뒤 oauthAccount만 개인 Max로 되돌려진 상태
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "B1", account: Self.maxAccount))

        let wrote = await switcher.refreshActiveSnapshotIfStable()

        XCTAssertFalse(wrote)
        XCTAssertEqual(try storedRefresh(team.id), "T0", "Team A의 계보를 덮으면 안 된다")
        XCTAssertNil(try storedRefresh(other.id))
    }

    /// 리뷰 2회차 P3-2: 섞인 저장본은 라이브에 설치하지 않는다 — 사용자가 고른 카드와 다른 조직으로 로그인된다.
    func testSwitchRefusesMixedTargetSnapshot() throws {
        let (team, max) = try setUpTwoOrganizations()
        try store.setSecret(orgSnap(token: "team", refresh: "X0", account: Self.maxAccount), for: max.id)
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "T0", account: Self.teamAccount))
        try store.setActive(team.id)

        XCTAssertThrowsError(try switcher.switchTo(max.id)) { error in
            XCTAssertEqual(error as? SwitcherError, .mixedSnapshot)
        }
        XCTAssertEqual(store.file.activeAccountID, team.id)
        XCTAssertEqual(try io.liveAccountKey(), AccountKey(emailAddress: "t@x.com", organizationUuid: "org-team"))
    }

    /// 전환 직전 되저장도 같은 판정을 탄다 — 떠나는 프로필에 남의 조직 토큰을 박지 않고, 전환 자체는 진행한다.
    func testSwitchSkipsResaveOfMismatchedLiveButStillSwitches() throws {
        let (team, max) = try setUpTwoOrganizations()
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "T1", account: Self.maxAccount))

        try switcher.switchTo(team.id)

        XCTAssertEqual(store.file.activeAccountID, team.id)
        XCTAssertEqual(try io.liveAccountKey(), AccountKey(emailAddress: "t@x.com", organizationUuid: "org-team"))
        XCTAssertEqual(try storedRefresh(max.id), "M0", "되저장을 건너뛰어 Max 프로필이 오염되지 않는다")
    }

    /// adopt도 어긋난 라이브로는 새 프로필을 만들지 않는다.
    func testAdoptSkipsMismatchedLive() async throws {
        _ = try store.upsertProfile(nickname: "team", snapshot: orgSnap(token: "team", refresh: "T0", account: Self.teamAccount))
        try io.writeLiveSnapshot(orgSnap(token: "team", refresh: "T1", account: Self.maxAccount)) // Max는 미등록
        let adopted = try await switcher.adoptLiveAccountIfUnregistered()
        XCTAssertNil(adopted)
        XCTAssertFalse(store.file.accounts.contains { $0.organizationUuid == "org-max" })
    }

    /// claude는 invalid_grant를 받은 토큰을 빈 문자열로 지운다(실측 `.bak`). 로그인 없는 상태를 프로필 저장본으로
    /// 굳히지 않는다 — 저장본을 남겨 두면 폴백 검증이 그 토큰의 생사를 스스로 판정한다.
    func testActiveSyncDoesNotSaveLoggedOutBlob() async throws {
        let (_, max) = try setUpTwoOrganizations()
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "", account: Self.maxAccount))

        let wrote = await switcher.refreshActiveSnapshotIfStable()

        XCTAssertFalse(wrote)
        XCTAssertEqual(try storedRefresh(max.id), "M0")
    }

    /// 이미 빈 토큰이 저장된 프로필(수정 전 버전이 남긴 상태)에 CLI에서 다시 로그인하면 딱지가 풀린다.
    func testReauthClearsWhenReloginReplacesStoredBlankToken() async throws {
        let (_, max) = try setUpTwoOrganizations()
        try store.setSecret(orgSnap(token: "max", refresh: "", account: Self.maxAccount), for: max.id)
        try store.setNeedsReauth(max.id, true)
        try io.writeLiveSnapshot(orgSnap(token: "max", refresh: "M9", account: Self.maxAccount))

        let wrote = await switcher.refreshActiveSnapshotIfStable()

        XCTAssertTrue(wrote)
        XCTAssertFalse(reauthFlag(max.id), "빈 토큰 다음의 비지 않은 토큰은 새 로그인에서만 나온다")
    }

    /// 표시 규칙이 바뀌면 기존 프로필의 등급 문자열도 저장 스냅샷에서 다시 계산한다.
    func testRefreshTierLabelsReplacesStaleCodename() throws {
        let (team, max) = try setUpTwoOrganizations()
        try store.update(team.id) { $0.tierDescription = "Raven" }   // 수정 전 규칙이 만든 문자열
        try store.update(max.id) { $0.tierDescription = "Max 20X" }

        XCTAssertEqual(Set(try switcher.refreshTierLabels()), [team.id, max.id])
        XCTAssertEqual(store.file.accounts.first { $0.id == team.id }?.tierDescription, "Team")
        XCTAssertEqual(store.file.accounts.first { $0.id == max.id }?.tierDescription, "Max 20x")
        XCTAssertEqual(try switcher.refreshTierLabels(), [], "이미 맞으면 건드리지 않는다")
    }
}
