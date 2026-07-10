import Foundation

/// Claude Code CLI(`claude`) 설치 감지 및 설치. Mobius는 CLI로 로그인/전환하므로
/// CLI가 없으면 아무것도 못 한다 — 온보딩/설정에서 상태를 보여주고 설치를 돕는다.
enum ClaudeCLI {
    struct Info: Equatable { var path: String; var version: String }

    /// 로그인 셸(zsh -lc)로 claude를 찾는다 — GUI 앱의 최소 PATH 대신 사용자 PATH를 쓴다.
    /// 알려진 설치 경로도 함께 확인한다.
    static func locate() -> Info? {
        // 1) 로그인 셸에서 command -v + 버전
        if let out = runLoginShell("command -v claude 2>/dev/null && claude --version 2>/dev/null"),
           let path = out.split(separator: "\n").first.map(String.init),
           FileManager.default.isExecutableFile(atPath: path) {
            let version = out.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
            return Info(path: path, version: version.trimmingCharacters(in: .whitespaces))
        }
        // 2) 폴백: 알려진 경로 직접 확인
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/usr/local/bin/claude",
                          "/opt/homebrew/bin/claude"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            let v = runLoginShell("'\(p)' --version 2>/dev/null")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Info(path: p, version: v)
        }
        return nil
    }

    static var isInstalled: Bool { locate() != nil }

    /// 공식 네이티브 설치 스크립트로 설치 (node 불필요, ~/.local/bin/claude에 설치).
    /// 성공 시 nil, 실패 시 에러 메시지.
    static func install() async -> String? {
        // 설치 스크립트는 홈 아래에 쓰므로 관리자 권한 불필요.
        let script = "curl -fsSL https://claude.ai/install.sh | bash"
        guard let (code, output) = await runLoginShellAsync(script) else {
            return "설치 프로세스를 시작하지 못했습니다."
        }
        if code == 0, isInstalled { return nil }
        let tail = output.split(separator: "\n").suffix(3).joined(separator: " ")
        return "설치 실패 (코드 \(code)). \(tail)"
    }

    // MARK: 셸 실행

    private static func runLoginShell(_ command: String) -> String? {
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

    private static func runLoginShellAsync(_ command: String) async -> (Int32, String)? {
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
