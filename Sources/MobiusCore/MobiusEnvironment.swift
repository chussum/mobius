import Foundation

/// 모든 파일 경로의 단일 출처. 테스트는 temp 루트로, CLI는 MOBIUS_HOME 환경변수로 재지정 가능.
public struct MobiusEnvironment: Sendable {
    public var home: URL
    public var localUser: String
    /// codex CLI 설정 루트 오버라이드 (codex 자신의 CODEX_HOME과 동일 의미). nil이면 ~/.codex.
    public var codexHome: URL?

    public init(home: URL, localUser: String, codexHome: URL? = nil) {
        self.home = home
        self.localUser = localUser
        self.codexHome = codexHome
    }

    public var claudeDir: URL { home.appendingPathComponent(".claude") }
    public var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    public var credentialsFile: URL { claudeDir.appendingPathComponent(".credentials.json") }
    public var projectsDir: URL { claudeDir.appendingPathComponent("projects") }
    public var appSupportDir: URL {
        home.appendingPathComponent("Library/Application Support/Mobius")
    }
    public var accountsFile: URL { appSupportDir.appendingPathComponent("accounts.json") }
    /// 계정별 자격증명 스냅샷 보관소(0700). Claude Code 자신도 토큰을 .credentials.json(0600)에
    /// 두므로 동일 보안 수준이며, Keychain 승인창이 뜨지 않아 UX가 크게 개선된다.
    public var secretsDir: URL { appSupportDir.appendingPathComponent("secrets") }
    public func secretFile(for id: UUID) -> URL {
        secretsDir.appendingPathComponent("\(id.uuidString).json")
    }

    /// Claude Desktop(Electron)의 데이터 디렉토리
    public var desktopDataDir: URL {
        home.appendingPathComponent("Library/Application Support/Claude")
    }
    /// Claude Desktop의 앱 설정 — ★ 로그인 토큰(oauth:tokenCache 등)이 여기 저장된다.
    /// 신원 파일(Cookies 등)만으로는 계정이 안 바뀌므로 이 파일의 oauth 키도 함께 스왑해야 한다.
    public var desktopConfigFile: URL {
        desktopDataDir.appendingPathComponent("config.json")
    }
    /// 계정별 Desktop 신원 스냅샷 보관소
    public var desktopProfilesDir: URL {
        appSupportDir.appendingPathComponent("desktop-profiles")
    }

    /// Claude Code가 쓰는 Keychain 항목 좌표
    public var claudeKeychainService: String { "Claude Code-credentials" }
    public var claudeKeychainAccount: String { localUser }

    /// codex CLI 설정 루트. 자격증명은 auth.json 단일 파일(0600), Keychain 무관.
    public var codexDir: URL { codexHome ?? home.appendingPathComponent(".codex") }
    public var codexAuthFile: URL { codexDir.appendingPathComponent("auth.json") }
    /// codex 세션 로그 루트 — rollout-*.jsonl에 rate_limits 이벤트가 in-band 포함된다.
    public var codexSessionsDir: URL { codexDir.appendingPathComponent("sessions") }

    public static func live() -> MobiusEnvironment {
        let home: URL
        if let override = ProcessInfo.processInfo.environment["MOBIUS_HOME"] {
            home = URL(fileURLWithPath: override)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
        return MobiusEnvironment(home: home, localUser: NSUserName(), codexHome: codexHome)
    }
}
