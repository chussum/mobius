import SwiftUI
import MobiusCore

struct AccountCardView: View {
    let profile: AccountProfile
    let isActive: Bool
    let isPrimary: Bool
    let autoSwitchOn: Bool
    let usage: UsageSnapshot?
    /// 활성 Codex 계정인데 아직 사용량 데이터가 없을 때(세션 로그 in-band라 codex 턴이 한 번
    /// 돌아야 생긴다) 빈 게이지 대신 안내를 띄운다. 리스트가 판정해 넘긴다.
    var codexAwaitingData: Bool = false
    let now: Date
    /// Desktop 설치 시에만 전달 — 눈에 보이는 ⋯ 메뉴에 "Claude Desktop 연결" 노출
    var onConnectDesktop: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    /// fallback 카드에만 전달 — ⋯ 메뉴/우클릭에서 primary로 승격
    var onSetPrimary: (() -> Void)? = nil
    /// needsReauth/authSuspect 카드에만 전달 — 로그인 플로우 재실행 (같은 계정 로그인 = 토큰 갱신)
    var onReauth: (() -> Void)? = nil
    /// usage 조회가 연속 401로 임계값을 넘긴 계정 — **의심**이지 확정이 아니다(AuthSuspicion).
    /// needsReauth(확정, 빨강)와 다른 문구·색으로 구분해 띄운다.
    var authSuspect: Bool = false

    private let accent = Color(red: 0.35, green: 0.65, blue: 1.0)

    /// 카드 1행이 List에서 차지하는 높이(행 인셋 6pt 포함)의 **초기 추정치** —
    /// AccountListView.poolCards가 첫 프레임에만 쓰고, 이후엔 행별 실측 높이(rowHeights)로
    /// 대체된다. 그래서 폰트/로케일/배지로 실제가 달라져도 잘리지 않는다. 추정이 실측과
    /// 가까울수록 첫 프레임 점프가 없다 (픽셀 실측 2026-07-15: 게이지+Fable 행 123~125,
    /// codex 힌트 행 93, 게이지 없음 행 ~73).
    static func estimatedHeight(hasUsage: Bool, scopedCount: Int = 0,
                                codexHint: Bool = false) -> CGFloat {
        hasUsage ? 110 + CGFloat(scopedCount) * 16 : (codexHint ? 94 : 74)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 상태 인디케이터
            ZStack {
                Circle().stroke(isActive ? accent : Color.secondary.opacity(0.3), lineWidth: 2)
                    .frame(width: 34, height: 34)
                Text(String(profile.nickname.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? accent : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.nickname)
                        .font(.system(size: 13, weight: .semibold))
                    if isPrimary {
                        Text("PRIMARY").font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(accent)
                    }
                    if profile.needsReauth || authSuspect {
                        let confirmed = profile.needsReauth
                        Text(confirmed ? loc("재로그인 필요") : loc("인증 확인 필요"))
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background((confirmed ? Color.red : .orange).opacity(0.15), in: Capsule())
                            .foregroundStyle(confirmed ? Color.red : .orange)
                        if let onReauth {
                            Button(loc("다시 로그인")) { onReauth() }
                                .buttonStyle(.borderless)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                    }
                }
                Text(profile.emailAddress)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                statusLine
                if let usage {
                    gauges(usage).padding(.top, 3)
                } else if codexAwaitingData {
                    Text(loc("codex 사용 후 사용량이 표시돼요"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .padding(.top, 3)
                }
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(accent).font(.system(size: 16))
            }
            if onConnectDesktop != nil || onDelete != nil || onSetPrimary != nil {
                Menu {
                    if profile.needsReauth || authSuspect, let onReauth {
                        Button(loc("다시 로그인"), systemImage: "arrow.clockwise") { onReauth() }
                    }
                    if let onSetPrimary {
                        Button(loc("Primary 계정으로 설정"), systemImage: "star") { onSetPrimary() }
                    }
                    if let onConnectDesktop {
                        // Desktop 연결은 이 계정이 '현재 활성'일 때만 — 캡처는 활성 세션을
                        // 잡으므로, 비활성 계정에서 연결하면 엉뚱한 계정이 저장된다.
                        Button(profile.hasDesktopSnapshot
                               ? loc("Claude Desktop 다시 연결") : loc("Claude Desktop 연결"),
                               systemImage: "macwindow") { onConnectDesktop() }
                            .disabled(!isActive)
                        if !isActive {
                            Text(loc("이 계정으로 전환한 뒤 연결할 수 있어요"))
                        }
                    }
                    if let onDelete {
                        Button(loc("계정 삭제"), systemImage: "trash", role: .destructive) { onDelete() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(isActive ? accent.opacity(0.5) : .clear, lineWidth: 1)))
        .contentShape(Rectangle())
    }

    // 상단 "리셋까지" 카운트다운은 이 풀의 자동 전환이 켜져 있고(autoSwitchOn) 계정이
    // **전반적으로** 소진일 때만 표시한다. usage로 볼 때 5시간·주간엔 여유가 있고 모델 스코프
    // (Fable 등)만 100%면, 계정은 다른 모델로 쓸 수 있으므로 상단 알람을 숨긴다
    // (그 한도는 아래 모델별 게이지가 이미 보여준다). 수동 모드에선 tier 설명으로 대체.
    private var generallyLimited: Bool {
        guard let u = usage else { return true } // usage 모르면 보수적으로 표시
        let five = u.fiveHourPercent ?? 0, week = u.sevenDayPercent ?? 0
        return five >= 100 || week >= 100
    }
    @ViewBuilder private var statusLine: some View {
        if autoSwitchOn, let rl = profile.rateLimit, rl.resetsAt > now, generallyLimited {
            let mins = max(0, Int(rl.resetsAt.timeIntervalSince(now) / 60))
            Label(loc("리셋까지 %d시간 %d분", mins / 60, mins % 60), systemImage: "hourglass")
                .font(.system(size: 10)).foregroundStyle(.orange)
        } else {
            Text(profile.tierDescription)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // MARK: 사용량 게이지 (5시간/주간 + 초기화 남은 시간)

    /// 이 시간을 넘은 스냅샷은 "지금 값"으로 보여주지 않는다(흐리게 + 기준 시각 표기).
    /// 4분 캐시 + 10분 재시도 쿨다운(AppState.usageRefreshRetryCooldown)을 감안한 여유값이라
    /// 정상 동작 중에는 뜨지 않는다.
    /// ★ 실측 2026-07-20: 활성 계정의 usage 조회가 401로 계속 실패하는 동안 게이지가 마지막
    ///   성공 스냅샷(08:54의 "5시간 1%")에 얼어붙어 14시간 내내 정상처럼 보였다. 초기화
    ///   카운트다운만 실시간 계산돼 살아 있는 것처럼 보이는 게 특히 위험했다.
    static let usageStaleAfter: TimeInterval = 15 * 60

    /// 게이지 값의 기준 시각이 오래됐을 때만 문구를 준다(아니면 nil = 표기 없음).
    private func staleAgeText(_ u: UsageSnapshot) -> String? {
        let age = now.timeIntervalSince(u.fetchedAt)
        guard age >= Self.usageStaleAfter else { return nil }
        return agoText(age)
    }

    private func gauges(_ u: UsageSnapshot) -> some View {
        let stale = staleAgeText(u)
        return VStack(alignment: .leading, spacing: 3) {
            if let pct = u.fiveHourPercent {
                gaugeRow(label: loc("5시간"), percent: pct, resetsAt: u.fiveHourResetsAt)
            }
            if let pct = u.sevenDayPercent {
                gaugeRow(label: loc("주간"), percent: pct, resetsAt: u.sevenDayResetsAt)
            }
            // 모델 스코프 주간 한도 (예: Fable) — API가 줄 때만. 제공 종료 시 자동 소멸.
            ForEach(u.scopedLimits ?? [], id: \.label) { s in
                gaugeRow(label: s.label, percent: s.percent, resetsAt: s.resetsAt)
            }
            // 실패인지 단순 미갱신인지는 여기서 단정하지 않는다 — Codex는 "그동안 codex를 안
            // 썼다"는 뜻이기도 하다. 기준 시각만 정직하게 밝히고 판단은 사용자에게 맡긴다.
            if let stale {
                Text(loc("%@ 값", stale))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
            }
        }
        // 얼어붙은 값을 지금 값처럼 보여주지 않기 위한 시각적 강등.
        .opacity(stale == nil ? 1 : 0.5)
    }

    private func gaugeRow(label: String, percent: Double, resetsAt: Date?) -> some View {
        HStack(spacing: 6) {
            // fixedSize로 라벨을 항상 같은 크기로 렌더한다 — minimumScaleFactor를 쓰면
            // 활성 카드(체크마크로 폭이 좁음)에서만 글자가 줄어 카드마다 크기가 달라졌다(실측).
            Text(label)
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
                .frame(width: 38, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(gaugeColor(percent))
                        .frame(width: max(3, geo.size.width * min(percent, 100) / 100))
                }
            }
            // 바가 남는 가로 공간을 모두 채운다 (오른쪽 텍스트는 fixedSize라 자리를 먼저 확보)
            .frame(minWidth: 40, maxWidth: .infinity)
            .frame(height: 5)
            Text("\(Int(percent))%")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(gaugeColor(percent))
                .lineLimit(1).fixedSize()
                .frame(width: 36, alignment: .trailing)
            if let resetsAt, resetsAt > now {
                Text(loc("초기화 %@", remainText(until: resetsAt)))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
            }
        }
    }

    private func gaugeColor(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return accent
        case ..<85: return .orange
        default: return .red
        }
    }

    /// 경과 시간 문구 — remainText("…후")의 과거형 짝.
    private func agoText(_ interval: TimeInterval) -> String {
        let mins = max(0, Int(interval / 60))
        let (d, h, m) = (mins / 1440, (mins % 1440) / 60, mins % 60)
        if d > 0 { return loc("%d일 %d시간 전", d, h) }
        if h > 0 { return loc("%d시간 %d분 전", h, m) }
        return loc("%d분 전", m)
    }

    private func remainText(until date: Date) -> String {
        let mins = max(0, Int(date.timeIntervalSince(now) / 60))
        let (d, h, m) = (mins / 1440, (mins % 1440) / 60, mins % 60)
        if d > 0 { return loc("%d일 %d시간 후", d, h) }
        if h > 0 { return loc("%d시간 %d분 후", h, m) }
        return loc("%d분 후", m)
    }
}
