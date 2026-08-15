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

    /// 이미 지난 리셋 시각은 소진으로 치지 않는다 — 24h 폴백을 잘못 박느니 다음 기회를 본다.
    func testExhaustedWindowWithPastResetIsDiscarded() {
        let stale = UsageSnapshot(fiveHourPercent: 100,
                                  fiveHourResetsAt: now.addingTimeInterval(-60),
                                  sevenDayPercent: 10, sevenDayResetsAt: now.addingTimeInterval(3600),
                                  fetchedAt: now)
        XCTAssertEqual(HitAttribution.verdict(usage: stale, now: now), .discard)
    }

    /// ★ **모델 전용 한도(Fable 등)는 계정 소진으로 치지 않는다.**
    /// 한때 "모델 한도로 막힌 진짜 소진을 놓치지 않으려고" 포함했는데, 그러면 이 이슈가 더
    /// 나쁘게 재현된다: 모델 한도 100%는 며칠 유지되는 **상태**라 익명 로그 라인의 귀속
    /// 증거가 못 되는데, `AccountProfile.isLimited`는 modelScoped를 구분하지 않으므로
    /// 멀쩡한 폴백이 **며칠** 후보에서 빠진다. 모델 스코프 기반 전환은 isLimited가 그 구분을
    /// 이해하게 만든 뒤의 후속 과제다.
    func testScopedModelLimitAloneIsNotAccountExhaustion() {
        let usage = snapshot(fiveHour: 20, sevenDay: 30,
                             scoped: [ScopedUsageLimit(label: "Fable", percent: 100,
                                                       resetsAt: now.addingTimeInterval(4 * 86400))])
        XCTAssertEqual(HitAttribution.verdict(usage: usage, now: now), .discard)
    }

    // MARK: 게이트 — 네트워크를 언제 쓰는가

    /// 이미 소진 기록이 있으면 아무것도 하지 않는다 — 소진 중엔 매 요청이 같은 에러를
    /// 남기므로, 이 가드가 없으면 hit마다 알림·엔진 호출이 반복된다(알림 폭풍).
    func testAlreadyRecordedSkipsEverything() {
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: true, cachedUsageAt: nil,
                                           hitObservedAt: now, lastFetchAttemptAt: nil, now: now),
                       .skipAlreadyRecorded)
        // 캐시도 쿨다운도 이 판정을 뒤집지 못한다.
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: true,
                                           cachedUsageAt: now.addingTimeInterval(-1000),
                                           hitObservedAt: now, lastFetchAttemptAt: now, now: now),
                       .skipAlreadyRecorded)
    }

    /// 첫 hit은 조회한다(캐시 없음).
    func testFirstHitFetches() {
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false, cachedUsageAt: nil,
                                           hitObservedAt: now, lastFetchAttemptAt: nil, now: now),
                       .fetchUsage)
    }

    /// 한 배치의 두 번째 hit부터는 방금 조회한 캐시를 그대로 쓴다 — 네트워크 0.
    func testCacheTakenAfterTheHitIsUsed() {
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false,
                                           cachedUsageAt: now.addingTimeInterval(0.4),
                                           hitObservedAt: now,
                                           lastFetchAttemptAt: now, now: now),
                       .verifyWithCache)
    }

    /// ★ **트리거보다 오래된 캐시로는 절대 판정하지 않는다.**
    /// 40초 전 96%였던 스냅샷으로 방금 100%가 된 창을 "여유"로 오판하면 진짜 소진을 버리는데,
    /// 그 버림은 흔적도 안 남아 "소진이 아니었다"와 구분되지 않는다.
    func testCacheOlderThanTheHitIsNotTrusted() {
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false,
                                           cachedUsageAt: now.addingTimeInterval(-40),
                                           hitObservedAt: now,
                                           lastFetchAttemptAt: nil, now: now),
                       .fetchUsage)
    }

    /// 조회가 실패한 직후엔 쿨다운 — 다만 이건 **포기가 아니라 보류**다(호출측이 트리거를
    /// 남겨 다음 틱에 다시 본다). 소진 중에도 사용자가 타이핑을 멈추면 새 hit이 안 오므로,
    /// 여기서 버리면 그 소진은 영영 기록되지 않는다.
    func testCooldownAfterFailedFetchThenRetry() {
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false, cachedUsageAt: nil,
                                           hitObservedAt: now.addingTimeInterval(-10),
                                           lastFetchAttemptAt: now.addingTimeInterval(-10),
                                           now: now),
                       .skipCooldown)
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false, cachedUsageAt: nil,
                                           hitObservedAt: now.addingTimeInterval(-61),
                                           lastFetchAttemptAt: now.addingTimeInterval(-61),
                                           now: now),
                       .fetchUsage)
    }

    /// 실패했던 조회의 낡은 캐시가 쿨다운을 건너뛰게 하지 않는다(캐시가 트리거보다 오래됨).
    func testStaleCacheDoesNotBypassCooldown() {
        XCTAssertEqual(HitAttribution.plan(activeIsLimited: false,
                                           cachedUsageAt: now.addingTimeInterval(-300),
                                           hitObservedAt: now.addingTimeInterval(-10),
                                           lastFetchAttemptAt: now.addingTimeInterval(-10),
                                           now: now),
                       .skipCooldown)
    }
}
