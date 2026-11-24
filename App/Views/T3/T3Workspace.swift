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
    @GestureState private var drawerDrag: CGFloat = 0
    @State private var showsFresh = true
    @State private var showsBotto = false
    @State private var openedOutput: T3OutputFile?
    @State private var chatCovered = false
    @State private var openingChat: String?
    @State private var openingError: String?
    @State private var launched = false
    @State private var pendingBottoDestination: (workspace: ObjectIdentifier, destination: BottoDestination)?

    private enum BottoDestination { case space(T3ChannelSummary), settings }

    private var artifactShown: Bool { presentation.artifact != nil }
    /// Anything above the conversation that should stop its reading, editing and toolbar actions.
    private var conversationCovered: Bool {
        drawerOpen || drawerDrag != 0 || coveredOutsideDrawer
    }
    private var coveredOutsideDrawer: Bool { rootCovered || showsBotto || artifactShown || openedOutput != nil }
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
                // Keep the strip mounted until the drag settles or is cancelled.
                Color.clear.frame(width: 18).contentShape(Rectangle())
                    .gesture(openDrag(width: width))
                    .padding(.top, 110).padding(.bottom, 140)
                    .allowsHitTesting(!drawerOpen && !coveredOutsideDrawer)
                    .accessibilityHidden(true)
            }
        }
        .background(BottoTheme.paper.ignoresSafeArea())
        .sheet(isPresented: $showsBotto, onDismiss: routeFromBotto) {
            BottoPage(store: store, outputs: outputs, onOpenChat: { channel in
                pendingBottoDestination = (ObjectIdentifier(store.chats), .space(channel))
                showsBotto = false
            }, onSettings: {
                pendingBottoDestination = (ObjectIdentifier(store.chats), .settings)
                showsBotto = false
            })
        }
        .sheet(item: $openedOutput) { T3OutputPreview(store: store, output: $0) }
        .sheet(isPresented: artifactBinding) { artifactReader }
        .task(id: launchReady) {
            await decideLaunch()
        }
        .task(id: mayPreload) {
            guard mayPreload else { return }
            await outputs.load(store)
        }
        .task(id: mayPreload) {
            guard mayPreload else { return }
            await store.loadT3ModelsIfNeeded()
        }
        .onChange(of: store.notificationNavigationRevision) { _, _ in
            showConversation()
            closeDrawerImmediately()
        }
        .onChange(of: rootCovered) { _, covered in if covered { editing.cancel() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { editing.cancel() } }
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
                        onOpenChat: open, onStarted: showConversation)
                .safeAreaInset(edge: .top) {
                    if !drawerOpen, let openingError {
                        InlineNotice(message: openingError) { self.openingError = nil }.padding(.horizontal, 20)
                    }
                }
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
        }
    }

    private func closeDrawerImmediately() {
        drawerOpen = false
    }

    private func openDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($drawerDrag) { value, drag, _ in
                guard value.translation.width > 0, abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = min(width, value.translation.width)
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let open = value.predictedEndTranslation.width > width * 0.4 || value.translation.width > width * 0.5
                if open { setDrawer(open: true) }
            }
    }

    private func closeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .updating($drawerDrag) { value, drag, _ in
                guard drawerOpen, value.translation.width < 0,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = max(-width, value.translation.width)
            }
            .onEnded { value in
                guard drawerOpen else { return }
                let close = value.predictedEndTranslation.width < -width * 0.35 || value.translation.width < -width * 0.5
                setDrawer(open: !close)
            }
    }

    // MARK: Navigation

    private var mayPreload: Bool { store.isConnected && !rootCovered }

    private var launchReady: Bool {
        guard !conversationCovered, openingChat == nil, store.primaryT3Bot != nil else { return false }
        return T3ChatShelf.spaces(store.t3Channels).main != nil || (store.isConnected && !store.isRefreshing)
            || (store.link == .offline && !store.t3Channels.isEmpty)
    }

    /// Open a space that needs you or is busy, otherwise the main space. The new-space page only stands in
    /// while a first connection finds the main space, or when the host can't hold one yet.
    private func decideLaunch() async {
        guard !launched, launchReady else { return }
        guard let initial = T3ChatShelf.initialSpace(store.t3Channels) else {
            launched = true
            return
        }
        if await store.openT3Channel(initial), !Task.isCancelled { showConversation() }
        else if !Task.isCancelled { reportOpenFailure() }
    }

    private func open(_ channel: T3ChannelSummary) {
        guard openingChat == nil else { return }
        let workspace = store.chats
        store.t3ComposerRequest = nil
        openingChat = channel.id
        openingError = nil
        Task {
            let opened = await store.openT3Channel(channel)
            guard openingChat == channel.id else { return }
            openingChat = nil
            guard store.chats === workspace else { return }
            if opened {
                showConversation()
                setDrawer(open: false)
            } else {
                reportOpenFailure()
            }
        }
    }

    private func showConversation() {
        launched = true
        showsFresh = false
        openingError = nil
        presentation.didChooseConversation()
    }

    private func reportOpenFailure() {
        openingError = store.isConnected ? String(localized: "That space didn’t open. Try again.")
            : String(localized: "Connect to open this space.")
    }

    private func routeFromBotto() {
        guard let pending = pendingBottoDestination else { return }
        pendingBottoDestination = nil
        guard pending.workspace == ObjectIdentifier(store.chats), !rootCovered else { return }
        switch pending.destination {
        case .space(let channel): open(channel)
        case .settings: onSettings()
        }
    }

    private func startFresh() {
        editing.cancel()
        store.t3ComposerRequest = nil
        launched = true
        openingError = nil
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
