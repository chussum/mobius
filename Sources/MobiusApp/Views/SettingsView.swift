import SwiftUI
import ServiceManagement
import MobiusCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var cliMessage = ""
    @AppStorage("showUsageGauges") private var showUsageGauges = true
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
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
                    Text(loc("설치됨") + (info.version.isEmpty ? "" : " · \(info.version)"))
                        .font(.system(size: 12))
                    Text(info.path).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
            }
        } else if !claudeChecked {
            HStack { ProgressView().controlSize(.small); Text(loc("확인 중…")).font(.caption).foregroundStyle(.secondary) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label(loc("Claude Code CLI가 설치되어 있지 않아요"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                Text(loc("Mobius는 Claude Code CLI로 계정을 로그인·전환합니다. 아래 버튼으로 공식 설치 스크립트를 실행하세요 (관리자 권한 불필요)."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        installClaude()
                    } label: {
                        if installingClaude {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(loc("설치 중…")) }
                        } else { Text(loc("Claude Code 설치")) }
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
        claudeInstallMessage = loc("설치 스크립트를 내려받아 실행 중입니다… (최대 1~2분)")
        Task {
            let err = await ClaudeCLI.install()
            let info = ClaudeCLI.locate()
            await MainActor.run {
                installingClaude = false
                claudeInfo = info
                claudeInstallMessage = err ?? loc("설치 완료! 이제 계정을 추가할 수 있어요.")
            }
        }
    }

    private var settingsForm: some View {
        Form {
            if state.file.accounts.count <= 1 {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(state.file.accounts.isEmpty
                              ? loc("아직 등록된 계정이 없어요")
                              : loc("Fallback 계정을 추가해 보세요"),
                              systemImage: "infinity")
                            .font(.system(size: 13, weight: .semibold))
                        Text(.init(state.file.accounts.isEmpty
                             ? loc("메뉴바의 ∞ 아이콘을 클릭하고 **계정 추가**를 눌러 Claude 계정을 등록하세요. 개인·회사 계정을 함께 등록해 두면, 한 계정의 사용량이 차는 순간 다음 계정으로 알아서 전환됩니다.")
                             : loc("지금은 계정이 하나뿐이라 사용량이 차면 기다리는 수밖에 없어요. 메뉴바의 ∞ 아이콘 → **계정 추가**로 계정을 하나 더 등록하면, 한도가 차는 순간 자동으로 이어서 쓸 수 있습니다.")))
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
            Section(loc("일반")) {
                Picker(loc("언어"), selection: Binding(
                    get: { L10n.current },
                    set: { L10n.setLanguage($0); state.objectWillChange.send() })) {
                    Text(loc("시스템 기본")).tag("system")
                    Text("한국어").tag("ko")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                }
                Toggle(loc("로그인 시 자동 시작"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { cliMessage = loc("실패: %@", error.localizedDescription) }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(loc("사용량 게이지 표시"), isOn: $showUsageGauges)
                    Text(loc("계정 카드에 5시간·주간 사용량과 초기화 남은 시간을 표시합니다"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(loc("Claude Code CLI 자동 Fallback"), isOn: Binding(
                    get: { state.file.autoSwitchEnabled },
                    set: { state.setAutoSwitch($0) }))
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(loc("Claude Desktop 자동 Fallback"), isOn: Binding(
                        get: { state.file.desktopAutoSwitchEnabled },
                        set: { state.setDesktopAutoSwitch($0) }))
                    Text(loc("자동 전환 시 Claude Desktop이 종료 후 재실행됩니다"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(loc("계정 전환 시 Claude Desktop도 전환"), isOn: Binding(
                    get: { state.file.desktopSyncEnabled },
                    set: { state.setDesktopSync($0) }))
            }
            labsSection
            Section(loc("업데이트")) {
                HStack {
                    Text(loc("현재 버전"))
                    Spacer()
                    Text("v" + state.currentVersion).foregroundStyle(.secondary)
                }
                Toggle(loc("하루 한 번 자동 확인"), isOn: $autoUpdateCheck)
                HStack {
                    Button(loc("지금 확인")) { state.checkForUpdates(manual: true) }
                        .disabled(state.updateStatus == .checking)
                    Spacer()
                    updateStatusRow
                }
            }
            Section("mobius CLI") {
                HStack {
                    Text(.init(loc("`mobius` 명령어 설치")))
                    Spacer()
                    Button(loc("설치")) { installCLI() }
                }
                if !cliMessage.isEmpty {
                    Text(cliMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: state.file.accounts.count <= 1 ? 700 : 560)
    }

    // MARK: 실험실 — 여러 Mac 동기화

    @AppStorage("syncEnabled") private var syncEnabled = false
    @AppStorage("syncProvider") private var syncProvider = "icloud"
    @AppStorage("syncCustomPath") private var syncCustomPath = ""
    @AppStorage("syncPropagateDeletes") private var syncPropagateDeletes = false
    @State private var syncCategories =
        Set(UserDefaults.standard.stringArray(forKey: "syncCategories") ?? [])
    @State private var sessionsSizeText = ""

    private func categoryBinding(_ raw: String) -> Binding<Bool> {
        Binding(
            get: { syncCategories.contains(raw) },
            set: { on in
                if on { syncCategories.insert(raw) } else { syncCategories.remove(raw) }
                UserDefaults.standard.set(Array(syncCategories), forKey: "syncCategories")
            })
    }

    private func categoryRow(_ raw: String, _ title: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: categoryBinding(raw))
            Text(desc).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var labsSection: some View {
        Section(loc("실험실")) {
            VStack(alignment: .leading, spacing: 3) {
                Toggle(loc("다른 Mac과 동기화"), isOn: $syncEnabled)
                Text(loc("이 Mac에서 켠 항목만 동기화에 참여해요. 끄면 이 Mac은 아무 영향도 받지 않아요."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if syncEnabled {
                Text(.init(loc("🔒 **로그인 정보는 옮기지 않아요** — 계정 자격증명, 계정 목록, 비밀 토큰은 어떤 경우에도 동기화되지 않습니다. 옮겨지는 건 대화 기록·플랜·스킬 같은 작업 데이터뿐이에요.")))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: 0.35, green: 0.65, blue: 1).opacity(0.10)))

                Picker(loc("보관 위치"), selection: $syncProvider) {
                    if SyncSupport.icloudRoot() != nil { Text("iCloud Drive").tag("icloud") }
                    if SyncSupport.gdriveRoot() != nil { Text("Google Drive").tag("gdrive") }
                    Text(loc("직접 선택한 폴더")).tag("custom")
                }
                if syncProvider == "custom" {
                    HStack {
                        Text(syncCustomPath.isEmpty ? loc("폴더가 선택되지 않았어요") : syncCustomPath)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(loc("다른 폴더 선택…")) { pickSyncFolder() }
                    }
                }

                categoryRow(SyncCategory.sessions.rawValue,
                            loc("대화 기록") + (sessionsSizeText.isEmpty ? "" : " · \(sessionsSizeText)"),
                            loc("다른 Mac에서 대화를 이어서 할 수 있어요 — 사용자명이 달라도 괜찮아요. 처음 한 번은 오래 걸려요."))
                    .onAppear {
                        guard sessionsSizeText.isEmpty else { return }
                        let dir = state.env.projectsDir
                        Task.detached(priority: .utility) {
                            let size = SyncSupport.formatSize(SyncSupport.directorySize(dir))
                            await MainActor.run { sessionsSizeText = size }
                        }
                    }
                categoryRow(SyncCategory.plans.rawValue, loc("플랜 문서"),
                            loc("작성해 둔 계획 파일을 함께 봐요."))
                categoryRow(SyncCategory.skills.rawValue, loc("스킬"),
                            loc("직접 만든 스킬을 모든 Mac에서 써요."))
                categoryRow(SyncCategory.globalMemory.rawValue, loc("글로벌 메모리 (CLAUDE.md)"),
                            loc("Claude가 배워 둔 내용을 함께 써서, 어느 Mac에서든 똑같이 똑똑해져요."))
                categoryRow(SyncCategory.pluginConfig.rawValue, loc("플러그인 목록"),
                            loc("어떤 플러그인을 쓰는지 목록만 맞춰요. 실제 파일은 각 Mac이 알아서 다시 내려받아요."))

                VStack(alignment: .leading, spacing: 3) {
                    Picker(loc("한쪽 Mac에서 지우면"), selection: $syncPropagateDeletes) {
                        Text(loc("다른 Mac에는 남겨두기")).tag(false)
                        Text(loc("다른 Mac에서도 지우기")).tag(true)
                    }
                    Text(syncPropagateDeletes
                         ? loc("다른 Mac에서는 바로 지워지지 않고 휴지통 폴더로 옮겨져 30일간 보관돼요.")
                         : loc("지운 파일이 다른 Mac에서는 그대로 유지돼요. 가장 안전한 선택이에요."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(loc("지금 동기화")) { state.syncNow(manual: true) }
                        .disabled(state.syncStatus == .running)
                    Spacer()
                    syncStatusRow
                }
                Text(loc("홈 폴더 안 프로젝트는 Mac마다 사용자명이 달라도 대화를 이어 쓸 수 있어요. 홈 밖 경로는 두 Mac의 경로가 같아야 해요."))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pickSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = loc("이 폴더 사용")
        if panel.runModal() == .OK, let url = panel.url {
            syncCustomPath = url.path
            syncProvider = "custom"
        }
    }

    @ViewBuilder private var syncStatusRow: some View {
        switch state.syncStatus {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(loc("동기화하는 중…")) }
                .font(.caption).foregroundStyle(.secondary)
        case .done(let report, let at):
            Text(loc("동기화됨 · 올림 %d · 받음 %d", report.uploaded, report.downloaded)
                 + " · " + relative(at))
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let reason, let at):
            Text(loc("동기화하지 못했어요 — %@", reason) + " · " + relative(at))
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder private var updateStatusRow: some View {
        switch state.updateStatus {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(loc("확인 중…")) }
                .font(.caption).foregroundStyle(.secondary)
        case .upToDate:
            Label(loc("최신 버전입니다"), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .available(let info):
            Button {
                if let url = URL(string: info.url) { NSWorkspace.shared.open(url) }
            } label: {
                Label(loc("새 버전 v%@ 받기", info.version), systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        case .failed:
            Text(loc("확인 실패 — 네트워크를 확인해주세요"))
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func installCLI() {
        // 번들 내 mobius 바이너리 → /usr/local/bin 심볼릭 링크 (osascript로 관리자 권한)
        guard let src = Bundle.main.url(forAuxiliaryExecutable: "mobius")?.path else {
            cliMessage = loc("번들에서 mobius 바이너리를 찾을 수 없습니다 (개발 빌드에서는 Scripts/install-cli.sh 사용)")
            return
        }
        let command = "mkdir -p /usr/local/bin && ln -sf \(shellQuoted(src)) /usr/local/bin/mobius"
        let script = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let reason = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            cliMessage = loc("설치 실패: %@", reason)
        } else {
            cliMessage = loc("설치 완료: /usr/local/bin/mobius")
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
