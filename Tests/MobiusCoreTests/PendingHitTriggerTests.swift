import XCTest
@testable import MobiusCore

/// 보류 트리거를 바꾸는 규칙(실패 기록 21·25). AppState에는 테스트 타깃이 없으므로, 트리거가 시간이
/// 흐르는 동안 어떤 값을 들고 있는지는 여기서 고정한다.
final class PendingHitTriggerTests: XCTestCase {
    let switchedAt = Date(timeIntervalSince1970: 1_770_000_000)
    let ttl: TimeInterval = 20 * 60
    let hit = RateLimitHit(resetsAt: Date(timeIntervalSince1970: 1_770_010_000))
    let otherHit = RateLimitHit(resetsAt: Date(timeIntervalSince1970: 1_770_020_000))
    let noRecentSwitch = Date(timeIntervalSince1970: 1_769_990_000)

    private func at(_ seconds: TimeInterval) -> Date { switchedAt.addingTimeInterval(seconds) }

    /// 리뷰 지적: 전환 17초 뒤에 도착한 hit은 트리거가 수명이나 429 대기 동안 붙들려 있어도 믿지 않는다.
    /// 같은 트리거를 전환 1분 뒤와 6분 뒤에 판단해도 둘 다 앞당기지 않고, 최후 폴백도 기록하지 않는다.
    func testHitRightAfterSwitchStaysUntrustedAsTimePasses() {
        var trigger = PendingHitTrigger(logHit: hit, arrivedAt: at(17), lastActiveChangeAt: switchedAt)
        XCTAssertFalse(trigger.hitTrusted)
        // 재시도가 이어지는 동안 트리거가 바뀌는 길(신선도 갱신, 백오프 해제)을 모두 지나도 판정은 그대로다.
        trigger.needsFresherThan = at(60)
        trigger = trigger.restartingLifetime(at: at(6 * 60))
        for judgedAt in [at(60), at(6 * 60)] {
            XCTAssertFalse(trigger.hitTrusted)
            XCTAssertFalse(HitAttribution.givesUpEarlyWhileRateLimited(
                retryAt: judgedAt.addingTimeInterval(3600), firstSeenAt: trigger.firstSeenAt, ttl: ttl,
                hitTrusted: trigger.hitTrusted))
        }
    }

    /// 셀프리뷰 지적: hit이 도착한 **뒤에** 사용자가 전환해도, 전환 전에 도착한 진짜 소진은 믿는다.
    /// 도착 시각을 지금의 마지막 전환과 비교하면 차이가 음수가 되어 끝내 버려진다.
    func testSwitchAfterArrivalKeepsHitTrusted() {
        let arrivedAt = at(0)
        var trigger = PendingHitTrigger(logHit: hit, arrivedAt: arrivedAt, lastActiveChangeAt: noRecentSwitch)
        XCTAssertTrue(trigger.hitTrusted)
        // t=60s 사용자가 다른 계정으로 전환한 뒤의 재시도·신선도 갱신
        trigger.needsFresherThan = at(126)
        XCTAssertTrue(trigger.hitTrusted)
        XCTAssertEqual(trigger.logHit, hit)
    }

    /// 믿지 못하던 트리거에 전환과 무관한 hit이 오면 그 hit으로 바뀌고 수명 기준은 물려받는다 →
    /// 다음 재시도에서 곧바로 앞당겨 기록한다.
    func testLaterTrustedHitReplacesUntrustedHitAndKeepsLifetime() {
        let first = PendingHitTrigger(logHit: hit, arrivedAt: at(17), lastActiveChangeAt: switchedAt)
        let next = first.receiving(otherHit, at: at(6 * 60), lastActiveChangeAt: switchedAt)
        XCTAssertTrue(next.hitTrusted)
        XCTAssertEqual(next.logHit, otherHit)
        XCTAssertEqual(next.firstSeenAt, at(17), "수명 기준은 물려받는다")
        XCTAssertEqual(next.needsFresherThan, at(6 * 60), "새 hit은 새 데이터를 요구한다")
        XCTAssertTrue(HitAttribution.givesUpEarlyWhileRateLimited(
            retryAt: at(6 * 60 + 3600), firstSeenAt: next.firstSeenAt, ttl: ttl, hitTrusted: next.hitTrusted))
    }

    /// 믿을 만한 hit을 들고 있는데 전환이 오간 직후 다른 계정의 늦은 에러가 도착해도 덮어쓰지 않는다.
    func testUntrustedHitDoesNotOverwriteTrustedHit() {
        let trusted = PendingHitTrigger(logHit: hit, arrivedAt: at(0), lastActiveChangeAt: noRecentSwitch)
        let rejoined = at(120)   // B→C→B 로 돌아온 시각
        let next = trusted.receiving(otherHit, at: rejoined.addingTimeInterval(17), lastActiveChangeAt: rejoined)
        XCTAssertTrue(next.hitTrusted)
        XCTAssertEqual(next.logHit, hit)
        XCTAssertEqual(next.needsFresherThan, rejoined.addingTimeInterval(17), "신선도 기준은 새 신호로 갱신한다")
    }

    /// P3 신호(창 hit이 아님)는 트리거의 hit과 판정을 바꾸지 않는다.
    func testMonthlySpendSignalKeepsHitAndTrust() {
        let untrusted = PendingHitTrigger(logHit: hit, arrivedAt: at(17), lastActiveChangeAt: switchedAt)
        let next = untrusted.receiving(nil, at: at(10 * 60), lastActiveChangeAt: switchedAt)
        XCTAssertFalse(next.hitTrusted)
        XCTAssertEqual(next.logHit, hit)
    }

    /// 셀프리뷰 지적: 모델 한도 때문에 보류됐다는 표시는 새 hit과 백오프 해제를 지나도 남는다. 예전에는
    /// 트리거를 다시 만들 때 false로 돌아가, 최후 폴백이 모델 한도만 걸린 계정을 계정 전체 소진으로 기록했다.
    func testModelScopedMarkSurvivesNewHitAndBackoffRelease() {
        var trigger = PendingHitTrigger(logHit: hit, arrivedAt: at(0), lastActiveChangeAt: noRecentSwitch)
        trigger.lastInconclusiveWasModelScoped = true
        let afterHit = trigger.receiving(otherHit, at: at(90), lastActiveChangeAt: noRecentSwitch)
        XCTAssertTrue(afterHit.lastInconclusiveWasModelScoped)
        let afterBackoff = afterHit.restartingLifetime(at: at(15 * 60))
        XCTAssertTrue(afterBackoff.lastInconclusiveWasModelScoped)
        XCTAssertEqual(afterBackoff.firstSeenAt, at(15 * 60))
        XCTAssertEqual(afterBackoff.logHit, otherHit)
        XCTAssertEqual(afterBackoff.hitTrusted, afterHit.hitTrusted)
    }
}
