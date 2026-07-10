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

            // (b) 취소: 창을 닫아도 로그인이 방금 끝났을 수 있으니 15초까지 완료를 더 기다린다.
            if userCanceled, graceUntil == nil { graceUntil = Date().addingTimeInterval(15) }
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // login shell로 PATH 확보, script(1)로 PTY 할당.
        // exec로 zsh를 script로 교체해 process가 곧 script(1)이 되게 한다
        // (terminate 시 셸만 죽고 script/claude가 고아로 남는 것 방지).
        proc.arguments = ["-lc", "exec script -q /dev/null claude auth login"]
        var env = ProcessInfo.processInfo.environment
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
            try await Task.sleep(for: .milliseconds(200))
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

    private func presentAuthWindow(url: URL) {
        // 앱을 활성화해야 인증 창이 앞으로 온다 (메뉴바 앱은 기본 비활성)
        NSApp.activate(ignoringOtherApps: true)
        let s = ASWebAuthenticationSession(url: forceLoginURL(url), callbackURLScheme: "mobius") {
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

    /// OAuth authorize URL에 `prompt=select_account`를 붙여 claude.ai가 기존 세션이 있어도
    /// 계정 선택 화면을 보이게 한다 (구글 등 타 사이트 세션은 건드리지 않음).
    /// claude.ai가 무시하면 "현재 계정 + 계정 전환 링크" 화면이 뜨며, 거기서 전환하면 된다.
    private func forceLoginURL(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "prompt" }) {
            items.append(URLQueryItem(name: "prompt", value: "select_account"))
        }
        comps.queryItems = items
        return comps.url ?? url
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
    case urlNotFound, timeout, canceled
    var errorDescription: String? {
        switch self {
        case .urlNotFound:
            return "로그인 URL을 얻지 못했습니다. 터미널에서 `claude auth login`으로 로그인한 뒤 "
                + "`mobius capture <이름>`으로 계정을 등록하세요."
        case .timeout:
            return "로그인 대기 시간이 초과되었습니다. 다시 시도해주세요."
        case .canceled:
            return "로그인이 취소되었습니다."
        }
    }
}
