import AppKit
import SwiftUI
import Combine
import MobiusCore

struct AccountListView: View {
    @EnvironmentObject var state: AppState
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @Namespace private var cardSpace

    var body: some View {
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
        .frame(width: 320)
        .onReceive(clock) { now = $0 }
        .onAppear { state.reload(); now = Date() }
    }

    private var header: some View {
        HStack {
            Text("Mobius").font(.system(size: 14, weight: .bold, design: .rounded))
            Text("뫼비우스").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Toggle("CLI 자동 fallback", isOn: Binding(
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
            .frame(height: CGFloat(max(0, state.file.accounts.count - 1)) * 68)
        }
    }

    private func card(_ p: AccountProfile, isPrimary: Bool) -> some View {
        AccountCardView(profile: p, isActive: p.id == state.file.activeAccountID,
                        isPrimary: isPrimary,
                        autoSwitchOn: state.file.autoSwitchEnabled, now: now)
            .matchedGeometryEffect(id: p.id, in: cardSpace)
            .onTapGesture {
                guard p.id != state.file.activeAccountID else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    state.manualSwitch(to: p.id)
                }
            }
            .contextMenu {
                Button("삭제", role: .destructive) { state.removeAccount(p.id) }
            }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "infinity").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("등록된 계정이 없습니다").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private var footer: some View {
        HStack {
            Button { state.addAccount() } label: {
                Label("계정 추가", systemImage: "plus.circle.fill").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            if let err = state.lastError {
                Text(err).font(.system(size: 9)).foregroundStyle(.red).lineLimit(1)
            }
            SettingsLink { Image(systemName: "gearshape").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}
