import SwiftUI

/// Toss 스타일 필 세그먼트 컨트롤 — 선택된 조각이 캡슐로 미끄러진다.
/// 팝오버(전체/Claude/Codex 탭)와 설정(설치 현황 Claude/Codex 탭)이 공유한다.
struct PillPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let label: String
        var badge: Int?

        init(value: Value, label: String, badge: Int? = nil) {
            self.value = value
            self.label = label
            self.badge = badge
        }
    }

    let options: [Option]
    @Binding var selection: Value
    /// true면 트랙이 가용 폭을 다 쓰고 조각들이 균등 분할된다 (팝오버 탭 바).
    var fillsWidth = false
    @Namespace private var pillSpace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                segment(opt)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func segment(_ opt: Option) -> some View {
        let selected = selection == opt.value
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                selection = opt.value
            }
        } label: {
            HStack(spacing: 4) {
                Text(opt.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                if let n = opt.badge, n > 0 {
                    Text("\(n)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected
                            ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background {
                if selected {
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "pill", in: pillSpace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
    }
}
