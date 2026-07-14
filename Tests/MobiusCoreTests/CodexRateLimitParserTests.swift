import XCTest
@testable import MobiusCore

final class CodexRateLimitParserTests: XCTestCase {

    /// 실측 라인(2026-07-12, codex-cli 0.144.1) — 값만 단순화, 구조는 그대로.
    func realLine(primaryPct: Double = 64.0, secondaryPct: Double = 82.0,
                  reached: String = "null") -> String {
        #"""
        {"timestamp":"2026-07-12T09:07:14.309Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":486875,"cached_input_tokens":412288,"output_tokens":2660,"reasoning_output_tokens":336,"total_tokens":489535},"last_token_usage":{"input_tokens":88304,"cached_input_tokens":86912,"output_tokens":662,"reasoning_output_tokens":101,"total_tokens":88966},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":\#(primaryPct),"window_minutes":300,"resets_at":1783861033},"secondary":{"used_percent":\#(secondaryPct),"window_minutes":10080,"resets_at":1784354513},"credits":null,"individual_limit":null,"plan_type":"pro","rate_limit_reached_type":\#(reached)}}}
        """#
    }

    func testParsesRealTokenCountLine() throws {
        let status = try XCTUnwrap(CodexRateLimitParser.parse(line: realLine()))
        XCTAssertEqual(status.primary?.usedPercent, 64.0)
        XCTAssertEqual(status.primary?.windowMinutes, 300)
        XCTAssertEqual(status.primary?.resetsAt, Date(timeIntervalSince1970: 1_783_861_033))
        XCTAssertEqual(status.secondary?.usedPercent, 82.0)
        XCTAssertEqual(status.secondary?.windowMinutes, 10080)
        XCTAssertNil(status.reachedType)
        XCTAssertEqual(status.timestamp,
                       RateLimitParser.isoFractional.date(from: "2026-07-12T09:07:14.309Z"))
        // 소진 아님
        XCTAssertNil(status.exhaustionHit())
        // 게이지 투영
        let usage = status.usageSnapshot(fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(usage.fiveHourPercent, 64.0)
        XCTAssertEqual(usage.sevenDayPercent, 82.0)
        XCTAssertEqual(usage.sevenDayResetsAt, Date(timeIntervalSince1970: 1_784_354_513))
    }

    func testIgnoresLinesWithoutRateLimits() {
        XCTAssertNil(CodexRateLimitParser.parse(
            line: #"{"timestamp":"2026-07-12T09:00:00Z","type":"response_item","payload":{"type":"message"}}"#))
        XCTAssertNil(CodexRateLimitParser.parse(line: "not json at all"))
        XCTAssertNil(CodexRateLimitParser.parse(line: #"{"payload":{}}"#))
    }

    // MARK: 소진 판정

    func testUsedPercent100TriggersExhaustion() throws {
        let status = try XCTUnwrap(CodexRateLimitParser.parse(line: realLine(primaryPct: 100.0)))
        let hit = try XCTUnwrap(status.exhaustionHit())
        // primary 창만 소진 → 그 창의 리셋 시각
        XCTAssertEqual(hit.resetsAt, Date(timeIntervalSince1970: 1_783_861_033))
    }

    func testBothWindowsExhaustedUsesLatestReset() throws {
        let status = try XCTUnwrap(CodexRateLimitParser.parse(
            line: realLine(primaryPct: 100.0, secondaryPct: 100.0)))
        // 주간 창이 소진이면 5시간 창이 리셋돼도 소용없다 — 늦은 쪽
        XCTAssertEqual(status.exhaustionHit()?.resetsAt,
                       Date(timeIntervalSince1970: 1_784_354_513))
    }

    func testReachedTypeTriggersExhaustionWithLatestReset() throws {
        // 서버 명시(reached_type != null)면 used_percent가 100 미만이어도 소진.
        // 어느 창인지 불명이라 관찰된 창 중 가장 늦은 리셋(보수적)으로 처리 — 슬롯 위치 무관.
        let status = try XCTUnwrap(CodexRateLimitParser.parse(
            line: realLine(primaryPct: 97.0, reached: #""some_kind""#)))
        XCTAssertNotNil(status.reachedType)
        XCTAssertEqual(status.exhaustionHit()?.resetsAt,
                       Date(timeIntervalSince1970: 1_784_354_513)) // 두 창 중 늦은 쪽(주간)
    }

    // MARK: ★ 창 종류는 window_minutes로 판정 (슬롯 위치 아님)

    /// 실측 2026-07-13: OpenAI가 5시간 한도를 제거 → primary 슬롯에 주간 창(10080분),
    /// secondary=null. 슬롯으로 매핑하면 주간이 "5시간" 게이지로 오표시된다.
    func testWeeklyOnlyStructureMapsToWeeklyGauge() throws {
        let line = #"""
        {"timestamp":"2026-07-13T00:26:12.136Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1784501289},"secondary":null,"credits":null,"individual_limit":null,"plan_type":"pro","rate_limit_reached_type":null}}}
        """#
        let status = try XCTUnwrap(CodexRateLimitParser.parse(line: line))
        let usage = status.usageSnapshot(fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(usage.fiveHourPercent)                       // 5h 한도 없음 → 게이지 미표시
        XCTAssertEqual(usage.sevenDayPercent, 42.0)               // 주간이 주간으로 매핑
        XCTAssertEqual(usage.sevenDayResetsAt, Date(timeIntervalSince1970: 1_784_501_289))
    }

    /// 주간이 primary 슬롯이어도 소진 판정은 슬롯 위치에 의존하지 않는다.
    func testWeeklyOnlyExhaustionByWindowMinutes() throws {
        let line = #"""
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1784501289},"secondary":null,"rate_limit_reached_type":null}}}
        """#
        let status = try XCTUnwrap(CodexRateLimitParser.parse(line: line))
        XCTAssertEqual(status.exhaustionHit()?.resetsAt, Date(timeIntervalSince1970: 1_784_501_289))
    }

    /// 5시간 한도가 "돌아올" 때의 자동 반영 검증 — 현재 구조(주간=primary)에 5h가 secondary로
    /// 추가되는 시나리오. 슬롯 위치가 뒤바뀌어도 window_minutes로 판정하므로 둘 다 정상 매핑.
    func testFiveHourReturnInSecondarySlotIsMappedBack() throws {
        let line = #"""
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":50.0,"window_minutes":10080,"resets_at":1784501289},"secondary":{"used_percent":30.0,"window_minutes":300,"resets_at":1783861033},"rate_limit_reached_type":null}}}
        """#
        let status = try XCTUnwrap(CodexRateLimitParser.parse(line: line))
        let usage = status.usageSnapshot(fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(usage.fiveHourPercent, 30.0)               // secondary(300분) → 5시간
        XCTAssertEqual(usage.fiveHourResetsAt, Date(timeIntervalSince1970: 1_783_861_033))
        XCTAssertEqual(usage.sevenDayPercent, 50.0)               // primary(10080분) → 주간
        XCTAssertEqual(usage.sevenDayResetsAt, Date(timeIntervalSince1970: 1_784_501_289))
    }

    /// 모델 전용 한도(limit_name 존재)는 계정 게이지·소진에서 제외 — 파서가 nil 반환.
    func testModelScopedLimitIsIgnored() {
        let line = #"""
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1784507145},"secondary":null,"plan_type":"pro","rate_limit_reached_type":null}}}
        """#
        XCTAssertNil(CodexRateLimitParser.parse(line: line))
    }

    func testMillisecondEpochDefensivelyHandled() throws {
        let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1783861033000}}}}"#
        let status = try XCTUnwrap(CodexRateLimitParser.parse(line: line))
        XCTAssertEqual(status.primary?.resetsAt, Date(timeIntervalSince1970: 1_783_861_033))
        XCTAssertNil(status.secondary)
    }
}
