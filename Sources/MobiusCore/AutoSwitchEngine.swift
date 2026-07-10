import Foundation

public enum SwitchReason: Equatable, Sendable {
    case activeExhausted    // 활성 계정 한도 소진
    case primaryRecovered   // primary 리셋 도래 → 복귀
}

public enum Decision: Equatable, Sendable {
    case none
    case switchTo(UUID, reason: SwitchReason)
    case allExhausted       // 전환할 곳이 없음 → 알림만
    case notifyExhaustedOnly(UUID) // 자동 전환 꺼짐 — 소진된 활성 계정 알림만
}

/// 순수 상태머신. 부작용 없음 — 호출자가 Decision을 실행하고 noteSwitched()로 알려준다.
public final class AutoSwitchEngine: @unchecked Sendable {
    public var cooldown: TimeInterval = 120   // 전환 직후 재전환 금지
    public var margin: TimeInterval = 60      // 리셋 시각 + margin 후에만 복귀
    private var lastSwitchAt: Date = .distantPast
    private let lock = NSLock()

    public init() {}

    public func noteSwitched(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastSwitchAt = now
    }

    private func inCooldown(_ now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return now < lastSwitchAt.addingTimeInterval(cooldown)
    }

    /// 후보: 순서(우선순위)대로, 한도 안 걸렸고 재인증 불필요한 계정
    private func firstAvailable(in file: AccountsFile, excluding: UUID?, now: Date) -> UUID? {
        file.accounts.first {
            $0.id != excluding && !$0.isLimited(now: now) && !$0.needsReauth
        }?.id
    }

    /// 활성 계정에서 rate-limit 이벤트 발생.
    /// 쿨다운 내 hit는 무시 — 전환 직후 구 세션이 계속 남기는 stale 로그를
    /// 새 활성 계정의 소진으로 오인해 연쇄 전환(B→C→D)되는 것을 막는다.
    public func onRateLimitHit(file: AccountsFile, hit: RateLimitHit, now: Date) -> Decision {
        guard let active = file.active, !inCooldown(now) else { return .none }
        // 자동 전환 꺼짐 — 스펙상 "끄면 소진 알림만": 전환 없이 알림 결정만 반환
        guard file.autoSwitchEnabled else { return .notifyExhaustedOnly(active.id) }
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
                                                      recordedAt: now)
        }
        return f
    }

    /// 주기 틱: primary 복귀 판단.
    /// 복귀는 현재 fallback 활성이 "자동 전환"의 결과일 때만(autoSwitchedFromPrimary) —
    /// 사용자가 수동으로 fallback에 전환한 상태를 강제로 되돌리지 않는다.
    public func onTick(file: AccountsFile, now: Date) -> Decision {
        guard file.autoSwitchEnabled,
              file.autoSwitchedFromPrimary,
              let primary = file.primary,
              let active = file.active,
              active.id != primary.id,
              !primary.needsReauth,
              !inCooldown(now) else { return .none }
        // primary가 한도 기록이 없거나, 리셋 시각 + margin이 지났으면 복귀
        if let rl = primary.rateLimit {
            guard now >= rl.resetsAt.addingTimeInterval(margin) else { return .none }
        }
        return .switchTo(primary.id, reason: .primaryRecovered)
    }
}
