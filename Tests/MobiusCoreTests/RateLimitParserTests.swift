import XCTest
@testable import MobiusCore

/// 스파이크(docs/spike/rate-limit-format.md) 실측 포맷 기준 테스트.
/// 실측 텍스트 5종 + 제외 규칙 + 시각 굴림(익일/익년) + 레거시 하위호환.
final class RateLimitParserTests: XCTestCase {

    // 기준 이벤트 시각: 2026-06-19 17:48:23 KST (= 08:48:23 UTC)
    static let defaultTimestamp = "2026-06-19T08:48:23.930Z"

    func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    /// 실측 구조(§1.1)를 본뜬 세션 로그 한 줄을 만든다.
    func eventLine(text: String,
                   timestamp: String? = defaultTimestamp,
                   error: String? = "rate_limit",
                   status: Int? = 429) -> String {
        var obj: [String: Any] = [
            "type": "assistant",
            "uuid": "00000000-0000-0000-0000-000000000000",
            "message": [
                "model": "<synthetic>",
                "role": "assistant",
                "type": "message",
                "content": [["type": "text", "text": text]],
            ],
        ]
        if let timestamp { obj["timestamp"] = timestamp }
        if let error {
            obj["error"] = error
            obj["isApiErrorMessage"] = true
        }
        if let status { obj["apiErrorStatus"] = status }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: 실측 텍스트 5종

    func testServerSideLimitIsExcluded() {
        // 실측 59건 중 41건(69%) — 서버측 제한. 계정 전환 트리거가 되면 안 된다.
        let line = eventLine(
            text: "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited")
        XCTAssertNil(RateLimitParser.parse(line: line))
    }

    func testMonthlySpendLimitIsClassifiedNotAsWindowExhaustion() {
        // 2026-07-13 실측: 이 이벤트는 플랜 창이 여유여도 뜬다(비차단) — kind로 구분해
        // 호출측이 소진 기록 대신 usage 교차 확인을 하게 한다.
        let line = eventLine(
            text: "You've hit your monthly spend limit · raise it at claude.ai/settings/usage")
        let hit = RateLimitParser.parse(line: line)
        XCTAssertEqual(hit?.kind, .monthlySpend)
        XCTAssertNil(hit?.resetsAt) // 리셋 시각 없음 → 호출측 폴백
        XCTAssertEqual(hit?.modelScoped, true) // 모델 전용(프리미엄) 한도 표식
        // 창 소진 이벤트는 window + modelScoped=false (음성 대조)
        let windowHit = RateLimitParser.parse(
            line: eventLine(text: "You've hit your session limit · resets 7:30pm (Asia/Seoul)"))
        XCTAssertEqual(windowHit?.kind, .window)
        XCTAssertEqual(windowHit?.modelScoped, false)
    }

    func testSessionLimitIsNotModelScoped() {
        let line = eventLine(text: "You've hit your session limit · resets 2:30pm (Asia/Seoul)")
        XCTAssertEqual(RateLimitParser.parse(line: line)?.modelScoped, false)
    }

    func testSessionLimitResetsSameDay() {
        // 이벤트 17:48 KST, resets 7:30pm → 당일 19:30 KST = 10:30 UTC
        let line = eventLine(text: "You've hit your session limit · resets 7:30pm (Asia/Seoul)")
        XCTAssertEqual(RateLimitParser.parse(line: line)?.resetsAt,
                       iso("2026-06-19T10:30:00Z"))
    }

    func testSessionLimitRollsToNextDayWhenTimePassed() {
        // 이벤트 17:48 KST, resets 2:30pm → 이미 지남 → 익일 14:30 KST = 05:30 UTC
        let line = eventLine(text: "You've hit your session limit · resets 2:30pm (Asia/Seoul)")
        XCTAssertEqual(RateLimitParser.parse(line: line)?.resetsAt,
                       iso("2026-06-20T05:30:00Z"))
    }

    func testWeeklyLimitWithDateAndOmittedMinutes() {
        // 분 생략형(8am) + 날짜. Jul 13 8:00 KST = Jul 12 23:00 UTC
        let line = eventLine(text: "You've hit your weekly limit · resets Jul 13 at 8am (Asia/Seoul)")
        XCTAssertEqual(RateLimitParser.parse(line: line)?.resetsAt,
                       iso("2026-07-12T23:00:00Z"))
    }

    func testWeeklyLimitRollsToNextYearWhenDatePassed() {
        // 이벤트가 12월인데 resets Jul 13 → 이미 지난 날짜 → 익년으로 굴림
        let line = eventLine(text: "You've hit your weekly limit · resets Jul 13 at 8am (Asia/Seoul)",
                             timestamp: "2026-12-20T00:00:00Z")
        XCTAssertEqual(RateLimitParser.parse(line: line)?.resetsAt,
                       iso("2027-07-12T23:00:00Z"))
    }

    func testModelUnavailabilityIsNotAHit() {
        let line = eventLine(text: "Claude Opus 4 is currently unavailable. Learn more: https://status.anthropic.com",
                             status: nil)
        XCTAssertNil(RateLimitParser.parse(line: line))
    }

    // MARK: 구조화 판별

    func testDefensiveCandidateCheckWithoutErrorField() {
        // error 필드가 없어도 isApiErrorMessage==true && apiErrorStatus==429 이면 후보로 인정
        var line = eventLine(text: "You've hit your session limit · resets 7:30pm (Asia/Seoul)",
                             error: nil)
        line = line.replacingOccurrences(of: #""apiErrorStatus":429"#,
                                         with: #""apiErrorStatus":429,"isApiErrorMessage":true"#)
        XCTAssertEqual(RateLimitParser.parse(line: line)?.resetsAt,
                       iso("2026-06-19T10:30:00Z"))
    }

    func testRateLimitTextWithoutStructuredFieldsIsIgnored() {
        // 구조화 필드가 없는 일반 메시지가 현행 문구를 인용해도 이벤트가 아니다
        let line = eventLine(text: "You've hit your session limit · resets 7:30pm (Asia/Seoul)",
                             error: nil, status: nil)
        XCTAssertNil(RateLimitParser.parse(line: line))
    }

    // MARK: P5 관대한 폴백

    func testFallbackVariantWithResetsAt() {
        // 미래 문구 변형: "resets at <시각>" 형태도 best-effort 파싱
        let line = eventLine(text: "You've hit your usage limit · resets at 7:30pm (Asia/Seoul)")
        XCTAssertEqual(RateLimitParser.parse(line: line)?.resetsAt,
                       iso("2026-06-19T10:30:00Z"))
    }

    func testFallbackVariantWithUnparseableTime() {
        // 계정 한도임은 확실하지만 시각을 못 읽으면 resetsAt nil로 이벤트만 알림
        let line = eventLine(text: "You've hit your session limit · resets soon")
        let hit = RateLimitParser.parse(line: line)
        XCTAssertNotNil(hit)
        XCTAssertNil(hit?.resetsAt)
    }

    // MARK: 레거시 하위호환 (P4)

    func testLegacyPipeEpochWithLineTimestamp() {
        // 구버전 포맷 — 구조화 필드 없이도 인정. sanity 기준은 라인의 timestamp.
        let line = eventLine(text: "Claude AI usage limit reached|1719900000",
                             timestamp: "2026-07-02T00:00:00Z", error: nil, status: nil)
        // 2026-07-02 기준으로 epoch 1719900000(2024-07-02)은 sanity 밖 → nil
        XCTAssertNil(RateLimitParser.parse(line: line))

        let ok = eventLine(text: "Claude AI usage limit reached|1719900000",
                           timestamp: "2024-07-02T00:00:00Z", error: nil, status: nil)
        XCTAssertEqual(RateLimitParser.parse(line: ok)?.resetsAt,
                       Date(timeIntervalSince1970: 1_719_900_000))
    }

    func testLegacyPipeEpochFallsBackToNowWhenNoTimestamp() {
        let line = eventLine(text: "Claude AI usage limit reached|1719900000",
                             timestamp: nil, error: nil, status: nil)
        XCTAssertEqual(RateLimitParser.parse(line: line,
                                             now: Date(timeIntervalSince1970: 1_719_890_000))?.resetsAt,
                       Date(timeIntervalSince1970: 1_719_900_000))
        // now가 멀리 떨어져 있으면 sanity에 걸림
        XCTAssertNil(RateLimitParser.parse(line: line,
                                           now: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testLegacyEpochMilliseconds() {
        let line = eventLine(text: "usage limit reached|1719900000000",
                             timestamp: "2024-07-02T00:00:00Z", error: nil, status: nil)
        XCTAssertEqual(RateLimitParser.parse(line: line)?.resetsAt,
                       Date(timeIntervalSince1970: 1_719_900_000))
    }

    // MARK: 오탐 방지

    func testNoFalsePositiveOnOrdinaryLines() {
        XCTAssertNil(RateLimitParser.parse(line: "not even json"))
        XCTAssertNil(RateLimitParser.parse(line: #"{"type":"user","message":"hello limit"}"#))
        // 한도 언급은 있으나 epoch도 구조화 필드도 없으면 무시
        XCTAssertNil(RateLimitParser.parse(line: #"{"text":"we discussed usage limit reached yesterday"}"#))
        // epoch 자릿수 미달
        XCTAssertNil(RateLimitParser.parse(line: #"{"text":"usage limit reached|123"}"#))
    }
}
