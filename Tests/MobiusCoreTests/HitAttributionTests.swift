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
        let apiResetsAt = now.addingTimeInterval(3600)
        let primary = snapshot(fiveHour: 12, sevenDay: 100)
        guard case let .record(hit) = HitAttribution.verdict(usage: primary, now: now) else {
            return XCTFail("소진 계정의 hit은 기록돼야 한다")
        }
        XCTAssertEqual(hit.resetsAt, apiResetsAt.addingTimeInterval(3600))  // 7일 창 = resetsIn*2
        XCTAssertFalse(hit.modelScoped)
    }

    /// 5시간 창만 찼어도 소진이다.
    func testFiveHourExhaustionIsRecorded() {
        guard case .record = HitAttribution.verdict(usage: snapshot(fiveHour: 100, sevenDay: 30),
                                                    now: now)
        else { return XCTFail("5시간 창 소진도 기록돼야 한다") }
    }

    /// 이미 지난 리셋 시각은 소진으로 치지 않는다 — 24h 폴백을 잘못 박느니 다음 hit을 기다린다.
    func testExhaustedWindowWithPastResetIsDiscarded() {
        let stale = UsageSnapshot(fiveHourPercent: 100,
                                  fiveHourResetsAt: now.addingTimeInterval(-60),
                                  sevenDayPercent: 10, sevenDayResetsAt: now.addingTimeInterval(3600),
                                  fetchedAt: now)
        XCTAssertEqual(HitAttribution.verdict(usage: stale, now: now), .discard)
    }

    // MARK: 모델 전용 한도 (Fable 등)

    /// ★ 계정 창은 여유인데 **모델 전용 주간 한도**가 찬 경우 — 검증이 계정 창만 보면
    /// 진짜 소진을 "여유"로 버려 영영 전환되지 않는다(고치려는 증상의 반대 방향 재발).
    func testScopedModelLimitCountsAsExhaustion() {
        let resets = now.addingTimeInterval(7200)
        let usage = snapshot(fiveHour: 20, sevenDay: 30,
                             scoped: [ScopedUsageLimit(label: "Fable", percent: 100, resetsAt: resets)])
        guard case let .record(hit) = HitAttribution.verdict(usage: usage, now: now) else {
            return XCTFail("모델 전용 한도 소진도 기록돼야 한다")
        }
        XCTAssertEqual(hit.resetsAt, resets)
        // modelScoped=true여야 엔진이 "사용자가 이 계정을 직접 골랐으면 머문다"를 존중한다.
        XCTAssertTrue(hit.modelScoped)
    }

    /// 모델 전용 한도가 여유면 아무 일도 없다.
    func testScopedModelLimitWithHeadroomIsDiscarded() {
        let usage = snapshot(fiveHour: 20, sevenDay: 30,
                             scoped: [ScopedUsageLimit(label: "Fable", percent: 40,
                                                       resetsAt: now.addingTimeInterval(7200))])
        XCTAssertEqual(HitAttribution.verdict(usage: usage, now: now), .discard)
    }

    /// 계정 창 소진이 모델 전용 한도보다 우선한다 — 계정 전체가 막힌 것이므로
    /// modelScoped=false(=pin과 무관하게 밀어낼 수 있음)로 기록돼야 한다.
    func testAccountWindowWinsOverScopedLimit() {
        let usage = snapshot(fiveHour: 100, sevenDay: 30,
                             scoped: [ScopedUsageLimit(label: "Fable", percent: 100,
                                                       resetsAt: now.addingTimeInterval(7200))])
        guard case let .record(hit) = HitAttribution.verdict(usage: usage, now: now) else {
            return XCTFail("계정 창 소진이 우선 기록돼야 한다")
        }
        XCTAssertFalse(hit.modelScoped)
    }

    // MARK: 게이트 — 네트워크를 언제 쓰는가

    /// 이미 소진 기록이 있으면 아무것도 하지 않는다 — 소진 중엔 매 요청이 같은 에러를
    /// 남기므로, 이 가드가 없으면 hit마다 알림·엔진 호출이 반복된다(알림 폭풍).
    func testAlreadyRecordedSkipsEverything() {
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: true, cachedUsageAt: nil,
                                           lastFetchAttemptAt: nil, now: now),
                       .skipAlreadyRecorded)
        // 캐시도 쿨다운도 이 판정을 뒤집지 못한다.
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: true,
                                           cachedUsageAt: now.addingTimeInterval(-1000),
                                           lastFetchAttemptAt: now, now: now),
                       .skipAlreadyRecorded)
    }

    /// 첫 hit은 조회한다(캐시 없음).
    func testFirstHitFetches() {
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false, cachedUsageAt: nil,
                                           lastFetchAttemptAt: nil, now: now),
                       .fetchUsage)
    }

    /// 신선한 캐시가 있으면 네트워크 0 — 한 배치의 두 번째 hit부터가 이 경로다.
    func testFreshCacheAvoidsNetwork() {
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false,
                                           cachedUsageAt: now.addingTimeInterval(-5),
                                           lastFetchAttemptAt: now.addingTimeInterval(-5), now: now),
                       .verifyWithCache)
    }

    /// ★ 검증용 캐시 수명은 표시용(4분)보다 짧다 — 4분 전 스냅샷으로 판정하면 그 사이 찬
    /// 한도를 "여유"로 오판해 전환이 그만큼 늦어진다. 2분 된 캐시는 다시 조회해야 한다.
    func testDisplayFreshCacheIsStillTooOldForVerification() {
        XCTAssertLessThan(HitAttribution.verifyCacheStaleness, 240)
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false,
                                           cachedUsageAt: now.addingTimeInterval(-120),
                                           lastFetchAttemptAt: nil, now: now),
                       .fetchUsage)
    }

    /// 조회가 실패한 직후엔 쿨다운 — 소진 중엔 hit이 계속 오므로 매 hit마다 두드리지 않는다.
    func testCooldownAfterFailedFetch() {
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false,
                                           cachedUsageAt: nil,
                                           lastFetchAttemptAt: now.addingTimeInterval(-10), now: now),
                       .skipCooldown)
        // 쿨다운이 지나면 다시 시도한다 — "확인 불가"는 영구 포기가 아니다.
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false,
                                           cachedUsageAt: nil,
                                           lastFetchAttemptAt: now.addingTimeInterval(-61), now: now),
                       .fetchUsage)
    }
}
