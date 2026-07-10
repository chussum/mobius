import SwiftUI
import Combine
import UserNotifications
import MobiusCore

enum MenuStatus { case primaryActive, fallbackActive, allExhausted, unknown }

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var file = AccountsFile()
    @Published var lastError: String?

    let env: MobiusEnvironment
    let store: AccountStore
    let io: ClaudeConfigIO
    let switcher: Switcher
    let watcher: SessionLogWatcher
    let engine = AutoSwitchEngine()
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
        guard loginFlow == nil else { return }
        let now = Date()
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
        case let .switchTo(id, reason):
            do {
                try switcher.switchTo(id)
                engine.noteSwitched(now: now)
                MobiusNotification.postAccountsChanged()
                let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
                let title = reason == .primaryRecovered
                    ? "Primary 계정으로 복귀" : "Fallback 계정으로 전환"
                notify(title: title, body: "활성 계정: \(name)")
            } catch {
                lastError = "자동 전환 실패: \(error.localizedDescription)"
            }
        }
    }

    // MARK: 사용자 액션

    func manualSwitch(to id: UUID) {
        do {
            try switcher.switchTo(id)
            engine.noteSwitched()
            MobiusNotification.postAccountsChanged()
            reload()
        } catch { lastError = "전환 실패: \(error.localizedDescription)" }
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

    func removeAccount(_ id: UUID) {
        try? store.remove(id)
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

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
