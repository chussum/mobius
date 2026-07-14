import Foundation

/// 세션 로그에서 발견된 "이 계정의" 사용 한도 이벤트.
public struct RateLimitHit: Equatable, Sendable {
    /// 이벤트가 가리키는 한도의 종류.
    /// - window: 5시간/주간 창 소진 — 그대로 소진 기록 대상.
    /// - monthlySpend: extra usage 크레딧의 월간 지출 한도(P3) — 창 소진이 아니며
    ///   플랜 창이 멀쩡해도 뜬다(2026-07-13 실측: 이벤트 후에도 세션 정상 동작).
    ///   단, 창 소진과 겹치면 이 메시지가 우선 표시돼 창 소진을 가릴 수 있으므로,
    ///   호출측은 기록 대신 usage로 5h/주간 현황을 교차 확인해 판단한다.
    public enum Kind: Equatable, Sendable { case window, monthlySpend }

    /// 리셋 시각. 시각을 못 읽는 창 소진 변형(P5)은 nil —
    /// 호출측(AppState/CLI)이 보수적 폴백(예: now+24h)을 적용한다.
    public var resetsAt: Date?
    public var kind: Kind
    /// 모델 전용 한도(월간 지출 = 프리미엄 모델 한도)인가. 계정 자체 한도(세션/주간)와 구분.
    /// (교차 확인 없이 직접 기록하는 경로에서 pin/알람숨김 규칙을 유지하기 위해 보존.)
    public var modelScoped: Bool

    public init(resetsAt: Date?, kind: Kind = .window, modelScoped: Bool = false) {
        self.resetsAt = resetsAt
        self.kind = kind
        self.modelScoped = modelScoped
    }

    /// 리셋 시각이 없는 이벤트(월간 지출 한도 등)의 보수적 폴백: now + 24시간.
    /// 엔진·호출자(AppState/CLI)가 한도 기록 시 공통으로 사용한다.
    public func effectiveResetsAt(now: Date) -> Date {
        resetsAt ?? now.addingTimeInterval(24 * 3600)
    }
}

/// 세션 로그(JSONL) 한 줄에서 rate-limit 이벤트를 찾는다.
///
/// 실측 근거: docs/spike/rate-limit-format.md §3.
/// 1. 라인을 JSON으로 디코드 (실패 시 스킵).
/// 2. `error == "rate_limit"` (방어적으로 `isApiErrorMessage==true && apiErrorStatus==429`도 허용)
///    인 라인만 후보. 레거시 pipe-epoch(P4)만 예외적으로 구조화 필드 없이 인정.
/// 3. `message.content[].text`를 이어붙여 패턴 P1~P5로 분류.
///    **`not your usage limit` 포함 시 반드시 제외** — 실측 69%가 서버측 제한이라
///    이 규칙이 없으면 계정 한도가 아닌 이벤트로 오전환이 발생한다.
/// 4. 리셋 시각 텍스트는 괄호 안 IANA TZ 기준으로 해석하고, 라인의 `timestamp`와 비교해
///    이미 지난 시각이면 익일(세션)/익년(주간)으로 굴린다.
public enum RateLimitParser {

    // P1/P5 시각형: "resets 7:30pm (Asia/Seoul)", "resets at 8am (Asia/Seoul)"
    static let timeOnly = try! NSRegularExpression(
        pattern: #"resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
        options: [.caseInsensitive])
    // P2/P5 날짜형: "resets Jul 13 at 8am (Asia/Seoul)"
    static let dateAndTime = try! NSRegularExpression(
        pattern: #"resets?\s+(?:at\s+)?([A-Za-z]{3})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#,
        options: [.caseInsensitive])
    // P3: 월간 지출 한도 — 리셋 시각 없음
    static let monthlySpend = try! NSRegularExpression(
        pattern: #"hit your monthly spend limit"#, options: [.caseInsensitive])
    // P4: 레거시 "usage limit reached|<epoch초|epoch밀리초>"
    static let pipeEpoch = try! NSRegularExpression(
        pattern: #"usage limit reached\|(\d{10,13})"#, options: [.caseInsensitive])
    // P5: 미래 문구 변형 대비 — 계정 한도 언급 + reset 언급이면 시각 없이도 이벤트로 인정
    static let lenientLimit = try! NSRegularExpression(
        pattern: #"hit your (?:usage|session|weekly)\s+limit\b.*\bresets?\b"#,
        options: [.caseInsensitive])

    static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain = ISO8601DateFormatter()

    /// - Parameters:
    ///   - line: 세션 로그 한 줄 (JSON 객체 기대).
    ///   - now: 라인에 `timestamp`가 없을 때의 기준 시각 (sanity 검사·시각 굴림용).
    public static func parse(line: String, now: Date = Date()) -> RateLimitHit? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let text = eventText(from: obj)
        guard !text.isEmpty else { return nil }

        // 제외 규칙 — 서버측 rate limit은 계정 한도가 아니다 (스파이크 §3, 최우선)
        if text.range(of: "not your usage limit", options: .caseInsensitive) != nil { return nil }

        // 시각 굴림·sanity의 기준은 라인 자신의 timestamp (없으면 now)
        let reference = timestamp(from: obj) ?? now

        guard isRateLimitCandidate(obj) else {
            // 구조화 필드가 없으면 레거시 pipe-epoch만 인정 (P4 하위호환)
            return legacyEpochHit(in: text, reference: reference)
        }

        // P3: 월간 지출 한도 — 창 소진이 아님(extra usage 크레딧 월 한도, 플랜 창 여유여도
        // 발생: 2026-07-13 실측). kind로 구분해 호출측(AppState)이 usage로 5h/주간을 교차
        // 확인한다. modelScoped=true도 유지 — 교차 확인 없이 직접 기록하는 경로(CLI 등)에서
        // upstream의 pin/알람숨김 규칙이 계속 동작하도록.
        if firstMatch(monthlySpend, in: text) != nil {
            return RateLimitHit(resetsAt: nil, kind: .monthlySpend, modelScoped: true)
        }
        // P2: 날짜 + 시각 (주간 한도)
        if let m = firstMatch(dateAndTime, in: text),
           let date = resolve(monthAbbr: capture(m, 1, in: text), day: capture(m, 2, in: text),
                              hour: capture(m, 3, in: text), minute: capture(m, 4, in: text),
                              meridiem: capture(m, 5, in: text), tzName: capture(m, 6, in: text),
                              reference: reference) {
            return RateLimitHit(resetsAt: date)
        }
        // P1: 시각만 (세션 한도)
        if let m = firstMatch(timeOnly, in: text),
           let date = resolve(monthAbbr: nil, day: nil,
                              hour: capture(m, 1, in: text), minute: capture(m, 2, in: text),
                              meridiem: capture(m, 3, in: text), tzName: capture(m, 4, in: text),
                              reference: reference) {
            return RateLimitHit(resetsAt: date)
        }
        // P4: 레거시 epoch
        if let hit = legacyEpochHit(in: text, reference: reference) { return hit }
        // P5: 계정 한도임은 확실하지만 시각 표기를 못 읽는 미래 변형 → 시각 없이 알림
        if firstMatch(lenientLimit, in: text) != nil { return RateLimitHit(resetsAt: nil) }
        return nil
    }

    // MARK: - JSON 필드 추출

    static func isRateLimitCandidate(_ obj: [String: Any]) -> Bool {
        if (obj["error"] as? String) == "rate_limit" { return true }
        return (obj["isApiErrorMessage"] as? Bool) == true
            && (obj["apiErrorStatus"] as? Int) == 429
    }

    /// message.content[].text 이어붙임. 없으면 최상위 "text" (레거시/축약 라인 대비).
    static func eventText(from obj: [String: Any]) -> String {
        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            let joined = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !joined.isEmpty { return joined }
        }
        return obj["text"] as? String ?? ""
    }

    static func timestamp(from obj: [String: Any]) -> Date? {
        guard let s = obj["timestamp"] as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: - 리셋 시각 계산

    /// 시각(+선택적 날짜)을 IANA TZ 기준으로 Date로 변환.
    /// 날짜가 없으면 reference 당일, 이미 지났으면 익일. 날짜가 있으면 reference 연도, 과거면 익년.
    static func resolve(monthAbbr: String?, day: String?, hour: String?, minute: String?,
                        meridiem: String?, tzName: String?, reference: Date) -> Date? {
        guard let hourText = hour, let hour12 = Int(hourText), (1...12).contains(hour12),
              let meridiem = meridiem?.lowercased(),
              let tzName, let tz = TimeZone(identifier: tzName)
        else { return nil }
        var hour24 = hour12 % 12
        if meridiem == "pm" { hour24 += 12 }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var comps = cal.dateComponents([.year, .month, .day], from: reference)
        comps.hour = hour24
        comps.minute = minute.flatMap { Int($0) } ?? 0
        comps.second = 0

        if let monthAbbr, let dayText = day {
            guard let month = months[monthAbbr.lowercased()], let dayNum = Int(dayText)
            else { return nil }
            comps.month = month
            comps.day = dayNum
            guard var date = cal.date(from: comps) else { return nil }
            if date < reference { // 이미 지난 날짜 → 익년
                date = cal.date(byAdding: .year, value: 1, to: date) ?? date
            }
            return date
        }
        guard var date = cal.date(from: comps) else { return nil }
        if date <= reference { // 이미 지난 시각 → 익일
            date = cal.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    /// P4: "usage limit reached|<epoch>". sanity: reference 기준 과거 1일 ~ 미래 7일.
    static func legacyEpochHit(in text: String, reference: Date) -> RateLimitHit? {
        guard let m = firstMatch(pipeEpoch, in: text),
              let raw = capture(m, 1, in: text), var epoch = TimeInterval(raw)
        else { return nil }
        if raw.count == 13 { epoch /= 1000 } // 밀리초 표기
        let date = Date(timeIntervalSince1970: epoch)
        guard date > reference.addingTimeInterval(-86_400),
              date < reference.addingTimeInterval(7 * 86_400)
        else { return nil }
        return RateLimitHit(resetsAt: date)
    }

    // MARK: - 정규식 헬퍼

    static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }

    static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text)
        else { return nil }
        return String(text[range])
    }
}
