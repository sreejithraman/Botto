import SwiftUI
import BottoCore

/// One native navigation owner and two fixed content slots. No geometry event
/// creates a presenter, opens a conversation, or changes the retained task.
struct AdaptiveWorkspace: View {
    @Bindable var store: AppStore
    let presentation: WorkspacePresentation
    let rootCovered: Bool
    let onSettings: () -> Void
    let onNewBot: () -> Void
    var body: some View {
        let workspace = store.chats
        let selected = store.selectedBot.map(WorkspaceChatInput.init)
        let owner = store.selectedBotID.flatMap { id in
            (try? ExactID(id)).flatMap { workspace.selection(profile: $0)?.owner }
        }
        WorkspaceShell(store: store, presentation: presentation, selected: selected, selectedOwner: owner,
            rootCovered: rootCovered, onSettings: onSettings, onNewBot: onNewBot)
    }
}

private struct WorkspaceChatInput: Equatable {
    let profile: BotProfile
    static func == (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.profile, b = rhs.profile
        func bytes(_ value: String?) -> Data? { value.map { Data($0.utf8) } }
        func appearance(_ value: BotAppearance?) -> [Data?]? {
            value.map { [bytes($0.rawShape), bytes($0.color), bytes($0.imageKind), bytes($0.expression)] }
        }
        return bytes(a.id) == bytes(b.id) && bytes(a.name) == bytes(b.name)
            && bytes(a.emoji) == bytes(b.emoji) && bytes(a.description) == bytes(b.description)
            && bytes(a.model) == bytes(b.model) && a.status == b.status && a.isPinned == b.isPinned
            && appearance(a.appearance) == appearance(b.appearance) && a.appearance?.custom == b.appearance?.custom
            && a.hasAvatar == b.hasAvatar && a.lookRevision == b.lookRevision
    }
}

private struct WorkspaceShell: View {
    let store: AppStore
    let presentation: WorkspacePresentation
    let selected: WorkspaceChatInput?
    let selectedOwner: PresentationOwner?
    let rootCovered: Bool
    let onSettings: () -> Void
    let onNewBot: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var chatCovered = false
    @State private var nativeDetail = WorkspaceNativeDetailState()
    @State private var editing = ComposerEditingHandle()
    @State private var observedLayout = WorkspaceLayout(compact: true, accessibilityText: false, workspaceWidth: 0)
    @State private var nativeCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var nativeNavigationRevision: UUID?
    @State private var nativeVisibility: NavigationSplitViewVisibility = .all

    private var showsFile: Bool { presentation.artifact != nil && !presentation.isBrowsingBots }
    private var showsBrowseBots: Bool {
        selected != nil && !presentation.isBrowsingBots && (!observedLayout.compact || showsFile)
    }
    private var allocation: WorkspacePaneAllocation { allocation(for: observedLayout) }
    private func allocation(for layout: WorkspaceLayout) -> WorkspacePaneAllocation {
        layout.allocation(hasArtifact: presentation.artifact != nil, browsingBots: presentation.isBrowsingBots,
                          expanded: presentation.isArtifactExpanded)
    }
    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { nativeVisibility }, set: { value in
            // Accept the native projection first. Reconciliation then emits a
            // real all -> detailOnly change after automatic sidebar expansion.
            // A constant getter cannot communicate that correction to UIKit.
            hideNativeReadEvidence()
            nativeDetail.requestRefresh(projection: value)
            nativeVisibility = value
        })
    }
    private var compactColumn: Binding<NavigationSplitViewColumn> {
        let renderedLayout = observedLayout
        let revision = presentation.revision
        let workspace = store.chats
        let owner = selectedOwner
        return Binding(get: {
            if presentation.isBrowsingBots || selected == nil { return .sidebar }
            if showsFile { return .detail }
            return nativeCompactColumn
        }, set: { value in
            // Ordinary native Back/edge-pop remains available for chat-only.
            // A foreground file has explicit Close/Bots; native fold feedback
            // cannot park or retire its reader.
            let accepted = sizeClass == .compact && observedLayout.compact && observedLayout == renderedLayout &&
                presentation.revision == revision && presentation.artifact == nil
            guard accepted else { return }
            nativeCompactColumn = value
            if value == .sidebar, store.selectedBot != nil {
                if let owner { workspace.setTranscriptVisible(false, owner: owner) }
                presentation.browseBots()
                nativeNavigationRevision = presentation.revision
            } else if value == .detail && presentation.isBrowsingBots {
                presentation.resumeTask()
                nativeNavigationRevision = presentation.revision
                nativeVisibility = .detailOnly
            }
        })
    }
    private var currentCompactColumn: NavigationSplitViewColumn {
        if presentation.isBrowsingBots || store.selectedBot == nil { return .sidebar }
        if showsFile { return .detail }
        return nativeCompactColumn
    }
    private var outputCovered: Bool { presentation.artifact?.isPresentingOutput == true }
    private var chatActionsAvailable: Bool {
        nativeDetail.inputVisible && allocation.chatVisible && !(observedLayout.compact && currentCompactColumn == .sidebar)
            && !rootCovered && !chatCovered && !outputCovered && scenePhase == .active
    }
    private var chatEditingAvailable: Bool {
        nativeDetail.inputVisible && observedLayout.editorExposed(browsingBots: presentation.isBrowsingBots,
            hasArtifact: presentation.artifact != nil, expanded: presentation.isArtifactExpanded,
            rootCovered: rootCovered || outputCovered, localCovered: chatCovered, sceneActive: scenePhase == .active,
            compactShowsSidebar: currentCompactColumn == .sidebar)
    }
    private func chatEditingExposed(in layout: WorkspaceLayout) -> Bool {
        layout.editorExposed(browsingBots: presentation.isBrowsingBots, hasArtifact: presentation.artifact != nil,
            expanded: presentation.isArtifactExpanded, rootCovered: rootCovered || outputCovered,
            localCovered: chatCovered, sceneActive: scenePhase == .active,
            compactShowsSidebar: compactColumn.wrappedValue == .sidebar)
    }
    private var artifactActionsAvailable: Bool {
        nativeDetail.readable && showsFile && allocation.artifactVisible && !rootCovered && !chatCovered && scenePhase == .active
    }
    private func chatExposed(in layout: WorkspaceLayout) -> Bool {
        layout.transcriptExposed(browsingBots: presentation.isBrowsingBots, hasArtifact: presentation.artifact != nil,
            expanded: presentation.isArtifactExpanded, rootCovered: rootCovered || outputCovered,
            localCovered: chatCovered, sceneActive: scenePhase == .active,
            compactShowsSidebar: compactColumn.wrappedValue == .sidebar)
    }
    private var title: String {
        if allocation.artifactVisible && !allocation.chatVisible { return "File" }
        return selected?.profile.name ?? ""
    }
    var body: some View {
        NavigationSplitView(columnVisibility: visibility, preferredCompactColumn: compactColumn) {
            InboxView(store: store, onSettings: onSettings, onNewBot: onNewBot,
                onOpened: { editing.cancel(); presentation.didChooseConversation() },
                isExposed: !rootCovered && (presentation.isBrowsingBots || selected == nil ||
                    (!observedLayout.compact && nativeVisibility != .detailOnly && !showsFile)))
                .navigationSplitViewColumnWidth(min: 310, ideal: 350, max: 420)
                .bottoNavigationChrome()
                .toolbar(removing: showsBrowseBots ? .sidebarToggle : nil)
        } detail: {
            NavigationStack {
                GeometryReader { geometry in
                    let layout = WorkspaceLayout(compact: sizeClass == .compact,
                        accessibilityText: dynamicTypeSize.isAccessibilitySize, workspaceWidth: geometry.size.width)
                    let panes = allocation(for: layout)
                    let chatSemanticallyVisible = (presentation.artifact == nil && !presentation.isBrowsingBots) ||
                        (panes.chatVisible && geometry.size.height > 0 && !(layout.compact && presentation.isBrowsingBots))
                    HStack(spacing: 0) {
                        RetainedWorkspacePane(width: panes.chatWidth, height: geometry.size.height,
                                              initialWidth: WorkspaceLayout.minimumChatWidth,
                                              allowsTopOverflow: true, isSemanticallyVisible: chatSemanticallyVisible) {
                            if let bot = selected?.profile {
                                ChatView(store: store, bot: bot, presentation: presentation,
                                    isExposed: chatExposed(in: layout), isEditingExposed: chatEditingExposed(in: layout), rootCovered: rootCovered || outputCovered,
                                    onLocalModalPresentation: { [renderedBotID = bot.id] covered in
                                        guard store.selectedBotID == renderedBotID else { return }
                                        chatCovered = covered
                                    }, toolbarVisible: panes.chatVisible && !(layout.compact && presentation.isBrowsingBots),
                                    canPresentToolbar: { chatActionsAvailable }, canContinueEditing: { chatEditingAvailable })
                                    .id(bot.id)
                            } else { emptyDetail }
                        }
                        Rectangle().fill(.separator).frame(width: panes.paired ? 1 : 0)
                            .accessibilityHidden(true)
                        RetainedWorkspacePane(width: panes.artifactWidth, height: geometry.size.height,
                                              initialWidth: WorkspaceLayout.minimumFileWidth,
                                              isSemanticallyVisible: panes.artifactVisible && geometry.size.height > 0) {
                            if let session = presentation.artifact {
                                artifactReader(session, active: nativeDetail.readable && panes.artifactVisible && !rootCovered && !chatCovered && scenePhase == .active)
                                    .id(session.id)
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                    .modifier(WorkspaceLayoutObservation { observedLayout = $0 })
                }
                .background(WorkspaceNativeDetailObservation(state: nativeDetail, projection: nativeVisibility,
                    layout: observedLayout, onUnavailable: { [weak store] in
                        guard let store, let id = store.selectedBotID, let profile = try? ExactID(id),
                              let owner = store.chats.screen(profile: profile)?.owner else { return }
                        store.chats.setTranscriptVisible(false, owner: owner)
                    }).allowsHitTesting(false).accessibilityHidden(true))
                .environment(\.workspaceNativeDetail, nativeDetail)
                .environment(\.composerEditing, editing)
                .bottoNavigationChrome()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden(showsFile)
                .toolbar {
                    if showsBrowseBots {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Bots", systemImage: "sidebar.left") {
                                guard !rootCovered, !chatCovered, !outputCovered else { return }
                                editing.cancel()
                                presentation.browseBots()
                            }
                            .accessibilityIdentifier("workspace-browse-bots")
                            .disabled(outputCovered)
                        }
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: scenePhase) { _, phase in if phase != .active { editing.cancel() } }
        .onChange(of: rootCovered) { _, covered in if covered { editing.cancel() } }
        .onChange(of: outputCovered) { _, covered in if covered { editing.cancel() } }
        .onChange(of: nativeDetail.inputVisible) { _, visible in if !visible { editing.cancel() } }
        .onChange(of: nativeVisibility) { _, _ in reconcileVisibility() }
        .onAppear { reconcileVisibility() }
        .onChange(of: presentation.revision) { _, revision in
            if nativeNavigationRevision != revision { editing.cancel() }
            nativeNavigationRevision = nil
            nativeCompactColumn = presentation.isBrowsingBots || store.selectedBot == nil ? .sidebar : .detail
            reconcileVisibility()
        }
        .onChange(of: store.selectedBotID) { _, _ in
            editing.cancel()
            chatCovered = false
            nativeCompactColumn = store.selectedBot == nil ? .sidebar : .detail
            presentation.selectedBotChanged(store: store)
        }
    }

    private func hideNativeReadEvidence() {
        guard let id = store.selectedBotID, let profile = try? ExactID(id),
              let owner = store.chats.screen(profile: profile)?.owner else { return }
        store.chats.setTranscriptVisible(false, owner: owner)
    }

    private func reconcileVisibility() {
        if store.selectedBot == nil || presentation.isBrowsingBots {
            if nativeVisibility != .all { nativeVisibility = .all }
        } else if showsFile, nativeVisibility != .detailOnly {
            nativeVisibility = .detailOnly
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 18) {
            if store.isDemo { DemoBanner() }
            BottoMark(size: 56)
            Text("A little help, a message away.").font(.title2.weight(.semibold))
            Text("Choose a bot to pick up the chat.").foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center).padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(BottoTheme.paper)
    }

    private func artifactReader(_ session: ArtifactPreviewSession, active: Bool) -> some View {
        let revision = presentation.revision
        return ArtifactPreview(session: session, isExpanded: presentation.isArtifactExpanded, isActive: active,
            onClose: {
                guard artifactActionsAvailable, presentation.acceptsArtifactCallback(id: session.id, revision: revision) else { return }
                presentation.closeArtifact(id: session.id)
            }, onToggleExpanded: {
                guard artifactActionsAvailable, presentation.acceptsArtifactCallback(id: session.id, revision: revision) else { return }
                presentation.setArtifactExpanded(!presentation.isArtifactExpanded, id: session.id)
            }, onRetry: {
                presentation.retryArtifact(id: session.id, revision: revision, canPresent: { artifactActionsAvailable })
            }, canPresentOutput: {
                artifactActionsAvailable && presentation.acceptsArtifactCallback(id: session.id, revision: revision)
            })
    }
}

/// The slot collapses; the retained content keeps its last useful bounds. In
/// particular QL never sees a zero-width layout when parked or covered by chat.
struct RetainedWorkspacePane<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let initialWidth: CGFloat
    var allowsTopOverflow = false
    let isSemanticallyVisible: Bool
    @ViewBuilder let content: () -> Content
    @State private var lastUsefulSize: CGSize?

    var body: some View {
        let hasUsefulBounds = width > 0 && height > 0
        let size = CGSize(width: width, height: height)
        let childSize = hasUsefulBounds ? size : (lastUsefulSize ?? CGSize(width: initialWidth, height: max(1, height)))
        content()
            .frame(width: childSize.width, height: childSize.height)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(WorkspacePaneClip(allowsTopOverflow: allowsTopOverflow))
            .opacity(isSemanticallyVisible ? 1 : 0)
            .allowsHitTesting(isSemanticallyVisible).accessibilityHidden(!isSemanticallyVisible)
            .onChange(of: size, initial: true) { _, size in
                if size.width > 0 && size.height > 0 { lastUsefulSize = size }
            }
    }
}

/// Floating top chrome may escape vertically; neighboring panes and the bottom stay clipped.
private struct WorkspacePaneClip: Shape {
    let allowsTopOverflow: Bool
    func path(in rect: CGRect) -> Path {
        let overflow = allowsTopOverflow ? rect.height : 0
        return Path(CGRect(x: rect.minX, y: rect.minY - overflow,
                           width: rect.width, height: rect.height + overflow))
    }
}

/// Observes the same detail bounds/traits used for allocation so native action
/// callbacks can recheck current exposure. Observation owns no presentation.
struct WorkspaceLayoutObservation: ViewModifier {
    let changed: (WorkspaceLayout) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ changed: @escaping (WorkspaceLayout) -> Void) { self.changed = changed }

    func body(content: Content) -> some View {
        let compact = sizeClass == .compact
        let accessibilityText = dynamicTypeSize.isAccessibilitySize
        return content.onGeometryChange(for: WorkspaceLayout.self) { geometry in
            WorkspaceLayout(compact: compact, accessibilityText: accessibilityText, workspaceWidth: geometry.size.width)
        } action: { changed($0) }
    }
}
