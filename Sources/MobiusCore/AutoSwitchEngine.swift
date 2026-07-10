import Foundation

public enum SwitchReason: Equatable, Sendable {
    case activeExhausted    // 활성 계정 한도 소진
    case primaryRecovered   // primary 리셋 도래 → 복귀
}

public enum Decision: Equatable, Sendable {
    case none
    case switchTo(UUID, reason: SwitchReason)
    case allExhausted       // 전환할 곳이 없음 → 알림만
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

    /// 활성 계정에서 rate-limit 이벤트 발생
    public func onRateLimitHit(file: AccountsFile, hit: RateLimitHit, now: Date) -> Decision {
        guard file.autoSwitchEnabled, let active = file.active else { return .none }
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

    /// 주기 틱: primary 복귀 판단
    public func onTick(file: AccountsFile, now: Date) -> Decision {
        guard file.autoSwitchEnabled,
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
