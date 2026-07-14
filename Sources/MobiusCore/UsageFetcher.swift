import Foundation

/// 모델별 스코프 한도 (예: Fable 주간). API의 limits[]에서 온다 —
/// 한시적 제공이 끝나 API가 항목을 안 주면 자동으로 사라진다(별도 토글 불필요).
public struct ScopedUsageLimit: Codable, Equatable, Sendable {
    public var label: String      // 모델 표시명 (예: "Fable")
    public var percent: Double
    public var resetsAt: Date?
    public init(label: String, percent: Double, resetsAt: Date?) {
        self.label = label; self.percent = percent; self.resetsAt = resetsAt
    }
}

/// 계정의 5시간/주간 사용량 스냅샷 (usage 엔드포인트 실측 스키마 기반)
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var fiveHourPercent: Double?
    public var fiveHourResetsAt: Date?
    public var sevenDayPercent: Double?
    public var sevenDayResetsAt: Date?
    /// 모델 스코프 주간 한도들 (limits[].weekly_scoped). 없으면 빈 배열.
    /// Codable: 구버전 캐시에 이 키가 없어도 디코드되도록 옵셔널.
    public var scopedLimits: [ScopedUsageLimit]?
    public var fetchedAt: Date

    public init(fiveHourPercent: Double?, fiveHourResetsAt: Date?,
                sevenDayPercent: Double?, sevenDayResetsAt: Date?,
                scopedLimits: [ScopedUsageLimit]? = nil, fetchedAt: Date) {
        self.fiveHourPercent = fiveHourPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayPercent = sevenDayPercent
        self.sevenDayResetsAt = sevenDayResetsAt
        self.scopedLimits = scopedLimits
        self.fetchedAt = fetchedAt
    }

    /// 소진 판정 — CodexRateLimitStatus.exhaustionHit와 같은 의미론:
    /// 100% 이상인 창들 중 가장 늦은(그리고 아직 안 지난) resets_at을 리셋 시각으로.
    /// 어느 창도 소진이 아니면 nil. monthly spend 이벤트(P3)의 usage 교차 확인용.
    public func exhaustionHit(now: Date) -> RateLimitHit? {
        var exhaustedResets: [Date] = []
        if let pct = fiveHourPercent, pct >= 100, let r = fiveHourResetsAt, r > now {
            exhaustedResets.append(r)
        }
        if let pct = sevenDayPercent, pct >= 100, let r = sevenDayResetsAt, r > now {
            exhaustedResets.append(r)
        }
        guard let resetsAt = exhaustedResets.max() else { return nil }
        return RateLimitHit(resetsAt: resetsAt)
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
        return dateFromEpochSecondsOrMillis(n)
    }

    /// usage 401/403 후 재로그인 마킹 판단. 자연 만료된 access 토큰의 401은 오탐이므로
    /// 마킹하지 않는다 — **활성 계정도 예외가 아니다**: claude는 세션이 돌 때만 토큰을
    /// 갱신하므로, 잠자기 등으로 한동안 안 돌면 라이브 토큰이 만료된 채 남는다
    /// (이슈 #4 실측 연쇄 — 아침 첫 팝오버 401 → 활성 오마킹 → 엔진이 멀쩡한 주계정을
    /// 밀어내 폴백 전환 + 재로그인 뱃지).
    /// 마킹하는 경우: (a) access 토큰이 아직 유효한데 거부 = 폐기(활성/비활성 공통),
    /// (b) 활성인데 refresh 토큰까지 시간 만료 = claude도 못 살림 → 재로그인만 남음.
    /// ※ (b)는 보수적 안전망이다 — claude가 쓴 라이브 blob에는 refreshTokenExpiresAt가
    /// 없어(핵심 사실의 blob 필드 목록) 값이 있는 blob(Mobius가 refresh 후 재구성한
    /// 스냅샷 등)에서만 발동한다. 정보가 없으면 죽었다고 단정하지 않는다.
    /// 비활성의 refresh 만료 판정은 validateFallbacksLocally 전담 — 여기서 관여하지 않는다.
    public static func shouldMarkReauthAfterAuthError(blob: Data, isActive: Bool,
                                                      now: Date = Date()) -> Bool {
        if (expiresAt(from: blob) ?? .distantPast) > now { return true }  // 유효한데 거부 = 폐기
        return isActive && CredentialBlob.isRefreshTokenExpired(blob: blob, now: now)
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

        // limits[] 중 모델 스코프 주간 한도(weekly_scoped) — 예: Fable 주간
        var scoped: [ScopedUsageLimit] = []
        for l in (obj["limits"] as? [[String: Any]]) ?? [] {
            guard l["kind"] as? String == "weekly_scoped",
                  let model = (l["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty else { continue }
            let pct: Double = (l["percent"] as? Double)
                ?? (l["percent"] as? Int).map(Double.init) ?? 0
            var reset: Date?
            if let s = l["resets_at"] as? String { reset = isoFrac.date(from: s) ?? iso.date(from: s) }
            scoped.append(ScopedUsageLimit(label: name, percent: pct, resetsAt: reset))
        }

        guard fivePct != nil || weekPct != nil || !scoped.isEmpty else { return nil }
        return UsageSnapshot(fiveHourPercent: fivePct, fiveHourResetsAt: fiveReset,
                             sevenDayPercent: weekPct, sevenDayResetsAt: weekReset,
                             scopedLimits: scoped.isEmpty ? nil : scoped, fetchedAt: now)
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
