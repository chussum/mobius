import SwiftUI
import MobiusCore

/// "Desktop 연결" 가이드 패널. 팝오버 위에 오버레이로 뜬다 —
/// MenuBarExtra 창은 포커스를 잃으면 닫히므로(사용자가 Desktop으로 전환해야 하는 플로우)
/// 시스템 시트 대신 상태 기반 오버레이를 쓴다. 팝오버를 다시 열면 진행 상황이 이어진다.
struct DesktopCaptureSheet: View {
    @EnvironmentObject var state: AppState

    private let accent = Color(red: 0.35, green: 0.65, blue: 1.0)

    private enum RowState { case pending, active, done }

    var body: some View {
        if let session = state.desktopCapture {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                    Text("Desktop 연결")
                        .font(.system(size: 13, weight: .semibold))
                    Text(session.nickname)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 10) {
                    stepRow(1, "Claude Desktop을 로그아웃하고 다시 엽니다", launchState(session.step))
                    stepRow(2, "\(session.nickname) 계정으로 로그인하세요", loginState(session.step))
                    stepRow(3, "로그인이 감지되면 자동으로 저장됩니다", saveState(session.step))
                }

                statusLine(session.step)
                buttons(session.step)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(accent.opacity(0.35), lineWidth: 1)))
            .padding(10)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    // MARK: 단계 상태 매핑

    private func launchState(_ step: AppState.DesktopCaptureSession.Step) -> RowState {
        step == .launching ? .active : .done
    }

    private func loginState(_ step: AppState.DesktopCaptureSession.Step) -> RowState {
        switch step {
        case .launching: return .pending
        case .waitingLogin, .failed: return .active
        case .saving, .done: return .done
        }
    }

    private func saveState(_ step: AppState.DesktopCaptureSession.Step) -> RowState {
        switch step {
        case .saving: return .active
        case .done: return .done
        default: return .pending
        }
    }

    // MARK: 구성 요소

    private func stepRow(_ n: Int, _ text: String, _ rowState: RowState) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(rowState == .pending ? Color.secondary.opacity(0.3) : accent,
                            lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                switch rowState {
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(accent)
                case .active:
                    Circle().fill(accent).frame(width: 7, height: 7)
                case .pending:
                    Text("\(n)").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(text)
                .font(.system(size: 12,
                              weight: rowState == .active ? .semibold : .regular))
                .foregroundStyle(rowState == .pending ? .secondary : .primary)
            if rowState == .active {
                ProgressView().controlSize(.mini)
            }
        }
    }

    @ViewBuilder private func statusLine(_ step: AppState.DesktopCaptureSession.Step) -> some View {
        switch step {
        case .failed(let message):
            Text(message).font(.system(size: 10)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .done:
            Label("저장 완료 — 이제 전환 시 Desktop도 함께 전환됩니다.",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 10)).foregroundStyle(accent)
        case .waitingLogin:
            Text("Claude Desktop이 로그아웃되고 다시 열렸습니다. 그 창에서 **\(session?.nickname ?? "이 계정")** 계정으로 로그인하면 자동으로 저장됩니다.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private var session: AppState.DesktopCaptureSession? { state.desktopCapture }

    @ViewBuilder private func buttons(_ step: AppState.DesktopCaptureSession.Step) -> some View {
        HStack {
            switch step {
            case .done:
                Spacer()
                Button("닫기") { state.endDesktopCapture() }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.small)
            case .failed:
                Spacer()
                Button("닫기") { state.endDesktopCapture() }
                    .buttonStyle(.bordered).controlSize(.small)
            case .launching, .saving, .waitingLogin:
                // 취소 시 강제 로그아웃했던 원래 세션을 되돌린다
                Button("취소") { state.endDesktopCapture() }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer()
            }
        }
    }
}
