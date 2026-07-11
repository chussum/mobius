import Foundation

/// 계정의 5시간/주간 사용량 스냅샷 (usage 엔드포인트 실측 스키마 기반)
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var fiveHourPercent: Double?
    public var fiveHourResetsAt: Date?
    public var sevenDayPercent: Double?
    public var sevenDayResetsAt: Date?
    public var fetchedAt: Date

    public init(fiveHourPercent: Double?, fiveHourResetsAt: Date?,
                sevenDayPercent: Double?, sevenDayResetsAt: Date?, fetchedAt: Date) {
        self.fiveHourPercent = fiveHourPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayPercent = sevenDayPercent
        self.sevenDayResetsAt = sevenDayResetsAt
        self.fetchedAt = fetchedAt
    }
}

public enum UsageFetcherError: Error, Equatable {
    /// 401/403 — 토큰이 거부됨. 저장된 expiresAt이 아직 유효한데 이 에러면
    /// 진짜 재로그인 필요(토큰 폐기)로 판단할 수 있다 (만료 토큰의 401은 오탐).
    case unauthorized
}

/// Claude OAuth usage 엔드포인트 조회. 사용자가 게이지 표시를 켰을 때만,
/// 팝오버를 열 때 저빈도(캐시 만료 시)로만 호출된다 — 상시 폴링 없음.
public enum UsageFetcher {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Claude Code 자격증명 blob(JSON)에서 access token 추출
    public static func accessToken(from keychainBlob: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: keychainBlob) as? [String: Any]
        else { return nil }
        if let oauth = obj["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String { return token }
        return obj["accessToken"] as? String
    }

    /// 자격증명 blob의 access token 만료 시각. epoch ms(실측: claudeAiOauth.expiresAt)와
    /// s 둘 다 허용 — 1e12 초과면 ms로 해석.
    public static func expiresAt(from keychainBlob: Data) -> Date? {
        guard let obj = try? JSONSerialization.jsonObject(with: keychainBlob) as? [String: Any]
        else { return nil }
        let raw = ((obj["claudeAiOauth"] as? [String: Any])?["expiresAt"]) ?? obj["expiresAt"]
        let n: Double
        if let d = raw as? Double { n = d }
        else if let i = raw as? Int { n = Double(i) }
        else { return nil }
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    }

    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso = ISO8601DateFormatter()

    public static func parse(_ data: Data, now: Date = Date()) -> UsageSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func block(_ key: String) -> (Double?, Date?) {
            guard let b = obj[key] as? [String: Any] else { return (nil, nil) }
            let pct: Double?
            if let d = b["utilization"] as? Double { pct = d }
            else if let i = b["utilization"] as? Int { pct = Double(i) }
            else { pct = nil }
            var date: Date?
            if let s = b["resets_at"] as? String {
                date = isoFrac.date(from: s) ?? iso.date(from: s)
            }
            return (pct, date)
        }
        let (fivePct, fiveReset) = block("five_hour")
        let (weekPct, weekReset) = block("seven_day")
        guard fivePct != nil || weekPct != nil else { return nil }
        return UsageSnapshot(fiveHourPercent: fivePct, fiveHourResetsAt: fiveReset,
                             sevenDayPercent: weekPct, sevenDayResetsAt: weekReset,
                             fetchedAt: now)
    }

    public static func fetch(keychainBlob: Data) async throws -> UsageSnapshot? {
        guard let token = accessToken(from: keychainBlob) else { return nil }
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageFetcherError.unauthorized
        }
        guard http.statusCode == 200 else { return nil }
        return parse(data)
    }
}
