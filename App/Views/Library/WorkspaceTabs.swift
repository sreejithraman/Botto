import SwiftUI
import BottoCore

struct WorkspaceTabs: View {
    let store: AppStore
    @Bindable var presentation: WorkspacePresentation
    let rootCovered: Bool
    let onSettings: () -> Void
    let onNewBot: () -> Void
    @State private var query = ""
    @State private var navigationError: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var selected: WorkspaceDestination { presentation.destination }
    private var openingChat: Bool { presentation.libraryOpening != nil }

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
            .sheet(item: $presentation.libraryReader, onDismiss: readerDidDismiss) { session in
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
                                    onRetry: { session.retry() },
                                    connectionFeedback: session.requiresConnection && !store.isConnected
                                        ? AnyView(ConnectionStatusView(store: store)) : nil)
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
                await store.refreshLibraryIfNeeded()
            }
            .onChange(of: ObjectIdentifier(store.library)) { _, _ in
                cancelOpening(); closeReader(); query = ""; presentation.destination = .bots
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
        let destination: WorkspaceDestination
        let revalidation: UUID
    }
    private var refreshKey: RefreshKey? {
        guard selected != .bots else { return nil }
        return .init(library: ObjectIdentifier(store.library), connected: store.isConnected,
              destination: selected, revalidation: store.library.revalidationRevision)
    }

    @ViewBuilder private var searchableTabs: some View {
        if #available(iOS 26, *) {
            tabs.tabViewSearchActivation(.searchTabSelection)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $presentation.destination) {
            Tab("Bots", systemImage: "bubble.left.and.bubble.right", value: .bots) {
                AdaptiveWorkspace(store: store, presentation: presentation,
                                  rootCovered: rootCovered || presentation.libraryReader != nil || selected != .bots,
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
        presentation.libraryReader = session
        session.retry()
    }

    private func closeReader(opening chat: LibraryChat? = nil) {
        presentation.closeLibraryReader(opening: chat)
    }

    private func readerDidDismiss() {
        guard let chat = presentation.takeChatAfterReaderDismissal() else { return }
        openChat(chat)
    }

    private func openChat(_ chat: LibraryChat) {
        guard !rootCovered, !openingChat, store.library.isCurrent(chat) else { return }
        let library = store.library
        let origin = selected
        presentation.libraryOpening = Task {
            let opened = await store.openLibraryChat(chat)
            guard !Task.isCancelled, store.library === library, selected == origin, !rootCovered else { return }
            presentation.libraryOpening = nil
            if opened {
                presentation.didChooseConversation()
            } else {
                navigationError = "This chat couldn’t be opened. Check your connection, then refresh and try again."
            }
        }
    }

    private func cancelOpening() { presentation.cancelLibraryOpening() }

    private func openMessage(_ target: SearchMessageTarget) {
        guard !rootCovered, !openingChat, store.library.isCurrent(target.chat) else { return }
        let library = store.library, origin = selected
        presentation.libraryOpening = Task {
            let result = await store.openSearchMessage(target)
            guard !Task.isCancelled, store.library === library, selected == origin, !rootCovered else { return }
            presentation.libraryOpening = nil
            switch result {
            case .opened(let focus):
                presentation.didChooseConversation(focusing: focus)
            case .unavailable:
                navigationError = "This message is no longer available here. Refresh Search and try again."
            case .couldNotOpen:
                navigationError = "This chat couldn’t be opened. Check your connection and try again."
            case .superseded: break
            }
        }
    }

    private func openBot(_ bot: BotProfile) {
        guard !rootCovered, !openingChat, store.bot(withID: bot.id) != nil else { return }
        guard let opening = store.prepareBotOpening(bot) else { return }
        presentation.didChooseConversation()
        Task { await store.openBot(opening) }
    }
}
