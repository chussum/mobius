import XCTest
@testable import MobiusCore

/// 설계 7.1·7.2: 격리 환경(메모리 키체인 + 임시 MOBIUS_HOME)에서 Switcher 왕복, 바이트 이메일 대조,
/// 롤백 없음, 기대 상태 재확인, 프로바이더 오류 격리(4.6).
final class AntigravitySwitcherTests: XCTestCase {
    var env: MobiusEnvironment!
    var kc: InMemoryKeychain!
    var store: AccountStore!
    var fake: FakeSecurity!
    var agy: AntigravityConfigIO!
    var codexIO: CodexConfigIO!
    var switcher: Switcher!

    override func setUpWithError() throws {
        env = AgyFixtures.tempEnv()
        try FileManager.default.createDirectory(at: env.codexDir, withIntermediateDirectories: true)
        kc = InMemoryKeychain()
        store = try AccountStore(env: env, keychain: kc)
        fake = FakeSecurity()
        agy = fake.makeIO()
        codexIO = CodexConfigIO(env: env)
        switcher = Switcher(env: env, keychain: kc, store: store, io: ClaudeConfigIO(env: env, keychain: kc),
                            extraIOs: [codexIO, agy])
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.appSupportDir.path)
        try? FileManager.default.removeItem(at: env.home)
    }

    /// agy 에서 로그인한 것처럼 라이브 값을 바꾸고(1초 해상도 mdat 이 바뀌게) adopt 를 돌린다.
    @discardableResult
    private func login(_ email: String, refresh: String = "rt") async throws -> AccountProfile? {
        fake.now += 2
        fake.set(AgyFixtures.secret(email, refresh: refresh))
        return try await switcher.adoptLiveAccountIfUnregistered()
    }

    // MARK: 등록과 전환 왕복 (7.2)

    func testAdoptTwoAccountsAndSwitchRoundTrip() async throws {
        let one = try await login("one@gmail.com")
        let two = try await login("two@gmail.com")
        let a = try XCTUnwrap(one), b = try XCTUnwrap(two)
        XCTAssertEqual(store.file.accounts(of: .antigravity).map(\.emailAddress), ["one@gmail.com", "two@gmail.com"])
        XCTAssertEqual(store.file.activeByProvider[.antigravity], b.id)
        XCTAssertEqual(try store.secretData(for: a.id), AgyFixtures.secret("one@gmail.com"))

        try switcher.switchTo(a.id)
        XCTAssertEqual(fake.value(), AgyFixtures.secret("one@gmail.com"))
        XCTAssertEqual(store.file.activeByProvider[.antigravity], a.id)
        XCTAssertEqual(try agy.liveEmail(), "one@gmail.com")
        try switcher.switchTo(b.id)
        XCTAssertEqual(fake.value(), AgyFixtures.secret("two@gmail.com"))
        // 다음 대사는 자기 쓰기를 외부 변경으로 세지 않는다
        let gen = store.activeGeneration(of: .antigravity)
        _ = await switcher.reconcileIsolated()
        XCTAssertEqual(store.activeGeneration(of: .antigravity), gen)
        XCTAssertTrue(store.file.accounts(of: .claude).isEmpty, "다른 풀은 그대로")
    }

    func testSwitchResavesLiveBytesIntoTheirOwnProfileBeforeWriting() async throws {
        let a = try await login("one@gmail.com")!
        let b = try await login("two@gmail.com")!
        // 같은 이메일로 다시 로그인해 받은 새 refresh 토큰
        fake.now += 2
        fake.set(AgyFixtures.secret("two@gmail.com", refresh: "rt-new"))
        try switcher.switchTo(a.id)
        XCTAssertEqual(try store.secretData(for: b.id), AgyFixtures.secret("two@gmail.com", refresh: "rt-new"))
    }

    func testReconcileSavesChangedLiveValueForActiveProfile() async throws {
        let b = try await login("two@gmail.com")!
        _ = await switcher.reconcileIsolated()   // 앱 틱처럼 adopt 뒤 대사가 지문 기준을 잡는다
        fake.now += 2
        fake.set(AgyFixtures.secret("two@gmail.com", refresh: "relogin"))
        let gen = store.activeGeneration(of: .antigravity)
        _ = await switcher.reconcileIsolated()
        XCTAssertEqual(try store.secretData(for: b.id), AgyFixtures.secret("two@gmail.com", refresh: "relogin"),
                       "같은 이메일 재로그인의 새 토큰을 스냅샷에 저장한다(설계 4.2)")
        XCTAssertEqual(store.activeGeneration(of: .antigravity), gen + 1, "라이브 바이트가 바뀌면 새 세대")
    }

    func testSwitchRefusesSnapshotOfAnotherAccount() async throws {
        let a = try await login("one@gmail.com")!
        _ = try await login("two@gmail.com")
        try store.setSecretData(AgyFixtures.secret("intruder@gmail.com"), for: a.id)
        let writes = fake.writes
        XCTAssertThrowsError(try switcher.switchTo(a.id)) {
            XCTAssertEqual($0 as? SwitcherError, .secretIdentityMismatch)
        }
        XCTAssertEqual(fake.writes, writes)
        XCTAssertEqual(fake.value(), AgyFixtures.secret("two@gmail.com"))
    }

    func testResaveUsesByteEmailNotSeparatelyReadEmail() async throws {
        _ = try await login("one@gmail.com")
        let b = try await login("two@gmail.com")!
        // 라이브는 one 인데(사용자가 바꿈) 메모리 캐시 이메일은 two 일 수 있는 틈 — 바이트로 고른다
        fake.set(AgyFixtures.secret("one@gmail.com", refresh: "fresh-one"))   // 같은 초: mdat 그대로
        let id = try switcher.resaveLiveIntoMatchingProfile(provider: .antigravity)
        XCTAssertNotEqual(id, b.id)
        XCTAssertEqual(try store.secretData(for: b.id), AgyFixtures.secret("two@gmail.com"))
    }

    // MARK: 롤백 없음 (설계 4.5)

    func testNoRollbackWhenSaveFailsAfterKeychainWrite() async throws {
        let a = try await login("one@gmail.com")!
        let b = try await login("two@gmail.com")!
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: env.appSupportDir.path)
        let writesBefore = fake.writes
        XCTAssertThrowsError(try switcher.switchTo(a.id)) { error in
            guard case SwitcherError.liveWrittenButSaveFailed = error else {
                return XCTFail("liveWrittenButSaveFailed 여야 한다: \(error)")
            }
        }
        XCTAssertEqual(fake.writes, writesBefore + 1, "키체인 쓰기는 한 번 — 되돌리는 쓰기가 없다")
        XCTAssertEqual(fake.value(), AgyFixtures.secret("one@gmail.com"), "키체인은 그대로 둔다")
        XCTAssertEqual(store.file.activeByProvider[.antigravity], b.id, "메모리 활성은 이전 값")
        // 다음 reconcile 이 라이브를 따라 맞춘다
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.appSupportDir.path)
        _ = await switcher.reconcileIsolated()
        XCTAssertEqual(store.file.activeByProvider[.antigravity], a.id)
    }

    func testKeychainWriteFailureDoesNotRollBackOrMarkActive() async throws {
        let a = try await login("one@gmail.com")!
        let b = try await login("two@gmail.com")!
        fake.nextWriteResult = .timedOut
        XCTAssertThrowsError(try switcher.switchTo(a.id))
        XCTAssertEqual(store.file.activeByProvider[.antigravity], b.id)
        XCTAssertTrue(agy.isLiveStateUnknown)
        XCTAssertEqual(fake.calls.filter { $0 == ["-i"] }.count, 1, "롤백 쓰기 없음")
    }

    // MARK: 기대 상태 재확인 (설계 4.7 「비동기 경합」)

    func testExpectationIsCheckedAfterResaveRightBeforeWrite() async throws {
        let a = try await login("one@gmail.com")!
        _ = try await login("two@gmail.com")
        var checkedWithReads = -1
        let writes = fake.writes
        XCTAssertThrowsError(try switcher.switchTo(a.id) { [fake] _ in
            checkedWithReads = fake!.valueReads
            return false
        }) { XCTAssertEqual($0 as? SwitcherError, .expectationChanged) }
        XCTAssertGreaterThan(checkedWithReads, 0, "되저장 읽기 뒤에 부른다")
        XCTAssertEqual(fake.writes, writes, "취소하면 쓰지 않는다")
    }

    /// 리뷰 1회차 Claude P1-1·Codex P1-3: 기대 상태 확인 뒤, 어댑터가 쓰기 직전에 읽은 값이 다르면
    /// (그사이 끝난 agy 로그인) 쓰지 않는다.
    func testAutoSwitchDoesNotOverwriteLoginFinishedAfterCheck() async throws {
        let a = try await login("one@gmail.com")!
        let b = try await login("two@gmail.com")!
        let start = try XCTUnwrap(AntigravityExpectation.begin(departure: b, store: store, io: agy))
        let writes = fake.writes
        XCTAssertThrowsError(try switcher.switchTo(a.id, expectedLiveFingerprint: start.liveFingerprint) { [fake] _ in
            fake!.now += 1
            fake!.set(AgyFixtures.secret("new@gmail.com"))   // 확인은 통과한 뒤 로그인이 끝났다
            return true
        }) { XCTAssertEqual($0 as? SwitcherError, .expectationChanged) }
        XCTAssertEqual(fake.writes, writes, "쓰지 않는다")
        XCTAssertEqual(fake.value(), AgyFixtures.secret("new@gmail.com"), "사용자의 새 로그인이 남는다")
        XCTAssertEqual(store.file.activeByProvider[.antigravity], b.id)
    }

    /// 리뷰 1회차 Claude P1-1: 기대값은 조회 **전에** 잡는다 — 조회 중 로그인이 바뀌면 holds 가 거짓.
    func testExpectationCapturedBeforeFetchRejectsLoginDuringFetch() async throws {
        _ = try await login("one@gmail.com")
        let b = try await login("two@gmail.com")!
        let e = try XCTUnwrap(AntigravityExpectation.begin(departure: b, store: store, io: agy))
        XCTAssertEqual(e.liveFingerprint, AntigravitySecret.fingerprint(AgyFixtures.secret("two@gmail.com")))
        // 조회(await) 중에 사용자가 다른 계정으로 로그인하고, 이후 무언가가 라이브를 읽었다
        fake.now += 2
        fake.set(AgyFixtures.secret("three@gmail.com"))
        _ = try agy.readLiveSecretData()
        XCTAssertFalse(e.holds(models: [], store: store, liveFingerprint: agy.liveFingerprint,
                               memory: AntigravityAutoSwitchMemory(), forSwitch: false, now: Date()))
        // 라이브가 출발 계정이 아니면 작업을 시작하지 않는다
        XCTAssertNil(AntigravityExpectation.begin(departure: b, store: store, io: agy))
    }

    /// 리뷰 1회차 Codex P2-4: "모름" 상태의 확인 일정 전에는 수동 전환도 라이브를 읽지 않는다.
    func testManualSwitchHonorsUnknownSchedule() async throws {
        let a = try await login("one@gmail.com")!
        let b = try await login("two@gmail.com")!
        fake.nextWriteResult = .timedOut
        XCTAssertThrowsError(try switcher.switchTo(a.id))
        XCTAssertTrue(agy.isLiveStateUnknown)
        let reads = fake.valueReads
        XCTAssertThrowsError(try switcher.switchTo(b.id)) {
            XCTAssertEqual($0 as? AntigravityConfigError, .liveStateUnknown)
        }
        XCTAssertEqual(fake.valueReads, reads, "확인 예정 시각 전에는 읽지 않는다")
    }

    /// 리뷰 2회차 Codex P1-2: 같은 이메일로 다시 로그인한 뒤 대사보다 먼저 작업이 시작되면, 작업 시작
    /// 읽기에서 본 지문 변화도 세대에 반영해 이전 로그인의 관측과 비교하지 않는다.
    func testSameEmailReloginStartsNewGenerationAtWorkStart() async throws {
        _ = try await login("one@gmail.com")
        let b = try await login("two@gmail.com")!
        _ = await switcher.reconcileIsolated()   // 앱처럼 지문 기준을 잡는다
        let gen0 = store.activeGeneration(of: .antigravity)
        let mem = AntigravityAutoSwitchMemory()
        let reset = "2026-11-20T05:00:00Z"
        _ = mem.observeActive(b.id, report: AgyFixtures.report([("gemini-3-flash", 0.5, reset)]), generation: gen0)
        // 다음 대사 전에 같은 이메일로 다시 로그인했다
        fake.now += 2
        fake.set(AgyFixtures.secret("two@gmail.com", refresh: "rt2"))
        let e = try XCTUnwrap(AntigravityExpectation.begin(departure: b, store: store, io: agy))
        XCTAssertNotEqual(e.generation, gen0, "작업 시작 읽기에서 본 지문 변화로 세대가 바뀐다")
        XCTAssertEqual(store.activeGeneration(of: .antigravity), e.generation)
        let trigger = mem.observeActive(b.id, report: AgyFixtures.report([("gemini-3-flash", 0, reset)]),
                                        generation: e.generation)
        XCTAssertTrue(trigger.isEmpty, "이전 로그인의 양수 관측과 비교하지 않는다")
    }

    /// 리뷰 2회차 Codex P1-1: 계정 목록을 읽지 못해 저장이 막힌 스토어로는 라이브도 바꾸지 않는다.
    func testSwitchRefusedWhileSavesAreBlocked() async throws {
        let a = try await login("one@gmail.com")!
        _ = try await login("two@gmail.com")
        let blocked = AccountStore(env: env, keychain: kc, afterLoadFailure: CocoaError(.fileReadNoPermission))
        try blocked.replaceFile(with: store.file)   // 메모리에는 계정이 있다(떠 있는 동안 다시 읽기 실패)
        let s = Switcher(env: env, keychain: kc, store: blocked, io: ClaudeConfigIO(env: env, keychain: kc),
                         extraIOs: [codexIO, agy])
        let writes = fake.writes
        XCTAssertThrowsError(try s.switchTo(a.id)) {
            XCTAssertEqual($0 as? AccountStoreError, .savesBlockedAfterLoadFailure)
        }
        XCTAssertEqual(fake.writes, writes)
    }

    /// 리뷰 2회차 Codex P1-3: 마지막 라이브 읽기 동안 자동 전환을 끄면 쓰지 않는다.
    func testAutoSwitchRechecksExpectationAfterFinalRead() async throws {
        let a = try await login("one@gmail.com")!
        let b = try await login("two@gmail.com")!
        let start = try XCTUnwrap(AntigravityExpectation.begin(departure: b, store: store, io: agy))
        let enabled = LockedFlag(true)
        // 되저장 읽기(1번째) 다음, 어댑터의 마지막 읽기(2번째)가 값을 얻은 뒤 사용자가 끈다
        fake.afterValueReadOnce = { [fake] in fake!.afterValueReadOnce = { enabled.set(false) } }
        let writes = fake.writes
        XCTAssertThrowsError(try switcher.switchTo(a.id, expectedLiveFingerprint: start.liveFingerprint) { _ in
            enabled.value
        }) { XCTAssertEqual($0 as? SwitcherError, .expectationChanged) }
        XCTAssertEqual(fake.writes, writes, "쓰지 않는다")
        XCTAssertEqual(fake.value(), AgyFixtures.secret("two@gmail.com"))
    }

    /// 리뷰 2회차 Codex P1-3: 마지막 라이브 읽기 동안 대상 계정이 지워지면 쓰지 않는다.
    func testAutoSwitchRechecksTargetRegistrationAfterFinalRead() async throws {
        let a = try await login("one@gmail.com")!
        let b = try await login("two@gmail.com")!
        let start = try XCTUnwrap(AntigravityExpectation.begin(departure: b, store: store, io: agy))
        fake.afterValueReadOnce = { [fake, store] in
            fake!.afterValueReadOnce = { try? store!.remove(a.id) }
        }
        let writes = fake.writes
        XCTAssertThrowsError(try switcher.switchTo(a.id, expectedLiveFingerprint: start.liveFingerprint) { _ in true }) {
            XCTAssertEqual($0 as? SwitcherError, .expectationChanged)
        }
        XCTAssertEqual(fake.writes, writes, "지워진 계정의 바이트를 설치하지 않는다")
    }

    /// 리뷰 2회차 Claude P3-1·Codex P2-2: 대사는 **자기가 커밋한** 활성 변경만 "라이브를 따라갔다"로
    /// 보고한다. 대사 중에 CLI 전환을 다시 읽어 활성이 이미 바뀌었으면 보고하지 않는다.
    func testReconcileReportsOnlyActiveChangesItCommitted() async throws {
        let a = try await login("one@gmail.com")!
        let b = try await login("two@gmail.com")!
        _ = await switcher.reconcileIsolated()
        // 이전 세션이 라이브를 a 로 되돌렸다 — 대사가 따라가고 보고한다
        fake.now += 2
        fake.set(AgyFixtures.secret("one@gmail.com"))
        let r1 = await switcher.reconcileIsolatedReportingFollowed(providers: [.antigravity])
        XCTAssertEqual(r1.followed[.antigravity], a.id)
        // `mobius switch two`: CLI 가 키체인을 쓰고, 대사가 안정 읽기를 하는 사이 앱이 CLI 의 저장을 다시 읽는다
        fake.now += 2
        fake.set(AgyFixtures.secret("two@gmail.com"))
        fake.afterValueReadOnce = { [fake, store] in
            fake!.afterValueReadOnce = { try? store!.setActive(b.id) }
        }
        let r2 = await switcher.reconcileIsolatedReportingFollowed(providers: [.antigravity])
        XCTAssertEqual(store.file.activeByProvider[.antigravity], b.id)
        XCTAssertNil(r2.followed[.antigravity], "대사가 바꾼 것이 아니다")
    }

    /// 리뷰 3회차 Codex P1-2: 자가복구는 결정을 내린 세대를 넘기고, 작업 시작 읽기가 세대를 바꾸면(같은
    /// 이메일 재로그인) 그 결정을 버린다 — 이전 로그인의 소진 기록으로 새 로그인을 덮지 않게.
    func testBeginRejectsDecisionFromEarlierGeneration() async throws {
        _ = try await login("one@gmail.com")
        let b = try await login("two@gmail.com")!
        _ = await switcher.reconcileIsolated()
        let decidedAt = store.activeGeneration(of: .antigravity)
        XCTAssertNotNil(AntigravityExpectation.begin(departure: b, store: store, io: agy, decidedAt: decidedAt),
                        "그대로면 진행한다")
        fake.now += 2
        fake.set(AgyFixtures.secret("two@gmail.com", refresh: "rt2"))   // 같은 이메일로 다시 로그인
        XCTAssertNil(AntigravityExpectation.begin(departure: b, store: store, io: agy, decidedAt: decidedAt),
                     "작업 시작 읽기가 세대를 바꿨다 — 이전 세대의 결정은 버린다")
    }

    /// 리뷰 3회차 Codex P1-3: 마지막 확인은 디스크 사본 **하나**로 설정·리비전·출발 계정·대상 등록을 함께
    /// 본다 — 기대 상태 클로저는 Switcher 가 읽은 그 사본을 받는다.
    func testFinalCheckUsesOneDiskSnapshot() async throws {
        let a = try await login("one@gmail.com")!
        let b = try await login("two@gmail.com")!
        try store.setAutoSwitch(true, provider: .antigravity)
        let start = try XCTUnwrap(AntigravityExpectation.begin(departure: b, store: store, io: agy))
        // 마지막 키체인 읽기 동안 디스크의 자동 전환을 끈다 — 클로저가 받는 사본에서 보인다
        fake.afterValueReadOnce = { [fake, store] in
            fake!.afterValueReadOnce = { try? store!.setAutoSwitch(false, provider: .antigravity) }
        }
        let seen = LockedFlag(true)
        let writes = fake.writes
        XCTAssertThrowsError(try switcher.switchTo(a.id, expectedLiveFingerprint: start.liveFingerprint) { disk in
            seen.set(disk.isAutoSwitchEnabled(.antigravity))
            return disk.isAutoSwitchEnabled(.antigravity)
        }) { XCTAssertEqual($0 as? SwitcherError, .expectationChanged) }
        XCTAssertFalse(seen.value)
        XCTAssertEqual(fake.writes, writes)
    }

    /// 리뷰 3회차 Claude P2-1: CLI 읽기 전용 명령은 Antigravity 활성을 디스크에 저장하지 않는다 — 앱보다
    /// 먼저 라이브를 따라가 저장하면, 앱 대사가 그 변경을 자기가 커밋한 것으로 보지 못해 왕복을 놓친다.
    func testReadOnlyDisplayReconcileLeavesAntigravityFollowToApp() async throws {
        let a = try await login("one@gmail.com")!
        let b = try await login("two@gmail.com")!
        _ = await switcher.reconcileIsolated()
        XCTAssertEqual(store.file.activeByProvider[.antigravity], b.id)
        // 이전 one 세션이 키체인을 one 으로 되돌린다
        fake.now += 2
        fake.set(AgyFixtures.secret("one@gmail.com"))
        // CLI `mobius status`(별도 프로세스)
        let cliStore = try AccountStore(env: env, keychain: kc)
        let cli = Switcher(env: env, keychain: kc, store: cliStore, io: ClaudeConfigIO(env: env, keychain: kc),
                           extraIOs: [codexIO, fake.makeIO()])
        let failed = await cli.reconcileForDisplay()
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(cliStore.file.activeByProvider[.antigravity], a.id, "CLI 출력은 라이브를 보여 준다")
        XCTAssertEqual(try AccountStore(env: env, keychain: kc).file.activeByProvider[.antigravity], b.id,
                       "디스크에는 저장하지 않는다")
        // 앱의 대사가 따라가고 그 변경을 보고한다(왕복 판정의 입력)
        let r = await switcher.reconcileIsolatedReportingFollowed(providers: [.antigravity])
        XCTAssertEqual(r.followed[.antigravity], a.id)
    }

    /// 리뷰 4회차 Codex P1-1: CLI `list`·`status` 는 **어느 풀도** 저장하지 않는다 — CLI 가 목록을 읽은 뒤
    /// 다른 프로세스가 더한 계정을, Claude·Codex 대사의 저장이 낡은 사본으로 지우지 않게.
    func testReadOnlyDisplayDoesNotSaveAnyPool() async throws {
        let x = try store.upsertProfile(nickname: "x", provider: .codex,
                                        identity: ProviderIdentity(emailAddress: "x@c.com", organizationName: "",
                                                                   tierDescription: ""),
                                        secretData: CodexFixtures.authJSON(email: "x@c.com"))
        let y = try store.upsertProfile(nickname: "y", provider: .codex,
                                        identity: ProviderIdentity(emailAddress: "y@c.com", organizationName: "",
                                                                   tierDescription: ""),
                                        secretData: CodexFixtures.authJSON(email: "y@c.com"))
        XCTAssertEqual(store.file.activeByProvider[.codex], x.id)
        // CLI 가 목록을 읽는다
        let cliStore = try AccountStore(env: env, keychain: kc)
        let cli = Switcher(env: env, keychain: kc, store: cliStore, io: ClaudeConfigIO(env: env, keychain: kc),
                           extraIOs: [codexIO, fake.makeIO()])
        // 그 뒤 다른 프로세스가 Codex 계정을 더하고, 밖에서 Codex 로그인이 y 로 바뀐다
        let z = try store.upsertProfile(nickname: "z", provider: .codex,
                                        identity: ProviderIdentity(emailAddress: "z@c.com", organizationName: "",
                                                                   tierDescription: ""),
                                        secretData: CodexFixtures.authJSON(email: "z@c.com"))
        try codexIO.writeLiveSecretData(CodexFixtures.authJSON(email: "y@c.com"))
        let before = try Data(contentsOf: env.accountsFile)
        let failed = await cli.reconcileForDisplay()
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(cliStore.file.activeByProvider[.codex], y.id, "CLI 출력은 라이브를 보여 준다")
        XCTAssertEqual(try Data(contentsOf: env.accountsFile), before, "디스크에는 저장하지 않는다")
        XCTAssertTrue(try AccountStore(env: env, keychain: kc).file.accounts.contains { $0.id == z.id })
    }

    /// 리뷰 4회차 Codex P3·Claude P3-1: 비어 있던 활성을 채운 대사(구버전 저장 뒤 복원)는 따라간 변경이지만
    /// "밖에서 바뀌었어요" 알림 대상이 아니다 — 앱이 가려낼 수 있게 따로 돌려준다.
    func testReconcileReportsFillingEmptyActiveSeparately() async throws {
        let a = try await login("one@gmail.com")!
        _ = try await login("two@gmail.com")
        try store.mutateFresh { $0.activeByProvider[.antigravity] = nil }
        fake.now += 2
        fake.set(AgyFixtures.secret("one@gmail.com"))
        let r = await switcher.reconcileIsolatedReportingFollowed(providers: [.antigravity])
        XCTAssertEqual(r.followed[.antigravity], a.id)
        XCTAssertEqual(r.filledEmpty, [.antigravity])
        // 다른 계정에서 바뀐 것은 채움이 아니다
        fake.now += 2
        fake.set(AgyFixtures.secret("two@gmail.com"))
        let r2 = await switcher.reconcileIsolatedReportingFollowed(providers: [.antigravity])
        XCTAssertNotNil(r2.followed[.antigravity])
        XCTAssertTrue(r2.filledEmpty.isEmpty)
    }

    /// 리뷰 1회차 Codex P2-3: 구버전 저장 직후 CLI list·status 는 디스크에 쓰지 않고 라이브 신원을
    /// 메모리 활성에 반영한 뒤 출력한다.
    func testReadOnlyReflectsLiveActiveWithoutSaving() async throws {
        _ = try await login("one@gmail.com")
        let two = try await login("two@gmail.com")!
        let legacy = try JSONDecoder().decode(V053AccountsFile.self, from: Data(contentsOf: env.accountsFile))
        try JSONEncoder().encode(legacy).write(to: env.accountsFile)
        let before = try Data(contentsOf: env.accountsFile)
        let cliStore = try AccountStore(env: env, keychain: kc)
        XCTAssertTrue(cliStore.restoredAfterLegacySave)
        XCTAssertNil(cliStore.file.activeByProvider[.antigravity])
        let cli = Switcher(env: env, keychain: kc, store: cliStore, io: ClaudeConfigIO(env: env, keychain: kc),
                           extraIOs: [codexIO, fake.makeIO()])
        let failed = cli.reflectLiveActiveWithoutSaving()
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(cliStore.file.activeByProvider[.antigravity], two.id)
        XCTAssertEqual(try Data(contentsOf: env.accountsFile), before, "파일에 저장하지 않는다")
    }

    // MARK: 오류 격리 (설계 4.6)

    func testThrowingAdapterDoesNotStopOtherPools() async throws {
        // Codex 라이브 계정 등록 상태에서 agy 읽기가 실패해도 Codex 대사는 끝난다
        let x = try store.upsertProfile(nickname: "x", provider: .codex,
                                        identity: ProviderIdentity(emailAddress: "x@c.com", organizationName: "",
                                                                   tierDescription: ""),
                                        secretData: CodexFixtures.authJSON(email: "x@c.com"))
        let y = try store.upsertProfile(nickname: "y", provider: .codex,
                                        identity: ProviderIdentity(emailAddress: "y@c.com", organizationName: "",
                                                                   tierDescription: ""),
                                        secretData: CodexFixtures.authJSON(email: "y@c.com"))
        XCTAssertEqual(store.file.activeByProvider[.codex], x.id)
        try codexIO.writeLiveSecretData(CodexFixtures.authJSON(email: "y@c.com"))
        fake.set(AgyFixtures.secret("one@gmail.com"))
        fake.nextReadResult = .exited(status: 1, stdout: Data(), stderr: Data())
        let failed = await switcher.reconcileIsolated()
        XCTAssertNotNil(failed[.antigravity])
        XCTAssertNil(failed[.codex])
        XCTAssertEqual(store.file.activeByProvider[.codex], y.id, "agy 오류 뒤에도 Codex 대사가 돈다")
        // 호환 API 는 끝까지 돈 뒤 첫 오류를 던진다
        fake.now += AntigravityConfigIO.failedReadRetry + 10
        fake.nextReadResult = .exited(status: 1, stdout: Data(), stderr: Data())
        do { try await switcher.reconcile(); XCTFail("던져야 한다") } catch {}
    }

    /// 응답하지 않는 어댑터(승인 대기에 걸린 security)를 진짜 프로세스로 주입한다 — 제한 시간이
    /// 막아 나머지 풀이 처리된다.
    func testHangingAdapterTimesOutAndOtherPoolsProceed() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("hang-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let hanging = AntigravityConfigIO(keychain: CLIKeychain(
            runner: ProcessSecurityRunner(executable: script), timeout: 0.5,
            attributeReader: { _, _ in .found(modified: Date()) }))
        let sw = Switcher(env: env, keychain: kc, store: store, io: ClaudeConfigIO(env: env, keychain: kc),
                          extraIOs: [codexIO, hanging])
        let x = try store.upsertProfile(nickname: "x", provider: .codex,
                                        identity: ProviderIdentity(emailAddress: "x@c.com", organizationName: "",
                                                                   tierDescription: ""),
                                        secretData: CodexFixtures.authJSON(email: "x@c.com"))
        _ = try store.upsertProfile(nickname: "y", provider: .codex,
                                    identity: ProviderIdentity(emailAddress: "y@c.com", organizationName: "",
                                                               tierDescription: ""),
                                    secretData: CodexFixtures.authJSON(email: "y@c.com"))
        try codexIO.writeLiveSecretData(CodexFixtures.authJSON(email: "x@c.com"))
        try store.setActive(store.file.accounts(of: .codex)[1].id)
        let start = Date()
        let failed = await sw.reconcileIsolated()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(failed[.antigravity] as? CLIKeychainError, .timedOut)
        XCTAssertEqual(store.file.activeByProvider[.codex], x.id)
    }

    func testCodexSwitchRefusesMismatchedSnapshotToo() throws {
        let x = try store.upsertProfile(nickname: "x", provider: .codex,
                                        identity: ProviderIdentity(emailAddress: "x@c.com", organizationName: "",
                                                                   tierDescription: ""),
                                        secretData: CodexFixtures.authJSON(email: "other@c.com"))
        XCTAssertThrowsError(try switcher.switchTo(x.id)) {
            XCTAssertEqual($0 as? SwitcherError, .secretIdentityMismatch)
        }
    }
}
