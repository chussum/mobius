import XCTest
@testable import MobiusCore

/// 이슈 #19 — 세션 로그 rate-limit hit의 계정 귀속.
final class HitAttributionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func snapshot(fiveHour: Double? = nil, sevenDay: Double? = nil,
                          scoped: [ScopedUsageLimit] = [],
                          resetsIn: TimeInterval = 3600,
                          fetchedAgo: TimeInterval = 0) -> UsageSnapshot {
        UsageSnapshot(fiveHourPercent: fiveHour,
                      fiveHourResetsAt: fiveHour == nil ? nil : now.addingTimeInterval(resetsIn),
                      sevenDayPercent: sevenDay,
                      sevenDayResetsAt: sevenDay == nil ? nil : now.addingTimeInterval(resetsIn * 2),
                      scopedLimits: scoped.isEmpty ? nil : scoped,
                      fetchedAt: now.addingTimeInterval(-fetchedAgo))
    }

    // MARK: 사고 재현 — 오귀인된 hit은 기록되지 않는다

    /// 제보된 사고(2026-08-15)의 핵심 상태를 그대로 재현한다.
    /// primary가 주간 100%로 소진 → 전환. 전환 뒤에도 **전환 전에 시작된 턴**이 primary의
    /// 같은 에러를 로그에 남기고, 그 hit이 새 활성(폴백)에 귀속되려 한다.
    /// 폴백의 실제 사용량은 7일 16% / 5시간 9% — 검증은 이 hit을 **버려야** 한다.
    /// 검증이 없던 시절엔 이 자리에서 폴백에 resets 21:00이 박혀 자동 전환이 통째로 죽었다.
    func testMisattributedHitIsDiscardedWhenTargetAccountHasHeadroom() {
        let fallback = snapshot(fiveHour: 9, sevenDay: 16)
        XCTAssertEqual(HitAttribution.verdict(usage: fallback, now: now), .discard)
    }

    /// 반대쪽: 진짜 소진된 계정의 hit은 기록된다 — 그리고 **API의 실제 리셋 시각**을 쓴다
    /// (로그 문구 파싱값 21:00 대신 API의 20:59:59 — 부수적으로 정확해지는 부분).
    func testGenuineExhaustionIsRecordedWithApiResetTime() {
        let primary = snapshot(fiveHour: 12, sevenDay: 100)
        guard case let .record(hit) = HitAttribution.verdict(usage: primary, now: now) else {
            return XCTFail("소진 계정의 hit은 기록돼야 한다")
        }
        XCTAssertEqual(hit.resetsAt, primary.sevenDayResetsAt)
        XCTAssertFalse(hit.modelScoped)
    }

    /// 5시간 창만 찼어도 소진이다.
    func testFiveHourExhaustionIsRecorded() {
        guard case .record = HitAttribution.verdict(usage: snapshot(fiveHour: 100, sevenDay: 30),
                                                    now: now)
        else { return XCTFail("5시간 창 소진도 기록돼야 한다") }
    }

    /// ★ 100%인데 리셋 시각이 이미 지났으면 **`.discard`가 아니라 `.inconclusive`**다.
    /// 잘못된 24h 폴백을 박지도 않지만, "여유"로 오해해 트리거를 태워 없애지도 않는다 —
    /// 둘을 같은 값으로 돌려주면 호출측이 트리거를 소비해 그 소진이 영영 기록되지 않는다.
    func testExhaustedWindowWithPastResetIsInconclusiveNotDiscard() {
        let stale = UsageSnapshot(fiveHourPercent: 100,
                                  fiveHourResetsAt: now.addingTimeInterval(-60),
                                  sevenDayPercent: 10, sevenDayResetsAt: now.addingTimeInterval(3600),
                                  fetchedAt: now)
        XCTAssertEqual(HitAttribution.verdict(usage: stale, now: now), .inconclusive)
    }

    /// 리셋 시각 자체가 없는 경우도 마찬가지 — 보류다.
    func testExhaustedWindowWithMissingResetIsInconclusive() {
        let noReset = UsageSnapshot(fiveHourPercent: 100, fiveHourResetsAt: nil,
                                    sevenDayPercent: 10,
                                    sevenDayResetsAt: now.addingTimeInterval(3600), fetchedAt: now)
        XCTAssertEqual(HitAttribution.verdict(usage: noReset, now: now), .inconclusive)
    }

    /// ★ 전환 직후에는 모델 전용 한도를 귀속 증거로 쓰지 않는다 — 그 100%는 며칠 가는
    /// **상태**라 "누가 이 에러를 냈는지"를 말해 주지 않는데, 오귀인은 정확히 전환 직후에만
    /// 생긴다. 이 갈래가 없으면 뒤늦게 도착한 남의 hit이 멀쩡한 계정에 "모델 한도"를 찍고
    /// 사용자가 시키지도 않은 전환·알림이 나간다(이 PR이 고치는 증상의 재현).
    func testScopedModelLimitIsNotTrustedRightAfterASwitch() {
        let usage = snapshot(fiveHour: 9, sevenDay: 16,
                             scoped: [ScopedUsageLimit(label: "Fable", percent: 100,
                                                       resetsAt: now.addingTimeInterval(4 * 86400))])
        // ★ `.discard`가 아니라 `.notYetTrusted`다 — 필요한 건 새 데이터가 아니라 **시간**이라,
        //   호출측이 같은 스냅샷으로 창이 지난 뒤 공짜로 다시 판정한다(조회 0회). discard로
        //   두면 그 discard가 백오프 카운터를 채워 신뢰 창이 열린 뒤에도 기록이 더 늦어진다.
        XCTAssertEqual(HitAttribution.verdict(usage: usage, now: now, trustModelScope: false),
                       .notYetTrusted)
        // 계정 창 소진은 시점 정보가 있는 증거라 전환 직후에도 그대로 인정한다.
        let exhausted = snapshot(fiveHour: 100, sevenDay: 16)
        guard case .record = HitAttribution.verdict(usage: exhausted, now: now,
                                                    trustModelScope: false)
        else { return XCTFail("계정 창 소진은 전환 직후에도 기록돼야 한다") }
    }

    /// ★ **모델 한도 100% + 쓸 수 있는 리셋 시각 없음**은 `.discard`가 아니라 `.inconclusive`다.
    ///
    /// 한때 이 자리는 `.discard`를 단언했다 — "오래된 scoped 100%가 멀쩡한 계정을 영영
    /// 보류로 묶는다"는 우려였다. 그 우려는 **보류에 상한이 없던 시절**의 것이고, 지금은
    /// 보류가 15분(TTL) 뒤 최후 폴백으로 기록되며 그 뒤로는 `.skipAlreadyRecorded`로
    /// 끊긴다 = **유한하고 수렴한다.** 반대로 `.discard`로 두면 실측으로 확인된 응답 형태
    /// (`weekly_scoped`의 `resets_at: null` — 이슈 #19, @Phantomn 2026-08-16)에서
    /// **그 모델로 막힌 사용자의 hit이 조용히 버려지고 백오프까지 걸린다.**
    /// 두 위험을 저울질하면 "유한한 보류" 쪽이 낫다.
    func testUnresolvableScopedLimitIsInconclusiveNotDiscard() {
        let usage = snapshot(fiveHour: 9, sevenDay: 16,
                             scoped: [ScopedUsageLimit(label: "Fable", percent: 100, resetsAt: nil)])
        XCTAssertEqual(HitAttribution.verdict(usage: usage, now: now), .inconclusive)

        // 이미 지난 리셋 시각도 같다 — 쓸 수 없는 값이라는 점에서 동일하다.
        let past = snapshot(fiveHour: 9, sevenDay: 16,
                            scoped: [ScopedUsageLimit(label: "Fable", percent: 100,
                                                      resetsAt: now.addingTimeInterval(-60))])
        XCTAssertEqual(HitAttribution.verdict(usage: past, now: now), .inconclusive)

        // ★ 100%가 아니면(그냥 오래된 항목) 여전히 즉시 버린다 — 보류 대상이 아니다.
        let idle = snapshot(fiveHour: 9, sevenDay: 16,
                            scoped: [ScopedUsageLimit(label: "Fable", percent: 0, resetsAt: nil)])
        XCTAssertEqual(HitAttribution.verdict(usage: idle, now: now), .discard)

        // ★ 전환 직후(신뢰 창 안)에는 보류로 승격시키지 않는다 — 그 구간에서 이 신호는
        //   귀속 증거가 못 되므로, 붙잡아 두면 남의 hit을 15분간 물고 있게 된다.
        XCTAssertEqual(HitAttribution.verdict(usage: usage, now: now, trustModelScope: false),
                       .discard)
    }

    /// 계정 창은 여유인데 **모델 전용 한도**(Fable 등)가 찼으면 그것도 진짜 소진이다 —
    /// 다만 `modelScoped: true`로 기록해 "계정 사용 불가"가 아니라 "그 모델만 불가"로 남긴다.
    /// 이 갈래가 없으면 모델 한도로 막힌 사용자는 hit이 매번 버려져 자동 전환을 못 받는다.
    func testScopedModelLimitIsRecordedAsModelScoped() {
        let resets = now.addingTimeInterval(4 * 86400)
        let usage = snapshot(fiveHour: 20, sevenDay: 30,
                             scoped: [ScopedUsageLimit(label: "Fable", percent: 100,
                                                       resetsAt: resets)])
        guard case let .record(hit) = HitAttribution.verdict(usage: usage, now: now) else {
            return XCTFail("모델 전용 한도 소진도 기록돼야 한다")
        }
        XCTAssertEqual(hit.resetsAt, resets)
        XCTAssertTrue(hit.modelScoped)
    }

    /// 계정 창 소진이 모델 전용 한도보다 우선한다 — 계정 전체가 막힌 것이므로
    /// modelScoped=false(= 핀과 무관하게 밀어낼 수 있고, 폴백 후보에서도 빠진다)로 기록된다.
    func testAccountWindowWinsOverScopedLimit() {
        let usage = snapshot(fiveHour: 100, sevenDay: 30,
                             scoped: [ScopedUsageLimit(label: "Fable", percent: 100,
                                                       resetsAt: now.addingTimeInterval(4 * 86400))])
        guard case let .record(hit) = HitAttribution.verdict(usage: usage, now: now) else {
            return XCTFail("계정 창 소진이 우선 기록돼야 한다")
        }
        XCTAssertFalse(hit.modelScoped)
    }

    /// 모델 한도 기록이 이미 있으면 재확인을 **끄지 않고 늦춘다** — 그 계정은 계속 쓸 수
    /// 있어 hit이 끊임없이 오므로 60초 주기면 사실상 배경 폴링이 되고, 그렇다고 완전히
    /// 스킵하면 그 사이 **계정 창 자체가** 소진되는 신호를 놓친다.
    func testModelLimitedAccountUsesLongerRecheckInterval() {
        XCTAssertGreaterThan(HitAttribution.modelLimitedRecheck, HitAttribution.cooldown)
        let recheck = HitAttribution.modelLimitedRecheck
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false, hasModelLimitRecord: true,
                                           cachedUsageAt: nil, hitObservedAt: now,
                                           lastFetchAttemptAt: now.addingTimeInterval(-recheck + 1),
                                           now: now),
                       .skipCooldown)
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false, hasModelLimitRecord: true,
                                           cachedUsageAt: nil, hitObservedAt: now,
                                           lastFetchAttemptAt: now.addingTimeInterval(-recheck - 1),
                                           now: now),
                       .fetchUsage)
        // 같은 상황에서 일반 쿨다운(60초)만 지났으면 아직 조회하지 않는다 — 이 상수가
        // 실제로 쓰이는지 못 박는다(그냥 60초로 돌아가도 위 두 단언은 통과한다).
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false, hasModelLimitRecord: true,
                                           cachedUsageAt: nil, hitObservedAt: now,
                                           lastFetchAttemptAt: now.addingTimeInterval(
                                               -HitAttribution.cooldown - 1),
                                           now: now),
                       .skipCooldown)
    }

    // MARK: 게이트 — 네트워크를 언제 쓰는가

    /// 이미 소진 기록이 있으면 아무것도 하지 않는다 — 소진 중엔 매 요청이 같은 에러를
    /// 남기므로, 이 가드가 없으면 hit마다 알림·엔진 호출이 반복된다(알림 폭풍).
    func testAlreadyRecordedSkipsEverything() {
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: true, cachedUsageAt: nil,
                                           hitObservedAt: now, lastFetchAttemptAt: nil, now: now),
                       .skipAlreadyRecorded)
        // 캐시도 쿨다운도 이 판정을 뒤집지 못한다.
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: true,
                                           cachedUsageAt: now.addingTimeInterval(-1000),
                                           hitObservedAt: now, lastFetchAttemptAt: now, now: now),
                       .skipAlreadyRecorded)
    }

    /// 첫 hit은 조회한다(캐시 없음).
    func testFirstHitFetches() {
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false, cachedUsageAt: nil,
                                           hitObservedAt: now, lastFetchAttemptAt: nil, now: now),
                       .fetchUsage)
    }

    /// 한 배치의 두 번째 hit부터는 방금 조회한 캐시를 그대로 쓴다 — 네트워크 0.
    func testCacheTakenAfterTheHitIsUsed() {
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false,
                                           cachedUsageAt: now.addingTimeInterval(0.4),
                                           hitObservedAt: now,
                                           lastFetchAttemptAt: now, now: now),
                       .verifyWithCache)
    }

    /// ★ **트리거보다 오래된 캐시로는 절대 판정하지 않는다.**
    /// 40초 전 96%였던 스냅샷으로 방금 100%가 된 창을 "여유"로 오판하면 진짜 소진을 버리는데,
    /// 그 버림은 흔적도 안 남아 "소진이 아니었다"와 구분되지 않는다.
    func testCacheOlderThanTheHitIsNotTrusted() {
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false,
                                           cachedUsageAt: now.addingTimeInterval(-40),
                                           hitObservedAt: now,
                                           lastFetchAttemptAt: nil, now: now),
                       .fetchUsage)
    }

    /// 조회가 실패한 직후엔 쿨다운 — 다만 이건 **포기가 아니라 보류**다(호출측이 트리거를
    /// 남겨 다음 틱에 다시 본다). 소진 중에도 사용자가 타이핑을 멈추면 새 hit이 안 오므로,
    /// 여기서 버리면 그 소진은 영영 기록되지 않는다.
    func testCooldownAfterFailedFetchThenRetry() {
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false, cachedUsageAt: nil,
                                           hitObservedAt: now.addingTimeInterval(-10),
                                           lastFetchAttemptAt: now.addingTimeInterval(-10),
                                           now: now),
                       .skipCooldown)
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false, cachedUsageAt: nil,
                                           hitObservedAt: now.addingTimeInterval(-61),
                                           lastFetchAttemptAt: now.addingTimeInterval(-61),
                                           now: now),
                       .fetchUsage)
    }

    /// 실패했던 조회의 낡은 캐시가 쿨다운을 건너뛰게 하지 않는다(캐시가 트리거보다 오래됨).
    func testStaleCacheDoesNotBypassCooldown() {
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false,
                                           cachedUsageAt: now.addingTimeInterval(-300),
                                           hitObservedAt: now.addingTimeInterval(-10),
                                           lastFetchAttemptAt: now.addingTimeInterval(-10),
                                           now: now),
                       .skipCooldown)
    }

    /// ★ 로그 hit은 "CLI가 실제로 막혔다"는 사실이고 usage 백분율은 근사값이라, 소진 순간
    /// API가 99%로 보일 수 있다. 그때 버리면 — 막힌 사용자는 타이핑을 멈춰 새 hit도 안 오므로 —
    /// 그 소진은 영영 기록되지 않는다. 한도에 바짝 붙었으면 버리지 않고 보류한다.
    func testNearLimitIsHeldPendingInsteadOfDiscarded() {
        XCTAssertEqual(HitAttribution.verdict(usage: snapshot(fiveHour: 99, sevenDay: 30), now: now),
                       .inconclusive)
        // 오귀인 쪽(폴백 7일 16%)은 이 선에 한참 못 미쳐 즉시 버려진다 — 비용이 늘지 않는다.
        XCTAssertEqual(HitAttribution.verdict(usage: snapshot(fiveHour: 9, sevenDay: 16), now: now),
                       .discard)
    }

    /// 모델 한도를 같은 값으로 재확인한 뒤에는 재확인 주기를 더 늦춘다 — 모델 한도는 며칠
    /// 가는 상태라, 안 늦추면 그 기간 내내 3분마다 조회가 돌아 "폴링 0" 계약이 무너진다.
    func testReconfirmedModelLimitUsesSteadyInterval() {
        XCTAssertGreaterThan(HitAttribution.modelLimitedSteadyRecheck,
                             HitAttribution.modelLimitedRecheck)
        // 첫 재확인 주기는 지났지만 정상 상태 주기는 아직 — 조회하지 않는다.
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false, hasModelLimitRecord: true,
                                           modelLimitReconfirmed: true, cachedUsageAt: nil,
                                           hitObservedAt: now,
                                           lastFetchAttemptAt: now.addingTimeInterval(
                                               -HitAttribution.modelLimitedRecheck - 1),
                                           now: now),
                       .skipCooldown)
        XCTAssertEqual(HitAttribution.plan(accountIsLimited: false, hasModelLimitRecord: true,
                                           modelLimitReconfirmed: true, cachedUsageAt: nil,
                                           hitObservedAt: now,
                                           lastFetchAttemptAt: now.addingTimeInterval(
                                               -HitAttribution.modelLimitedSteadyRecheck - 1),
                                           now: now),
                       .fetchUsage)
    }

    /// ★ 계정 창이 100%면 **모델 한도보다 먼저** 결론 낸다 — 리셋 시각을 못 얻어
    /// exhaustionHit이 nil이었을 뿐, 계정은 실제로 막혀 있다. 순서가 뒤집히면 완전히
    /// 소진된 계정이 "그 모델만 막힘"으로 기록돼 폴백 후보로 남고, 메뉴바도 빨강이 안 되며
    /// 핀이 걸려 있으면 자동 전환까지 멈춘다.
    func testExhaustedAccountWindowBeatsScopedEvenWithoutUsableReset() {
        let usage = UsageSnapshot(
            fiveHourPercent: 100, fiveHourResetsAt: nil,
            sevenDayPercent: 30, sevenDayResetsAt: now.addingTimeInterval(3600),
            scopedLimits: [ScopedUsageLimit(label: "Fable", percent: 100,
                                            resetsAt: now.addingTimeInterval(4 * 86400))],
            fetchedAt: now)
        XCTAssertEqual(HitAttribution.verdict(usage: usage, now: now), .inconclusive)
    }

    /// 한도 근접 보류는 **5시간 창에만** 적용한다. 주간 사용률은 주말 즈음 정상적으로 95%를
    /// 넘는데, 거기 걸면 남의 hit이 영영 `.discard`에 못 닿아 15분 내내 조회가 도는 상태로 굳는다.
    func testWeeklyNearLimitDoesNotBlockDiscard() {
        XCTAssertEqual(HitAttribution.verdict(usage: snapshot(fiveHour: 12, sevenDay: 97), now: now),
                       .discard)
        XCTAssertEqual(HitAttribution.verdict(usage: snapshot(fiveHour: 97, sevenDay: 12), now: now),
                       .inconclusive)
    }

    // MARK: 최후 폴백이 무엇으로 기록할지 (셀프리뷰 H1)

    /// ★ 로그 라인에는 **모델 이름이 없다** — 그래서 로그 hit은 항상 `modelScoped == false`다.
    /// 15분 뒤 최후 폴백이 그걸 그대로 기록하면 "그 모델만 막힘"이 **계정 전체 소진**이 되어
    /// 메뉴바가 빨개지고 CLI 라벨이 틀리며, `autoSwitchMayLeave`가 `isLimited`에서 핀을 보기
    /// **전에 단락**하므로 사용자가 고정해 둔 계정에서 강제로 밀려난다. 보류의 "종류"를
    /// 기억해야 하는 이유이고, 그 판별이 이 함수다.
    func testInconclusiveKindDecidesFallbackAttribution() {
        // 계정 창 여유 + 모델 한도만 100%(리셋 시각 없음) → 모델 갈래
        let modelOnly = snapshot(fiveHour: 9, sevenDay: 16,
                                 scoped: [ScopedUsageLimit(label: "Fable", percent: 100,
                                                           resetsAt: nil)])
        XCTAssertEqual(HitAttribution.verdict(usage: modelOnly, now: now), .inconclusive)
        XCTAssertTrue(HitAttribution.inconclusiveIsModelScoped(usage: modelOnly))

        // 계정 창이 100%인데 리셋 시각을 못 얻은 경우 → 계정 갈래(모델 아님)
        let accountStuck = UsageSnapshot(fiveHourPercent: 100, fiveHourResetsAt: nil,
                                         sevenDayPercent: 10,
                                         sevenDayResetsAt: now.addingTimeInterval(3600),
                                         fetchedAt: now)
        XCTAssertEqual(HitAttribution.verdict(usage: accountStuck, now: now), .inconclusive)
        XCTAssertFalse(HitAttribution.inconclusiveIsModelScoped(usage: accountStuck))

        // 한도 근접(5시간 99%)으로 보류된 경우도 계정 갈래다 — 곧 계정이 막힌다는 뜻이다.
        let nearLimit = snapshot(fiveHour: 99, sevenDay: 30)
        XCTAssertEqual(HitAttribution.verdict(usage: nearLimit, now: now), .inconclusive)
        XCTAssertFalse(HitAttribution.inconclusiveIsModelScoped(usage: nearLimit))
    }

    // MARK: 사용량 조회가 요청 제한(429) 중인 보류 트리거 (실패 기록 25)

    private let ttl: TimeInterval = 20 * 60

    /// 다시 조회할 시각이 수명 끝 이후면 기다려도 조회하지 못한다 → 최후 폴백을 바로 쓴다.
    func testRateLimitBeyondTTLGivesUpEarly() {
        XCTAssertTrue(HitAttribution.givesUpEarlyWhileRateLimited(
            retryAt: now.addingTimeInterval(3600), firstSeenAt: now, ttl: ttl, hitTrusted: true))
        XCTAssertTrue(HitAttribution.givesUpEarlyWhileRateLimited(
            retryAt: now.addingTimeInterval(ttl), firstSeenAt: now, ttl: ttl, hitTrusted: true),
            "수명 끝과 같은 시각도 조회할 틈이 없다")
    }

    /// 수명 안에 풀리면 재시도 루프가 잇는다 — 앞당기지 않는다.
    func testRateLimitWithinTTLKeepsWaiting() {
        XCTAssertFalse(HitAttribution.givesUpEarlyWhileRateLimited(
            retryAt: now.addingTimeInterval(126), firstSeenAt: now, ttl: ttl, hitTrusted: true))
        // 수명의 절반이 지난 트리거는 남은 수명으로 따진다.
        XCTAssertTrue(HitAttribution.givesUpEarlyWhileRateLimited(
            retryAt: now.addingTimeInterval(ttl / 2 + 1), firstSeenAt: now.addingTimeInterval(-ttl / 2),
            ttl: ttl, hitTrusted: true))
    }

    /// 최후 폴백이 기록하지 않을 hit(전환 직후 도착)으로는 앞당기지 않는다 — 앞당겨 얻을 것이 없고,
    /// 트리거를 붙들어 둬야 그 뒤에 온 hit이 트리거를 바꿔 기록될 수 있다.
    func testUntrustedHitDoesNotGiveUpEarly() {
        XCTAssertFalse(HitAttribution.givesUpEarlyWhileRateLimited(
            retryAt: now.addingTimeInterval(3600), firstSeenAt: now, ttl: ttl, hitTrusted: false))
    }

    /// 도착 판정의 경계 — 전환보다 신뢰 창 **넘게** 뒤에 도착한 hit만 믿는다.
    func testLogFallbackAllowedBoundary() {
        let window = HitAttribution.modelScopeTrustWindow
        XCTAssertFalse(HitAttribution.logFallbackAllowed(
            hitArrivedAt: now.addingTimeInterval(17), lastActiveChangeAt: now))
        XCTAssertFalse(HitAttribution.logFallbackAllowed(
            hitArrivedAt: now.addingTimeInterval(window), lastActiveChangeAt: now))
        XCTAssertTrue(HitAttribution.logFallbackAllowed(
            hitArrivedAt: now.addingTimeInterval(window + 1), lastActiveChangeAt: now))
    }
}
