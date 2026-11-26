import Foundation

/// 계정 × 모델 ID 의 마지막 관측값과 그때의 활성 세대.
public struct AntigravityBaseline: Equatable, Sendable {
    public var fraction: Double
    public var generation: Int
    public init(fraction: Double, generation: Int) {
        self.fraction = fraction; self.generation = generation
    }
}

/// Antigravity 자동 전환 판정(순수 함수, 설계 4.7).
///
/// **규칙 한 줄.** 지금 쓰던 모델(들)이 명시적인 0 이 되면, 그 모델 모두에 명시적인 여유가 확인된
/// 다음 계정으로 옮긴다. 소진 판정은 계정별 토큰으로 조회한 `fetchAvailableModels` 응답만 쓴다.
public enum AntigravityExhaustion {
    /// 같은 세대의 기준값이 0 보다 컸던 모델 가운데 이번 응답에서 **명시적인 0** 이 된 모델 집합 M.
    /// - 새 세대의 첫 관측은 기준값만 잡는다(이전 활성 기간의 값과 비교해 떠나지 않게).
    /// - 값 모름(remainingFraction 없음)과 행 빠짐은 트리거가 아니고, 기준값도 바꾸지 않는다.
    /// - 전이를 보지 못한 0 은 아무것도 하지 않는다.
    /// 활성 계정을 조회하는 **모든 경로**가 기준값을 바꾸기 전에 이 함수를 먼저 부른다.
    public static func evaluate(previous: [String: AntigravityBaseline],
                                current: AntigravityQuotaReport,
                                generation: Int) -> (trigger: Set<String>, next: [String: AntigravityBaseline]) {
        var next = previous
        var trigger = Set<String>()
        for m in current.models {
            guard let f = m.remainingFraction else { continue }
            if let prev = previous[m.id], prev.generation == generation, prev.fraction > 0, f == 0 {
                trigger.insert(m.id)
            }
            next[m.id] = AntigravityBaseline(fraction: f, generation: generation)
        }
        return (trigger, next)
    }

    /// 비활성 계정 조회·후보 확인은 판정하지 않고 기준값만 바꾼다.
    public static func baseline(from report: AntigravityQuotaReport, previous: [String: AntigravityBaseline],
                                generation: Int) -> [String: AntigravityBaseline] {
        var next = previous
        for m in report.models {
            guard let f = m.remainingFraction else { continue }
            next[m.id] = AntigravityBaseline(fraction: f, generation: generation)
        }
        return next
    }

    /// 트리거 M 의 기록. M 이 모두 풀려야 같은 쓰임으로 다시 후보가 되므로 resetTime 가운데
    /// **가장 늦은 것**을 쓴다. `modelScoped: true` 만 쓴다(계정 소진은 Antigravity 에 없다).
    public static func record(for trigger: Set<String>, report: AntigravityQuotaReport,
                              now: Date) -> RateLimitInfo? {
        let models = trigger.sorted()
        let resets = models.compactMap { report.model($0)?.resetTime }
        guard !models.isEmpty, let latest = resets.max() else { return nil }
        let names = Dictionary(uniqueKeysWithValues: report.models.compactMap { m in
            m.displayName.map { (m.id, $0) }
        })
        return RateLimitInfo(resetsAt: latest, recordedAt: now, modelScoped: true,
                             scopeModelIDs: models,
                             scopeLabel: AntigravityQuotaReport.label(forModelIDs: models,
                                                                      displayNames: names))
    }

    public enum CandidateVerdict: Equatable, Sendable {
        /// M 의 모델이 모두 응답에 있고 모두 명시적으로 0 보다 크다 → 전환한다.
        case headroom
        /// M 의 모델 가운데 명시적인 0 이 있다 → 전환하지 않고 제외한다(모델 ID → resetTime).
        case exhausted([String: Date])
        /// 행 빠짐·값 모름·조회 실패·확인 불가 → 전환하지 않고 쿨다운.
        case unverifiable
    }

    /// 후보 확인(설계 4.7). 같은 계열의 다른 모델 값으로 대신하지 않는다.
    public static func verifyCandidate(_ report: AntigravityQuotaReport?,
                                       models: Set<String>) -> CandidateVerdict {
        guard let report, !models.isEmpty else { return .unverifiable }
        var zero: [String: Date] = [:]
        var allHeadroom = true
        for id in models {
            guard let m = report.model(id) else { allHeadroom = false; continue }
            if m.isExplicitlyExhausted { zero[id] = m.resetTime }
            else if !m.hasExplicitHeadroom { allHeadroom = false }
        }
        if !zero.isEmpty { return .exhausted(zero) }
        return allHeadroom ? .headroom : .unverifiable
    }

    /// 아직 유효한 기록의 `scopeModelIDs` 가 M 과 겹치는 계정(모델 ID 로 비교).
    public static func accountsWithOverlappingRecords(in file: AccountsFile, provider: Provider,
                                                      models: Set<String>, now: Date) -> Set<UUID> {
        Set(file.accounts(of: provider).filter { p in
            guard let rl = p.rateLimit, rl.modelScoped, now < rl.resetsAt,
                  let ids = rl.scopeModelIDs else { return false }
            return !models.isDisjoint(with: ids)
        }.map(\.id))
    }
}

/// 자동 전환 작업이 await 를 건너는 동안 바뀌면 안 되는 값들(설계 4.7 「비동기 경합」).
public struct AntigravityExpectation: Equatable, Sendable {
    public let generation: Int
    public let liveFingerprint: Data?
    public let diskRevision: Int
    public let departure: UUID

    public init(generation: Int, liveFingerprint: Data?, diskRevision: Int, departure: UUID) {
        self.generation = generation; self.liveFingerprint = liveFingerprint
        self.diskRevision = diskRevision; self.departure = departure
    }

    /// 작업 시작 확인과 기대 상태 캡처를 **라이브 읽기 한 번**으로 한다. 활성 폴·팝오버·자가복구·
    /// 전환 직후 확인이 모두 조회(await) **전에** 부른다(설계 4.7 「비동기 경합」, 리뷰 1회차
    /// Claude P1-1·Codex P1-3). 조회 뒤에 다시 읽어 그 지문을 기대값으로 삼으면 조회 중에 끝난
    /// agy 로그인이 기대값이 되어 자동 전환이 그 로그인을 덮는다.
    /// - 읽은 바이트의 지문을 스토어에 먼저 알리고, **그 뒤의** 세대를 잡는다 — 같은 이메일로 다시
    ///   로그인한 직후 대사보다 이 읽기가 먼저 그 변화를 보면, 여기서 세대가 바뀌어 이전 로그인의 관측과
    ///   비교하지 않는다(리뷰 2회차 Codex P1-2). 그 뒤 대사가 세대를 또 올리면 holds 가 잡는다.
    /// - 라이브 바이트의 이메일이 출발 계정과 다르면(외부 로그인 직후, 로그아웃) nil — 이번 작업을
    ///   하지 않는다. 지문도 같은 바이트에서 계산한다.
    /// - 메인 밖에서 부를 수 있다(security CLI 호출, 최대 5초).
    public static func begin(departure: AccountProfile, store: AccountStore,
                             io: AntigravityConfigIO, decidedAt: Int? = nil) -> AntigravityExpectation? {
        guard let live = try? io.readLiveSecretData() else { return nil }
        let fingerprint = AntigravitySecret.fingerprint(live)
        let generation = store.noteLiveFingerprint(fingerprint, provider: .antigravity)
        // 엔진 결정을 먼저 내리고 작업을 시작하는 경로(자가복구)는 그 결정을 내린 세대를 넘긴다. 이 읽기가
        // 세대를 바꿨으면(같은 이메일 재로그인 등) 그 결정은 이전 로그인의 기록에서 나온 것이므로 버린다
        // (리뷰 3회차 Codex P1-2).
        if let decidedAt, decidedAt != generation { return nil }
        guard io.email(fromSecret: live) == departure.emailAddress,
              let disk = store.peekDisk(),
              disk.activeByProvider[.antigravity] == departure.id else { return nil }
        return AntigravityExpectation(generation: generation,
                                      liveFingerprint: fingerprint,
                                      diskRevision: disk.activeRevision(.antigravity),
                                      departure: departure.id)
    }

    /// 기대 상태가 그대로인가. 하나라도 다르면 기록·전환을 취소한다.
    /// - 활성 세대 번호, 라이브 키체인 바이트의 지문, 디스크의 활성 리비전과 활성 계정
    /// - (`forSwitch`) 디스크에서 다시 읽은 자동 전환 설정, 출발 계정의 소진 기록이 지금 시각
    ///   기준으로 유효한지, 그사이 더 새 관측에서 출발 계정의 M 이 0 보다 크게 보이지 않았는지
    /// 메인 밖(`Switcher.switchTo` 의 expectation)에서도 부르므로 잠금으로 보호된 값만 읽는다.
    public func holds(models: Set<String>, store: AccountStore, liveFingerprint current: Data?,
                      memory: AntigravityAutoSwitchMemory, forSwitch: Bool, now: Date) -> Bool {
        guard let disk = store.peekDisk() else { return false }
        return holds(models: models, store: store, disk: disk, liveFingerprint: current,
                     memory: memory, forSwitch: forSwitch, now: now)
    }

    /// 이미 읽은 디스크 사본 `disk` 로 판정한다 — `switchTo` 의 마지막 확인이 대상 등록과 같은 사본을
    /// 쓰도록(리뷰 3회차 Codex P1-3).
    public func holds(models: Set<String>, store: AccountStore, disk: AccountsFile, liveFingerprint current: Data?,
                      memory: AntigravityAutoSwitchMemory, forSwitch: Bool, now: Date) -> Bool {
        guard store.activeGeneration(of: .antigravity) == generation,
              current == liveFingerprint,
              disk.activeRevision(.antigravity) == diskRevision,
              disk.activeByProvider[.antigravity] == departure else { return false }
        guard forSwitch else { return true }
        guard disk.isAutoSwitchEnabled(.antigravity) else { return false }
        guard let p = store.file.accounts.first(where: { $0.id == departure }),
              let rl = p.rateLimit, rl.modelScoped, now < rl.resetsAt,
              let ids = rl.scopeModelIDs, !models.isDisjoint(with: ids) else { return false }
        let baseline = memory.baseline(departure)
        return !models.contains { (baseline[$0]?.fraction ?? 0) > 0 }
    }
}

/// Antigravity 자동 전환의 메모리 상태(재시작하면 비어서 시작한다). 앱이 한 인스턴스를 든다.
/// 판정 자체는 `AntigravityExhaustion` 의 순수 함수가 하고, 여기는 기억과 하한·쿨다운만 맡는다.
public final class AntigravityAutoSwitchMemory: @unchecked Sendable {
    /// 같은 후보는 10분에 한 번만 조회한다. 확인 불가 쿨다운과 후보 제외의 재확인 하한도 같다.
    public static let candidateProbeInterval: TimeInterval = 10 * 60
    /// 자동 전환으로 떠난 계정으로 라이브가 이 시간 안에 되돌아가면 왕복으로 본다.
    public static let roundTripWindow: TimeInterval = 6 * 3600

    private let lock = NSLock()
    private var baselines: [UUID: [String: AntigravityBaseline]] = [:]
    /// 계정 × 모델 후보 제외. `until` 은 재확인 하한(max(리셋, 지금 + 10분))이고, 알림 시각에는
    /// 하한을 섞지 않도록 실제 `reset` 을 따로 둔다(리뷰 1회차 Codex P2-6).
    private struct Exclusion { let until: Date; let reset: Date }
    private var exclusions: [UUID: [String: Exclusion]] = [:]
    private var lastProbeAt: [UUID: Date] = [:]
    private var unverifiableUntil: [UUID: Date] = [:]
    private var notifiedAllExhausted: Set<String> = []
    private var leftByAutoSwitch: (account: UUID, at: Date)?
    public private(set) var pausedUntil: Date?

    public init() {}

    // MARK: 기준값

    /// 활성 계정 관측: 판정하고 기준값을 바꾼다. 반환은 트리거 M.
    public func observeActive(_ account: UUID, report: AntigravityQuotaReport,
                              generation: Int) -> Set<String> {
        lock.withLock {
            let (m, next) = AntigravityExhaustion.evaluate(previous: baselines[account] ?? [:],
                                                           current: report, generation: generation)
            baselines[account] = next
            return m
        }
    }

    /// 비활성 계정 관측·후보 확인: 기준값만 바꾼다. 자동 전환으로 활성이 될 후보는 전환 뒤의
    /// 세대 번호로 넘겨받는다(설계 4.7 예외).
    public func observeInactive(_ account: UUID, report: AntigravityQuotaReport, generation: Int) {
        lock.withLock {
            baselines[account] = AntigravityExhaustion.baseline(
                from: report, previous: baselines[account] ?? [:], generation: generation)
        }
    }

    /// 기준값의 세대 번호를 바꿔 넘겨받는다(자동 전환 직후 — 후보 확인의 관측을 새 세대 기준으로).
    public func rebase(_ account: UUID, toGeneration generation: Int) {
        lock.withLock {
            guard var b = baselines[account] else { return }
            for k in b.keys { b[k]?.generation = generation }
            baselines[account] = b
        }
    }

    public func baseline(_ account: UUID) -> [String: AntigravityBaseline] {
        lock.withLock { baselines[account] ?? [:] }
    }

    // MARK: 후보 제외

    /// 엔진에 넘길 제외 집합: M 과 겹치는 유효 기록, 메모리 후보 제외(M 의 모델 하나라도),
    /// 확인 불가 쿨다운, 10분 조회 하한 안의 후보.
    public func excludedCandidates(file: AccountsFile, models: Set<String>, now: Date) -> Set<UUID> {
        var out = AntigravityExhaustion.accountsWithOverlappingRecords(
            in: file, provider: .antigravity, models: models, now: now)
        lock.withLock {
            for (id, byModel) in exclusions where byModel.contains(where: { models.contains($0.key) && now < $0.value.until }) {
                out.insert(id)
            }
            for (id, until) in unverifiableUntil where now < until { out.insert(id) }
            for (id, at) in lastProbeAt where now < at.addingTimeInterval(Self.candidateProbeInterval) {
                out.insert(id)
            }
        }
        return out
    }

    public func canProbe(_ account: UUID, now: Date) -> Bool {
        lock.withLock {
            guard let at = lastProbeAt[account] else { return true }
            return now >= at.addingTimeInterval(Self.candidateProbeInterval)
        }
    }

    public func noteProbe(_ account: UUID, now: Date) {
        lock.withLock { lastProbeAt[account] = now }
    }

    /// 후보 확인 결과를 반영한다. 0 이면 계정 × 모델 제외(해제 = max(resetTime, 지금 + 10분)),
    /// 확인 불가면 10분 쿨다운.
    public func apply(_ verdict: AntigravityExhaustion.CandidateVerdict, to account: UUID, now: Date) {
        lock.withLock {
            switch verdict {
            case .headroom:
                unverifiableUntil[account] = nil
            case .exhausted(let byModel):
                let floor = now.addingTimeInterval(Self.candidateProbeInterval)
                for (id, reset) in byModel {
                    exclusions[account, default: [:]][id] = Exclusion(until: max(reset, floor), reset: reset)
                }
            case .unverifiable:
                unverifiableUntil[account] = now.addingTimeInterval(Self.candidateProbeInterval)
            }
        }
    }

    /// 다른 후보가 모두 M 의 **명시적인 0** 으로 확인됐는가 — 확인할 수 없어서 빠진 후보가 있으면
    /// nil(알리지 않는다). 참이면 **M 을 모두 다시 쓸 수 있는 가장 이른 시각**을 준다: 계정마다 걸린
    /// 모델들의 리셋 가운데 가장 늦은 것을 구하고, 출발 계정(`active`, 소진 기록의 리셋)을 포함해 그
    /// 가운데 가장 이른 것을 고른다. 10분 재조회 하한은 섞지 않는다(리뷰 1회차 Codex P2-6).
    public func allOthersExplicitlyExhausted(file: AccountsFile, active: UUID, models: Set<String>,
                                             now: Date) -> Date? {
        let pool = file.accounts(of: .antigravity)
        let others = pool.filter { $0.id != active }
        guard !others.isEmpty else { return nil }
        func recordReset(_ p: AccountProfile) -> Date? {
            guard let rl = p.rateLimit, rl.modelScoped, now < rl.resetsAt,
                  let ids = rl.scopeModelIDs, !models.isDisjoint(with: ids) else { return nil }
            return rl.resetsAt
        }
        var usableAt: [Date] = []
        if let departure = pool.first(where: { $0.id == active }), let r = recordReset(departure) {
            usableAt.append(r)
        }
        return lock.withLock { () -> Date? in
            for p in others {
                let byModel = exclusions[p.id] ?? [:]
                // 재조회 하한으로만 남은 제외(리셋이 이미 지남)는 지금 유효한 소진 근거가 아니다
                // (리뷰 2회차 Codex P2-3) — 그런 후보만 남으면 "확인되지 않은 후보"로 보고 알리지 않는다.
                let hits = models.compactMap { id -> Date? in
                    guard let e = byModel[id], now < e.until, now < e.reset else { return nil }
                    return e.reset
                }
                if let r = recordReset(p) {
                    usableAt.append(([r] + hits).max()!); continue
                }
                guard !hits.isEmpty else { return nil }   // 확인되지 않은 후보 — 알리지 않는다
                usableAt.append(hits.max()!)
            }
            return usableAt.min()
        }
    }

    /// 같은 (모델 집합, 가장 이른 리셋)에 한 번만 알린다. 처음이면 true.
    public func shouldNotifyAllExhausted(models: Set<String>, earliestReset: Date) -> Bool {
        let key = models.sorted().joined(separator: ",") + "@\(Int(earliestReset.timeIntervalSince1970))"
        return lock.withLock { notifiedAllExhausted.insert(key).inserted }
    }

    // MARK: 왕복 차단

    public func noteAutoSwitchedAway(from account: UUID, at now: Date) {
        lock.withLock { leftByAutoSwitch = (account, now) }
    }

    /// 사용자가 앱에서 직접 전환하면 왕복 감시를 내린다 — 자동 전환으로 떠난 계정을 사용자가 다시
    /// 고른 것은 이전 세션의 되돌림이 아니다(리뷰 1회차 Claude P2-2).
    public func clearAutoSwitchedAway() {
        lock.withLock { leftByAutoSwitch = nil }
    }

    /// 라이브가 자동 전환으로 떠난 계정으로 6시간 안에 되돌아갔는가. 그렇다면 그 계정 기록의
    /// 리셋 시각까지 자동 전환을 멈춘다(반환: 멈춘 시각, 처음 감지했을 때만).
    /// 호출자는 **라이브를 따라간 대사가 활성을 바꾼 경우에만** 부른다 — 앱·CLI 의 Mobius 전환
    /// (디스크에서 다시 읽은 활성, 앱 수동 전환)은 되돌림이 아니다(리뷰 1회차 Claude P2-2).
    public func detectRoundTrip(newActive: UUID?, file: AccountsFile, now: Date) -> Date? {
        lock.withLock {
            guard let left = leftByAutoSwitch, left.account == newActive,
                  now < left.at.addingTimeInterval(Self.roundTripWindow) else { return nil }
            leftByAutoSwitch = nil
            let reset = file.accounts.first { $0.id == left.account }?.rateLimit?.resetsAt
            let until = max(reset ?? now, now.addingTimeInterval(Self.candidateProbeInterval))
            pausedUntil = until
            return until
        }
    }

    public func isPaused(now: Date) -> Bool {
        lock.withLock { pausedUntil.map { now < $0 } ?? false }
    }
}
