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

    /// **모델 전용** 주간 한도(`limits[].weekly_scoped`, 예: Fable)의 소진 판정.
    /// 계정 창(5시간/주간)과 **의도적으로 분리**돼 있다 — 계정 자체는 여유인데 특정 모델만
    /// 막힌 상태이므로 `modelScoped: true`로 표시하고, 소비자는 이를 "계정 사용 불가"가
    /// 아니라 "그 모델만 불가"로 다룬다(`AccountProfile.isModelLimited`).
    /// `exhaustionHit`과 같은 규칙으로 **아직 안 지난 리셋 시각**만 인정하고, 그중 가장 늦은 것.
    public func scopedExhaustionHit(now: Date) -> RateLimitHit? {
        let resets = (scopedLimits ?? [])
            .filter { $0.percent >= 100 }
            .compactMap(\.resetsAt)
            .filter { $0 > now }
        guard let resetsAt = resets.max() else { return nil }
        return RateLimitHit(resetsAt: resetsAt, kind: .window, modelScoped: true)
    }

    /// **계정 창**(5시간/주간) 중 100%인 것이 있는가(리셋 시각의 유효성과 무관).
    /// `.inconclusive` 판정용 — "여유 있음"과 "소진인데 리셋 시각을 못 얻음"을 가른다.
    /// ★ 모델 전용 한도는 **일부러 제외한다**: 며칠 100%로 남아 있을 수 있어서, 포함하면
    ///   멀쩡한 계정에 스쳐 온 hit 하나가 영영 "판정 보류"로 남는다.
    public func hasExhaustedAccountWindow() -> Bool {
        (fiveHourPercent ?? 0) >= 100 || (sevenDayPercent ?? 0) >= 100
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

    /// ★ `URLSession.shared`를 쓰면 안 된다 — 공유 세션은 **디스크 URLCache**를 물고 있어
    ///   요청이 직렬화되어 `~/Library/Caches/dev.chussum.mobius/Cache.db`에 저장되고,
    ///   거기에 `Authorization: Bearer <액세스 토큰>` 헤더가 **평문으로 남는다**.
    ///   실측 2026-08-10: `Cache.db-wal`에서 실제 액세스 토큰 13개 발견(파일 0644,
    ///   디렉터리 0755). 그중 1개는 당시 유효한 토큰이었고, 나머지는 회전·전환으로
    ///   밀려난 과거 계정 토큰들이었다.
    ///   키체인은 접근 시 ACL 승인을 요구하지만 `~/Library/Caches`는 TCC 보호 대상이
    ///   아니라, 같은 사용자로 실행되는 아무 프로세스나 승인 없이 읽어간다 —
    ///   앱이 키체인으로 지키던 것을 캐시가 우회로로 흘리는 셈이다.
    ///   → TokenRefresher·CodexUsageFetcher·CodexTokenRefresher와 동일하게
    ///   ephemeral 세션을 쓴다(디스크에 아무것도 안 남음).
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    /// HTTP 전송(주입식) — 기본값은 위 ephemeral 세션. OAuthTokenRefresher.transport와 같은 패턴.
    /// ★ 이 이음매가 있어야 **fetch가 실제로 어느 경로로 나가는지**를 테스트가 관찰할 수 있다.
    ///   `session` 속성만 검사하는 테스트는 호출부가 `URLSession.shared`로 되돌아가도
    ///   (안 쓰이는 속성은 그대로 남으므로) 초록불이라 회귀를 못 잡는다.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public static let defaultTransport: Transport = { try await session.data(for: $0) }

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

    public static func fetch(keychainBlob: Data,
                             transport: Transport = defaultTransport) async throws -> UsageSnapshot? {
        guard let token = accessToken(from: keychainBlob) else { return nil }
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10
        let (data, resp) = try await transport(req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageFetcherError.unauthorized
        }
        guard http.statusCode == 200 else { return nil }
        return parse(data)
    }
}
