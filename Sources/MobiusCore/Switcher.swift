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
    /// 사용자 전환(switchTo) 직전에 호출 — 라이브가 settled 상태이므로 단일 읽기로 충분하다.
    @discardableResult
    public func resaveLiveIntoMatchingProfile() throws -> UUID? {
        guard let live = try io.readLiveSnapshot(),
              let email = try io.liveEmail(),
              let profile = store.file.accounts.first(where: { $0.emailAddress == email })
        else { return nil }
        try store.setSecret(live, for: profile.id)
        return profile.id
    }

    /// 활성 계정의 스냅샷을 라이브(claude가 갱신하는 최신 토큰)와 동기화한다.
    /// "떠날 때만 되저장" 방식의 틈을 메운다 — 한 계정을 오래 쓰다 크래시해도 스냅샷이
    /// 낡지 않게. 안정 읽기(값 2회 일치)로 토큰/이메일 불일치 레이스를 피한다(실패 기록 2·9).
    /// OAuth 갱신이 아니라 이미 갱신된 라이브 사본을 저장할 뿐이라 안전하다.
    public func refreshActiveSnapshotIfStable() async {
        guard let email = try? io.liveEmail(),
              let profile = store.file.accounts.first(where: { $0.emailAddress == email }),
              profile.id == store.file.activeAccountID else { return }
        guard let (live, stableEmail) = await io.readStableLiveSnapshot(),
              stableEmail == email else { return }
        try? store.setSecret(live, for: profile.id)
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

    /// 현재 claude에 로그인된 계정이 아직 프로필로 등록되지 않았다면 자동 흡수한다.
    /// 앱 최초 실행 시 "등록된 계정 없음" 대신 사용 중인 계정이 바로 뜨도록 하는 부트스트랩.
    /// 반환: 새로 흡수한 프로필(있으면). 로그인 상태가 아니거나 이미 등록됐으면 nil.
    @discardableResult
    public func adoptLiveAccountIfUnregistered() async throws -> AccountProfile? {
        // ★ 등록 여부를 먼저 확인 — 이메일은 .claude.json에서 읽어 승인창이 없다.
        //   Keychain 읽기(승인창 유발)는 정말 미등록일 때만.
        guard let email = try io.liveEmail(),
              !store.file.accounts.contains(where: { $0.emailAddress == email })
        else { return nil }
        // 토큰+이메일을 두 번 읽어 일치할 때만(전환 중 불일치 배제) 저장한다.
        guard let (live, stableEmail) = await io.readStableLiveSnapshot(),
              stableEmail == email else { return nil }
        let nickname = String(email.split(separator: "@").first ?? "account")
        let profile = try store.upsertProfile(nickname: nickname, snapshot: live)
        try store.setActive(profile.id)
        return profile
    }

    /// 외부(앱 밖) 재로그인 감지 시 상태 대사: 라이브 email이 아는 프로필이면
    /// 그 프로필을 활성으로 표시하고 최신 토큰을 흡수한다. 모르는 계정이면 손대지 않는다.
    public func reconcile() async throws {
        // 이메일은 .claude.json에서 읽어 승인창이 없다. 활성 계정이 그대로면
        // Keychain(토큰) 읽기를 아예 하지 않아 15초 주기 승인창 폭탄을 막는다.
        guard let email = try io.liveEmail(),
              let profile = store.file.accounts.first(where: { $0.emailAddress == email })
        else { return }
        let activeUnchanged = store.file.activeAccountID == profile.id
        let alreadyHasSecret = (try? store.secret(for: profile.id)) != nil
        if activeUnchanged && alreadyHasSecret { return } // 정상 상태 — Keychain 접근 없음

        // 실제 변화가 있을 때만(드묾) 토큰+이메일 두 번 읽어 일치 확인 후 Keychain 접근.
        guard let (live, stableEmail) = await io.readStableLiveSnapshot(),
              stableEmail == email else { return }
        try store.setSecret(live, for: profile.id)
        if !activeUnchanged {
            try store.setActive(profile.id)
            // 외부(사용자) 로그인으로 활성이 바뀐 것 — 자동 전환 상태가 아니므로
            // 플래그를 내려 onTick의 primary 자동 복귀를 막는다 (앱·CLI 공통 경로).
            try store.setAutoSwitchedFromPrimary(false)
        }
    }
}
