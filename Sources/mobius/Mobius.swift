import ArgumentParser
import Foundation
import MobiusCore

@main
struct MobiusCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mobius",
        abstract: "Claude·Codex CLI 계정 매니저 (뫼비우스)",
        subcommands: [List.self, Switch.self, Status.self, Capture.self, Auto.self])
}

/// - Parameter healProviders: 구버전 바이너리가 저장하며 소실시킨 per-account provider를
///   secret 형태로 복구할지(앱 AppState.init과 동일 경로). **변경 명령(switch/capture/auto)
///   에서만 켠다** — heal은 계정당 secret 파일을 읽고(레거시 계정은 Keychain 폴백까지),
///   교정 시 accounts.json을 저장하므로 읽기 전용 명령(list/status)에는 과하다(리뷰 반영).
///   미복구 상태의 표시 오류는 앱 실행 시 또는 전환 시점 heal이 잡는다.
///   ★ `backfillOrganizationUUIDs`도 같은 게이트를 쓴다 — 그래서 업그레이드 후 앱을 아직 안 켠
///   사용자에게는 `list`/`status`에 조직 이름이 안 뜬다. 의도한 동작이다: 읽기 전용 명령은
///   accounts.json을 고치지 않는다는 기존 정책이 우선이고, 다음 변경 명령이나 앱 실행이 채운다.
func makeContext(healProviders: Bool = false) throws -> (
    env: MobiusEnvironment, store: AccountStore,
    io: ClaudeConfigIO, codexIO: CodexConfigIO, switcher: Switcher) {
    let env = MobiusEnvironment.live()
    let kc = SystemKeychain()
    let store = try AccountStore(env: env, keychain: kc)
    let io = ClaudeConfigIO(env: env, keychain: kc)
    let codexIO = CodexConfigIO(env: env)
    let switcher = Switcher(env: env, keychain: kc, store: store, io: io, extraIOs: [codexIO])
    if healProviders {
        if let reassigned = try? switcher.healMisassignedProviders(), !reassigned.isEmpty {
            for r in reassigned {
                FileHandle.standardError.write(Data(
                    "⚠️ 프로바이더 정보 소실을 복구했습니다: \(r.nickname) (\(r.from.rawValue) → \(r.to.rawValue))\n".utf8))
            }
        }
        // 구버전 프로필(조직 미상)에 저장 스냅샷의 organizationUuid를 채운다 — 같은 이메일의 다른
        // 조직 로그인이 이 프로필을 덮어쓰지 않게(실패 기록 23). 비밀 파일이 있는 계정만 읽으므로
        // 승인창은 뜨지 않는다.
        _ = try? switcher.backfillOrganizationUUIDs()
        _ = try? switcher.refreshTierLabels()
    }
    return (env, store, io, codexIO, switcher)
}

func parseProvider(_ raw: String) throws -> Provider {
    guard let provider = Provider(rawValue: raw) else {
        let names = Provider.allCases.map(\.rawValue).joined(separator: ", ")
        throw ValidationError("프로바이더는 \(names) 중 하나입니다.")
    }
    return provider
}

func fmtReset(_ p: AccountProfile) -> String {
    guard let rl = p.rateLimit, rl.resetsAt > Date() else { return "" }
    let mins = Int(rl.resetsAt.timeIntervalSinceNow / 60)
    // ★ 모델 전용 한도(Fable 등)를 "한도 소진"으로 적으면 거짓말이다 — 그 계정은 다른
    //   모델로 멀쩡히 쓸 수 있다(AccountProfile.isLimited가 둘을 구분한다).
    let label = rl.modelScoped ? "모델 한도" : "한도 소진"
    return "  [\(label) — \(mins / 60)시간 \(mins % 60)분 후 리셋]"
}

/// `list --usage`가 usage 조회에 쓸 자격증명 blob. **활성 계정은 라이브 토큰**을 쓴다 — 저장 스냅샷은
/// claude가 라이브를 갱신하는 동안 만료돼 있을 수 있다. 라이브 열쇠(이메일+조직)가 이 프로필과 일치할
/// 때만 쓴다(AppState.usageQueryBlob과 같은 규칙 — 어긋난 라이브 토큰으로 조회해 다른 계정의 값을
/// 보여주지 않는다). 아니면 저장 스냅샷으로 내려온다.
func usageBlob(for p: AccountProfile, store: AccountStore, io: ClaudeConfigIO) -> Data? {
    if store.file.activeByProvider[.claude] == p.id,
       let idx = store.file.accounts.firstIndex(where: { $0.id == p.id }),
       let liveKey = try? io.liveAccountKey(),
       store.file.firstIndex(provider: io.provider, matching: liveKey) == idx,
       let live = try? io.readLiveSnapshot() {
        return live.keychainBlob
    }
    return (try? store.secret(for: p.id))?.keychainBlob
}

/// 계정 한 줄 아래에 붙일 사용량 행. 429면 서버가 준 대기 시간을 그대로 밝힌다(재시도하지 않는다).
func usageLines(for p: AccountProfile, store: AccountStore, io: ClaudeConfigIO) async -> [String] {
    guard let blob = usageBlob(for: p, store: store, io: io) else { return ["사용량: 저장된 자격증명 없음"] }
    switch await UsageFetcher.fetchOutcome(keychainBlob: blob) {
    case .ok(let snap):
        return snap.summaryLines(now: Date())
    case .rateLimited(let retryAfter):
        let wait = retryAfter.map { " — \(UsageRateLimitBackoff.minutesUntilRetry(Date().addingTimeInterval($0), now: Date()))분 후 다시 시도" } ?? ""
        return ["사용량: 조회 제한 중\(wait)"]
    case .unauthorized:
        return ["사용량: 토큰 거부됨 (만료됐을 수 있음 — claude를 한 번 실행해 보세요)"]
    case .failed:
        return ["사용량: 조회 실패"]
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "계정 목록")

    // 기본은 네트워크 0 — usage 엔드포인트는 429를 주고 같은 계정을 부르는 모든 클라이언트가 제한을
    // 나눠 쓰므로(CLAUDE.md '사용량 엔드포인트'), 요청이 나가는 것은 사용자가 명시했을 때만이다.
    @Flag(help: "Claude 계정별 5시간·7일 사용률과 리셋 시각도 표시 (usage API를 호출한다)")
    var usage = false

    func run() async throws {
        let ctx = try makeContext()
        try await ctx.switcher.reconcile()
        if ctx.store.file.accounts.isEmpty {
            print("등록된 계정이 없습니다. 앱에서 '계정 추가' 또는 `mobius capture <이름>`으로 등록하세요.")
            return
        }
        for provider in Provider.allCases {
            let accounts = ctx.store.file.accounts(of: provider)
            guard !accounts.isEmpty else { continue }
            print("\(provider.displayName):")
            for (i, p) in accounts.enumerated() {
                let active = p.id == ctx.store.file.activeByProvider[provider] ? "●" : "○"
                let role = i == 0 ? "primary " : "fallback\(i)"
                let reauth = p.needsReauth ? "  [재로그인 필요]" : ""
                // 회사 조직(Team/Enterprise) 이름을 함께 적는다 — 같은 이메일의 계정이 여럿일 때 구분 근거.
                print("  \(active) \(role)  \(p.nickname)  <\(p.emailAddress)>  \(p.subtitle)\(fmtReset(p))\(reauth)")
                // needsReauth 계정은 건너뛴다 — 토큰이 죽었다고 이미 표시했고, 죽은 토큰으로 부를 이유가 없다.
                if usage, provider == .claude, !p.needsReauth {
                    for line in await usageLines(for: p, store: ctx.store, io: ctx.io) {
                        print("        \(line)")
                    }
                }
            }
        }
    }
}

struct Switch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "계정 전환")
    @Argument(help: "전환할 계정 닉네임") var name: String
    @Option(help: "claude 또는 codex — 두 프로바이더에 같은 닉네임이 있을 때 지정")
    var provider: String?

    func run() throws {
        let ctx = try makeContext(healProviders: true)
        let wanted = try provider.map(parseProvider)
        let matches = ctx.store.file.accounts.filter {
            $0.nickname == name && (wanted == nil || $0.provider == wanted)
        }
        guard let target = matches.first else {
            let names = ctx.store.file.accounts
                .map { "\($0.nickname)(\($0.provider.rawValue))" }.joined(separator: ", ")
            throw ValidationError("'\(name)' 계정 없음. 등록된 계정: \(names)")
        }
        guard matches.count == 1 else {
            if Set(matches.map(\.provider)).count > 1 {
                throw ValidationError(
                    "'\(name)' 닉네임이 여러 프로바이더에 있습니다. --provider claude|codex 로 지정하세요.")
            }
            // 같은 풀 안의 중복 — 같은 이메일의 다른 조직을 같은 이름으로 capture한 경우.
            let orgs = matches.map { $0.organizationLabel.isEmpty ? $0.tierDescription : $0.organizationLabel }
                .joined(separator: ", ")
            // ★ 안내가 회복 경로까지 말해야 한다(리뷰 지적) — 중복 닉네임은 `switch`로 고를 수
            //   없으므로 "그 계정으로 로그인"을 `mobius switch`로는 할 수 없다. 그래서 claude에서
            //   직접 로그인하는 경로를 명시한다. (구버전에서 이메일 앞부분만으로 adopt된
            //   `leo@a.com`·`leo@b.com`이 둘 다 `leo`가 된 사용자가 실제로 이 상태다.)
            throw ValidationError(
                "'\(name)' 닉네임의 계정이 같은 프로바이더에 여러 개입니다 (\(orgs)). "
                + "`claude`에서 그 계정으로 직접 로그인한 뒤 "
                + "`mobius capture <다른 닉네임>`으로 이름을 바꾸세요.")
        }
        do {
            try ctx.switcher.switchTo(target.id)
        } catch SwitcherError.mixedSnapshot {
            // 실패 기록 24 — 설치하면 이 카드와 다른 조직으로 로그인된다
            throw ValidationError("'\(target.nickname)'에 다른 조직의 로그인이 저장돼 있어 전환하지 않았습니다. "
                + "`claude`에서 /login 으로 이 조직에 로그인한 뒤 `mobius capture \(target.nickname)` 하세요.")
        }
        // 사용자의 의지로 전환 — 앱 onTick의 primary 자동 복귀 대상이 아니다
        try ctx.store.setAutoSwitchedFromPrimary(false, provider: target.provider)
        MobiusNotification.postAccountsChanged()
        print("전환 완료 → [\(target.provider.displayName)] \(target.nickname) <\(target.emailAddress)>")
        // ★ [정정 2026-08-15] 프로바이더마다 전제가 다르다 — claude 세션은 턴마다 자격증명을
        //   다시 읽어 다음 입력부터 이어지고(재시작 불필요, claude 2.1.232/2.1.233 기준),
        //   codex 세션은 시작 시점 토큰을 계속 쓰며 토큰 갱신으로 로그인을 되돌리기까지
        //   한다(클로버). 한 문장으로 합치지 말 것.
        //   ★ if/else가 아니라 switch인 이유(셀프리뷰 반영): 프로바이더가 늘면 "claude가
        //   아니면 codex"가 조용히 틀린 안내를 한다 — 컴파일 에러로 드러나야 한다.
        switch target.provider {
        case .claude:
            print("실행 중인 세션도 다음 입력부터 새 계정으로 이어집니다 (진행 중이던 응답만 이전 계정).")
            print("Desktop 동시 전환은 앱에서 전환할 때만 적용됩니다.")
        case .codex:
            print("실행 중인 codex 세션은 종료해야 새 계정이 적용됩니다 (구 세션이 로그인을 되돌릴 수 있음).")
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "현재 상태")
    func run() async throws {
        let ctx = try makeContext()
        try await ctx.switcher.reconcile()
        var printedAny = false
        for provider in Provider.allCases {
            guard let active = ctx.store.file.active(of: provider) else { continue }
            let role = active.id == ctx.store.file.primary(of: provider)?.id
                ? "primary" : "fallback"
            let org = active.organizationLabel.isEmpty ? "" : " \(active.organizationLabel)"
            print("[\(provider.displayName)] 활성: \(active.nickname) <\(active.emailAddress)>\(org) (\(role))\(fmtReset(active))")
            printedAny = true
        }
        if !printedAny {
            print("활성 계정 없음 (로그아웃 상태이거나 미등록 계정)")
            return
        }
        let states = Provider.allCases.map {
            "\($0.displayName) \(ctx.store.file.isAutoSwitchEnabled($0) ? "켜짐" : "꺼짐")"
        }
        print("자동 전환: \(states.joined(separator: " · "))")
    }
}

struct Capture: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "현재 로그인 계정을 프로필로 캡처")
    @Argument(help: "저장할 닉네임") var name: String
    @Option(help: "claude(기본) 또는 codex") var provider: String = "claude"

    func run() throws {
        let ctx = try makeContext(healProviders: true)
        let provider = try parseProvider(self.provider)
        let p: AccountProfile
        switch provider {
        case .claude:
            guard let snap = try ctx.io.readLiveSnapshot() else {
                throw ValidationError("claude 로그인 상태가 아닙니다. 먼저 `claude`에서 /login 하세요.")
            }
            guard let identity = ClaudeConfigIO.identity(fromSnapshot: snap) else {
                throw ValidationError("~/.claude.json 에 계정 정보(oauthAccount)가 없습니다. `claude`에서 다시 로그인하세요.")
            }
            // 토큰과 계정 정보가 같은 로그인의 것일 때만 등록한다(실패 기록 24).
            switch ClaudeConfigIO.liveSnapshotVerdict(snap) {
            case .storable: break
            case .loggedOut:
                throw ValidationError("로그인이 진행 중이거나 로그아웃된 상태입니다. 로그인이 끝난 뒤 다시 실행하세요.")
            case .organizationMismatch:
                throw ValidationError("Keychain의 토큰과 ~/.claude.json 의 계정 정보가 서로 다른 조직(회사/개인)을 가리킵니다. `claude`에서 /login 으로 캡처할 조직에 다시 로그인한 뒤 실행하세요.")
            }
            try Self.rejectNicknameTakenByAnotherAccount(name, provider: .claude,
                                                        identity: identity, store: ctx.store)
            p = try ctx.store.upsertProfile(nickname: name, snapshot: snap)
        case .codex:
            guard let data = try ctx.codexIO.readLiveSecretData(),
                  let identity = try ctx.codexIO.liveIdentity() else {
                throw ValidationError("codex 로그인 상태가 아닙니다. 먼저 `codex login` 하세요.")
            }
            try Self.rejectNicknameTakenByAnotherAccount(name, provider: .codex,
                                                        identity: identity, store: ctx.store)
            p = try ctx.store.upsertProfile(nickname: name, provider: .codex,
                                            identity: identity, secretData: data)
        }
        try ctx.store.setActive(p.id)
        MobiusNotification.postAccountsChanged()
        print("캡처 완료: [\(p.provider.displayName)] \(p.nickname) <\(p.emailAddress)> \(p.subtitle)")
    }

    /// 같은 풀의 **다른** 계정이 이미 쓰는 닉네임이면 거부한다 — 같은 이름이 둘이면 `switch`가 고를
    /// 수 없다. 같은 계정(열쇠 일치)의 재캡처(토큰 갱신·이름 변경)는 통과한다.
    static func rejectNicknameTakenByAnotherAccount(_ name: String, provider: Provider,
                                                    identity: ProviderIdentity,
                                                    store: AccountStore) throws {
        let sameAccount = store.file.firstAccount(provider: provider, matching: identity.key)?.id
        guard let other = store.file.accounts(of: provider)
            .first(where: { $0.nickname == name && $0.id != sameAccount }) else { return }
        let what = other.organizationLabel.isEmpty ? other.tierDescription : other.organizationLabel
        throw ValidationError(
            "'\(name)' 닉네임은 이미 다른 계정(<\(other.emailAddress)> \(what))이 쓰고 있습니다. 다른 닉네임을 지정하세요.")
    }
}

struct Auto: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "자동 전환 켜기/끄기")
    @Argument(help: "on 또는 off") var mode: String
    @Option(help: "claude 또는 codex — 미지정 시 Claude(기존 동작 보존)") var provider: String?

    func run() throws {
        let ctx = try makeContext(healProviders: true)
        let enabled: Bool
        switch mode {
        case "on": enabled = true
        case "off": enabled = false
        default: throw ValidationError("on 또는 off만 가능합니다.")
        }
        // 미지정 시 Claude만 — Codex 도입 이전 동작을 보존한다(기존 스크립트가 --provider 없이
        // `mobius auto on`을 쓰면 예전처럼 Claude에만 적용). Codex는 --provider codex로 명시.
        let targets = try provider.map { [try parseProvider($0)] } ?? [.claude]
        for target in targets {
            try ctx.store.setAutoSwitch(enabled, provider: target)
        }
        MobiusNotification.postAccountsChanged()
        let names = targets.map(\.displayName).joined(separator: "·")
        print("\(names) 자동 전환: \(enabled ? "켜짐" : "꺼짐")")
        // 미지정인데 Codex 계정이 있으면 Codex는 안 바뀐다는 걸 알려 발견성을 높인다.
        if provider == nil, !ctx.store.file.accounts(of: .codex).isEmpty {
            print("(Codex는 바뀌지 않았습니다 — `mobius auto \(mode) --provider codex`로 지정)")
        }
    }
}
