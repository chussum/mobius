import XCTest
@testable import MobiusCore

final class UsagePollBreakerTests: XCTestCase {
    func testNotTrippedBelowThreshold() {
        XCTAssertFalse(UsagePollBreaker.isTripped(consecutiveFailures: 0))
        XCTAssertFalse(UsagePollBreaker.isTripped(consecutiveFailures: 1))
        XCTAssertFalse(UsagePollBreaker.isTripped(consecutiveFailures: 2))
    }

    /// 3연속 실패에서 정확히 열린다 — 사용자가 정한 임계값.
    func testTrippedAtThreshold() {
        XCTAssertEqual(UsagePollBreaker.failureThreshold, 3)
        XCTAssertTrue(UsagePollBreaker.isTripped(consecutiveFailures: 3))
        XCTAssertTrue(UsagePollBreaker.isTripped(consecutiveFailures: 4))
    }
}
