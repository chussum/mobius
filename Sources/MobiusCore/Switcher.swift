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
    /// 토큰/이메일 파일이 이 시간 내에 수정됐으면 저장 계열 연산을 미룬다(불일치 방지).
    /// 테스트는 파일을 막 쓰고 즉시 검증하므로 0으로 설정한다.
    public var stabilityWindow: TimeInterval = 2

    public init(env: MobiusEnvironment, keychain: KeychainClient,
                store: AccountStore, io: ClaudeConfigIO) {
        self.env = env; self.keychain = keychain; self.store = store; self.io = io
    }

    private var liveStable: Bool { io.liveIsStable(window: stabilityWindow) }

    /// 현재 라이브 상태를, email이 일치하는 프로필에 되저장한다.
    /// 반환: 되저장된 프로필 id (일치 프로필 없으면 nil).
    @discardableResult
    public func resaveLiveIntoMatchingProfile() throws -> UUID? {
        // 토큰/이메일 두 파일이 갱신 중이면(=불일치 위험) 저장하지 않는다.
        guard liveStable else { return nil }
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

    /// 현재 claude에 로그인된 계정이 아직 프로필로 등록되지 않았다면 자동 흡수한다.
    /// 앱 최초 실행 시 "등록된 계정 없음" 대신 사용 중인 계정이 바로 뜨도록 하는 부트스트랩.
    /// 반환: 새로 흡수한 프로필(있으면). 로그인 상태가 아니거나 이미 등록됐으면 nil.
    @discardableResult
    public func adoptLiveAccountIfUnregistered() throws -> AccountProfile? {
        guard liveStable else { return nil }
        // ★ 등록 여부를 먼저 확인한다 — 이메일은 .claude.json에서 읽어 승인창이 없다.
        //   readLiveSnapshot()(=Keychain, 승인창 유발)은 정말 미등록일 때만 호출.
        //   (과거: guard에서 readLiveSnapshot을 먼저 평가해 매 틱 Keychain을 읽어 15초마다 승인창이 떴음)
        guard let email = try io.liveEmail(),
              !store.file.accounts.contains(where: { $0.emailAddress == email })
        else { return nil }
        guard let live = try io.readLiveSnapshot() else { return nil }
        let nickname = String(email.split(separator: "@").first ?? "account")
        let profile = try store.upsertProfile(nickname: nickname, snapshot: live)
        try store.setActive(profile.id)
        return profile
    }

    /// 외부(앱 밖) 재로그인 감지 시 상태 대사: 라이브 email이 아는 프로필이면
    /// 그 프로필을 활성으로 표시하고 최신 토큰을 흡수한다. 모르는 계정이면 손대지 않는다.
    public func reconcile() throws {
        guard liveStable else { return }
        // 이메일은 .claude.json에서 읽어 승인창이 없다. 활성 계정이 그대로면
        // Keychain(토큰) 읽기를 아예 하지 않아 15초 주기 승인창 폭탄을 막는다.
        guard let email = try io.liveEmail(),
              let profile = store.file.accounts.first(where: { $0.emailAddress == email })
        else { return }
        let activeUnchanged = store.file.activeAccountID == profile.id
        let alreadyHasSecret = (try? store.secret(for: profile.id)) != nil
        if activeUnchanged && alreadyHasSecret { return } // 정상 상태 — Keychain 접근 없음

        // 여기부터는 외부 전환/최초 흡수 등 실제 변화가 있을 때만 (드묾) Keychain 1회 접근.
        if let live = try io.readLiveSnapshot() {
            try store.setSecret(live, for: profile.id)
        }
        if !activeUnchanged {
            try store.setActive(profile.id)
            // 외부(사용자) 로그인으로 활성이 바뀐 것 — 자동 전환 상태가 아니므로
            // 플래그를 내려 onTick의 primary 자동 복귀를 막는다 (앱·CLI 공통 경로).
            try store.setAutoSwitchedFromPrimary(false)
        }
    }
}
