import SwiftUI
import BottoCore

struct WorkspaceTabs: View {
    enum Destination: Hashable { case bots, artifacts, search }
    let store: AppStore
    let presentation: WorkspacePresentation
    let rootCovered: Bool
    let onSettings: () -> Void
    let onNewBot: () -> Void
    @State private var selected = Destination.bots
    @State private var query = ""
    @State private var reader: LibraryArtifactPreviewSession?
    @State private var chatAfterReaderDismissal: LibraryChat?
    @State private var openingTask: Task<Void, Never>?
    @State private var navigationError: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var openingChat: Bool { openingTask != nil }

    private var hidesTabs: Bool {
        selected == .bots && sizeClass == .compact && store.selectedBot != nil && !presentation.isBrowsingBots
    }

    var body: some View {
        searchableTabs
            .overlay(alignment: .bottom) {
                if openingChat {
                    HStack(spacing: 16) {
                        ProgressView("Opening chat…")
                        Button("Cancel") { cancelOpening() }
                    }
                    .padding().background(.regularMaterial, in: Capsule()).padding(.bottom, 80)
                }
            }
            .sheet(item: $reader, onDismiss: readerDidDismiss) { session in
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.item.chat.botName).font(.subheadline.weight(.semibold))
                            Text(session.item.chat.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open chat", systemImage: "bubble.left") {
                            guard !session.isPresentingOutput else { return }
                            closeReader(opening: session.item.chat)
                        }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .disabled(!session.isCurrent || session.isPresentingOutput)
                        .accessibilityIdentifier("library-open-chat")
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                    ArtifactPreview(session: session, isExpanded: true,
                                    onClose: { guard !session.isPresentingOutput else { return }; closeReader() },
                                    onRetry: { session.retry() })
                }
                .background(BottoTheme.paper)
                .interactiveDismissDisabled(session.isPresentingOutput)
                .presentationDetents([.large])
                .onDisappear { session.finish() }
            }
            .alert("Could Not Open Chat", isPresented: Binding(get: { navigationError != nil }, set: { if !$0 { navigationError = nil } })) {
                Button("OK") { navigationError = nil }
            } message: { Text(navigationError ?? "") }
            .task(id: refreshKey) {
                guard selected != .bots else { return }
                await store.refreshLibrary()
            }
            .onChange(of: ObjectIdentifier(store.library)) { _, _ in
                cancelOpening(); closeReader(); query = ""; selected = .bots
            }
            .onChange(of: store.notificationNavigationRevision) { _, _ in
                cancelOpening(); closeReader(); selected = .bots
            }
            .onChange(of: rootCovered) { _, covered in
                if covered { cancelOpening(); closeReader(); presentation.retireSearchFocus() }
            }
            .onChange(of: selected) { _, tab in
                cancelOpening()
                if tab != .bots { presentation.retireSearchFocus() }
            }
    }

    private struct RefreshKey: Equatable {
        let library: ObjectIdentifier
        let connected: Bool
        let needsLibrary: Bool
    }
    private var refreshKey: RefreshKey {
        .init(library: ObjectIdentifier(store.library), connected: store.isConnected, needsLibrary: selected != .bots)
    }

    @ViewBuilder private var searchableTabs: some View {
        if #available(iOS 26, *) {
            tabs.tabViewSearchActivation(.searchTabSelection)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $selected) {
            Tab("Bots", systemImage: "bubble.left.and.bubble.right", value: .bots) {
                AdaptiveWorkspace(store: store, presentation: presentation,
                                  rootCovered: rootCovered || reader != nil || selected != .bots,
                                  onSettings: onSettings, onNewBot: onNewBot)
                    .toolbar(hidesTabs ? .hidden : .visible, for: .tabBar)
            }
            Tab("Artifacts", systemImage: "square.stack", value: .artifacts) {
                ArtifactsView(store: store, library: store.library, onOpen: openArtifact)
                    .id(ObjectIdentifier(store.library))
                    .toolbar(.visible, for: .tabBar)
            }
            Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
                WorkspaceSearchView(store: store, library: store.library, query: $query,
                                    onBot: openBot, onChat: openChat, onArtifact: openArtifact, onMessage: openMessage)
                    .id(ObjectIdentifier(store.library))
                    .toolbar(.visible, for: .tabBar)
            }
        }
    }

    private func openArtifact(_ item: LibraryArtifact) {
        guard !rootCovered, !openingChat, store.library.isCurrent(item) else { return }
        closeReader()
        let session = LibraryArtifactPreviewSession(item: item, library: store.library)
        reader = session
        session.retry()
    }

    private func closeReader(opening chat: LibraryChat? = nil) {
        chatAfterReaderDismissal = chat
        reader?.finish()
        reader = nil
    }

    private func readerDidDismiss() {
        guard let chat = chatAfterReaderDismissal else { return }
        chatAfterReaderDismissal = nil
        openChat(chat)
    }

    private func openChat(_ chat: LibraryChat) {
        guard !rootCovered, !openingChat, store.library.isCurrent(chat) else { return }
        let library = store.library
        let origin = selected
        openingTask = Task {
            let opened = await store.openLibraryChat(chat)
            guard !Task.isCancelled, store.library === library, selected == origin, !rootCovered else { return }
            openingTask = nil
            if opened {
                presentation.didChooseConversation()
                selected = .bots
            } else {
                navigationError = "This chat couldn’t be opened. Check your connection, then refresh and try again."
            }
        }
    }

    private func cancelOpening() {
        chatAfterReaderDismissal = nil
        openingTask?.cancel(); openingTask = nil
    }

    private func openMessage(_ target: SearchMessageTarget) {
        guard !rootCovered, !openingChat, store.library.isCurrent(target.chat) else { return }
        let library = store.library, origin = selected
        openingTask = Task {
            let result = await store.openSearchMessage(target)
            guard !Task.isCancelled, store.library === library, selected == origin, !rootCovered else { return }
            openingTask = nil
            switch result {
            case .opened(let focus):
                presentation.didChooseConversation(focusing: focus)
                selected = .bots
            case .unavailable:
                navigationError = "This message is no longer available here. Refresh Search and try again."
            case .couldNotOpen:
                navigationError = "This chat couldn’t be opened. Check your connection and try again."
            case .superseded: break
            }
        }
    }

    private func openBot(_ bot: BotProfile) {
        guard !rootCovered, !openingChat, store.bot(withID: bot.id) != nil,
              let profile = try? ExactID(bot.id) else { return }
        let workspace = store.chats
        store.selectedBotID = bot.id
        guard let intent = workspace.captureOpening(profile: profile) else { return }
        presentation.didChooseConversation()
        selected = .bots
        Task { await workspace.open(intent) }
    }
}
