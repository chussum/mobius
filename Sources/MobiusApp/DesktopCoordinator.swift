import AppKit
import MobiusCore

enum DesktopCoordinatorError: Error, LocalizedError {
    case switchInProgress
    var errorDescription: String? {
        switch self {
        case .switchInProgress: return "이전 Desktop 전환이 아직 진행 중입니다."
        }
    }
}

/// Desktop 앱의 종료 → 스왑 → 재실행 시퀀스.
/// 수동 전환(desktopSyncEnabled) 및 자동 전환(desktopAutoSwitchEnabled 켬)에서 호출된다.
@MainActor
final class DesktopCoordinator {
    static let bundleID = "com.anthropic.claudefordesktop" // Task 16 Step 1 실측 확인 (2026-07-10)
    let switcher: DesktopSwitcher
    /// 전환 직렬화 — 진행 중 재진입은 드롭(throw). 중첩 실행 시 capture/restore가
    /// 서로의 중간 상태를 스냅샷에 담는 교차 오염을 원천 차단한다.
    private var isSwitching = false

    init(switcher: DesktopSwitcher) { self.switcher = switcher }

    private var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    /// from(현재 활성)의 상태를 백업하고 to의 스냅샷으로 교체. Desktop이 켜져 있었으면 재실행.
    func switchDesktop(from: UUID, to: UUID) async throws {
        guard switcher.isDesktopInstalled, switcher.hasSnapshot(for: to) else { return }
        guard !isSwitching else { throw DesktopCoordinatorError.switchInProgress }
        isSwitching = true
        defer { isSwitching = false }

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

        // 스왑이 실패해도 원래 켜져 있었으면 반드시 재실행한다 (사용자를 앱 없는 상태로 방치 금지)
        var swapError: Error?
        do {
            try switcher.capture(for: from)   // 현재 상태 되저장
            try switcher.restore(for: to)
        } catch {
            swapError = error
        }

        if wasRunning {
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.bundleID)
            if let url {
                try? await NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        if let swapError { throw swapError }
    }
}
