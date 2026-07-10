import AppKit
import MobiusCore

/// Desktop 앱의 종료 → 스왑 → 재실행 시퀀스.
/// 수동 전환(desktopSyncEnabled) 및 자동 전환(desktopAutoSwitchEnabled 켬)에서 호출된다.
@MainActor
final class DesktopCoordinator {
    static let bundleID = "com.anthropic.claudefordesktop" // Task 16 Step 1 실측 확인 (2026-07-10)
    let switcher: DesktopSwitcher

    init(switcher: DesktopSwitcher) { self.switcher = switcher }

    private var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    /// from(현재 활성)의 상태를 백업하고 to의 스냅샷으로 교체. Desktop이 켜져 있었으면 재실행.
    func switchDesktop(from: UUID, to: UUID) async throws {
        guard switcher.isDesktopInstalled, switcher.hasSnapshot(for: to) else { return }
        let wasRunning = runningApp != nil

        if let app = runningApp {
            app.terminate()
            for _ in 0..<50 { // 최대 10초 대기
                try await Task.sleep(for: .milliseconds(200))
                if app.isTerminated { break }
            }
            if !app.isTerminated { app.forceTerminate() }
            try await Task.sleep(for: .milliseconds(500)) // 파일 핸들 정리 여유
        }

        try switcher.capture(for: from)   // 현재 상태 되저장
        try switcher.restore(for: to)

        if wasRunning {
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.bundleID)
            if let url {
                try await NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
}
