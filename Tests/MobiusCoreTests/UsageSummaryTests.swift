import XCTest
@testable import MobiusCore

final class UsageSummaryTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC

    func testHoursAndAbsoluteClock() {
        let snap = UsageSnapshot(fiveHourPercent: 1.4, fiveHourResetsAt: now.addingTimeInterval(90 * 60),
                                 sevenDayPercent: 0, sevenDayResetsAt: nil, fetchedAt: now)
        let lines = snap.summaryLines(now: now, timeZone: utc)
        XCTAssertEqual(lines[0], "5시간 1%  리셋 1시간 30분 후 (23:43)")
        XCTAssertEqual(lines[1], "7일 0%  리셋 -")
    }

    func testDaysKeepMinutes() {
        let reset = now.addingTimeInterval(Double((2 * 1440 + 3 * 60 + 59) * 60))
        XCTAssertEqual(UsageSnapshot.resetText(reset, now: now, timeZone: utc),
                       "2일 3시간 59분 후 (11/17 02:12)")
    }

    func testPastResetAndMissingPercent() {
        XCTAssertEqual(UsageSnapshot.resetText(now.addingTimeInterval(-1), now: now, timeZone: utc), "-")
        XCTAssertEqual(UsageSnapshot.summaryRow("5시간", nil, nil, now: now, timeZone: utc),
                       "5시간 ?  리셋 -")
    }
}
