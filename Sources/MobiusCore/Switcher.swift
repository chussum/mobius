import Foundation

public enum SwitcherError: Error, Equatable {
    case unknownAccount
    case noStoredSecret
}

/// 계정 전환 엔진. 순서: 라이브 되저장 → 대상 기록 → 실패 시 롤백.
public final class Switcher: @unchecked Sendable {
    let env: MobiusEnvironment
    let keychain: KeychainClient
    let store: AccountStore
    let io: ClaudeConfigIO

    public init(env: MobiusEnvironment, keychain: KeychainClient,
                store: AccountStore, io: ClaudeConfigIO) {
        self.env = env; self.keychain = keychain; self.store = store; self.io = io
    }

    /// 현재 라이브 상태를, email이 일치하는 프로필에 되저장한다.
    /// 반환: 되저장된 프로필 id (일치 프로필 없으면 nil).
    @discardableResult
    public func resaveLiveIntoMatchingProfile() throws -> UUID? {
        guard let live = try io.readLiveSnapshot(),
              let email = try io.liveEmail(),
              let profile = store.file.accounts.first(where: { $0.emailAddress == email })
        else { return nil }
        try store.setSecret(live, for: profile.id)
        return profile.id
    }

    public func switchTo(_ id: UUID) throws {
        guard store.file.accounts.contains(where: { $0.id == id }) else {
            throw SwitcherError.unknownAccount
        }
        guard let target = try store.secret(for: id) else { throw SwitcherError.noStoredSecret }

        // 1. 라이브 최신 토큰 되저장 (CLI가 refresh했을 수 있으므로)
        let before = try io.readLiveSnapshot()
        try resaveLiveIntoMatchingProfile()

        // 2. 대상 기록, 실패 시 롤백
        do {
            try io.writeLiveSnapshot(target)
        } catch {
            if let before { try? io.writeLiveSnapshot(before) }
            throw error
        }
        try store.setActive(id)
    }

    /// 외부(앱 밖) 재로그인 감지 시 상태 대사: 라이브 email이 아는 프로필이면
    /// 그 프로필을 활성으로 표시하고 최신 토큰을 흡수한다. 모르는 계정이면 손대지 않는다.
    public func reconcile() throws {
        guard let email = try io.liveEmail(),
              let profile = store.file.accounts.first(where: { $0.emailAddress == email })
        else { return }
        if let live = try io.readLiveSnapshot() {
            try store.setSecret(live, for: profile.id)
        }
        if store.file.activeAccountID != profile.id {
            try store.setActive(profile.id)
            // 외부(사용자) 로그인으로 활성이 바뀐 것 — 자동 전환 상태가 아니므로
            // 플래그를 내려 onTick의 primary 자동 복귀를 막는다 (앱·CLI 공통 경로).
            try store.setAutoSwitchedFromPrimary(false)
        }
    }
}
