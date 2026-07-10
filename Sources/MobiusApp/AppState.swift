import AppKit
import SwiftUI
import Combine
import UserNotifications
import MobiusCore

enum MenuStatus { case primaryActive, fallbackActive, allExhausted, unknown }

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var file = AccountsFile()
    @Published var lastError: String?
    @Published private(set) var usage: [UUID: UsageSnapshot] = [:]
    private var usageTask: Task<Void, Never>?
    /// 게이지 캐시 유효 시간 — 팝오버를 자주 여닫아도 이 간격보다 잦게 조회하지 않는다
    private let usageStaleness: TimeInterval = 240

    let env: MobiusEnvironment
    let store: AccountStore
    let io: ClaudeConfigIO
    let switcher: Switcher
    let watcher: SessionLogWatcher
    let engine = AutoSwitchEngine()
    lazy var desktopSwitcher = DesktopSwitcher(env: env)
    lazy var desktopCoordinator = DesktopCoordinator(switcher: desktopSwitcher)
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init() {
        let env = MobiusEnvironment.live()
        let kc = SystemKeychain()
        self.env = env
        // 초기화 실패(accounts.json 손상 등)는 빈 스토어로 시작하고 에러 표시
        let store: AccountStore
        var initError: String?
        do {
            store = try AccountStore(env: env, keychain: kc)
        } catch {
            store = AccountStore(env: env, keychain: kc, file: AccountsFile())
            initError = "계정 목록 로드 실패: \(error.localizedDescription)"
        }
        self.store = store
        self.io = ClaudeConfigIO(env: env, keychain: kc)
        self.switcher = Switcher(env: env, keychain: kc, store: store, io: io)
        self.watcher = SessionLogWatcher(env: env)
        self.file = store.file
        self.lastError = initError

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // CLI 등 외부 변경 통지 수신
        observer = DistributedNotificationCenter.default().addObserver(
            forName: MobiusNotification.accountsChanged, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reload() } }

        // 15초 주기: 로그 스캔 → 자동 전환 판단 → reconcile
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    deinit {
        timer?.invalidate()
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    /// 팝오버가 열릴 때 호출 — 캐시가 만료된 계정만 사용량 조회 (상시 폴링 없음)
    func refreshUsageIfStale() {
        guard UserDefaults.standard.object(forKey: "showUsageGauges") == nil
                || UserDefaults.standard.bool(forKey: "showUsageGauges") else { return }
        guard usageTask == nil else { return }
        let now = Date()
        let stale = store.file.accounts.filter {
            (usage[$0.id]?.fetchedAt ?? .distantPast) < now.addingTimeInterval(-usageStaleness)
        }
        guard !stale.isEmpty else { return }
        usageTask = Task { @MainActor in
            defer { usageTask = nil }
            for profile in stale {
                guard let secret = try? store.secret(for: profile.id),
                      let snap = try? await UsageFetcher.fetch(keychainBlob: secret.keychainBlob)
                else { continue }
                usage[profile.id] = snap
            }
        }
    }

    func reload() {
        // AccountStore는 자기 인스턴스 상태를 유지하므로 디스크에서 재로드
        if let fresh = try? AccountStore(env: env, keychain: SystemKeychain()) {
            try? store.replaceFile(with: fresh.file)
        }
        file = store.file
    }

    var menuStatus: MenuStatus {
        let now = Date()
        guard let active = file.active else { return .unknown }
        if file.accounts.allSatisfy({ $0.isLimited(now: now) || $0.needsReauth }),
           !file.accounts.isEmpty { return .allExhausted }
        return active.id == file.primary?.id ? .primaryActive : .fallbackActive
    }

    // MARK: 주기 처리

    func tick() {
        // 로그인 창이 열려 있는 동안은 reconcile/자동 전환이 LoginFlow의
        // 자격증명 변경 감지와 경합하지 않도록 전체를 건너뛴다.
        // Desktop 가이드 캡처 중에도 동일 — 자동 전환이 Desktop을 재실행하면
        // 사용자가 로그인 중인 창을 죽이고 감시 신호를 오염시킨다.
        guard loginFlow == nil, desktopCapture == nil else { return }
        let now = Date()
        try? switcher.adoptLiveAccountIfUnregistered()
        try? switcher.reconcile()

        // 배치 내 모든 hit는 스캔 시점의 활성 계정에 귀속 —
        // 루프 중 전환이 일어나도 남은 hit(구 세션 로그)가 새 활성 계정에 오기록되지 않도록.
        let activeID = store.file.activeAccountID
        for hit in watcher.scan(now: now) {
            if let activeID {
                try? store.update(activeID) {
                    $0.rateLimit = RateLimitInfo(resetsAt: hit.effectiveResetsAt(now: now),
                                                 recordedAt: now)
                }
            }
            apply(engine.onRateLimitHit(file: store.file, hit: hit, now: now), now: now)
        }
        apply(engine.onTick(file: store.file, now: now), now: now)
        file = store.file
    }

    private func apply(_ decision: Decision, now: Date) {
        switch decision {
        case .none: break
        case .allExhausted:
            notify(title: "모든 계정 한도 소진",
                   body: "전환 가능한 계정이 없습니다. 리셋을 기다려주세요.")
        case let .notifyExhaustedOnly(id):
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: "한도 소진 — 자동 전환이 꺼져 있습니다",
                   body: "\(name) 계정이 한도에 도달했습니다. 수동으로 전환하세요.")
        case let .switchTo(id, reason):
            let fromID = store.file.activeAccountID
            do {
                try switcher.switchTo(id)
                engine.noteSwitched(now: now)
                // 자동 전환의 결과인지 기록 — onTick의 primary 복귀는 이 플래그가
                // true일 때만 일어난다 (수동 전환 자동 회귀 방지)
                try? store.setAutoSwitchedFromPrimary(reason == .activeExhausted)
                MobiusNotification.postAccountsChanged()
                let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
                let title = reason == .primaryRecovered
                    ? "Primary 계정으로 복귀" : "Fallback 계정으로 전환"
                notify(title: title, body: "활성 계정: \(name)")
            } catch {
                lastError = "자동 전환 실패: \(error.localizedDescription)"
                return
            }
            // Desktop 자동 Fallback: 옵션 켬 + 대상 스냅샷 존재 시에만
            if store.file.desktopAutoSwitchEnabled {
                switchDesktopIfPossible(from: fromID, to: id)
            }
        }
    }

    // MARK: 사용자 액션

    func manualSwitch(to id: UUID) {
        let fromID = store.file.activeAccountID
        do {
            try switcher.switchTo(id)
            engine.noteSwitched()
            // 사용자의 의지로 전환 — 자동 복귀 대상이 아니다
            try? store.setAutoSwitchedFromPrimary(false)
            MobiusNotification.postAccountsChanged()
            reload()
        } catch {
            lastError = "전환 실패: \(error.localizedDescription)"
            return
        }
        // Desktop 동시 전환 (옵션 켜짐 + 대상 스냅샷 존재 시)
        if store.file.desktopSyncEnabled {
            switchDesktopIfPossible(from: fromID, to: id)
        }
    }

    /// 진행 중인 Desktop 전환 태스크 — 자동/수동 어느 경로든 하나만 허용.
    private var desktopSwitchTask: Task<Void, Never>?

    /// CLI 전환 성공 후 Desktop 동반 전환. 실패해도 CLI 전환은 유지된다.
    private func switchDesktopIfPossible(from fromID: UUID?, to id: UUID) {
        guard let fromID, fromID != id,
              desktopSwitcher.hasSnapshot(for: id),
              desktopCapture == nil else { return } // 가이드 캡처 중엔 Desktop을 건드리지 않음
        // 직렬화 게이트: 이전 Desktop 전환이 진행 중이면 이번 요청은 드롭 —
        // 연속 전환(A→B, B→C)이 겹치며 스냅샷이 교차 오염되는 것을 방지 (코디네이터도 재차 차단).
        guard desktopSwitchTask == nil else {
            lastError = "Desktop 전환이 진행 중입니다 — 이번 전환에서는 Desktop을 건너뜁니다."
            return
        }
        desktopSwitchTask = Task { @MainActor in
            defer { desktopSwitchTask = nil }
            do { try await desktopCoordinator.switchDesktop(from: fromID, to: id) }
            catch { lastError = "Desktop 전환 실패(CLI는 전환됨): \(error.localizedDescription)" }
        }
    }

    func moveFallback(from source: IndexSet, to destination: Int) {
        // List.onMove는 fallback 섹션(전체 인덱스 1...) 기준으로 변환해 호출한다
        guard let src = source.first else { return }
        let from = src + 1
        var to = destination + 1
        if to > from { to -= 1 }
        guard from != to else { return }
        try? store.moveFallback(fromIndex: from, toIndex: to)
        MobiusNotification.postAccountsChanged()
        reload()
    }

    func setAutoSwitch(_ on: Bool) {
        try? store.setAutoSwitch(on)
        MobiusNotification.postAccountsChanged()
        reload()
    }

    func setDesktopSync(_ on: Bool) {
        try? store.setDesktopSync(on)
        MobiusNotification.postAccountsChanged()
        reload()
    }

    func setDesktopAutoSwitch(_ on: Bool) {
        try? store.setDesktopAutoSwitch(on)
        MobiusNotification.postAccountsChanged()
        reload()
    }

    func removeAccount(_ id: UUID) {
        try? store.remove(id)
        desktopSwitcher.deleteSnapshot(for: id) // 고아 Desktop 스냅샷 정리
        MobiusNotification.postAccountsChanged()
        reload()
    }

    private var loginFlow: LoginFlowController?

    func addAccount() {
        guard loginFlow == nil else { return } // 진행 중이면 중복 실행 방지
        let flow = LoginFlowController(io: io, store: store, switcher: switcher)
        loginFlow = flow
        Task { @MainActor in
            do {
                switch try await flow.run() {
                case .added(let profile):
                    notify(title: "계정 추가 완료",
                           body: "\(profile.nickname) <\(profile.emailAddress)>")
                case .refreshed(let profile):
                    notify(title: "기존 계정 자격증명 갱신됨",
                           body: "\(profile.nickname) <\(profile.emailAddress)>")
                }
                reload()
            } catch {
                lastError = error.localizedDescription
                // 팝오버가 닫혀 있어도 인지할 수 있도록 알림으로도 전달
                notify(title: "계정 추가 실패", body: error.localizedDescription)
            }
            loginFlow = nil
        }
    }

    // MARK: Desktop 연결 — 가이드형 자동 캡처

    struct DesktopCaptureSession: Identifiable, Equatable {
        enum Step: Equatable {
            case launching      // Desktop 실행 중
            case waitingLogin   // 사용자 로그인 대기 (변경 감시)
            case saving         // 스냅샷 저장 중
            case done
            case failed(String)
        }
        let accountID: UUID
        let nickname: String
        var step: Step = .launching
        var id: UUID { accountID }
    }

    @Published var desktopCapture: DesktopCaptureSession?
    private var desktopCaptureTask: Task<Void, Never>?

    /// 카드 "Desktop 연결": 안내 시트 표시 → Desktop 실행 → 로그인 자동 감지 → 캡처.
    func beginDesktopCapture(for id: UUID) {
        guard desktopCapture == nil else { return } // 진행 중이면 중복 방지
        guard let profile = store.file.accounts.first(where: { $0.id == id }) else { return }
        guard desktopSwitcher.isDesktopInstalled else {
            lastError = "Claude Desktop이 설치되어 있지 않습니다."
            return
        }
        desktopCapture = DesktopCaptureSession(accountID: id, nickname: profile.nickname)
        desktopCaptureTask = Task { @MainActor [weak self] in
            await self?.runDesktopCaptureWatch(for: id)
        }
    }

    /// "지금 상태 저장": 이미 로그인돼 있어 mtime이 안 변할 때 즉시 캡처.
    func captureDesktopNow() {
        guard let session = desktopCapture else { return }
        desktopCaptureTask?.cancel()
        desktopCaptureTask = nil
        finishDesktopCapture(for: session.accountID)
    }

    /// 시트 닫기/취소 — 감시 태스크 정리.
    func endDesktopCapture() {
        desktopCaptureTask?.cancel()
        desktopCaptureTask = nil
        desktopCapture = nil
    }

    private func runDesktopCaptureWatch(for id: UUID) async {
        let baseline = desktopSwitcher.identityLastModified()

        // Desktop 실행 (이미 실행 중이면 앞으로 가져온다) — 실패 시 5분 침묵 없이 즉시 알림
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: DesktopCoordinator.bundleID) else {
            desktopCapture?.step = .failed("Claude Desktop 앱을 찾을 수 없습니다.")
            return
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            desktopCapture?.step = .failed("Claude Desktop 실행 실패: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled, desktopCapture?.accountID == id else { return }
        desktopCapture?.step = .waitingLogin

        // 1초 폴링, 최대 5분. 신원 파일 mtime 변경 후 2초간 정지하면
        // 쓰기가 끝난 것으로 보고 로그인 완료로 판정한다.
        var lastSeen = baseline
        var changedAt: Date?
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            do { try await Task.sleep(for: .seconds(1)) } catch { return } // 취소됨
            guard desktopCapture?.accountID == id else { return }
            let current = desktopSwitcher.identityLastModified()
            if current != lastSeen {
                lastSeen = current
                changedAt = Date()
            } else if let stamp = changedAt, current != baseline,
                      Date().timeIntervalSince(stamp) >= 2 {
                desktopCaptureTask = nil
                finishDesktopCapture(for: id)
                return
            }
        }
        desktopCapture?.step = .failed(
            "5분 안에 로그인 변경이 감지되지 않았습니다. 이미 로그인돼 있다면 '지금 상태 저장'을 누르세요.")
    }

    private func finishDesktopCapture(for id: UUID) {
        desktopCapture?.step = .saving
        do {
            try desktopSwitcher.capture(for: id)
            try store.update(id) { $0.hasDesktopSnapshot = true }
            MobiusNotification.postAccountsChanged()
            reload()
            desktopCapture?.step = .done
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: "Desktop 스냅샷 저장",
                   body: "\(name) 전환 시 Claude Desktop도 함께 전환됩니다.")
        } catch {
            desktopCapture?.step = .failed("저장 실패: \(error.localizedDescription)")
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
