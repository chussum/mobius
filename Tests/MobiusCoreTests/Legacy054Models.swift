import Foundation
@testable import MobiusCore

// ★ v0.5.4 의 accounts.json 모델 **고정 사본**(git show v0.5.4:Sources/MobiusCore/Models.swift 에서
//   타입 이름에 V054 접두사를 붙이고 `public` 을 지웠다. `CredentialsSnapshot` 은 뺐다). v0.5.5 의
//   Models.swift 는 v0.5.4 와 같다 — 이 사본이 지금 배포된 최신 릴리스(계정 열쇠에 organizationUuid 가
//   들어간 첫 판)를 대표한다. 다운그레이드 호환 테스트(설계 4.4-6)가 "구버전이 새 파일을 어떻게 읽고
//   다시 저장하는가"를 재현하는 데 쓴다. 본체 모델이 바뀌어도 이 파일은 고치지 않는다.
//   `ProviderIdentity` 는 본체 타입을 그대로 쓴다(닉네임 제안 함수의 인자일 뿐 저장 형식과 무관).
// swiftlint:disable all

/// 계정이 속한 AI CLI 프로바이더. 전환·자동 fallback은 프로바이더별 풀에서 독립적으로 동작한다.
enum V054Provider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

struct V054RateLimitInfo: Codable, Equatable, Sendable {
    var resetsAt: Date
    var recordedAt: Date
    /// 모델 전용 한도(예: Fable 주간)인가 — 계정 자체(5시간/주간)는 여유가 있을 수 있다.
    /// 이 경우 자동 전환은 "사용자가 그 계정을 직접 고르지 않았을 때"만 일어난다(pin 존중).
    var modelScoped: Bool
    init(resetsAt: Date, recordedAt: Date, modelScoped: Bool = false) {
        self.resetsAt = resetsAt
        self.recordedAt = recordedAt
        self.modelScoped = modelScoped
    }

    // 하위 호환: modelScoped 키가 없는 구버전 파일도 디코드되게 (없으면 false).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resetsAt = try c.decode(Date.self, forKey: .resetsAt)
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        modelScoped = try c.decodeIfPresent(Bool.self, forKey: .modelScoped) ?? false
    }
}

/// 임계값 선제 경고 기록 — **소진(rateLimit)이 아니다.** 계정 카드에만 노출되는 "soft" 신호로,
/// 아직 쓸 수 있지만 곧 찰 것 같은 상태를 뜻한다. rateLimit에 플래그를 얹지 않고 **물리적으로
/// 분리된 필드**로 둔 이유: isLimited/autoSwitchMayLeave/메뉴바/CLI가 전부 rateLimit만 읽으므로
/// 이 구조에서는 경고가 소진으로 새어나갈 수 없다 (같은 레코드에 플래그를 얹으면 모든 소비자가
/// 그 플래그를 각자 알아야 하는 버그 클래스가 된다).
struct V054AdvisoryRecord: Codable, Equatable, Sendable {
    /// 경고를 유발한 사용률(백분율)
    var utilization: Double
    /// 이 경고가 걸린 창의 리셋 시각 — 이 시각이 지나면 경고는 자동 무효(시간 게이트)
    var resetsAt: Date
    /// 처음 경고가 올라온 시각. 수동 핀이 "경고를 보고 나서 일부러 돌아온 것"인지
    /// 판정할 때 pinnedAt과 비교된다.
    var detectedAt: Date

    init(utilization: Double, resetsAt: Date, detectedAt: Date) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.detectedAt = detectedAt
    }

    /// 임계값 히스테리시스 폭(포인트) — 경계에서 사용률이 오르내릴 때 경고가 깜빡이며
    /// 알림·후보 탐색 백오프를 매번 리셋하는 것을 막는다.
    static let hysteresis: Double = 5

    /// 경고를 세울 조건 — 임계값 **이상**
    static func shouldSet(utilization: Double, threshold: Double) -> Bool {
        utilization >= threshold
    }

    /// 경고를 내릴 조건 — 임계값 - 5 **이하**. 둘 사이(밴드 내부)에서는 shouldSet도
    /// shouldClear도 false라 기존 상태가 그대로 유지된다.
    static func shouldClear(utilization: Double, threshold: Double) -> Bool {
        utilization <= threshold - hysteresis
    }
}

/// 한 프로바이더 안에서 계정을 구분하는 열쇠 — 이메일 **과 조직**.
///
/// 이메일 하나로는 부족하다(실패 기록 23): Claude는 한 이메일이 여러 조직(개인 Max·회사 Team·
/// 회사 Enterprise)에 동시에 속할 수 있고, 조직마다 자격증명·한도·약관이 따로다. `~/.claude.json`의
/// `oauthAccount.organizationUuid`가 그 조직을 가리킨다.
/// `organizationUuid`가 빈 문자열이면 "조직을 모른다"는 뜻이다 — 조직 개념이 없는 프로바이더(Codex),
/// 이 필드가 생기기 전에 등록된 구버전 프로필, 조직 정보를 안 주는 옛 claude.json. 이때는
/// 이메일만으로 대조해 예전 동작을 유지한다(`matches`).
struct V054AccountKey: Equatable, Sendable {
    var emailAddress: String
    var organizationUuid: String

    init(emailAddress: String, organizationUuid: String = "") {
        self.emailAddress = emailAddress
        self.organizationUuid = organizationUuid
    }

    /// 같은 계정으로 볼 수 있는가. 양쪽이 조직을 알면 조직까지 같아야 하고, 한쪽이라도 모르면
    /// 이메일만 본다. "정확히 맞는 쪽 우선"이 필요한 조회는 `V054AccountsFile.firstAccount(provider:matching:)`.
    func matches(_ other: V054AccountKey) -> Bool {
        guard emailAddress == other.emailAddress else { return false }
        if organizationUuid.isEmpty || other.organizationUuid.isEmpty { return true }
        return organizationUuid == other.organizationUuid
    }
}

struct V054AccountProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var provider: V054Provider
    var nickname: String
    var emailAddress: String
    var organizationName: String
    /// 조직 UUID (`~/.claude.json` oauthAccount.organizationUuid). 같은 이메일의 다른 조직을
    /// 구분한다 — `V054AccountKey` 참조. 구버전 프로필은 "" (앱·CLI가 로드 직후 저장 스냅샷에서 채운다:
    /// `Switcher.backfillOrganizationUUIDs`).
    var organizationUuid: String
    var tierDescription: String      // 표시용 예: "Max 20x", "Team", "Pro"
    var needsReauth: Bool
    var rateLimit: V054RateLimitInfo?
    var hasDesktopSnapshot: Bool     // Claude 전용 (Desktop 동시 전환)
    /// 사용자가 이 계정을 직접(수동) 골랐는가. true면 모델 전용 한도(Fable 등)로는
    /// 자동 전환해 밀어내지 않는다 — "1회 자동 전환 후 내가 되돌리면 머문다"는 규칙.
    /// 계정 자체 한도(5시간/주간)가 차면 이 핀은 무시된다(진짜 사용 불가이므로).
    var userPinned: Bool
    /// userPinned를 세운 시각. "경고를 보고 나서 일부러 돌아왔는가"를 판정하려면 핀만으로는
    /// 부족하다 — 몇 시간 전에 눌러둔 핀과 방금 누른 핀을 구분해야 advisory 전환의 거부권을
    /// 올바른 방향으로 줄 수 있다 (advisory.detectedAt보다 나중인 핀만 거부권을 갖는다).
    var pinnedAt: Date?
    /// 임계값 선제 경고 (소진 아님). **카드 UI와 엔진의 advisory 경로만** 읽는다 —
    /// isLimited/autoSwitchMayLeave/메뉴바/CLI는 이 필드를 절대 보지 않는다.
    var advisory: V054AdvisoryRecord?

    init(id: UUID, provider: V054Provider = .claude, nickname: String, emailAddress: String,
                organizationName: String, tierDescription: String, organizationUuid: String = "",
                needsReauth: Bool = false, rateLimit: V054RateLimitInfo? = nil,
                hasDesktopSnapshot: Bool = false, userPinned: Bool = false,
                pinnedAt: Date? = nil, advisory: V054AdvisoryRecord? = nil) {
        self.id = id; self.provider = provider
        self.nickname = nickname; self.emailAddress = emailAddress
        self.organizationName = organizationName; self.tierDescription = tierDescription
        self.organizationUuid = organizationUuid
        self.needsReauth = needsReauth; self.rateLimit = rateLimit
        self.hasDesktopSnapshot = hasDesktopSnapshot; self.userPinned = userPinned
        self.pinnedAt = pinnedAt; self.advisory = advisory
    }

    /// 하위호환 디코딩 — 새 키(provider, userPinned 등)가 없는 구버전 파일도 디코드되게.
    /// provider 없으면 Claude로 간주. 다른 사용자가 업데이트해도 계정 목록이 깨지지 않도록.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        provider = try c.decodeIfPresent(V054Provider.self, forKey: .provider) ?? .claude
        nickname = try c.decode(String.self, forKey: .nickname)
        emailAddress = try c.decode(String.self, forKey: .emailAddress)
        organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName) ?? ""
        organizationUuid = try c.decodeIfPresent(String.self, forKey: .organizationUuid) ?? ""
        tierDescription = try c.decodeIfPresent(String.self, forKey: .tierDescription) ?? ""
        needsReauth = try c.decodeIfPresent(Bool.self, forKey: .needsReauth) ?? false
        rateLimit = try c.decodeIfPresent(V054RateLimitInfo.self, forKey: .rateLimit)
        hasDesktopSnapshot = try c.decodeIfPresent(Bool.self, forKey: .hasDesktopSnapshot) ?? false
        userPinned = try c.decodeIfPresent(Bool.self, forKey: .userPinned) ?? false
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        advisory = try c.decodeIfPresent(V054AdvisoryRecord.self, forKey: .advisory)
    }

    /// 프로바이더 풀 안에서 이 프로필을 가리키는 열쇠 (이메일 + 조직).
    var key: V054AccountKey {
        V054AccountKey(emailAddress: emailAddress, organizationUuid: organizationUuid)
    }

    /// 표시용 조직 이름. 개인 구독의 자동 생성 조직은 이름에 정보가 없으므로 비운다 — 회사 조직
    /// (Team/Enterprise)의 이름만 같은 이메일의 계정들을 구분하는 데 쓸모가 있다.
    var organizationLabel: String {
        Self.isPersonalOrganizationName(organizationName, email: emailAddress) ? "" : organizationName
    }

    /// 카드·CLI의 부제 — 조직 이름과 등급 중 **있는 것만** " · "로 잇는다(빈 쪽이 있으면 구분자도 없다).
    var subtitle: String {
        [organizationLabel, tierDescription].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 개인 구독의 자동 생성 조직인가 — 실측 형태는 `"<이메일>'s Organization"`. 휴리스틱이라
    /// 틀려도 결과는 "조직 이름을 표시하느냐" 정도의 차이뿐이다(대조에는 쓰지 않는다).
    static func isPersonalOrganizationName(_ name: String, email: String) -> Bool {
        name.isEmpty || name.hasPrefix(email) || name.hasSuffix("'s Organization")
    }

    /// 지금 한도에 걸려 있는가 (리셋 시각 전인가)
    /// **계정 자체**(5시간/주간)가 막혔는가 = "지금 이 계정으로는 아무것도 못 한다".
    ///
    /// ★ 모델 전용 한도(Fable 등)는 **여기 포함하지 않는다**(2026-08-15, 이슈 #19 후속).
    ///   그 계정은 다른 모델로 멀쩡히 쓸 수 있으므로 "못 쓰는 계정"이 아니다. 예전엔 둘을
    ///   섞어 봤는데, 며칠짜리 모델 한도 하나가 계정을 통째로 후보에서 빼 **"모든 계정 한도
    ///   소진"**이 뜨는 경로가 됐다(메뉴바·CLI 문구도 거짓말이 된다). 모델 한도는
    ///   `isModelLimited`로 따로 보고, 그 한도 때문에 떠날 때만 후보에서 걸러낸다.
    func isLimited(now: Date) -> Bool {
        guard let rl = rateLimit, !rl.modelScoped else { return false }
        return now < rl.resetsAt
    }

    /// **모델 전용** 한도(Fable 등)로 막혔는가. 계정 자체는 여유가 있을 수 있다.
    /// 이 계정으로 옮겨도 **같은 모델은 여전히 막혀 있으므로**, 모델 한도 때문에 떠나는
    /// 전환에서는 후보에서 제외한다(그 외의 전환에서는 정상 후보다).
    func isModelLimited(now: Date) -> Bool {
        guard let rl = rateLimit, rl.modelScoped else { return false }
        return now < rl.resetsAt
    }

    /// 임계값 선제 경고가 지금 유효한가 (경고가 걸린 창의 리셋 전인가). isLimited와 같은
    /// 시간 게이트 모양이지만 **의미가 다르다 — 소진이 아니라 "곧 찰 것 같다"이다.**
    /// ★ 이 함수는 isLimited, autoSwitchMayLeave, 메뉴바 상태에서 **절대 읽지 말 것.**
    /// 그 세 곳은 "이 계정을 지금 쓸 수 없다"는 정직한 신호라서, 경고가 섞이는 순간
    /// 메뉴바·CLI·알림 문구가 거짓말을 하게 된다. 소비자는 카드 UI와 엔진 advisory 경로뿐.
    func hasActiveAdvisory(now: Date) -> Bool {
        guard let ad = advisory else { return false }
        return now < ad.resetsAt
    }

    /// 자동 전환이 이 계정을 밀어내도 되는가. 모델 전용 한도 + 사용자 핀이면 밀어내지 않는다.
    /// (계정 자체 한도로 걸린 경우엔 modelScoped=false라 핀과 무관하게 밀어낼 수 있다.)
    func autoSwitchMayLeave(now: Date) -> Bool {
        if needsReauth || isLimited(now: now) { return true }
        return isModelLimited(now: now) && !userPinned
    }
}

/// accounts.json 전체. 모든 프로바이더의 계정이 한 배열에 담기고, 활성/자동전환 상태는
/// 프로바이더별 풀로 독립 관리된다. 프로바이더 내 순서가 우선순위 — 그 프로바이더의
/// 첫 계정이 primary(고정), 이후가 fallback 순서.
struct V054AccountsFile: Codable, Equatable, Sendable {
    var accounts: [V054AccountProfile]
    /// 프로바이더별 활성 계정 id
    var activeByProvider: [V054Provider: UUID]
    /// 프로바이더별: 현재 fallback 활성 상태가 "자동 전환"의 결과인가. 수동 전환/외부
    /// 로그인은 false — onTick의 primary 자동 복귀는 이 플래그가 true일 때만 일어난다
    /// (수동 전환 자동 회귀 방지).
    var autoSwitchedByProvider: [V054Provider: Bool]
    /// 프로바이더별 자동 전환 on/off (없는 키는 켬 — isAutoSwitchEnabled 참조)
    var autoSwitchByProvider: [V054Provider: Bool]
    var desktopSyncEnabled: Bool       // 수동 전환 시 Desktop 동시 전환 (Claude 전용)
    var desktopAutoSwitchEnabled: Bool // 자동 전환 시에도 Desktop 동시 전환 (기본 끔)

    init(accounts: [V054AccountProfile] = [], activeAccountID: UUID? = nil,
                autoSwitchEnabled: Bool = true, desktopSyncEnabled: Bool = true,
                desktopAutoSwitchEnabled: Bool = false, autoSwitchedFromPrimary: Bool = false) {
        self.accounts = accounts
        self.activeByProvider = activeAccountID.map { [.claude: $0] } ?? [:]
        self.autoSwitchedByProvider = autoSwitchedFromPrimary ? [.claude: true] : [:]
        self.autoSwitchByProvider = autoSwitchEnabled ? [:]
            : Dictionary(uniqueKeysWithValues: V054Provider.allCases.map { ($0, false) })
        self.desktopSyncEnabled = desktopSyncEnabled
        self.desktopAutoSwitchEnabled = desktopAutoSwitchEnabled
    }

    /// 하위호환 디코딩 — 풀 분리 이전(activeAccountID/autoSwitchedFromPrimary가 최상위
    /// 단일 값이던) accounts.json은 Claude 풀로 흡수하고, 없는 필드는 기본값으로 채운다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([V054AccountProfile].self, forKey: .accounts) ?? []
        if let pools: [V054Provider: UUID] = try Self.decodeProviderMap(c, .activeByProvider) {
            activeByProvider = pools
        } else {
            let legacy = try c.decodeIfPresent(UUID.self, forKey: .legacyActiveAccountID)
            activeByProvider = legacy.map { [.claude: $0] } ?? [:]
        }
        if let flags: [V054Provider: Bool] = try Self.decodeProviderMap(c, .autoSwitchedByProvider) {
            autoSwitchedByProvider = flags
        } else {
            let legacy = try c.decodeIfPresent(Bool.self, forKey: .legacyAutoSwitchedFromPrimary)
            autoSwitchedByProvider = legacy.map { [.claude: $0] } ?? [:]
        }
        if let flags: [V054Provider: Bool] = try Self.decodeProviderMap(c, .autoSwitchByProvider) {
            autoSwitchByProvider = flags
        } else {
            // 구 전역 키는 양쪽 풀에 동일 적용
            let legacy = try c.decodeIfPresent(Bool.self, forKey: .legacyAutoSwitchEnabled) ?? true
            autoSwitchByProvider = legacy ? [:]
                : Dictionary(uniqueKeysWithValues: V054Provider.allCases.map { ($0, false) })
        }
        desktopSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .desktopSyncEnabled) ?? true
        desktopAutoSwitchEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .desktopAutoSwitchEnabled) ?? false
    }

    /// 프로바이더 키 딕셔너리의 디코딩 (키 없으면 nil → 호출측이 레거시 v1 키로 폴백).
    /// - 신형(JSON 객체): `{"claude": …}` — **모르는 프로바이더 키만 스킵**한다. 미래 버전이
    ///   추가한 프로바이더가 있어도 unknown raw value 하나가 파일 전체 디코드 실패(→ corrupt
    ///   백업 + 빈 스토어)로 번지지 않게 한다 (실패 기록 13과 같은 클래스의 예방).
    ///   단 **아는 키의 값 손상은 throw** — try?로 삼키면 손상 파일이 조용히 빈 상태로
    ///   디코드되고 다음 save가 원본을 덮어써, AccountStore의 corrupt 백업 경로(원본 보존)가
    ///   무력화된다 (리뷰 지적).
    /// - 구형(JSON 배열): `["claude", …]` — V054Provider가 CodingKeyRepresentable을 채택하지 않아
    ///   Swift 기본 Dictionary Codable이 배열로 저장하던 초기 v2 파일. 읽기만 지원한다.
    private static func decodeProviderMap<V: Decodable>(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> [V054Provider: V]? {
        // 신형: 항목 단위로 디코드해 "모르는 키 스킵"과 "값 손상 throw"를 구분한다
        if let nested = try? c.nestedContainer(keyedBy: RawKey.self, forKey: key) {
            var out: [V054Provider: V] = [:]
            for k in nested.allKeys {
                guard let provider = V054Provider(rawValue: k.stringValue) else { continue }
                out[provider] = try nested.decode(V.self, forKey: k)
            }
            return out
        }
        guard c.contains(key) else { return nil }
        // 객체가 아니면 구형(배열) — 그마저 아니면 손상이므로 throw (corrupt 백업 경로)
        return try c.decode([V054Provider: V].self, forKey: key)
    }

    /// 임의 문자열 키 (프로바이더 맵의 항목 단위 디코딩용)
    private struct RawKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func stringKeyed<V>(_ map: [V054Provider: V]) -> [String: V] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
    }

    enum CodingKeys: String, CodingKey {
        case accounts, activeByProvider, autoSwitchedByProvider, autoSwitchByProvider
        case desktopSyncEnabled, desktopAutoSwitchEnabled
        case legacyActiveAccountID = "activeAccountID"
        case legacyAutoSwitchedFromPrimary = "autoSwitchedFromPrimary"
        case legacyAutoSwitchEnabled = "autoSwitchEnabled"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accounts, forKey: .accounts)
        // 프로바이더 키 딕셔너리는 [String:]으로 명시 인코딩 — V054Provider를 그대로 쓰면 Swift
        // Dictionary Codable이 JSON 배열(["claude", …])로 저장한다(CodingKeyRepresentable
        // 미채택). 객체 형태여야 사람이 읽을 수 있고 unknown 키 스킵(위 decodeProviderMap)이
        // 가능하다.
        try c.encode(Self.stringKeyed(activeByProvider), forKey: .activeByProvider)
        try c.encode(Self.stringKeyed(autoSwitchedByProvider), forKey: .autoSwitchedByProvider)
        try c.encode(Self.stringKeyed(autoSwitchByProvider), forKey: .autoSwitchByProvider)
        try c.encode(desktopSyncEnabled, forKey: .desktopSyncEnabled)
        try c.encode(desktopAutoSwitchEnabled, forKey: .desktopAutoSwitchEnabled)
        // 다운그레이드 완충: 풀 분리 이전 바이너리도 Claude 활성 상태는 올바르게 읽도록
        // 레거시 키를 함께 기록한다 (구버전이 저장하면 provider 필드가 소실되므로
        // 완전한 하위호환은 아님 — 신구 바이너리 혼용 금지는 문서에 기록).
        try c.encodeIfPresent(activeByProvider[.claude], forKey: .legacyActiveAccountID)
        try c.encode(isAutoSwitchedFromPrimary(.claude), forKey: .legacyAutoSwitchedFromPrimary)
        try c.encode(isAutoSwitchEnabled(.claude), forKey: .legacyAutoSwitchEnabled)
    }

    // MARK: 프로바이더별 풀

    func accounts(of provider: V054Provider) -> [V054AccountProfile] {
        accounts.filter { $0.provider == provider }
    }

    /// 계정이 하나 이상 등록된 풀 — `V054Provider.allCases` 순서를 유지한다.
    /// 팝오버의 탭 노출(계정 없는 프로바이더는 숨김)과 '전체' 탭 섹션이 공유한다.
    var providersWithAccounts: [V054Provider] {
        V054Provider.allCases.filter { !accounts(of: $0).isEmpty }
    }

    func primary(of provider: V054Provider) -> V054AccountProfile? {
        accounts.first { $0.provider == provider }
    }

    func active(of provider: V054Provider) -> V054AccountProfile? {
        guard let id = activeByProvider[provider] else { return nil }
        return accounts.first { $0.id == id && $0.provider == provider }
    }

    func isAutoSwitchedFromPrimary(_ provider: V054Provider) -> Bool {
        autoSwitchedByProvider[provider] ?? false
    }

    // MARK: 계정 열쇠 대조 (이메일 + 조직)

    /// key와 같은 계정의 인덱스. **조직까지 정확히 맞는 프로필을 먼저** 찾고, 없으면 조직을 모르는
    /// 쪽(구버전 프로필, 또는 조직 없는 key)만 이메일로 맞춘다 — 같은 이메일에 조직 A·B 프로필이
    /// 둘 다 있을 때 A의 열쇠가 B를 잡는 일이 없어야 한다. 계정이 없으면 nil.
    ///
    /// ★ **이메일 폴백에서 후보가 둘 이상이면 nil이다.** 조직을 모르는 열쇠와 이메일이 같은
    ///   프로필이 여럿인 상태는 이 변경 이후에 처음 생긴다(그전엔 이메일당 하나였다). 그때
    ///   배열 순서로 아무거나 잡으면 `resaveLiveIntoMatchingProfile`·`reconcile`이 **남의 조직
    ///   토큰을 그 프로필에 저장하고 setActive까지** 한다 — 이 저장소에서 가장 비싼 실패
    ///   클래스(실패 기록 1·13)와 같은 모양이다. 잘못된 기록보다 미룬 판정이 낫다(실패 기록 21):
    ///   소비자는 nil을 받으면 아무것도 안 하고 다음 틱에 다시 본다. 폴백이 더 자주 나는 것뿐
    ///   손해가 없는 방향이다.
    func firstIndex(provider: V054Provider, matching key: V054AccountKey) -> Int? {
        let sameEmail = accounts.indices.filter {
            accounts[$0].provider == provider && accounts[$0].emailAddress == key.emailAddress
        }
        if !key.organizationUuid.isEmpty,
           let exact = sameEmail.first(where: { accounts[$0].organizationUuid == key.organizationUuid }) {
            return exact
        }
        // 여기부터는 한쪽이 조직을 모르는 이메일 폴백이다 — 모호하면 손대지 않는다.
        let loose = sameEmail.filter { accounts[$0].key.matches(key) }
        return loose.count == 1 ? loose.first : nil
    }

    func firstAccount(provider: V054Provider, matching key: V054AccountKey) -> V054AccountProfile? {
        firstIndex(provider: provider, matching: key).map { accounts[$0] }
    }

    /// 새 프로필의 기본 닉네임 — 이메일 앞부분. 같은 풀에 이미 그 이름이 있으면(같은 이메일의 다른
    /// 조직) 조직 이름(개인 구독이면 등급)을 붙여 구분하고, 그래도 겹치면 번호를 단다.
    /// 닉네임은 CLI `switch <닉네임>`의 열쇠라 한 풀 안에서 겹치면 그 계정을 고를 수 없다.
    func suggestedNickname(provider: V054Provider, for identity: ProviderIdentity) -> String {
        let base = String(identity.emailAddress.split(separator: "@").first ?? "account")
        let taken = Set(accounts(of: provider).map(\.nickname))
        guard taken.contains(base) else { return base }
        let personal = V054AccountProfile.isPersonalOrganizationName(identity.organizationName,
                                                                 email: identity.emailAddress)
        let tag = Self.nicknameSlug(personal ? identity.tierDescription : identity.organizationName)
        let candidate = tag.isEmpty ? base : "\(base)-\(tag)"
        guard taken.contains(candidate) else { return candidate }
        var n = 2
        while taken.contains("\(candidate)-\(n)") { n += 1 }
        return "\(candidate)-\(n)"
    }

    /// 닉네임 꼬리표용 슬러그: 소문자, 영숫자 외는 '-' 하나로, 앞뒤 '-' 제거.
    static func nicknameSlug(_ s: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingDash { out.append("-"); pendingDash = false }
                out.append(ch)
            } else if !out.isEmpty {
                pendingDash = true
            }
        }
        return out
    }

    /// 풀별 자동 전환 on/off — 기록이 없는 풀은 켬(기본값)
    func isAutoSwitchEnabled(_ provider: V054Provider) -> Bool {
        autoSwitchByProvider[provider] ?? true
    }

    // MARK: Claude 풀의 경계된 뷰 (Desktop 연동 등 Claude 전용 경로용)

    var activeAccountID: UUID? {
        get { activeByProvider[.claude] }
        set { activeByProvider[.claude] = newValue }
    }
    var autoSwitchedFromPrimary: Bool {
        get { isAutoSwitchedFromPrimary(.claude) }
        set { autoSwitchedByProvider[.claude] = newValue }
    }
    var primary: V054AccountProfile? { primary(of: .claude) }
    var active: V054AccountProfile? { active(of: .claude) }
}
