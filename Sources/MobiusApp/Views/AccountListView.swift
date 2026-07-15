import AppKit
import SwiftUI
import Combine
import MobiusCore

extension Provider {
    /// 사용자에게 보이는 CLI 도구 이름 (토글 라벨 등).
    var cliDisplayName: String {
        switch self {
        case .claude: return "Claude Code CLI"
        case .codex: return "Codex CLI"
        }
    }
}

/// 팝오버 상단 필터 탭 — 전체 / Claude / Codex. rawValue가 AppStorage로 저장돼
/// 마지막 선택이 재시작 후에도 유지된다.
enum ProviderTab: String, CaseIterable {
    case all, claude, codex

    var provider: Provider? {
        switch self {
        case .all: return nil
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    var title: String {
        switch self {
        case .all: return loc("전체")
        case .claude: return Provider.claude.displayName
        case .codex: return Provider.codex.displayName
        }
    }
}

struct AccountListView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showUsageGauges") private var showUsageGauges = true
    @AppStorage("providerTab") private var providerTabRaw = ProviderTab.all.rawValue
    @State private var now = Date()
    @State private var showAddChooser = false
    @State private var showCodexAddGuide = false
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var tab: ProviderTab { ProviderTab(rawValue: providerTabRaw) ?? .all }

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                header
                if state.file.accounts.isEmpty {
                    emptyView
                } else {
                    tabBar
                    cards
                }
                footer
            }
            .padding(14)
            .disabled(state.desktopCapture != nil)
            .blur(radius: state.desktopCapture != nil ? 2 : 0)
            // Desktop 연결 가이드 — 팝오버가 닫혔다 열려도 진행 상태가 이어진다
            if state.desktopCapture != nil {
                DesktopCaptureSheet()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85),
                   value: state.desktopCapture)
        .frame(width: 430)
        .onReceive(clock) { now = $0 }
        .onAppear { state.reload(); state.refreshUsageIfStale(); state.validateFallbacksLocally(); now = Date() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "infinity")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
            Text("Mobius").font(.system(size: 14, weight: .bold, design: .rounded))
            Text(loc("뫼비우스")).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            // 풀 탭에서만 그 풀의 자동 전환 토글 — 구 전역 토글과 같은 자리라 익숙하고,
            // 탭 바가 한 줄을 온전히 쓸 수 있다(100% 폭). 전체 탭의 풀별 토글은 설정에.
            // 라벨은 어느 CLI의 전환인지 명시 (Claude Code CLI / Codex CLI — 사용자 요청).
            if let provider = tab.provider {
                Toggle(loc("%@ 자동 전환", provider.cliDisplayName), isOn: Binding(
                    get: { state.file.isAutoSwitchEnabled(provider) },
                    set: { state.setAutoSwitch($0, provider: provider) }))
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 10))
                    .help(loc("한도가 차면 다음 계정으로 자동으로 이어집니다"))
            }
        }
    }

    private var providersWithAccounts: [Provider] {
        Provider.allCases.filter { !state.file.accounts(of: $0).isEmpty }
    }

    // MARK: 프로바이더 탭 바 — 100% 폭, 3등분 (자동 전환 토글은 헤더 오른쪽)

    private func poolCount(_ t: ProviderTab) -> Int {
        t.provider.map { state.file.accounts(of: $0).count } ?? state.file.accounts.count
    }

    private var tabBar: some View {
        PillPicker(options: ProviderTab.allCases.map {
            .init(value: $0.rawValue, label: $0.title, badge: poolCount($0))
        }, selection: $providerTabRaw, fillsWidth: true)
    }

    // MARK: 카드 목록

    @ViewBuilder private var cards: some View {
        if let provider = tab.provider {
            // 풀 탭: 타이틀 없이 그 풀만 (기존 단일 풀 시절 디자인)
            poolCards(provider)
        } else {
            // 전체 탭: 풀별 섹션 + 타이틀 (두 풀 다 있을 때만 타이틀 표기)
            VStack(spacing: 14) {
                ForEach(providersWithAccounts, id: \.self) { provider in
                    VStack(spacing: 5) {
                        if providersWithAccounts.count > 1 {
                            sectionHeader(provider)
                        }
                        poolCards(provider)
                    }
                }
            }
        }
    }

    /// 전체 탭의 풀 경계 — 대문자 레이블 + 오른쪽으로 흐르는 헤어라인.
    /// 맨글자 하나만 떠 있으면 길 잃은 텍스트처럼 보여서(사용자 피드백), 디바이더로
    /// "여기부터 이 풀"임을 시각적으로 고정한다.
    private func sectionHeader(_ provider: Provider) -> some View {
        HStack(spacing: 8) {
            Text(provider.displayName.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.leading, 2)
    }

    // ★ primary 카드도 반드시 풀의 같은 List의 행이어야 한다 (이슈 #5). primary를 List 밖
    // 고정 슬롯에 두면 primary 전환 때 List 멤버십이 바뀌어(승격 행 삭제 + 강등 행 삽입)
    // NSTableView 기반 List가 스크롤 오프셋을 한 행만큼 어긋난 채 방치한다 — 카드 높이가
    // 전부 같아 frame(height:)이 안 변하는 경우(예: 전 계정 게이지 표시)에만 나타나 재현이
    // 까다로웠다. 풀의 전 계정을 한 List에 두면(primary는 moveDisabled) 전환이 같은 id 집합
    // 내 "행 이동"으로 diff되어 오프셋이 깨지지 않는다 (실측: 미니 재현 앱 + 실앱 검증,
    // 2026-07-15).
    @ViewBuilder private func poolCards(_ provider: Provider) -> some View {
        let accounts = state.file.accounts(of: provider)
        if accounts.isEmpty {
            poolEmptyView(provider)
        } else {
            List {
                ForEach(accounts, id: \.id) { p in
                    let isPrimary = p.id == accounts.first?.id
                    card(p, isPrimary: isPrimary)
                        // 시각 위계: fallback 카드는 양쪽을 균등하게 들여 primary보다 살짝
                        // 작게(가운데 정렬). 행 안의 스타일 변경이라 이슈 #5(멤버십 불변)와
                        // 무관 — primary 전환 시에도 행은 그대로, 크기만 다시 그려진다.
                        .padding(.horizontal, isPrimary ? 0 : 12)
                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .moveDisabled(isPrimary)
                }
                .onMove { state.moveFallback(provider: provider, from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // 높이가 내용과 정확히 같아 스크롤할 게 없다 — 스크롤을 꺼서 세로 스크롤바
            // 거터(카드가 왼쪽으로 밀리며 오른쪽에 빈 틈)가 생기지 않게 한다 (사용자 실측).
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            // macOS List(NSTableView)가 행 콘텐츠에 좌 7pt·우 9pt의 자체 여백을 비대칭으로
            // 얹어, 카드가 List 밖 요소(탭 바·헤더, 패딩 14)보다 좁고 어긋나 보인다
            // (픽셀 실측 2026-07-15: 카드 [21..407] vs 컨테이너 [14..416]). 음수 패딩으로 상쇄.
            .padding(.leading, -7)
            .padding(.trailing, -9)
            .frame(height: accounts.reduce(CGFloat(0)) { sum, p in
                sum + AccountCardView.estimatedHeight(
                    hasUsage: usageFor(p) != nil,
                    scopedCount: usageFor(p)?.scopedLimits?.count ?? 0,
                    codexHint: codexAwaitingData(p))
            })
        }
    }

    /// 풀 탭이 비어 있을 때 — 프로바이더별 계정 추가 안내.
    @ViewBuilder private func poolEmptyView(_ provider: Provider) -> some View {
        VStack(spacing: 8) {
            Text(loc("등록된 계정이 없습니다"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            switch provider {
            case .claude:
                Button { state.addAccount() } label: {
                    Label(loc("Claude 계정 추가"), systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .codex:
                Text(loc("터미널에서 `codex logout` 후 `codex login`으로 추가할 계정에 로그인하면, Mobius가 몇 초 안에 자동으로 등록합니다."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
    }

    private func usageFor(_ p: AccountProfile) -> UsageSnapshot? {
        showUsageGauges ? state.usage[p.id] : nil
    }

    private func isActive(_ p: AccountProfile) -> Bool {
        p.id == state.file.activeByProvider[p.provider]
    }

    /// 활성 Codex 계정인데 아직 사용량 데이터가 없을 때(게이지 켜짐 + Codex는 세션 로그
    /// in-band라 앱 시작 후 codex 턴이 한 번 돌아야 rate_limits가 생김) 빈 게이지 대신 안내.
    private func codexAwaitingData(_ p: AccountProfile) -> Bool {
        showUsageGauges && p.provider == .codex && isActive(p) && state.usage[p.id] == nil
    }

    private func card(_ p: AccountProfile, isPrimary: Bool) -> some View {
        // Desktop 연결·재로그인 플로우는 Claude 전용 (Codex 재로그인 감지는 미배선)
        let claudeCard = p.provider == .claude
        // 낙관적 표시: 수동 전환(Claude) 클릭 직후 pendingSwitchID로 그 카드를 즉시 활성으로
        // 보여줘 UI가 스무스하게 전환된 것처럼 보이게 한다. Codex·평시엔 풀별 isActive.
        let showActive = claudeCard && state.pendingSwitchID != nil
            ? (p.id == state.pendingSwitchID) : isActive(p)
        return AccountCardView(profile: p, isActive: showActive,
                        isPrimary: isPrimary,
                        autoSwitchOn: state.file.isAutoSwitchEnabled(p.provider),
                        usage: usageFor(p), codexAwaitingData: codexAwaitingData(p), now: now,
                        onConnectDesktop: claudeCard && state.desktopSwitcher.isDesktopInstalled
                            ? { state.beginDesktopCapture(for: p.id) } : nil,
                        onDelete: { state.removeAccount(p.id) },
                        onSetPrimary: isPrimary ? nil : {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                state.setPrimary(p.id)
                            }
                        },
                        onReauth: p.needsReauth && claudeCard ? { state.addAccount() } : nil)
            .onTapGesture {
                guard !isActive(p) else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    state.manualSwitch(to: p.id)
                }
            }
            .contextMenu {
                if p.needsReauth && claudeCard {
                    Button(loc("다시 로그인")) { state.addAccount() }
                }
                if !isPrimary {
                    Button(loc("Primary 계정으로 설정")) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            state.setPrimary(p.id)
                        }
                    }
                }
                if claudeCard {
                    Button(p.hasDesktopSnapshot ? loc("Claude Desktop 다시 연결") : loc("Claude Desktop 연결")) {
                        state.beginDesktopCapture(for: p.id)
                    }
                }
                Button(loc("삭제"), role: .destructive) { state.removeAccount(p.id) }
            }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "infinity").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(loc("등록된 계정이 없습니다")).font(.system(size: 12)).foregroundStyle(.secondary)
            // 1클릭 온보딩 — 설정 경유 없이 Claude 로그인 플로우를 바로 시작한다.
            // (CLI 미설치면 addAccount가 설정에서 설치하도록 안내.)
            Button { state.addAccount() } label: {
                Label(loc("Claude 계정 추가"), systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            // Codex(터미널 adopt)·CLI 설치 등은 설정에서
            Button(loc("설정에서 추가 (Codex 포함)")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    /// 푸터 오류 메시지 — 공간이 모자라 …로 잘렸을 때만 hover 툴팁으로 전체를 보여준다.
    /// (숨긴 fixedSize 텍스트로 '필요한 전체 폭'을 재고, 실제 표시 폭과 비교해 잘림을 감지)
    private struct TruncatingErrorText: View {
        let text: String
        @State private var visibleWidth: CGFloat = 0
        @State private var fullWidth: CGFloat = 0
        private var isTruncated: Bool { fullWidth > visibleWidth + 0.5 }

        var body: some View {
            let label = Text(text).font(.system(size: 9)).foregroundStyle(.red)
                .lineLimit(1).truncationMode(.tail)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { visibleWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in visibleWidth = w }
                })
                .background(
                    Text(text).font(.system(size: 9)).lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .hidden()
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { fullWidth = g.size.width }
                                .onChange(of: g.size.width) { _, w in fullWidth = w }
                        })
                )
            if isTruncated { label.help(text) } else { label }
        }
    }

    private var footer: some View {
        HStack {
            if !state.file.accounts.isEmpty {
                addAccountButton
            }
            if let err = state.lastError {
                TruncatingErrorText(text: err)
            }
            Spacer()
            // SettingsLink는 accessory(메뉴바 전용) 앱에서 창을 활성화하지 못해 무반응 —
            // 앱을 먼저 활성화한 뒤 openSettings 환경 액션으로 연다
            footerButton("gearshape", help: loc("설정")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            footerButton("power", help: loc("종료")) { NSApp.terminate(nil) }
        }
    }

    /// 계정 추가 — 탭에 따라 동작이 다르다: Claude 탭은 브라우저 로그인 즉시,
    /// Codex 탭은 CLI 안내(브라우저 로그인 미지원), 전체 탭은 프로바이더 선택 팝오버.
    @ViewBuilder private var addAccountButton: some View {
        let label = Label(loc("계정 추가"), systemImage: "plus.circle.fill")
            .font(.system(size: 11))
        switch tab {
        case .claude:
            Button { state.addAccount() } label: { label }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        case .codex:
            Button { showCodexAddGuide.toggle() } label: { label }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .popover(isPresented: $showCodexAddGuide, arrowEdge: .bottom) {
                    codexAddGuide.padding(14).frame(width: 280)
                }
        case .all:
            Button { showAddChooser.toggle() } label: { label }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .popover(isPresented: $showAddChooser, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            showAddChooser = false
                            state.addAccount()
                        } label: {
                            Label(loc("Claude 계정 추가"), systemImage: "globe")
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Divider()
                        codexAddGuide
                    }
                    .padding(14)
                    .frame(width: 280)
                }
        }
    }

    /// Codex 계정 추가 안내 — 브라우저 로그인 미지원, CLI adopt 방식 안내.
    private var codexAddGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(loc("Codex는 터미널로 추가해요"), systemImage: "terminal")
                .font(.system(size: 12, weight: .semibold))
            Text(loc("터미널에서 `codex logout` 후 `codex login`으로 추가할 계정에 로그인하면, Mobius가 몇 초 안에 자동으로 등록합니다."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(loc("지금 쓰던 계정은 이미 카드에 저장돼 있어 카드를 눌러 언제든 되돌아올 수 있어요."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// footer 아이콘 버튼 — 아이콘보다 넓은 히트 영역(28pt)으로 누르기 쉽게
    private func footerButton(_ symbol: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help(help)
    }
}
