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
    private var runningApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
    }

    var isRunning: Bool { runningApp != nil }

    /// Desktop을 **완전히** 종료하고 모든 인스턴스가 사라질 때까지 대기한다.
    /// (Electron은 헬퍼 프로세스가 여럿 — 하나만 isTerminated여도 다른 게 config.json/신원 파일을
    /// 붙잡고 있으면 이후 로그아웃(파일 제거)이 반영되지 않아 이전 계정으로 되살아난다.
    /// 그래서 bundleID로 실행 중인 게 0이 될 때까지 확인하고, 안 죽으면 forceTerminate.)
    func terminateAndWait() async {
        guard !runningApps.isEmpty else { return }
        for app in runningApps { app.terminate() }
        for _ in 0..<50 {                     // graceful 최대 10초
            try? await Task.sleep(for: .milliseconds(200))
            if runningApps.isEmpty { break }
        }
        for app in runningApps { app.forceTerminate() }
        for _ in 0..<25 {                     // force 최대 5초
            try? await Task.sleep(for: .milliseconds(200))
            if runningApps.isEmpty { break }
        }
        try? await Task.sleep(for: .milliseconds(900)) // 파일 핸들/leveldb 플러시 정리 여유
    }

    /// Desktop 실행(이미 실행 중이면 앞으로).
    func launch() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID)
        else { return }
        _ = try? await NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration())
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
            // from은 '이미 연결(스냅샷)된 계정'일 때만 되저장한다 —
            // 스냅샷 없는 계정은 사용자가 명시적으로 연결한 적이 없으므로 자동 생성하지 않는다.
            if switcher.hasSnapshot(for: from) { try switcher.capture(for: from) }
            try switcher.restore(for: to)
        } catch {
            swapError = error
        }

        if wasRunning {
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.bundleID)
            if let url {
                _ = try? await NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        if let swapError { throw swapError }
    }
}
