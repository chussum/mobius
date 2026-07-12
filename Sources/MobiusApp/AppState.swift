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
    private var usageCacheLoaded = false
    private static let usageCacheKey = "usageCacheV1"

    // 폴백 로그인 검증. 네트워크 refresh는 **자동 폴백 전환 직전에만**(호출 빈도 최소 → 블락 위험↓).
    // 팝오버에서는 네트워크 0 로컬 검사(빈/만료 refresh 토큰 즉시 플래그)만 한다.
    private var fallbackLocalTask: Task<Void, Never>?
    lazy var fallbackChecker = FallbackAuthChecker(store: store)

    /// 마지막 성공 스냅샷 복원 — 비활성 계정은 저장 토큰이 만료되어(수 시간) 조회가 401로
    /// 실패할 수 있는데, 그때 빈 게이지 대신 마지막 값을 보여준다. 초기화 시각은 절대
    /// 시각이라 지나면 표기가 자연히 사라지고, 계정이 다시 활성화되면 값도 갱신된다.
    private func loadUsageCacheIfNeeded() {
        guard !usageCacheLoaded else { return }
        usageCacheLoaded = true
        guard let data = UserDefaults.standard.data(forKey: Self.usageCacheKey),
              let dict = try? JSONDecoder().decode([UUID: UsageSnapshot].self, from: data)
        else { return }
        for (id, snap) in dict where usage[id] == nil { usage[id] = snap }
    }

    private func saveUsageCache() {
        let ids = Set(store.file.accounts.map(\.id))
        let pruned = usage.filter { ids.contains($0.key) }
        if let data = try? JSONEncoder().encode(pruned) {
            UserDefaults.standard.set(data, forKey: Self.usageCacheKey)
        }
    }
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
    private var lastReconcileAt = Date.distantPast
    private var lastActiveSnapshotSyncAt = Date.distantPast
    static let reconcileInterval: TimeInterval = 15
    static let activeSnapshotSyncInterval: TimeInterval = 5 * 60 // 활성 계정 토큰 스냅샷 동기화

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
            initError = loc("계정 목록 로드 실패: %@", error.localizedDescription)
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

        // 앱 실행 시 Claude 자격증명 Keychain에 한 번 접근해 권한을 미리 받는다 —
        // 여기서 '항상 허용'을 한 번 누르면, 이후 계정 추가/전환 각 단계마다 반복해서
        // 권한 요청이 뜨지 않는다. (ACL이 이미 허용돼 있으면 조용히 지나간다.)
        let ioForWarmup = io
        Task.detached(priority: .utility) { _ = try? ioForWarmup.readLiveSnapshot() }

        // 3초 주기: 로그 스캔 → 자동 전환 판단 (빠른 fallback). reconcile/adopt는 내부에서
        // 15초로 게이팅해 Keychain 접근·라이브 추종 바운스를 늘리지 않는다.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { @MainActor in await tick() }
    }

    deinit {
        timer?.invalidate()
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    /// 팝오버가 열릴 때 호출 — 캐시가 만료된 계정만 사용량 조회 (상시 폴링 없음)
    func refreshUsageIfStale() {
        loadUsageCacheIfNeeded()
        guard UserDefaults.standard.object(forKey: "showUsageGauges") == nil
                || UserDefaults.standard.bool(forKey: "showUsageGauges") else { return }
        guard usageTask == nil else { return }
        let now = Date()
        // needsReauth 계정도 계속 조회한다 — CLI에서 직접 `claude auth login`으로 복구하는
        // 경우, 조회가 200이면 그 복구를 감지해 needsReauth를 자동으로 푼다(아래 성공 경로).
        // 여전히 401이면 `!profile.needsReauth` 가드가 재알림을 막으므로 스팸은 없다.
        let stale = store.file.accounts.filter {
            (usage[$0.id]?.fetchedAt ?? .distantPast) < now.addingTimeInterval(-usageStaleness)
        }
        guard !stale.isEmpty else { return }
        usageTask = Task { @MainActor in
            defer { usageTask = nil }
            var reauthChanged = false
            for profile in stale {
                let isActive = store.file.activeAccountID == profile.id
                // 활성 계정은 저장 스냅샷 대신 **라이브 토큰**으로 조회한다 — claude CLI가
                // 라이브 토큰을 갱신하므로 저장본이 낡으면 401 오탐(잘 쓰는데 "재로그인 필요")이
                // 난다. 비활성 계정은 라이브가 그 계정이 아니므로 저장 스냅샷을 쓴다.
                let blob: Data?
                if isActive, let live = try? io.readLiveSnapshot() { blob = live.keychainBlob }
                else { blob = (try? store.secret(for: profile.id))?.keychainBlob }
                guard let blob else { continue }
                do {
                    guard let snap = try await UsageFetcher.fetch(keychainBlob: blob)
                    else { continue }
                    usage[profile.id] = snap
                    // 조회 성공 = 토큰 살아있음 → 잘못 남은 재로그인 마킹 자가 해제
                    if profile.needsReauth {
                        try? store.setNeedsReauth(profile.id, false)
                        reauthChanged = true
                    }
                    // 리셋 시각 보정: 로그 기반 감지는 시각이 없으면 24h로 때웠지만
                    // usage API는 진짜 리셋 시각을 안다. 이 계정이 limited로 마킹돼 있고
                    // 소진된 한도(≥100%)의 실제 리셋이 현재 기록과 다르면 그 값으로 교정.
                    if let real = earliestExhaustedReset(snap),
                       let cur = store.file.accounts.first(where: { $0.id == profile.id })?.rateLimit,
                       abs(cur.resetsAt.timeIntervalSince(real)) > 60 {
                        try? store.update(profile.id) {
                            $0.rateLimit = RateLimitInfo(resetsAt: real, recordedAt: cur.recordedAt,
                                                         modelScoped: cur.modelScoped)
                        }
                        reauthChanged = true // reload 유발용 (상태 변경 반영)
                    }
                } catch is UsageFetcherError {
                    // 401/403 = 이 계정의 토큰이 거부됨. 계정별 토큰으로 조회하므로 오귀인 불가.
                    // - 활성 계정: 라이브 토큰으로 조회했는데도 거부 = 진짜 재로그인 필요.
                    // - 비활성 계정: 저장 토큰이 자연 만료(expiresAt 지남)면 정상 휴면이라 마킹 안 함
                    //   (전환하면 Claude Code가 갱신). 아직 유효기간인데 거부면 폐기된 것 → 마킹.
                    let stillValid = (UsageFetcher.expiresAt(from: blob) ?? .distantPast) > Date()
                    if (isActive || stillValid), !profile.needsReauth {
                        try? store.setNeedsReauth(profile.id, true)
                        reauthChanged = true
                        notify(title: loc("재로그인 필요"),
                               body: loc("%@ 계정의 인증이 만료됐어요. 카드의 '다시 로그인'을 눌러주세요.", profile.nickname))
                    }
                } catch { continue }
            }
            if reauthChanged {
                MobiusNotification.postAccountsChanged()
                reload()
            }
            saveUsageCache()
        }
    }

    /// 팝오버 열 때 폴백 계정을 **네트워크 0 로컬 검사**만 한다 — 빈/시간만료 refresh 토큰을
    /// 즉시 needsReauth로 플래그(fore.st 같은 손상 스냅샷 대응). 실제 네트워크 refresh는 하지
    /// 않는다(계정 리스크 최소화 — 매 팝오버마다 서버 호출 안 함). 진짜 refresh 검증은
    /// 자동 폴백 전환 직전에만 한다(preflightFallback).
    func validateFallbacksLocally() {
        guard fallbackLocalTask == nil else { return }
        let active = store.file.activeAccountID
        let now = Date()
        let targets = store.file.accounts.filter { $0.id != active && !$0.needsReauth }
        guard !targets.isEmpty else { return }
        fallbackLocalTask = Task { @MainActor in
            defer { fallbackLocalTask = nil }
            var changed = false
            for p in targets {
                let r = await fallbackChecker.check(p.id, activeAccountID: active, now: now, allowNetwork: false)
                if r == .noRefreshToken || r == .locallyDead {
                    changed = true   // targets는 !needsReauth만 → 새 전이 → 1회 알림
                    notify(title: loc("재로그인 필요"),
                           body: loc("%@ 계정의 로그인이 만료됐어요. 카드의 '다시 로그인'을 눌러주세요.", p.nickname))
                }
            }
            if changed { MobiusNotification.postAccountsChanged(); reload() }
        }
    }

    /// 자동 폴백이 이 계정으로 넘어가기 **직전** 실제 refresh로 검증한다. 죽었으면(마킹됨)
    /// false를 반환해 전환을 취소 — 다음 틱에 엔진(onTick)이 needsReauth를 제외하고 다음 폴백을
    /// 고른다. 살아있거나(refresh 성공) 판단 불가(네트워크 오류)면 true(전환 진행).
    private func preflightFallback(_ id: UUID, now: Date) async -> Bool {
        let r = await fallbackChecker.check(id, activeAccountID: store.file.activeAccountID,
                                            now: now, allowNetwork: true)
        switch r {
        case .dead, .locallyDead, .noRefreshToken, .storeFailed:
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: loc("재로그인 필요"),
                   body: loc("%@ 계정의 로그인이 만료돼 전환을 건너뛰었어요. '다시 로그인'을 눌러주세요.", name))
            return false
        default:
            return true   // refreshedAlive / transient / notFallback → 전환 진행
        }
    }

    /// 스냅샷에서 소진된(≥100%) 한도들의 가장 이른 실제 리셋 시각. 없으면 nil.
    private func earliestExhaustedReset(_ s: UsageSnapshot) -> Date? {
        var dates: [Date] = []
        if let p = s.fiveHourPercent, p >= 100, let r = s.fiveHourResetsAt { dates.append(r) }
        if let p = s.sevenDayPercent, p >= 100, let r = s.sevenDayResetsAt { dates.append(r) }
        for l in s.scopedLimits ?? [] where l.percent >= 100 {
            if let r = l.resetsAt { dates.append(r) }
        }
        return dates.min()
    }

    // MARK: 여러 Mac 동기화 (실험)

    enum SyncUIStatus: Equatable {
        case idle, running
        case done(SyncReport, Date)
        case failed(String, Date)
    }
    @Published var syncStatus: SyncUIStatus = .idle
    static let syncInterval: TimeInterval = 15 * 60

    private var syncMachineID: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "syncMachineID") { return id }
        let id = UUID().uuidString
        d.set(id, forKey: "syncMachineID")
        return id
    }

    /// manual=false(자동)는 15분 게이트. 파일 IO는 백그라운드, 결과만 메인 반영.
    func syncNow(manual: Bool = false) {
        let d = UserDefaults.standard
        guard d.bool(forKey: "syncEnabled") else { return }
        if !manual {
            let last = d.double(forKey: "lastSyncAt")
            guard Date().timeIntervalSince1970 - last >= Self.syncInterval else { return }
        }
        guard syncStatus != .running else { return }
        let cats = (d.stringArray(forKey: "syncCategories") ?? [])
            .compactMap(SyncCategory.init(rawValue:))
        guard !cats.isEmpty else {
            if manual { syncStatus = .failed(loc("동기화할 항목을 하나 이상 켜주세요"), Date()) }
            return
        }
        guard let root = SyncSupport.resolvedSyncRoot() else {
            if manual { syncStatus = .failed(loc("보관 위치에 접근할 수 없어요"), Date()) }
            return
        }
        syncStatus = .running
        d.set(Date().timeIntervalSince1970, forKey: "lastSyncAt")
        let claudeDir = env.claudeDir
        let machineID = syncMachineID
        let propagate = d.bool(forKey: "syncPropagateDeletes")
        Task { @MainActor in
            let report = await Task.detached(priority: .utility) {
                let engine = SyncEngine(
                    machineID: machineID,
                    localTrashDir: claudeDir.appendingPathComponent(".mobius-trash"))
                return engine.sync(categories: cats, claudeDir: claudeDir,
                                   syncRoot: root, propagateDeletes: propagate)
            }.value
            if let first = report.errors.first, report.uploaded + report.downloaded == 0 {
                syncStatus = .failed(first, Date())
            } else {
                syncStatus = .done(report, Date())
            }
        }
    }

    // MARK: 업데이트 확인

    enum UpdateStatus: Equatable { case idle, checking, upToDate, available(ReleaseInfo), failed }
    @Published var updateStatus: UpdateStatus = .idle
    static let updateCheckInterval: TimeInterval = 24 * 3600 // 하루 1회

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// manual=false(자동)는 토글 켜짐 + 마지막 확인에서 24시간 경과 시에만 조회.
    /// 자동 발견 알림은 같은 버전에 대해 한 번만 보낸다 (매일 잔소리 방지).
    func checkForUpdates(manual: Bool = false) {
        let defaults = UserDefaults.standard
        if !manual {
            let enabled = defaults.object(forKey: "autoUpdateCheck") == nil
                || defaults.bool(forKey: "autoUpdateCheck")
            guard enabled else { return }
            let last = defaults.double(forKey: "lastUpdateCheckAt")
            guard Date().timeIntervalSince1970 - last >= Self.updateCheckInterval else { return }
        }
        guard updateStatus != .checking else { return }
        updateStatus = .checking
        defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheckAt")
        Task { @MainActor in
            guard let info = try? await UpdateChecker.fetchLatest() else {
                updateStatus = manual ? .failed : .idle
                return
            }
            if UpdateChecker.isNewer(info.version, than: currentVersion) {
                updateStatus = .available(info)
                if !manual, defaults.string(forKey: "lastNotifiedVersion") != info.version {
                    defaults.set(info.version, forKey: "lastNotifiedVersion")
                    notify(title: loc("새 버전이 나왔어요"),
                           body: loc("Mobius v%@ — 설정에서 업데이트를 확인하세요.", info.version))
                }
            } else {
                updateStatus = .upToDate
            }
        }
    }

    func reload() {
        // AccountStore는 자기 인스턴스 상태를 유지하므로 디스크에서 재로드
        if let fresh = try? AccountStore(env: env, keychain: SystemKeychain()) {
            try? store.replaceFile(with: fresh.file)
        }
        file = store.file
        // 플래그(hasDesktopSnapshot)를 진실의 원천으로 삼아 스냅샷 디렉토리를 정리 —
        // 실패한 캡처의 잔재 dir이 유효 스냅샷으로 오인돼 잘못 복원되는 것을 막는다.
        let flagged = Set(store.file.accounts.filter { $0.hasDesktopSnapshot }.map { $0.id })
        desktopSwitcher.pruneSnapshotsExcept(flagged)
    }

    var menuStatus: MenuStatus {
        let now = Date()
        guard let active = file.active else { return .unknown }
        // 주계정에 머무는 중이면 주계정 색을 우선한다 — 사용자가 직접 주계정을 선택했을 때
        // (Fable 등 일부 한도만 소진돼도) 알람색으로 보이지 않게. 실측 피드백 반영.
        if active.id == file.primary?.id { return .primaryActive }
        // fallback 활성 중: 갈 곳이 모두 소진/재로그인이면 allExhausted, 아니면 fallback.
        if file.accounts.allSatisfy({ $0.isLimited(now: now) || $0.needsReauth }),
           !file.accounts.isEmpty { return .allExhausted }
        return .fallbackActive
    }

    // MARK: 주기 처리

    func tick() async {
        checkForUpdates() // 내부에서 24시간 게이트 — 실제 조회는 하루 1회
        syncNow()         // 내부에서 15분 게이트 — 켜져 있을 때만 동작
        // 로그인 창이 열려 있는 동안은 reconcile/자동 전환이 LoginFlow의
        // 자격증명 변경 감지와 경합하지 않도록 전체를 건너뛴다.
        // Desktop 가이드 캡처 중에도 동일 — 자동 전환이 Desktop을 재실행하면
        // 사용자가 로그인 중인 창을 죽이고 감시 신호를 오염시킨다.
        guard loginFlow == nil, desktopCapture == nil else { return }
        let now = Date()
        // reconcile/adopt는 15초마다만 — 3초 틱에 매번 돌리면 Keychain 접근이 잦아진다.
        // reconcile은 항상 라이브(실제 자격증명)를 진실로 삼아 active를 맞춘다 — active 마커가
        // 라이브와 어긋나면 UI가 /status와 달라지는 더 나쁜 버그가 된다(유예는 넣지 않는다).
        if now.timeIntervalSince(lastReconcileAt) >= Self.reconcileInterval {
            lastReconcileAt = now
            try? await switcher.adoptLiveAccountIfUnregistered()
            try? await switcher.reconcile()
        }
        // 활성 계정 스냅샷을 5분마다 라이브(갱신된 토큰)와 동기화 — 오래 쓰다 크래시해도
        // 스냅샷이 낡지 않게. reconcile은 활성 불변 시 되저장을 건너뛰므로 이 보강이 그 틈을 메운다.
        if now.timeIntervalSince(lastActiveSnapshotSyncAt) >= Self.activeSnapshotSyncInterval {
            lastActiveSnapshotSyncAt = now
            await switcher.refreshActiveSnapshotIfStable()
        }

        // 배치 내 모든 hit는 스캔 시점의 활성 계정에 귀속 —
        // 루프 중 전환이 일어나도 남은 hit(구 세션 로그)가 새 활성 계정에 오기록되지 않도록.
        let activeID = store.file.activeAccountID
        let hits = watcher.scan(now: now)
        // 주의: 인증 만료(authentication_failed) 로그는 "어느 계정" 것인지 적혀 있지 않다.
        // 활성 계정에 갖다 붙이면 전환 직후 등에 엉뚱한 계정이 마킹된다(실측 오귀인).
        // → needsReauth는 로그가 아니라 usage API 401(계정별 토큰으로 조회 → 오귀인 불가)로만
        //   판정한다. refreshUsageIfStale() 참조.
        for hit in hits {
            if let activeID {
                try? store.update(activeID) {
                    $0.rateLimit = RateLimitInfo(resetsAt: hit.effectiveResetsAt(now: now),
                                                 recordedAt: now, modelScoped: hit.modelScoped)
                }
            }
            await apply(engine.onRateLimitHit(file: store.file, hit: hit, now: now), now: now)
        }
        await apply(engine.onTick(file: store.file, now: now), now: now)
        file = store.file
    }

    private func apply(_ decision: Decision, now: Date) async {
        switch decision {
        case .none: break
        case .allExhausted:
            notify(title: loc("모든 계정 한도 소진"),
                   body: loc("전환 가능한 계정이 없습니다. 리셋을 기다려주세요."))
        case let .notifyExhaustedOnly(id):
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: loc("한도 소진 — 자동 전환이 꺼져 있습니다"),
                   body: loc("%@ 계정이 한도에 도달했습니다. 수동으로 전환하세요.", name))
        case let .switchTo(id, reason):
            // 전환 직전 검증: 자동 폴백(activeExhausted)으로 넘어가기 전에 대상 계정을 실제
            // refresh로 확인한다. 죽었으면 취소(마킹됨) → 다음 틱에 엔진이 다음 폴백을 고른다.
            if reason == .activeExhausted {
                guard await preflightFallback(id, now: now) else { file = store.file; return }
            }
            let fromID = store.file.activeAccountID
            do {
                try switcher.switchTo(id)
                engine.noteSwitched(now: now)
                // 자동 전환의 결과인지 기록 — onTick의 primary 복귀는 이 플래그가
                // true일 때만 일어난다 (수동 전환 자동 회귀 방지)
                try? store.setAutoSwitchedFromPrimary(reason == .activeExhausted)
                MobiusNotification.postAccountsChanged()
                let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
                let fromName = store.file.accounts.first { $0.id == fromID }?.nickname
                if reason == .primaryRecovered {
                    notify(title: loc("✅ %@ 계정으로 복귀했어요", name),
                           body: loc("한도가 초기화돼 주 계정으로 돌아왔어요."))
                } else {
                    notify(title: loc("🔄 %@ 계정으로 전환했어요", name),
                           body: loc("%@ 한도 소진 → %@. 새로 시작하는 claude 세션부터 적용돼요.",
                                     fromName ?? "?", name))
                }
            } catch {
                lastError = loc("자동 전환 실패: %@", error.localizedDescription)
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
        // 재로그인 필요로 이미 마킹된 계정은 그대로 전환(이미 죽은 걸 앎). 아니면 클릭한 계정을
        // **한 번 refresh** 해 살았는지 확인 + 신선한 토큰 확보 후 전환한다(전환 직전 검증과 동일).
        let alreadyFlagged = store.file.accounts.first { $0.id == id }?.needsReauth ?? false
        guard !alreadyFlagged else { performSwitch(to: id); return }
        Task { @MainActor in
            guard await preflightFallback(id, now: Date()) else { reload(); return } // 죽음 → 취소(마킹됨)
            performSwitch(to: id)
        }
    }

    private func performSwitch(to id: UUID) {
        let fromID = store.file.activeAccountID
        do {
            try switcher.switchTo(id)
            engine.noteSwitched()
            // 사용자가 직접 고른 계정 — 모델 전용 한도(Fable 등)로 자동으로 밀어내지 않는다.
            try? store.setUserPinned(id)
            // 사용자의 의지로 전환 — 자동 복귀 대상이 아니다
            try? store.setAutoSwitchedFromPrimary(false)
            MobiusNotification.postAccountsChanged()
            reload()
        } catch {
            lastError = loc("전환 실패: %@", error.localizedDescription)
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
              desktopCapture == nil else { return } // 가이드 캡처 중엔 Desktop을 건드리지 않음
        // 대상이 캡처됐으면 복원, 미캡처지만 Desktop이 로그인돼 있으면 로그아웃한다.
        // 둘 다 아니면(대상 미캡처 + Desktop 이미 로그아웃) 건드릴 필요 없음 — 불필요한 재실행 방지.
        guard desktopSwitcher.hasSnapshot(for: id) || desktopSwitcher.hasLiveLogin() else { return }
        // 직렬화 게이트: 이전 Desktop 전환이 진행 중이면 이번 요청은 드롭 —
        // 연속 전환(A→B, B→C)이 겹치며 스냅샷이 교차 오염되는 것을 방지 (코디네이터도 재차 차단).
        guard desktopSwitchTask == nil else {
            lastError = loc("Desktop 전환이 진행 중입니다 — 이번 전환에서는 Desktop을 건너뜁니다.")
            return
        }
        let targetUncaptured = !desktopSwitcher.hasSnapshot(for: id)
        desktopSwitchTask = Task { @MainActor in
            defer { desktopSwitchTask = nil }
            do { try await desktopCoordinator.switchDesktop(from: fromID, to: id) }
            catch { lastError = loc("Desktop 전환 실패(CLI는 전환됨): %@", error.localizedDescription); return }
            // 미캡처 계정으로 전환 = Desktop 로그아웃됨. 이제 사용자가 Desktop에 로그인하면
            // 그 세션을 자동으로 캡처해 다음부터는 전환만으로 복원되게 한다.
            if targetUncaptured { startDesktopAutoCapture(for: id) }
        }
    }

    private var desktopAutoCaptureTask: Task<Void, Never>?

    /// 미캡처 계정으로 전환해 Desktop이 로그아웃된 뒤, 사용자가 그 계정으로 로그인하면
    /// 자동으로 캡처한다. (로그아웃 확인 → 새 로그인 전이로만 발동, 5분 후 포기.)
    private func startDesktopAutoCapture(for id: UUID) {
        desktopAutoCaptureTask?.cancel()
        desktopAutoCaptureTask = Task { @MainActor in
            defer { desktopAutoCaptureTask = nil }
            var confirmedLoggedOut = false
            var loginSeenAt: Date?
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                // 그 사이 계정을 바꿨거나 가이드 캡처가 시작되면 중단
                guard store.file.activeAccountID == id, desktopCapture == nil else { return }
                let loggedIn = desktopSwitcher.hasLiveLogin()
                if !confirmedLoggedOut {
                    if !loggedIn { confirmedLoggedOut = true }
                    continue // 아직 로그인 상태면 자동캡처 안 함(오캡처 방지)
                }
                guard loggedIn else { loginSeenAt = nil; continue }
                if loginSeenAt == nil { loginSeenAt = Date() }
                else if Date().timeIntervalSince(loginSeenAt!) >= 2 { // 토큰 기록 완료 대기
                    do {
                        try desktopSwitcher.capture(for: id)
                        try store.update(id) { $0.hasDesktopSnapshot = true }
                        MobiusNotification.postAccountsChanged()
                        reload()
                        let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
                        notify(title: loc("Claude Desktop 자동 연결됨"),
                               body: loc("%@ 계정의 Desktop 세션을 저장했어요. 이제 전환하면 자동으로 이어집니다.", name))
                    } catch { lastError = loc("Desktop 자동 캡처 실패: %@", error.localizedDescription) }
                    return
                }
            }
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

    func setPrimary(_ id: UUID) {
        do { try store.setPrimary(id) } catch {
            lastError = loc("Primary 변경 실패: %@", error.localizedDescription)
            return
        }
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
        // 계정 추가는 `claude auth login`으로 동작 — CLI가 없으면 설정에서 설치하도록 안내
        guard ClaudeCLI.isInstalled else {
            lastError = loc("Claude Code CLI가 필요합니다 — 설정에서 설치하세요.")
            notify(title: loc("Claude Code CLI 필요"),
                   body: loc("계정을 추가하려면 먼저 Claude Code CLI를 설치하세요. 설정 → Claude Code CLI에서 설치할 수 있어요."))
            return
        }
        let flow = LoginFlowController(io: io, store: store, switcher: switcher)
        loginFlow = flow
        Task { @MainActor in
            do {
                switch try await flow.run() {
                case .added(let profile):
                    notify(title: loc("계정 추가 완료"),
                           body: "\(profile.nickname) <\(profile.emailAddress)>")
                case .refreshed(let profile):
                    notify(title: loc("기존 계정 자격증명 갱신됨"),
                           body: "\(profile.nickname) <\(profile.emailAddress)>")
                }
                reload()
                loginFlow = nil
                // 계정 추가는 CLI 계정만 추가한다. Desktop 연결은 사용자가 카드 메뉴에서
                // 필요할 때 직접 한다 (계정 추가 흐름에 끼워넣으면 저장 계정이 뒤섞였음).
                return
            } catch {
                lastError = error.localizedDescription
                // 팝오버가 닫혀 있어도 인지할 수 있도록 알림으로도 전달
                notify(title: loc("계정 추가 실패"), body: error.localizedDescription)
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
    /// 강제 로그아웃으로 치워둔 원래 세션 — 취소 시 복원용
    private var desktopCaptureStash: URL?

    /// 카드 "Desktop 연결": 현재 Desktop을 강제 로그아웃(세션 치우기)한 뒤 다시 띄워
    /// 사용자가 **해당 계정으로 새로 로그인**하게 하고, 그 세션을 캡처한다.
    /// 강제 로그아웃 덕에 다른 계정이 잘못 저장될 여지가 원천 차단된다.
    func beginDesktopCapture(for id: UUID) {
        guard desktopCapture == nil else { return } // 진행 중이면 중복 방지
        guard let profile = store.file.accounts.first(where: { $0.id == id }) else { return }
        // 안전 가드: Desktop 캡처는 현재 활성 계정의 세션을 잡으므로, 활성 계정에서만 허용한다.
        guard id == store.file.activeAccountID else {
            lastError = loc("먼저 이 계정으로 전환한 뒤 Claude Desktop을 연결하세요.")
            return
        }
        guard desktopSwitcher.isDesktopInstalled else {
            lastError = loc("Claude Desktop이 설치되어 있지 않습니다.")
            return
        }
        desktopCapture = DesktopCaptureSession(accountID: id, nickname: profile.nickname)
        desktopCaptureTask = Task { @MainActor [weak self] in
            await self?.runDesktopCaptureWatch(for: id)
        }
    }

    /// 시트 닫기/취소 — 감시 태스크 정리 + 강제 로그아웃했던 원래 세션 복원.
    func endDesktopCapture() {
        desktopCaptureTask?.cancel()
        desktopCaptureTask = nil
        desktopCapture = nil
        guard let stash = desktopCaptureStash else { return }
        desktopCaptureStash = nil
        // 취소: 치워둔 원래 Desktop 로그인을 되돌린다 (종료 → 복원 → 재실행)
        Task { @MainActor in
            await desktopCoordinator.terminateAndWait()
            try? desktopSwitcher.restoreStashedIdentity(from: stash)
            if await !desktopCoordinator.launch() {
                lastError = loc("Claude Desktop 재실행 실패 — 업데이트 적용 중일 수 있어요. 잠시 후 수동으로 실행해주세요.")
            }
        }
    }

    private func runDesktopCaptureWatch(for id: UUID) async {
        // 1. Desktop 종료 → 현재 세션 치우기(강제 로그아웃) → 재실행(로그인 화면)
        await desktopCoordinator.terminateAndWait()
        guard !Task.isCancelled, desktopCapture?.accountID == id else { return }
        do {
            desktopCaptureStash = try desktopSwitcher.stashLiveIdentity()
        } catch {
            desktopCapture?.step = .failed(loc("Desktop 로그아웃 실패: %@", error.localizedDescription))
            return
        }
        if await !desktopCoordinator.launch() {
            desktopCapture?.step = .failed(
                loc("Claude Desktop 재실행 실패 — 업데이트 적용 중일 수 있어요. 잠시 후 다시 시도해주세요."))
            return
        }
        guard !Task.isCancelled, desktopCapture?.accountID == id else { return }
        desktopCapture?.step = .waitingLogin

        // 자동 감지 — **로그아웃 확인 → 새 로그인** 전이일 때만 저장한다.
        //  ① 먼저 실제로 로그아웃됐는지 확인(hasLiveLogin==false). 재실행 직후에도 계속 로그인
        //     상태면 강제 로그아웃이 실패한 것 → 이전 계정을 잘못 캡처하지 않도록 에러 처리.
        //  ② 로그아웃 확인 후, 로그인 토큰이 새로 생기면(사용자가 로그인) 1.5초 안정화 뒤 저장.
        var confirmedLoggedOut = false
        let stillLoggedInSince = Date()
        var loginSeenAt: Date?
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            do { try await Task.sleep(for: .seconds(1)) } catch { return } // 취소됨
            guard desktopCapture?.accountID == id else { return }
            let loggedIn = desktopSwitcher.hasLiveLogin()

            if !confirmedLoggedOut {
                if loggedIn {
                    // 재실행했는데도 로그아웃이 안 됨 — 6초까지 기다려보고 계속이면 실패 판정.
                    if Date().timeIntervalSince(stillLoggedInSince) >= 6 {
                        desktopCapture?.step = .failed(
                            loc("Claude Desktop 로그아웃에 실패했어요. 잠시 후 다시 시도하거나, Desktop을 완전히 종료한 뒤 다시 연결해주세요."))
                        return
                    }
                } else {
                    confirmedLoggedOut = true // 로그아웃 확인됨 — 이제 새 로그인을 기다린다
                }
                continue
            }

            // 로그아웃 확인 후 단계: 새 로그인 감지
            guard loggedIn else { loginSeenAt = nil; continue }
            if loginSeenAt == nil { loginSeenAt = Date() }
            else if Date().timeIntervalSince(loginSeenAt!) >= 1.5 { // 토큰 기록 완료 대기
                desktopCaptureTask = nil
                finishDesktopCapture(for: id)
                return
            }
        }
        desktopCapture?.step = .failed(loc("5분 안에 로그인이 감지되지 않았습니다. 다시 시도해주세요."))
    }

    private func finishDesktopCapture(for id: UUID) {
        // 로그인 전(신원 파일 없음)에 저장을 누른 경우 빈 세션을 캡처하지 않도록 막는다.
        guard desktopSwitcher.identityLastModified() != nil else {
            desktopCapture?.step = .failed(
                loc("아직 로그인이 감지되지 않았어요. Claude Desktop에서 로그인을 마친 뒤 다시 저장을 눌러주세요."))
            return
        }
        desktopCapture?.step = .saving
        do {
            try desktopSwitcher.capture(for: id)
            try store.update(id) { $0.hasDesktopSnapshot = true }
            if let stash = desktopCaptureStash { desktopSwitcher.discardStash(stash) }
            desktopCaptureStash = nil
            MobiusNotification.postAccountsChanged()
            reload()
            desktopCapture?.step = .done
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: loc("Desktop 스냅샷 저장"),
                   body: loc("%@ 전환 시 Claude Desktop도 함께 전환됩니다.", name))
        } catch {
            desktopCapture?.step = .failed(loc("저장 실패: %@", error.localizedDescription))
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
