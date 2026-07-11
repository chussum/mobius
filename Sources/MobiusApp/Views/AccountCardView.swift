import SwiftUI
import MobiusCore

struct AccountCardView: View {
    let profile: AccountProfile
    let isActive: Bool
    let isPrimary: Bool
    let autoSwitchOn: Bool
    let usage: UsageSnapshot?
    let now: Date
    /// Desktop 설치 시에만 전달 — 눈에 보이는 ⋯ 메뉴에 "Claude Desktop 연결" 노출
    var onConnectDesktop: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    /// fallback 카드에만 전달 — ⋯ 메뉴/우클릭에서 primary로 승격
    var onSetPrimary: (() -> Void)? = nil
    /// needsReauth 카드에만 전달 — 로그인 플로우 재실행 (같은 계정 로그인 = 토큰 갱신)
    var onReauth: (() -> Void)? = nil

    private let accent = Color(red: 0.35, green: 0.65, blue: 1.0)

    /// 카드 1행이 List에서 차지하는 높이(행 인셋 6pt 포함) — 넉넉히 잡아 내부 스크롤을 없앤다.
    /// AccountListView의 List 높이 계산과 공유. 과소추정하면 내부 스크롤이 생기므로 살짝 크게.
    static func estimatedHeight(hasUsage: Bool) -> CGFloat { hasUsage ? 116 : 74 }

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
                    if profile.needsReauth {
                        Text(loc("재로그인 필요")).font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
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
                }
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(accent).font(.system(size: 16))
            }
            if onConnectDesktop != nil || onDelete != nil || onSetPrimary != nil {
                Menu {
                    if profile.needsReauth, let onReauth {
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

    // 리셋 카운트다운은 자동 Fallback이 켜져 있을 때만 표시.
    // 수동 모드에서는 한도 추적이 UX에 의미가 없으므로 tier 설명으로 대체한다.
    @ViewBuilder private var statusLine: some View {
        if autoSwitchOn, let rl = profile.rateLimit, rl.resetsAt > now {
            let mins = max(0, Int(rl.resetsAt.timeIntervalSince(now) / 60))
            Label(loc("리셋까지 %d시간 %d분", mins / 60, mins % 60), systemImage: "hourglass")
                .font(.system(size: 10)).foregroundStyle(.orange)
        } else {
            Text(profile.tierDescription)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // MARK: 사용량 게이지 (5시간/주간 + 초기화 남은 시간)

    private func gauges(_ u: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let pct = u.fiveHourPercent {
                gaugeRow(label: loc("5시간"), percent: pct, resetsAt: u.fiveHourResetsAt)
            }
            if let pct = u.sevenDayPercent {
                gaugeRow(label: loc("주간"), percent: pct, resetsAt: u.sevenDayResetsAt)
            }
        }
    }

    private func gaugeRow(label: String, percent: Double, resetsAt: Date?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(gaugeColor(percent))
                        .frame(width: max(3, geo.size.width * min(percent, 100) / 100))
                }
            }
            // 바는 유연하게 — 공간이 부족하면 텍스트 대신 바가 줄어든다
            .frame(minWidth: 36, maxWidth: 78)
            .frame(height: 4)
            Text("\(Int(percent))%")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(gaugeColor(percent))
                .frame(width: 26, alignment: .trailing)
            if let resetsAt, resetsAt > now {
                Text(loc("초기화 %@", remainText(until: resetsAt)))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize().layoutPriority(1) // 절대 잘리지 않게 — 바가 대신 줄어든다
            }
            Spacer(minLength: 0)
        }
    }

    private func gaugeColor(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return accent
        case ..<85: return .orange
        default: return .red
        }
    }

    private func remainText(until date: Date) -> String {
        let mins = max(0, Int(date.timeIntervalSince(now) / 60))
        let (d, h, m) = (mins / 1440, (mins % 1440) / 60, mins % 60)
        if d > 0 { return loc("%d일 %d시간 후", d, h) }
        if h > 0 { return loc("%d시간 %d분 후", h, m) }
        return loc("%d분 후", m)
    }
}
