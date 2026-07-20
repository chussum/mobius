import XCTest
@testable import MobiusCore

final class AuthSuspicionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

    func testFirstFailureStartsCountAndClock() {
        let r = AuthSuspicion.recordFailure(nil, now: t0)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.firstFailedAt, t0)
        XCTAssertFalse(r.notified)
    }

    /// 첫 실패 시각은 누적 중에 밀리면 안 된다 — 경과 시간 조건이 영영 안 차게 된다.
    func testSubsequentFailuresKeepFirstFailedAt() {
        var r = AuthSuspicion.recordFailure(nil, now: t0)
        r = AuthSuspicion.recordFailure(r, now: t0.addingTimeInterval(600))
        r = AuthSuspicion.recordFailure(r, now: t0.addingTimeInterval(3600))
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.firstFailedAt, t0)
    }

    /// 팝오버를 연달아 열어 3회를 채워도 30분이 안 지났으면 배지를 띄우지 않는다.
    func testCountAloneIsNotEnough() {
        var r = AuthSuspicion.recordFailure(nil, now: t0)
        r = AuthSuspicion.recordFailure(r, now: t0.addingTimeInterval(60))
        r = AuthSuspicion.recordFailure(r, now: t0.addingTimeInterval(120))
        XCTAssertEqual(r.count, 3)
        XCTAssertFalse(AuthSuspicion.isSuspect(r, now: t0.addingTimeInterval(120)))
    }

    /// 반대로 시간만 지나고 실패가 1~2회면 단발성이므로 역시 띄우지 않는다.
    func testElapsedAloneIsNotEnough() {
        var r = AuthSuspicion.recordFailure(nil, now: t0)
        r = AuthSuspicion.recordFailure(r, now: t0.addingTimeInterval(60))
        XCTAssertFalse(AuthSuspicion.isSuspect(r, now: t0.addingTimeInterval(6 * 3600)))
    }

    func testBothConditionsMet() {
        var r = AuthSuspicion.recordFailure(nil, now: t0)
        r = AuthSuspicion.recordFailure(r, now: t0.addingTimeInterval(600))
        r = AuthSuspicion.recordFailure(r, now: t0.addingTimeInterval(1_200))
        XCTAssertTrue(AuthSuspicion.isSuspect(r, now: t0.addingTimeInterval(1_800)))
    }

    /// 임계값은 시간 조건을 포함하므로, 실패가 더 안 나도 시간이 지나면 켜진다
    /// (tick이 주기적으로 재계산하는 이유 — 팝오버를 안 열어도 배지가 뜬다).
    func testFlipsOnWithoutNewFailuresOnceTimePasses() {
        var r = AuthSuspicion.recordFailure(nil, now: t0)
        r = AuthSuspicion.recordFailure(r, now: t0)
        r = AuthSuspicion.recordFailure(r, now: t0)
        XCTAssertFalse(AuthSuspicion.isSuspect(r, now: t0))
        XCTAssertTrue(AuthSuspicion.isSuspect(r, now: t0.addingTimeInterval(AuthSuspicion.minElapsed)))
    }

    func testNilRecordIsNeverSuspect() {
        XCTAssertFalse(AuthSuspicion.isSuspect(nil, now: t0))
    }

    /// UserDefaults에 저장되므로 왕복이 손실 없이 되어야 한다(앱 재시작에도 누적 유지).
    func testCodableRoundTrip() throws {
        let r = AuthFailureRecord(count: 4, firstFailedAt: t0, notified: true)
        let data = try JSONEncoder().encode([UUID(): r])
        let back = try JSONDecoder().decode([UUID: AuthFailureRecord].self, from: data)
        XCTAssertEqual(back.values.first, r)
    }
}
