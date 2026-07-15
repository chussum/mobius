import SwiftUI
import ServiceManagement
import MobiusCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var cliMessage = ""
    @AppStorage("showUsageGauges") private var showUsageGauges = true
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @State private var showDesktopAutoInfo = false
    @State private var showDesktopSyncInfo = false
    @State private var claudeInfo: ClaudeCLI.Info?
    @State private var codexInfo: ToolInventory.CLIInfo?
    @State private var claudeDesktop: ToolInventory.AppInfo?
    @State private var chatGPTApp: ToolInventory.AppInfo?
    @State private var toolsChecked = false
    @State private var installingClaude = false
    @State private var claudeInstallMessage = ""
    @State private var mobiusPaths: [String] = []
    @State private var mobiusChecked = false
    /// 설치 현황의 프로바이더 탭 — 팝오버와 같은 필 탭, 마지막 선택 유지.
    @AppStorage("settingsProviderTab") private var settingsTabRaw = Provider.claude.rawValue

    private var settingsTab: Provider { Provider(rawValue: settingsTabRaw) ?? .claude }

    var body: some View {
        settingsForm
            // 설정창이 떠 있는 동안만 Dock에 아이콘 표시, 닫으면 메뉴바 전용으로 복귀
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                checkTools()
            }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: 설치 현황

    /// CLI 감지는 로그인 셸 호출이라 느리다(수백 ms) — 백그라운드에서 확인.
    /// 앱 번들 조회(LaunchServices)와 mobius 경로 확인은 빨라서 메인에서 바로.
    private func checkTools() {
        claudeDesktop = ToolInventory.appBundle(bundleID: "com.anthropic.claudefordesktop")
        chatGPTApp = ToolInventory.appBundle(bundleID: "com.openai.codex")
        refreshMobius()
        Task {
            let (claude, codex) = await Task.detached {
                (ClaudeCLI.locate(), ToolInventory.locateCodexCLI())
            }.value
            await MainActor.run {
                claudeInfo = claude
                codexInfo = codex
                toolsChecked = true
            }
        }
    }

    private func refreshMobius() {
        mobiusPaths = ToolInventory.mobiusInstallations()
        mobiusChecked = true
    }

    /// 공통 상태 행: [상태 아이콘] 이름 · 버전 / 경로
    @ViewBuilder private func toolRow(_ name: String, path: String?, version: String?) -> some View {
        HStack(spacing: 8) {
            if let path {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(name).font(.system(size: 12, weight: .medium))
                        Spacer()
                        if let version, !version.isEmpty {
                            Text(version).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text(path).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if !toolsChecked {
                ProgressView().controlSize(.small)
                Text(name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(loc("확인 중…")).font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(loc("설치 안 됨")).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    /// Claude Code CLI 행 — 미설치면 공식 스크립트 설치 버튼을 함께 노출
    /// (계정 추가가 이 CLI에 의존하므로 설치 수단은 유지한다).
    @ViewBuilder private var claudeCLIRow: some View {
        toolRow("Claude Code CLI", path: claudeInfo?.path, version: claudeInfo?.version)
        if toolsChecked, claudeInfo == nil {
            VStack(alignment: .leading, spacing: 6) {
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

    /// CLI별 자동 전환 토글 + 등록 계정 요약 — 설치 현황의 Claude/Codex 탭 공용.
    /// 계정들은 라운드 박스 안의 행으로(팝오버 카드와 같은 시각 언어 — PRIMARY 캡슐,
    /// 활성은 초록 점 + '사용 중'). 계정 추가 진입점: Claude는 로그인 플로우 버튼,
    /// Codex는 터미널 안내(adopt 방식).
    @ViewBuilder private func poolControls(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(loc("자동 전환"), isOn: Binding(
                get: { state.file.isAutoSwitchEnabled(provider) },
                set: { state.setAutoSwitch($0, provider: provider) }))
            Text(loc("한도가 차면 다음 계정으로 자동으로 이어집니다"))
                .font(.caption).foregroundStyle(.secondary)
        }
        let accounts = state.file.accounts(of: provider)
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if accounts.isEmpty {
                    Text(loc("등록된 계정이 없습니다"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                ForEach(Array(accounts.enumerated()), id: \.element.id) { idx, p in
                    accountRow(p, isPrimary: idx == 0, provider: provider)
                    if idx < accounts.count - 1 {
                        Divider().padding(.leading, 24)
                    }
                }
                // 계정 추가는 박스 안의 마지막 행 — 리스트를 수정하는 액션은 리스트 안에
                // (iOS/macOS 설정의 '계정 추가' 행 패턴). 떠 있는 작은 버튼보다 히트
                // 영역이 행 전체로 넓고 소속이 분명하다. Codex는 CLI adopt 방식이라
                // 행 대신 아래 안내 텍스트가 그 역할을 한다.
                if provider == .claude {
                    Divider().padding(.leading, 30)
                    Button { state.addAccount() } label: {
                        HStack(spacing: 8) {
                            // 위 계정 행들의 점(●)과 같은 글리프 컬럼(12pt) — 크기가 다른
                            // 아이콘이 점들과 나란하면 리듬이 깨진다 (사용자 피드백).
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 12)
                            Text(loc("계정 추가"))
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        // 팝오버 푸터의 계정 추가와 같은 회색 — 설정의 중립 팔레트에서
                        // 액센트 파랑은 혼자 튄다 (사용자 피드백).
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            if provider == .codex {
                Text(loc("터미널에서 `codex logout` 후 `codex login`으로 추가할 계정에 로그인하면, Mobius가 몇 초 안에 자동으로 등록합니다."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(loc("지금 쓰던 계정은 이미 카드에 저장돼 있어 카드를 눌러 언제든 되돌아올 수 있어요."))
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }


    /// 계정 요약 행 — [점 12pt 컬럼] 닉네임 · PRIMARY(회색) · 사용 중 ……… 이메일(우측).
    /// 이메일을 오른쪽 정렬해 닉네임 길이에 따른 지그재그를 없애고(왼쪽 이름/오른쪽 값 —
    /// macOS 설정 문법), PRIMARY 캡슐은 회색 톤다운 — 중립 팔레트에서 파랑은 혼자 튄다
    /// (사용자 피드백). 활성 표시는 초록 점 + '사용 중' 캡션.
    private func accountRow(_ p: AccountProfile, isPrimary: Bool,
                            provider: Provider) -> some View {
        let isActive = p.id == state.file.activeByProvider[provider]
        return HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
                .frame(width: 12)
            Text(p.nickname).font(.system(size: 11.5, weight: .medium))
            if isPrimary {
                Text("PRIMARY").font(.system(size: 7.5, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if isActive {
                Text(loc("사용 중")).font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.green)
            }
            Spacer()
            Text(p.emailAddress).font(.system(size: 10.5)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// mobius CLI 행 (일반 섹션) — 설치 상태 pill + 설치/재설치/삭제
    @ViewBuilder private var mobiusCLIRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("mobius CLI")
                    statusPill(installed: !mobiusPaths.isEmpty)
                }
                if !mobiusPaths.isEmpty {
                    Text(mobiusPaths.joined(separator: "  ·  "))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if mobiusChecked {
                if mobiusPaths.isEmpty {
                    Button(loc("설치")) { installMobius() }
                } else {
                    Button(loc("재설치")) { reinstallMobius() }
                    Button(loc("삭제"), role: .destructive) { uninstallMobius() }
                }
            }
        }
        if !cliMessage.isEmpty {
            Text(cliMessage).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 설치 상태 pill — AccountCardView의 PRIMARY 캡슐과 같은 스타일
    private func statusPill(installed: Bool) -> some View {
        let color: Color = installed ? .green : .orange
        return Text(installed ? loc("설치됨") : loc("미설치"))
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    /// fallback이 없는 상태 = 어느 프로바이더 풀에도 계정이 2개 이상 없다.
    /// 전체 수로 세면 Claude 1개 + Codex 1개일 때 안내가 사라지는데, 그 상태는
    /// 여전히 어떤 풀도 자동 전환이 불가능하다.
    private var needsFallbackOnboarding: Bool {
        !Provider.allCases.contains { state.file.accounts(of: $0).count >= 2 }
    }

    private var settingsForm: some View {
        Form {
            if needsFallbackOnboarding {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(state.file.accounts.isEmpty
                              ? loc("아직 등록된 계정이 없어요")
                              : loc("Fallback 계정을 추가해 보세요"),
                              systemImage: "infinity")
                            .font(.system(size: 13, weight: .semibold))
                        Text(.init(state.file.accounts.isEmpty
                             ? loc("아래 **설치 현황**의 **계정 추가** 버튼으로 Claude 계정을 등록하세요. 개인·회사 계정을 함께 등록해 두면, 한 계정의 사용량이 차는 순간 다음 계정으로 알아서 전환됩니다.")
                             : loc("지금은 계정이 하나뿐이라 사용량이 차면 기다리는 수밖에 없어요. 아래 **설치 현황**의 **계정 추가**로 계정을 하나 더 등록하면, 한도가 차는 순간 자동으로 이어서 쓸 수 있습니다.")))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
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
            }
            Section(loc("설치 현황")) {
                // mobius 자체 CLI는 프로바이더와 무관한 공통 도구 — 탭 위에 항상 표시.
                mobiusCLIRow
                PillPicker(options: Provider.allCases.map {
                    .init(value: $0.rawValue, label: $0.displayName,
                          badge: state.file.accounts(of: $0).count)
                }, selection: $settingsTabRaw, fillsWidth: true)
                switch settingsTab {
                case .claude:
                    // 탭 콘텐츠는 VStack 한 덩어리라 Form의 행 구분선이 없다 —
                    // 다른 섹션과 같은 표현으로 Divider를 직접 넣는다 (사용자 피드백).
                    VStack(alignment: .leading, spacing: 10) {
                        claudeCLIRow
                        Divider()
                        poolControls(.claude)
                    }
                    .padding(.vertical, 2)
                    // Claude Desktop 연동은 Claude 전용 기능 — 앱 상태와 토글을 한자리에
                    // (구 실험실 → 프로바이더 탭으로 이동, 사용자 요청).
                    VStack(alignment: .leading, spacing: 10) {
                        toolRow("Claude Desktop", path: claudeDesktop?.path,
                                version: claudeDesktop?.version)
                        Divider()
                        desktopToggles
                    }
                    .padding(.vertical, 2)
                case .codex:
                    VStack(alignment: .leading, spacing: 10) {
                        toolRow("Codex CLI", path: codexInfo?.path, version: codexInfo?.version)
                        Divider()
                        poolControls(.codex)
                    }
                    .padding(.vertical, 2)
                    // 동명의 "ChatGPT" 앱이 둘일 수 있어(구형 com.openai.chat) 번들 ID
                    // com.openai.codex(Codex 데스크톱)만 대상으로 감지한다.
                    toolRow("ChatGPT", path: chatGPTApp?.path, version: chatGPTApp?.version)
                }
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
        }
        .formStyle(.grouped)
        .frame(width: 580, height: needsFallbackOnboarding ? 820 : 680)
    }

    /// Desktop 토글 2종의 차이를 설명하는 ⓘ 팝오버 — "언제 / 하는 일 / 나머지는 누가"
    private func desktopInfoButton(isPresented: Binding<Bool>,
                                   when: String, note: String) -> some View {
        Button { isPresented.wrappedValue.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 7) {
                    Text(loc("언제")).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(when).font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 7) {
                    Text(loc("하는 일")).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(loc("Claude Desktop도 같은 계정으로 재시작해요 (2~5초)"))
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
        }
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

    /// Claude Desktop 동시 전환 토글 2종 — 설치 현황의 Claude 탭에 표시
    /// (Claude 전용 기능이라 실험실보다 프로바이더 탭이 제자리다).
    @ViewBuilder private var desktopToggles: some View {
        Toggle(isOn: Binding(
            get: { state.file.desktopSyncEnabled },
            set: { state.setDesktopSync($0) })) {
            HStack(spacing: 5) {
                Text(loc("계정 전환 시 Claude Desktop도 전환"))
                desktopInfoButton(
                    isPresented: $showDesktopSyncInfo,
                    when: loc("카드를 눌러 직접 계정을 바꿀 때"),
                    note: loc("자동 전환일 때는 '자동 전환 시에도 Claude Desktop 전환'이 담당해요. Desktop에 연결해 둔 계정에서만 동작해요."))
            }
        }
        Divider()
        Toggle(isOn: Binding(
            get: { state.file.desktopAutoSwitchEnabled },
            set: { state.setDesktopAutoSwitch($0) })) {
            HStack(spacing: 5) {
                Text(loc("자동 전환 시에도 Claude Desktop 전환"))
                desktopInfoButton(
                    isPresented: $showDesktopAutoInfo,
                    when: loc("한도가 차서 Mobius가 알아서 계정을 바꿀 때"),
                    note: loc("카드를 눌러 직접 바꿀 때는 '계정 전환 시 Claude Desktop도 전환'이 담당해요."))
            }
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
                state.downloadUpdate(info)
            } label: {
                Label(loc("새 버전 v%@ 받기", info.version), systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        case .downloading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(loc("다운로드 중…")) }
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text(loc("확인 실패 — 네트워크를 확인해주세요"))
                .font(.caption).foregroundStyle(.orange)
        }
    }

    // MARK: mobius 명령어 설치/재설치/삭제

    private var bundledMobiusPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "mobius")?.path
    }

    private func installMobius() {
        // 신규 설치는 /usr/local/bin/mobius 심볼릭 링크 (osascript로 관리자 권한)
        applyMobius(paths: ["/usr/local/bin/mobius"], action: .install)
    }

    private func reinstallMobius() {
        // 발견된 모든 위치의 심링크를 현재 번들 기준으로 재생성 (낡은 대상 교정)
        applyMobius(paths: mobiusPaths, action: .install)
    }

    private func uninstallMobius() {
        applyMobius(paths: mobiusPaths, action: .remove)
    }

    private enum MobiusCLIAction { case install, remove }

    /// 홈 아래 경로는 FileManager로 직접, /usr/local 등은 osascript 관리자 권한으로 처리.
    private func applyMobius(paths: [String], action: MobiusCLIAction) {
        guard !paths.isEmpty else { return }
        let src: String?
        if action == .install {
            guard let bundled = bundledMobiusPath else {
                cliMessage = loc("번들에서 mobius 바이너리를 찾을 수 없습니다 (개발 빌드에서는 Scripts/install-cli.sh 사용)")
                return
            }
            src = bundled
        } else {
            src = nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userPaths = paths.filter { $0.hasPrefix(home) }
        let adminPaths = paths.filter { !$0.hasPrefix(home) }
        var errors: [String] = []

        for path in userPaths {
            do {
                try? FileManager.default.removeItem(atPath: path)
                if let src {
                    try FileManager.default.createSymbolicLink(atPath: path,
                                                               withDestinationPath: src)
                }
            } catch { errors.append("\(path): \(error.localizedDescription)") }
        }

        if !adminPaths.isEmpty {
            let commands = adminPaths.map { path in
                if let src { return "ln -sf \(shellQuoted(src)) \(shellQuoted(path))" }
                return "rm -f \(shellQuoted(path))"
            }
            let command = (src != nil ? ["mkdir -p /usr/local/bin"] : []) + commands
            let script = "do shell script \(appleScriptQuoted(command.joined(separator: " && "))) with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                errors.append(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
            }
        }

        refreshMobius()
        if let first = errors.first {
            cliMessage = loc(action == .install ? "설치 실패: %@" : "삭제 실패: %@", first)
        } else if action == .install {
            cliMessage = loc("설치 완료: %@", paths.joined(separator: ", "))
        } else {
            cliMessage = loc("삭제 완료")
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
