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

    /// 테스트 주입용 — Claude 전용 ShipIt(자동업데이트 적용 프로세스)이 실행 중인가.
    var updaterIsRunning: @Sendable () -> Bool = { DesktopCoordinator.shipItRunning() }

    init(switcher: DesktopSwitcher) { self.switcher = switcher }

    /// pgrep으로 Claude 전용 ShipIt 프로세스를 찾는다. 실패(권한 등)는 false 취급.
    /// 패턴에 번들ID가 들어 있어 다른 Electron 앱의 ShipIt과는 안 겹친다.
    nonisolated static func shipItRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "com.anthropic.claudefordesktop.ShipIt"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 // 0 = 매칭 프로세스 존재
    }

    /// Desktop 종료 직후 ShipIt(Squirrel)이 스테이징된 업데이트를
    /// `/Applications/Claude.app` 통째 이동+교체로 적용할 수 있다. 적용 중에 재실행하면
    /// (a) 실행 인스턴스가 업데이트를 막거나(App Still Running Error)
    /// (b) 실행 중인 프로세스의 번들이 디스크에서 교체되어 코드서명 동적 검증이 깨지고,
    ///     키체인 승인창이 무한 반복된다 — '항상 허용'도 ACL에 저장되지 않는다.
    ///     (실측: 2026-07-11 ShipIt_stderr.log, CLAUDE.md 실패 기록 10)
    /// → 재실행 전에 ShipIt이 뜨는지 잠깐 관찰하고, 떠 있으면 끝날 때까지 기다린다.
    private func waitForUpdaterQuiescence() async {
        let probe = updaterIsRunning
        // ① 등장 관찰: 종료 직후 ShipIt이 뜨기까지 약간 걸림 — 최대 2.5초
        var seen = false
        for i in 0..<5 {
            if await Task.detached(operation: { probe() }).value { seen = true; break }
            if i < 4 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        guard seen else { return }
        // ② 종료 대기: 적용 자체는 수 초지만 여유 있게 최대 30초
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if await !Task.detached(operation: { probe() }).value {
                try? await Task.sleep(for: .milliseconds(500)) // 번들 교체 마무리 여유
                return
            }
        }
    }

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
        // 주의: 종료 직후 ShipIt이 업데이트 적용을 시작할 수 있다 — 재실행 측(launch())이
        // waitForUpdaterQuiescence()로 대기하므로 여기서는 추가 대기하지 않는다.
    }

    /// Desktop 실행(이미 실행 중이면 앞으로). 실행했으면(또는 필요 없으면) true.
    /// 업데이트 적용 중이거나 번들 위치가 비정상이면 실행하지 않고 false — 호출자가 안내.
    @discardableResult
    func launch() async -> Bool {
        await waitForUpdaterQuiescence()
        // URL은 매번 새로 해석 — 업데이트 직후 낡은 캐시가 이동된 옛 번들을 가리킬 수 있다.
        // 번들 교체 찰나에 파일이 없을 수 있으므로 0.5초 간격 최대 5초 재시도.
        var url: URL?
        for i in 0..<10 {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID),
               FileManager.default.fileExists(atPath: u.path) { url = u; break }
            if i < 9 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        guard let url else { return false }
        // 이동된 temp 번들(ShipIt이 밖으로 옮긴 옛 버전) 실행 금지 — 코드서명 깨진
        // 프로세스가 키체인 승인창 폭풍을 일으킨다.
        guard url.path.hasPrefix("/Applications/") else {
            NSLog("Mobius: Claude Desktop 경로가 비정상(\(url.path)) — 실행 생략")
            return false
        }
        _ = try? await NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// from(현재 활성)의 상태를 백업하고 to의 스냅샷으로 교체. Desktop이 켜져 있었으면 재실행.
    func switchDesktop(from: UUID, to: UUID) async throws {
        guard switcher.isDesktopInstalled else { return }
        guard !isSwitching else { throw DesktopCoordinatorError.switchInProgress }
        isSwitching = true
        defer { isSwitching = false }

        let wasRunning = isRunning
        // ★ 연결(capture)과 동일한 '완전 종료'를 사용한다 — 예전 인라인 종료는 헬퍼가 남아
        //   config.json/신원 파일을 붙잡은 채라 restore가 반영 안 돼 이전 계정으로 되살아났다.
        await terminateAndWait()

        // 스왑이 실패해도 원래 켜져 있었으면 반드시 재실행한다 (사용자를 앱 없는 상태로 방치 금지)
        var swapError: Error?
        do {
            // from은 '이미 연결(스냅샷)된 계정'일 때만 되저장한다.
            if switcher.hasSnapshot(for: from) { try switcher.capture(for: from) }
            // 대상이 캡처됐으면 그 세션으로, 미캡처면 로그아웃 상태로 —
            // Desktop이 이전 계정으로 남지 않고 항상 활성 계정을 반영한다.
            if switcher.hasSnapshot(for: to) {
                try switcher.restore(for: to)
            } else {
                try switcher.logout()
            }
        } catch {
            swapError = error
        }

        if wasRunning { await launch() }
        if let swapError { throw swapError }
    }
}
