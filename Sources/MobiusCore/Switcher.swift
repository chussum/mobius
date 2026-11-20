import Foundation

public enum SwitcherError: Error, Equatable {
    case unknownAccount
    case noStoredSecret
    case unsupportedProvider(Provider)
    /// 대상 프로필의 저장본이 다른 조직의 토큰과 그 프로필의 신원을 섞어 들고 있다(실패 기록 24).
    /// 설치하면 사용자가 고른 카드와 다른 조직으로 로그인되므로 전환하지 않는다 — 복구는 '다시 로그인'.
    case mixedSnapshot
    /// 설치할 스냅샷 바이트의 이메일이 대상 프로필과 다르다 — 다른 계정의 값을 라이브에 쓰지
    /// 않는다(설계 4.1).
    case secretIdentityMismatch
    /// 자동 전환의 기대 상태(활성 세대·라이브 지문·디스크 리비전·설정·출발 기록)가 라이브 쓰기
    /// 직전에 달라졌다 — 전환을 취소했다(설계 4.7 「비동기 경합」).
    case expectationChanged
    /// 라이브 쓰기는 성공했지만 계정 목록 저장이 실패했다. 키체인은 그대로 두고 메모리 활성은
    /// 이전 값이다 — 다음 reconcile 이 라이브를 따라 맞춘다(설계 4.5).
    case liveWrittenButSaveFailed(String)
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

    /// reconcile·adopt가 저장을 거부한 라이브의 신원 지문, 그 시각, 거부 사유(로그인 없음인가)(프로바이더별).
    /// 같은 라이브면 비밀을 다시 읽지 않는다 — 아래 `reconcile(provider:io:)` 참조.
    private struct DeferredLive { let fingerprint: Data; let at: Date; let lacksLogin: Bool }
    private var deferredLive: [Provider: DeferredLive] = [:]
    private let deferredLiveLock = NSLock()
    /// 조직이 어긋나 거부한 라이브(`.organizationMismatch`)를 신원 지문이 그대로여도 다시 확인하는 간격.
    /// 이 상태에서 신원은 그대로이고 토큰만 다른 계보로 바뀌는 일은 드물다 — refresh 저장이 CAS라 다른 세션은
    /// Keychain 토큰이 빈 문자열일 때만 덮을 수 있다(핵심 사실 "토큰과 신원은 쓰는 경로가 다르다"). 같은
    /// 계보 안의 회전은 판정 결과를 바꾸지 않으므로, 이 간격은 알 수 없는 경로에 대한 상한일 뿐이다.
    /// 거부 사유는 처음 거부한 시점에 정해진다. 불일치로 기억된 뒤 토큰이 invalid_grant로 비워지고 그 자리를
    /// 다른 세션의 refresh가 채우면 이 긴 간격을 따른다 — 그 경로는 refresh 요청이 나가 있는 동안 비워질
    /// 때만 생겨 드물다(리뷰 4회차 P3-2).
    public var deferredLiveRecheckInterval: TimeInterval = 5 * 60
    /// 로그인이 없어 거부한 라이브(빈 refresh 토큰 등)를 다시 확인하는 간격. 빈 자리는 refresh 요청이 이미
    /// 나간 뒤에 비워진 경우 그 refresh가 CAS로 채울 수 있고(refresh는 락을 잡은 채 그 순간 Keychain에 있는
    /// 토큰으로만 한다), 그때 신원(oauthAccount)은 그대로라 지문으로는 알 수 없다. 늦게 따라가면 그동안
    /// 활성 표시가 실제 로그인과 달라지고 실제 라이브 계정이 폴백으로 취급되어 refresh 대상이 될 수 있으므로
    /// 짧게 둔다(AppState의 "reconcile에 유예는 넣지 않는다"와 같은 이유). 15초마다 읽던 것의 1/4이다.
    public var loggedOutLiveRecheckInterval: TimeInterval = 60

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
        var firstError: Error?
        // ★ 계정 하나의 실패가 나머지 계정의 복구를 멈추지 않게 한다(설계 4.6 오류 격리).
        for account in store.file.accounts {
            guard let claimedIO = ios[account.provider] else { continue }
            guard let data = try? store.secretData(for: account.id), !data.isEmpty else { continue }
            if claimedIO.recognizesSecret(data) { continue } // 형태 일치 — 정상 계정
            let matches = ios.filter { $0.key != account.provider && $0.value.recognizesSecret(data) }
            guard matches.count == 1, let actual = matches.first?.key else { continue }
            do {
                try store.update(account.id) { $0.provider = actual }
            } catch {
                if firstError == nil { firstError = error }
                continue
            }
            fixed.append(ProviderReassignment(id: account.id, nickname: account.nickname,
                                              from: account.provider, to: actual))
        }
        if let firstError, fixed.isEmpty { throw firstError }
        // heal은 **provider만** 되돌린다 — 저장 secret이 provider의 authority이기 때문. 완전
        // 다운그레이드로 루트 activeByProvider까지 사라져 되돌린 풀의 active가 비어도 여기서는
        // 채우지 않는다: heal은 **라이브 identity를 모르므로**(저장 secret만 본다) 어떤 계정이
        // 실제 활성인지 알 수 없고, 임의로 찍으면 오active가 영속돼 오라우팅/오전환(switchTo가
        // 라이브 토큰 퇴행)을 유발할 수 있다(적대적 리뷰). active는 **라이브를 읽는
        // reconcile/adopt**가 첫 틱에 채운다 — 그 사이 '활성 없음'은 무해(초 단위, 실측 확인).
        return fixed
    }

    /// 구버전 프로필(organizationUuid 없음)에 **저장 스냅샷**의 조직 UUID를 채운다.
    /// 이메일만으로 대조하던 시절의 프로필은 조직을 모른다. 그대로 두면 같은 이메일의 **다른**
    /// 조직으로 로그인했을 때 이 프로필이 이메일만으로 잡혀 덮어써진다 — 고치려는 버그 그대로다
    /// (실패 기록 23). 저장 스냅샷의 oauthAccount 블록이 그 프로필의 진짜 조직을 알고 있으므로
    /// 거기서 채운다 — 라이브를 보지 않으니 지금 어느 조직으로 로그인했든 오귀속되지 않는다.
    /// 비밀 **파일이 있는** 계정만 읽는다(stat 게이트) — 구버전 Keychain 폴백(승인창)은 타지 않는다.
    /// 반환: 채워 넣은 프로필 id. 앱 시작·CLI 변경 명령에서 heal 직후 1회 호출.
    ///
    /// ★ 조직 UUID만 채우면 **라벨과 토큰이 어긋난 채로 굳는다**(리뷰 지적). 이 버그를 이미
    ///   맞은 프로필은 v0.5.3의 되저장이 이메일로 맞춰 **비밀만** 덮어쓴 결과라, "라벨은
    ///   Acme Team인데 저장 스냅샷 토큰은 개인 Max"일 수 있다. 거기에 개인 Max의 UUID만 찍으면
    ///   카드는 계속 회사 조직을 말하면서 실제로는 개인 계정이 된다 — 데이터는 안 잃지만
    ///   사용자가 영영 오해한다. 스냅샷이 그 프로필의 자격증명 진실이므로 같은 identity에서
    ///   이름과 등급도 함께 맞춘다. 다만 **빈 값으로는 덮어쓰지 않는다** — 구버전 스냅샷의
    ///   oauthAccount는 organizationName이 없을 수 있고, 그때 멀쩡한 표시를 지우면 어긋남은
    ///   안 줄고 정보만 사라진다.
    @discardableResult
    public func backfillOrganizationUUIDs() throws -> [UUID] {
        var filled: [UUID] = []
        for account in store.file.accounts
        where account.provider == .claude && account.organizationUuid.isEmpty {
            guard FileManager.default.fileExists(atPath: env.secretFile(for: account.id).path),
                  let data = try? store.secretData(for: account.id),
                  let snap = try? JSONDecoder().decode(CredentialsSnapshot.self, from: data),
                  let identity = ClaudeConfigIO.identity(fromSnapshot: snap),
                  !identity.organizationUuid.isEmpty
            else { continue }
            try store.update(account.id) { $0.applyBackfilledIdentity(identity) }
            filled.append(account.id)
        }
        return filled
    }

    /// 조직을 이미 아는 Claude 프로필의 **등급 표시**를 저장 스냅샷에서 다시 계산한다.
    /// 등급 문자열은 등록·재로그인 때만 정해지므로, 표시 규칙(`ClaudeConfigIO.tierDescription`)을
    /// 고쳐도 기존 프로필은 옛 문자열("Raven", "Max 20X")을 계속 보여 준다. 스냅샷의 조직이 프로필의
    /// 조직과 같을 때만, 빈 값이 아닐 때만 바꾼다 — backfill과 같은 stat 게이트(승인창 없음).
    /// 반환: 등급을 바꾼 프로필 id. 앱 시작·CLI 변경 명령에서 backfill 직후 1회 호출.
    @discardableResult
    public func refreshTierLabels() throws -> [UUID] {
        var changed: [UUID] = []
        for account in store.file.accounts
        where account.provider == .claude && !account.organizationUuid.isEmpty {
            guard FileManager.default.fileExists(atPath: env.secretFile(for: account.id).path),
                  let data = try? store.secretData(for: account.id),
                  let snap = try? JSONDecoder().decode(CredentialsSnapshot.self, from: data),
                  let identity = ClaudeConfigIO.identity(fromSnapshot: snap),
                  identity.organizationUuid == account.organizationUuid,
                  !identity.tierDescription.isEmpty,
                  identity.tierDescription != account.tierDescription
            else { continue }
            try store.update(account.id) { $0.tierDescription = identity.tierDescription }
            changed.append(account.id)
        }
        return changed
    }

    /// 현재 라이브 상태를, (provider, 계정 열쇠)가 일치하는 프로필에 되저장한다.
    /// 반환: 되저장된 프로필 id (일치 프로필 없으면 nil).
    /// 사용자 전환(switchTo) 직전에 호출 — 라이브가 settled 상태이므로 단일 읽기로 충분하다.
    /// provider 기본값 없음 — 풀을 바꾸는 연산은 대상 풀을 항상 명시한다 (오라우팅 방지).
    /// ★ 토큰과 신원이 어긋난 라이브는 열쇠가 가리키는 프로필에 되저장하지 않는다(`canStoreLiveSecret`,
    ///   실패 기록 24) — 남의 조직 토큰을 떠나는 프로필에 박으면 두 프로필이 한 계보를 나눠 갖게 된다.
    ///   다만 토큰이 활성 프로필의 것으로 보이면(`reattributedToActive`) 그쪽에 저장한다 — 떠나는
    ///   활성 프로필의 최신 계보를 잃지 않게.
    @discardableResult
    public func resaveLiveIntoMatchingProfile(provider: Provider) throws -> UUID? {
        guard let io = ios[provider],
              let live = try io.readLiveSecretData(),
              let key = try identityKey(of: live, io: io)
        else { return nil }
        if io.canStoreLiveSecret(live) {
            guard let profile = store.file.firstAccount(provider: provider, matching: key) else { return nil }
            try saveLiveSecret(live, for: profile.id)
            return profile.id
        }
        guard let (id, repaired) = reattributedToActive(provider: provider, io: io, live: live,
                                                        email: key.emailAddress) else { return nil }
        try saveLiveSecret(repaired, for: id)
        return id
    }

    /// 어긋난 라이브의 토큰이 **활성 프로필의 것**으로 보이면 (그 프로필 id, 저장할 secret)을 돌려준다.
    ///
    /// 2.1.281에서 두 곳이 어긋나는 흔한 경로는 옛 토큰을 캐시한 세션의 bootstrap이 oauthAccount만 옛
    /// 조직으로 되돌리는 경우다. 이때 Keychain 토큰은 Mobius가 마지막에 설치한 활성 프로필의 계보다
    /// (refresh 저장이 CAS라 다른 세션이 덮지 못한다). 판정을 미루기만 하면 그사이 claude가 토큰을
    /// 회전하고 사용자가 전환할 때 활성 프로필의 저장본이 소비된 토큰으로 남는다(리뷰 P2-3).
    ///
    /// 조건은 셋이다: 라이브 열쇠의 이메일이 활성 프로필의 이메일과 같다, 토큰 종류(좌석형/개인 구독)가
    /// 활성 프로필 저장본의 조직 종류와 같다(`liveSecret(_:reattributedTo:)`), 그리고 같은 이메일의 다른
    /// 프로필 중 그 토큰의 주인**일 수 있는** 것이 없다(`liveToken(_:couldBelongTo:)`). 개인 조직은
    /// 이메일당 하나라 개인 구독 토큰은 항상 주인이 하나로 정해지고, 좌석형 조직이 둘 이상이면 가릴 수
    /// 없어 nil이다(모호하면 손대지 않는다). 다른 프로필의 저장본이 빈 토큰이거나 섞여 있거나 조직 종류를
    /// 모르면 주인일 수 있는 것으로 센다 — 건강한 저장본만 세면 모호한데도 활성 하나로 좁혀진다(리뷰 2회차 P2-3).
    /// 신원은 활성 프로필 저장본의 oauthAccount를 쓴다 — 라이브의 것은 되돌려진 옛 조직이다.
    private func reattributedToActive(provider: Provider, io: any ProviderConfigIO,
                                      live: Data, email: String) -> (id: UUID, data: Data)? {
        guard let activeID = store.file.activeByProvider[provider],
              store.file.accounts.first(where: { $0.id == activeID })?.emailAddress == email,
              FileManager.default.fileExists(atPath: env.secretFile(for: activeID).path),
              let activeStored = try? store.secretData(for: activeID),
              let repaired = io.liveSecret(live, reattributedTo: activeStored)
        else { return nil }
        for p in store.file.accounts
        where p.provider == provider && p.emailAddress == email && p.id != activeID {
            // stat 게이트 — 구버전 Keychain 폴백(승인창)은 타지 않는다. 저장본이 없으면 모른다(nil).
            let stored = FileManager.default.fileExists(atPath: env.secretFile(for: p.id).path)
                ? try? store.secretData(for: p.id) : nil
            if io.liveToken(live, couldBelongTo: stored) { return nil }
        }
        return (activeID, repaired)
    }

    /// 저장·설치할 바이트의 계정 열쇠. 신원이 바이트 안에 있는 프로바이더(Codex·Antigravity)는
    /// **바이트에서만** 이메일을 꺼낸다 — 값과 이메일을 따로 읽어 짝짓는 틈(실패 기록 1·2)이 생기지
    /// 않게(설계 4.1). 이 프로바이더들에는 조직 개념이 없어 열쇠는 이메일뿐이다(`AccountKey` 기본값).
    /// 바이트에 신원이 없는 Claude 만 따로 읽은 열쇠(이메일 + 조직, `liveAccountKey`)로 대조한다.
    private func identityKey(of data: Data, io: any ProviderConfigIO) throws -> AccountKey? {
        if let email = io.email(fromSecret: data) { return AccountKey(emailAddress: email) }
        return io.identityIsInSecret ? nil : try io.liveAccountKey()
    }

    /// 라이브 자격증명을 프로필 스냅샷으로 저장한다. refresh 토큰이 **다른 값으로 교체**됐으면
    /// `needsReauth` 딱지도 함께 내린다 (판정 근거는 `ReauthClearance` 참조).
    ///
    /// 이 자리가 필요한 이유: 딱지를 자동으로 내리는 경로가 **usage 200 하나뿐**이었고
    /// (`AppState.refreshUsageIfStale`), 그 함수는 '사용량 게이지 표시'(showUsageGauges)가
    /// 꺼져 있으면 통째로 조기 반환한다. 반대로 refresh를 시도하는 모든 진입점은 스스로를
    /// `!needsReauth`로 필터링하므로, 게이지를 끈 사용자에게 딱지는 **일방향 래치**가 됐다 —
    /// CLI에서 재로그인해 실제로 복구해도 딱지가 남고, `AccountProfile.autoSwitchMayLeave`가
    /// needsReauth를 소진과 동급으로 보기 때문에 멀쩡한 활성 계정에서 계속 밀려난다 (이슈 #14).
    /// 여기는 **네트워크 0**이고 5분마다 어차피 도는 라이브싱크에 얹히므로, 게이지를 꺼도
    /// "끄면 폴링 0" 계약을 지키면서 복구가 자동으로 잡힌다.
    /// ★ 순서 주의(실패 기록 3b): **값싼 플래그 검사를 먼저** 하고 이전 스냅샷 읽기는 정말
    ///   필요할 때만 한다. `secretData`는 비밀 파일이 없으면 구버전 Keychain 항목까지
    ///   찾아보므로(= `security` subprocess), 조건 없이 읽으면 딱지가 없는 정상 계정도
    ///   5분마다 그 비용을 낸다. 딱지가 붙어 있는 경우는 드물다 — 비싼 쪽을 뒤로.
    private func saveLiveSecret(_ data: Data, for id: UUID) throws {
        let flagged = store.file.accounts.first(where: { $0.id == id })?.needsReauth == true
        let previous = flagged ? try? store.secretData(for: id) : nil
        try store.setSecretData(data, for: id)
        guard flagged,
              ReauthClearance.refreshTokenRotated(previous: previous, next: data) else { return }
        // 저장 실패는 삼킨다 — secret 저장(위)은 이미 성공했고, 딱지는 다음 회전에서 다시
        // 내려간다. 호출자의 신선도 계약(아래 refreshActiveSnapshotIfStable)은 secret 쓰기의
        // 성패만을 뜻하므로 여기서 false로 뒤집으면 오히려 거짓말이 된다.
        try? store.setNeedsReauth(id, false)
    }

    /// 활성 계정의 스냅샷을 라이브(claude가 갱신하는 최신 토큰)와 동기화한다.
    /// "떠날 때만 되저장" 방식의 틈을 메운다 — 한 계정을 오래 쓰다 크래시해도 스냅샷이
    /// 낡지 않게. 안정 읽기(값 2회 일치)로 토큰/이메일 불일치 레이스를 피한다(실패 기록 2·9).
    /// OAuth 갱신이 아니라 이미 갱신된 라이브 사본을 저장할 뿐이라 안전하다.
    ///
    /// 반환: **이번 호출에서 실제로 새 스냅샷을 썼는지**. 호출자(AppState)는 이 값을 보고
    /// "활성 계정의 저장 secret이 이번 사이클 기준으로 신선하다"를 알며, 그 덕에 라이브
    /// Keychain을 한 번 더 읽지 않는다(승인창·subprocess 비용 절감 — 실패 기록 3 계열).
    /// 그래서 이 불리언은 **신선도 계약** 그 자체다: 쓰기가 실패했는데 true를 돌려주면
    /// 호출자가 낡은 스냅샷을 신선하다고 믿고 판단해 조용히 틀린다. 그러므로 저장 실패는
    /// `try?`로 삼키지 말고 do/catch로 잡아 반드시 false로 보고한다.
    @discardableResult
    public func refreshActiveSnapshotIfStable() async -> Bool {
        // 활성 Claude 계정만 — 라이브(~/.claude)가 그 계정일 때 최신 토큰을 스냅샷에 반영.
        // (Codex auth.json은 실행 세션이 수시로 다시 쓰는 "바쁜 파일"이라 이 경로에서 제외.)
        let provider = Provider.claude
        guard let io = ios[provider],
              let key = try? io.liveAccountKey(),
              let activeID = store.file.activeByProvider[provider] else { return false }
        let keyIsActive = store.file.firstAccount(provider: provider, matching: key)?.id == activeID
        // 열쇠가 활성 프로필을 가리키지 않으면 보통은 다른 계정의 라이브다(reconcile 몫). 다만 같은
        // 이메일이면 oauthAccount만 옛 조직으로 되돌려진 경우일 수 있어 아래 보정 경로까지 본다.
        guard keyIsActive
                || store.file.accounts.first(where: { $0.id == activeID })?.emailAddress == key.emailAddress
        else { return false }
        // 안정 읽기 뒤 열쇠를 한 번 더 확인한다 — 같은 이메일의 다른 조직으로 로그인이 끝난 직후라면
        // 이메일은 같아도 조직이 달라, 이 프로필에 남의 조직 토큰을 저장하게 된다(파일 읽기 한 번).
        guard let (data, stableEmail) = await io.readStableLiveSecretData(),
              stableEmail == key.emailAddress,
              (try? io.liveAccountKey()) == key else { return false }
        // 토큰과 신원이 맞으면 그대로, 어긋났으면 토큰이 활성 프로필의 것으로 보일 때만 보정해 저장한다.
        // 둘 다 아니면(다른 조직 토큰, 로그인 없는 blob) 저장하지 않는다 — false는 "이번 사이클은 신선하지
        // 않다"는 뜻이라 호출자 계약과도 맞는다(실패 기록 24).
        let toSave: Data
        if keyIsActive, io.canStoreLiveSecret(data) {
            toSave = data
        } else if let (_, repaired) = reattributedToActive(provider: provider, io: io, live: data,
                                                           email: key.emailAddress) {
            toSave = repaired
        } else {
            return false
        }
        do {
            try saveLiveSecret(toSave, for: activeID)
            return true
        } catch {
            return false // 디스크 실패 등 — 신선하다고 보고하면 안 된다 (위 계약 참조)
        }
    }

    /// - Parameter expectation: 자동 전환이 넘기는 기대 상태 확인. 대상 스냅샷을 읽고 되저장한
    ///   **뒤, 라이브 쓰기 바로 앞**에서 부르고 false 면 `expectationChanged` 로 취소한다(설계 4.7
    ///   「비동기 경합」). 수동 전환은 지금처럼 nil 로 부른다.
    /// - Parameter expectedLiveFingerprint: 자동 전환이 작업 시작 때 본 라이브 값의 지문. expectation 이
    ///   있으면 어댑터가 쓰기 직전에 읽은 값도 이 지문과 같아야 쓴다(리뷰 1회차 Codex P1-3) — 확인과
    ///   쓰기 사이에 끝난 새 agy 로그인을 덮지 않게.
    public func switchTo(_ id: UUID, expectedLiveFingerprint: Data? = nil,
                         expectation: ((AccountsFile) -> Bool)? = nil) throws {
        // 계정 목록을 읽지 못해 저장이 막힌 동안은 라이브도 바꾸지 않는다 — 바꾼 뒤 활성을 저장하지
        // 못하는 반쪽 전환이 된다(리뷰 2회차 Codex P1-1).
        if store.loadFailure != nil { throw AccountStoreError.savesBlockedAfterLoadFailure }
        guard let profile = store.file.accounts.first(where: { $0.id == id }) else {
            throw SwitcherError.unknownAccount
        }
        guard let io = ios[profile.provider] else {
            throw SwitcherError.unsupportedProvider(profile.provider)
        }
        // ★ credential lock 안에서 스냅샷을 **읽고** 라이브에 설치한다 — 이 락은 비활성 계정 토큰
        //   자동 갱신(CodexTokenRefresher)의 저장과 상호 배제되어 **저장 단계**만 보장한다. 전환↔
        //   회전 HTTP 창(회전 직전 스냅샷 install 레이스)은 이 락이 아니라 AppState 게이트(비활성
        //   게이지 refresh의 활성 fresh-read 가드 + 전환 진입 시 codexUsageTask 정지·완료대기)가 닫는다.
        try store.withCredentialLock(id) {
            guard let target = try store.secretData(for: id) else { throw SwitcherError.noStoredSecret }
            guard !io.secretIsMixed(target) else { throw SwitcherError.mixedSnapshot }
            // 설치할 바이트의 이메일이 대상 프로필과 다르면 쓰지 않는다(설계 4.1·4.5).
            if let byteEmail = io.email(fromSecret: target), byteEmail != profile.emailAddress {
                throw SwitcherError.secretIdentityMismatch
            }

            guard io.rollsBackFailedSwitch else {
                // Antigravity: 되저장 → 기대 상태 재확인 → 쓰기. **되돌리지 않는다**(설계 4.5).
                try resaveLiveIntoMatchingProfile(provider: profile.provider)
                if let expectation {
                    // 기대 상태 + 대상이 디스크에 아직 같은 신원으로 등록돼 있는가. 되저장 뒤 한 번, 어댑터의
                    // 마지막 읽기 **뒤** 실제 쓰기 바로 앞에서 한 번 더 본다(리뷰 2회차 Codex P1-3).
                    // 디스크는 **한 번만** 읽어 그 사본 하나로 설정·리비전·출발 계정·대상 등록을 함께 본다 —
                    // 두 번 읽으면 두 읽기 사이의 설정 변경을 뒤 읽기가 보고도 놓친다(리뷰 3회차 Codex P1-3).
                    let stillValid = { [store] () -> Bool in
                        guard let disk = store.peekDisk(), expectation(disk) else { return false }
                        return disk.accounts.contains {
                            $0.id == id && $0.provider == profile.provider
                                && $0.emailAddress == profile.emailAddress
                                && $0.organizationUuid == profile.organizationUuid
                        }
                    }
                    guard stillValid() else { throw SwitcherError.expectationChanged }
                    guard let guarded = io as? GuardedLiveWriting else {
                        throw SwitcherError.expectationChanged
                    }
                    do {
                        try guarded.writeLiveSecretData(target, ifLiveFingerprint: expectedLiveFingerprint,
                                                        stillValid: stillValid)
                    } catch AntigravityConfigError.liveChangedBeforeWrite {
                        throw SwitcherError.expectationChanged
                    }
                } else {
                    try io.writeLiveSecretData(target)
                }
                // 자기 쓰기로 바뀐 지문을 먼저 알려, 다음 대사가 이걸 "외부 변경"으로 다시 세지 않게.
                if let fp = io as? LiveFingerprintReporting {
                    store.noteLiveFingerprint(fp.liveFingerprint, provider: profile.provider)
                }
                do {
                    try store.setActive(id)   // 실패하면 메모리 활성도 이전 값 그대로다
                } catch {
                    throw SwitcherError.liveWrittenButSaveFailed(String(describing: error))
                }
                return
            }

            // 1. 라이브 최신 토큰 되저장 (CLI가 refresh했을 수 있으므로)
            let before = try io.readLiveSecretData()
            try resaveLiveIntoMatchingProfile(provider: profile.provider)
            if let expectation, !(store.peekDisk().map(expectation) ?? false) {
                throw SwitcherError.expectationChanged
            }

            // 2. 대상 기록, 실패 시 롤백
            do {
                try io.writeLiveSecretData(target)
            } catch {
                if let before { try? io.writeLiveSecretData(before) }
                throw error
            }
            try store.setActive(id)
        }
    }

    /// 현재 로그인된 계정이 아직 프로필로 등록되지 않았다면 자동 흡수한다 (전 프로바이더).
    /// 앱 최초 실행 시 "등록된 계정 없음" 대신 사용 중인 계정이 바로 뜨도록 하는 부트스트랩.
    /// 반환: 새로 흡수한 첫 프로필(있으면). 로그인 상태가 아니거나 이미 등록됐으면 nil.
    @discardableResult
    public func adoptLiveAccountIfUnregistered() async throws -> AccountProfile? {
        let (first, failed) = await adoptLiveAccountsIsolated()
        if first == nil, let error = Self.firstError(failed) { throw error }
        return first
    }

    /// CLI 읽기 전용 명령(`list`·`status`)의 대사. **어느 풀도 저장하지 않고** 라이브 신원만 메모리의 활성
    /// 값에 반영해 보여 준다.
    /// - Antigravity: CLI 가 앱보다 먼저 라이브를 따라 저장하면, 앱 대사는 그 변경을 자기가 커밋한 것으로
    ///   보지 못해 이전 세션의 되돌림(왕복)을 놓친다(리뷰 3회차 Claude P2-1).
    /// - Claude·Codex: 대사의 저장은 CLI 가 시작할 때 읽은 목록 전체를 쓰므로, 그사이 다른 프로세스가 더한
    ///   계정을 지운다(리뷰 4회차 Codex P1-1).
    /// 라이브 추종 저장(토큰 흡수 포함)은 앱의 대사와 CLI 변경 명령이 한다.
    public func reconcileForDisplay() async -> [Provider: any Error] {
        reflectLiveActiveWithoutSaving()
    }

    /// 디스크에 쓰지 않고 라이브 신원을 메모리의 활성 값에 반영한다 — 구버전 저장 직후의 CLI
    /// `list`·`status` 용(설계 4.4-4 「CLI 는 복원 결과를 보여 주기만 하고 저장하지 않는다」, 리뷰 1회차
    /// Codex P2-3). 라이브 계정이 등록돼 있지 않거나 로그아웃 상태면 그 풀은 그대로 둔다.
    public func reflectLiveActiveWithoutSaving(providers: Set<Provider>? = nil) -> [Provider: any Error] {
        var failed: [Provider: any Error] = [:]
        for (provider, io) in orderedIOs where providers?.contains(provider) ?? true {
            do {
                // 계정 열쇠(이메일 + 조직)로 고른다 — 같은 이메일의 다른 조직 프로필을 활성으로 보이지 않게
                // (실패 기록 23). 모호하면(`firstAccount` 가 nil) 그 풀은 그대로 둔다.
                guard let key = try io.liveAccountKey(),
                      let profile = store.file.firstAccount(provider: provider, matching: key)
                else { continue }
                store.setActiveInMemoryOnly(profile.id, provider: provider)
            } catch {
                failed[provider] = error
            }
        }
        return failed
    }

    /// 프로바이더별 오류 격리판(설계 4.6). 한 풀의 오류가 다음 풀의 adopt 를 멈추지 않는다.
    /// 반환: 새로 흡수한 첫 프로필, 실패한 프로바이더와 그 오류.
    /// - Parameter providers: 이 풀만 돈다(nil = 전부). 앱은 Antigravity 를 공통 틱과 분리된 작업에서
    ///   따로 돌린다 — agy 키체인 시간 초과가 Claude·Codex 대사를 늦추지 않게(리뷰 1회차 Codex P2-1).
    public func adoptLiveAccountsIsolated(providers: Set<Provider>? = nil)
        async -> (AccountProfile?, [Provider: any Error]) {
        var first: AccountProfile?
        var failed: [Provider: any Error] = [:]
        for (provider, io) in orderedIOs where providers?.contains(provider) ?? true {
            do {
                guard let adopted = try await adoptLiveAccount(provider: provider, io: io) else {
                    continue
                }
                if first == nil { first = adopted }
            } catch {
                failed[provider] = error
            }
        }
        return (first, failed)
    }

    private static func firstError(_ failed: [Provider: any Error]) -> (any Error)? {
        failed.sorted { $0.key.rawValue < $1.key.rawValue }.first?.value
    }

    private func adoptLiveAccount(provider: Provider,
                                  io: any ProviderConfigIO) async throws -> AccountProfile? {
        // ★ 등록 여부를 먼저 확인 — 열쇠(이메일+조직) 읽기는 승인창 없는 값싼 경로다(프로토콜 계약).
        //   Claude의 Keychain 읽기(승인창 유발)는 정말 미등록일 때만.
        //   같은 이메일이라도 조직이 다르면 미등록이다 — 회사 Team과 개인 Max를 한 이메일로 쓰는
        //   사용자의 두 번째 조직이 여기서 새 프로필로 흡수된다.
        guard let key = try io.liveAccountKey(),
              store.file.firstAccount(provider: provider, matching: key) == nil
        else { return nil }
        // ★ 직전에 저장을 거부한 라이브가 그대로면 비밀을 다시 읽지 않는다 — reconcile과 같은 기억을 쓴다
        //   (리뷰 3회차 P2-1). 등록하지 않은 조직의 신원과 다른 조직의 토큰이 놓인 상태(예: 죽은 로그인의
        //   카드를 지운 뒤)는 오래 이어질 수 있고, 그동안 15초마다 Keychain을 두 번 읽게 된다.
        let fingerprint = try? io.liveIdentityFingerprint()
        if let fingerprint, isDeferredLive(provider, fingerprint: fingerprint) { return nil }
        // 비밀+이메일을 두 번 읽어 일치할 때만(전환/리프레시 중 불일치 배제) 저장한다.
        guard let (live, stableEmail) = await io.readStableLiveSecretData(),
              stableEmail == key.emailAddress
        else { return nil }
        guard io.canStoreLiveSecret(live) else {
            rememberRejectedLive(provider, io: io, live: live, fingerprint: fingerprint)
            return nil
        }
        // 신원이 바이트 안에 있으면 **저장하는 바이트의 이메일**과 다시 대조한다(설계 4.1).
        if io.identityIsInSecret, io.email(fromSecret: live) != key.emailAddress { return nil }
        guard let identity = try io.liveIdentity(), identity.key == key else { return nil }
        forgetDeferredLive(provider)
        let nickname = store.file.suggestedNickname(provider: provider, for: identity)
        let profile = try store.upsertProfile(nickname: nickname, provider: provider,
                                              identity: identity, secretData: live)
        try store.setActive(profile.id)
        return profile
    }

    /// 외부(앱 밖) 재로그인 감지 시 상태 대사 (전 프로바이더): 라이브 계정 열쇠(이메일+조직)가
    /// 아는 프로필이면 그 프로필을 활성으로 표시하고 최신 토큰을 흡수한다.
    /// 모르는 계정(같은 이메일의 다른 조직 포함)이면 손대지 않는다 — adopt가 새 프로필로 흡수한다.
    /// 한 풀이 실패해도 나머지 풀은 끝까지 돈 뒤, 첫 오류를 던진다(호환용 — 새 코드는
    /// `reconcileIsolated` 로 실패한 풀을 받는다).
    public func reconcile() async throws {
        if let error = Self.firstError(await reconcileIsolated()) { throw error }
    }

    /// 프로바이더별 오류 격리판(설계 4.6). 반환: 실패한 프로바이더와 그 오류.
    /// 앱은 그 틱에 실패한 풀의 엔진 onTick 과 자동 쓰기를 건너뛰고, CLI 는 오류 한 줄로 보인다.
    @discardableResult
    public func reconcileIsolated(providers: Set<Provider>? = nil) async -> [Provider: any Error] {
        await reconcileIsolatedReportingFollowed(providers: providers).failed
    }

    /// `reconcileIsolated` 와 같고, **이 대사가 라이브를 따라 직접 커밋한** 활성 변경(풀 → 새 활성)을 함께
    /// 돌려준다. 대사가 도는 사이 다른 경로(CLI 전환을 다시 읽은 앱, 자동 전환)가 바꾼 활성은 들어가지
    /// 않는다 — 왕복 차단은 이 값으로만 판정한다(리뷰 2회차 Claude P3-1·Codex P2-2).
    /// `filledEmpty` 는 그 가운데 **비어 있던** 활성을 채운 풀이다(구버전 저장 뒤 복원) — 외부 로그인
    /// 알림에서 뺀다(리뷰 4회차 Codex P3·Claude P3-1).
    public func reconcileIsolatedReportingFollowed(providers: Set<Provider>? = nil)
        async -> (failed: [Provider: any Error], followed: [Provider: UUID], filledEmpty: Set<Provider>) {
        var failed: [Provider: any Error] = [:]
        var followed: [Provider: UUID] = [:]
        var filledEmpty: Set<Provider> = []
        for (provider, io) in orderedIOs where providers?.contains(provider) ?? true {
            do {
                if let (id, previous) = try await reconcile(provider: provider, io: io) {
                    followed[provider] = id
                    if previous == nil { filledEmpty.insert(provider) }
                }
            } catch {
                failed[provider] = error
            }
            // 라이브 값의 지문이 바뀌면(같은 이메일 재로그인·로그아웃) 활성 세대를 늘린다(설계 4.7).
            if let fp = io as? LiveFingerprintReporting {
                store.noteLiveFingerprint(fp.liveFingerprint, provider: provider)
            }
        }
        return (failed, followed, filledEmpty)
    }

    /// 반환: 라이브를 따라 이 대사가 활성 값을 실제로 바꿨으면 그 계정 ID 와 저장 직전의 활성 값.
    @discardableResult
    private func reconcile(provider: Provider,
                           io: any ProviderConfigIO) async throws -> (id: UUID, previous: UUID?)? {
        // 열쇠(이메일+조직)는 승인창 없는 값싼 경로로 읽는다. 활성 계정이 그대로면 비밀 읽기
        // (Claude는 Keychain)를 아예 하지 않아 15초 주기 승인창 폭탄을 막는다.
        guard let key = try io.liveAccountKey(),
              let profile = store.file.firstAccount(provider: provider, matching: key)
        else { return nil }
        // 변화 감지 중에 새로 읽은 값이 활성 프로필의 것이면 그 스냅샷으로 저장한다(네트워크 0) —
        // 같은 이메일로 다시 로그인해 받은 새 refresh 토큰이 저장되지 않은 채 남지 않게(설계 4.2).
        // 신원은 **그 바이트의 이메일**로 대조한다(이 경로는 신원이 바이트 안에 있는 Antigravity 만 쓴다).
        if let reporter = io as? LiveValueChangeReporting, let changed = reporter.takeChangedLiveValue(),
           store.file.activeByProvider[provider] == profile.id,
           io.email(fromSecret: changed) == profile.emailAddress,
           (try? store.secretData(for: profile.id)) != changed {
            try saveLiveSecret(changed, for: profile.id)
        }
        let activeUnchanged = store.file.activeByProvider[provider] == profile.id
        // 존재 확인은 stat으로 — 15초 주기 정상 경로에서 비밀 파일 전체를 읽지 않는다
        // (파일이 없을 때만 secretData가 레거시 Keychain 이관까지 시도).
        let alreadyHasSecret = FileManager.default
            .fileExists(atPath: env.secretFile(for: profile.id).path)
            || (try? store.secretData(for: profile.id)) != nil
        if activeUnchanged && alreadyHasSecret { return nil } // 정상 상태 — 비밀 접근 없음

        // ★ 직전에 저장을 거부한 라이브가 그대로면 비밀을 다시 읽지 않는다(리뷰 P2-1, 실패 기록 3·3b).
        //   거부되는 상태(예: 옛 토큰을 캐시한 세션의 bootstrap이 신원만 되돌림)는 새 claude 세션이 다시
        //   bootstrap할 때까지 이어질 수 있고, 그동안 15초마다 Keychain을 두 번 읽게 된다(`security`
        //   subprocess, 파티션 리스트가 리셋된 환경이면 승인창). 신원 지문(파일 한 번 읽기)이 바뀌거나
        //   간격이 지나면 다시 본다(간격은 거부 사유별 — 위 두 간격 참조). 로그인은 oauthAccount를 다시
        //   쓰므로 곧바로 다시 보게 된다.
        //   "라이브 이메일이 활성과 같으면 조기 반환"으로 막지 않는다 — 같은 이메일의 다른 조직으로 앱 밖에서
        //   로그인한 경우를 reconcile이 따라가지 못하고, 5분 동기화도 종류가 다른 토큰은 보정하지 않는다.
        let fingerprint = try? io.liveIdentityFingerprint()
        if let fingerprint, isDeferredLive(provider, fingerprint: fingerprint) { return nil }

        // 실제 변화가 있을 때만(드묾) 비밀+이메일 두 번 읽어 일치 확인 후 저장. 열쇠를 한 번 더
        // 읽어 그 사이 같은 이메일의 다른 조직으로 바뀌지 않았는지도 확인한다(파일 읽기 한 번).
        guard let (live, stableEmail) = await io.readStableLiveSecretData(),
              stableEmail == key.emailAddress,
              (try? io.liveAccountKey()) == key else { return nil }
        // ★ 토큰과 신원이 어긋났으면 활성도 옮기지 않는다 — 열쇠가 가리키는 프로필이 실제 로그인이
        //   아니다. 이 경로가 "Max 토큰을 Team 프로필에 저장 + Team을 활성으로"를 만들던 자리다(실패 기록 24).
        //   불안정한 읽기(위 guard)는 로그인 도중의 일시적인 상태라 기억하지 않는다 — 거부만 기억한다.
        guard io.canStoreLiveSecret(live) else {
            rememberRejectedLive(provider, io: io, live: live, fingerprint: fingerprint)
            return nil
        }
        // 신원이 바이트 안에 있으면 **저장하는 바이트의 이메일**과 다시 대조한다(설계 4.1).
        if io.identityIsInSecret, io.email(fromSecret: live) != profile.emailAddress { return nil }
        forgetDeferredLive(provider)
        try saveLiveSecret(live, for: profile.id)
        guard !activeUnchanged else { return nil }
        // 안정 읽기(0.7초) 사이에 다른 경로가 이미 활성을 바꿨을 수 있으므로, 이 저장이 실제로 바꿨는지는
        // 저장 직전 값으로 판정한다.
        let (changed, previous) = try store.setActiveReportingPrevious(profile.id)
        // 외부(사용자) 로그인으로 활성이 바뀐 것 — 자동 전환 상태가 아니므로
        // 플래그를 내려 onTick의 primary 자동 복귀를 막는다 (앱·CLI 공통 경로).
        try store.setAutoSwitchedFromPrimary(false, provider: provider)
        return changed ? (profile.id, previous) : nil
    }

    private func isDeferredLive(_ provider: Provider, fingerprint: Data) -> Bool {
        deferredLiveLock.lock(); defer { deferredLiveLock.unlock() }
        guard let deferred = deferredLive[provider], deferred.fingerprint == fingerprint else { return false }
        let interval = deferred.lacksLogin ? loggedOutLiveRecheckInterval : deferredLiveRecheckInterval
        return Date().timeIntervalSince(deferred.at) < interval
    }

    /// 저장을 거부한 라이브를 기억한다. 간격은 거부 사유로 정한다 — 로그인이 없는 상태는 다른 세션의 refresh가
    /// 신원을 그대로 둔 채 채울 수 있어 짧게, 조직이 어긋난 상태는 신원이 바뀌어야 풀리므로 길게.
    private func rememberRejectedLive(_ provider: Provider, io: any ProviderConfigIO,
                                      live: Data, fingerprint: Data?) {
        guard let fingerprint else { return }
        let lacksLogin = io.liveSecretLacksLogin(live)
        deferredLiveLock.lock(); defer { deferredLiveLock.unlock() }
        deferredLive[provider] = DeferredLive(fingerprint: fingerprint, at: Date(), lacksLogin: lacksLogin)
    }

    private func forgetDeferredLive(_ provider: Provider) {
        deferredLiveLock.lock(); defer { deferredLiveLock.unlock() }
        deferredLive[provider] = nil
    }
}
