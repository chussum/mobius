import Foundation

public enum SwitcherError: Error, Equatable {
    case unknownAccount
    case noStoredSecret
    case unsupportedProvider(Provider)
}

/// 소실됐던 provider를 secret 형태로 재도출해 되돌린 기록 (사용자 경고용).
public struct ProviderReassignment: Equatable, Sendable {
    public let id: UUID
    public let nickname: String
    public let from: Provider
    public let to: Provider
}

/// 계정 전환 엔진. 순서: 라이브 되저장 → 대상 기록 → 실패 시 롤백.
/// 프로바이더별 라이브 IO는 ProviderConfigIO 어댑터가 담당하고,
/// Switcher는 등록된 어댑터의 풀들에 같은 전환/adopt/reconcile 규칙을 적용한다.
public final class Switcher: @unchecked Sendable {
    let env: MobiusEnvironment
    let keychain: KeychainClient
    let store: AccountStore
    let ios: [Provider: any ProviderConfigIO]

    public init(env: MobiusEnvironment, keychain: KeychainClient,
                store: AccountStore, io: ClaudeConfigIO,
                extraIOs: [any ProviderConfigIO] = []) {
        self.env = env; self.keychain = keychain; self.store = store
        var map: [Provider: any ProviderConfigIO] = [.claude: io]
        for extra in extraIOs { map[extra.provider] = extra }
        self.ios = map
    }

    /// 등록된 어댑터들 — 프로바이더 rawValue 순으로 결정적 순회.
    private var orderedIOs: [(Provider, any ProviderConfigIO)] {
        ios.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    /// 구버전 바이너리가 accounts.json을 저장하며 per-account `provider`를 드롭하면(구 구조체엔
    /// 필드 없음), 다음 신버전 로드에서 그 계정이 `?? .claude`로 흡수돼 엉뚱한 풀에서 자격증명
    /// 디코드 실패 → 매 틱 롤백(degraded)한다. secret 바이트는 provider의 authority이므로,
    /// 각 계정의 저장 secret을 등록 어댑터들에 물어 진짜 provider를 재도출해 프로필을 되돌린다.
    /// **정확히 하나의 다른 프로바이더만** 그 secret을 인식할 때만 고친다(오정정 방지 —
    /// claimed 어댑터가 인식하면 정상이라 건드리지 않고, 아무도/여럿이 인식하면 애매하므로 보류).
    /// 되돌린 계정 목록을 반환한다 — 앱은 이를 사용자에게 경고한다. 로드 직후 1회 호출.
    @discardableResult
    public func healMisassignedProviders() throws -> [ProviderReassignment] {
        var fixed: [ProviderReassignment] = []
        for account in store.file.accounts {
            guard let claimedIO = ios[account.provider] else { continue }
            guard let data = try? store.secretData(for: account.id), !data.isEmpty else { continue }
            if claimedIO.recognizesSecret(data) { continue } // 형태 일치 — 정상 계정
            let matches = ios.filter { $0.key != account.provider && $0.value.recognizesSecret(data) }
            guard matches.count == 1, let actual = matches.first?.key else { continue }
            try store.update(account.id) { $0.provider = actual }
            fixed.append(ProviderReassignment(id: account.id, nickname: account.nickname,
                                              from: account.provider, to: actual))
        }
        // heal은 **provider만** 되돌린다 — 저장 secret이 provider의 authority이기 때문. 완전
        // 다운그레이드로 루트 activeByProvider까지 사라져 되돌린 풀의 active가 비어도 여기서는
        // 채우지 않는다: heal은 **라이브 identity를 모르므로**(저장 secret만 본다) 어떤 계정이
        // 실제 활성인지 알 수 없고, 임의로 찍으면 오active가 영속돼 오라우팅/오전환(switchTo가
        // 라이브 토큰 퇴행)을 유발할 수 있다(적대적 리뷰). active는 **라이브를 읽는
        // reconcile/adopt**가 첫 틱에 채운다 — 그 사이 '활성 없음'은 무해(초 단위, 실측 확인).
        return fixed
    }

    /// 현재 라이브 상태를, (provider, email)이 일치하는 프로필에 되저장한다.
    /// 반환: 되저장된 프로필 id (일치 프로필 없으면 nil).
    /// 사용자 전환(switchTo) 직전에 호출 — 라이브가 settled 상태이므로 단일 읽기로 충분하다.
    /// provider 기본값 없음 — 풀을 바꾸는 연산은 대상 풀을 항상 명시한다 (오라우팅 방지).
    @discardableResult
    public func resaveLiveIntoMatchingProfile(provider: Provider) throws -> UUID? {
        guard let io = ios[provider],
              let live = try io.readLiveSecretData(),
              let email = try io.liveEmail(),
              let profile = store.file.accounts.first(where: {
                  $0.provider == provider && $0.emailAddress == email
              })
        else { return nil }
        try store.setSecretData(live, for: profile.id)
        return profile.id
    }

    /// 활성 계정의 스냅샷을 라이브(claude가 갱신하는 최신 토큰)와 동기화한다.
    /// "떠날 때만 되저장" 방식의 틈을 메운다 — 한 계정을 오래 쓰다 크래시해도 스냅샷이
    /// 낡지 않게. 안정 읽기(값 2회 일치)로 토큰/이메일 불일치 레이스를 피한다(실패 기록 2·9).
    /// OAuth 갱신이 아니라 이미 갱신된 라이브 사본을 저장할 뿐이라 안전하다.
    public func refreshActiveSnapshotIfStable() async {
        // 활성 Claude 계정만 — 라이브(~/.claude)가 그 계정일 때 최신 토큰을 스냅샷에 반영.
        // (Codex auth.json은 실행 세션이 수시로 다시 쓰는 "바쁜 파일"이라 이 경로에서 제외.)
        let provider = Provider.claude
        guard let io = ios[provider],
              let email = try? io.liveEmail(),
              let profile = store.file.accounts.first(where: {
                  $0.provider == provider && $0.emailAddress == email
              }),
              profile.id == store.file.activeByProvider[provider] else { return }
        guard let (data, stableEmail) = await io.readStableLiveSecretData(),
              stableEmail == email else { return }
        try? store.setSecretData(data, for: profile.id)
    }

    public func switchTo(_ id: UUID) throws {
        guard let profile = store.file.accounts.first(where: { $0.id == id }) else {
            throw SwitcherError.unknownAccount
        }
        guard let io = ios[profile.provider] else {
            throw SwitcherError.unsupportedProvider(profile.provider)
        }
        guard let target = try store.secretData(for: id) else { throw SwitcherError.noStoredSecret }

        // 1. 라이브 최신 토큰 되저장 (CLI가 refresh했을 수 있으므로)
        let before = try io.readLiveSecretData()
        try resaveLiveIntoMatchingProfile(provider: profile.provider)

        // 2. 대상 기록, 실패 시 롤백
        do {
            try io.writeLiveSecretData(target)
        } catch {
            if let before { try? io.writeLiveSecretData(before) }
            throw error
        }
        try store.setActive(id)
    }

    /// 현재 로그인된 계정이 아직 프로필로 등록되지 않았다면 자동 흡수한다 (전 프로바이더).
    /// 앱 최초 실행 시 "등록된 계정 없음" 대신 사용 중인 계정이 바로 뜨도록 하는 부트스트랩.
    /// 반환: 새로 흡수한 첫 프로필(있으면). 로그인 상태가 아니거나 이미 등록됐으면 nil.
    @discardableResult
    public func adoptLiveAccountIfUnregistered() async throws -> AccountProfile? {
        var first: AccountProfile?
        for (provider, io) in orderedIOs {
            guard let adopted = try await adoptLiveAccount(provider: provider, io: io) else {
                continue
            }
            if first == nil { first = adopted }
        }
        return first
    }

    private func adoptLiveAccount(provider: Provider,
                                  io: any ProviderConfigIO) async throws -> AccountProfile? {
        // ★ 등록 여부를 먼저 확인 — 이메일 읽기는 승인창 없는 값싼 경로다(프로토콜 계약).
        //   Claude의 Keychain 읽기(승인창 유발)는 정말 미등록일 때만.
        guard let email = try io.liveEmail(),
              !store.file.accounts.contains(where: {
                  $0.provider == provider && $0.emailAddress == email
              })
        else { return nil }
        // 비밀+이메일을 두 번 읽어 일치할 때만(전환/리프레시 중 불일치 배제) 저장한다.
        guard let (live, stableEmail) = await io.readStableLiveSecretData(),
              stableEmail == email,
              let identity = try io.liveIdentity(), identity.emailAddress == email
        else { return nil }
        let nickname = String(email.split(separator: "@").first ?? "account")
        let profile = try store.upsertProfile(nickname: nickname, provider: provider,
                                              identity: identity, secretData: live)
        try store.setActive(profile.id)
        return profile
    }

    /// 외부(앱 밖) 재로그인 감지 시 상태 대사 (전 프로바이더): 라이브 email이 아는
    /// 프로필이면 그 프로필을 활성으로 표시하고 최신 토큰을 흡수한다.
    /// 모르는 계정이면 손대지 않는다.
    public func reconcile() async throws {
        for (provider, io) in orderedIOs {
            try await reconcile(provider: provider, io: io)
        }
    }

    private func reconcile(provider: Provider, io: any ProviderConfigIO) async throws {
        // 이메일은 승인창 없는 값싼 경로로 읽는다. 활성 계정이 그대로면 비밀 읽기
        // (Claude는 Keychain)를 아예 하지 않아 15초 주기 승인창 폭탄을 막는다.
        guard let email = try io.liveEmail(),
              let profile = store.file.accounts.first(where: {
                  $0.provider == provider && $0.emailAddress == email
              })
        else { return }
        let activeUnchanged = store.file.activeByProvider[provider] == profile.id
        // 존재 확인은 stat으로 — 15초 주기 정상 경로에서 비밀 파일 전체를 읽지 않는다
        // (파일이 없을 때만 secretData가 레거시 Keychain 이관까지 시도).
        let alreadyHasSecret = FileManager.default
            .fileExists(atPath: env.secretFile(for: profile.id).path)
            || (try? store.secretData(for: profile.id)) != nil
        if activeUnchanged && alreadyHasSecret { return } // 정상 상태 — 비밀 접근 없음

        // 실제 변화가 있을 때만(드묾) 비밀+이메일 두 번 읽어 일치 확인 후 저장.
        guard let (live, stableEmail) = await io.readStableLiveSecretData(),
              stableEmail == email else { return }
        try store.setSecretData(live, for: profile.id)
        if !activeUnchanged {
            try store.setActive(profile.id)
            // 외부(사용자) 로그인으로 활성이 바뀐 것 — 자동 전환 상태가 아니므로
            // 플래그를 내려 onTick의 primary 자동 복귀를 막는다 (앱·CLI 공통 경로).
            try store.setAutoSwitchedFromPrimary(false, provider: provider)
        }
    }
}
