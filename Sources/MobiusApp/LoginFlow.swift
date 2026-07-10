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

    init(io: ClaudeConfigIO, store: AccountStore, switcher: Switcher) {
        self.io = io; self.store = store; self.switcher = switcher
    }

    /// 반환: 새로 등록된 프로필. 실패/취소 시 에러 throw.
    func run() async throws -> AccountProfile {
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

        // ④ 자격증명 변경 대기 (최대 180초, 1초 폴링)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            guard let changed = try? io.liveEmail(), changed != baselineEmail else { continue }
            // CLI가 ~/.claude.json과 Keychain을 순차 기록하는 사이의 부분 상태를
            // 피하기 위해 1초 뒤 재확인하고, Keychain 블롭도 실제로 바뀌었는지 본다.
            try await Task.sleep(for: .seconds(1))
            if let email = try? io.liveEmail(), email != baselineEmail,
               let snap = try? io.readLiveSnapshot(),
               snap.keychainBlob != previous?.keychainBlob {
                let nickname = String(email.split(separator: "@").first ?? "account")
                let profile = try store.upsertProfile(nickname: nickname, snapshot: snap)
                // ⑤ 원래 계정 복원 (새 계정은 fallback 목록 끝에 등록됨).
                //    원래 계정이 없었으면(첫 계정 등록) 새 계정을 활성으로 유지.
                if let previous, let prevID = previousActiveID {
                    try io.writeLiveSnapshot(previous)
                    try store.setActive(prevID)
                } else {
                    try store.setActive(profile.id)
                }
                MobiusNotification.postAccountsChanged()
                return profile
            }
        }
        throw LoginFlowError.timeout
    }

    private func launchLoginAndCaptureURL() async throws -> URL {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // login shell로 PATH 확보, script(1)로 PTY 할당.
        // 실측(claude 2.1.206): `claude /login`(초기 프롬프트) 대신
        // `claude auth login` 서브커맨드가 로그인 진입점 — URL을 stdout에 출력하고
        // localhost 콜백 서버로 완료를 자동 감지한다.
        proc.arguments = ["-lc", "script -q /dev/null claude auth login"]
        var env = ProcessInfo.processInfo.environment
        // CLI의 기본 브라우저 자동 오픈 억제 — 인증 창은 앱이 ephemeral로 띄운다.
        env["BROWSER"] = "true"
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

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            if let url = collector.extractURL() { return url }
            if !proc.isRunning {
                // 프로세스가 이미 끝났으면 남은 버퍼만 마지막으로 확인
                if let url = collector.extractURL() { return url }
                break
            }
        }
        throw LoginFlowError.urlNotFound
    }

    private func presentAuthWindow(url: URL) {
        // 앱을 활성화해야 인증 창이 앞으로 온다 (메뉴바 앱은 기본 비활성)
        NSApp.activate(ignoringOtherApps: true)
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "mobius") { _, _ in
            // 완료는 자격증명 파일 변경 감지로 판단하므로 콜백은 무시
        }
        s.prefersEphemeralWebBrowserSession = true // 매번 쿠키 백지 → 항상 로그인창
        s.presentationContextProvider = self
        s.start()
        session = s
    }

    private func cleanup() {
        session?.cancel(); session = nil
        process?.terminate(); process = nil
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

enum LoginFlowError: LocalizedError {
    case urlNotFound, timeout
    var errorDescription: String? {
        switch self {
        case .urlNotFound:
            return "로그인 URL을 얻지 못했습니다. 터미널에서 `claude auth login`으로 로그인한 뒤 "
                + "`mobius capture <이름>`으로 계정을 등록하세요."
        case .timeout:
            return "로그인 대기 시간이 초과되었습니다. 다시 시도해주세요."
        }
    }
}
