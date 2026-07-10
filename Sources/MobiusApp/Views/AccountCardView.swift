import SwiftUI
import MobiusCore

struct AccountCardView: View {
    let profile: AccountProfile
    let isActive: Bool
    let isPrimary: Bool
    let autoSwitchOn: Bool
    let now: Date

    private let accent = Color(red: 0.35, green: 0.65, blue: 1.0)

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
                        Text("재로그인 필요").font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
                Text(profile.emailAddress)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                statusLine
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(accent).font(.system(size: 16))
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
            Label("리셋까지 \(mins / 60)시간 \(mins % 60)분", systemImage: "hourglass")
                .font(.system(size: 10)).foregroundStyle(.orange)
        } else {
            Text(profile.tierDescription)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
