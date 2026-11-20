import Foundation

public enum ClaudeConfigError: Error { case malformedClaudeJSON }

/// 라이브 스냅샷(토큰 + oauthAccount)을 프로필에 저장해도 되는지의 판정.
public enum LiveSnapshotVerdict: Equatable, Sendable {
    case storable
    /// 쓸 수 있는 refresh 토큰이 없다 — invalid_grant 뒤 비워진 토큰, 재로그인 준비 단계가 남긴
    /// `mcpOAuth`만의 blob, 빈 객체 `{}`
    case loggedOut
    /// 토큰과 oauthAccount가 서로 다른 조직(좌석형 ↔ 개인 구독)을 가리킨다
    case organizationMismatch
}

/// Claude Code 자격증명 3곳(Keychain / .credentials.json / ~/.claude.json oauthAccount)의 읽기·쓰기.
public struct ClaudeConfigIO: Sendable {
    let env: MobiusEnvironment
    let keychain: KeychainClient

    public init(env: MobiusEnvironment, keychain: KeychainClient) {
        self.env = env
        self.keychain = keychain
    }

    // MARK: 읽기

    /// 현재 로그인 상태의 스냅샷. 로그아웃 상태(Keychain·파일 둘 다 없음)면 nil.
    ///
    /// **Keychain을 진실의 원천으로 삼는다** — 실측 결과 이 환경의 Claude Code는
    /// 최신 토큰을 Keychain "Claude Code-credentials"에 쓰고 .credentials.json 파일은
    /// 갱신하지 않는다(낡음). 파일을 우선 읽으면 낡은 토큰이 최신 이메일과 짝지어져
    /// 프로필이 오염된다(실측 버그). 파일은 Keychain이 비었을 때의 폴백일 뿐이다.
    /// 호출측이 매 틱 이걸 부르지 않도록 상위에서 변화 감지로 게이팅한다(승인창 최소화).
    public func readLiveSnapshot() throws -> CredentialsSnapshot? {
        let blob: Data
        if let keychainBlob = try keychain.read(service: env.claudeKeychainService,
                                                account: env.claudeKeychainAccount) {
            blob = keychainBlob
        } else if let fileData = try? Data(contentsOf: env.credentialsFile), !fileData.isEmpty {
            blob = fileData
        } else {
            return nil
        }
        var oauthJSON: Data?
        if let block = try readOAuthAccountDict() {
            oauthJSON = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
        }
        return CredentialsSnapshot(keychainBlob: blob, credentialsFileData: blob,
                                   oauthAccountJSON: oauthJSON)
    }

    public func readOAuthAccountDict() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: env.claudeJSON) else { return nil }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConfigError.malformedClaudeJSON
        }
        return dict["oauthAccount"] as? [String: Any]
    }

    public func liveEmail() throws -> String? {
        try readOAuthAccountDict()?["emailAddress"] as? String
    }

    /// 라이브 상태(토큰+계정 열쇠)를 간격을 두고 두 번 읽어 **값이 일치할 때만** 반환한다.
    /// 로그인/전환 도중 토큰(Keychain)과 계정 정보(~/.claude.json)가 순차 갱신되는 찰나엔
    /// 두 읽기가 달라지므로 nil을 반환해 "새 토큰 + 옛 계정 정보" 오저장을 막는다.
    /// ★ 비교는 이메일이 아니라 **열쇠(이메일+조직)**다 — 같은 이메일의 다른 조직으로 바뀌는
    ///   찰나는 이메일만 보면 안정으로 오판한다(실패 기록 23). 통째 JSON 비교는 쓰지 않는다:
    ///   claude가 profileFetchedAt 등을 수시로 다시 써서 정상 상태에서도 두 읽기가 달라진다.
    ///
    /// 파일 mtime 기반 판정은 부적합하다 — 활성 claude 세션이 ~/.claude.json을 자주 쓰므로
    /// "N초간 idle" 조건이 영영 충족되지 않아 로그인 완료 감지가 막힌다(실측 버그). 그래서
    /// 파일이 바쁜지와 무관하게 값 자체를 두 번 비교한다.
    public func readStableLiveSnapshot(gap: Duration = .milliseconds(700))
        async -> (snapshot: CredentialsSnapshot, email: String)? {
        guard let s1 = try? readLiveSnapshot(), let e1 = try? liveEmail() else { return nil }
        try? await Task.sleep(for: gap)
        guard let s2 = try? readLiveSnapshot(), let e2 = try? liveEmail() else { return nil }
        guard s1.keychainBlob == s2.keychainBlob, e1 == e2,
              Self.identity(fromSnapshot: s1)?.key == Self.identity(fromSnapshot: s2)?.key
        else { return nil }
        return (s2, e2)
    }

    // MARK: 쓰기

    public func writeLiveSnapshot(_ snap: CredentialsSnapshot) throws {
        try keychain.write(service: env.claudeKeychainService,
                           account: env.claudeKeychainAccount, data: snap.keychainBlob)
        try writeAtomic(snap.credentialsFileData, to: env.credentialsFile, mode: 0o600)
        try patchOAuthAccount(snap.oauthAccountJSON)
    }

    private func patchOAuthAccount(_ oauthJSON: Data?) throws {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: env.claudeJSON) {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ClaudeConfigError.malformedClaudeJSON }
            dict = existing
        }
        if let oauthJSON,
           let block = try JSONSerialization.jsonObject(with: oauthJSON) as? [String: Any] {
            dict["oauthAccount"] = block
        } else {
            dict.removeValue(forKey: "oauthAccount")
        }
        let out = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try writeAtomic(out, to: env.claudeJSON, mode: 0o600)
    }

}

// MARK: - ProviderConfigIO (secret data = CredentialsSnapshot JSON — 기존 비밀 파일 포맷 그대로)

extension ClaudeConfigIO: ProviderConfigIO {
    public var provider: Provider { .claude }
    /// Claude 자격증명 blob 에는 계정 식별자가 없다 — 이메일은 `~/.claude.json` 으로 대조한다.
    public func email(fromSecret data: Data) -> String? { nil }

    /// 스냅샷에 함께 캡처한 oauthAccount 블록의 신원 — 토큰을 읽은 그 순간의 신원이다. 따로 읽은 열쇠
    /// (`liveAccountKey`)와 다르면 두 읽기 사이에 로그인이 바뀐 것이다(병합 리뷰 Codex P1-2).
    public func identity(fromSecret data: Data) -> ProviderIdentity? {
        guard let snap = try? JSONDecoder().decode(CredentialsSnapshot.self, from: data) else { return nil }
        return Self.identity(fromSnapshot: snap)
    }

    public func readLiveSecretData() throws -> Data? {
        guard let snap = try readLiveSnapshot() else { return nil }
        return try JSONEncoder().encode(snap)
    }

    public func liveIdentity() throws -> ProviderIdentity? {
        guard let block = try readOAuthAccountDict() else { return nil }
        return Self.identity(fromOAuthBlock: block)
    }

    /// 이메일 + organizationUuid — `liveEmail`과 같은 파일 한 번 읽기(승인창 없음).
    public func liveAccountKey() throws -> AccountKey? {
        guard let block = try readOAuthAccountDict() else { return nil }
        return Self.identity(fromOAuthBlock: block)?.key
    }

    /// oauthAccount 블록 전체(키 정렬 JSON) — 파일 한 번 읽기(승인창 없음). 열쇠만 보지 않는 이유: 로그인은
    /// 이 블록을 지우고 다시 쓰므로(2.1.281 실측, 핵심 사실 "토큰과 신원은 쓰는 경로가 다르다"), 같은 조직으로
    /// 다시 로그인해 열쇠가 그대로여도 지문은 바뀐다. `profileFetchedAt` 같은 필드도 가끔 바뀌는데, 그때는
    /// 한 번 더 읽을 뿐이다.
    public func liveIdentityFingerprint() throws -> Data? {
        guard let block = try readOAuthAccountDict() else { return nil }
        return try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
    }

    /// oauthAccount 블록 → 표시용 신원. 라이브 읽기와 스냅샷 기반 등록(AccountStore)이 공유.
    /// organizationUuid가 없는 옛 claude.json이면 ""(조직 미상)으로 둔다 — 이메일만으로 대조된다.
    public static func identity(fromOAuthBlock block: [String: Any]) -> ProviderIdentity? {
        guard let email = block["emailAddress"] as? String else { return nil }
        return ProviderIdentity(emailAddress: email,
                                organizationName: block["organizationName"] as? String ?? "",
                                tierDescription: tierDescription(from: block),
                                organizationUuid: block["organizationUuid"] as? String ?? "")
    }

    /// 저장 스냅샷의 oauthAccount 블록에서 신원을 꺼낸다 — 라이브를 보지 않으므로 "그 스냅샷이
    /// 어느 계정·조직의 것인가"를 정확히 답한다(구버전 프로필의 조직 UUID 채우기, CLI capture).
    public static func identity(fromSnapshot snap: CredentialsSnapshot) -> ProviderIdentity? {
        guard let json = snap.oauthAccountJSON,
              let block = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }
        return identity(fromOAuthBlock: block)
    }

    /// "default_claude_max_20x" → "Max 20x" 정도의 사람이 읽는 문자열로.
    /// ★ 좌석형 조직(Team·Enterprise)은 organizationRateLimitTier를 **보지 않는다**. 2026-09-24 실측에서
    ///   Team의 organizationRateLimitTier는 `"default_raven"`으로 채워져 와서, 등급 칸에 내부 코드명
    ///   "Raven"이 떴다. 조직 한도 등급은 개인 구독(Max 5x·20x)에서만 사람이 읽을 이름이다.
    /// ★ 좌석형인지는 `isSeatOrganization` **한 곳**에서 정한다 — 저장 판정과 같은 규칙이어야 한다.
    ///   로그인 직후에는 organizationType이 비어 있고 seatTier만 있어서(아래 판정의 주석), organizationType만
    ///   보면 LoginFlow가 막 등록한 Team 카드가 "Raven"이나 "Team Tier 1"로 뜬다(리뷰 지적). 이때는 seatTier의
    ///   앞 낱말(`"team_tier_1"` → "Team")을 쓴다 — 다른 Team 카드와 같은 표기가 된다. 판정이 organizationType을
    ///   먼저 보므로, refresh가 seatTier만 덮어쓴 개인 구독 신원은 개인 구독 등급으로 남는다.
    static func tierDescription(from block: [String: Any]) -> String {
        if isSeatOrganization(oauthBlock: block) == true {
            switch block["organizationType"] as? String {
            case "claude_team": return "Team"
            case "claude_enterprise": return "Enterprise"
            default:
                let word = ((block["seatTier"] as? String) ?? "").split(separator: "_").first.map(String.init) ?? ""
                return word.prefix(1).uppercased() + word.dropFirst()
            }
        }
        let tier = (block["organizationRateLimitTier"] as? String)
            ?? (block["organizationType"] as? String) ?? ""
        return tier.replacingOccurrences(of: "default_", with: "")
            .replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            // `capitalized`는 "20x"를 "20X"로 만든다 — 글자로 시작하는 낱말만 첫 글자를 올린다.
            .map { $0.first?.isLetter == true ? $0.prefix(1).uppercased() + $0.dropFirst() : String($0) }
            .joined(separator: " ")
    }

    /// oauthAccount 블록이 좌석형 조직(Team·Enterprise)을 가리키는가. 개인 구독이면 false, 모르면 nil.
    /// ★ `organizationType`을 먼저 보고, 없을 때만 `seatTier`를 본다. 판정 근거는 "organizationUuid와 **같은
    ///   쓰기**로 바뀌는 필드인가"다(claude 2.1.281 바이너리 실측).
    ///   - organizationType은 bootstrap이 organizationUuid·organizationName·seatTier와 함께 쓴다. 로그인은 ①에서
    ///     oauthAccount를 지우므로 로그인 직후(④ bootstrap 전)에는 아예 없다. 즉 있으면 organizationUuid와 짝이 맞다.
    ///   - seatTier는 로그인(②)과 bootstrap이 organizationUuid와 함께 쓰지만, **refresh도** 프로필을 다시 받으면
    ///     그 토큰의 프로필에서 seatTier만 덮어쓴다(organizationUuid·organizationType은 병합 대상이 아니다).
    ///     그래서 신원이 개인 Max로 되돌려진 라이브에서 Team 토큰이 refresh되면 seatTier만 `"team_tier_1"`이
    ///     되고, seatTier를 먼저 보면 Team 토큰과 Max 신원이 짝이 맞는 것으로 판정돼 사고와 같은 방향의
    ///     섞인 저장이 다시 열린다(리뷰 3회차 P1).
    ///   organizationType이 없는 구간(로그인 직후, 또는 그 구간에 등록한 저장본을 설치한 뒤 다음 bootstrap
    ///   전)에는 seatTier를 쓴다. 대개 로그인이 organizationUuid와 함께 쓴 값이지만, refresh의 병합은 CAS
    ///   결과와 상관없이 일어나므로 그 사이 전환이 겹치면 다른 토큰의 값일 수 있다. 그때는 대개 거짓 거부로
    ///   끝나고 bootstrap이 organizationType을 채우면 풀린다(리뷰 4회차 P3-1).
    /// ★ 전제: 개인 구독의 seatTier는 null이다(2026-09-24 실측 한 번: 개인 Max null, Team `"team_tier_1"`).
    ///   이제 이 전제는 organizationType이 없는 짧은 구간에만 쓰인다.
    static func isSeatOrganization(oauthBlock block: [String: Any]) -> Bool? {
        switch block["organizationType"] as? String {
        case "claude_team", "claude_enterprise": return true
        case "claude_max", "claude_pro": return false
        default: break
        }
        if let seat = block["seatTier"] as? String, !seat.isEmpty { return true }
        return nil
    }

    /// 라이브 스냅샷을 프로필에 저장해도 되는가 — 토큰(Keychain)과 신원(~/.claude.json)이
    /// **같은 로그인**의 것인가를 네트워크 없이 판정한다(실패 기록 24).
    ///
    /// 두 곳은 쓰는 주체와 시점이 다르다. claude는 refresh 때 토큰만 쓰고 oauthAccount의
    /// organizationUuid는 건드리지 않으며, 세션 시작 때의 bootstrap은 **그 프로세스가 쥔 토큰**의
    /// 조직으로 oauthAccount를 다시 쓴다(2.1.281 실측). 전환 직후 옛 토큰을 캐시한 세션(캐시 30초)이
    /// bootstrap하면 oauthAccount만 옛 조직으로 돌아가고, Keychain 토큰이 빈 문자열로 지워진 뒤에는
    /// 다른 세션의 refresh 결과가 그 자리를 채울 수 있다. 이렇게 두 곳이 서로 다른 조직을 가리킬 때
    /// 짝지어 저장하면 조직 A의 토큰이 조직 B 프로필에 들어가고, 그 뒤로는 두 프로필이 한 토큰 계보를
    /// 나눠 가져 한쪽이 회전할 때마다 다른 쪽이 invalid_grant가 된다.
    ///
    /// 판정 근거는 blob의 `subscriptionType`이다. claude는 이 값을 로그인 때 조직 종류에서 만들고,
    /// 조직 종류를 모르면 null로 둔다. null인 계보에서는 판정할 수 없어 `.storable`이 된다
    /// (2026-09-24 실측 환경에서는 Team `"team"`, 개인 Max `"max"`로 채워져 있었다).
    ///
    /// 판정은 좌석형(Team·Enterprise)인지 개인 구독(Max·Pro)인지만 본다. 같은 이메일의 개인 조직은
    /// 하나뿐이라 회사 조직과 개인 구독이 섞이는 경우를 정확히 잡는다. 같은 종류의 두 조직(Team과
    /// 다른 Team)은 이 신호로 가를 수 없다 — 그건 폴백 refresh 응답의 조직 UUID가 잡는다
    /// (`FallbackAuthChecker`). Pro→Max처럼 개인 구독 안에서 요금제가 바뀌어도 오판하지 않는다.
    public static func liveSnapshotVerdict(_ snap: CredentialsSnapshot) -> LiveSnapshotVerdict {
        if CredentialBlob.lacksLogin(snap.keychainBlob) { return .loggedOut }
        guard let tokenSeat = CredentialBlob.isSeatSubscription(from: snap.keychainBlob),
              let json = snap.oauthAccountJSON,
              let block = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let accountSeat = isSeatOrganization(oauthBlock: block)
        else { return .storable }   // 한쪽이라도 모르면 막지 않는다(구버전 claude·테스트 blob)
        return tokenSeat == accountSeat ? .storable : .organizationMismatch
    }

    public func readStableLiveSecretData(gap: Duration) async -> (data: Data, email: String)? {
        guard let (snap, email) = await readStableLiveSnapshot(gap: gap),
              let data = try? JSONEncoder().encode(snap) else { return nil }
        return (data, email)
    }

    public func writeLiveSecretData(_ data: Data) throws {
        try writeLiveSnapshot(try JSONDecoder().decode(CredentialsSnapshot.self, from: data))
    }

    public func canStoreLiveSecret(_ data: Data) -> Bool {
        guard let snap = try? JSONDecoder().decode(CredentialsSnapshot.self, from: data) else { return false }
        return Self.liveSnapshotVerdict(snap) == .storable
    }

    public func liveSecretLacksLogin(_ data: Data) -> Bool {
        guard let snap = try? JSONDecoder().decode(CredentialsSnapshot.self, from: data) else { return false }
        return Self.liveSnapshotVerdict(snap) == .loggedOut
    }

    /// 어긋난 라이브(`.organizationMismatch`)의 토큰 종류(좌석형/개인 구독)가 `stored`의 oauthAccount
    /// 조직 종류와 같으면, 라이브 토큰에 `stored`의 oauthAccount를 붙인 스냅샷을 돌려준다.
    /// 옛 토큰을 캐시한 세션의 bootstrap이 oauthAccount만 옛 조직으로 되돌린 경우, Keychain 토큰은
    /// Mobius가 설치한 활성 프로필의 것이 맞다(2.1.281 refresh 저장은 CAS라 다른 세션이 덮지 못한다).
    /// 그 토큰을 버리면 판정을 미루는 동안 회전된 계보를 잃는다(리뷰 P2-3). **어느 프로필에 붙일지는
    /// 호출자(Switcher)가 정한다** — 이 함수는 종류가 맞는지만 본다. `stored` 자체가 섞여 있으면 nil.
    public func liveSecret(_ live: Data, reattributedTo stored: Data) -> Data? {
        let decoder = JSONDecoder()
        guard let liveSnap = try? decoder.decode(CredentialsSnapshot.self, from: live),
              let storedSnap = try? decoder.decode(CredentialsSnapshot.self, from: stored),
              Self.liveSnapshotVerdict(liveSnap) == .organizationMismatch,
              Self.liveSnapshotVerdict(storedSnap) == .storable,
              let tokenSeat = CredentialBlob.isSeatSubscription(from: liveSnap.keychainBlob),
              let json = storedSnap.oauthAccountJSON,
              let block = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              Self.isSeatOrganization(oauthBlock: block) == tokenSeat
        else { return nil }
        return try? JSONEncoder().encode(CredentialsSnapshot(keychainBlob: liveSnap.keychainBlob,
                                                             credentialsFileData: liveSnap.credentialsFileData,
                                                             oauthAccountJSON: storedSnap.oauthAccountJSON))
    }

    /// 저장본의 oauthAccount가 가리키는 조직 종류가 라이브 토큰 종류와 같거나 **모르면** true.
    /// 저장본의 토큰 상태(빈 토큰, 섞임)는 보지 않는다 — 신원은 그 프로필이 어느 조직인지를 말할 뿐이다.
    public func liveToken(_ live: Data, couldBelongTo stored: Data?) -> Bool {
        let decoder = JSONDecoder()
        guard let liveSnap = try? decoder.decode(CredentialsSnapshot.self, from: live),
              let tokenSeat = CredentialBlob.isSeatSubscription(from: liveSnap.keychainBlob),
              let stored,
              let storedSnap = try? decoder.decode(CredentialsSnapshot.self, from: stored),
              let json = storedSnap.oauthAccountJSON,
              let block = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let accountSeat = Self.isSeatOrganization(oauthBlock: block)
        else { return true }
        return accountSeat == tokenSeat
    }

    public func secretIsMixed(_ data: Data) -> Bool {
        guard let snap = try? JSONDecoder().decode(CredentialsSnapshot.self, from: data) else { return false }
        return Self.liveSnapshotVerdict(snap) == .organizationMismatch
    }

    /// Claude secret은 CredentialsSnapshot JSON이다 — 디코드되면 Claude 형태.
    /// Codex auth.json(keychainBlob/credentialsFileData 키 없음)은 여기서 디코드 실패한다.
    public func recognizesSecret(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(CredentialsSnapshot.self, from: data)) != nil
    }
}
