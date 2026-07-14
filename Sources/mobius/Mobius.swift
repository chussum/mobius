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

func makeContext() throws -> (env: MobiusEnvironment, store: AccountStore,
                              io: ClaudeConfigIO, codexIO: CodexConfigIO, switcher: Switcher) {
    let env = MobiusEnvironment.live()
    let kc = SystemKeychain()
    let store = try AccountStore(env: env, keychain: kc)
    let io = ClaudeConfigIO(env: env, keychain: kc)
    let codexIO = CodexConfigIO(env: env)
    let switcher = Switcher(env: env, keychain: kc, store: store, io: io, extraIOs: [codexIO])
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
    return "  [한도 소진 — \(mins / 60)시간 \(mins % 60)분 후 리셋]"
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "계정 목록")
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
                print("  \(active) \(role)  \(p.nickname)  <\(p.emailAddress)>  \(p.tierDescription)\(fmtReset(p))\(reauth)")
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
        let ctx = try makeContext()
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
            throw ValidationError(
                "'\(name)' 닉네임이 여러 프로바이더에 있습니다. --provider claude|codex 로 지정하세요.")
        }
        try ctx.switcher.switchTo(target.id)
        // 사용자의 의지로 전환 — 앱 onTick의 primary 자동 복귀 대상이 아니다
        try ctx.store.setAutoSwitchedFromPrimary(false, provider: target.provider)
        MobiusNotification.postAccountsChanged()
        print("전환 완료 → [\(target.provider.displayName)] \(target.nickname) <\(target.emailAddress)>")
        print("실행 중인 세션에는 새 계정이 즉시 적용되지 않을 수 있습니다 — 그 경우 세션을 새로 시작하세요.")
        if target.provider == .claude {
            print("Desktop 동시 전환은 앱에서 전환할 때만 적용됩니다.")
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
            print("[\(provider.displayName)] 활성: \(active.nickname) <\(active.emailAddress)> (\(role))\(fmtReset(active))")
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
        let ctx = try makeContext()
        let provider = try parseProvider(self.provider)
        let p: AccountProfile
        switch provider {
        case .claude:
            guard let snap = try ctx.io.readLiveSnapshot() else {
                throw ValidationError("claude 로그인 상태가 아닙니다. 먼저 `claude`에서 /login 하세요.")
            }
            p = try ctx.store.upsertProfile(nickname: name, snapshot: snap)
        case .codex:
            guard let data = try ctx.codexIO.readLiveSecretData(),
                  let identity = try ctx.codexIO.liveIdentity() else {
                throw ValidationError("codex 로그인 상태가 아닙니다. 먼저 `codex login` 하세요.")
            }
            p = try ctx.store.upsertProfile(nickname: name, provider: .codex,
                                            identity: identity, secretData: data)
        }
        try ctx.store.setActive(p.id)
        MobiusNotification.postAccountsChanged()
        print("캡처 완료: [\(p.provider.displayName)] \(p.nickname) <\(p.emailAddress)> \(p.tierDescription)")
    }
}

struct Auto: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "자동 전환 켜기/끄기")
    @Argument(help: "on 또는 off") var mode: String
    @Option(help: "claude 또는 codex — 미지정 시 Claude(기존 동작 보존)") var provider: String?

    func run() throws {
        let ctx = try makeContext()
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
