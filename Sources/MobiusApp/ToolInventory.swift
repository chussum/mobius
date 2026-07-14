import AppKit
import Foundation

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

    static func runLoginShell(_ command: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
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
