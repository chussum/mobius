import Foundation

public enum CodexUsageFetcherError: Error, Equatable {
    /// 401/403 — 토큰이 거부됨. 게이지 프로브에서는 **무해**하다(만료된 비활성 계정 토큰이
    /// 흔하고, GET엔 회전이 없어 재로그인 신호가 아니다). 호출측은 게이지를 stale로 두고
    /// 아무것도 마킹하지 않는다 (CLAUDE.md: Codex 재인증 자동 감지 미구현).
    case unauthorized
}

/// codex ChatGPT usage 엔드포인트 조회 — **비활성 codex 계정의 게이지 전용**.
/// 활성 계정은 세션 로그 in-band 경로(processCodexBatches)가 그대로 담당하므로 이 경로를 타지
/// 않는다. Claude의 `UsageFetcher`와 대칭이며, 같은 상태 엔드포인트를 codex가 이미 폴링하므로
/// 추가 쿼터 부담이 없다.
///
/// 실측 응답 스키마(HTTP 200):
/// ```
/// {"rate_limit":{"allowed":true,"limit_reached":false,
///   "primary_window":{"used_percent":12,"limit_window_seconds":604800,"reset_at":1784961938},
///   "secondary_window":null},
///  "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark", ...}],
///  "rate_limit_reached_type":null}
/// ```
/// 매핑:
/// - 창은 `rate_limit.primary_window` / `secondary_window` (각각 null 가능).
/// - `used_percent`→usedPercent, `limit_window_seconds`/60→windowMinutes, `reset_at`→resetsAt.
///   창 종류(5시간/주간)는 슬롯이 아니라 CodexRateLimitStatus가 window_minutes로 판정한다.
/// - `additional_rate_limits[]`(limit_name 존재 = 모델 전용)는 계정 창·소진에서 **제외** —
///   세션 로그 파서가 `limit_name != null`을 거르는 것과 동일 취급(Claude weekly_scoped와 같은 원리).
/// - 소진: top-level `rate_limit_reached_type` 또는 `rate_limit.limit_reached` 또는 used_percent>=100
///   (기존 exhaustionHit 의미론에 그대로 정규화해 태운다).
public enum CodexUsageFetcher {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// 방어적 UA — codex CLI와 동일 형태로 실어 서버가 봇으로 차단하지 않게 한다. URLRequest
    /// setValue만으로는 CFNetwork가 무시할 수 있어(TokenRefresher 실패 기록 14) 세션 레벨로 못박는다.
    public static let userAgent = CodexTokenRefresher.userAgent
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["User-Agent": CodexUsageFetcher.userAgent]
        return URLSession(configuration: cfg)
    }()

    /// wham/usage 응답 → CodexRateLimitStatus (순수 — 유닛 테스트 대상). now는 상태 timestamp용.
    public static func parse(_ data: Data, now: Date = Date()) -> CodexRateLimitStatus? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rl = obj["rate_limit"] as? [String: Any] else { return nil }
        let primary = window(rl["primary_window"] as? [String: Any])
        let secondary = window(rl["secondary_window"] as? [String: Any])
        guard primary != nil || secondary != nil else { return nil }
        // 소진 신호를 reachedType로 정규화 — 기존 exhaustionHit(reachedType != nil 또는
        // used_percent>=100)에 그대로 태운다. rate_limit.limit_reached는 top-level reached_type가
        // 비어 있어도 서버가 명시한 소진이므로 합성 마커로 승격한다.
        let reached: String?
        if let t = obj["rate_limit_reached_type"] as? String { reached = t }
        else if (rl["limit_reached"] as? Bool) == true { reached = "limit_reached" }
        else { reached = nil }
        return CodexRateLimitStatus(primary: primary, secondary: secondary,
                                    reachedType: reached, timestamp: now)
    }

    static func window(_ dict: [String: Any]?) -> CodexRateLimitStatus.Window? {
        guard let dict else { return nil }  // null 슬롯 → 창 없음
        let pct: Double
        if let d = dict["used_percent"] as? Double { pct = d }
        else if let i = dict["used_percent"] as? Int { pct = Double(i) }
        else { return nil }
        let minutes: Int?
        if let s = dict["limit_window_seconds"] as? Int { minutes = s / 60 }
        else if let s = dict["limit_window_seconds"] as? Double { minutes = Int(s) / 60 }
        else { minutes = nil }
        let reset = (dict["reset_at"] as? Double).map(dateFromEpochSecondsOrMillis)
            ?? (dict["reset_at"] as? Int).map { dateFromEpochSecondsOrMillis(Double($0)) }
        return CodexRateLimitStatus.Window(usedPercent: pct, windowMinutes: minutes, resetsAt: reset)
    }

    /// 저장된 auth.json 바이트로 GET 조회. 401/403 → unauthorized throw, 200 → parse, 그 외 → nil.
    /// **읽기 전용**: auth.json을 쓰지 않고, 토큰을 회전/갱신하지 않는다.
    public static func fetch(authJSON: Data) async throws -> CodexRateLimitStatus? {
        guard let token = CodexAuthBlob.accessToken(fromAuthJSON: authJSON) else { return nil }
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountId = CodexAuthBlob.accountId(fromAuthJSON: authJSON) {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CodexUsageFetcherError.unauthorized
        }
        guard http.statusCode == 200 else { return nil }
        return parse(data)
    }
}
