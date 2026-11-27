import Foundation

extension UsageSnapshot {
    /// CLI `list --usage` 표시용 — 계정 창(5시간, 주간)의 사용률과 리셋 시각(남은 시간 + 절대 시각).
    /// 창 이름은 앱 카드(`AccountCardView.gauges`의 "5시간"/"주간")와 맞춘다.
    /// 모델 전용 한도(`scopedLimits`)는 일부러 싣지 않는다 — 계정 창과 구분되는 별개 한도다.
    public func summaryLines(now: Date, timeZone: TimeZone = .current) -> [String] {
        [Self.summaryRow("5시간", fiveHourPercent, fiveHourResetsAt, now: now, timeZone: timeZone),
         Self.summaryRow("주간", sevenDayPercent, sevenDayResetsAt, now: now, timeZone: timeZone)]
    }

    static func summaryRow(_ label: String, _ percent: Double?, _ resetsAt: Date?,
                           now: Date, timeZone: TimeZone) -> String {
        // 내림한다 - 반올림하면 99.6%가 "100%"로 보여 아직 남은 창이 소진된 것처럼 읽힌다.
        let pct = percent.map { "\(Int($0.rounded(.down)))%" } ?? "?"
        return "\(label) \(pct)  리셋 \(resetText(resetsAt, now: now, timeZone: timeZone))"
    }

    /// "4시간 22분 후 (18:30)" / "5일 1시간 52분 후 (10/28 16:00)". 시각이 없거나 이미 지났으면 "-".
    /// 리셋이 `now`와 같은 날(그 시간대 달력 기준)이 아니면 날짜를 붙인다 - 23:00에 본 "03:00"이 오늘인지 내일인지 갈리게.
    /// ★ 일 단위여도 분까지 적는다 — 절대 시각과 대조할 때 어긋나 보이지 않게.
    static func resetText(_ date: Date?, now: Date, timeZone: TimeZone) -> String {
        guard let date, date > now else { return "-" }
        let mins = Int(date.timeIntervalSince(now) / 60)
        let days = mins / 1440, rem = mins % 1440
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        f.dateFormat = cal.isDate(date, inSameDayAs: now) ? "HH:mm" : "MM/dd HH:mm"
        let remaining = "\(rem / 60)시간 \(rem % 60)분"
        return "\(days > 0 ? "\(days)일 " : "")\(remaining) 후 (\(f.string(from: date)))"
    }
}
