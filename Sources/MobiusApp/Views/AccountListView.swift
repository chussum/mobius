import AppKit
import SwiftUI
import Combine
import MobiusCore

struct AccountListView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showUsageGauges") private var showUsageGauges = true
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @Namespace private var cardSpace

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                header
                if state.file.accounts.isEmpty {
                    emptyView
                } else {
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
        .frame(width: 410)
        .onReceive(clock) { now = $0 }
        .onAppear { state.reload(); state.refreshUsageIfStale(); now = Date() }
    }

    @State private var showFallbackInfo = false

    private var fallbackInfoButton: some View {
        Button { showFallbackInfo.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(loc("자동 Fallback이 무엇인지 보기"))
        .popover(isPresented: $showFallbackInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label(loc("자동 Fallback"), systemImage: "infinity")
                    .font(.system(size: 12, weight: .semibold))
                Text(loc("사용하던 계정의 한도가 다 차면, 아래 순서(우선순위)대로 여유 있는 다음 계정으로 자동 전환됩니다."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(loc("맨 위 계정의 한도가 초기화되면 다시 맨 위 계정으로 돌아옵니다."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                Text(loc("끄면 자동 전환 없이 한도 소진 알림만 보냅니다. 계정은 카드를 눌러 직접 바꿀 수 있어요."))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(width: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "infinity")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
            Text("Mobius").font(.system(size: 14, weight: .bold, design: .rounded))
            Text(loc("뫼비우스")).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            fallbackInfoButton
            Toggle(loc("Claude Code CLI 자동 Fallback"), isOn: Binding(
                get: { state.file.autoSwitchEnabled },
                set: { state.setAutoSwitch($0) }))
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 10))
        }
    }

    private var cards: some View {
        VStack(spacing: 6) {
            // primary (고정)
            if let primary = state.file.primary {
                card(primary, isPrimary: true)
            }
            // fallbacks (DnD 재정렬)
            List {
                ForEach(Array(state.file.accounts.dropFirst()), id: \.id) { p in
                    card(p, isPrimary: false)
                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { state.moveFallback(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: state.file.accounts.dropFirst().reduce(CGFloat(0)) { sum, p in
                sum + AccountCardView.estimatedHeight(
                    hasUsage: usageFor(p) != nil,
                    scopedCount: usageFor(p)?.scopedLimits?.count ?? 0)
            })
        }
    }

    private func usageFor(_ p: AccountProfile) -> UsageSnapshot? {
        showUsageGauges ? state.usage[p.id] : nil
    }

    private func card(_ p: AccountProfile, isPrimary: Bool) -> some View {
        AccountCardView(profile: p, isActive: p.id == state.file.activeAccountID,
                        isPrimary: isPrimary,
                        autoSwitchOn: state.file.autoSwitchEnabled,
                        usage: usageFor(p), now: now,
                        onConnectDesktop: state.desktopSwitcher.isDesktopInstalled
                            ? { state.beginDesktopCapture(for: p.id) } : nil,
                        onDelete: { state.removeAccount(p.id) },
                        onSetPrimary: isPrimary ? nil : {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                state.setPrimary(p.id)
                            }
                        },
                        onReauth: p.needsReauth ? { state.addAccount() } : nil)
            .matchedGeometryEffect(id: p.id, in: cardSpace)
            .onTapGesture {
                guard p.id != state.file.activeAccountID else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    state.manualSwitch(to: p.id)
                }
            }
            .contextMenu {
                if p.needsReauth {
                    Button(loc("다시 로그인")) { state.addAccount() }
                }
                if !isPrimary {
                    Button(loc("Primary 계정으로 설정")) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            state.setPrimary(p.id)
                        }
                    }
                }
                Button(p.hasDesktopSnapshot ? loc("Claude Desktop 다시 연결") : loc("Claude Desktop 연결")) {
                    state.beginDesktopCapture(for: p.id)
                }
                Button(loc("삭제"), role: .destructive) { state.removeAccount(p.id) }
            }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "infinity").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(loc("등록된 계정이 없습니다")).font(.system(size: 12)).foregroundStyle(.secondary)
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
            Button { state.addAccount() } label: {
                Label(loc("계정 추가"), systemImage: "plus.circle.fill").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            if let err = state.lastError {
                TruncatingErrorText(text: err)
            }
            // SettingsLink는 accessory(메뉴바 전용) 앱에서 창을 활성화하지 못해 무반응 —
            // 앱을 먼저 활성화한 뒤 openSettings 환경 액션으로 연다
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: { Image(systemName: "gearshape").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}
