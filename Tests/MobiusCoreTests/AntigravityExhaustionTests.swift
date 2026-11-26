import XCTest
@testable import MobiusCore

/// 설계 7.1: 판정(같은 세대 전이·집합 M), 후보 확인, 엔진 정책, 메모리 하한, 비동기 재확인.
final class AntigravityExhaustionTests: XCTestCase {
    let r1 = "2026-11-19T18:00:00Z", r2 = "2026-11-19T20:00:00Z"
    let now = RFC3339.date(from: "2026-11-19T15:00:00Z")!

    private func base(_ pairs: [(String, Double)], gen: Int) -> [String: AntigravityBaseline] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, AntigravityBaseline(fraction: $0.1, generation: gen)) })
    }

    // MARK: 판정 (4.7 「판정」)

    func testTransitionWithinSameGenerationTriggers() {
        let prev = base([("gemini-3-flash", 0.2)], gen: 3)
        let cur = AgyFixtures.report([("gemini-3-flash", 0, r1)])
        let (m, next) = AntigravityExhaustion.evaluate(previous: prev, current: cur, generation: 3)
        XCTAssertEqual(m, ["gemini-3-flash"])
        XCTAssertEqual(next["gemini-3-flash"]?.fraction, 0)
    }

    func testFirstObservationOfNewGenerationOnlySetsBaseline() {
        let prev = base([("gemini-3-flash", 0.2)], gen: 3)
        let cur = AgyFixtures.report([("gemini-3-flash", 0, r1)])
        let (m, next) = AntigravityExhaustion.evaluate(previous: prev, current: cur, generation: 4)
        XCTAssertTrue(m.isEmpty, "이전 활성 기간의 값과 비교해 떠나지 않는다")
        XCTAssertEqual(next["gemini-3-flash"], AntigravityBaseline(fraction: 0, generation: 4))
    }

    func testZeroWithoutObservedTransitionDoesNothing() {
        let (m, _) = AntigravityExhaustion.evaluate(previous: [:], current: AgyFixtures.report([("gemini-3-flash", 0, r1)]),
                                                    generation: 1)
        XCTAssertTrue(m.isEmpty)
        let (m2, _) = AntigravityExhaustion.evaluate(previous: base([("gemini-3-flash", 0)], gen: 1),
                                                     current: AgyFixtures.report([("gemini-3-flash", 0, r1)]),
                                                     generation: 1)
        XCTAssertTrue(m2.isEmpty, "0 → 0 은 전이가 아니다")
    }

    func testSharedBucketAndBothFamiliesFormSetM() {
        let prev = base([("gemini-3-flash", 0.3), ("gemini-2.5-pro", 0.3), ("claude-sonnet-4-6", 0.6)], gen: 1)
        let cur = AgyFixtures.report([("gemini-3-flash", 0, r1), ("gemini-2.5-pro", 0, r1),
                                      ("claude-sonnet-4-6", 0, r2)])
        let (m, _) = AntigravityExhaustion.evaluate(previous: prev, current: cur, generation: 1)
        XCTAssertEqual(m, ["gemini-3-flash", "gemini-2.5-pro", "claude-sonnet-4-6"])
        let rec = AntigravityExhaustion.record(for: m, report: cur, now: now)!
        XCTAssertEqual(rec.resetsAt, RFC3339.date(from: r2), "M 이 모두 풀려야 하므로 가장 늦은 리셋")
        XCTAssertTrue(rec.modelScoped)
        XCTAssertEqual(rec.scopeModelIDs, ["claude-sonnet-4-6", "gemini-2.5-pro", "gemini-3-flash"])
        XCTAssertEqual(rec.scopeLabel, "Claude·Gemini")
    }

    func testUnknownFractionAndMissingRowAreNotTriggers() {
        let prev = base([("gemini-3-flash", 0.3), ("claude-sonnet-4-6", 0.3)], gen: 1)
        let cur = AgyFixtures.report([("gemini-3-flash", nil, r1)])   // 값 모름, claude 행 빠짐
        let (m, next) = AntigravityExhaustion.evaluate(previous: prev, current: cur, generation: 1)
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(next["gemini-3-flash"]?.fraction, 0.3, "값 모름은 기준값을 바꾸지 않는다")
        // 그 뒤 명시적인 0 이 오면 같은 세대의 마지막 확인값(0.3)과 비교한다
        let (m2, _) = AntigravityExhaustion.evaluate(previous: next,
                                                     current: AgyFixtures.report([("gemini-3-flash", 0, r1)]),
                                                     generation: 1)
        XCTAssertEqual(m2, ["gemini-3-flash"])
    }

    // MARK: 후보 확인 (4.7 「후보 확인」)

    func testCandidateNeedsExplicitHeadroomForAllOfM() {
        let m: Set<String> = ["gemini-3-flash", "claude-sonnet-4-6"]
        XCTAssertEqual(AntigravityExhaustion.verifyCandidate(
            AgyFixtures.report([("gemini-3-flash", 0.5, r1), ("claude-sonnet-4-6", 1, r2)]), models: m), .headroom)
        XCTAssertEqual(AntigravityExhaustion.verifyCandidate(
            AgyFixtures.report([("gemini-3-flash", 0.5, r1), ("claude-sonnet-4-6", 0, r2)]), models: m),
                       .exhausted(["claude-sonnet-4-6": RFC3339.date(from: r2)!]))
        // 같은 계열의 다른 모델 값으로 대신하지 않는다 — 행 빠짐은 확인 불가
        XCTAssertEqual(AntigravityExhaustion.verifyCandidate(
            AgyFixtures.report([("gemini-3-flash", 0.5, r1), ("claude-opus-4-6-thinking", 1, r2)]), models: m),
                       .unverifiable)
        XCTAssertEqual(AntigravityExhaustion.verifyCandidate(
            AgyFixtures.report([("gemini-3-flash", 0.5, r1), ("claude-sonnet-4-6", nil, r2)]), models: m),
                       .unverifiable)
        XCTAssertEqual(AntigravityExhaustion.verifyCandidate(nil, models: m), .unverifiable)
    }

    func testCandidateMemoryFloorsAndCooldowns() {
        let mem = AntigravityAutoSwitchMemory()
        let a = UUID(), b = UUID(), c = UUID()
        let m: Set<String> = ["gemini-3-flash"]
        let soon = now.addingTimeInterval(60)   // resetTime 이 1분 뒤여도 해제는 10분 하한
        mem.apply(.exhausted(["gemini-3-flash": soon]), to: a, now: now)
        mem.apply(.unverifiable, to: b, now: now)
        mem.noteProbe(c, now: now)
        let file = AccountsFile()
        XCTAssertEqual(mem.excludedCandidates(file: file, models: m, now: now.addingTimeInterval(5 * 60)), [a, b, c])
        XCTAssertFalse(mem.canProbe(c, now: now.addingTimeInterval(9 * 60)))
        XCTAssertEqual(mem.excludedCandidates(file: file, models: m, now: now.addingTimeInterval(11 * 60)), [])
        XCTAssertEqual(mem.excludedCandidates(file: file, models: ["claude-sonnet-4-6"],
                                              now: now.addingTimeInterval(5 * 60)), [b, c],
                       "모델 제외는 같은 모델 ID 일 때만")
    }

    func testRecordsOverlapByModelID() {
        var p = AccountProfile(id: UUID(), provider: .antigravity, nickname: "p", emailAddress: "p@g",
                               organizationName: "", tierDescription: "")
        p.rateLimit = RateLimitInfo(resetsAt: now.addingTimeInterval(3600), recordedAt: now, modelScoped: true,
                                    scopeModelIDs: ["gemini-3-flash"], scopeLabel: "Gemini")
        let file = AccountsFile(accounts: [p])
        XCTAssertEqual(AntigravityExhaustion.accountsWithOverlappingRecords(
            in: file, provider: .antigravity, models: ["gemini-3-flash", "x"], now: now), [p.id])
        XCTAssertEqual(AntigravityExhaustion.accountsWithOverlappingRecords(
            in: file, provider: .antigravity, models: ["claude-sonnet-4-6"], now: now), [])
    }

    func testAllExhaustedNotifiesOnlyWhenEveryCandidateIsExplicitZero() {
        let mem = AntigravityAutoSwitchMemory()
        let active = AccountProfile(id: UUID(), provider: .antigravity, nickname: "a", emailAddress: "a@g",
                                    organizationName: "", tierDescription: "")
        let b = AccountProfile(id: UUID(), provider: .antigravity, nickname: "b", emailAddress: "b@g",
                               organizationName: "", tierDescription: "")
        let c = AccountProfile(id: UUID(), provider: .antigravity, nickname: "c", emailAddress: "c@g",
                               organizationName: "", tierDescription: "")
        let file = AccountsFile(accounts: [active, b, c])
        let m: Set<String> = ["gemini-3-flash"]
        mem.apply(.exhausted(["gemini-3-flash": now.addingTimeInterval(3600)]), to: b.id, now: now)
        mem.apply(.unverifiable, to: c.id, now: now)
        XCTAssertNil(mem.allOthersExplicitlyExhausted(file: file, active: active.id, models: m, now: now),
                     "확인할 수 없어서 빠진 후보가 있으면 알리지 않는다")
        mem.apply(.exhausted(["gemini-3-flash": now.addingTimeInterval(1800)]), to: c.id, now: now)
        let earliest = mem.allOthersExplicitlyExhausted(file: file, active: active.id, models: m, now: now)
        XCTAssertEqual(earliest, now.addingTimeInterval(1800))
        XCTAssertTrue(mem.shouldNotifyAllExhausted(models: m, earliestReset: earliest!))
        XCTAssertFalse(mem.shouldNotifyAllExhausted(models: m, earliestReset: earliest!), "같은 조합에 한 번")
    }

    /// 리뷰 1회차 Codex P2-6: 알림 시각 = "M 을 모두 쓸 수 있는 첫 계정"의 시각. 계정마다 필요한 모델
    /// 리셋의 최댓값을 구하고, 출발 계정을 포함해 그 최솟값을 고른다. 10분 재조회 하한은 섞지 않는다.
    func testAllExhaustedReportsWhenEveryModelIsUsableAgain() {
        let mem = AntigravityAutoSwitchMemory()
        var a = AccountProfile(id: UUID(), provider: .antigravity, nickname: "a", emailAddress: "a@g",
                               organizationName: "", tierDescription: "")
        a.rateLimit = RateLimitInfo(resetsAt: now.addingTimeInterval(30 * 60), recordedAt: now, modelScoped: true,
                                    scopeModelIDs: ["m1", "m2"])
        let b = AccountProfile(id: UUID(), provider: .antigravity, nickname: "b", emailAddress: "b@g",
                               organizationName: "", tierDescription: "")
        let file = AccountsFile(accounts: [a, b])
        let m: Set<String> = ["m1", "m2"]
        mem.apply(.exhausted(["m1": now.addingTimeInterval(15 * 60), "m2": now.addingTimeInterval(60 * 60)]),
                  to: b.id, now: now)
        XCTAssertEqual(mem.allOthersExplicitlyExhausted(file: file, active: a.id, models: m, now: now),
                       now.addingTimeInterval(30 * 60), "B 는 60분 뒤, 출발 계정 A 는 30분 뒤")
        // 리셋이 10분 하한보다 이르면 실제 리셋 시각을 알린다
        let mem2 = AntigravityAutoSwitchMemory()
        mem2.apply(.exhausted(["m1": now.addingTimeInterval(2 * 60), "m2": now.addingTimeInterval(3 * 60)]),
                   to: b.id, now: now)
        XCTAssertEqual(mem2.allOthersExplicitlyExhausted(file: file, active: a.id, models: m, now: now),
                       now.addingTimeInterval(3 * 60))
    }

    /// 리뷰 2회차 Codex P2-3: 리셋이 이미 지난 제외(재조회 하한으로만 남은 것)는 소진 근거로 쓰지 않는다.
    func testAllExhaustedIgnoresExclusionsWhoseResetHasPassed() {
        let mem = AntigravityAutoSwitchMemory()
        let a = AccountProfile(id: UUID(), provider: .antigravity, nickname: "a", emailAddress: "a@g",
                               organizationName: "", tierDescription: "")
        let b = AccountProfile(id: UUID(), provider: .antigravity, nickname: "b", emailAddress: "b@g",
                               organizationName: "", tierDescription: "")
        let c = AccountProfile(id: UUID(), provider: .antigravity, nickname: "c", emailAddress: "c@g",
                               organizationName: "", tierDescription: "")
        let file = AccountsFile(accounts: [a, b, c])
        let m: Set<String> = ["m1"]
        mem.apply(.exhausted(["m1": now.addingTimeInterval(2 * 60)]), to: b.id, now: now)
        let later = now.addingTimeInterval(3 * 60)
        mem.apply(.exhausted(["m1": later.addingTimeInterval(60 * 60)]), to: c.id, now: later)
        XCTAssertNil(mem.allOthersExplicitlyExhausted(file: file, active: a.id, models: m, now: later),
                     "B 의 리셋은 이미 지났다 — 지금 유효한 근거가 없으므로 알리지 않는다")
    }

    func testRoundTripPausesUntilRecordReset() {
        let mem = AntigravityAutoSwitchMemory()
        var a = AccountProfile(id: UUID(), provider: .antigravity, nickname: "a", emailAddress: "a@g",
                               organizationName: "", tierDescription: "")
        a.rateLimit = RateLimitInfo(resetsAt: now.addingTimeInterval(2 * 3600), recordedAt: now, modelScoped: true,
                                    scopeModelIDs: ["gemini-3-flash"])
        let file = AccountsFile(accounts: [a])
        mem.noteAutoSwitchedAway(from: a.id, at: now)
        XCTAssertNil(mem.detectRoundTrip(newActive: UUID(), file: file, now: now.addingTimeInterval(60)))
        let until = mem.detectRoundTrip(newActive: a.id, file: file, now: now.addingTimeInterval(120))
        XCTAssertEqual(until, now.addingTimeInterval(2 * 3600))
        XCTAssertTrue(mem.isPaused(now: now.addingTimeInterval(3600)))
        XCTAssertFalse(mem.isPaused(now: now.addingTimeInterval(3 * 3600)))
        XCTAssertNil(mem.detectRoundTrip(newActive: a.id, file: file, now: now.addingTimeInterval(200)), "알림은 한 번")
    }

    func testRebaseCarriesCandidateObservationIntoNewGeneration() {
        let mem = AntigravityAutoSwitchMemory()
        let b = UUID()
        mem.observeInactive(b, report: AgyFixtures.report([("gemini-3-flash", 0.4, r1)]), generation: 1)
        mem.rebase(b, toGeneration: 2)
        let m = mem.observeActive(b, report: AgyFixtures.report([("gemini-3-flash", 0, r1)]), generation: 2)
        XCTAssertEqual(m, ["gemini-3-flash"], "자동 전환으로 활성이 된 계정은 후보 확인의 관측을 기준값으로 넘겨받는다")
    }

    // MARK: 엔진 정책 (4.7 「엔진 규칙」)

    private func pool(pinActive: Bool = false) -> (AccountsFile, AccountProfile, AccountProfile, AccountProfile) {
        func p(_ n: String) -> AccountProfile {
            AccountProfile(id: UUID(), provider: .antigravity, nickname: n, emailAddress: "\(n)@g",
                           organizationName: "", tierDescription: "")
        }
        var a = p("a"), b = p("b"), c = p("c")
        a.userPinned = pinActive
        var file = AccountsFile(accounts: [a, b, c])
        file.activeByProvider[.antigravity] = b.id     // fallback 이 활성
        file.autoSwitchByProvider[.antigravity] = true
        return (file, a, b, c)
    }

    private func limited(_ file: inout AccountsFile, _ id: UUID, recordedAt: Date) {
        let i = file.accounts.firstIndex { $0.id == id }!
        file.accounts[i].rateLimit = RateLimitInfo(resetsAt: recordedAt.addingTimeInterval(3600),
                                                   recordedAt: recordedAt, modelScoped: true,
                                                   scopeModelIDs: ["gemini-3-flash"], scopeLabel: "Gemini")
    }

    func testLeavesOnlyForRecordWrittenSinceActivation() {
        var (file, a, b, _) = pool()
        let engine = AutoSwitchEngine(provider: .antigravity)
        limited(&file, b.id, recordedAt: now.addingTimeInterval(-600))
        XCTAssertEqual(engine.onTick(file: file, now: now, activeSince: now.addingTimeInterval(-60)), .none,
                       "활성이 되기 전의 기록(재시작 전 포함)으로는 떠나지 않는다")
        XCTAssertEqual(engine.onTick(file: file, now: now, activeSince: now.addingTimeInterval(-3600)),
                       .switchTo(a.id, reason: .modelExhausted))
        XCTAssertEqual(engine.onTick(file: file, now: now, activeSince: nil), .none)
    }

    func testIgnoresPinAndNeverReturnsToPrimary() {
        var (file, a, b, c) = pool()
        file.activeByProvider[.antigravity] = a.id
        let i = file.accounts.firstIndex { $0.id == a.id }!
        file.accounts[i].userPinned = true
        limited(&file, a.id, recordedAt: now)
        let engine = AutoSwitchEngine(provider: .antigravity)
        let hit = RateLimitHit(resetsAt: now.addingTimeInterval(3600), modelScoped: true)
        XCTAssertEqual(engine.onRateLimitHit(file: file, hit: hit, now: now),
                       .switchTo(b.id, reason: .modelExhausted), "핀이 있어도 쓰던 버킷이 소진되면 옮긴다(0절)")
        // fallback(c) 활성 + primary(a) 여유 + 자동 전환 플래그 → 그래도 복귀하지 않는다
        var f2 = file
        f2.accounts[i].rateLimit = nil
        f2.activeByProvider[.antigravity] = c.id
        f2.autoSwitchedByProvider[.antigravity] = true
        XCTAssertEqual(engine.onTick(file: f2, now: now.addingTimeInterval(10_000), activeSince: now), .none)
    }

    func testExcludedIDsAndNoAllExhaustedForModelScoped() {
        var (file, a, b, c) = pool()
        limited(&file, b.id, recordedAt: now)
        let engine = AutoSwitchEngine(provider: .antigravity)
        let hit = RateLimitHit(resetsAt: now.addingTimeInterval(3600), modelScoped: true)
        XCTAssertEqual(engine.onRateLimitHit(file: file, hit: hit, now: now, excludedIDs: [a.id]),
                       .switchTo(c.id, reason: .modelExhausted))
        XCTAssertEqual(engine.onRateLimitHit(file: file, hit: hit, now: now, excludedIDs: [a.id, c.id]), .none,
                       "Antigravity 에는 '모든 계정 한도 소진'이 없다")
    }

    func testAutoSwitchOffOnlyNotifiesModelLimit() {
        var (file, _, b, _) = pool()
        file.autoSwitchByProvider[.antigravity] = nil   // 기본값 = 꺼짐
        limited(&file, b.id, recordedAt: now)
        let engine = AutoSwitchEngine(provider: .antigravity)
        let hit = RateLimitHit(resetsAt: now.addingTimeInterval(3600), modelScoped: true)
        XCTAssertEqual(engine.onRateLimitHit(file: file, hit: hit, now: now), .notifyModelLimitedOnly(b.id))
        XCTAssertEqual(engine.onTick(file: file, now: now, activeSince: .distantPast), .none)
    }

    func testStandardPolicyIsUnchangedForClaude() {
        XCTAssertEqual(AutoSwitchEngine(provider: .claude).policy, .standard)
        XCTAssertEqual(AutoSwitchEngine(provider: .codex).policy, .standard)
        XCTAssertEqual(AutoSwitchEngine(provider: .antigravity).policy, .antigravity)
    }

    // MARK: 비동기 재확인 (4.7 「비동기 경합」)

    private struct Fixture {
        let store: AccountStore
        let memory = AntigravityAutoSwitchMemory()
        let a: AccountProfile, b: AccountProfile
        let models: Set<String> = ["gemini-3-flash"]
    }

    private func fixture() throws -> Fixture {
        let env = AgyFixtures.tempEnv()
        let store = try AccountStore(env: env, keychain: InMemoryKeychain())
        let id = { (e: String) in ProviderIdentity(emailAddress: e, organizationName: "", tierDescription: "") }
        let a = try store.upsertProfile(nickname: "a", provider: .antigravity, identity: id("a@g"),
                                        secretData: AgyFixtures.secret("a@g"))
        let b = try store.upsertProfile(nickname: "b", provider: .antigravity, identity: id("b@g"),
                                        secretData: AgyFixtures.secret("b@g"))
        try store.setAutoSwitch(true, provider: .antigravity)
        try store.update(a.id) {
            $0.rateLimit = RateLimitInfo(resetsAt: Date().addingTimeInterval(3600), recordedAt: Date(),
                                         modelScoped: true, scopeModelIDs: ["gemini-3-flash"])
        }
        return Fixture(store: store, a: a, b: b)
    }

    private func capture(_ f: Fixture, fp: Data? = Data([1])) -> AntigravityExpectation {
        AntigravityExpectation(generation: f.store.activeGeneration(of: .antigravity), liveFingerprint: fp,
                               diskRevision: f.store.peekDisk()!.activeRevision(.antigravity), departure: f.a.id)
    }

    private func holds(_ e: AntigravityExpectation, _ f: Fixture, fp: Data? = Data([1])) -> Bool {
        e.holds(models: f.models, store: f.store, liveFingerprint: fp, memory: f.memory, forSwitch: true, now: Date())
    }

    func testExpectationHoldsWhenNothingChanged() throws {
        let f = try fixture()
        XCTAssertTrue(holds(capture(f), f))
    }

    func testExpectationCancelsOnGenerationChange() throws {
        let f = try fixture()
        let e = capture(f)
        f.store.noteLiveFingerprint(Data([7]), provider: .antigravity)
        f.store.noteLiveFingerprint(Data([8]), provider: .antigravity)   // 세대 +1
        XCTAssertFalse(holds(e, f))
    }

    func testExpectationCancelsOnLiveFingerprintChange() throws {
        let f = try fixture()
        XCTAssertFalse(holds(capture(f), f, fp: Data([2])))
    }

    func testExpectationCancelsOnDiskRevisionChange() throws {
        let f = try fixture()
        let e = capture(f)
        let cli = try AccountStore(env: f.store.env, keychain: InMemoryKeychain())   // 다른 프로세스
        try cli.setActive(f.b.id)
        try cli.setActive(f.a.id)   // 활성 값은 같지만 리비전이 달라졌다
        XCTAssertFalse(holds(e, f))
    }

    func testExpectationCancelsWhenAutoSwitchTurnedOffOnDisk() throws {
        let f = try fixture()
        let e = capture(f)
        let cli = try AccountStore(env: f.store.env, keychain: InMemoryKeychain())
        try cli.setAutoSwitch(false, provider: .antigravity)
        XCTAssertFalse(holds(e, f))
    }

    func testExpectationCancelsWhenDepartureRecordNoLongerValid() throws {
        let f = try fixture()
        let e = capture(f)
        try f.store.update(f.a.id) { $0.rateLimit = nil }
        XCTAssertFalse(holds(e, f))
    }

    func testExpectationCancelsWhenNewerObservationShowsHeadroom() throws {
        let f = try fixture()
        let e = capture(f)
        f.memory.observeInactive(f.a.id, report: AgyFixtures.report([("gemini-3-flash", 0.3, r1)]), generation: 0)
        XCTAssertFalse(holds(e, f), "그사이 출발 계정의 M 이 0 보다 크게 보였으면 취소")
    }
}
