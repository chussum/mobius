import XCTest
@testable import MobiusCore

final class UsageFetcherTests: XCTestCase {
    // 실측 응답(2026-07-11) 축약본
    let sample = #"""
    {
     "five_hour": {"utilization": 42.0, "resets_at": "2026-07-10T19:09:59.895133+00:00"},
     "seven_day": {"utilization": 33.0, "resets_at": "2026-07-12T22:59:59.895158+00:00"},
     "extra_usage": {"is_enabled": true}
    }
    """#

    func testParseRealSchema() throws {
        let snap = try XCTUnwrap(UsageFetcher.parse(Data(sample.utf8)))
        XCTAssertEqual(snap.fiveHourPercent, 42.0)
        XCTAssertEqual(snap.sevenDayPercent, 33.0)
        // 마이크로초 fractional seconds 파싱 확인
        let expected = ISO8601DateFormatter()
        XCTAssertEqual(Int(snap.fiveHourResetsAt!.timeIntervalSince1970),
                       Int(expected.date(from: "2026-07-10T19:09:59+00:00")!.timeIntervalSince1970))
        XCTAssertNotNil(snap.sevenDayResetsAt)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(UsageFetcher.parse(Data("not json".utf8)))
        XCTAssertNil(UsageFetcher.parse(Data(#"{"unrelated": 1}"#.utf8)))
    }

    func testAccessTokenExtraction() {
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r"}}"#.utf8)
        XCTAssertEqual(UsageFetcher.accessToken(from: blob), "tok-123")
        XCTAssertNil(UsageFetcher.accessToken(from: Data("{}".utf8)))
    }

    func testExpiresAtParsing() {
        // 실측: claudeAiOauth.expiresAt는 13자리 epoch 밀리초 (2026-07-11 확인)
        let ms = Data(#"{"claudeAiOauth":{"expiresAt":1783785648000}}"#.utf8)
        XCTAssertEqual(UsageFetcher.expiresAt(from: ms),
                       Date(timeIntervalSince1970: 1_783_785_648))
        let secs = Data(#"{"expiresAt":1783785648}"#.utf8) // 방어: 초 단위도 허용
        XCTAssertEqual(UsageFetcher.expiresAt(from: secs),
                       Date(timeIntervalSince1970: 1_783_785_648))
        XCTAssertNil(UsageFetcher.expiresAt(from: Data("{}".utf8)))
    }
}
