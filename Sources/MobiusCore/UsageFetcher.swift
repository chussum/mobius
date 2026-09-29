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

    /// 모델 전용 한도가 100%인데 **쓸 수 있는 리셋 시각이 없는가**(누락/이미 지남).
    ///
    /// ★ 실측 근거(이슈 #19, @Phantomn 2026-08-16): 라이브 응답의 `weekly_scoped` 항목은
    ///   `resets_at: null`로 온다 — 그 계정은 `percent: 0`이었지만 **필드 자체가 옵셔널**임이
    ///   확인됐다. 그러면 `scopedExhaustionHit`의 `compactMap(\.resetsAt)`이 조용히 떨어뜨려
    ///   "여유 있음"과 구분되지 않는다(= 100%로 막힌 사용자의 hit이 버려지고 백오프까지 걸린다).
    ///   계정 창에 `hasExhaustedAccountWindow`로 만들어 둔 `.inconclusive` 구분을 여기에도 둔다.
    public func hasUnresolvableScopedLimit(now: Date) -> Bool {
        (scopedLimits ?? []).contains { limit in
            guard limit.percent >= 100 else { return false }
            guard let reset = limit.resetsAt else { return true }   // 시각 없음
            return reset <= now                                      // 이미 지남
        }
    }

    /// 이 계정의 **모델 전용 창**이 지금 막혀 있는가 — 자동 전환 후보에서 뺄지 판정한다(실패 기록 22).
    ///
    /// `scopedExhaustionHit`과 갈리는 지점은 **리셋 시각이 없는 100%**다. 그쪽은 `RateLimitHit`을
    /// 만들어야 해서 시각이 반드시 필요하지만, 여기서는 "그 모델을 지금 쓸 수 있는가"만 물으므로
    /// 시각을 몰라도 막힌 것으로 본다 — `weekly_scoped`의 `resets_at`은 실제로 null로 온다
    /// (실패 기록 21). 그때도 카드 게이지는 100%를 그대로 그리므로(`AccountCardView.gaugeRow`),
    /// 시각이 없다고 후보로 두면 화면이 보여주는 것과 전환 결정이 어긋난다.
    ///
    /// 리셋이 **이미 지난** 항목은 제외한다 — 낡은 캐시가 계정을 무기한 묶지 않게.
    /// (`hasUnresolvableScopedLimit`을 그대로 쓰면 안 되는 이유가 이것이다. 그쪽은 "판정 보류"를
    /// 가리는 술어라 지난 창도 true다.)
    public func modelWindowBlocked(now: Date) -> Bool {
        (scopedLimits ?? []).contains { limit in
            guard limit.percent >= 100 else { return false }
            guard let reset = limit.resetsAt else { return true }   // 시각을 몰라도 100%면 막힘
            return reset > now                                      // 지난 창은 이미 풀렸다
        }
    }

    /// **계정 창**(5시간/주간) 중 100%인 것이 있는가(리셋 시각의 유효성과 무관).
    /// `.inconclusive` 판정용 — "여유 있음"과 "소진인데 리셋 시각을 못 얻음"을 가른다.
    /// ★ 모델 전용 한도는 **일부러 제외한다**: 며칠 100%로 남아 있을 수 있어서, 포함하면
    ///   멀쩡한 계정에 스쳐 온 hit 하나가 영영 "판정 보류"로 남는다.
    public func hasExhaustedAccountWindow() -> Bool {
        (fiveHourPercent ?? 0) >= 100 || (sevenDayPercent ?? 0) >= 100
    }

    /// 계정 창이 한도에 **바짝 붙어** 있는가 — "아직 100%는 아니지만 곧"인 상태.
    /// 로그가 소진을 말하는데 API가 살짝 못 따라온 경우를 버리지 않고 보류하는 데 쓴다.
    public func hasNearLimitAccountWindow(threshold: Double) -> Bool {
        (fiveHourPercent ?? 0) >= threshold || (sevenDayPercent ?? 0) >= threshold
    }
}

public enum UsageFetcherError: Error, Equatable {
    /// 401/403 — 토큰이 거부됨. 저장된 expiresAt이 아직 유효한데 이 에러면
    /// 진짜 재로그인 필요(토큰 폐기)로 판단할 수 있다 (만료 토큰의 401은 오탐).
    case unauthorized
    /// 429 — 이 토큰의 사용량 조회가 요청 제한에 걸렸다. `retryAfter`는 응답의 `Retry-After`(초),
    /// 없으면 nil. 토큰 문제가 아니므로 재인증 판정에 쓰지 않는다.
    /// ★ 실측 2026-09-24: 같은 계정을 Mobius·ccstatusline·claude(`/usage`, 한도 도달 시 조회)가 함께
    ///   부르다 `rate_limit_error`를 받았고, `Retry-After`는 3600초까지 왔다. 예전엔 200이 아니면
    ///   조용히 nil이라 게이지가 한 시간 넘게 얼어붙은 채 팝오버를 열 때마다 다시 호출했다.
    case rateLimited(retryAfter: TimeInterval?)
}

/// 사용량 조회 한 번의 결과(실패 기록 25). 앱의 조회는 모두 `UsageFetcher.fetchOutcome`을 거친다.
///
/// 결과의 **종류**를 값으로 돌려주는 이유: 예전 호출자는 스냅샷이 nil이면 "방금 429였나"를
/// 대기 표(`UsageRateLimitBackoff.isBlocked`)를 다시 읽어 거꾸로 추측했다. 그 추측은 대기 하한
/// (`minWait`)이 충분히 길고 다른 경로가 기록을 지우지 않는다는 가정에 기대므로, 가정이 깨지면
/// 조용히 틀어진다(리뷰 지적).
public enum UsageFetchOutcome: Equatable, Sendable {
    /// 200 — 스냅샷을 얻었다.
    case ok(UsageSnapshot)
    /// 429 — 이 토큰의 조회가 요청 제한에 걸렸다. `retryAfter`는 `Retry-After`(초), 없으면 nil.
    case rateLimited(retryAfter: TimeInterval?)
    /// 401/403 — 토큰이 거부됐다. 재인증 판정은 호출자가 자기 조건으로 한다.
    case unauthorized
    /// 그 밖의 실패 — 네트워크 오류·타임아웃·5xx·응답 해석 실패·토큰 없음.
    case failed

    public var snapshot: UsageSnapshot? {
        if case .ok(let snap) = self { return snap }
        return nil
    }

    /// 임계값 폴의 서킷 브레이커(`UsagePollBreaker`)가 이 결과를 연속 실패로 세는가.
    /// 429는 세지 않는다 — 브레이커는 네트워크 이상을 위한 것이고, 제한은 서버가 준 시각에
    /// 스스로 풀린다. 401/403은 이 결과값을 도입하기 전과 같이 센다(예전엔 `try?`가 nil로 바꿔
    /// 다른 실패와 함께 셌다).
    public var countsAsPollFailure: Bool {
        switch self {
        case .ok, .rateLimited: return false
        case .unauthorized, .failed: return true
        }
    }
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

    /// `fetch`의 결과를 종류별 값으로 돌려준다 — 던지지 않는다(`UsageFetchOutcome` 참조).
    public static func fetchOutcome(keychainBlob: Data,
                                    transport: Transport = defaultTransport) async -> UsageFetchOutcome {
        do {
            guard let snap = try await fetch(keychainBlob: keychainBlob, transport: transport) else {
                return .failed
            }
            return .ok(snap)
        } catch UsageFetcherError.rateLimited(let retryAfter) {
            return .rateLimited(retryAfter: retryAfter)
        } catch UsageFetcherError.unauthorized {
            return .unauthorized
        } catch {
            return .failed
        }
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
        if http.statusCode == 429 {
            throw UsageFetcherError.rateLimited(
                retryAfter: retryAfterSeconds(http.value(forHTTPHeaderField: "Retry-After"), now: Date()))
        }
        guard http.statusCode == 200 else { return nil }
        return parse(data)
    }

    /// `Retry-After` 헤더 → 기다릴 초. 정수 초와 HTTP 날짜(RFC 9110 IMF-fixdate) 둘 다 받는다.
    /// 해석할 수 없거나 음수면 nil — 호출자가 기본 대기 시간을 쓴다.
    static func retryAfterSeconds(_ header: String?, now: Date) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let secs = TimeInterval(raw) { return secs >= 0 ? secs : nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
