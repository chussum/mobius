import ArgumentParser
import Foundation
import MobiusCore

@main
struct MobiusCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mobius",
        abstract: "Claude CLI 계정 매니저 (뫼비우스)",
        subcommands: [List.self, Switch.self, Status.self, Capture.self, Auto.self])
}

func makeContext() throws -> (env: MobiusEnvironment, store: AccountStore,
                              io: ClaudeConfigIO, switcher: Switcher) {
    let env = MobiusEnvironment.live()
    let kc = SystemKeychain()
    let store = try AccountStore(env: env, keychain: kc)
    let io = ClaudeConfigIO(env: env, keychain: kc)
    let switcher = Switcher(env: env, keychain: kc, store: store, io: io)
    return (env, store, io, switcher)
}

func fmtReset(_ p: AccountProfile) -> String {
    guard let rl = p.rateLimit, rl.resetsAt > Date() else { return "" }
    let mins = Int(rl.resetsAt.timeIntervalSinceNow / 60)
    return "  [한도 소진 — \(mins / 60)시간 \(mins % 60)분 후 리셋]"
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "계정 목록")
    func run() throws {
        let ctx = try makeContext()
        try ctx.switcher.reconcile()
        if ctx.store.file.accounts.isEmpty {
            print("등록된 계정이 없습니다. 앱에서 '계정 추가' 또는 `mobius capture <이름>`으로 등록하세요.")
            return
        }
        for (i, p) in ctx.store.file.accounts.enumerated() {
            let active = p.id == ctx.store.file.activeAccountID ? "●" : "○"
            let role = i == 0 ? "primary " : "fallback\(i)"
            let reauth = p.needsReauth ? "  [재로그인 필요]" : ""
            print("\(active) \(role)  \(p.nickname)  <\(p.emailAddress)>  \(p.tierDescription)\(fmtReset(p))\(reauth)")
        }
    }
}

struct Switch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "계정 전환")
    @Argument(help: "전환할 계정 닉네임") var name: String
    func run() throws {
        let ctx = try makeContext()
        guard let target = ctx.store.file.accounts.first(where: { $0.nickname == name }) else {
            let names = ctx.store.file.accounts.map(\.nickname).joined(separator: ", ")
            throw ValidationError("'\(name)' 계정 없음. 등록된 계정: \(names)")
        }
        try ctx.switcher.switchTo(target.id)
        MobiusNotification.postAccountsChanged()
        print("전환 완료 → \(target.nickname) <\(target.emailAddress)>")
        print("실행 중인 claude 세션은 다음 요청부터 새 계정이 적용되지 않을 수 있습니다 — 그 경우 세션을 새로 시작하세요.")
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "현재 상태")
    func run() throws {
        let ctx = try makeContext()
        try ctx.switcher.reconcile()
        guard let active = ctx.store.file.active else {
            print("활성 계정 없음 (claude 로그아웃 상태이거나 미등록 계정)")
            return
        }
        let role = active.id == ctx.store.file.primary?.id ? "primary" : "fallback"
        print("활성: \(active.nickname) <\(active.emailAddress)> (\(role))\(fmtReset(active))")
        print("자동 전환: \(ctx.store.file.autoSwitchEnabled ? "켜짐" : "꺼짐")")
    }
}

struct Capture: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "현재 claude 로그인 계정을 프로필로 캡처")
    @Argument(help: "저장할 닉네임") var name: String
    func run() throws {
        let ctx = try makeContext()
        guard let snap = try ctx.io.readLiveSnapshot() else {
            throw ValidationError("claude 로그인 상태가 아닙니다. 먼저 `claude`에서 /login 하세요.")
        }
        let p = try ctx.store.upsertProfile(nickname: name, snapshot: snap)
        try ctx.store.setActive(p.id)
        MobiusNotification.postAccountsChanged()
        print("캡처 완료: \(p.nickname) <\(p.emailAddress)> \(p.tierDescription)")
    }
}

struct Auto: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "자동 fallback 켜기/끄기")
    @Argument(help: "on 또는 off") var mode: String
    func run() throws {
        let ctx = try makeContext()
        switch mode {
        case "on": try ctx.store.setAutoSwitch(true)
        case "off": try ctx.store.setAutoSwitch(false)
        default: throw ValidationError("on 또는 off만 가능합니다.")
        }
        MobiusNotification.postAccountsChanged()
        print("자동 전환: \(mode)")
    }
}
