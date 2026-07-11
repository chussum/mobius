import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var cliMessage = ""
    @AppStorage("showUsageGauges") private var showUsageGauges = true
    @State private var claudeInfo: ClaudeCLI.Info?
    @State private var claudeChecked = false
    @State private var installingClaude = false
    @State private var claudeInstallMessage = ""

    var body: some View {
        settingsForm
            // 설정창이 떠 있는 동안만 Dock에 아이콘 표시, 닫으면 메뉴바 전용으로 복귀
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                checkClaude()
            }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    @ViewBuilder private var claudeCLIRow: some View {
        if let info = claudeInfo {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("설치됨\(info.version.isEmpty ? "" : " · \(info.version)")")
                        .font(.system(size: 12))
                    Text(info.path).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
            }
        } else if !claudeChecked {
            HStack { ProgressView().controlSize(.small); Text("확인 중…").font(.caption).foregroundStyle(.secondary) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Claude Code CLI가 설치되어 있지 않아요", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                Text("Mobius는 Claude Code CLI로 계정을 로그인·전환합니다. 아래 버튼으로 공식 설치 스크립트를 실행하세요 (관리자 권한 불필요).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        installClaude()
                    } label: {
                        if installingClaude {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("설치 중…") }
                        } else { Text("Claude Code 설치") }
                    }
                    .disabled(installingClaude)
                    Spacer()
                }
                if !claudeInstallMessage.isEmpty {
                    Text(claudeInstallMessage).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func checkClaude() {
        Task {
            let info = await Task.detached { ClaudeCLI.locate() }.value
            await MainActor.run { claudeInfo = info; claudeChecked = true }
        }
    }

    private func installClaude() {
        installingClaude = true
        claudeInstallMessage = "설치 스크립트를 내려받아 실행 중입니다… (최대 1~2분)"
        Task {
            let err = await ClaudeCLI.install()
            let info = ClaudeCLI.locate()
            await MainActor.run {
                installingClaude = false
                claudeInfo = info
                claudeInstallMessage = err ?? "설치 완료! 이제 계정을 추가할 수 있어요."
            }
        }
    }

    private var settingsForm: some View {
        Form {
            if state.file.accounts.count <= 1 {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(state.file.accounts.isEmpty
                              ? "아직 등록된 계정이 없어요"
                              : "Fallback 계정을 추가해 보세요",
                              systemImage: "infinity")
                            .font(.system(size: 13, weight: .semibold))
                        Text(state.file.accounts.isEmpty
                             ? "메뉴바의 ∞ 아이콘을 클릭하고 **계정 추가**를 눌러 Claude 계정을 등록하세요. 개인·회사 계정을 함께 등록해 두면, 한 계정의 사용량이 차는 순간 다음 계정으로 알아서 전환됩니다."
                             : "지금은 계정이 하나뿐이라 사용량이 차면 기다리는 수밖에 없어요. 메뉴바의 ∞ 아이콘 → **계정 추가**로 계정을 하나 더 등록하면, 한도가 차는 순간 자동으로 이어서 쓸 수 있습니다.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("Claude Code CLI") {
                claudeCLIRow
            }
            Section("일반") {
                Toggle("로그인 시 자동 시작", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { cliMessage = "실패: \(error.localizedDescription)" }
                    }
                Toggle("Claude Code CLI 자동 Fallback", isOn: Binding(
                    get: { state.file.autoSwitchEnabled },
                    set: { state.setAutoSwitch($0) }))
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("사용량 게이지 표시", isOn: $showUsageGauges)
                    Text("계정 카드에 5시간·주간 사용량과 초기화 남은 시간을 표시합니다")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Claude Desktop 자동 Fallback", isOn: Binding(
                        get: { state.file.desktopAutoSwitchEnabled },
                        set: { state.setDesktopAutoSwitch($0) }))
                    Text("자동 전환 시 Claude Desktop이 종료 후 재실행됩니다")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("계정 전환 시 Claude Desktop도 전환 (experimental)", isOn: Binding(
                    get: { state.file.desktopSyncEnabled },
                    set: { state.setDesktopSync($0) }))
            }
            Section("mobius CLI") {
                HStack {
                    Text("`mobius` 명령어 설치")
                    Spacer()
                    Button("설치") { installCLI() }
                }
                if !cliMessage.isEmpty {
                    Text(cliMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Claude Desktop 키체인 창") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude Desktop을 켤 때마다 뜨는 ‘Claude Code-credentials’ 키체인 창을 없애려면, 그 항목을 ‘모든 앱 허용’으로 한 번만 바꾸면 됩니다. (Desktop 자체 동작이라 Mobius가 대신 못 바꿉니다.)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("① 아래 버튼으로 Keychain Access 열기\n② 로그인 키체인에서 ‘Claude Code-credentials’ 더블클릭\n③ ‘접근 제어’ 탭 → ‘모든 응용 프로그램이 접근하도록 허용’\n④ 변경 사항 저장 (로그인 암호 1회)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Keychain Access 열기") { openKeychainAccess() }
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: state.file.accounts.count <= 1 ? 680 : 590)
    }

    private func openKeychainAccess() {
        // 번들 ID로 여는 게 macOS 버전별 경로 차이(Utilities vs CoreServices)에 견고하다.
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.keychainaccess") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath:
                "/System/Library/CoreServices/Applications/Keychain Access.app"))
        }
    }

    private func installCLI() {
        // 번들 내 mobius 바이너리 → /usr/local/bin 심볼릭 링크 (osascript로 관리자 권한)
        guard let src = Bundle.main.url(forAuxiliaryExecutable: "mobius")?.path else {
            cliMessage = "번들에서 mobius 바이너리를 찾을 수 없습니다 (개발 빌드에서는 Scripts/install-cli.sh 사용)"
            return
        }
        let command = "mkdir -p /usr/local/bin && ln -sf \(shellQuoted(src)) /usr/local/bin/mobius"
        let script = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let reason = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            cliMessage = "설치 실패: \(reason)"
        } else {
            cliMessage = "설치 완료: /usr/local/bin/mobius"
        }
    }

    /// POSIX shell 단일 인용 — `'` → `'\''` 로 어떤 경로도 안전하게.
    private func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 문자열 리터럴 — `\`와 `"` 이스케이프.
    private func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
