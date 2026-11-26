import Foundation

public enum SwitchReason: Equatable, Sendable {
    case activeExhausted    // 활성 계정 한도 소진
    case modelExhausted     // **모델 전용** 한도 소진 — 계정은 멀쩡하다(문구를 섞지 말 것)
    case primaryRecovered   // primary 리셋 도래 → 복귀
    case thresholdAdvisory  // 임계값 선제 경고 — **소진 아님** (알림 문구도 소진 표현 금지)
}

public enum Decision: Equatable, Sendable {
    case none
    case switchTo(UUID, reason: SwitchReason)
    case allExhausted       // 전환할 곳이 없음 → 알림만
    case notifyExhaustedOnly(UUID) // 자동 전환 꺼짐 — 소진된 활성 계정 알림만
    /// 자동 전환 꺼짐 — **모델 전용** 한도 알림만. notifyExhaustedOnly와 문구를 공유하면
    /// "계정 한도 소진"이라고 거짓말하게 된다(계정은 다른 모델로 계속 쓸 수 있다).
    case notifyModelLimitedOnly(UUID)
    /// 자동 전환 꺼짐 — 임계값 선제 경고 알림만. notifyExhaustedOnly와 **다른 케이스**다:
    /// 저쪽은 "이미 못 쓴다", 이쪽은 "아직 쓸 수 있는데 곧 찬다" — 문구가 섞이면 거짓말이 된다.
    case notifyAdvisoryOnly(UUID)
}

/// 후보 계정의 사용률을 확인하기 전에 "저장된 토큰을 그대로 쓸지 / 이번 사이클은 건너뛸지 /
/// 네트워크 refresh로 승격할지"를 정하는 순수 결정. 무조건 refresh를 쏘면 멀쩡한 폴백 토큰을
/// 코드베이스가 의도한 주기의 수십 배로 회전시켜 storeFailed로 벽돌 만들 수 있다 (CLAUDE.md의
/// 회전 실효 기록) — 그래서 "이미 만료된 토큰 + 계정별 쿨다운 경과"일 때만 승격한다.
public enum CandidateProbeAction: Equatable, Sendable {
    case useStoredToken   // 저장 토큰이 아직 유효(또는 만료 정보 없음) → 그대로 조회
    case skipCooldown     // 만료됐지만 쿨다운 중 → 이번 사이클 판정 없음(죽었다고 단정 금지)
    case escalate         // 만료 + 쿨다운 경과(또는 첫 시도) → 네트워크 refresh로 승격
}

/// 프로바이더별 엔진 규칙. Antigravity 는 규칙을 줄였다(설계 4.7, 2026-11-20 사용자 결정):
/// "쓰던 모델이 0 이 되면, 같은 모델에 여유가 확인된 다음 계정으로". 계정 전체 소진 판정과
/// 리셋 시각 기반 primary 자동 복귀는 두지 않는다.
public struct AutoSwitchPolicy: Equatable, Sendable {
    /// 모델 한도로 떠날 때 사용자 핀을 보지 않는다(Antigravity — 0절 사용자 결정).
    public var ignoresPinForModelLimit: Bool
    /// onTick (B) primary 자동 복귀를 하는가.
    public var returnsToPrimary: Bool
    /// 엔진 내장 `avoidModelLimited` 후보 필터를 쓰는가. Antigravity 는 호출자가 **모델 ID 로**
    /// 비교한 제외 집합을 넘기므로 쓰지 않는다.
    public var usesBuiltInModelLimitFilter: Bool
    /// 떠나기 조건: 활성 계정의 모델 한도 기록이 **그 계정이 활성이 된 시각 이후**에 쓰였고 아직
    /// 유효할 때만 떠난다(재시작 전·이전 활성 기간의 기록으로는 떠나지 않는다).
    public var leavesOnlyForRecordSinceActivation: Bool

    public static let standard = AutoSwitchPolicy(
        ignoresPinForModelLimit: false, returnsToPrimary: true,
        usesBuiltInModelLimitFilter: true, leavesOnlyForRecordSinceActivation: false)
    public static let antigravity = AutoSwitchPolicy(
        ignoresPinForModelLimit: true, returnsToPrimary: false,
        usesBuiltInModelLimitFilter: false, leavesOnlyForRecordSinceActivation: true)

    public static func `for`(_ provider: Provider) -> AutoSwitchPolicy {
        switch provider {
        case .claude, .codex: return .standard
        case .antigravity: return .antigravity
        }
    }
}

/// 순수 상태머신. 부작용 없음 — 호출자가 Decision을 실행하고 noteSwitched()로 알려준다.
/// 프로바이더 풀당 1인스턴스 — 쿨다운/복귀 판단이 풀별로 독립이다.
public final class AutoSwitchEngine: @unchecked Sendable {
    public let provider: Provider
    public let policy: AutoSwitchPolicy
    /// 전환 직후 재전환 금지 간격.
    ///
    /// ★ **실측 근거로 정한 값**(이슈 #19, @Phantomn 2026-08-22): 사고 로그에서 각 한도
    ///   에러의 "그 요청이 시작된 시각"까지 되짚으니 **재시도 지연이 63초 ~ 2분 7초(127초)**
    ///   였다. 즉 예전 값 120초는 **한 요청 분량도 못 덮어서**, 전환 전에 시작된 턴이 남긴
    ///   옛 계정 에러가 쿨다운이 풀린 뒤 도착해 새 활성 계정의 소진으로 오인됐다.
    ///   180초는 그 상한(127초)에 여유를 둔 값이고, 같은 사고를 다루는 다른 창들
    ///   (`HitAttribution.modelScopeTrustWindow` 300초)보다는 짧게 유지한다 —
    ///   이건 "전환 직후 연쇄 전환 금지"이지 귀속 판정 자체가 아니기 때문이다.
    /// ※ 이 값은 더 이상 **유일한** 방어가 아니다: 귀속은 usage 검증이 판정한다
    ///   (`HitAttribution`). 쿨다운은 그 위에 얹은 연쇄 전환 방지 장치다.
    public var cooldown: TimeInterval = 180
    public var margin: TimeInterval = 60      // 리셋 시각 + margin 후에만 복귀
    private var lastSwitchAt: Date = .distantPast
    private let lock = NSLock()

    public init(provider: Provider = .claude) {
        self.provider = provider
        self.policy = .for(provider)
    }

    /// 활성 계정이 이 정책에서 떠나야 하는가.
    /// - Parameter activeSince: 그 계정이 활성이 된 시각(호출자 메모리 — 세대가 바뀔 때 갱신).
    func mayLeave(_ active: AccountProfile, activeSince: Date?, now: Date) -> Bool {
        guard policy.leavesOnlyForRecordSinceActivation else { return active.autoSwitchMayLeave(now: now) }
        guard let rl = active.rateLimit, rl.modelScoped, now < rl.resetsAt,
              let activeSince, rl.recordedAt >= activeSince else { return false }
        return true   // 핀은 보지 않는다(0절 사용자 결정)
    }

    /// - Parameters:
    ///   - forModelLimit: 이 전환이 **모델 전용 한도 때문**이었는가.
    ///   - leftAccount: 그때 떠난 계정. primary 자동 복귀 게이트가 본다 — 아래 `onTick` (B).
    ///
    /// ★ 불리언 하나로 기억하면 안 된다(셀프리뷰 지적): 모델 한도로 A→B로 떠난 뒤 **다른
    ///   이유의 전환**(임계값·계정 소진)이 한 번이라도 일어나면 플래그가 지워져, 아직 모델
    ///   한도가 걸린 A로 복귀했다가 다음 틱에 곧바로 다시 떠나는 **왕복**(전환 2회 + 알림
    ///   2회)이 그 창이 리셋될 때까지 반복된다. "어느 계정을 그 이유로 떠났는지"를 기억한다.
    public func noteSwitched(now: Date = Date(), forModelLimit: Bool = false,
                             leftAccount: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        lastSwitchAt = now
        if forModelLimit { modelLimitLeftAccount = leftAccount }
    }

    /// 모델 전용 한도 때문에 떠난 계정(인메모리 — 재시작하면 nil로 시작한다. 그 경우 복귀가
    /// 조금 더 관대해질 뿐이라 안전한 방향이다).
    private var modelLimitLeftAccount: UUID?

    private func inCooldown(_ now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return now < lastSwitchAt.addingTimeInterval(cooldown)
    }

    /// 후보: 풀 내 순서(우선순위)대로, 한도 안 걸렸고 재인증 불필요한 계정.
    ///
    /// - Parameter avoidModelLimited: **모델 전용 한도 때문에 떠나는 중인가.** 그렇다면
    ///   같은 모델이 막힌 계정으로 옮겨봐야 소용없으므로 후보에서 뺀다. 반대로 계정 자체가
    ///   소진돼 떠나는 경우엔 모델 한도가 걸린 계정도 **정상 후보다** — 계정은 멀쩡하고
    ///   사용자는 다른 모델을 쓸 수 있다(이슈 #19 후속: 이걸 구분 안 하면 며칠짜리 모델
    ///   한도 하나가 폴백을 통째로 지워 "모든 계정 한도 소진"이 난다).
    /// - Parameter modelBlocked: **사용량 캐시가 모델 창 소진을 보여주는 계정들**(호출자가
    ///   `UsageSnapshot.modelWindowBlocked`로 계산). `isModelLimited`는 그 계정이 **활성일 때
    ///   hit을 맞아야** 생기는 기록이라, 한 번도 활성이 아니었던 폴백은 Fable이 100%여도 기록이
    ///   없다 — 그 폴백으로 옮기면 사용자는 같은 에러를 다시 보고, 그제서야 기록이 생겨 다음
    ///   폴백으로 또 옮긴다(실패 기록 22: 폴백마다 한 번씩 헛돈다). 모델 한도 때문에 떠날 때만
    ///   본다 — 계정 소진으로 떠날 때는 모델이 막힌 계정도 정상 후보(위와 같은 이유).
    /// - Parameter excludedIDs: 호출자가 모은 **제외할 계정 ID 집합**(Antigravity: 같은 모델 ID 의
    ///   유효 기록·메모리 후보 제외·확인 불가 쿨다운 — 설계 4.7 「후보 고르기」).
    private func firstAvailable(in file: AccountsFile, excluding: UUID?, now: Date,
                                avoidModelLimited: Bool = false,
                                modelBlocked: Set<UUID> = [],
                                excludedIDs: Set<UUID> = []) -> UUID? {
        let filterModel = avoidModelLimited && policy.usesBuiltInModelLimitFilter
        return file.accounts(of: provider).first {
            $0.id != excluding && !excludedIDs.contains($0.id)
                && !$0.isLimited(now: now) && !$0.needsReauth
                && !(filterModel && ($0.isModelLimited(now: now) || modelBlocked.contains($0.id)))
        }?.id
    }

    /// 활성 계정에서 rate-limit 이벤트 발생.
    /// 쿨다운 내 hit는 무시 — 전환 직후 구 세션이 계속 남기는 stale 로그를
    /// 새 활성 계정의 소진으로 오인해 연쇄 전환(B→C→D)되는 것을 막는다.
    /// - Parameter modelBlocked: 사용량 캐시상 모델 창이 소진된 계정들 — `firstAvailable` 참조.
    public func onRateLimitHit(file: AccountsFile, hit: RateLimitHit, now: Date,
                               modelBlocked: Set<UUID> = [],
                               excludedIDs: Set<UUID> = []) -> Decision {
        guard let active = file.active(of: provider), !inCooldown(now) else { return .none }
        // 모델 전용 한도(Fable 등) + 사용자가 이 계정을 직접 고름(pin) → 전환하지 않고 머문다.
        // 계정은 다른 모델로 쓸 수 있고, 사용자가 "여기 있겠다"고 이미 선택했으므로.
        // ★ 이 검사는 자동 전환 on/off보다 **먼저**다: 꺼져 있을 때도 핀은 존중해야 하고,
        //   무엇보다 아래 알림 분기가 pin 케이스까지 삼키면 안 된다.
        // ★ Antigravity 는 핀을 보지 않는다 — 쓰던 버킷이 소진되면 핀이 있어도 옮긴다(0절).
        if hit.modelScoped && active.userPinned && !policy.ignoresPinForModelLimit { return .none }
        // 이 풀의 자동 전환 꺼짐 — 스펙상 "끄면 소진 알림만": 전환 없이 알림 결정만 반환.
        // ★ 모델 전용 한도는 문구가 다르다 — "계정 한도 소진"이라고 하면 거짓말이다.
        guard file.isAutoSwitchEnabled(provider) else {
            return hit.modelScoped ? .notifyModelLimitedOnly(active.id)
                                   : .notifyExhaustedOnly(active.id)
        }
        guard let next = firstAvailable(in: markedFile(file, activeID: active.id, hit: hit, now: now),
                                        excluding: active.id, now: now,
                                        avoidModelLimited: hit.modelScoped,
                                        modelBlocked: modelBlocked,
                                        excludedIDs: excludedIDs) else {
            // ★ 모델 전용 한도인데 갈 곳이 없다 = 어디로 옮겨도 그 모델은 막혀 있다.
            //   이때 "모든 계정 한도 소진"은 **거짓말이다** — 계정들은 멀쩡하고 다른 모델은
            //   쓸 수 있다. 조용히 머문다(사용자는 CLI 에러로 이미 상황을 안다).
            return hit.modelScoped ? .none : .allExhausted
        }
        return .switchTo(next, reason: hit.modelScoped ? .modelExhausted : .activeExhausted)
    }

    /// hit를 반영한 가상의 file (호출자는 별도로 store.update로 실제 반영한다)
    /// 리셋 시각 없는 이벤트는 effectiveResetsAt의 보수적 24h 폴백을 쓴다.
    private func markedFile(_ file: AccountsFile, activeID: UUID,
                            hit: RateLimitHit, now: Date) -> AccountsFile {
        var f = file
        if let idx = f.accounts.firstIndex(where: { $0.id == activeID }) {
            f.accounts[idx].rateLimit = RateLimitInfo(resetsAt: hit.effectiveResetsAt(now: now),
                                                      recordedAt: now,
                                                      modelScoped: hit.modelScoped)
        }
        return f
    }

    /// 주기 틱: (A) 활성 계정이 소진 상태면 여유 있는 계정으로 자가 전환,
    ///          (B) fallback 활성이 자동 전환의 결과라면 primary 리셋 시 복귀.
    /// - Parameters:
    ///   - activeSince: 활성 계정이 활성이 된 시각. `leavesOnlyForRecordSinceActivation` 정책
    ///     (Antigravity)만 본다 — 그보다 앞선 기록으로는 떠나지 않는다.
    ///   - modelBlocked: 사용량 캐시상 모델 창이 소진된 계정들 — `firstAvailable` 참조.
    ///   - excludedIDs: 호출자가 모은 후보 제외 집합(Antigravity).
    public func onTick(file: AccountsFile, now: Date, activeSince: Date? = nil,
                       modelBlocked: Set<UUID> = [], excludedIDs: Set<UUID> = []) -> Decision {
        guard file.isAutoSwitchEnabled(provider), !inCooldown(now),
              let active = file.active(of: provider) else { return .none }

        if policy.leavesOnlyForRecordSinceActivation {
            // Antigravity: 자가복구(A)만. primary 복귀(B)와 계정 소진 판정은 두지 않는다(설계 4.7).
            guard mayLeave(active, activeSince: activeSince, now: now),
                  let next = firstAvailable(in: file, excluding: active.id, now: now,
                                            excludedIDs: excludedIDs) else { return .none }
            return .switchTo(next, reason: .modelExhausted)
        }

        // (A) 자가복구: 활성 계정이 소진/로그인만료인데 여전히 활성이면 여유 계정으로 전환한다
        //     (로그 hit 순간의 전환을 쿨다운·throw 등으로 놓쳐도 다음 틱에 복구).
        //     단 autoSwitchMayLeave가 false면(모델 전용 한도 + 사용자 핀) 밀어내지 않는다 —
        //     "1회 자동 전환 후 내가 되돌리면 머문다".
        // ★ avoidModelLimited는 "모델 한도 기록이 있는가"가 아니라 **"그것 때문에 떠나는가"**다.
        //   재인증 필요·계정 소진으로 떠나는데 옛 모델 한도 기록이 남아 있다는 이유로 후보를
        //   걸러내면, 갈 수 있는 폴백이 있는데도 **못 쓰는 계정에 머문다**(셀프리뷰 지적).
        let leavingForModelLimit = !active.needsReauth && !active.isLimited(now: now)
            && active.isModelLimited(now: now)
        if active.autoSwitchMayLeave(now: now),
           let next = firstAvailable(in: file, excluding: active.id, now: now,
                                     avoidModelLimited: leavingForModelLimit,
                                     modelBlocked: modelBlocked) {
            return .switchTo(next, reason: leavingForModelLimit ? .modelExhausted
                                                                : .activeExhausted)
        }

        // (B) primary 복귀 — 현재 fallback 활성이 "자동 전환"의 결과일 때만
        //     (사용자가 수동으로 fallback에 전환한 상태는 강제로 되돌리지 않는다).
        guard file.isAutoSwitchedFromPrimary(provider),
              let primary = file.primary(of: provider),
              active.id != primary.id,
              !primary.needsReauth else { return .none }
        // ★ 두 게이트 중 **있는 것 전부**를 지나야 복귀한다. 예전엔 rateLimit이 있을 때만
        //   검사해서, advisory만 보고 떠난 경우(rateLimit 없음) 가드가 통째로 스킵됐다 →
        //   쿨다운(120초)이 풀리는 순간 primary로 돌아가고, 아직 임계값 위인 primary를
        //   다시 떠나는 2분 주기 핑퐁이 창이 리셋될 때까지 계속된다.
        // ★ primary의 **모델 전용 한도**는 "떠난 이유가 그것이었을 때만" 복귀를 막는다
        //   (셀프리뷰 지적). 모델 한도는 며칠 가는데, 그걸 무조건 게이트로 쓰면 계정 자체가
        //   멀쩡한 primary로 **일주일 내내 못 돌아온다** — 게다가 (A)의 firstAvailable은
        //   같은 상태의 계정을 다른 이유의 전환에서는 정상 후보로 고르므로 두 분기가 서로
        //   모순된 말을 하게 된다. 계정 자체 한도는 이유와 무관하게 늘 게이트다.
        let modelGate = lock.withLock { modelLimitLeftAccount } == primary.id
            ? primary.rateLimit.flatMap { $0.modelScoped ? $0.resetsAt : nil } : nil
        let accountGate = primary.rateLimit.flatMap { $0.modelScoped ? nil : $0.resetsAt }
        let gates = [accountGate, modelGate, primary.advisory?.resetsAt]
            .compactMap { $0?.addingTimeInterval(margin) }
        if let blockedUntil = gates.max(), now < blockedUntil { return .none }
        return .switchTo(primary.id, reason: .primaryRecovered)
    }

    // MARK: 임계값 선제 전환 (advisory)

    /// 후보 탐색 백오프 — 갈 곳이 없다고 판정한 뒤 이 간격 안에는 다시 걷지 않는다.
    /// (5분마다 풀 전체를 재탐색하며 폴백들을 계속 건드리는 것을 막는다.)
    public var candidateProbeBackoff: TimeInterval = 15 * 60

    /// 후보 탐색을 다시 돌려도 되는가 — 순수 판정.
    /// 이전 "후보 없음" 기록이 없으면 허용, 백오프 창 안이면 차단, 창을 지나면 다시 허용.
    public func shouldProbeCandidates(lastNoCandidateAt: Date?, now: Date) -> Bool {
        guard let last = lastNoCandidateAt else { return true }
        return now >= last.addingTimeInterval(candidateProbeBackoff)
    }

    /// 후보 1개에 대한 조회 방식 결정 — 순수 함수(네트워크·IO 없음).
    /// AppState의 후보 탐색 메서드가 이 결과를 그대로 switch한다(조건을 재유도하지 말 것).
    public static func candidateProbeAction(expiresAt: Date?,
                                            now: Date,
                                            lastRefreshAttemptAt: Date?,
                                            cooldown: TimeInterval) -> CandidateProbeAction {
        // 만료 정보가 없거나 아직 유효 → 저장 토큰으로 그냥 조회 (refresh 0회)
        guard let expiresAt, expiresAt <= now else { return .useStoredToken }
        // 만료됨 — 계정별 재시도 쿨다운 안이면 판정하지 않고 넘어간다
        if let last = lastRefreshAttemptAt, now < last.addingTimeInterval(cooldown) {
            return .skipCooldown
        }
        return .escalate
    }

    /// 임계값 선제 경고 판정. 후보 검증(네트워크)은 호출자가 미리 끝내고 그 결과를
    /// `verifiedCandidate`로 넘긴다 — 이 함수는 순수하게 결정만 한다.
    /// `alreadyAdvised`는 호출자가 "직전 advised resetsAt == 이번 advisory의 resetsAt"으로
    /// 계산해 넣는다(단순 존재 여부가 아니다 — 창이 바뀌면 다시 알려야 하므로).
    public func checkAdvisory(file: AccountsFile,
                              activeID: UUID,
                              verifiedCandidate: UUID?,
                              alreadyAdvised: Bool,
                              now: Date) -> Decision {
        // 1) 해당 id가 이 풀의 활성이 아니거나 경고가 없으면 할 일 없음
        guard let active = file.active(of: provider), active.id == activeID,
              let advisory = active.advisory else { return .none }

        // 2) ★ 이 풀의 자동 전환이 꺼져 있으면 알림만 — **쿨다운 가드보다 먼저** 평가한다.
        //    알림만 하는 결정은 전환을 실행하지 않으므로 쿨다운 보호가 애초에 필요 없다.
        //    쿨다운을 먼저 두면 무관한 전환의 쿨다운 창이 이 알림을 영구히 삼켜버린다.
        guard file.isAutoSwitchEnabled(provider) else {
            return alreadyAdvised ? .none : .notifyAdvisoryOnly(active.id)
        }

        // 3) 전환 직후 쿨다운 — 여기부터는 실제로 전환을 실행할 수 있는 분기들뿐이다.
        guard !inCooldown(now) else { return .none }

        // 4) 경고를 보고 나서 사용자가 **일부러 돌아온** 핀만 거부권을 갖는다.
        //    경고 이전의 핀(또는 시각 없는 구버전 핀)은 "경고를 보고 선택한 것"이 아니므로 거부권 없음.
        if active.userPinned, let pinnedAt = active.pinnedAt, pinnedAt > advisory.detectedAt {
            return .none
        }

        // 5) 검증된 후보가 없으면 조용히 머문다 (알림도 전환도 없음 — 스펙)
        guard let candidate = verifiedCandidate else { return .none }

        return .switchTo(candidate, reason: .thresholdAdvisory)
    }
}
