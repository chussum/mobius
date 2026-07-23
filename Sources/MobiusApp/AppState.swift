import AppKit
import SwiftUI
import Combine
import UserNotifications
import MobiusCore

enum MenuStatus { case primaryActive, fallbackActive, allExhausted, unknown }

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var file = AccountsFile()
    /// 푸터 에러 배너. 5분 지나면 tick이 자동 소거한다 — 스스로 사라지지 않아
    /// 옛 에러(예: 취소한 로그인)가 영구 잔류하던 것 방지(사용자 요청).
    @Published var lastError: String? {
        didSet { lastErrorAt = lastError == nil ? nil : Date() }
    }
    private var lastErrorAt: Date?
    static let lastErrorTTL: TimeInterval = 5 * 60
    @Published private(set) var usage: [UUID: UsageSnapshot] = [:]
    // 수동 전환 낙관적 표시 — 클릭 즉시 이 계정을 활성으로 보여주고(스무스), 실제 refresh+스왑은
    // 백그라운드에서. 완료되면 nil로 정착(실제 activeAccountID가 인계).
    @Published private(set) var pendingSwitchID: UUID?
    private var usageTask: Task<Void, Never>?
    // 비활성 codex 게이지 프로브 — 단일 플라이트 핸들 + 순수 조회기. 게이지 전용(마킹 없음).
    private var codexUsageTask: Task<Void, Never>?
    private let codexProber = CodexUsageProber()
    // 비활성 codex 계정의 만료 access 토큰 refresh(게이지 전용) — 회전본은 credential lock 안에서
    // 활성 재확인·신원 검증 후 원자 저장한다. 활성 계정은 절대 refresh하지 않는다.
    private let codexRefresher = CodexTokenRefresher()
    // transient(네트워크/5xx) 실패 시 팝오버마다 회전 시도가 반복되지 않게 하는 계정당 재시도 쿨다운.
    private var lastCodexRefreshAttemptAt: [UUID: Date] = [:]
    // refresh_token_invalidated/invalid_grant(죽은 토큰) 계정의 긴 백오프 — 죽은 토큰은 어차피 401
    // 이므로 이 시각 전까지 refresh/probe를 아예 건너뛴다(게이지는 마지막 값에 둔다).
    private var codexRefreshDeadUntil: [UUID: Date] = [:]
    static let codexDeadRefreshCooldown: TimeInterval = 24 * 3600
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

    // MARK: 배지(인증 의심) — 무상태 세션활동×토큰만료 판정 (AuthSuspicion)

    /// 알림을 이미 보낸 의심 계정 id — **알림 중복만** 막는 최소 영속 집합이다(의심 조건
    /// 자체는 무상태라 저장하지 않는다). 재시작해도 같은 에피소드에 다시 알리지 않고,
    /// 회복(조건 해제)하면 제거돼 다음 재발엔 다시 알린다.
    private var notifiedSuspects: Set<UUID> = []
    private var notifiedSuspectsLoaded = false
    private static let notifiedSuspectsKey = "authSuspectNotifiedV1"

    private func loadNotifiedSuspectsIfNeeded() {
        guard !notifiedSuspectsLoaded else { return }
        notifiedSuspectsLoaded = true
        guard let data = UserDefaults.standard.data(forKey: Self.notifiedSuspectsKey),
              let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) else { return }
        notifiedSuspects = ids
    }

    /// 변경 시에만 저장 — 현재 계정 id로 필터해 삭제된 계정의 잔재를 정리한다.
    private func saveNotifiedSuspects() {
        let ids = Set(store.file.accounts.map(\.id))
        notifiedSuspects = notifiedSuspects.filter { ids.contains($0) }
        if let data = try? JSONEncoder().encode(notifiedSuspects) {
            UserDefaults.standard.set(data, forKey: Self.notifiedSuspectsKey)
        }
    }

    /// 활성 계정의 저장 스냅샷 access 만료 시각 캐시 — 한 계정만 담는다(활성). 값싼 절반이
    /// 매 틱 호출해도 파일을 다시 읽지 않도록, 캐시가 비었거나 다른 계정 키일 때만 계산·캐싱.
    /// 5분 fresh sync마다 invalidate돼 다음 조회가 갱신된 스냅샷으로 재계산된다.
    private var expiryCache: (id: UUID, expiry: Date?)?

    private func cachedStoredExpiry(for id: UUID) -> Date? {
        if let c = expiryCache, c.id == id { return c.expiry }
        let exp = (try? store.secret(for: id)).flatMap { UsageFetcher.expiresAt(from: $0.keychainBlob) }
        expiryCache = (id, exp)
        return exp
    }

    private func invalidateExpiryCache() { expiryCache = nil }

    /// 배지 값싼 절반 — **IO 0**(Keychain·네트워크 없음, 만료 캐시 + 워처 인메모리 활동만).
    /// 로그인 플로우 가드 **아래**에서 매 틱 돈다. 활성 Claude가 없으면 배지를 비운다.
    /// 조건이 안 성립하면 배지·알림 기록에서 빼고(재발 시 다시 알림), 이미 플래그면
    /// 라이브 재검증 없이 유지한다(승격은 5분 블록의 라이브 절반이 fresh sync 뒤에만).
    private func recomputeBadgeCheap(now: Date) {
        loadNotifiedSuspectsIfNeeded()
        guard let active = store.file.active(of: .claude) else {
            if !authSuspect.isEmpty { authSuspect = [] }
            return
        }
        // 배지는 활성 계정 전용 신호 — 활성이 바뀌면 옛 계정의 잔여 배지를 정리한다.
        let stale = authSuspect.subtracting([active.id])
        if !stale.isEmpty { authSuspect.subtract(stale) }

        let holds = AuthSuspicion.cheapConditionsHold(
            lastActivityAt: watcher.lastActivity,
            storedExpiresAt: cachedStoredExpiry(for: active.id), now: now)
        guard holds else {
            if authSuspect.contains(active.id) { authSuspect.remove(active.id) }
            if notifiedSuspects.contains(active.id) {
                notifiedSuspects.remove(active.id); saveNotifiedSuspects()
            }
            return
        }
        // 조건 성립 — 이미 플래그면 여기서 끝(라이브 재검증은 5분 블록에서만).
        // 아직 미플래그면 아무것도 안 하고 종료(승격은 라이브 절반이 fresh sync 뒤에).
    }

    /// 배지 라이브 절반 — 이번 사이클에 **fresh sync가 성사된 뒤에만** 호출한다.
    /// 값싼 조건을 갱신된 캐시로 재확인하고, 여전히 성립하면 저장 secret을 직접 읽어(파일
    /// 읽기 — subprocess 아님) confirmed로 최종 판정한다. 참이면 배지에 넣고, 알림은
    /// notified 집합에 없을 때만 1회 보내고 집합에 추가·저장한다.
    private func recomputeBadgeLive(now: Date) {
        loadNotifiedSuspectsIfNeeded()
        guard let active = store.file.active(of: .claude) else { return }
        guard AuthSuspicion.cheapConditionsHold(
            lastActivityAt: watcher.lastActivity,
            storedExpiresAt: cachedStoredExpiry(for: active.id), now: now) else { return }
        // confirmed = 신선도 단언: 방금 동기화된 그 스냅샷을 그대로 읽는다(독립 라이브 읽기 아님).
        let liveExpiry = (try? store.secret(for: active.id))
            .flatMap { UsageFetcher.expiresAt(from: $0.keychainBlob) }
        guard AuthSuspicion.confirmed(liveExpiresAt: liveExpiry, now: now) else { return }
        authSuspect.insert(active.id)
        if !notifiedSuspects.contains(active.id) {
            notifiedSuspects.insert(active.id)
            saveNotifiedSuspects()
            notify(title: loc("인증 확인 필요"),
                   body: loc("%@ 계정의 세션이 도는데 로그인이 만료된 채예요. 카드의 '다시 로그인'을 눌러주세요.", active.nickname))
        }
    }

    let env: MobiusEnvironment
    let store: AccountStore
    let io: ClaudeConfigIO
    let codexIO: CodexConfigIO
    let switcher: Switcher
    let watcher: SessionLogWatcher<RateLimitHit>              // Claude 세션 로그
    let codexWatcher: SessionLogWatcher<CodexRateLimitStatus> // Codex 세션 로그
    let codexRouter = CodexStatusRouter() // 전환 전 세션 파일 격리 (계정 오귀속 방지)
    let engines: [Provider: AutoSwitchEngine] = [
        .claude: AutoSwitchEngine(provider: .claude),
        .codex: AutoSwitchEngine(provider: .codex),
    ]
    lazy var desktopSwitcher = DesktopSwitcher(env: env)
    lazy var desktopCoordinator = DesktopCoordinator(switcher: desktopSwitcher)
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var lastReconcileAt = Date.distantPast
    private var lastActiveSnapshotSyncAt = Date.distantPast
    static let reconcileInterval: TimeInterval = 15
    static let activeSnapshotSyncInterval: TimeInterval = 5 * 60 // 활성 계정 토큰 스냅샷 동기화
    // 만료 임박 폴백 자동 refresh: 1시간마다 스윕, 만료 3일 전부터, 계정당 최소 6시간 간격.
    private var lastProactiveRefreshSweepAt = Date.distantPast
    private var lastProactiveRefreshAt: [UUID: Date] = [:]
    static let proactiveRefreshSweepInterval: TimeInterval = 3600
    static let proactiveRefreshRenewWindow: TimeInterval = 3 * 24 * 3600
    static let proactiveRefreshPerAccountGate: TimeInterval = 6 * 3600
    // 만료 토큰 게이지용 refresh(reactive)의 계정당 재시도 쿨다운 — transient(네트워크/5xx)
    // 실패 시 usage 캐시가 안 갱신돼 계속 stale로 남으므로, 이게 없으면 팝오버를 여닫을
    // 때마다 회전 시도가 반복된다. 성공하면 즉시 해제(exp가 미래로 풀려 재진입도 자연히 멈춤).
    private var lastUsageRefreshAttemptAt: [UUID: Date] = [:]
    static let usageRefreshRetryCooldown: TimeInterval = 600

    /// 배지 의심 계정 — 카드 배지·'다시 로그인' 버튼 노출에만 쓴다(표시 전용).
    /// 무상태 판정(recomputeBadgeCheap/Live)이 채운다. ★ 절대 needsReauth로 승격하지 말 것
    /// (AuthSuspicion 주석 참조 — 이슈 #4 재발).
    @Published private(set) var authSuspect: Set<UUID> = []

    // MARK: 임계값 선제 전환 (advisory) 상태 — 전부 인메모리(스냅샷 아님)

    /// 후보 "없음" 마지막 판정 시각 — 엔진의 백오프 창(shouldProbeCandidates)에 넘긴다.
    /// distantPast로 시작. ★ advisory가 해제돼도 distantPast로 리셋하지 않는다 — 경계에서
    /// 켜졌다 꺼졌다 하는 오실레이션이 백오프를 매번 무장해제해 폴백을 계속 두드리는 것을 막는다.
    private var lastNoCandidateAt = Date.distantPast
    /// 계정별 "마지막으로 경고를 알린 창의 resetsAt". 같은 창에 중복 알림/전환을 막는
    /// 인트라세션 가드 — 창(resetsAt)이 바뀌면 다시 알린다. **영속하지 않는다.**
    private var lastAdvisedResetsAt: [UUID: Date] = [:]
    /// 활성 스냅샷 동기화가 연속으로 실패한 횟수 — 3회 도달 시 푸터 배너 힌트를 띄운다.
    /// ★ **활성 Claude 프로필이 있을 때만** 증가한다(Codex-only 풀·adopt 대기 오탐 방지).
    /// true 결과가 나오면 0으로 리셋. 영속하지 않는다.
    private var consecutiveSyncFailures = 0
    /// 활성 계정 사용량 **조회**가 연속 실패한 횟수(네트워크/타임아웃/5xx 등) — 위 동기화
    /// 실패(로컬)와 별개다. `UsagePollBreaker.failureThreshold` 도달 시 배경 폴링을 멈춘다
    /// (서킷 브레이커). 성공 시 0으로 리셋, 팝오버를 다시 열면(refreshUsageIfStale) 재개.
    /// 인메모리 — 앱 재시작도 재개 신호(사용자 결정 2026-07-21).
    private var consecutiveUsagePollFailures = 0

    /// 임계값 선제 전환 기능 토글(기본 꺼짐). 설정 UI가 같은 키를 쓴다.
    private var advisorySwitchEnabled: Bool {
        UserDefaults.standard.bool(forKey: "advisorySwitchEnabled")
    }
    /// ★ 유효 게이트 — 미리 전환은 '자동 전환(Claude)'의 하위 옵션이라 **부모가 켜져 있을
    /// 때만** 동작한다(사용자 결정 2026-07-24: 부모 off면 UI도 강제 off+disabled — 구 "표시만"
    /// 모드 제거). 폴링·pill 셋/클리어 모두 이 게이트를 본다 — 부모를 끄면 5분 폴링이 서고,
    /// 남은 advisory pill은 아래 정리 경로가 다음 틱에 걷어간다.
    private var advisoryEffectivelyEnabled: Bool {
        advisorySwitchEnabled && store.file.isAutoSwitchEnabled(.claude)
    }
    /// 임계값(%) — 기본 90. 설정 UI 범위 50~95(step 5). Int/Double 저장 모두 관대하게 읽는다.
    private var advisoryThreshold: Double {
        let raw = UserDefaults.standard.object(forKey: "advisoryThresholdPercent")
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        return 90
    }

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
        self.codexIO = CodexConfigIO(env: env)
        self.switcher = Switcher(env: env, keychain: kc, store: store, io: io,
                                 extraIOs: [codexIO])
        self.watcher = SessionLogWatcher(env: env)
        self.codexWatcher = SessionLogWatcher.codex(env: env)
        // 구버전 바이너리가 accounts.json을 저장하며 per-account provider를 드롭했다면 Codex 계정이
        // Claude 풀로 흡수돼 매 틱 자격증명 디코드 실패로 degraded 상태가 된다. secret이 provider의
        // authority이므로 로드 직후 진짜 provider로 되돌리고, 되돌린 게 있으면 사용자에게 경고한다.
        if let reassigned = try? switcher.healMisassignedProviders(), !reassigned.isEmpty {
            let names = reassigned
                .map { "\($0.nickname) (\($0.from.displayName)→\($0.to.displayName))" }
                .joined(separator: ", ")
            let warn = loc("구버전이 저장한 계정 목록에서 프로바이더 정보가 소실돼 복구했습니다: %@", names)
            initError = initError.map { "\($0)\n\(warn)" } ?? warn
        }
        self.file = store.file
        self.lastError = initError
        // init에서의 직접 대입은 didSet이 불리지 않는다 — TTL 기준점을 수동 기록
        if initError != nil { lastErrorAt = Date() }

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // 옛 연속-401 누적 배지 저장키를 1회 제거한다 — 무상태 판정으로 대체됐고, 남겨두면
        // 구버전 바이너리가 이 키를 읽어 유령 배지를 띄울 수 있다(의심 조건용 대체키는 없다).
        UserDefaults.standard.removeObject(forKey: "authFailuresV1")
        // 알림 중복 방지 집합은 한 번만 로드한다.
        loadNotifiedSuspectsIfNeeded()

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
        // 임계값 폴 서킷 브레이커 재개 지점 — 사용자가 앱을 다시 열었으니(네트워크가
        // 돌아왔을 가능성) 연속 실패 카운터를 풀어 배경 폴링을 재개시킨다(사용자 결정).
        consecutiveUsagePollFailures = 0
        loadUsageCacheIfNeeded()
        guard UserDefaults.standard.object(forKey: "showUsageGauges") == nil
                || UserDefaults.standard.bool(forKey: "showUsageGauges") else { return }
        guard usageTask == nil else { return }
        let now = Date()
        // Claude만 — Codex 게이지는 세션 로그에서 얻는다 (tick의 processCodexBatches).
        // needsReauth 계정도 계속 조회한다 — CLI에서 직접 `claude auth login`으로 복구하는
        // 경우, 조회가 200이면 그 복구를 감지해 needsReauth를 자동으로 푼다(아래 성공 경로).
        // 여전히 401이면 `!profile.needsReauth` 가드가 재알림을 막으므로 스팸은 없다.
        let stale = store.file.accounts.filter {
            $0.provider == .claude &&
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
                // 비활성 계정의 저장 access 토큰이 만료됐으면 게이지를 못 읽어 얼어붙는다
                // (429/401 → 조용히 continue). 폴백 refresh 기계로 미리 갱신한다 — 활성은
                // check의 첫 guard가 절대 건드리지 않고, 회전 토큰은 원자 저장되며,
                // refresh 토큰이 만료/폐기면 needsReauth로 마킹된다(계정당 access TTL≈1h라
                // 갱신 후엔 만료 조건이 풀려 재-refresh가 자연히 멈춘다 = 스톰 없음).
                var fetchBlob = blob
                if !isActive, !profile.needsReauth,
                   let exp = UsageFetcher.expiresAt(from: blob), exp <= now {
                    // 계정당 쿨다운: 최근 시도가 있으면 이번 라운드는 아예 건너뛴다(만료 토큰이라
                    // 어차피 게이지도 못 읽는다). transient 실패가 팝오버마다 회전 시도로 반복되지
                    // 않게 하는 것 — 첫 시도는 게이팅 안 됨(distantPast)이라 프리즈 해소는 유지.
                    guard now.timeIntervalSince(lastUsageRefreshAttemptAt[profile.id] ?? .distantPast)
                            >= Self.usageRefreshRetryCooldown else { continue }
                    lastUsageRefreshAttemptAt[profile.id] = now
                    switch await fallbackChecker.check(profile.id,
                                                       activeAccountID: store.file.activeAccountID,
                                                       now: now, allowNetwork: true) {
                    case .refreshedAlive:
                        lastUsageRefreshAttemptAt[profile.id] = nil   // 성공 — 쿨다운 해제
                        if let fresh = (try? store.secret(for: profile.id))?.keychainBlob {
                            fetchBlob = fresh
                        }
                    case .dead, .storeFailed:
                        // **네트워크로만 알 수 있는** 죽음(invalid_grant / 저장 실패) — 매 팝오버
                        // 함께 도는 validateFallbacksLocally는 로컬 검사(allowNetwork:false)라
                        // 못 잡는다. 여기서 알림을 전담한다(check가 이미 needsReauth 마킹).
                        reauthChanged = true
                        notify(title: loc("재로그인 필요"),
                               body: loc("%@ 계정의 인증이 만료됐어요. 카드의 '다시 로그인'을 눌러주세요.", profile.nickname))
                        continue
                    case .locallyDead, .noRefreshToken:
                        // **로컬로 판정 가능**한 죽음 — 매 팝오버 함께 도는 validateFallbacksLocally가
                        // 알림을 전담하므로(같은 계정에 알림 2개 방지) 여기선 알리지 않는다.
                        // check가 켠 needsReauth 반영(reload)만 하고 조용히 스킵.
                        reauthChanged = true
                        continue
                    case .transient, .notFallback, .noSecret:
                        continue   // 갱신 실패/불가 — 쿨다운 뒤 재시도
                    }
                }
                do {
                    guard let snap = try await UsageFetcher.fetch(keychainBlob: fetchBlob)
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
                    // 단 자연 만료 토큰의 401은 **활성/비활성 모두** 오탐이라 마킹하지 않는다 —
                    // 활성도 잠자기 등으로 claude가 안 돌면 라이브 토큰이 만료된 채 남는다
                    // (이슈 #4: 오마킹 → 엔진이 멀쩡한 주계정을 밀어내던 연쇄의 수정).
                    // 판정 규칙은 UsageFetcher.shouldMarkReauthAfterAuthError 참조.
                    // ★ 판정 대상은 fetchBlob: refresh 성공 시 fetchBlob은 신선한(유효) 토큰이라
                    //   그래도 401이면 폐기로 마킹, refresh를 안 한 경로면 fetchBlob==blob.
                    let marked = UsageFetcher.shouldMarkReauthAfterAuthError(blob: fetchBlob,
                                                                            isActive: isActive)
                        && !profile.needsReauth
                    if marked {
                        try? store.setNeedsReauth(profile.id, true)
                        reauthChanged = true
                        notify(title: loc("재로그인 필요"),
                               body: loc("%@ 계정의 인증이 만료됐어요. 카드의 '다시 로그인'을 눌러주세요.", profile.nickname))
                    }
                    // 위 규칙이 못 잡는 죽음(활성 계정의 진짜 폐기)은 이제 무상태 배지
                    // (AuthSuspicion.cheapConditionsHold/confirmed — recomputeBadgeCheap/Live)가
                    // 세션 활동 × 토큰 만료 상관으로 감지한다. 여기서 401을 누적하지 않는다.
                } catch { continue }   // 네트워크 오류 — 토큰 문제가 아니므로 누적하지 않는다
            }
            if reauthChanged {
                MobiusNotification.postAccountsChanged()
                reload()
            }
            saveUsageCache()
        }
    }

    /// codex 전환 직전, 진행 중인 비활성 게이지 refresh를 정지·완료대기시킨다 — 전환↔회전 HTTP
    /// 창(케이스2: 왕복 중 전환)을 닫는다. cancel()은 루프의 다음 계정 진입을 막아, 대기를 현재 처리
    /// 중인 계정의 진행 중 HTTP(refresh 후 probe까지 최대 2회 순차) 완료까지로 바운드한다.
    private func quiesceCodexUsageTask() async {
        codexUsageTask?.cancel()
        await codexUsageTask?.value
    }

    /// 팝오버가 열릴 때 호출 — **비활성 codex** 계정의 게이지를 네트워크로 조회한다(Claude의
    /// refreshUsageIfStale와 대칭). 활성 codex 계정은 세션 로그 in-band 경로(tick의
    /// processCodexBatches)가 그대로 담당하므로 제외한다 — processCodexBatches는 손대지 않는다.
    ///
    /// ★ **게이지 전용**: usage 캐시(usage[id])만 채운다. setNeedsReauth·엔진·rateLimit 기록을
    /// 절대 호출하지 않고(CodexUsageProber의 안전 계약), 자격증명은 저장 스냅샷 바이트를 읽기
    /// 전용으로만 쓴다(쓰기/refresh/codex 실행 없음). 401은 만료된 비활성 토큰이라 무해하게
    /// 게이지를 stale로 둔다. wham/usage는 codex가 이미 폴링하는 상태 엔드포인트라 추가 쿼터
    /// 부담이 없어(B1), showUsageGauges와 함께 기본 활성이다(별도 토글 없음 — Claude와 대칭).
    /// 신선도/쿨다운 기준은 usage[id].fetchedAt(영속됨) — 재시작 후에도 엔드포인트를 난타하지 않는다.
    func refreshCodexUsageIfStale() {
        loadUsageCacheIfNeeded()
        guard UserDefaults.standard.object(forKey: "showUsageGauges") == nil
                || UserDefaults.standard.bool(forKey: "showUsageGauges") else { return }
        guard codexUsageTask == nil else { return }
        let now = Date()
        let codexActiveID = store.file.activeByProvider[.codex]
        // 비활성 codex 계정 중 게이지 캐시가 만료된 것만. 활성은 로그 경로가 담당하므로 제외.
        let stale = store.file.accounts.filter {
            $0.provider == .codex && $0.id != codexActiveID &&
            (usage[$0.id]?.fetchedAt ?? .distantPast) < now.addingTimeInterval(-usageStaleness)
        }
        guard !stale.isEmpty else { return }
        codexUsageTask = Task { @MainActor in
            defer { codexUsageTask = nil }
            var updated = false
            for profile in stale {
                if Task.isCancelled { break }
                // 죽은 토큰 계정은 긴 백오프 동안 refresh/probe를 아예 건너뛴다(어차피 401 → 무의미).
                if let deadUntil = codexRefreshDeadUntil[profile.id], now < deadUntil { continue }
                // 저장된 auth.json 스냅샷 바이트를 읽는다. refresh 성공 시 아래에서 회전본으로 교체.
                guard let authJSON = try? store.secretData(for: profile.id) else { continue }
                var probeBytes = authJSON

                // 저장 access 토큰이 이미 만료됐으면 게이지를 못 읽어 얼어붙는다(GET엔 회전이 없어
                // 만료 토큰으로 조회하면 401만 받는다) → refresh로 미리 되살린다. **활성 계정은 절대
                // refresh하지 않는다**(락 밖 fresh-read로 활성/전환중 계정을 재확인).
                let liveActiveID = store.file.activeByProvider[.codex]
                if profile.id != liveActiveID, profile.id != pendingSwitchID,
                   let exp = CodexAuthBlob.accessTokenExpiry(fromAuthJSON: authJSON), exp <= now {
                    // 계정당 쿨다운: 최근 시도가 있으면 이번 라운드는 건너뛴다(만료 토큰이라 게이지도
                    // 어차피 못 읽는다). 첫 시도는 게이팅 안 됨(distantPast)이라 프리즈 해소는 유지.
                    guard now.timeIntervalSince(lastCodexRefreshAttemptAt[profile.id] ?? .distantPast)
                            >= Self.usageRefreshRetryCooldown else { continue }
                    lastCodexRefreshAttemptAt[profile.id] = now
                    let refreshOutcome = await Task { await codexRefresher.refresh(authJSON: authJSON) }.value
                    switch refreshOutcome {
                    case .refreshed(let rotated):
                        // ★ 원자 capture: credential lock 안에서 (1) 활성 재확인(TOCTOU — 그 사이
                        //   자동/수동 전환으로 활성이 됐으면 라이브 ~/.codex가 authoritative이므로
                        //   회전본을 버린다), (2) 신원/형태 검증(실패 기록 1/13 클래스: 손상·타 계정
                        //   바이트가 스냅샷을 덮어쓰지 않게), (3) 원자 저장. 하나라도 어긋나면 기존
                        //   스냅샷을 보존한다(덮어쓰지 않음).
                        let stored: Data? = store.withCredentialLock(profile.id) { () -> Data? in
                            guard profile.id != store.file.activeByProvider[.codex] else { return nil }
                            // 락 안에서 스냅샷을 다시 읽는다 — HTTP 왕복 중 adopt/재로그인이 끼면
                            // 신규 로그인 스냅샷을 구 세션 회전본으로 덮는 edge를 차단(회전본 폐기).
                            guard let current = try? store.secretData(for: profile.id),
                                  current == authJSON else { return nil }
                            guard codexIO.recognizesSecret(rotated),
                                  CodexConfigIO.email(fromAuthJSON: rotated) == profile.emailAddress,
                                  CodexTokenRefresher.refreshToken(fromAuthJSON: rotated)?.isEmpty == false
                            else { return nil }
                            do { try store.setSecretData(rotated, for: profile.id) } catch { return nil }
                            return rotated
                        }
                        guard let stored else { continue }   // 활성이 됨 / 검증 실패 — 이번 라운드 스킵
                        probeBytes = stored
                        lastCodexRefreshAttemptAt[profile.id] = nil   // 성공 — 쿨다운 해제
                        codexRefreshDeadUntil[profile.id] = nil
                    case .invalidated:
                        // 죽은 refresh 토큰(세션 종료) — 게이지 전용 방화벽: 엔진/persisted reauth를
                        // 절대 건드리지 않고, 긴 백오프(codexRefreshDeadUntil)만 남기고 stale로 둔다.
                        codexRefreshDeadUntil[profile.id] = now.addingTimeInterval(Self.codexDeadRefreshCooldown)
                        continue
                    case .transient:
                        // refresh POST는 위 Task {} 쉴드로 취소 비전파라 여기는 순수 네트워크/5xx다
                        // (우리 자신의 취소로 인한 transient는 이 분기에 도달할 수 없다).
                        continue   // 쿨다운 뒤 재시도(게이지는 마지막 값 유지)
                    }
                }

                // B1 게이지 조회 — (가능하면 갱신된) 바이트로. 읽기 전용, 아무것도 마킹하지 않는다.
                switch await codexProber.probe(authJSON: probeBytes, now: now) {
                case .usage(let snap):
                    usage[profile.id] = snap
                    updated = true
                case .stale, .transient:
                    continue   // 게이지를 마지막 스냅샷에 둔다 — 아무것도 마킹하지 않는다.
                }
            }
            if updated { saveUsageCache() }
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
        // Claude 전용: 이 checker는 Claude refresh 토큰 형태만 판정한다. Codex 계정이 새면
        // (a) 활성 제외 가드가 Claude activeAccountID 기준이라 활성 Codex가 우회될 수 있고
        // (b) 팝오버마다 Codex 계정 수만큼 불필요한 secret 디코드 시도가 돈다.
        let targets = store.file.accounts.filter { $0.provider == .claude && $0.id != active && !$0.needsReauth }
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

    /// 만료 임박한 폴백의 refresh 토큰을 미리 갱신한다 — refresh가 새 refresh 토큰(연장된
    /// 만료)을 주므로, 안 쓰던 폴백이 몇 주 뒤 조용히 죽는 것을 막는다. 폴백만(활성 제외),
    /// **만료 3일 이내**일 때만, 계정당 **6시간 이상 간격**으로만 호출(→ 블락 위험 미미).
    /// 성공하면 만료일이 멀어져 다음 스윕엔 대상에서 빠진다. 이미 만료/토큰없음이면
    /// checker가 네트워크 0으로 needsReauth 마킹.
    private func proactiveRefreshExpiringFallbacks(now: Date) async {
        let active = store.file.activeAccountID
        var changed = false
        // Claude 폴백만 — OAuth refresh는 Claude 자격증명 형식 전용이다. Codex 계정에
        // 이 검사를 돌리면 refresh 토큰을 못 읽어 잘못 needsReauth로 마킹된다.
        for p in store.file.accounts where p.provider == .claude && p.id != active && !p.needsReauth {
            guard let snap = try? store.secret(for: p.id),
                  let exp = CredentialBlob.refreshTokenExpiresAt(from: snap.keychainBlob),
                  exp.timeIntervalSince(now) < Self.proactiveRefreshRenewWindow,
                  (lastProactiveRefreshAt[p.id] ?? .distantPast)
                      < now.addingTimeInterval(-Self.proactiveRefreshPerAccountGate)
            else { continue }
            lastProactiveRefreshAt[p.id] = now
            let r = await fallbackChecker.check(p.id, activeAccountID: active, now: now, allowNetwork: true)
            switch r {
            case .refreshedAlive:
                changed = true
            case .dead, .locallyDead, .noRefreshToken, .storeFailed:
                changed = true
                notify(title: loc("재로그인 필요"),
                       body: loc("%@ 계정의 로그인이 만료됐어요. 카드의 '다시 로그인'을 눌러주세요.", p.nickname))
            default:
                break
            }
        }
        if changed { MobiusNotification.postAccountsChanged(); reload() }
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

    enum UpdateStatus: Equatable { case idle, checking, upToDate, available(ReleaseInfo), downloading, failed }
    @Published var updateStatus: UpdateStatus = .idle

    /// 최신 DMG를 앱에서 직접 내려받아 마운트한다(브라우저 의존 없이). 드래그 한 번으로 교체.
    /// 실패하면 릴리즈 페이지를 연다. (실행 중 앱을 프로그램으로 바꿔치는 자동 교체는 위험해서
    /// 하지 않는다 — 안전하게 마운트까지만.)
    func downloadUpdate(_ info: ReleaseInfo) {
        guard let dmg = URL(string:
            "https://github.com/chussum/mobius/releases/download/v\(info.version)/Mobius-\(info.version).dmg")
        else { openReleasePage(info); return }
        updateStatus = .downloading
        Task { @MainActor in
            defer { updateStatus = .available(info) }
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: dmg)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let dest = dir.appendingPathComponent("Mobius-\(info.version).dmg")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                NSWorkspace.shared.open(dest)   // DMG 마운트 → 설치 창(드래그)
            } catch {
                openReleasePage(info)           // 실패 시 릴리즈 페이지로 폴백
            }
        }
    }

    private func openReleasePage(_ info: ReleaseInfo) {
        if let u = URL(string: info.url) { NSWorkspace.shared.open(u) }
    }
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
        let pools = Provider.allCases.filter { !file.accounts(of: $0).isEmpty }
        guard pools.contains(where: { file.active(of: $0) != nil }) else { return .unknown }
        func poolExhausted(_ provider: Provider) -> Bool {
            file.accounts(of: provider).allSatisfy { $0.isLimited(now: now) || $0.needsReauth }
        }
        // 빨강 = 모든 풀이 막혀 어디서도 작업 불가.
        if pools.allSatisfy(poolExhausted) { return .allExhausted }
        // 주계정에 머무는 중인 풀은 알람색 아님 — 사용자가 직접 주계정을 선택했을 때
        // (Fable 등 일부 한도만 소진돼도) 알람색으로 보이지 않게(upstream 293a911 반영).
        // 어떤 풀이든 fallback에 활성이면 주황. (진짜 소진이면 자가복구가 fallback으로 옮긴다.)
        if pools.contains(where: { provider in
            guard let active = file.active(of: provider) else { return false }
            return active.id != file.primary(of: provider)?.id
        }) { return .fallbackActive }
        return .primaryActive
    }

    // MARK: 주기 처리

    func tick() async {
        checkForUpdates() // 내부에서 24시간 게이트 — 실제 조회는 하루 1회
        syncNow()         // 내부에서 15분 게이트 — 켜져 있을 때만 동작
        // 오래된 푸터 에러 자동 소거 (TTL 5분)
        if let at = lastErrorAt, Date().timeIntervalSince(at) >= Self.lastErrorTTL {
            lastError = nil
        }
        let now = Date()
        // 임계값 기능이 유효하지 않으면(토글 off 또는 부모 '자동 전환' off) 남아있는 advisory를
        // 매 틱 정리한다 — **가드 위**에서 도는 값싼 로컬 정리라 라이브 자격증명을 안 건드린다
        // (로그인 플로우 감지와 경합 없음). 잔재 없음을 보장해, 꺼져 있는데 옛 advisory가
        // primary 복귀를 막거나 pill이 얼어붙는 일이 없게.
        if !advisoryEffectivelyEnabled { clearAdvisoriesIfFeatureOff() }
        // 로그인 창이 열려 있는 동안은 reconcile/자동 전환이 LoginFlow의
        // 자격증명 변경 감지와 경합하지 않도록 전체를 건너뛴다.
        // Desktop 가이드 캡처 중에도 동일 — 자동 전환이 Desktop을 재실행하면
        // 사용자가 로그인 중인 창을 죽이고 감시 신호를 오염시킨다.
        guard loginFlow == nil, desktopCapture == nil else { return }
        // 배지 값싼 절반 — 가드 바로 아래(IO 0). 라이브 재검증은 5분 블록에서만.
        recomputeBadgeCheap(now: now)
        // reconcile/adopt는 15초마다만 — 3초 틱에 매번 돌리면 Keychain 접근이 잦아진다.
        // reconcile은 항상 라이브(실제 자격증명)를 진실로 삼아 active를 맞춘다 — active 마커가
        // 라이브와 어긋나면 UI가 /status와 달라지는 더 나쁜 버그가 된다(유예는 넣지 않는다).
        if now.timeIntervalSince(lastReconcileAt) >= Self.reconcileInterval {
            lastReconcileAt = now
            let activeBefore = store.file.activeByProvider
            _ = try? await switcher.adoptLiveAccountIfUnregistered()
            try? await switcher.reconcile()
            // 외부 요인(재로그인, 또는 구 세션의 토큰 리프레시가 자격증명 파일을 되돌리는
            // 클로버 — Codex 실측)으로 활성이 바뀌면 조용히 넘어가지 않고 알린다.
            for provider in Provider.allCases {
                let after = store.file.activeByProvider[provider]
                guard activeBefore[provider] != after, activeBefore[provider] != nil,
                      let name = store.file.accounts.first(where: { $0.id == after })?.nickname
                else { continue }
                notify(title: loc("%@ 활성 계정이 밖에서 바뀌었어요", provider.displayName),
                       body: loc("외부 로그인 또는 실행 중 세션의 갱신으로 활성 계정이 %@(으)로 바뀌었습니다. 카드를 눌러 되돌릴 수 있어요.", name))
            }
        }
        // 활성 계정 스냅샷을 5분마다 라이브(갱신된 토큰)와 동기화 — 오래 쓰다 크래시해도
        // 스냅샷이 낡지 않게. reconcile은 활성 불변 시 되저장을 건너뛰므로 이 보강이 그 틈을 메운다.
        // 이 fresh 스냅샷을 배지 라이브 절반과 임계값 폴이 공유한다(5분 창당 라이브 자격증명
        // subprocess 1회로 묶는 통합 — 실패 기록 3 계열의 승인창 비용 절감).
        if now.timeIntervalSince(lastActiveSnapshotSyncAt) >= Self.activeSnapshotSyncInterval {
            lastActiveSnapshotSyncAt = now   // await 전에 설정 — 이 창 안 재진입 방지
            if await switcher.refreshActiveSnapshotIfStable() {
                consecutiveSyncFailures = 0     // 진짜 fresh write — 실패 카운터 리셋
                invalidateExpiryCache()         // 스냅샷 갱신 → 만료 캐시 재계산 유도
                recomputeBadgeLive(now: now)    // fresh 스냅샷으로 confirmed 최종 판정
                // 서킷 브레이커: 사용량 조회가 3연속 실패하면 배경 폴링을 멈춘다(네트워크
                // 이상 방어 — 이상 중엔 미리 전환 자체가 무의미). 재개는 팝오버 열기/재시작.
                if advisoryEffectivelyEnabled,
                   !UsagePollBreaker.isTripped(consecutiveFailures: consecutiveUsagePollFailures) {
                    await pollThreshold(now: now)
                }
            } else {
                // false = 이른 가드 실패(라이브 이메일이 등록 활성과 불일치) 또는 저장 실패.
                // ★ 활성 Claude 프로필이 실제로 있을 때만 실패로 센다 — Codex-only 풀이나
                //   Claude adopt 대기 상태는 첫 가드가 상시/일시적으로 false라, 이 게이트가
                //   없으면 멀쩡한 사용자에게 매 세션 유령 배너가 뜬다(finding LOW-breadcrumb-scope).
                if store.file.active(of: .claude) != nil {
                    consecutiveSyncFailures += 1
                    if consecutiveSyncFailures >= 3 {
                        lastError = loc("활성 계정 동기화가 계속 실패하고 있어요 — 자동 전환·배지가 잠시 지연될 수 있어요.")
                    }
                }
            }
        }
        // 만료 임박 폴백 자동 refresh (저빈도 스윕) — 안 쓰던 폴백이 조용히 죽는 것 방지.
        if now.timeIntervalSince(lastProactiveRefreshSweepAt) >= Self.proactiveRefreshSweepInterval {
            lastProactiveRefreshSweepAt = now
            await proactiveRefreshExpiringFallbacks(now: now)
        }

        // 로그 스캔은 메인 액터 밖에서 — Codex 세션 루트는 파일이 수만 개라
        // 열거+stat(실측 ~0.1s)가 UI를 막지 않게 한다. 워처는 자체 락으로 안전.
        let claudeWatcher = watcher, codexWatcher = self.codexWatcher
        let (claudeHits, codexBatches) = await Task.detached(priority: .utility) {
            (claudeWatcher.scan(now: now), codexWatcher.scanBatches(now: now))
        }.value

        // Claude: 세션 로그의 rate-limit 에러 이벤트.
        // 배치 내 모든 hit는 스캔 시점의 활성 계정에 귀속 —
        // 루프 중 전환이 일어나도 남은 hit(구 세션 로그)가 새 활성 계정에 오기록되지 않도록.
        // 주의(upstream 293a911): 인증 만료(authentication_failed) 로그는 "어느 계정" 것인지
        // 적혀 있지 않아 활성 계정에 오귀인된다 → needsReauth는 로그가 아니라 usage API 401
        // (계정별 토큰으로 조회 → 오귀인 불가)로만 판정한다(refreshUsageIfStale 참조).
        // 여기서는 rate-limit(창 소진)만 처리한다.
        let claudeActiveID = store.file.activeByProvider[.claude]
        var sawMonthlySpend = false
        for hit in claudeHits {
            // 월간 지출 한도(P3)는 창 소진이 아니다 — 기록하면 24h 폴백 오탐이 된다
            // (2026-07-13 실측: 플랜 창 여유 상태에서도 뜨고 세션은 정상 동작).
            // 단 창 소진과 겹치면 이 메시지가 우선 표시돼 창 소진을 가리므로 usage로 교차 확인.
            guard hit.kind == .window else { sawMonthlySpend = true; continue }
            recordHit(hit, on: claudeActiveID, now: now)
            await apply(engines[.claude]!.onRateLimitHit(file: store.file, hit: hit, now: now),
                        provider: .claude, now: now)
        }
        if sawMonthlySpend { await verifyWindowsAfterSpendLimit(accountID: claudeActiveID, now: now) }

        // Codex: 매 턴 실리는 rate_limits 상태 — 라우터가 전환 전 세션 파일을 걸러낸 뒤
        // 게이지 갱신 + 소진 판정 (네트워크 0)
        await processCodexBatches(codexBatches, now: now)

        for provider in Provider.allCases {
            await apply(engines[provider]!.onTick(file: store.file, now: now),
                        provider: provider, now: now)
        }
        file = store.file
    }

    private func recordHit(_ hit: RateLimitHit, on accountID: UUID?, now: Date) {
        guard let accountID else { return }
        try? store.update(accountID) {
            $0.rateLimit = RateLimitInfo(resetsAt: hit.effectiveResetsAt(now: now),
                                         recordedAt: now, modelScoped: hit.modelScoped)
        }
    }

    /// 월 지출(P3, extra-usage) 한도 이벤트의 교차 확인 — 이 메시지는 표시 우선순위(override)라
    /// 실제 막힌 한도의 신뢰 신호가 아니므로, usage로 5h/주간 창을 교차확인해 진짜 창 소진이면
    /// 실제 리셋 시각으로 기록하고 창 여유면 무시한다(applyVerifiedExhaustion).
    /// P3는 짧은 폭주로 온다(실측: 30초에 15개 세션 파일) — 캐시 우선 + 단일 인플라이트로
    /// 네트워크 호출을 억제하고, 이미 소진 기록이 있으면 건너뛴다.
    private var spendVerifyTask: Task<Void, Never>?

    private func verifyWindowsAfterSpendLimit(accountID: UUID?, now: Date) async {
        guard let accountID, spendVerifyTask == nil else { return }
        guard let account = store.file.accounts.first(where: { $0.id == accountID }),
              !account.isLimited(now: now) else { return }
        // 신선한 캐시가 있으면 네트워크 없이 판단
        if let cached = usage[accountID], now.timeIntervalSince(cached.fetchedAt) < usageStaleness {
            await applyVerifiedExhaustion(cached, accountID: accountID, now: now)
            return
        }
        // 활성 계정은 라이브 토큰으로 조회한다 — 저장 스냅샷은 앱 시작 직후 만료 토큰일 수 있고
        // (claude CLI가 라이브를 갱신), P3는 활성 계정 세션 로그에서 오므로 대개 활성 계정이다.
        let blob: Data
        if store.file.activeAccountID == accountID, let live = try? io.readLiveSnapshot() {
            blob = live.keychainBlob
        } else if let secret = try? store.secret(for: accountID) {
            blob = secret.keychainBlob
        } else { return }
        spendVerifyTask = Task { @MainActor in
            defer { spendVerifyTask = nil }
            guard let snap = try? await UsageFetcher.fetch(keychainBlob: blob)
            else { return }
            usage[accountID] = snap
            await applyVerifiedExhaustion(snap, accountID: accountID, now: Date())
        }
    }

    private func applyVerifiedExhaustion(_ snap: UsageSnapshot, accountID: UUID, now: Date) async {
        // P3(extra-usage 월 지출 한도) 메시지는 표시 우선순위(override)라 "무엇이 막혔는지"의
        // 신뢰 신호가 아니다(extra-usage가 차면 실제 원인인 다른 한도를 가린다 — 사용자 정정).
        // → usage로 5h/주간 창을 교차확인해 진짜 창 소진이면 실제 리셋 시각으로 기록하고,
        // 창 여유면 무시한다(계정은 창 안에서 계속 사용 가능). 프리미엄 유지 전환은 P3가 아니라
        // 모델 스코프 한도(scopedLimits/Fable) 기반으로 판단해야 하며 별도 후속이다.
        guard let hit = snap.exhaustionHit(now: now) else { return }
        recordHit(hit, on: accountID, now: now)
        await apply(engines[.claude]!.onRateLimitHit(file: store.file, hit: hit, now: now),
                    provider: .claude, now: now)
        file = store.file
    }

    private func processCodexBatches(_ batches: [SessionLogWatcher<CodexRateLimitStatus>.Batch],
                                     now: Date) async {
        // 라우터는 활성 변경 감지를 겸하므로 배치가 비어도 매 틱 호출한다
        // (CLI/외부 전환도 다음 틱에 격리가 반영되도록).
        let codexActiveID = store.file.activeByProvider[.codex]
        let routed = codexRouter.route(batches: batches,
                                       trackedFiles: codexWatcher.trackedFiles,
                                       activeID: codexActiveID)
        guard let codexActiveID else { return }
        if let latest = routed.latestUsage {
            usage[codexActiveID] = latest.usageSnapshot(fetchedAt: now)
        }
        for hit in routed.exhaustionHits {
            // 이미 한도 기록이 있으면 중복 처리하지 않는다 — codex는 매 턴 상태를 남기므로
            // 이 가드가 없으면 15초마다 알림·엔진 호출이 반복된다 (알림 폭풍).
            let active = store.file.accounts.first { $0.id == codexActiveID }
            guard let active, !active.isLimited(now: now) else { break }
            recordHit(hit, on: codexActiveID, now: now)
            await apply(engines[.codex]!.onRateLimitHit(file: store.file, hit: hit, now: now),
                        provider: .codex, now: now)
        }
    }

    // MARK: 임계값 선제 전환 (advisory)

    /// 임계값 기능이 꺼져 있을 때 남은 advisory를 정리한다 — 매 틱(가드 위)에서 값싸게 돈다.
    /// setAdvisory의 동등성 스킵 덕에 첫 정리 이후 반복 틱은 인메모리 스캔 비용만 든다(재저장 없음).
    private func clearAdvisoriesIfFeatureOff() {
        for p in store.file.accounts where p.provider == .claude && p.advisory != nil {
            try? store.setAdvisory(p.id, nil)
        }
    }

    /// 임계값 폴 — **5분 fresh sync 성사 뒤에만** 호출된다(활성 secret이 방금 갱신됨).
    /// 활성 Claude를 저장 secret으로 조회(라이브 2차 읽기 없음)해 사용률을 얻고, 히스테리시스로
    /// advisory를 set/clear한 뒤, advisory가 유효하면 후보 탐색→엔진 판정→결정 적용을 한다.
    private func pollThreshold(now: Date) async {
        // 재인증 필요/저장 secret 없으면 스킵(secret은 5분 블록이 방금 동기화했다).
        guard let active = store.file.active(of: .claude), !active.needsReauth,
              let blob = (try? store.secret(for: active.id))?.keychainBlob else { return }
        // 저장 secret으로 조회 — 방금 fresh sync됐으므로 라이브를 한 번 더 읽지 않는다.
        // 실패(네트워크/타임아웃/5xx 등)는 서킷 브레이커 카운터를 올린다. 3연속이면 위
        // 5분 블록이 다음부터 폴을 건너뛴다. 성공하면 0으로 리셋.
        guard let snap = try? await UsageFetcher.fetch(keychainBlob: blob) else {
            consecutiveUsagePollFailures += 1
            return
        }
        consecutiveUsagePollFailures = 0
        usage[active.id] = snap
        // await 뒤 활성이 바뀌었을 수 있다 — 재확인.
        guard let current = store.file.active(of: .claude), current.id == active.id else { return }

        let threshold = advisoryThreshold
        let util = snap.fiveHourPercent ?? 0

        // 히스테리시스 set/clear. set: 임계값 이상 + 리셋 시각 존재 → detectedAt 보존해 세운다.
        // clear: 밴드 아래(임계값-5 이하) + 기존 advisory 존재 → 해제하되 백오프·last-advised
        //        맵은 **건드리지 않는다**(새 창은 resetsAt이 달라 자연히 재알림된다).
        // 그 사이(밴드 내부)면 그대로 둔다.
        if AdvisoryRecord.shouldSet(utilization: util, threshold: threshold),
           let resetsAt = snap.fiveHourResetsAt {
            let detectedAt = current.advisory?.detectedAt ?? now  // 이미 있었으면 첫 시각 보존
            try? store.setAdvisory(active.id,
                AdvisoryRecord(utilization: util, resetsAt: resetsAt, detectedAt: detectedAt))
        } else if AdvisoryRecord.shouldClear(utilization: util, threshold: threshold),
                  current.advisory != nil {
            try? store.setAdvisory(active.id, nil)
        }
        // else(밴드 내부 or advisory 없음): advisory 필드는 그대로 둔다.

        // advisory가 여전히 유효한 경우에만 후보 탐색 + 엔진 판정 + 알림/전환.
        guard let advised = store.file.active(of: .claude), advised.id == active.id,
              let advisory = advised.advisory else { return }

        let engine = engines[.claude]!
        var verifiedCandidate: UUID?
        // 후보 탐색은 "전환 가능(switch-eligible)"할 때만 — 풀 자동 전환이 켜져 있고(스펙 AC3:
        // 폴백은 switch-eligible probe에서만 읽는다) 백오프 창을 지났을 때. 자동 전환이 꺼져
        // 있으면 후보는 알림 경로에서 쓰이지 않으므로 탐색(네트워크)도 생략한다.
        if store.file.isAutoSwitchEnabled(.claude),
           engine.shouldProbeCandidates(lastNoCandidateAt: lastNoCandidateAt, now: now) {
            verifiedCandidate = await probeCandidate(now: now)
            // 후보 있으면 백오프 리셋(distantPast=즉시 재탐색 허용), 없으면 now(백오프 시작).
            // ★ 여기서만 리셋한다 — advisory clear에서는 절대 리셋하지 않는다(오실레이션 방어).
            lastNoCandidateAt = verifiedCandidate != nil ? .distantPast : now
            // 후보 탐색(네트워크) 중 활성이 바뀌었을 수 있다 — 재확인.
            guard let still = store.file.active(of: .claude), still.id == active.id else { return }
        }

        // ★★★ 로드-베어링 순서 (finding MEDIUM-notify-ordering) — 절대 재배열 금지.
        // "맵을 먼저 쓰고 플래그를 계산"하면 비교가 항상 같아져 alreadyAdvised가 영원히 true가
        // 되고, 토글-off 알림(notifyAdvisoryOnly)이 영구히 삼켜진다(엔진 테스트는 플래그를
        // 파라미터로 주입받아 초록으로 남는다 — 캡처-비교-호출-쓰기 순서로만 잡힌다).
        //   1) 직전 last-advised resetsAt을 **맵 쓰기 전에** 지역 변수로 포착한다.
        let priorAdvised = lastAdvisedResetsAt[active.id]
        //   2) 포착한 지역 값과 이번 advisory의 resetsAt을 비교해 alreadyAdvised를 계산한다.
        let alreadyAdvised = priorAdvised == advisory.resetsAt
        //   3) 엔진 판정을 호출하고 결정을 적용한다.
        let decision = engine.checkAdvisory(file: store.file, activeID: active.id,
                                            verifiedCandidate: verifiedCandidate,
                                            alreadyAdvised: alreadyAdvised, now: now)
        await apply(decision, provider: .claude, now: now)
        //   4) **그런 다음에야** 이번 폴의 resetsAt을 맵에 쓴다(토글 상태 무관).
        lastAdvisedResetsAt[active.id] = advisory.resetsAt
    }

    /// advisory가 걸린 활성 계정의 폴백 후보를 우선순위대로 검증한다. 임계값 미만인 첫 후보의
    /// id를 반환(없으면 nil). ★ **네트워크 refresh는 `.escalate`(만료+쿨다운경과)에서만** —
    /// AppState:225-232의 검증된 가드를 그대로 미러링한다(멀쩡한 폴백 토큰을 회전시켜 벽돌
    /// 만들지 않도록). 이 메서드는 배지 집합·notified 집합을 절대 건드리지 않고, checker가
    /// 스스로 하는 것 이상으로 needsReauth를 마킹하지 않는다(추가 알림도 없음 — stale sweep 전담).
    private func probeCandidate(now: Date) async -> UUID? {
        let threshold = advisoryThreshold
        let active = store.file.activeByProvider[.claude]
        for p in store.file.accounts where p.provider == .claude
            && p.id != active && !p.isLimited(now: now) && !p.needsReauth {
            guard let secret = try? store.secret(for: p.id) else { continue }
            var fetchBlob = secret.keychainBlob
            switch AutoSwitchEngine.candidateProbeAction(
                    expiresAt: UsageFetcher.expiresAt(from: fetchBlob),
                    now: now,
                    lastRefreshAttemptAt: lastUsageRefreshAttemptAt[p.id],
                    cooldown: Self.usageRefreshRetryCooldown) {
            case .skipCooldown:
                continue   // 만료 + 쿨다운 중 — 판정 없이 스킵(죽었다고 단정 금지)
            case .useStoredToken:
                break      // 저장 토큰 유효(또는 만료 정보 없음) — 네트워크 없이 아래서 조회
            case .escalate:
                // ★ 만료 + 쿨다운 경과일 때만 네트워크 refresh로 승격한다.
                lastUsageRefreshAttemptAt[p.id] = now
                switch await fallbackChecker.check(p.id, activeAccountID: active,
                                                   now: now, allowNetwork: true) {
                case .refreshedAlive:
                    lastUsageRefreshAttemptAt[p.id] = nil   // 성공 — 쿨다운 해제
                    guard let fresh = (try? store.secret(for: p.id))?.keychainBlob else { continue }
                    fetchBlob = fresh   // 회전된 신선한 토큰으로 조회
                default:
                    continue   // dead/storeFailed/locallyDead/noRefreshToken/transient 등 —
                               // checker가 이미 마킹, 추가 알림 없이 스킵(stale sweep 전담)
                }
            }
            guard let snap = try? await UsageFetcher.fetch(keychainBlob: fetchBlob) else { continue }
            usage[p.id] = snap
            if (snap.fiveHourPercent ?? 0) < threshold { return p.id }   // 임계값 미만 = 검증된 후보
        }
        return nil
    }

    private func apply(_ decision: Decision, provider: Provider, now: Date) async {
        switch decision {
        case .none: break
        case .allExhausted:
            notify(title: loc("%@ 모든 계정 한도 소진", provider.displayName),
                   body: loc("전환 가능한 계정이 없습니다. 리셋을 기다려주세요."))
        case let .notifyAdvisoryOnly(id):
            // 임계값 선제 경고 알림 — **소진이 아니다**(문구가 섞이면 거짓말). 자동 전환이
            // 꺼진 풀에서만 온다. 계정+창(resetsAt) 전이당 1회 — 엔진이 alreadyAdvised로
            // 걸러 이 케이스를 딱 한 번만 돌려주므로(pollThreshold의 last-advised 맵) 여기선
            // 무조건 알린다.
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: loc("⚠️ %@ 계정 한도가 가까워요", name),
                   body: loc("%@ 계정이 설정한 임계값에 도달했어요. 자동 전환이 꺼져 있으니 필요하면 직접 전환하세요.", name))
        case let .notifyExhaustedOnly(id):
            let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
            notify(title: loc("한도 소진 — 자동 전환이 꺼져 있습니다"),
                   body: loc("%@ 계정이 한도에 도달했습니다. 수동으로 전환하세요.", name))
        case let .switchTo(id, reason):
            // 전환 직전 검증(Claude 전용): 자동 폴백(activeExhausted)이나 임계값 선제
            // 전환(thresholdAdvisory)으로 넘어가기 전에 대상 계정을 실제 OAuth refresh로
            // 확인한다. 죽었으면 취소(마킹됨) → 다음 틱에 엔진이 다음 폴백을 고른다.
            // (Codex는 OAuth refresh 검증 경로가 없어 스킵한다.)
            let autoFromPrimary = reason == .activeExhausted || reason == .thresholdAdvisory
            if autoFromPrimary, provider == .claude {
                guard await preflightFallback(id, now: now) else { file = store.file; return }
            }
            let fromID = store.file.activeByProvider[provider]
            if provider == .codex { await quiesceCodexUsageTask() }
            do {
                try switcher.switchTo(id)
                engines[provider]?.noteSwitched(now: now)
                // 자동 전환의 결과인지 기록 — onTick의 primary 복귀는 이 플래그가
                // true일 때만 일어난다 (수동 전환 자동 회귀 방지). 임계값 선제 전환도
                // 자동 전환이므로 소진 전환과 동일하게 플래그를 세운다.
                try? store.setAutoSwitchedFromPrimary(autoFromPrimary, provider: provider)
                MobiusNotification.postAccountsChanged()
                let name = store.file.accounts.first { $0.id == id }?.nickname ?? "?"
                let fromName = store.file.accounts.first { $0.id == fromID }?.nickname
                switch reason {
                case .primaryRecovered:
                    notify(title: loc("✅ %@ 계정으로 복귀했어요", name),
                           body: loc("한도가 초기화돼 주 계정으로 돌아왔어요."))
                case .thresholdAdvisory:
                    // ★ 소진 표현 금지 — 아직 쓸 수 있는데 임계값에 가까워 미리 옮긴 것이다.
                    notify(title: loc("🔄 %@ 계정으로 미리 전환했어요", name),
                           body: loc("%@ 계정이 한도에 가까워져 여유 있는 %@(으)로 미리 전환했어요. 새로 시작하는 %@ 세션부터 적용돼요.",
                                     fromName ?? "?", name, provider.rawValue))
                case .activeExhausted:
                    notify(title: loc("🔄 %@ 계정으로 전환했어요", name),
                           body: loc("%@ 한도 소진 → %@. 새로 시작하는 %@ 세션부터 적용돼요.",
                                     fromName ?? "?", name, provider.rawValue))
                }
            } catch {
                lastError = loc("자동 전환 실패: %@", error.localizedDescription)
                return
            }
            // Desktop 자동 Fallback (Claude 전용): 옵션 켬 + 대상 스냅샷 존재 시에만
            if provider == .claude, store.file.desktopAutoSwitchEnabled {
                switchDesktopIfPossible(from: fromID, to: id)
            }
        }
    }

    // MARK: 사용자 액션

    func manualSwitch(to id: UUID) {
        guard let provider = store.file.accounts.first(where: { $0.id == id })?.provider else { return }
        let alreadyFlagged = store.file.accounts.first { $0.id == id }?.needsReauth ?? false
        // Codex는 OAuth refresh 검증 경로가 없고, 이미 재로그인 필요로 마킹된 계정은 사용자가
        // 의도적으로 고른 것이므로 — 두 경우 모두 preflight 없이 바로 전환한다.
        guard provider == .claude, !alreadyFlagged else {
            if provider == .codex {
                // 낙관적 표시 + ①a fresh-read 가드 강화(전환 대상 계정의 게이지 refresh를 스킵시킴).
                pendingSwitchID = id
                Task { @MainActor in
                    defer { pendingSwitchID = nil }
                    await quiesceCodexUsageTask()
                    performSwitch(to: id)
                }
            } else {
                performSwitch(to: id)   // 이미 재인증 필요로 마킹된 claude — preflight 없이 전환
            }
            return
        }
        // 낙관적 표시: 클릭 즉시 이 계정을 활성으로 보여줘 UI가 스무스하게 전환된 것처럼 보이게 한다.
        // 실제 refresh(대상이 아직 폴백일 때 — 안전) + 자격증명 스왑은 백그라운드에서.
        pendingSwitchID = id
        Task { @MainActor in
            defer { pendingSwitchID = nil }   // 완료되면 실제 activeAccountID가 표시를 인계
            guard await preflightFallback(id, now: Date()) else { reload(); return } // 죽음 → 취소(마킹됨)
            performSwitch(to: id)
        }
    }

    private func performSwitch(to id: UUID) {
        let provider = store.file.accounts.first { $0.id == id }?.provider ?? .claude
        let fromID = store.file.activeByProvider[provider]
        do {
            try switcher.switchTo(id)
            engines[provider]?.noteSwitched()
            // 사용자가 직접 고른 계정 — 모델 전용 한도(Fable 등)로 자동으로 밀어내지 않는다.
            try? store.setUserPinned(id)
            // 사용자의 의지로 전환 — 자동 복귀 대상이 아니다
            try? store.setAutoSwitchedFromPrimary(false, provider: provider)
            MobiusNotification.postAccountsChanged()
            reload()
        } catch {
            lastError = loc("전환 실패: %@", error.localizedDescription)
            return
        }
        // Desktop 동시 전환 (Claude 전용 — 옵션 켜짐 + 대상 스냅샷 존재 시)
        if provider == .claude, store.file.desktopSyncEnabled {
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

    func moveFallback(provider: Provider, from source: IndexSet, to destination: Int) {
        // List.onMove는 풀 계정 배열 인덱스로 호출한다 (primary 행 0은 moveDisabled).
        // destination은 "제거 전 삽입 위치"라 from보다 뒤면 1을 빼고, primary 위(0)로
        // 떨어뜨리면 첫 fallback 자리(1)로 고정한다 — 승격은 명시적 메뉴로만.
        guard let from = source.first else { return }
        var to = destination
        if to > from { to -= 1 }
        to = max(to, 1)
        guard from != to, from >= 1 else { return }
        try? store.moveFallback(provider: provider, fromIndex: from, toIndex: to)
        MobiusNotification.postAccountsChanged()
        reload()
    }

    func setAutoSwitch(_ on: Bool, provider: Provider) {
        try? store.setAutoSwitch(on, provider: provider)
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
                   body: loc("계정을 추가하려면 먼저 Claude Code CLI를 설치하세요. 설정 → 설치 현황에서 설치할 수 있어요."))
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
