import AppKit
import AuthenticationServices
import MobiusCore

/// "계정 추가" 오케스트레이션:
/// ① 라이브 되저장+보관 → ② `claude auth login`을 PTY로 구동해 출력에서 OAuth URL 추출
/// → ③ 그 URL을 ephemeral 인증 창으로 표시(매번 쿠키 백지 → 항상 로그인창)
/// → ④ 자격증명 변경 감지 → 프로필 자동 저장 → ⑤ 원래 계정 자동 복원.
/// 로그인 완료는 CLI가 띄우는 localhost 콜백 서버 경유로 자동 감지되므로
/// 인증 창의 커스텀 스킴 콜백은 사용하지 않는다.
@MainActor
final class LoginFlowController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let io: ClaudeConfigIO
    private let store: AccountStore
    private let switcher: Switcher
    private var process: Process?
    private var session: ASWebAuthenticationSession?
    private var userCanceled = false

    init(io: ClaudeConfigIO, store: AccountStore, switcher: Switcher) {
        self.io = io; self.store = store; self.switcher = switcher
    }

    /// 반환: 새로 등록(.added) 또는 같은 계정 재로그인으로 토큰 갱신(.refreshed)된 프로필.
    /// 실패/취소 시 에러 throw.
    func run() async throws -> LoginFlowResult {
        // ① 현재 상태 보관 (없으면 로그아웃 상태에서 시작한 것 — 복원 생략)
        try switcher.resaveLiveIntoMatchingProfile()
        let previous = try io.readLiveSnapshot()
        let previousActiveID = store.file.activeAccountID
        let baselineEmail = try io.liveEmail()

        defer { cleanup() }

        // ② claude auth login PTY 구동 + URL 추출
        let url = try await launchLoginAndCaptureURL()

        // ③ ephemeral 인증 창
        presentAuthWindow(url: url)

        // ④ 로그인 완료 감지 (0.5초 폴링, 최대 180초).
        //    완료 신호 = 자격증명 블롭 변경 + 안정화(liveIsStable). claude auth login은
        //    localhost 콜백을 받으면 자격증명을 쓰고 종료하므로, 프로세스 종료 시 인증 창을
        //    즉시 닫아 "창이 안 닫혀 사용자가 강제로 닫는" 상황을 막는다.
        let deadline = Date().addingTimeInterval(180)
        var graceUntil: Date?   // 창을 닫아도(취소 신호) 실제 로그인 완료를 놓치지 않게 유예
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))

            // 프로세스가 끝났으면(로그인 완료/종료) 인증 창을 즉시 닫는다.
            if !(process?.isRunning ?? true) { session?.cancel(); session = nil }

            // (a) 완료 감지를 취소 판단보다 먼저 — 로그인이 실제로 됐으면 취소로 오판하지 않는다.
            //     토큰+이메일을 두 번 읽어 일치할 때만(전환 중 불일치 배제) 등록한다.
            if let (snap, email) = await io.readStableLiveSnapshot(),
               snap.keychainBlob != previous?.keychainBlob {
                session?.cancel(); session = nil   // 창 닫기

                let nickname = store.file.accounts
                    .first { $0.emailAddress == email }?.nickname
                    ?? String(email.split(separator: "@").first ?? "account")
                let profile = try store.upsertProfile(nickname: nickname, snapshot: snap)

                if email == baselineEmail {
                    MobiusNotification.postAccountsChanged()
                    return .refreshed(profile)
                }
                // ⑤ 원래 계정 복원 (새 계정은 fallback 목록 끝). 원래 계정 없으면 새 계정 유지.
                if let previous, let prevID = previousActiveID {
                    try io.writeLiveSnapshot(previous)
                    try store.setActive(prevID)
                } else {
                    try store.setActive(profile.id)
                }
                MobiusNotification.postAccountsChanged()
                return .added(profile)
            }

            // (b) 취소: 창을 닫아도 로그인이 방금 끝났을 수 있으니 짧게(2.5초)만 완료를 더 기다린다.
            //     로그인 성공 시 자격증명은 창이 닫히기 전에 이미 써지므로 2.5초로 충분하고,
            //     로그인 없이 닫은 경우엔 곧바로 취소 처리돼 "계정 추가" 버튼이 다시 반응한다.
            if userCanceled, graceUntil == nil { graceUntil = Date().addingTimeInterval(2.5) }
            if let g = graceUntil, Date() > g { throw LoginFlowError.canceled }
        }
        throw LoginFlowError.timeout
    }

    private var browserHookFiles: (hook: URL, urlFile: URL)?

    /// 핵심(실측, claude 2.1.206): 터미널에 "출력"되는 URL은 수동 코드 페이지용
    /// (redirect_uri=platform.claude.com/oauth/code/callback — 코드를 CLI에 붙여넣어야 함)이고,
    /// CLI가 "브라우저로 열려는" URL이 자동 완료용(redirect_uri=http://localhost:PORT/callback)이다.
    /// 그래서 BROWSER 환경변수에 후킹 스크립트를 꽂아 브라우저행 URL을 가로챈다.
    private func makeBrowserHook() throws -> (hook: URL, urlFile: URL) {
        let dir = FileManager.default.temporaryDirectory
        let urlFile = dir.appendingPathComponent("mobius-login-url-\(UUID().uuidString)")
        let hook = dir.appendingPathComponent("mobius-browser-hook-\(UUID().uuidString).sh")
        try "#!/bin/sh\nprintf '%s' \"$1\" > \"\(urlFile.path)\"\n"
            .write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: hook.path)
        return (hook, urlFile)
    }

    private func launchLoginAndCaptureURL() async throws -> URL {
        // claude를 셸 PATH에 의존하지 않고 절대경로로 찾는다 — GUI(Finder) 실행 시 앱의 최소
        // 환경에선 `zsh -lc`가 .zshrc를 안 읽어 claude를 못 찾는다(계정 추가 실패의 원인).
        // 로그인 셸 폴백이 최대 5초 블록될 수 있어 해석은 백그라운드에서.
        guard let claudePath = await Task.detached(priority: .userInitiated,
                                                   operation: { Self.resolveClaudeBinary() }).value
        else { throw LoginFlowError.claudeNotFound }

        let proc = Process()
        // 셸 없이 script(PTY)로 직접 구동 — 셸 설정 의존 제거 + 인용 문제 없음.
        // proc가 곧 script(1)이라 terminate/kill(-pid)로 claude까지 정리된다.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        proc.arguments = ["-q", "/dev/null", claudePath, "auth", "login"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.augmentedPATH(env["PATH"])   // claude 및 claude가 spawn하는 하위 프로세스 해석용
        let files = try makeBrowserHook()
        browserHookFiles = files
        env["BROWSER"] = files.hook.path
        if env["TERM"] == nil { env["TERM"] = "xterm-256color" }
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = Pipe() // PTY 입력은 사용하지 않음
        try proc.run()
        process = proc

        // availableData 동기 읽기는 데이터가 없으면 블로킹 —
        // readabilityHandler(백그라운드 스레드)로 논블로킹 수집한다.
        // URL 추출 후에도 핸들러를 유지해 파이프를 계속 비운다
        // (읽기를 멈추면 버퍼가 차서 CLI가 쓰기 블로킹될 수 있음).
        // 프로세스 종료 → EOF에서 핸들러가 스스로 해제된다.
        let collector = LoginOutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return } // EOF
            collector.append(data)
        }

        let start = Date()
        let deadline = start.addingTimeInterval(20)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50)) // 빠르게 폴링해 로그인 창을 즉시 띄운다
            // 1순위: BROWSER 후킹으로 가로챈 자동 콜백 URL (localhost redirect — 완료 자동 감지)
            if let files = browserHookFiles,
               let text = try? String(contentsOf: files.urlFile, encoding: .utf8),
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.scheme?.hasPrefix("http") == true {
                return url
            }
            // 2순위(8초 유예 후): 터미널 출력 URL — 수동 코드 페이지로 이어지는 폴백.
            // 구버전 CLI가 BROWSER를 무시하는 경우에만 의미가 있다.
            if Date().timeIntervalSince(start) > 8, let url = collector.extractURL() {
                return url
            }
            if !proc.isRunning {
                if let files = browserHookFiles,
                   let text = try? String(contentsOf: files.urlFile, encoding: .utf8),
                   let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return url
                }
                if let url = collector.extractURL() { return url }
                break
            }
        }
        throw LoginFlowError.urlNotFound
    }

    /// GUI 앱 최소 PATH에 claude 표준 설치 경로들을 앞에 붙인다(셸 설정 무관).
    nonisolated static func augmentedPATH(_ existing: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parts = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                     "\(home)/.claude/local"]
        if let existing, !existing.isEmpty { parts.append(existing) }
        parts.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// claude 실행파일 절대경로 — 표준 위치 우선, 없으면 대화형 로그인 셸(.zshrc 소싱) 폴백.
    /// 블로킹(로그인 셸 폴백)이 있으니 백그라운드에서 호출한다.
    nonisolated static func resolveClaudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        // 폴백: `zsh -ilc`(대화형 → .zshrc 소싱)로 사용자 PATH에서 조회. `-lc`(비대화형)는 실패.
        if let p = viaLoginShell(), fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private nonisolated static func viaLoginShell() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-ilc", "command -v claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        // 최대 5초 폴링 — 무거운 .zshrc가 늦게 끝나도 계정 추가가 영영 안 막히게.
        // (command -v 출력은 한 줄이라 파이프가 안 차 데드락 없음.)
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if proc.isRunning { proc.terminate(); return nil }
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty
        else { return nil }
        return out.split(separator: "\n").first.map(String.init)
    }

    private func presentAuthWindow(url: URL) {
        // 앱을 활성화해야 인증 창이 앞으로 온다 (메뉴바 앱은 기본 비활성)
        NSApp.activate(ignoringOtherApps: true)
        // selectAccount 진입 URL로 변환해 바로 계정 선택 화면을 띄운다. returnTo에 localhost
        // 콜백이 그대로 실려 자동 완료도 유지된다 (실측 확인됨).
        let s = ASWebAuthenticationSession(url: selectAccountURL(url), callbackURLScheme: "mobius") {
            [weak self] _, error in
            // 완료는 자격증명 파일 변경 감지로 판단한다. 단, 사용자가 창을 닫으면
            // 3분 대기 없이 즉시 취소로 종료한다.
            if let error, (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                Task { @MainActor in self?.userCanceled = true }
            }
        }
        // ephemeral=false: 기본 브라우저(Safari) 쿠키를 공유 → 구글 등 다른 사이트 로그인은
        // 유지된다. 대신 claude.ai가 기존 세션으로 자동 로그인되지 않도록 아래 prompt로
        // 재인증을 강제해 "클로드 계정만 새로 고르는" 효과를 낸다.
        s.prefersEphemeralWebBrowserSession = false
        s.presentationContextProvider = self
        s.start()
        session = s
    }

    /// 가로챈 OAuth authorize URL을 claude.ai의 "계정 선택" 진입 URL로 변환한다.
    /// 관측된 패턴(계정 전환 링크): `https://claude.ai/login?selectAccount=true&returnTo=<authorize 경로>`
    /// → 기존 세션이 있어도 곧바로 계정 선택 화면이 뜨고, 구글 등 타 사이트 세션은 유지된다.
    /// (claude.ai 고유 URL 규칙이라 바뀔 수 있음 — 변환 실패 시 원본 URL로 폴백.)
    private func selectAccountURL(_ url: URL) -> URL {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = comps.percentEncodedQuery else { return url }
        // returnTo 값은 authorize 경로+쿼리 전체를 하나의 값으로 완전 인코딩해야 한다
        // (/ ? = & 까지 %2F %3F %3D %26 로). URLQueryItem은 / ? 를 인코딩하지 않아
        // claude.ai가 returnTo를 "/oauth/authorize"까지만 읽고 파라미터를 버렸다(실측 버그).
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")   // RFC 3986 unreserved만 그대로 둔다
        let returnToRaw = "/oauth/authorize?" + query
        guard let returnTo = returnToRaw.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return url }
        return URL(string: "https://claude.ai/login?selectAccount=true&returnTo=\(returnTo)") ?? url
    }

    private func cleanup() {
        if let files = browserHookFiles {
            try? FileManager.default.removeItem(at: files.hook)
            try? FileManager.default.removeItem(at: files.urlFile)
            browserHookFiles = nil
        }
        session?.cancel(); session = nil
        if let proc = process {
            let pid = proc.processIdentifier
            if proc.isRunning { proc.terminate() }
            // 프로세스 그룹에도 SIGTERM 폴백 — script/claude 고아 방지.
            // (그룹 리더가 아니면 조용히 실패하며, PTY 마스터가 닫히면
            //  claude는 SIGHUP으로 정리된다.)
            if pid > 0 { kill(-pid, SIGTERM) }
        }
        process = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
        -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

/// PTY 출력 수집 + OAuth URL 추출. readabilityHandler(백그라운드)와
/// 폴링 루프(메인)에서 동시에 접근하므로 락으로 보호한다.
final class LoginOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
    }

    func extractURL() -> URL? {
        lock.lock()
        let raw = String(decoding: buffer, as: UTF8.self)
        lock.unlock()
        return Self.extractLoginURL(from: raw)
    }

    /// ANSI 이스케이프를 제거하고 첫 https URL을 뽑는다.
    /// OSC 시퀀스(터미널 하이퍼링크 \u{1B}]8;;URL\u{07})를 먼저 제거하지 않으면
    /// 링크 목적지 URL과 화면 표시 URL이 이어붙어 두 배 길이 URL이 매칭된다.
    static func extractLoginURL(from raw: String) -> URL? {
        var clean = raw.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)",
            with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]",
            with: "", options: .regularExpression)
        guard let range = clean.range(
            of: "https://[^\\s\"'\u{1B}]+", options: .regularExpression) else { return nil }
        var url = String(clean[range])
        // 방어: 잔여 이스케이프로 URL이 중복 연결됐으면 첫 URL까지만 취한다
        let afterScheme = url.index(url.startIndex, offsetBy: "https://".count)
        if let second = url.range(of: "https://", range: afterScheme..<url.endIndex) {
            url = String(url[..<second.lowerBound])
        }
        return URL(string: url)
    }
}

enum LoginFlowResult {
    case added(AccountProfile)      // 새 계정 등록
    case refreshed(AccountProfile)  // 같은 계정 재로그인 → 토큰 갱신
}

enum LoginFlowError: LocalizedError {
    case urlNotFound, timeout, canceled, claudeNotFound
    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return loc("claude CLI를 찾지 못했어요. 설치를 확인하거나, 터미널에서 `claude auth login`으로 로그인한 뒤 `mobius capture <이름>`으로 계정을 등록하세요.")
        case .urlNotFound:
            return loc("로그인 URL을 얻지 못했습니다. 터미널에서 `claude auth login`으로 로그인한 뒤 `mobius capture <이름>`으로 계정을 등록하세요.")
        case .timeout:
            return loc("로그인 대기 시간이 초과되었습니다. 다시 시도해주세요.")
        case .canceled:
            return loc("로그인이 취소되었습니다.")
        }
    }
}
