import SwiftUI
import BottoCore

/// The whole T3 app: one conversation surface, a spaces drawer over it, and Botto's page.
/// There is no tab bar and no list to land on; launch opens the main space, or one that needs attention.
struct T3Workspace: View {
    let store: AppStore
    let presentation: WorkspacePresentation
    let rootCovered: Bool
    let onSettings: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing = ComposerEditingHandle()
    @State private var outputs = T3OutputsModel()
    @State private var drawerOpen = false
    @State private var drawerDrag: CGFloat = 0
    @State private var showsFresh = true
    @State private var showsBotto = false
    @State private var openedOutput: T3OutputFile?
    @State private var chatCovered = false
    @State private var openingChat: String?
    @State private var openingError: String?
    @State private var launched = false

    private var artifactShown: Bool { presentation.artifact != nil }
    /// Anything above the conversation that should stop its reading, editing and toolbar actions.
    private var conversationCovered: Bool {
        rootCovered || drawerOpen || drawerDrag != 0 || showsBotto || artifactShown || openedOutput != nil
    }
    private var chatActionsAvailable: Bool { !conversationCovered && !chatCovered && scenePhase == .active }
    private var showsChat: Bool { !showsFresh && store.selectedBot != nil && store.selectedT3ChannelID != nil }

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.86, 340)
            let progress = drawerProgress(width: width)
            ZStack(alignment: .leading) {
                NavigationStack { surface }
                    .environment(\.t3Chrome, chrome)
                    .environment(\.composerEditing, editing)
                    .accessibilityHidden(progress > 0)
                // Dragging the dimmed space closes the drawer; rows keep their own swipe actions.
                Color.black.opacity(0.28 * progress)
                    .ignoresSafeArea()
                    .allowsHitTesting(progress > 0)
                    .onTapGesture { setDrawer(open: false) }
                    .gesture(closeDrag(width: width))
                    .accessibilityHidden(true)
                T3ChatsDrawer(store: store, outputs: outputs, openingChatID: openingChat, error: $openingError,
                              isExposed: drawerOpen && !rootCovered && !showsBotto,
                              onOpen: open, onNewSpace: startFresh, onOpenFile: openFile,
                              onBotto: { presentBotto() }, onSettings: openSettings, onClose: { setDrawer(open: false) })
                    .frame(width: width)
                    .background(BottoTheme.paper.ignoresSafeArea())
                    .compositingGroup()
                    .shadow(color: .black.opacity(progress > 0 ? 0.12 : 0), radius: 24, x: 8)
                    .offset(x: (progress - 1) * (width + 32))
                    .accessibilityHidden(progress == 0)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { setDrawer(open: false) }
                if progress == 0, !conversationCovered {
                    // A thin edge strip clear of the top bar and the composer opens the drawer.
                    Color.clear.frame(width: 18).contentShape(Rectangle())
                        .gesture(openDrag(width: width))
                        .padding(.top, 110).padding(.bottom, 140)
                        .accessibilityHidden(true)
                }
            }
        }
        .background(BottoTheme.paper.ignoresSafeArea())
        .sheet(isPresented: $showsBotto) {
            BottoPage(store: store, outputs: outputs, onOpenChat: { channel in
                showsBotto = false
                Task { await afterSheet { open(channel) } }
            }, onSettings: {
                showsBotto = false
                Task { await afterSheet(onSettings) }
            })
        }
        .sheet(item: $openedOutput) { T3OutputPreview(store: store, output: $0) }
        .sheet(isPresented: artifactBinding) { artifactReader }
        .task(id: LaunchKey(channels: store.t3Channels.count, hasMain: hasMain, link: store.link, refreshing: store.isRefreshing)) {
            await decideLaunch()
        }
        .task(id: store.connectionGeneration) {
            guard store.isConnected else { return }
            await outputs.load(store)
            await store.loadT3ModelsIfNeeded()
        }
        .onChange(of: store.selectedT3ChannelID) { old, new in
            // A notification or another opener chose a space; show it rather than the new-space page.
            if new != nil, new != old, openingChat == nil { showsFresh = false }
        }
        .onChange(of: store.notificationNavigationRevision) { _, _ in
            showsFresh = false
            closeDrawerImmediately()
        }
        .onChange(of: rootCovered) { _, covered in if covered { editing.cancel() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { editing.cancel() } }
        .onChange(of: store.configuration?.id) { _, _ in
            launched = false
            showsFresh = true
            showsBotto = false
            openedOutput = nil
            closeDrawerImmediately()
        }
    }

    // MARK: Surface

    @ViewBuilder private var surface: some View {
        if showsChat, let bot = store.selectedBot {
            ChatView(store: store, bot: bot, presentation: presentation,
                     isExposed: !conversationCovered, isEditingExposed: !conversationCovered,
                     importPaneVisible: !artifactShown, rootCovered: conversationCovered,
                     onLocalModalPresentation: { [renderedBotID = bot.id] covered in
                         guard store.selectedBotID == renderedBotID else { return }
                         chatCovered = covered
                     }, toolbarVisible: true,
                     canPresentToolbar: { chatActionsAvailable }, canContinueEditing: { chatActionsAvailable })
                .id(bot.id)
                .bottoNavigationChrome()
                .navigationBarTitleDisplayMode(.inline)
        } else {
            T3FreshPage(store: store, namesSpace: launched, isExposed: !conversationCovered && scenePhase == .active,
                        onOpenChat: open, onStarted: { showsFresh = false })
                .bottoNavigationChrome()
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var chrome: T3ChromeActions {
        T3ChromeActions(openDrawer: { setDrawer(open: true) }, newSpace: startFresh, openBotto: { presentBotto() })
    }

    // MARK: Drawer motion

    private func drawerProgress(width: CGFloat) -> CGFloat {
        let base: CGFloat = drawerOpen ? 1 : 0
        return min(1, max(0, base + drawerDrag / width))
    }

    private var drawerAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.38, bounce: 0.12)
    }

    private func setDrawer(open: Bool) {
        if open {
            guard !rootCovered, !showsBotto, !chatCovered else { return }
            editing.cancel()
            BottoHaptics.shared.play(.surface)
        }
        withAnimation(drawerAnimation) {
            drawerOpen = open
            drawerDrag = 0
        }
    }

    private func closeDrawerImmediately() {
        drawerOpen = false
        drawerDrag = 0
    }

    private func openDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard value.translation.width > 0, abs(value.translation.width) > abs(value.translation.height) else { return }
                if drawerDrag == 0 { editing.cancel() }
                drawerDrag = min(width, value.translation.width)
            }
            .onEnded { value in
                let open = value.predictedEndTranslation.width > width * 0.4 || value.translation.width > width * 0.5
                if open { setDrawer(open: true) } else { withAnimation(drawerAnimation) { drawerDrag = 0 } }
            }
    }

    private func closeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { value in
                guard drawerOpen, value.translation.width < 0,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                drawerDrag = max(-width, value.translation.width)
            }
            .onEnded { value in
                guard drawerOpen else { return }
                let close = value.predictedEndTranslation.width < -width * 0.35 || value.translation.width < -width * 0.5
                setDrawer(open: !close)
            }
    }

    // MARK: Navigation

    private struct LaunchKey: Equatable {
        let channels: Int
        let hasMain: Bool
        let link: AppStore.Link
        let refreshing: Bool
    }

    private var hasMain: Bool { T3ChatShelf.spaces(store.t3Channels).main != nil }

    /// Open a space that needs you or is busy, otherwise the main space. The new-space page only stands in
    /// while a first connection finds the main space, or when the host can't hold one yet.
    private func decideLaunch() async {
        guard !launched else { return }
        // Saved spaces open right away; saves from before main spaces wait for the host to name one.
        let settled = store.isConnected && !store.isRefreshing
        guard hasMain || settled || (store.link == .offline && !store.t3Channels.isEmpty) else { return }
        launched = true
        guard let initial = T3ChatShelf.initialSpace(store.t3Channels) else {
            showsFresh = true
            return
        }
        if store.selectedT3ChannelID == initial.id, store.selectedBot != nil {
            showsFresh = false
        } else if await store.openT3Channel(initial) {
            showsFresh = false
        }
    }

    private func open(_ channel: T3ChannelSummary) {
        guard openingChat == nil else { return }
        if store.selectedT3ChannelID == channel.id, store.selectedBot != nil {
            showsFresh = false
            presentation.didChooseConversation()
            setDrawer(open: false)
            return
        }
        let scope = store.configuration?.id
        openingChat = channel.id
        openingError = nil
        Task {
            let opened = await store.openT3Channel(channel)
            guard store.configuration?.id == scope, openingChat == channel.id else { return }
            openingChat = nil
            if opened {
                showsFresh = false
                presentation.didChooseConversation()
                setDrawer(open: false)
            } else {
                openingError = store.isConnected
                    ? String(localized: "That space didn’t open. Try again.")
                    : String(localized: "Connect to open this space.")
            }
        }
    }

    /// Lets Botto's sheet finish dismissing before another presentation or the conversation takes over.
    private func afterSheet(_ action: @MainActor () -> Void) async {
        try? await Task.sleep(for: .milliseconds(350))
        guard !showsBotto else { return }
        action()
    }

    private func startFresh() {
        editing.cancel()
        showsFresh = true
        setDrawer(open: false)
    }

    private func presentBotto() {
        guard !rootCovered else { return }
        editing.cancel()
        closeDrawerImmediately()
        showsBotto = true
    }

    private func openFile(_ output: T3OutputFile) {
        editing.cancel()
        openedOutput = output
    }

    private func openSettings() {
        closeDrawerImmediately()
        onSettings()
    }

    // MARK: Files from a space

    private var artifactBinding: Binding<Bool> {
        Binding(get: { presentation.artifact != nil }, set: { shown in
            guard !shown, let session = presentation.artifact else { return }
            presentation.closeArtifact(id: session.id)
        })
    }

    @ViewBuilder private var artifactReader: some View {
        if let session = presentation.artifact {
            let revision = presentation.revision
            let active = scenePhase == .active && !rootCovered
            ArtifactPreview(session: session, isExpanded: true, isActive: active, holdsOutput: scenePhase != .background,
                onClose: {
                    guard presentation.acceptsArtifactCallback(id: session.id, revision: revision) else { return }
                    presentation.closeArtifact(id: session.id)
                }, onRetry: {
                    presentation.retryArtifact(id: session.id, revision: revision, canPresent: { active })
                }, canPresentOutput: {
                    active && presentation.acceptsArtifactCallback(id: session.id, revision: revision)
                }, connectionFeedback: session.requiresConnection && !store.isConnected
                    ? AnyView(ConnectionStatusView(store: store)) : nil,
                pages: session.page.map { page in
                    ArtifactPages(index: page.index, count: page.count, session: presentation.artifactSession(atPage:)) { step in
                        guard active, presentation.acceptsArtifactCallback(id: session.id, revision: revision) else { return false }
                        return presentation.moveArtifact(by: step, id: session.id, store: store)
                    }
                })
                .id(session.readerID)
                .background(BottoTheme.paper)
                .interactiveDismissDisabled(session.isPresentingOutput)
                .presentationDetents([.large])
        }
    }
}
