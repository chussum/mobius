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
    /// needsReauth 카드에만 전달 — 로그인 플로우 재실행 (같은 계정 로그인 = 토큰 갱신)
    var onReauth: (() -> Void)? = nil

    private let accent = Color(red: 0.35, green: 0.65, blue: 1.0)

    /// 카드 1행이 List에서 차지하는 높이(행 인셋 6pt 포함) — 넉넉히 잡아 내부 스크롤을 없앤다.
    /// AccountListView의 List 높이 계산과 공유. 과소추정하면 내부 스크롤이 생기므로 살짝 크게.
    /// 게이지 없으면 74. 있으면 기본 5시간+주간 2줄(116)에 모델 스코프 한도(Fable 등)
    /// 줄당 +15를 더한다 — 리스트 높이 계산이 실제 카드 높이를 따라가야 스크롤이 안 생긴다.
    static func estimatedHeight(hasUsage: Bool, scopedCount: Int = 0,
                                codexHint: Bool = false) -> CGFloat {
        // codexHint 90은 실제보다 살짝 작아 List에 스크롤바가 생겼다(실측) → 94로 보정.
        hasUsage ? 122 + CGFloat(scopedCount) * 17 : (codexHint ? 94 : 74)
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

    private func gauges(_ u: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
        }
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

    private func remainText(until date: Date) -> String {
        let mins = max(0, Int(date.timeIntervalSince(now) / 60))
        let (d, h, m) = (mins / 1440, (mins % 1440) / 60, mins % 60)
        if d > 0 { return loc("%d일 %d시간 후", d, h) }
        if h > 0 { return loc("%d시간 %d분 후", h, m) }
        return loc("%d분 후", m)
    }
}
