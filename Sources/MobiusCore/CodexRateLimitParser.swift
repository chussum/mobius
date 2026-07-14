import Foundation

/// codex 세션 로그(rollout-*.jsonl)의 rate_limits 상태.
///
/// 실측(2026-07-12, codex-cli 0.144.1): 매 턴의 `event_msg`/`token_count` 이벤트에
/// `payload.rate_limits`가 붙어 온다 — Claude처럼 에러 문구를 긁을 필요 없이 구조화돼 있고,
/// 사용량 게이지도 이 이벤트에서 네트워크 없이 얻는다.
/// ```
/// {"timestamp":"2026-07-12T09:07:14.309Z","type":"event_msg","payload":{"type":"token_count",
///  "info":{...},"rate_limits":{"limit_id":"codex","primary":{"used_percent":64.0,
///  "window_minutes":300,"resets_at":1783861033},"secondary":{"used_percent":82.0,
///  "window_minutes":10080,"resets_at":1784354513},"plan_type":"pro",
///  "rate_limit_reached_type":null}}}
/// ```
/// ★ 창 종류는 슬롯(primary/secondary)이 아니라 `window_minutes`로 판정한다.
/// 실측 2026-07-12: primary=5시간(300분), secondary=주간(10080분)이었으나,
/// 실측 2026-07-13: OpenAI가 5시간 한도를 임시 제거 → primary=주간(10080분), secondary=null.
/// 슬롯 위치로 매핑하면 주간이 "5시간" 게이지로 오표시된다 → 반드시 window_minutes로 분류.
public struct CodexRateLimitStatus: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var usedPercent: Double
        public var windowMinutes: Int?
        public var resetsAt: Date?

        public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.windowMinutes = windowMinutes
            self.resetsAt = resetsAt
        }
    }

    public var primary: Window?    // rate_limits.primary 슬롯 (창 종류 고정 아님)
    public var secondary: Window?  // rate_limits.secondary 슬롯
    /// rate_limit_reached_type — null이 아니면 서버가 소진을 명시한 것.
    /// 값 형태는 미실측(실제 소진 미관찰).
    public var reachedType: String?
    /// 라인 자신의 timestamp (없으면 nil)
    public var timestamp: Date?

    public init(primary: Window?, secondary: Window?, reachedType: String?, timestamp: Date?) {
        self.primary = primary
        self.secondary = secondary
        self.reachedType = reachedType
        self.timestamp = timestamp
    }

    /// 관찰된 창들 (슬롯 위치 무관).
    private var windows: [Window] { [primary, secondary].compactMap { $0 } }

    /// 5시간(단기) 창 — window_minutes < 하루(1440분). window_minutes가 없으면 단기로 간주
    /// (구 구조의 primary=5h 기본값 보존).
    public var shortWindow: Window? { windows.first { ($0.windowMinutes ?? 300) < 1440 } }
    /// 주간(장기) 창 — window_minutes ≥ 하루.
    public var weeklyWindow: Window? { windows.first { ($0.windowMinutes ?? 0) >= 1440 } }

    /// 소진 판정: used_percent >= 100인 창이 있거나, 서버가 명시(reached_type != nil).
    /// 리셋 시각은 소진(또는 관찰된) 창들 중 가장 늦은 resets_at — 어느 창이 잠갔든 가장
    /// 늦게 풀리는 시점까지 계정을 못 쓰므로(보수적). 슬롯 위치에 의존하지 않는다.
    public func exhaustionHit() -> RateLimitHit? {
        let exhausted = windows.filter { $0.usedPercent >= 100 }
        if !exhausted.isEmpty {
            return RateLimitHit(resetsAt: exhausted.compactMap(\.resetsAt).max())
        }
        if reachedType != nil {
            // 서버 명시하나 어느 창도 100% 아님 → 관찰된 창 중 가장 늦은 리셋(없으면 nil→24h 폴백).
            return RateLimitHit(resetsAt: windows.compactMap(\.resetsAt).max())
        }
        return nil
    }

    /// 게이지용 사용량 스냅샷 — 창 종류를 window_minutes로 판정해 투영 (네트워크 0).
    /// 5h 한도가 없는 계정(주간만)은 fiveHour=nil로 5시간 게이지가 표시되지 않는다.
    public func usageSnapshot(fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(fiveHourPercent: shortWindow?.usedPercent,
                      fiveHourResetsAt: shortWindow?.resetsAt,
                      sevenDayPercent: weeklyWindow?.usedPercent,
                      sevenDayResetsAt: weeklyWindow?.resetsAt,
                      fetchedAt: fetchedAt)
    }
}

/// codex 세션 로그 한 줄에서 rate_limits 상태를 찾는다.
public enum CodexRateLimitParser {
    /// - Parameter line: rollout 로그 한 줄 (JSON 객체 기대). 시각 판단은
    ///   라인 자신의 timestamp를 상태에 실어 호출측이 한다.
    public static func parse(line: String) -> CodexRateLimitStatus? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any]
        else { return nil }

        // ★ 모델 전용 한도(limit_name 존재 — 예: "GPT-5.3-Codex-Spark", limit_id "codex_*")는
        //   계정 게이지·소진 판정에서 제외한다(실측 2026-07-13). 특정 모델만 제한될 뿐 계정은
        //   다른 모델로 쓸 수 있으므로(Claude weekly_scoped와 동일 취급). 계정 한도는
        //   limit_name==null. 안 걸러내면 계정 창과 섞여 게이지가 깜빡이고 오소진 판정된다.
        if rateLimits["limit_name"] is String { return nil }

        return CodexRateLimitStatus(
            primary: window(rateLimits["primary"] as? [String: Any]),
            secondary: window(rateLimits["secondary"] as? [String: Any]),
            reachedType: rateLimits["rate_limit_reached_type"] as? String,
            timestamp: RateLimitParser.timestamp(from: obj))
    }

    static func window(_ dict: [String: Any]?) -> CodexRateLimitStatus.Window? {
        guard let dict, let pct = dict["used_percent"] as? Double else { return nil }
        return CodexRateLimitStatus.Window(usedPercent: pct,
                                           windowMinutes: dict["window_minutes"] as? Int,
                                           resetsAt: (dict["resets_at"] as? Double)
                                               .map(dateFromEpochSecondsOrMillis))
    }
}
