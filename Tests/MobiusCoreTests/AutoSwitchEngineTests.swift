import XCTest
@testable import MobiusCore

final class AutoSwitchEngineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var primary: AccountProfile!; var fb1: AccountProfile!; var fb2: AccountProfile!
    var file: AccountsFile!

    override func setUp() {
        primary = AccountProfile(id: UUID(), nickname: "primary", emailAddress: "a@x",
                                 organizationName: "", tierDescription: "")
        fb1 = AccountProfile(id: UUID(), nickname: "fb1", emailAddress: "b@x",
                             organizationName: "", tierDescription: "")
        fb2 = AccountProfile(id: UUID(), nickname: "fb2", emailAddress: "c@x",
                             organizationName: "", tierDescription: "")
        file = AccountsFile(accounts: [primary, fb1, fb2], activeAccountID: primary.id)
    }

    func testHitOnActiveSwitchesToFirstAvailableFallback() {
        let engine = AutoSwitchEngine()
        let d = engine.onRateLimitHit(file: file,
                                      hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)),
                                      now: t0)
        XCTAssertEqual(d, .switchTo(fb1.id, reason: .activeExhausted))
    }

    func testSkipsLimitedAndReauthFallbacks() {
        file.accounts[1].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(999), recordedAt: t0)
        var d = AutoSwitchEngine().onRateLimitHit(
            file: file, hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)), now: t0)
        XCTAssertEqual(d, .switchTo(fb2.id, reason: .activeExhausted))

        file.accounts[2].needsReauth = true
        d = AutoSwitchEngine().onRateLimitHit(
            file: file, hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)), now: t0)
        XCTAssertEqual(d, .allExhausted) // 갈 곳 없음
    }

    func testTickSelfHealsWhenActiveLimitedButNotSwitched() {
        // 로그 hit 순간의 전환을 놓쳐(쿨다운·throw 등) primary가 소진된 채 활성으로 남은 상태.
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(3600), recordedAt: t0)
        // 쿨다운 밖의 다음 틱 → 여유 있는 fb1로 자가 전환
        let d = AutoSwitchEngine().onTick(file: file, now: t0)
        XCTAssertEqual(d, .switchTo(fb1.id, reason: .activeExhausted))
    }

    func testTickSelfHealsWhenActiveNeedsReauth() {
        // 로그인 만료로 primary가 needsReauth 마킹된 채 활성 → 여유 있는 fb1로 전환
        file.accounts[0].needsReauth = true
        XCTAssertEqual(AutoSwitchEngine().onTick(file: file, now: t0),
                       .switchTo(fb1.id, reason: .activeExhausted))
    }

    func testModelScopedLimitDoesNotSwitchPinnedAccount() {
        // 사용자가 직접 고른(pin) primary가 Fable(모델 전용) 한도 소진 → 밀어내지 않는다.
        file.accounts[0].userPinned = true
        file.accounts[0].rateLimit = RateLimitInfo(
            resetsAt: t0.addingTimeInterval(3600), recordedAt: t0, modelScoped: true)
        XCTAssertEqual(AutoSwitchEngine().onTick(file: file, now: t0), .none)
        // hit 경로도 동일 — 모델 전용 + pin이면 전환 안 함
        XCTAssertEqual(
            AutoSwitchEngine().onRateLimitHit(file: file, hit: RateLimitHit(resetsAt: nil, modelScoped: true), now: t0),
            .none)
    }

    func testModelScopedLimitSwitchesUnpinnedAccount() {
        // pin 안 된 계정이 Fable 소진 → 1회 자동 전환은 정상 동작
        file.accounts[0].userPinned = false
        XCTAssertEqual(
            AutoSwitchEngine().onRateLimitHit(file: file, hit: RateLimitHit(resetsAt: nil, modelScoped: true), now: t0),
            .switchTo(fb1.id, reason: .activeExhausted))
    }

    func testAccountWideLimitSwitchesEvenPinned() {
        // pin됐어도 계정 자체 한도(modelScoped=false)면 밀어낸다 — 진짜 사용 불가.
        file.accounts[0].userPinned = true
        file.accounts[0].rateLimit = RateLimitInfo(
            resetsAt: t0.addingTimeInterval(3600), recordedAt: t0, modelScoped: false)
        XCTAssertEqual(AutoSwitchEngine().onTick(file: file, now: t0),
                       .switchTo(fb1.id, reason: .activeExhausted))
    }

    func testTickSelfHealRespectsCooldown() {
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(3600), recordedAt: t0)
        let engine = AutoSwitchEngine()
        engine.noteSwitched(now: t0)                      // 방금 전환됨
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(30)), .none) // 쿨다운
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(121)),
                       .switchTo(fb1.id, reason: .activeExhausted)) // 쿨다운 후
    }

    func testTickSelfHealNoTargetStaysPut() {
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(3600), recordedAt: t0)
        file.accounts[1].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(3600), recordedAt: t0)
        file.accounts[2].needsReauth = true
        XCTAssertEqual(AutoSwitchEngine().onTick(file: file, now: t0), .none) // 갈 곳 없음 → 유지
    }

    func testAutoSwitchDisabledNotifiesExhaustedOnly() {
        // 스펙: 자동 전환을 끄면 전환 없이 "소진 알림만"
        file.autoSwitchByProvider[.claude] = false
        let d = AutoSwitchEngine().onRateLimitHit(
            file: file, hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)), now: t0)
        XCTAssertEqual(d, .notifyExhaustedOnly(primary.id))
    }

    func testAutoSwitchToggleGatesOnlyItsOwnPool() {
        // claude 풀만 끔 — codex 풀 엔진은 여전히 전환한다
        let x1 = AccountProfile(id: UUID(), provider: .codex, nickname: "x1", emailAddress: "x1@x",
                                organizationName: "", tierDescription: "")
        let x2 = AccountProfile(id: UUID(), provider: .codex, nickname: "x2", emailAddress: "x2@x",
                                organizationName: "", tierDescription: "")
        file.accounts += [x1, x2]
        file.activeByProvider[.codex] = x1.id
        file.autoSwitchByProvider[.claude] = false

        let hit = RateLimitHit(resetsAt: t0.addingTimeInterval(3600))
        XCTAssertEqual(AutoSwitchEngine(provider: .claude).onRateLimitHit(file: file, hit: hit, now: t0),
                       .notifyExhaustedOnly(primary.id))
        XCTAssertEqual(AutoSwitchEngine(provider: .codex).onRateLimitHit(file: file, hit: hit, now: t0),
                       .switchTo(x2.id, reason: .activeExhausted))

        // onTick 복귀도 꺼진 풀만 억제된다
        file.activeByProvider = [.claude: fb1.id, .codex: x2.id]
        file.autoSwitchedByProvider = [.claude: true, .codex: true]
        XCTAssertEqual(AutoSwitchEngine(provider: .claude).onTick(file: file, now: t0), .none)
        XCTAssertEqual(AutoSwitchEngine(provider: .codex).onTick(file: file, now: t0),
                       .switchTo(x1.id, reason: .primaryRecovered))
    }

    func testTickReturnsToPrimaryAfterResetPlusMargin() {
        // 자동 전환으로 fb1 활성, primary는 t0+100에 리셋
        file.activeAccountID = fb1.id
        file.autoSwitchedFromPrimary = true
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(100), recordedAt: t0)
        let engine = AutoSwitchEngine()
        // 리셋 전: 복귀 안 함
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(50)), .none)
        // 리셋 직후(margin 60초 전): 아직
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(110)), .none)
        // 리셋 + margin 후: 복귀
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(161)),
                       .switchTo(primary.id, reason: .primaryRecovered))
    }

    func testCooldownPreventsFlapping() {
        let engine = AutoSwitchEngine()
        _ = engine.onRateLimitHit(file: file,
                                  hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)), now: t0)
        engine.noteSwitched(now: t0) // 호출자가 실제 전환 후 알려줌
        // 쿨다운(120초) 내 primary 회복 틱 → 억제
        file.activeAccountID = fb1.id
        file.autoSwitchedFromPrimary = true
        file.accounts[0].rateLimit = nil
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(60)), .none)
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(121)),
                       .switchTo(primary.id, reason: .primaryRecovered))
    }

    func testCooldownSuppressesStaleRateLimitHits() {
        // 전환 직후 구 세션이 남기는 stale rate-limit 로그를 새 활성 계정의
        // 소진으로 오인해 연쇄 전환(B→C→D)되면 안 된다
        let engine = AutoSwitchEngine()
        let hit = RateLimitHit(resetsAt: t0.addingTimeInterval(3600))
        XCTAssertEqual(engine.onRateLimitHit(file: file, hit: hit, now: t0),
                       .switchTo(fb1.id, reason: .activeExhausted))
        engine.noteSwitched(now: t0)
        // 호출자가 전환을 반영: primary 한도 기록, fb1 활성
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(3600), recordedAt: t0)
        file.activeAccountID = fb1.id
        // 쿨다운(120초) 내 hit → 억제
        XCTAssertEqual(engine.onRateLimitHit(file: file, hit: hit, now: t0.addingTimeInterval(60)),
                       .none)
        // 경계 정각(t0 + cooldown): now < last + cooldown 이 거짓 → 허용
        XCTAssertEqual(engine.onRateLimitHit(file: file, hit: hit, now: t0.addingTimeInterval(120)),
                       .switchTo(fb2.id, reason: .activeExhausted))
        // 쿨다운 경과 후 같은 hit → 전환
        XCTAssertEqual(engine.onRateLimitHit(file: file, hit: hit, now: t0.addingTimeInterval(121)),
                       .switchTo(fb2.id, reason: .activeExhausted))
    }

    func testTickDoesNotRevertManualFallbackSwitch() {
        // 사용자가 수동으로 fb1에 전환한 상태 (플래그 false) — primary가 멀쩡해도
        // onTick이 강제로 primary로 되돌리면 안 된다
        file.activeAccountID = fb1.id
        file.autoSwitchedFromPrimary = false
        XCTAssertEqual(AutoSwitchEngine().onTick(file: file, now: t0.addingTimeInterval(300)), .none)

        // 같은 상황에서 플래그가 true(자동 전환의 결과)면 기존 복귀 동작 유지
        file.autoSwitchedFromPrimary = true
        XCTAssertEqual(AutoSwitchEngine().onTick(file: file, now: t0.addingTimeInterval(300)),
                       .switchTo(primary.id, reason: .primaryRecovered))
    }

    func testNilResetsAtUses24HourFallback() {
        // 월간 지출 한도 등 리셋 시각 없는 이벤트 → 보수적 24시간 폴백
        let hit = RateLimitHit(resetsAt: nil)
        XCTAssertEqual(hit.effectiveResetsAt(now: t0), t0.addingTimeInterval(24 * 3600))
        // 시각형 이벤트는 자기 시각 그대로
        XCTAssertEqual(RateLimitHit(resetsAt: t0.addingTimeInterval(3600)).effectiveResetsAt(now: t0),
                       t0.addingTimeInterval(3600))

        let engine = AutoSwitchEngine()
        // nil resetsAt도 fallback 전환은 그대로 일어난다
        XCTAssertEqual(engine.onRateLimitHit(file: file, hit: hit, now: t0),
                       .switchTo(fb1.id, reason: .activeExhausted))
        engine.noteSwitched(now: t0)

        // 호출자의 실제 반영을 시뮬레이션: primary에 24h 폴백 기록, fb1 활성 (자동 전환)
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: hit.effectiveResetsAt(now: t0),
                                                   recordedAt: t0)
        file.activeAccountID = fb1.id
        file.autoSwitchedFromPrimary = true
        // 24h + margin 전: 복귀 안 함
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(24 * 3600 + 30)), .none)
        // 24h + margin 후: 복귀 후보
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(24 * 3600 + 61)),
                       .switchTo(primary.id, reason: .primaryRecovered))
    }

    // MARK: 임계값 선제 전환 (advisory)

    /// primary에 경고를 세운 file (기본: 지금 감지, 1시간 뒤 리셋)
    private func withAdvisory(detectedAt: Date? = nil, resetsAt: Date? = nil) -> AccountsFile {
        var f = file!
        f.accounts[0].advisory = AdvisoryRecord(utilization: 92,
                                                resetsAt: resetsAt ?? t0.addingTimeInterval(3600),
                                                detectedAt: detectedAt ?? t0)
        return f
    }

    func testAdvisorySwitchesToVerifiedCandidate() {
        let f = withAdvisory()
        XCTAssertEqual(AutoSwitchEngine().checkAdvisory(file: f, activeID: primary.id,
                                                        verifiedCandidate: fb1.id,
                                                        alreadyAdvised: false, now: t0),
                       .switchTo(fb1.id, reason: .thresholdAdvisory))
    }

    func testAdvisoryAlreadyAdvisedStillSwitchesWhenEnabled() {
        // ★ alreadyAdvised는 **알림만** 게이트한다 — 전환은 절대 억제하지 않는다.
        //   임계값 폴은 매 폴마다 이번 resetsAt을 last-advised에 써서, 한 5시간 창 안에서는
        //   두 번째 폴부터 이 플래그가 영구히 true다. 이 플래그를 전환 위로 끌어올리면
        //   (예: guard 2로 `guard !alreadyAdvised else { return .none }`) 첫 폴 이후 임계값
        //   자동 전환이 통째로 죽는데 기존 테스트는 전부 green으로 남는다 — 이 테스트가 그 구멍을 잠근다.
        let f = withAdvisory()  // 기본 fixture = 자동 전환 켬
        XCTAssertEqual(AutoSwitchEngine().checkAdvisory(file: f, activeID: primary.id,
                                                        verifiedCandidate: fb1.id,
                                                        alreadyAdvised: true, now: t0),
                       .switchTo(fb1.id, reason: .thresholdAdvisory))
    }

    func testAdvisoryNoCandidateStaysQuietRepeatably() {
        // 후보를 못 찾으면 알림도 전환도 없이 조용히 머문다 — 몇 번을 물어도 같은 답(부작용 없음)
        let f = withAdvisory()
        let engine = AutoSwitchEngine()
        for i in 0..<3 {
            XCTAssertEqual(engine.checkAdvisory(file: f, activeID: primary.id,
                                                verifiedCandidate: nil,
                                                alreadyAdvised: false,
                                                now: t0.addingTimeInterval(Double(i) * 300)),
                           .none)
        }
    }

    func testAdvisoryNoDecisionWithoutAdvisoryOrWrongActive() {
        // 경고 없음 → 결정 없음
        XCTAssertEqual(AutoSwitchEngine().checkAdvisory(file: file, activeID: primary.id,
                                                        verifiedCandidate: fb1.id,
                                                        alreadyAdvised: false, now: t0), .none)
        // 활성이 아닌 id로 물으면 결정 없음
        let f = withAdvisory()
        XCTAssertEqual(AutoSwitchEngine().checkAdvisory(file: f, activeID: fb1.id,
                                                        verifiedCandidate: fb2.id,
                                                        alreadyAdvised: false, now: t0), .none)
    }

    func testAdvisoryToggleOffNotifiesOnceThenStaysSilent() {
        var f = withAdvisory()
        f.autoSwitchByProvider[.claude] = false
        let engine = AutoSwitchEngine()
        // 아직 안 알림 → 알림만
        XCTAssertEqual(engine.checkAdvisory(file: f, activeID: primary.id,
                                            verifiedCandidate: fb1.id,
                                            alreadyAdvised: false, now: t0),
                       .notifyAdvisoryOnly(primary.id))
        // 같은 창에서 이미 알림 → 결정 없음 (매 폴링마다 알림 폭풍 금지)
        XCTAssertEqual(engine.checkAdvisory(file: f, activeID: primary.id,
                                            verifiedCandidate: fb1.id,
                                            alreadyAdvised: true, now: t0),
                       .none)
    }

    func testAdvisoryNotifyOnlySurvivesCooldown() {
        // ★ 가드 순서 회귀 테스트: 알림만 하는 결정은 전환을 실행하지 않으므로 쿨다운과 무관하다.
        //   쿨다운 가드를 먼저 두면 무관한 전환의 쿨다운 창이 이 알림을 영구히 삼킨다.
        var f = withAdvisory()
        f.autoSwitchByProvider[.claude] = false
        let engine = AutoSwitchEngine()
        engine.noteSwitched(now: t0)  // 방금 전환 → 쿨다운 한복판
        XCTAssertEqual(engine.checkAdvisory(file: f, activeID: primary.id,
                                            verifiedCandidate: nil,
                                            alreadyAdvised: false,
                                            now: t0.addingTimeInterval(30)),
                       .notifyAdvisoryOnly(primary.id))
    }

    func testAdvisoryPinBeforeOrWithoutTimestampDoesNotVeto() {
        // 경고보다 **앞선** 핀 → "경고를 보고 돌아온 것"이 아니므로 거부권 없음
        var f = withAdvisory(detectedAt: t0)
        f.accounts[0].userPinned = true
        f.accounts[0].pinnedAt = t0.addingTimeInterval(-600)
        XCTAssertEqual(AutoSwitchEngine().checkAdvisory(file: f, activeID: primary.id,
                                                        verifiedCandidate: fb1.id,
                                                        alreadyAdvised: false, now: t0),
                       .switchTo(fb1.id, reason: .thresholdAdvisory))
        // 시각 없는 구버전 핀도 거부권 없음
        f.accounts[0].pinnedAt = nil
        XCTAssertEqual(AutoSwitchEngine().checkAdvisory(file: f, activeID: primary.id,
                                                        verifiedCandidate: fb1.id,
                                                        alreadyAdvised: false, now: t0),
                       .switchTo(fb1.id, reason: .thresholdAdvisory))
    }

    func testAdvisoryPinAfterDetectionVetoesSwitch() {
        // 경고를 본 **뒤** 수동으로 돌아온 핀 → 후보가 있어도 밀어내지 않는다
        var f = withAdvisory(detectedAt: t0)
        f.accounts[0].userPinned = true
        f.accounts[0].pinnedAt = t0.addingTimeInterval(60)
        XCTAssertEqual(AutoSwitchEngine().checkAdvisory(file: f, activeID: primary.id,
                                                        verifiedCandidate: fb1.id,
                                                        alreadyAdvised: false,
                                                        now: t0.addingTimeInterval(120)),
                       .none)
    }

    func testAdvisoryAndExhaustionShareCooldown() {
        // 소진 전환 직후 → 임계값 전환은 쿨다운에 막힌다
        let engine = AutoSwitchEngine()
        XCTAssertEqual(engine.onRateLimitHit(file: file,
                                             hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)),
                                             now: t0),
                       .switchTo(fb1.id, reason: .activeExhausted))
        engine.noteSwitched(now: t0)
        let f = withAdvisory()
        XCTAssertEqual(engine.checkAdvisory(file: f, activeID: primary.id,
                                            verifiedCandidate: fb2.id,
                                            alreadyAdvised: false,
                                            now: t0.addingTimeInterval(60)),
                       .none)
        // 쿨다운 후엔 전환
        XCTAssertEqual(engine.checkAdvisory(file: f, activeID: primary.id,
                                            verifiedCandidate: fb2.id,
                                            alreadyAdvised: false,
                                            now: t0.addingTimeInterval(121)),
                       .switchTo(fb2.id, reason: .thresholdAdvisory))

        // 반대 방향: 임계값 전환 직후 → 소진 hit도 쿨다운에 막힌다
        let engine2 = AutoSwitchEngine()
        XCTAssertEqual(engine2.checkAdvisory(file: f, activeID: primary.id,
                                             verifiedCandidate: fb1.id,
                                             alreadyAdvised: false, now: t0),
                       .switchTo(fb1.id, reason: .thresholdAdvisory))
        engine2.noteSwitched(now: t0)
        XCTAssertEqual(engine2.onRateLimitHit(file: file,
                                              hit: RateLimitHit(resetsAt: t0.addingTimeInterval(3600)),
                                              now: t0.addingTimeInterval(60)),
                       .none)
    }

    // MARK: 후보 탐색 백오프 / 조회 방식

    func testCandidateProbeBackoffPredicate() {
        let engine = AutoSwitchEngine()
        XCTAssertTrue(engine.shouldProbeCandidates(lastNoCandidateAt: nil, now: t0))
        XCTAssertFalse(engine.shouldProbeCandidates(lastNoCandidateAt: t0,
                                                    now: t0.addingTimeInterval(14 * 60)))
        XCTAssertTrue(engine.shouldProbeCandidates(lastNoCandidateAt: t0,
                                                   now: t0.addingTimeInterval(15 * 60)))
        XCTAssertTrue(engine.shouldProbeCandidates(lastNoCandidateAt: t0,
                                                   now: t0.addingTimeInterval(16 * 60)))
    }

    func testCandidateProbeActionMatrix() {
        let cooldown: TimeInterval = 6 * 3600
        // 만료 정보 없음 / 아직 유효 → 저장 토큰 그대로 (네트워크 refresh 0회)
        XCTAssertEqual(AutoSwitchEngine.candidateProbeAction(expiresAt: nil, now: t0,
                                                             lastRefreshAttemptAt: nil,
                                                             cooldown: cooldown),
                       .useStoredToken)
        XCTAssertEqual(AutoSwitchEngine.candidateProbeAction(expiresAt: t0.addingTimeInterval(3600),
                                                             now: t0,
                                                             lastRefreshAttemptAt: t0,
                                                             cooldown: cooldown),
                       .useStoredToken)
        // 만료 + 첫 시도 → 승격
        XCTAssertEqual(AutoSwitchEngine.candidateProbeAction(expiresAt: t0.addingTimeInterval(-60),
                                                             now: t0,
                                                             lastRefreshAttemptAt: nil,
                                                             cooldown: cooldown),
                       .escalate)
        // 만료 + 쿨다운 경과 → 승격
        XCTAssertEqual(AutoSwitchEngine.candidateProbeAction(
            expiresAt: t0.addingTimeInterval(-60), now: t0,
            lastRefreshAttemptAt: t0.addingTimeInterval(-cooldown), cooldown: cooldown),
                       .escalate)
        // 만료 + 쿨다운 안 → 판정 없이 스킵
        XCTAssertEqual(AutoSwitchEngine.candidateProbeAction(
            expiresAt: t0.addingTimeInterval(-60), now: t0,
            lastRefreshAttemptAt: t0.addingTimeInterval(-60), cooldown: cooldown),
                       .skipCooldown)
    }

    // MARK: primary 복귀 게이트 (advisory 포함)

    func testRecoveryGateBlocksOnAdvisoryOnlyDeparture() {
        // advisory만 보고 떠난 경우 primary에는 rateLimit이 없다 — 예전 가드는 이때 통째로
        // 스킵돼 쿨다운(120초)만 지나면 복귀 → 2분 주기 핑퐁이 났다.
        file.activeAccountID = fb1.id
        file.autoSwitchedFromPrimary = true
        file.accounts[0].advisory = AdvisoryRecord(utilization: 95,
                                                   resetsAt: t0.addingTimeInterval(1800),
                                                   detectedAt: t0)
        let engine = AutoSwitchEngine()
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(300)), .none)
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(1830)), .none) // margin 전
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(1861)),
                       .switchTo(primary.id, reason: .primaryRecovered))
    }

    func testRecoveryGateWaitsForBothGates() {
        // 둘 다 있으면 **늦은 쪽**을 지나야 복귀한다
        file.activeAccountID = fb1.id
        file.autoSwitchedFromPrimary = true
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(600), recordedAt: t0)
        file.accounts[0].advisory = AdvisoryRecord(utilization: 95,
                                                   resetsAt: t0.addingTimeInterval(1800),
                                                   detectedAt: t0)
        let engine = AutoSwitchEngine()
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(700)), .none) // rateLimit만 지남
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(1861)),
                       .switchTo(primary.id, reason: .primaryRecovered))
    }

    func testRecoveryGateUnchangedWhenAdvisoryAbsent() {
        // 토글 끄기 등으로 advisory가 지워진 뒤엔 기존 rateLimit 전용 게이트와 완전히 동일
        file.activeAccountID = fb1.id
        file.autoSwitchedFromPrimary = true
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(100), recordedAt: t0)
        file.accounts[0].advisory = nil
        let engine = AutoSwitchEngine()
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(110)), .none)
        XCTAssertEqual(engine.onTick(file: file, now: t0.addingTimeInterval(161)),
                       .switchTo(primary.id, reason: .primaryRecovered))
    }
}
