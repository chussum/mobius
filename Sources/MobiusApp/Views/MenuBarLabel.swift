import SwiftUI
import ServiceManagement

struct MenuBarLabel: View {
    let status: MenuStatus
    @Environment(\.openSettings) private var openSettings
    @AppStorage("hasCompletedFirstLaunch") private var hasCompletedFirstLaunch = false

    var dotColor: Color? {
        switch status {
        case .primaryActive: return nil       // 기본 상태는 점 없음(깔끔)
        case .fallbackActive: return .orange
        case .allExhausted: return .red
        case .unknown: return .gray
        }
    }

    var body: some View {
        // 메뉴바는 템플릿 이미지가 관례 — ∞ 심볼 + 상태 점
        Image(systemName: dotColor == nil ? "infinity" : "infinity.circle.fill")
            .symbolRenderingMode(dotColor == nil ? .monochrome : .palette)
            .foregroundStyle(dotColor ?? .primary, .primary)
            .task {
                // 최초 실행 1회만 설정창 자동 오픈 — 온보딩 진입점.
                // 단, 로그인 자동 시작이 켜져 있으면(=이미 설정을 마친 사용자,
                // 로그인 시점 실행일 수 있음) 조용히 메뉴바에만 표시한다.
                guard !hasCompletedFirstLaunch,
                      SMAppService.mainApp.status != .enabled else { return }
                hasCompletedFirstLaunch = true
                try? await Task.sleep(for: .milliseconds(400)) // 상태 아이템 안착 대기
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
    }
}
