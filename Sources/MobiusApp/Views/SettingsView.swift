import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var cliMessage = ""
    @AppStorage("showUsageGauges") private var showUsageGauges = true

    var body: some View {
        settingsForm
            // 설정창이 떠 있는 동안만 Dock에 아이콘 표시, 닫으면 메뉴바 전용으로 복귀
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
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
        }
        .formStyle(.grouped)
        .frame(width: 400, height: state.file.accounts.count <= 1 ? 560 : 470)
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
