import AppKit
import BottoCore
import SwiftUI

/// One window: the spaces list, then an open space or the new-space page, with Botto's page as an inspector.
struct MacRootView: View {
    let server: LocalT3ServerManager
    @Bindable var store: MacBottoStore
    @State private var firstBot = MacFirstBotDraft()
    @State private var renaming: T3ChannelSummary?
    @State private var previewing: MacPreviewItem?

    var body: some View {
        Group {
            if store.needsBotSetup, let bot = store.bot {
                // Nothing else in the window makes sense until the bot has a name and a face.
                MacFirstBotPage(store: store, bot: bot, draft: $firstBot)
                    .toolbarBackground(MacTheme.paper, for: .windowToolbar)
                    .toolbar(removing: .title)
                    .navigationTitle("Botto")
            } else {
                workspace
            }
        }
        .tint(MacTheme.action)
        .onChange(of: server.state) { _, state in if state != .running { previewing = nil } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from Terminal or a download page is when a provider has usually just been set up.
            guard store.wantsProviderCheck else { return }
            Task { await store.loadProviders() }
        }
    }

    private var workspace: some View {
        NavigationSplitView {
            MacChatSidebar(server: server, store: store, onRename: { renaming = $0 }, onPreview: { previewing = $0 })
                .navigationSplitViewColumnWidth(min: 230, ideal: 272, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if let notice = store.pendingMutationNotice {
                    errorBanner(notice) {
                        Button("Acknowledge", action: store.acknowledgeUncertainAction)
                    }
                }
                if let error = store.error {
                    errorBanner(error) {
                        Button(action: store.dismissError) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Dismiss message")
                    }
                }
                if !store.providersNeedingSetup.isEmpty, !store.showsProviderGuide { MacProviderBanner(store: store) }
                detail
            }
            .background(MacTheme.paper)
            .navigationTitle(store.selectedChannel?.displayTitle ?? "Botto")
        }
        .inspector(isPresented: $store.showsInspector) {
            MacBottoInspector(server: server, store: store, onPreview: { previewing = $0 })
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar(removing: .title)
        .toolbarBackground(MacTheme.paper, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.showFreshPage() } label: { Label("New Space", systemImage: "square.and.pencil") }
                    .help("New Space (⌘N)")
                    .disabled(!store.canStartSpace)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.showsInspector.toggle() } label: { Label("Botto", systemImage: "sidebar.trailing") }
                    .help("Botto (⌘I)")
                    .disabled(!store.isConnected)
            }
        }
        .sheet(item: $renaming) { chat in MacRenameSpaceSheet(chat: chat, store: store) }
        .sheet(item: $previewing) { item in MacFilePreview(item: item) }
    }

    private func errorBanner<Control: View>(_ error: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(MacTheme.error)
            Text(error).font(.callout).lineLimit(4).textSelection(.enabled)
            Spacer(minLength: 0)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(MacTheme.surface, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var detail: some View {
        let profileID = store.bot?.id ?? "main"
        let appearance = store.bot?.appearance
        let name = store.bot?.name ?? "Botto"
        if store.showsProviderGuide {
            MacProviderGuide(store: store)
        } else if let opened = store.openedConversation {
            let id = opened.identity.stored.text
            MacChatPane(store: store, opened: opened, draft: Binding(
                get: { store.drafts[id, default: ""] },
                set: { store.drafts[id] = $0.isEmpty ? nil : $0 }
            ), onPreview: { previewing = $0 })
            .id(id)
        } else if store.isConnecting || store.isOpeningChannel || server.state == .starting {
            MacMoodState(profileID: profileID, appearance: appearance, activity: .thinking,
                         title: store.isOpeningChannel ? "Opening the space…" : "\(name) is waking up…",
                         message: store.isOpeningChannel ? "Fetching the conversation." : "Starting the engine on this Mac.")
        } else {
            switch server.state {
            case .failed(let reason):
                MacMoodState(profileID: profileID, appearance: appearance, activity: .sleeping,
                             title: "\(name) couldn’t wake up", message: reason) {
                    Button("Wake \(name)") { server.start() }.buttonStyle(MacPillButtonStyle())
                }
            case .stopped:
                MacMoodState(profileID: profileID, appearance: appearance, activity: .sleeping,
                             title: "\(name) is asleep",
                             message: "Wake \(name) to pick up your spaces on this Mac and your phone.") {
                    Button("Wake \(name)") { server.start() }.buttonStyle(MacPillButtonStyle())
                }
            case .running where !store.isConnected:
                MacMoodState(profileID: profileID, appearance: appearance, activity: .waiting,
                             title: "Can’t reach \(name)",
                             message: "The engine is running, but \(name) couldn’t connect to it.") {
                    Button("Reconnect") { Task { await store.connect(to: server) } }.buttonStyle(MacPillButtonStyle())
                    Button("Pair Again") { Task { await store.connect(to: server, pairingAgain: true) } }
                        .buttonStyle(MacPillButtonStyle(prominent: false))
                }
            default:
                if let selected = store.selectedChannel {
                    MacMoodState(profileID: profileID, appearance: appearance, activity: .waiting,
                                 title: "“\(selected.displayTitle)” didn’t open",
                                 message: "Something got in the way. Try again?") {
                        Button("Retry") { Task { await store.openChannel(selected.id) } }.buttonStyle(MacPillButtonStyle())
                        Button("New Space") { store.showFreshPage() }.buttonStyle(MacPillButtonStyle(prominent: false))
                    }
                } else {
                    MacFreshPage(store: store, form: store.fresh)
                }
            }
        }
    }
}

private struct MacRenameSpaceSheet: View {
    let chat: T3ChannelSummary
    let store: MacBottoStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename space").font(MacTheme.rounded(.title3, weight: .bold))
            TextField("Space name", text: $title)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(MacTheme.surface, in: .rect(cornerRadius: 12))
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(MacPillButtonStyle(prominent: false))
                Button("Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(MacPillButtonStyle())
                    .disabled(!canSubmit)
            }
        }
        .padding(22)
        .frame(width: 360)
        .background(MacTheme.paper)
        .onAppear { title = chat.isUntitled ? "" : chat.displayTitle }
        .disabled(saving)
    }

    private var canSubmit: Bool {
        store.isConnected && !saving && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        saving = true
        Task {
            defer { saving = false }
            if await store.renameChannel(threadID: chat.id, title: title) { dismiss() }
        }
    }
}
