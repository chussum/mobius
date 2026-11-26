import Foundation
import MobiusCore

/// 설치된 agy 의 실제 바이너리·버전·client secret 후보. **agy 를 실행하지 않고** 파일만 읽는다
/// (agy 실행 위치를 제한하는 래퍼를 쓰는 환경이 있다 — 설계 4.3). 처음 쓸 때 한 번만 찾는다.
enum AntigravityInstallInfo {
    struct Resolved: Sendable {
        let launcher: String?
        let binary: URL?
        let version: String?
    }

    static let shared: Resolved = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let launcher = ToolInventory.locatePath("agy", fallbackPaths: [
            "/opt/homebrew/bin/agy", "/usr/local/bin/agy", "\(home)/bin/agy",
        ])
        let binary = launcher.flatMap { AntigravityInstall.resolveBinary(from: URL(fileURLWithPath: $0)) }
        let version = binary.flatMap { AntigravityInstall.version(fromBinaryPath: $0.path) }
        return Resolved(launcher: launcher, binary: binary, version: version)
    }()

    static var userAgent: String { AntigravityUsageFetcher.userAgent(version: shared.version) }

    /// 바이너리 안의 client secret 후보. 못 찾으면 빈 배열 — 그때는 토큰을 갱신하지 않는다.
    static func clientSecretCandidates() -> [String] {
        guard let binary = shared.binary else { return [] }
        return AntigravityInstall.clientSecretCandidates(inBinary: binary)
    }
}

extension AppState {
    // MARK: 상수

    static let agyPollInterval: TimeInterval = 5 * 60
    static let agyRecentUseWindow: TimeInterval = 30 * 60
    static let agyDeadBackoff: TimeInterval = 24 * 3600

    var agyAutoSwitchEnabled: Bool { store.file.isAutoSwitchEnabled(.antigravity) }

    /// 최근 30분 안에 agy 를 썼는가 — `history.jsonl` 수정 시각(사용자 입력 때만 쓰인다).
    func agyRecentlyUsed(now: Date) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: env.antigravityHistoryFile.path),
              let m = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(m) <= Self.agyRecentUseWindow
    }

    // MARK: 틱 배선

    /// Antigravity 풀의 15초 대사(adopt·reconcile)를 공통 틱이 기다리지 않는 작업에서 돌린다 —
    /// security 5초 제한이 걸려도 Claude·Codex 의 대사·엔진 처리가 밀리지 않는다(리뷰 1회차 Codex
    /// P2-1). 진행 중이거나 수동 전환이 쓰는 중이면 이번 주기는 건너뛴다(다음 15초에 다시 한다).
    func startAgyReconcile(now: Date) {
        guard agyReconcileTask == nil, agyManualTask == nil else { return }
        let switcher = self.switcher
        agyReconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.agyReconcileTask = nil }
            let (_, adoptFailed) = await switcher.adoptLiveAccountsIsolated(providers: [.antigravity])
            let (reconcileFailed, followed, filledEmpty) =
                await switcher.reconcileIsolatedReportingFollowed(providers: [.antigravity])
            let failed = adoptFailed[.antigravity] != nil || reconcileFailed[.antigravity] != nil
            if failed { self.poolsFailedReconcile.insert(.antigravity) }
            else { self.poolsFailedReconcile.remove(.antigravity) }
            // 왕복 판정은 **대사가 직접 커밋한** 활성 변경만 받는다 — 작업 전후 비교로 하면 await 사이에
            // 앱이 다시 읽은 CLI 전환이나 자동 전환의 setActive 까지 센다(리뷰 2회차 Claude P3-1·Codex P2-2).
            self.agyAfterReconcile(failed: failed, followedLiveTo: followed[.antigravity], now: Date())
            // "밖에서 바뀌었어요" 알림도 대사가 직접 커밋한 변경으로만 낸다 — 겹친 자동 전환이나 다시 읽은
            // CLI 전환을 외부 로그인으로 알리지 않게(리뷰 3회차 Claude P3-1). 비어 있던 활성을 채운 것(구버전
            // 저장 뒤 복원)은 외부 로그인이 아니므로 알리지 않는다 — 복원 알림이 따로 뜬다(리뷰 4회차 Codex P3).
            if let id = followed[.antigravity], !filledEmpty.contains(.antigravity),
               let name = self.store.file.accounts.first(where: { $0.id == id })?.nickname {
                self.notify(title: loc("%@ 활성 계정이 밖에서 바뀌었어요", Provider.antigravity.displayName),
                            body: loc("외부 로그인 또는 실행 중 세션의 갱신으로 활성 계정이 %@(으)로 바뀌었습니다. 카드를 눌러 되돌릴 수 있어요.", name))
            }
            self.publishStoreFile()
        }
    }

    /// 대사 뒤에 부른다. 활성 세대가 바뀌었으면 "활성이 된 시각"을 지금으로 바꾸고, **라이브를 따라간
    /// 대사가** 자동 전환으로 떠난 계정으로 활성을 되돌렸으면 왕복 차단을 건다. 디스크에서 다시 읽은
    /// 활성(CLI 전환)과 앱 수동 전환은 대사를 거치지 않으므로 왕복으로 세지 않는다(리뷰 1회차 Claude P2-2).
    func agyAfterReconcile(failed: Bool, followedLiveTo newActive: UUID?, now: Date) {
        agyPoolFailed = failed
        agySyncGeneration()
        if let newActive,
           let until = agyMemory.detectRoundTrip(newActive: newActive, file: store.file, now: now) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            notify(title: loc("Antigravity 자동 전환을 멈췄어요"),
                   body: loc("이전 계정의 agy 세션이 계정을 되돌렸어요. 그 세션을 종료해 주세요. 자동 전환은 %@ 에 다시 동작해요.",
                             f.string(from: until)))
        }
        if store.restoredAfterLegacySave {
            store.acknowledgeLegacyRestore()
            notify(title: loc("Antigravity 설정을 되돌렸어요"),
                   body: loc("이전 버전이 계정 목록을 저장해 Antigravity 설정을 되돌렸어요. 계정은 복원했고 자동 전환은 꺼져 있어요."))
        }
    }

    /// 활성 세대가 바뀌었으면 "활성이 된 시각"을 지금으로 바꾼다. 대사(15초)뿐 아니라 매 틱 앞에서도
    /// 부른다 — CLI 전환 뒤 reload 처럼 대사 사이에 세대가 바뀌면, 옛 활성 시각으로 새 활성 계정의
    /// 이전 기록을 보고 떠나는 일이 생긴다(설계 4.7 「떠나기」).
    /// ★ 활성 시각은 호출자가 넘긴 시각이 아니라 **세대 변경을 관측한 지금**이다. 공통 틱은 시작할 때 잡은
    /// `now` 로 await 를 건너온 뒤 이 함수를 부르므로, 그 시각을 쓰면 await 사이에 쓰인 이전 로그인의 소진
    /// 기록이 새 세대의 활성 시각보다 새것이 되어 자가복구가 같은 이메일의 재로그인을 덮는다(리뷰 5회차
    /// Codex P1-3). 그래서 시각을 인자로 받지 않는다.
    func agySyncGeneration() {
        let gen = store.activeGeneration(of: .antigravity)
        guard gen != agyKnownGeneration else { return }
        agyKnownGeneration = gen
        agyActiveSince = Date()
    }

    /// 매 틱: 자동 전환 작업을 시작할지 정한다. 공통 틱은 이 작업을 기다리지 않는다(설계 4.7
    /// 「공통 틱과 분리」). 풀마다 진행 중 작업은 하나만 두고, 수동 전환이 쓰는 동안은 시작하지 않는다.
    func agyTick(now: Date) {
        agySyncGeneration()
        guard agyAutoTask == nil, agyManualTask == nil, !agyPoolFailed, !agyIO.isLiveStateUnknown,
              !agyMemory.isPaused(now: now), agyAutoSwitchEnabled,
              store.file.active(of: .antigravity) != nil else { return }
        // (A) 자가복구 — 이번 활성 기간에 쓰인 유효 기록이 있으면 엔진이 다음 후보를 고른다.
        //     작업 시작 확인이 실패한 뒤에는 10분 동안 다시 시도하지 않는다(리뷰 1회차 Claude P2-1).
        if now >= agyStartCheckRetryAt,
           let active = store.file.active(of: .antigravity),
           let rl = active.rateLimit, rl.modelScoped, now < rl.resetsAt,
           let ids = rl.scopeModelIDs, !ids.isEmpty {
            let models = Set(ids)
            // 결정을 내린 세대 — 작업 시작 읽기가 세대를 바꾸면(같은 이메일 재로그인) 이 결정을 버린다
            // (리뷰 3회차 Codex P1-2). 엔진에 넘기는 `agyActiveSince` 와 **같은 세대**여야 한다 — 스토어 값을
            // 다시 읽으면, 메인 밖의 대사가 그 사이 세대를 올린 경우 옛 활성 시각과 새 세대가 묶여 새 로그인을
            // 이전 로그인의 기록으로 덮는다(리뷰 4회차 Codex P1-2·Claude P2-1).
            let decidedAt = agyKnownGeneration
            let excluded = agyMemory.excludedCandidates(file: store.file, models: models, now: now)
            let decision = engines[.antigravity]!.onTick(file: store.file, now: now,
                                                         activeSince: agyActiveSince,
                                                         excludedIDs: excluded)
            if case .switchTo = decision {
                startAgyWork {
                    await $0.agyHandleDecision(decision, models: models, expectation: nil, decidedAt: decidedAt)
                }
                return
            }
        }
        // (B) 5분 폴 — 최근 30분 안에 agy 를 썼고 서킷 브레이커가 열려 있지 않을 때, 활성 계정 하나만.
        guard now.timeIntervalSince(agyLastPollAt) >= Self.agyPollInterval,
              agyRecentlyUsed(now: now),
              !UsagePollBreaker.isTripped(consecutiveFailures: agyConsecutivePollFailures) else { return }
        agyLastPollAt = now
        startAgyWork { await $0.agyObserveActive(fromPoll: true) }
    }

    private func startAgyWork(_ body: @escaping @MainActor (AppState) async -> Void) {
        guard agyAutoTask == nil, agyManualTask == nil else { return }
        agyAutoTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.agyAutoTask = nil; self.publishStoreFile() }
            await body(self)
        }
    }

    // MARK: 팝오버 게이지 (설계 4.3)

    /// 팝오버를 열 때: 캐시가 4분 넘은 Antigravity 계정을 조회한다. 활성 계정은 판정을 겸하므로
    /// 자동 전환 작업(풀당 하나)으로 넘기고, 비활성 계정은 여기서 기준값만 바꾼다.
    func refreshAntigravityUsageIfStale() {
        loadUsageCacheIfNeeded()
        agyConsecutivePollFailures = 0   // 서킷 브레이커 재개 지점(팝오버 열기)
        guard UserDefaults.standard.object(forKey: "showUsageGauges") == nil
                || UserDefaults.standard.bool(forKey: "showUsageGauges") else { return }
        let now = Date()
        let activeID = store.file.activeByProvider[.antigravity]
        let stale = store.file.accounts(of: .antigravity).filter {
            (usage[$0.id]?.fetchedAt ?? .distantPast) < now.addingTimeInterval(-usageStaleness)
        }
        guard !stale.isEmpty else { return }
        if let activeID, stale.contains(where: { $0.id == activeID }) {
            startAgyWork { await $0.agyObserveActive(fromPoll: false) }
        }
        let inactive = stale.filter { $0.id != activeID }
        guard agyUsageTask == nil, !inactive.isEmpty else { return }
        agyUsageTask = Task { @MainActor in
            defer { agyUsageTask = nil }
            var updated = false
            for p in inactive {
                guard let report = await agyFetchReport(for: p.id, now: now) else { continue }
                agyMemory.observeInactive(p.id, report: report,
                                          generation: store.activeGeneration(of: .antigravity))
                updated = true
            }
            if updated { saveUsageCache() }
        }
    }

    /// 저장 스냅샷으로 한 계정을 조회한다(계정 ID 로 꺼내므로 귀속이 구조적으로 정확하다).
    /// 게이지 캐시를 갱신하고 보고서를 돌려준다. 실패하면 nil(게이지는 마지막 값 — stale 표시).
    /// - Parameter retryCooldown: 직전 시도가 실패했으면 10분 동안 다시 조회하지 않는다(팝오버·후보).
    ///   5분 폴은 자기 간격과 서킷 브레이커로 조절하므로 끈다 — 켜 두면 쿨다운으로 건너뛴 폴까지
    ///   실패로 세어 브레이커가 실제 실패 두 번 만에 열린다.
    func agyFetchReport(for id: UUID, now: Date, retryCooldown: Bool = true) async -> AntigravityQuotaReport? {
        if let dead = agyDeadUntil[id], now < dead { return nil }
        if retryCooldown, let last = agyLastFetchAttempt[id],
           now.timeIntervalSince(last) < Self.usageRefreshRetryCooldown,
           (usage[id]?.fetchedAt ?? .distantPast) < last { return nil }   // 직전 시도가 실패 — 쿨다운
        agyLastFetchAttempt[id] = now
        guard let data = try? store.secretData(for: id), let cred = AntigravitySecret.parse(data)
        else { return nil }
        let tokens = agyTokens
        let tokenResult = await Task.detached { await tokens.accessToken(for: cred, now: now) }.value
        let token: String
        switch tokenResult {
        case .token(let t): token = t
        case .invalidGrant:
            // 게이지만 비우고 긴 백오프 — needsReauth·엔진은 건드리지 않는다(설계 4.3).
            agyDeadUntil[id] = now.addingTimeInterval(Self.agyDeadBackoff)
            clearUsage(for: id)
            return nil
        case .unavailable, .transient:
            return nil
        }
        // 설치 정보의 첫 초기화는 로그인 셸을 돌리므로 메인 액터에서 하지 않는다(리뷰 1회차 Codex P1-6).
        let userAgent = await Task.detached { AntigravityInstallInfo.userAgent }.value
        let transport = AntigravityUsageFetcher.defaultTransport(userAgent: userAgent)
        do {
            let report = try await AntigravityUsageFetcher.fetch(accessToken: token, transport: transport,
                                                                 now: Date())
            if report.hasUnknownFraction, !agyLoggedUnknownFraction {
                agyLoggedUnknownFraction = true
                // 실측 근거 수집(설계 4.3) — 값은 남기지 않고 모양만.
                NSLog("Mobius: Antigravity quotaInfo 에 remainingFraction 없이 resetTime 만 온 모델이 있다(값 모름으로 처리)")
            }
            setUsage(report.usageSnapshot(), for: id)
            agyLastFetchAttempt[id] = nil
            return report
        } catch {
            return nil
        }
    }

    // MARK: 활성 계정 관측과 판정 (설계 4.7)

    /// 작업 시작 확인 + 기대 상태 캡처(라이브 읽기 한 번, 메인 밖). **조회 await 전에** 부른다 —
    /// 조회 뒤에 잡으면 조회 중에 끝난 agy 로그인이 기대값이 된다(리뷰 1회차 Claude P1-1·Codex P1-3).
    /// 라이브 바이트의 이메일이 출발 계정과 다르면 nil(이번 작업을 하지 않는다 — 설계 4.7).
    func agyBeginWork(departure: AccountProfile, decidedAt: Int? = nil) async -> AntigravityExpectation? {
        let store = self.store, io = agyIO
        return await Task.detached {
            AntigravityExpectation.begin(departure: departure, store: store, io: io, decidedAt: decidedAt)
        }.value
    }

    /// 활성 계정 조회 → 판정 → (트리거면) 기록과 후보 확인. 5분 폴과 팝오버가 같은 함수를 쓴다.
    func agyObserveActive(fromPoll: Bool) async {
        let now = Date()
        guard let active = store.file.active(of: .antigravity) else { return }
        let expectation = await agyBeginWork(departure: active)
        guard let report = await agyFetchReport(for: active.id, now: now, retryCooldown: !fromPoll) else {
            if fromPoll { agyConsecutivePollFailures += 1 }
            return
        }
        if fromPoll { agyConsecutivePollFailures = 0 }
        saveUsageCache()
        // 작업 시작 확인이 실패했거나 조회 중 세대가 바뀌었으면 판정하지 않는다(다음 대사 뒤에).
        guard let expectation, store.activeGeneration(of: .antigravity) == expectation.generation,
              store.file.activeByProvider[.antigravity] == active.id else { return }
        let trigger = agyMemory.observeActive(active.id, report: report, generation: expectation.generation)
        guard !trigger.isEmpty else { return }
        await agyHandleTrigger(trigger, report: report, active: active, expectation: expectation)
    }

    /// 트리거 M: 조회 전에 잡은 기대 상태를 확인하고 기록한 뒤 엔진에 묻는다.
    func agyHandleTrigger(_ models: Set<String>, report: AntigravityQuotaReport,
                          active: AccountProfile, expectation: AntigravityExpectation) async {
        let now = Date()
        guard expectation.departure == active.id,
              let record = AntigravityExhaustion.record(for: models, report: report, now: now) else { return }
        // 기록 직전 재확인 — 하나라도 다르면 기록하지 않는다.
        guard agyExpectationHolds(expectation, models: models, requireRecord: false) else { return }
        do {
            try store.mutateFresh { f in
                guard let i = f.accounts.firstIndex(where: { $0.id == active.id }) else { return }
                f.accounts[i].rateLimit = record
            }
        } catch { return }
        publishStoreFile()
        let hit = RateLimitHit(resetsAt: record.resetsAt, kind: .window, modelScoped: true)
        let excluded = agyMemory.excludedCandidates(file: store.file, models: models, now: now)
        let decision = engines[.antigravity]!.onRateLimitHit(file: store.file, hit: hit, now: now,
                                                             excludedIDs: excluded)
        await agyHandleDecision(decision, models: models, expectation: expectation)
    }

    /// 엔진 결정을 적용한다. 전환이면 후보를 조회해 M 전체의 명시적 여유를 확인한 뒤에만 옮기고,
    /// 아니면 제외하고 다음 후보를 다시 묻는다.
    func agyHandleDecision(_ first: Decision, models: Set<String>,
                           expectation given: AntigravityExpectation?, decidedAt: Int? = nil) async {
        var decision = first
        guard let departure = store.file.active(of: .antigravity) else { return }
        // 왕복 차단·"모름" 상태 중에는 어느 경로(폴·팝오버·자가복구)에서 왔든 전환하지 않는다.
        if case .switchTo = decision,
           agyMemory.isPaused(now: Date()) || agyIO.isLiveStateUnknown || agyPoolFailed { return }
        var expectation = given
        if case .switchTo = decision, given == nil {
            // 자가복구 경로도 후보 조회 전에 작업 시작 확인과 기대 상태 캡처를 거친다. 실패하면
            // 10분 동안 다시 시도하지 않는다 — 로그아웃 상태 등에서 3초마다 security 값 읽기를
            // 되풀이하지 않게(리뷰 1회차 Claude P2-1).
            expectation = await agyBeginWork(departure: departure, decidedAt: decidedAt)
            if expectation == nil {
                // 세대가 바뀌어 결정을 버린 경우는 쿨다운을 두지 않는다 — 새 세대에서 다시 판단한다.
                if decidedAt == nil || store.activeGeneration(of: .antigravity) == decidedAt {
                    agyStartCheckRetryAt = Date().addingTimeInterval(AntigravityAutoSwitchMemory.candidateProbeInterval)
                }
                return
            }
        }
        guard let expectation else { return }
        var tried = Set<UUID>()
        while case let .switchTo(candidate, _) = decision, !tried.contains(candidate) {
            tried.insert(candidate)
            let now = Date()
            guard agyMemory.canProbe(candidate, now: now) else { break }
            agyMemory.noteProbe(candidate, now: now)
            let report = await agyFetchReport(for: candidate, now: now)
            if let report {
                agyMemory.observeInactive(candidate, report: report, generation: expectation.generation)
                saveUsageCache()
            }
            let verdict = AntigravityExhaustion.verifyCandidate(report, models: models)
            agyMemory.apply(verdict, to: candidate, now: now)
            if verdict == .headroom {
                await agySwitch(to: candidate, models: models, expectation: expectation)
                return
            }
            let excluded = agyMemory.excludedCandidates(file: store.file, models: models, now: now)
                .union(tried)
            decision = engines[.antigravity]!.onTick(file: store.file, now: now,
                                                     activeSince: .distantPast, excludedIDs: excluded)
        }
        switch decision {
        case .notifyModelLimitedOnly:
            await apply(decision, provider: .antigravity, now: Date())
        case .none, .switchTo:
            // 갈 곳이 없다 — 후보가 모두 M 의 명시적인 0 으로 확인됐을 때만 알린다(같은 조합에 한 번).
            let now = Date()
            if let earliest = agyMemory.allOthersExplicitlyExhausted(file: store.file, active: departure.id,
                                                                     models: models, now: now),
               agyMemory.shouldNotifyAllExhausted(models: models, earliestReset: earliest) {
                let label = departure.rateLimit?.scopeLabel
                    ?? AntigravityQuotaReport.label(forModelIDs: models.sorted())
                let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
                notify(title: loc("Antigravity 한도"),
                       body: loc("모든 Antigravity 계정에서 %@ 한도가 찼어요. %@ 이후 다시 쓸 수 있어요.",
                                 label, f.string(from: earliest)))
            }
        default:
            break
        }
    }

    private func agyExpectationHolds(_ e: AntigravityExpectation, models: Set<String>,
                                     requireRecord: Bool) -> Bool {
        e.holds(models: models, store: store, liveFingerprint: agyIO.liveFingerprint,
                memory: agyMemory, forSwitch: requireRecord, now: Date())
    }

    /// 실제 전환. 라이브 쓰기 바로 앞에서 기대 상태를 다시 확인한다(`switchTo` 의 expectation).
    func agySwitch(to candidate: UUID, models: Set<String>, expectation: AntigravityExpectation) async {
        guard agyExpectationHolds(expectation, models: models, requireRecord: true) else { return }
        let switcher = self.switcher, store = self.store, io = agyIO, memory = agyMemory
        let result: Result<Void, Error> = await Task.detached {
            Result {
                // switchTo 가 대상 스냅샷을 읽고 되저장한 **뒤, 라이브 쓰기 바로 앞**에서 부른다.
                // 어댑터가 쓰기 직전에 읽은 값도 작업 시작 때 본 지문과 같아야 쓴다(Codex P1-3).
                // 기대 상태는 switchTo 가 마지막에 읽은 디스크 사본 하나로 본다(리뷰 3회차 Codex P1-3).
                try switcher.switchTo(candidate, expectedLiveFingerprint: expectation.liveFingerprint) { disk in
                    expectation.holds(models: models, store: store, disk: disk,
                                      liveFingerprint: io.liveFingerprint,
                                      memory: memory, forSwitch: true, now: Date())
                }
            }
        }.value
        let now = Date()
        switch result {
        case .failure(SwitcherError.expectationChanged):
            return   // 상태가 바뀌었다 — 조용히 취소(다음 대사·폴이 다시 판단한다)
        case .failure(let error):
            lastError = agySwitchErrorMessage(error, target: candidate)
            return
        case .success:
            break
        }
        // 새 세대로 시작하되, 후보 확인의 관측을 기준값으로 넘겨받는다(설계 4.7 예외).
        let gen = store.activeGeneration(of: .antigravity)
        agyKnownGeneration = gen
        agyActiveSince = now
        agyMemory.rebase(candidate, toGeneration: gen)
        agyMemory.noteAutoSwitchedAway(from: expectation.departure, at: now)
        engines[.antigravity]?.noteSwitched(now: now, forModelLimit: true, leftAccount: expectation.departure)
        // primary 복귀를 하지 않으므로 자동 전환 플래그를 세우지 않는다(설계 4.7).
        MobiusNotification.postAccountsChanged()
        publishStoreFile()
        let name = store.file.accounts.first { $0.id == candidate }?.nickname ?? "?"
        let label = store.file.accounts.first { $0.id == expectation.departure }?.rateLimit?.scopeLabel
            ?? AntigravityQuotaReport.label(forModelIDs: models.sorted())
        notify(title: loc("🔄 %@ 계정으로 전환했어요", name),
               body: loc("Antigravity 계정을 전환했어요(%@ 한도). 실행 중인 agy 세션은 다시 시작해야 새 계정이 적용돼요.", label))
        // 전환 직후 한 번 바로 조회한다(새 세대의 기준값은 넘겨받았으므로 전이를 볼 수 있다).
        // 이 확인도 조회 전에 기대 상태를 잡는다.
        if let active = store.file.active(of: .antigravity), active.id == candidate {
            let next = await agyBeginWork(departure: active)
            if let report = await agyFetchReport(for: candidate, now: Date()) {
                let trigger = agyMemory.observeActive(candidate, report: report, generation: gen)
                saveUsageCache()
                if !trigger.isEmpty, let next, next.generation == gen,
                   store.activeGeneration(of: .antigravity) == gen {
                    await agyHandleTrigger(trigger, report: report, active: active, expectation: next)
                }
            }
        }
    }

    func agySwitchErrorMessage(_ error: Error, target: UUID) -> String {
        let name = store.file.accounts.first { $0.id == target }?.nickname ?? "?"
        switch error {
        case SwitcherError.liveWrittenButSaveFailed:
            return loc("agy 는 %@(으)로 바뀌었지만 계정 목록 저장에 실패했어요.", name)
        case CLIKeychainError.timedOut where !agyIO.isLiveStateUnknown:
            // 쓰기 전 읽기에서 시간을 넘겼다 — 아무것도 쓰지 않았다(리뷰 1회차 Claude P3-4).
            return loc("agy 키체인이 응답하지 않아 전환하지 못했어요.")
        case CLIKeychainError.timedOut, AntigravityConfigError.liveStateUnknown:
            return loc("agy 키체인이 응답하지 않아 전환 결과를 확인하는 중이에요.")
        case AntigravityConfigError.liveFormatChanged:
            return loc("agy 키체인 값의 형식이 달라 전환을 멈췄어요. agy 를 업데이트했다면 Mobius 업데이트가 필요할 수 있어요.")
        default:
            return loc("전환 실패: %@", error.localizedDescription)
        }
    }

    // MARK: 수동 전환

    /// Antigravity 수동 전환 — 키체인 CLI 호출(최대 5초 제한)이 메인 스레드를 막지 않게 따로 돈다.
    /// ★ 풀당 쓰기 체인 하나(리뷰 1회차 Codex P1-4): 클릭마다 앞 작업(수동 전환, 자동 전환 작업,
    ///   Antigravity 대사)이 끝나길 기다린 뒤, **그사이 더 새 클릭이 없을 때만** 쓴다. 연속 클릭 B→C 가
    ///   같은 키체인 항목에 동시에 써서 마지막 선택 C 가 B 로 덮이는 일을 막는다.
    func manualSwitchAntigravity(to id: UUID) {
        pendingSwitchID = id
        agyManualSeq += 1
        let seq = agyManualSeq
        let previous = agyManualTask
        agyManualTask = Task { @MainActor in
            defer {
                if seq == agyManualSeq { agyManualTask = nil; pendingSwitchID = nil }
            }
            await previous?.value
            agyAutoTask?.cancel()
            await agyAutoTask?.value
            await agyReconcileTask?.value
            guard seq == agyManualSeq else { return }   // 더 새 클릭이 있다 — 그 요청만 쓴다
            guard store.file.accounts.contains(where: { $0.id == id && $0.provider == .antigravity })
            else { return }                              // 그사이 지워진 계정
            let switcher = self.switcher
            let result: Result<Void, Error> = await Task.detached {
                Result { try switcher.switchTo(id) }
            }.value
            if case .failure(let error) = result {
                // 키체인에는 썼고 목록 저장만 실패했으면 라이브는 사용자가 고른 계정이다 — 다음 대사가 그 계정을
                // 따라가도 이전 세션의 되돌림이 아니므로 감시를 내린다(리뷰 3회차 Codex P2-1).
                if case SwitcherError.liveWrittenButSaveFailed = error { agyMemory.clearAutoSwitchedAway() }
                lastError = agySwitchErrorMessage(error, target: id)
                reload()
                return
            }
            // 사용자가 고른 계정은 이전 세션의 되돌림이 아니다 — 감시는 전환이 **성공한 뒤에** 내린다
            // (실패한 전환이 감시를 미리 내리지 않게. 리뷰 2회차 Claude P3-1).
            agyMemory.clearAutoSwitchedAway()
            agyKnownGeneration = store.activeGeneration(of: .antigravity)
            agyActiveSince = Date()
            engines[.antigravity]?.noteSwitched()
            try? store.setUserPinned(id)
            try? store.setAutoSwitchedFromPrimary(false, provider: .antigravity)
            MobiusNotification.postAccountsChanged()
            reload()
        }
    }
}
