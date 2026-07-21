import Foundation

public enum SwitchReason: Equatable, Sendable {
    case activeExhausted    // 활성 계정 한도 소진
    case primaryRecovered   // primary 리셋 도래 → 복귀
    case thresholdAdvisory  // 임계값 선제 경고 — **소진 아님** (알림 문구도 소진 표현 금지)
}

public enum Decision: Equatable, Sendable {
    case none
    case switchTo(UUID, reason: SwitchReason)
    case allExhausted       // 전환할 곳이 없음 → 알림만
    case notifyExhaustedOnly(UUID) // 자동 전환 꺼짐 — 소진된 활성 계정 알림만
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

/// 순수 상태머신. 부작용 없음 — 호출자가 Decision을 실행하고 noteSwitched()로 알려준다.
/// 프로바이더 풀당 1인스턴스 — 쿨다운/복귀 판단이 풀별로 독립이다.
public final class AutoSwitchEngine: @unchecked Sendable {
    public let provider: Provider
    public var cooldown: TimeInterval = 120   // 전환 직후 재전환 금지
    public var margin: TimeInterval = 60      // 리셋 시각 + margin 후에만 복귀
    private var lastSwitchAt: Date = .distantPast
    private let lock = NSLock()

    public init(provider: Provider = .claude) { self.provider = provider }

    public func noteSwitched(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastSwitchAt = now
    }

    private func inCooldown(_ now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return now < lastSwitchAt.addingTimeInterval(cooldown)
    }

    /// 후보: 풀 내 순서(우선순위)대로, 한도 안 걸렸고 재인증 불필요한 계정
    private func firstAvailable(in file: AccountsFile, excluding: UUID?, now: Date) -> UUID? {
        file.accounts(of: provider).first {
            $0.id != excluding && !$0.isLimited(now: now) && !$0.needsReauth
        }?.id
    }

    /// 활성 계정에서 rate-limit 이벤트 발생.
    /// 쿨다운 내 hit는 무시 — 전환 직후 구 세션이 계속 남기는 stale 로그를
    /// 새 활성 계정의 소진으로 오인해 연쇄 전환(B→C→D)되는 것을 막는다.
    public func onRateLimitHit(file: AccountsFile, hit: RateLimitHit, now: Date) -> Decision {
        guard let active = file.active(of: provider), !inCooldown(now) else { return .none }
        // 이 풀의 자동 전환 꺼짐 — 스펙상 "끄면 소진 알림만": 전환 없이 알림 결정만 반환
        guard file.isAutoSwitchEnabled(provider) else { return .notifyExhaustedOnly(active.id) }
        // 모델 전용 한도(Fable 등) + 사용자가 이 계정을 직접 고름(pin) → 전환하지 않고 머문다.
        // 계정은 다른 모델로 쓸 수 있고, 사용자가 "여기 있겠다"고 이미 선택했으므로.
        if hit.modelScoped && active.userPinned { return .none }
        guard let next = firstAvailable(in: markedFile(file, activeID: active.id, hit: hit, now: now),
                                        excluding: active.id, now: now) else {
            return .allExhausted
        }
        return .switchTo(next, reason: .activeExhausted)
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
    public func onTick(file: AccountsFile, now: Date) -> Decision {
        guard file.isAutoSwitchEnabled(provider), !inCooldown(now),
              let active = file.active(of: provider) else { return .none }

        // (A) 자가복구: 활성 계정이 소진/로그인만료인데 여전히 활성이면 여유 계정으로 전환한다
        //     (로그 hit 순간의 전환을 쿨다운·throw 등으로 놓쳐도 다음 틱에 복구).
        //     단 autoSwitchMayLeave가 false면(모델 전용 한도 + 사용자 핀) 밀어내지 않는다 —
        //     "1회 자동 전환 후 내가 되돌리면 머문다".
        if active.autoSwitchMayLeave(now: now),
           let next = firstAvailable(in: file, excluding: active.id, now: now) {
            return .switchTo(next, reason: .activeExhausted)
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
        let gates = [primary.rateLimit?.resetsAt, primary.advisory?.resetsAt]
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
