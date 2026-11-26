import AppKit
import Foundation
import MobiusCore

/// 설정 화면 "설치 현황"의 감지 유틸 — CLI 바이너리(로그인 셸 PATH 기준),
/// 데스크톱 앱(번들 ID 기준), mobius 명령어 설치 위치.
enum ToolInventory {
    struct CLIInfo: Equatable { var path: String; var version: String }
    struct AppInfo: Equatable { var path: String; var version: String }

    /// 로그인 셸(zsh -lc)로 CLI를 찾는다 — GUI 앱의 최소 PATH 대신 사용자 PATH를 쓴다
    /// (실패 기록 15: GUI 셸은 .zshrc를 읽지 않아 bare 명령이 실패할 수 있다).
    /// 알려진 설치 경로도 함께 확인한다.
    static func locateCLI(_ binary: String, fallbackPaths: [String]) -> CLIInfo? {
        if let out = runLoginShell(
               "command -v \(binary) 2>/dev/null && \(binary) --version 2>/dev/null"),
           let path = out.split(separator: "\n").first.map(String.init),
           FileManager.default.isExecutableFile(atPath: path) {
            let version = out.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
            return CLIInfo(path: path, version: version.trimmingCharacters(in: .whitespaces))
        }
        for p in fallbackPaths where FileManager.default.isExecutableFile(atPath: p) {
            let v = runLoginShell("'\(p)' --version 2>/dev/null")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CLIInfo(path: p, version: v)
        }
        return nil
    }

    /// 경로만 찾는다 — **명령을 실행하지 않는다**(`--version` 도 부르지 않는다).
    /// agy 를 허용한 경로 안에서만 실행하도록 래퍼로 막아 둔 환경이 있어,
    /// 설치 확인만으로 agy 를 띄우지 않는다.
    static func locatePath(_ binary: String, fallbackPaths: [String]) -> String? {
        if let out = runLoginShell("command -v \(binary) 2>/dev/null"),
           let path = out.split(separator: "\n").first.map(String.init),
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return fallbackPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// agy 설치 현황 — 버전은 실제 바이너리의 Caskroom 경로에서 읽는다(실행하지 않는다).
    static func locateAntigravityCLI() -> CLIInfo? {
        let info = AntigravityInstallInfo.shared
        guard let path = info.launcher else { return nil }
        return CLIInfo(path: path, version: info.version ?? "")
    }

    static func locateCodexCLI() -> CLIInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return locateCLI("codex", fallbackPaths: [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
        ])
    }

    /// 번들 ID로 설치된 앱을 찾는다 (LaunchServices 경유 — 경로 스캔 불필요).
    /// 이름이 같은 앱이 여럿일 때(예: "ChatGPT"가 com.openai.codex와 com.openai.chat
    /// 두 개) 번들 ID가 유일한 안정 식별자다.
    static func appBundle(bundleID: String) -> AppInfo? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let version = Bundle(url: url)?
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return AppInfo(path: url.path, version: version)
    }

    // MARK: mobius 명령어 설치 관리

    /// 관리 대상 위치. /usr/local/bin은 설치 버튼의 기본 대상(관리자 권한),
    /// ~/.local/bin은 수동 설치를 흡수하기 위한 감지·관리 대상.
    static var mobiusCandidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/mobius", "\(home)/.local/bin/mobius"]
    }

    /// 현재 설치된(깨진 심링크 포함) mobius 경로들.
    static func mobiusInstallations() -> [String] {
        mobiusCandidatePaths.filter { path in
            FileManager.default.fileExists(atPath: path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
        }
    }

    // MARK: 셸 실행 (ClaudeCLI와 공유)

    /// 로그인 셸 한 번. **제한 시간(기본 10초)** 을 넘기면 종료하고 nil — `~/.zprofile` 이 멈추거나
    /// stderr 를 많이 써도 호출자가 영영 기다리지 않게 한다. stdout·stderr 는 별도 큐에서 끝까지 읽는다
    /// (읽지 않는 파이프가 차서 자식이 멈추는 일을 막는다 — 리뷰 1회차 Codex P1-6).
    static func runLoginShell(_ command: String, timeout: TimeInterval = 10) -> String? {
        let runner = ProcessSecurityRunner(executable: URL(fileURLWithPath: "/bin/zsh"))
        guard case let .exited(_, stdout, _) = runner.run(["-lc", command], stdin: nil, timeout: timeout)
        else { return nil }
        let out = String(decoding: stdout, as: UTF8.self)
        return out.isEmpty ? nil : out
    }

    static func runLoginShellAsync(_ command: String) async -> (Int32, String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-lc", command]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do { try proc.run() } catch {
                    continuation.resume(returning: nil); return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                continuation.resume(returning:
                    (proc.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
