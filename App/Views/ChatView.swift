import SwiftUI
import UIKit
import BottoCore

struct ChatView: View {
    @Bindable var store: AppStore
    let bot: BotProfile
    let presentation: WorkspacePresentation
    let isExposed: Bool
    let isEditingExposed: Bool
    let rootCovered: Bool
    let onLocalModalPresentation: (Bool) -> Void
    var toolbarVisible = true
    var canPresentToolbar: () -> Bool = { true }
    var canContinueEditing: () -> Bool = { true }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspaceNativeDetail) private var nativeDetail
    @Environment(\.composerEditing) private var providedEditing
    @State private var localEditing = ComposerEditingHandle()
    private var editing: ComposerEditingHandle { providedEditing ?? localEditing }
    @State private var connectionRequested = false
    @State private var tabPreviews = ChatTabPreviews()
    @State private var transcriptPreview = NativeTranscriptPreview()
    @State private var composerHeight: CGFloat = 0
    @State private var headerOverlap: CGFloat = 44
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsProfile = false
    @State private var profileDestination: AppStore.AvatarDestination?
    @State private var showsOverview = false
    @State private var overviewCovered = false
    @State private var overviewTransition = ChatOverviewTransition()
    @State private var overviewSelectionID: ChatID?
    @State private var overviewCreationSource: ChatID?
    @State private var recentlyClosedChat: ChatID?
    @State private var profileEditor: AppStore.AvatarDestination?
    @State private var showsAttachmentPicker = false
    @State private var childModals: Set<UUID> = []
    @State private var importPresentationRevision = UUID()

    private var workspace: ConversationWorkspace { store.chats }
    private var screen: ChatScreen? {
        guard let profile = try? ExactID(bot.id) else { return nil }
        return workspace.screen(profile: profile)
    }
    private var owner: PresentationOwner? {
        guard let profile = try? ExactID(bot.id) else { return nil }
        return workspace.selection(profile: profile)?.owner
    }
    private var chatUncoveredByPresentation: Bool {
        !showsProfile && !overviewCovered && !showsAttachmentPicker && childModals.isEmpty && !rootCovered &&
            !store.showsConnection && scenePhase == .active
    }
    private var transcriptVisible: Bool { isExposed && chatUncoveredByPresentation && (nativeDetail?.readable ?? true) }
    private var inputAvailable: Bool {
        isEditingExposed && chatUncoveredByPresentation && (nativeDetail?.inputVisible ?? true) && !presentation.isBrowsingBots
    }

    private var localModalPresented: Bool {
        showsProfile || showsAttachmentPicker || !childModals.isEmpty
    }

    var body: some View {
        readerLifecycle
        .onChange(of: store.showsConnection) { _, shown in
            if shown { showsProfile = false; dismissOverviewImmediately(); discardPreviews() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                dismissOverviewImmediately()
                discardPreviews()
                importPresentationRevision = UUID()
            }
        }
        .onChange(of: rootCovered) { _, covered in
            if covered { coverTranscript(); dismissOverviewImmediately(); importPresentationRevision = UUID() }
        }
        .onChange(of: presentation.revision) { _, _ in importPresentationRevision = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            dismissOverviewImmediately()
            discardPreviews()
        }
        .onDisappear {
            dismissOverviewImmediately()
            transcriptPreview.didCapture = nil
            transcriptPreview.invalidate()
            hiddenTranscript()()
        }
    }

    private var presentationContent: some View {
        let screen = self.screen
        let toolbarRevision = presentation.revision
        let toolbarOwner = screen?.owner
        let editingRevision = presentation.revision
        return chatPane(screen, toolbarRevision: toolbarRevision, toolbarOwner: toolbarOwner, editingRevision: editingRevision)
        .onChange(of: colorScheme) { _, _ in if overviewCovered { overviewTransition.allowsAnimation = false } }
        .onChange(of: textSize) { _, _ in if overviewCovered { overviewTransition.allowsAnimation = false } }
        .onChange(of: store.isConnected) { _, _ in connectionRequested = false }
        .onChange(of: screen?.selectedChatID) { _, selected in
            if let selected, overviewSelectionID == selected ||
                (overviewCreationSource != nil && overviewCreationSource != selected) {
                if !showsProfile { closeOverview() }
            }
            connectionRequested = false
        }
        .onChange(of: ObjectIdentifier(workspace)) { _, _ in
            editing.cancel()
            discardPreviews()
            configurePreviewCapture()
            showsProfile = false; dismissOverviewImmediately(); childModals = []
            connectionRequested = false
        }
        .sheet(isPresented: $showsProfile) {
            if let profileDestination { profileSheet(profileDestination, workspace: workspace) }
        }
        .task(id: screen?.isOpening == false ? screen?.owner : nil) {
            let workspace = workspace
            guard let screen, !screen.isOpening else { return }
            let owner = screen.owner
            await workspace.refreshDirectory(owner)
        }
    }

    private var readerLifecycle: some View {
        let screen = self.screen
        return presentationContent
        .onChange(of: localModalPresented, initial: true) { _, shown in onLocalModalPresentation(shown) }
        .onAppear { configurePreviewCapture(); markDisplayed() }
        .onChange(of: screen?.snapshot) { _, _ in markDisplayed() }
        .onChange(of: screen?.isOpening) { _, _ in markDisplayed() }
        .onChange(of: screen?.isLoadingDirectory) { _, loading in
            if loading == false { markDisplayed() }
        }
        .onChange(of: transcriptVisible) { _, _ in markDisplayed() }
        .onChange(of: screen?.owner.epoch) { _, _ in
            markDisplayed()
        }
        .onChange(of: screen?.selectedViewLifetime) { _, _ in
            editing.cancel()
            childModals = []
        }
        .onChange(of: profileDestination.map { $0.isCurrent(in: store) }) { _, current in
            if current == false { showsProfile = false }
        }
        .onChange(of: showsProfile) { _, shown in
            if !shown { profileEditor = nil; profileDestination = nil }
        }
    }

    private func chatPane(_ screen: ChatScreen?, toolbarRevision: UUID, toolbarOwner: PresentationOwner?,
                          editingRevision: UUID) -> some View {
        ZStack(alignment: .bottom) {
            ChatTranscript(store: store, bot: bot, workspace: workspace, screen: screen,
                           messageDisplayRevision: (screen?.snapshot?.messages ?? []).map { .message($0, working: false) }, isExposed: transcriptVisible,
                           onOpenArtifact: { presentation.openArtifact($0, store: store) },
                           onConnectionRequired: { connectionRequested = true },
                           preview: transcriptPreview, topContentInset: toolbarVisible ? headerOverlap : 0,
                           bottomContentInset: composerHeight,
                           actionRevision: toolbarRevision, admitsAction: {
                               presentation.revision == toolbarRevision && !presentation.isBrowsingBots && transcriptVisible && canPresentToolbar()
                           })
                // Keep the reader's position across access refreshes in this chat.
                .id(screen?.selectedChatID)
                .ignoresSafeArea(.container, edges: .top)
                .accessibilityHidden(overviewCovered)
            if toolbarVisible {
                VStack(spacing: 0) {
                    BottoTheme.paper.frame(height: headerOverlap)
                    LinearGradient(colors: [BottoTheme.paper, BottoTheme.paper.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            overviewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(overviewCovered)
            VStack(spacing: 10) {
                if store.isDemo { DemoBanner() }
                if connectionRequested && !store.isConnected {
                    ConnectionStatusView(store: store).padding(.horizontal, 16)
                }
                if let notice = store.notice {
                    InlineNotice(message: notice) { store.notice = nil }.padding(.horizontal, 16)
                }
                if let error = screen?.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                }
                // Its structural identity stays attached to the bot, preserving editor focus.
                ChatComposer(store: store, bot: bot, workspace: workspace, screen: screen,
                             inputAvailable: inputAvailable,
                             importsAllowed: !showsProfile && !overviewCovered && childModals.isEmpty && !rootCovered && !presentation.isBrowsingBots && scenePhase != .background,
                             importPresentationRevision: importPresentationRevision,
                             editingRevision: editingRevision,
                             onPickerPresentation: { shown in
                                 if shown { coverTranscript() }
                                 showsAttachmentPicker = shown
                             }, canContinueEditing: {
                                 let sameRevision = presentation.revision == editingRevision
                                 let exposed = inputAvailable
                                 let available = canContinueEditing()
                                 return sameRevision && !presentation.isBrowsingBots && exposed && available
                             }, editingHandle: editing, connectionRequested: $connectionRequested)
            }
            .padding(.top, 8)
            .opacity(showsOverview ? 0 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0.10 : 0.16), value: showsOverview)
            .allowsHitTesting(!overviewCovered)
            .accessibilityHidden(overviewCovered)
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { composerHeight = $0 }
        }
        .background(BottoTheme.paper)
        .overlay(alignment: .top) {
            if toolbarVisible {
                NativeTranscriptHeader(preview: transcriptPreview, onActivate: screen == nil ? nil : {
                    presentProfile(revision: toolbarRevision, owner: toolbarOwner)
                }) {
                    profileButton(screen, revision: toolbarRevision, owner: toolbarOwner)
                }
                .onGeometryChange(for: CGFloat.self) { max(0, $0.size.height - headerReferenceHeight) } action: { headerOverlap = $0 }
                .offset(y: -headerReferenceHeight)
            }
        }
        .environment(\.reportChatModal, modalReporter())
        .environment(\.composerEditing, editing)
        .toolbar {
            if toolbarVisible {
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .principal) {
                        Color.clear.frame(width: 72, height: 44).accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) {
                        Color.clear.frame(width: 72, height: 44).accessibilityHidden(true)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    chatsButton(screen, revision: toolbarRevision, owner: toolbarOwner)
                }
            }
        }
    }

    private var overviewPane: some View {
        ChatOverviewContainer(isPresented: showsOverview, transition: overviewTransition,
                              onDismiss: { overviewCovered = false; showsOverview = false }) {
            if let screen, let profile = try? ExactID(bot.id) {
                ChatPickerCards(workspace: workspace, profile: profile) { cards in
                    picker(screen, cards: cards, workspace: workspace)
                }
                .environment(\.colorScheme, colorScheme)
                .dynamicTypeSize(textSize)
            }
        }
    }

    private func mayPresent(revision: UUID, owner: PresentationOwner?) -> Bool {
        guard canPresentToolbar(), presentation.revision == revision,
              store.selectedBotID?.utf8.elementsEqual(bot.id.utf8) == true,
              let owner, workspace.isCurrent(owner), !localModalPresented else { return false }
        return true
    }

    private func presentProfile(revision: UUID, owner: PresentationOwner?) {
        guard mayPresent(revision: revision, owner: owner),
              let destination = store.avatarDestination(for: bot) else { return }
        coverTranscript()
        importPresentationRevision = UUID()
        profileDestination = destination
        overviewSelectionID = nil; overviewCreationSource = nil
        showsProfile = true
    }

    private func presentOverview(revision: UUID, owner: PresentationOwner?) {
        guard mayPresent(revision: revision, owner: owner) else { return }
        overviewTransition.prepareOpening(id: screen?.selectedChatID.value.uuidString)
        overviewTransition.selectedID = screen?.selectedChatID.value.uuidString
        overviewTransition.allowsAnimation = true
        coverTranscript()
        importPresentationRevision = UUID()
        overviewCovered = true
        showsOverview = true
        BottoHaptics.shared.play(.surface)
    }

    private func closeOverview() {
        if let owner, let intent = workspace.captureActivation(owner) {
            Task { await workspace.select(intent) }
        }
        overviewSelectionID = nil; overviewCreationSource = nil
        overviewTransition.selectedID = screen?.selectedChatID.value.uuidString
        showsOverview = false
    }

    private func dismissOverviewImmediately() {
        overviewSelectionID = nil; overviewCreationSource = nil
        overviewTransition.allowsAnimation = false
        showsOverview = false
        overviewTransition.finishImmediately()
    }

    private var headerReferenceHeight: CGFloat {
        BotAvatarLayout(shape: .circle, size: 56).fittedHeight
    }

    private var shortAvatarHeaderLift: CGFloat {
        let layout = BotAvatarLayout(shape: bot.face.shape, size: 56, imageSize: store.avatar(for: bot)?.size)
        return max(0, headerReferenceHeight - layout.fittedHeight)
    }

    private var profileNameLabel: some View {
        Text(bot.name).font(.headline).lineLimit(1)
            .padding(.horizontal, 18).frame(minHeight: 44)
    }

    private func profileButton(_ screen: ChatScreen?, revision: UUID, owner: PresentationOwner?) -> some View {
        Button { presentProfile(revision: revision, owner: owner) } label: {
            VStack(spacing: -8) {
                AppBotAvatar(store: store, bot: bot, scope: .selectedChat, size: 56, fitsBody: true)
                    .zIndex(1)
                let label = profileNameLabel.foregroundStyle(BottoTheme.ink)
                if #available(iOS 26, *) {
                    label.glassEffect(.regular.interactive(), in: .capsule)
                        .padding(.bottom, 8 + shortAvatarHeaderLift)
                } else {
                    label.background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8 + shortAvatarHeaderLift)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile for \(bot.name)")
        .accessibilityValue(store.avatarPresentation(for: bot, scope: .selectedChat).accessibilityStatus ?? "")
        .accessibilityHint("View bot details or edit the profile.")
        .accessibilityIdentifier("bot-profile-button")
        .disabled(screen == nil)
    }

    private func configurePreviewCapture() {
        let store = store, workspace = workspace, cache = tabPreviews
        let editing = editing
        guard let profile = try? ExactID(bot.id) else { return }
        overviewTransition.viewportProvider = { [weak preview = transcriptPreview] id in preview?.viewportView(for: id) }
        transcriptPreview.viewportDidChange = { [weak transition = overviewTransition] in transition?.viewportDidChange?() }
        transcriptPreview.canCapture = { [weak editing] in editing?.editor?.isFirstResponder != true }
        transcriptPreview.didCapture = { owner, image, appearance, textSize in
            guard store.chats === workspace, workspace.isCurrent(owner),
                  workspace.screen(profile: profile)?.owner == owner else { return }
            cache.capture(image, id: owner.chat.value.uuidString, colorScheme: appearance, textSize: textSize)
        }
    }

    private func discardPreviews() {
        transcriptPreview.invalidate()
        tabPreviews.removeAll()
    }

    private func pickerItem(_ card: ChatCard, selected: ChatID, canClose: Bool = false) -> ChatPickerItem {
        ChatPickerItem(id: card.id.value.uuidString, title: card.title,
                       userPreview: card.userPreview, replyPreview: card.replyPreview,
                       isMain: card.isMain, isSelected: card.id == selected,
                       isPreferred: card.isPreferred, isUnread: card.unread,
                       isAvailable: card.isAvailable, canClose: canClose, activity: card.activity)
    }

    private func chatsButton(_ screen: ChatScreen?, revision: UUID, owner: PresentationOwner?) -> some View {
        Button {
            if overviewCovered { closeOverview() }
            else { presentOverview(revision: revision, owner: owner) }
        } label: {
            Image(systemName: "rectangle.on.rectangle")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chats with \(bot.name)")
        .accessibilityValue(screen?.title ?? "Main")
        .accessibilityHint(overviewCovered ? "Return to the current chat." : "Choose a chat or start a new one.")
        .keyboardShortcut(overviewCovered && !localModalPresented ? KeyboardShortcut(.escape, modifiers: []) : nil)
        .accessibilityIdentifier("chat-picker-button")
        .disabled(screen == nil)
    }

    private func profileSheet(_ destination: AppStore.AvatarDestination, workspace: ConversationWorkspace) -> some View {
        let revision = presentation.revision
        return NavigationStack {
            ScrollView {
                BotProfileView(store: store, bot: bot, isCurrent: {
                    showsProfile && !presentation.isBrowsingBots && store.chats === workspace &&
                        destination.isCurrent(in: store) && presentation.revision == revision &&
                        store.selectedBotID?.utf8.elementsEqual(bot.id.utf8) == true &&
                        !rootCovered && !store.showsConnection && scenePhase == .active
                }, editor: $profileEditor)
                .padding(20)
            }
            .accessibilityIdentifier("bot-details-scroll")
            .background(BottoTheme.paper)
            .bottoNavigationChrome()
            .navigationTitle(bot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close profile", systemImage: "xmark") { showsProfile = false }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("bot-profile-done")
                }
            }
        }
        .tint(BottoTheme.action)
        .hapticSheet()
    }

    private func modalReporter() -> @MainActor (UUID, Bool) -> Void {
        let workspace = workspace
        let owner = owner
        let editing = editing
        return { id, shown in
            if shown {
                editing.cancel()
                guard let owner, workspace.isCurrent(owner) else { return }
                workspace.setTranscriptVisible(false, owner: owner)
                childModals.insert(id)
                importPresentationRevision = UUID()
            } else { childModals.remove(id) }
        }
    }

    private func coverTranscript() {
        editing.cancel()
        guard let screen else { return }
        workspace.setTranscriptVisible(false, owner: screen.owner)
    }

    private func hiddenTranscript() -> () -> Void {
        let workspace = workspace
        let owner = owner
        return {
            guard let owner else { return }
            workspace.setTranscriptVisible(false, owner: owner)
        }
    }

    private func markDisplayed() {
        guard let owner else { return }
        workspace.setTranscriptVisible(transcriptVisible, owner: owner)
    }

    private func picker(_ screen: ChatScreen, cards: [ChatCard], workspace: ConversationWorkspace) -> some View {
        let owner = screen.owner
        // Main is pinned; the workspace's stable sibling order is otherwise preserved.
        let cards = cards.filter(\.isMain) + cards.filter { !$0.isMain }
        let closed = (try? ExactID(bot.id)).map { workspace.closedChats(profile: $0) } ?? []
        return ChatPickerView(bot: bot, items: cards.map {
            pickerItem($0, selected: owner.chat, canClose: workspace.captureClose($0.id, owner: owner) != nil)
        },
                              previews: tabPreviews, transition: overviewTransition, onDone: closeOverview, headerClearance: headerOverlap + 12, isLoading: screen.isLoadingDirectory, isConnected: store.isConnected, isCreating: screen.isCreating,
           canCreate: screen.canCreate || (!store.isConnected && screen.canEditDraft), error: screen.error,
           connectionFeedback: ConnectionStatusView(store: store),
           onSelect: { id in
               guard let card = cards.first(where: { $0.id.value.uuidString == id }), card.isAvailable else { return }
               overviewTransition.selectedID = id
               if card.id == screen.selectedChatID { closeOverview(); return }
               guard let intent = workspace.captureSelection(card.id, owner: owner) else { return }
               overviewSelectionID = card.id
               BottoHaptics.shared.play(.selection)
               Task {
                   await workspace.select(intent)
                   if self.screen?.selectedChatID != card.id, overviewSelectionID == card.id { overviewSelectionID = nil }
               }
           }, onCreate: {
               guard let intent = workspace.captureCreation(owner) else { return }
               overviewCreationSource = owner.chat
               Task {
                   await workspace.create(intent)
                   if self.screen?.selectedChatID == owner.chat { overviewCreationSource = nil }
               }
           }, onSetPreferred: { id in
               let chat = id.flatMap { value in cards.first { $0.id.value.uuidString == value }?.id }
               guard id == nil || chat != nil else { return }
               workspace.preferOpening(chat, owner: owner)
           }, onRefresh: {
               guard workspace.isCurrent(owner) else { return }
               Task { await workspace.refreshDirectory(owner) }
           }, closedItems: closed.map { ChatPickerItem(id: $0.id.value.uuidString, title: $0.title) },
           recentlyClosedID: recentlyClosedChat?.value.uuidString,
           onClose: { id in
               guard overviewCovered, !showsProfile,
                     let card = cards.first(where: { $0.id.value.uuidString == id }),
                     let intent = workspace.captureClose(card.id, owner: owner) else { return }
               if card.id == owner.chat { overviewSelectionID = nil; overviewCreationSource = nil }
               if let closed = workspace.close(intent) { recentlyClosedChat = closed.id }
           }, onReopen: { id in
               guard overviewCovered, !showsProfile,
                     let chat = closed.first(where: { $0.id.value.uuidString == id }),
                     let intent = workspace.captureReopening(chat.id, owner: owner) else { return }
               workspace.reopen(intent)
               if recentlyClosedChat == chat.id { recentlyClosedChat = nil }
           })
        .task { await workspace.refreshDirectory(owner) }
    }
}

private struct ChatPickerCards<Content: View>: View {
    let workspace: ConversationWorkspace
    let profile: ExactID
    @ViewBuilder let content: ([ChatCard]) -> Content
    var body: some View { content(workspace.cards(profile: profile)) }
}

private struct ChatTranscript: View {
    let store: AppStore
    let bot: BotProfile
    let workspace: ConversationWorkspace
    let screen: ChatScreen?
    // Preserve byte-distinct host updates through SwiftUI's outer value comparison.
    let messageDisplayRevision: [NativeTranscriptRowValue]
    let isExposed: Bool
    let onOpenArtifact: (AppStore.ArtifactDestination) -> Void
    var onConnectionRequired: () -> Void = {}
    var preview: NativeTranscriptPreview? = nil
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    var actionRevision: UUID? = nil
    var admitsAction: @MainActor () -> Bool = { true }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.layoutDirection) private var direction
    @Environment(\.reportChatModal) private var reportModal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    // The original renderer is accessible only to opt-in matched measurement
    // fixtures. Normal Debug and Release product flows use the native owner.
    var measurementUsesNative = true
    @State private var scrollPolicy = TranscriptScrollPolicy()
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    nonisolated private enum Anchor: Hashable, Sendable { case latest }
    #endif
    private struct RenderOwner: Hashable {
        let messageID: String
        let generation: UUID
        let reviewingConnection: Bool
    }
    private var chat: Conversation? { screen?.snapshot }

    @ViewBuilder var body: some View {
        #if DEBUG
        if measurementUsesNative { nativeTranscript }
        else { swiftUITranscript }
        #else
        nativeTranscript
        #endif
    }
    private var messagePlan: NativeTranscriptMessagePlan {
        NativeTranscriptMessagePlan(chat?.messages ?? [], queuedMessages: chat?.queuedMessages ?? [])
    }
    private var visibleMessages: [ChatMessage] { messagePlan.entries.map(\.message) }
    private var lastVisibleMessageID: String? { messagePlan.entries.last?.message.id }

    private var nativeTranscript: some View {
        NativeTranscript(context: NativeTranscriptContext(workspace: ObjectIdentifier(workspace),
            profile: Data(bot.id.utf8), chat: screen?.selectedChatID, owner: screen?.owner,
            generation: store.artifactGeneration, reviewingConnection: store.showsConnection,
            dynamicType: dynamicType, colorScheme: colorScheme, direction: direction,
            scenePhase: scenePhase, reduceMotion: reduceMotion, actionRevision: actionRevision),
            snapshot: chat, rows: nativeRows, active: isExposed, currentTaskSnapshot: taskSnapshot(),
            admitsAction: admitsAction, preview: preview, topContentInset: topContentInset,
            bottomContentInset: bottomContentInset)
    }

    /// Read cached state only. Coverage by this transcript's own reader does not
    /// change the captured task; Core owner currentness remains a prerequisite.
    private func taskSnapshot() -> @MainActor () -> Conversation? {
        let store = store, workspace = workspace, profile = try? ExactID(bot.id)
        let owner = screen?.owner, chatID = screen?.selectedChatID
        let generation = store.artifactGeneration, reviewing = store.showsConnection
        return {
            guard store.chats === workspace, generation == store.artifactGeneration,
                  reviewing == store.showsConnection, let profile, let owner, workspace.isCurrent(owner),
                  let current = workspace.screen(profile: profile), current.owner == owner,
                  current.selectedChatID == chatID else { return nil }
            return current.snapshot
        }
    }

    private func hosted<V: View>(_ content: V) -> AnyView {
        AnyView(content.environment(\.scenePhase, scenePhase)
            .environment(\.colorScheme, colorScheme).environment(\.dynamicTypeSize, dynamicType)
            .environment(\.layoutDirection, direction).environment(\.reportChatModal, reportModal))
    }

    private var nativeRows: [NativeTranscriptRow] {
        var rows: [NativeTranscriptRow] = []
        let messages = messagePlan
        let lastMessageID = messages.entries.last?.id
        let requests = NativeTranscriptRequestPlan(screen?.requests ?? [])
        if messages.hasAmbiguity || requests.hasAmbiguity {
            rows.append(.init(id: .identityNotice, value: .auxiliary("ambiguous-identifiers")) { _, _ in
                hosted(NativeTranscriptIdentityNotice())
            })
        }
        if let chat, !messages.entries.isEmpty {
            if let date = messages.entries.first?.message.timestamp {
                rows.append(.init(id: .date, value: .auxiliary(String(describing: date))) { _, _ in
                    hosted(Text(date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12))
                })
            }
            // Share this view/environment capture across the metadata array.
            // Capturing the whole transcript separately for every row retained
            // two 12.8MB closure groups at 10k messages in the native heap trace.
            let renderMessage: @MainActor (ChatMessage, Bool, @escaping @MainActor @Sendable () -> Bool,
                NativeTranscriptRowExposure, ReplyBodyMeasurements) -> AnyView = { message, streaming, writer, scope, history in
                hosted(ReplyBodyLayoutOwner(message: message, acceptsWrites: { scope.isCurrent && writer() },
                    content: { renderedMessage(message, in: chat, streaming: streaming, actionScope: ObjectIdentifier(scope), isCurrent: { scope.canPresent }) }, providedHistory: history))
            }
            for displayRow in messages.displayRows {
                if case let .workDetails(tools) = displayRow {
                    rows.append(.init(id: displayRow.id, value: .workDetails(tools)) { _, _ in
                        hosted(WorkDetailsView(messages: tools))
                    })
                    continue
                }
                guard case let .message(entry) = displayRow else { continue }
                let message = entry.message
                if entry.isAmbiguous {
                    rows.append(.init(id: entry.id, value: .message(message, working: false)) { _, _ in
                        hosted(NativeTranscriptAmbiguousMessage(message: message))
                    })
                    continue
                }
                let writer = layoutWriter(for: message)
                let streaming = chat.isWorking && entry.id == lastMessageID
                rows.append(.init(id: entry.id, value: .message(message, working: chat.isWorking, streaming: streaming)) { scope, history in
                    renderMessage(message, streaming, writer, scope, history)
                })
            }
        } else {
            let display = NativeTranscriptEmptyDisplay(profile: bot, image: store.avatar(for: bot),
                opening: screen?.isOpening == true, connected: store.isConnected,
                presentation: store.avatarPresentation(for: bot, scope: .selectedChat))
            rows.append(.init(id: .empty, value: .empty(display)) { _, _ in
                hosted(VStack(spacing: 16) {
                    BotAvatar(profile: display.profile, image: display.image, size: display.opening ? 64 : 90,
                        presentation: display.presentation)
                    if display.opening {
                        Text("Opening your chat…").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Hello, \(display.profile.name).").font(.title2.weight(.semibold))
                        Text(display.connected ? "A thought, a question, a little job.\nThis is a good place to start." : "No saved messages yet.\nReconnect to start the chat.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 44))
            })
        }
        if let screen, let profile = try? ExactID(bot.id) {
            for entry in requests.entries {
                let row = entry.row
                let input = RequestCardInput(row: row, store: store, workspace: workspace, owner: screen.owner, profile: profile)
                rows.append(.init(id: entry.id, value: .request(row.request, enabled: screen.canAct && !entry.isAmbiguous),
                                  request: entry.isAmbiguous ? nil : input) { scope, _ in
                    if entry.isAmbiguous { return hosted(NativeTranscriptAmbiguousRequest(request: row.request)) }
                    return hosted(RequestCard(input: input, canAct: screen.canAct, canEditDraft: screen.canEditDraft, lifetime: scope.requestState))
                })
            }
        }
        if chat?.isWorking == true {
            rows.append(.init(id: .typing, value: .auxiliary(bot.name)) { _, _ in
                hosted(TypingIndicator(botName: bot.name))
            })
        }
        rows.append(.init(id: .terminal, value: .auxiliary("terminal")) { _, _ in
            AnyView(Color.clear.frame(height: 1).accessibilityHidden(true)
                #if DEBUG
                .background { if TranscriptMeasurements.current != nil { TranscriptMeasurementPoint(point: .terminal) } }
                #endif
            )
        })
        return rows
    }

    private func renderedMessage(_ message: ChatMessage, in chat: Conversation, streaming: Bool? = nil,
                                 actionScope: ObjectIdentifier? = nil,
                                 isCurrent: @escaping @MainActor () -> Bool = { true }) -> some View {
        TranscriptMessage(store: store, botID: bot.id, message: message,
                    isStreaming: streaming ?? (chat.isWorking && chat.messages.last.map { $0.id.utf8.elementsEqual(message.id.utf8) } == true),
                    filePreviewsAreSettled: !chat.isWorking,
                    actionOwner: screen?.owner, actionGeneration: store.artifactGeneration,
                    actionScope: actionScope, actionRevision: actionRevision,
                    onOpenAttachment: artifactAction(isCurrent: isCurrent))
            .id(RenderOwner(messageID: message.id, generation: store.artifactGeneration,
                            reviewingConnection: store.showsConnection))
            #if DEBUG
            .environment(\.transcriptMeasurementMessage, TranscriptMeasurements.current != nil ? Data(message.id.utf8) : nil)
            .background {
                if TranscriptMeasurements.current != nil {
                    TranscriptMeasurementPoint(point: .row(Data(message.id.utf8)), revision: Data(message.text.utf8))
                }
            }
            #endif
    }

    private func artifactAction(isCurrent: @escaping @MainActor () -> Bool = { true }) -> ((ChatAttachment) -> Void)? {
        transcriptArtifactAction(store: store, workspace: workspace, botID: bot.id, owner: screen?.owner,
                                 admittedBy: isCurrent, onConnectionRequired: onConnectionRequired, onOpen: onOpenArtifact)
    }

    private func layoutWriter(for message: ChatMessage) -> @MainActor @Sendable () -> Bool {
        let store = store, workspace = workspace
        let profile = try? ExactID(bot.id)
        let chatID = screen?.selectedChatID
        let generation = store.artifactGeneration
        let reviewingConnection = store.showsConnection
        let messageID = Data(message.id.utf8), text = message.text
        return {
            guard generation == store.artifactGeneration, reviewingConnection == store.showsConnection,
                  store.chats === workspace, let profile,
                  let current = workspace.screen(profile: profile), current.selectedChatID == chatID,
                  let currentMessage = current.snapshot?.messages.first(where: { Data($0.id.utf8) == messageID }) else { return false }
            return currentMessage.text.utf8.elementsEqual(text.utf8)
        }
    }

    #if DEBUG
    private var swiftUITranscript: some View {
        Group {
            ScrollView {
                transcriptStack
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 14)
                .frame(maxWidth: 740).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("chat-transcript")
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(sizeChangesAnchor, for: .sizeChanges)
            .onScrollGeometryChange(for: TranscriptScrollPolicy.Metrics.self) { geometry in
                TranscriptScrollPolicy.Metrics(geometry)
            } action: { previous, metrics in
                if scrollPolicy.geometryChanged(from: previous, to: metrics) { scrollToLatest() }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                // Navigation and the keyboard resize the actual viewport after its
                // first layout. ScrollGeometry can still report the pre-navigation
                // size, so observe the view itself before following the final row.
                if scrollPolicy.shouldFollowLatest && size.height > 0 {
                    scrollToLatest()
                }
            }
            .onScrollPhaseChange { previous, phase, context in
                scrollPolicy.phaseChanged(from: previous, to: phase, geometry: context.geometry)
            }
            .onChange(of: chat) { _, _ in
                if scrollPolicy.snapshotChanged() {
                    scrollToLatest()
                }
            }
            .overlay(alignment: .bottom) {
                if scrollPolicy.showsLatest {
                    Button {
                        scrollPolicy.requestLatest()
                        if reduceMotion { scrollPosition.scrollTo(id: Anchor.latest, anchor: .bottom) }
                        else { withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(id: Anchor.latest, anchor: .bottom) } }
                    } label: {
                        Label("Latest messages", systemImage: "arrow.down").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).frame(minHeight: 44)
                            .background(BottoTheme.action, in: Capsule()).foregroundStyle(BottoTheme.onAction)
                    }
                    .buttonStyle(.plain).padding(.bottom, 8)
                }
            }
        }
    }

    private var sizeChangesAnchor: UnitPoint? {
        return scrollPolicy.followsLatest ? .bottom : nil
    }

    @ViewBuilder private var transcriptStack: some View {
        LazyVStack(alignment: .leading, spacing: 14) { transcriptRows }
            .scrollTargetLayout()
    }

    @ViewBuilder private var transcriptRows: some View {
        if let chat, !visibleMessages.isEmpty {
            if let firstDate = visibleMessages.first?.timestamp {
                Text(firstDate, format: .dateTime.month(.abbreviated).day())
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            ForEach(messagePlan.displayRows) { row in
                switch row {
                case .workDetails(let tools):
                    WorkDetailsView(messages: tools)
                case .message(let entry):
                    if entry.isAmbiguous {
                        NativeTranscriptAmbiguousMessage(message: entry.message)
                    } else {
                        ReplyBodyLayoutOwner(message: entry.message, acceptsWrites: layoutWriter(for: entry.message)) {
                            messageLayout(entry.message, in: chat)
                        }
                    }
                }
            }
            requestRows
        } else if screen?.isOpening == true {
            VStack(spacing: 16) {
                AppBotAvatar(store: store, bot: bot, scope: .selectedChat, size: 64)
                Text("Opening your chat…").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 44)
        } else {
            VStack(spacing: 16) {
                AppBotAvatar(store: store, bot: bot, scope: .selectedChat, size: 90)
                Text("Hello, \(bot.name).").font(.title2.weight(.semibold))
                Text(store.isConnected ? "A thought, a question, a little job.\nThis is a good place to start." : "No saved messages yet.\nReconnect to start the chat.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 44)
            requestRows
        }
        if visibleMessages.isEmpty && chat?.isWorking == true { TypingIndicator(botName: bot.name) }
        Color.clear.frame(height: 1).id(Anchor.latest).accessibilityHidden(true)
    }

    @ViewBuilder private func messageLayout(_ message: ChatMessage, in chat: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            renderedMessage(message, in: chat, streaming: chat.isWorking && lastVisibleMessageID.map { TranscriptContentRevision.exact($0, message.id) } == true)
            if chat.isWorking && lastVisibleMessageID.map({ TranscriptContentRevision.exact($0, message.id) }) == true {
                TypingIndicator(botName: bot.name)
            }
        }
    }

    @ViewBuilder private var requestRows: some View {
        if let screen, let profile = try? ExactID(bot.id) {
            ForEach(screen.requests) { row in
                RequestCard(input: .init(row: row, store: store, workspace: workspace, owner: screen.owner, profile: profile),
                                canAct: screen.canAct, canEditDraft: screen.canEditDraft)
            }
        }
    }

    private func scrollToLatest() {
        // Follow the edge without resolving a lazy row during layout. On iOS 26,
        // resolving the final row can alternate content-height estimates and
        // trigger another scroll from the geometry observer indefinitely.
        // Automatic following is immediate, including while tokens arrive.
        withTransaction(Transaction(animation: nil)) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }
    #endif
}

/// Captures file action admission separately from the semantic lifetime of an
/// already-open reader. The native caller supplies its current display gate.
@MainActor func transcriptArtifactAction(store: AppStore, workspace: ConversationWorkspace, botID: String,
                                       owner: PresentationOwner?, admittedBy admission: @escaping @MainActor () -> Bool,
                                       onConnectionRequired: @escaping () -> Void = {},
                                       onOpen: @escaping (AppStore.ArtifactDestination) -> Void) -> ((ChatAttachment) -> Void)? {
    let generation = store.artifactGeneration
    return { attachment in
        guard admission(), generation == store.artifactGeneration, let owner, workspace.isCurrent(owner) else { return }
        guard store.isConnected else { onConnectionRequired(); return }
        guard let destination = store.artifactDestination(for: attachment, botID: botID) else { return }
        onOpen(destination)
    }
}

#if DEBUG
/// Opt-in matched measurements reuse the same rows, model and action guards.
/// This is not a launch argument or a product-mode switch.
@MainActor func transcriptFixture(store: AppStore, bot: BotProfile,
                                  presentation: WorkspacePresentation, native: Bool) -> some View {
    let workspace = store.chats
    let screen = (try? ExactID(bot.id)).flatMap { workspace.screen(profile: $0) }
    return ChatTranscript(store: store, bot: bot, workspace: workspace, screen: screen,
                           messageDisplayRevision: (screen?.snapshot?.messages ?? []).map { .message($0, working: false) }, isExposed: true,
        onOpenArtifact: { presentation.openArtifact($0, store: store) }, measurementUsesNative: native)
        .id(screen?.selectedChatID)
}
#endif

/// Local source/preview sheets and approval confirmations report coverage to
/// their containing chat without taking ownership of conversation authority.
private struct ChatModalReporterKey: EnvironmentKey {
    static let defaultValue: @MainActor (UUID, Bool) -> Void = { _, _ in }
}
extension EnvironmentValues {
    var reportChatModal: @MainActor (UUID, Bool) -> Void {
        get { self[ChatModalReporterKey.self] }
        set { self[ChatModalReporterKey.self] = newValue }
    }
}

/// Lazy row discovery must stay cheap. Resolving a rich-reply context validates
/// canonical blocks, so defer that work until SwiftUI renders this message.
private struct TranscriptMessage: View {
    let store: AppStore
    let botID: String
    let message: ChatMessage
    let isStreaming: Bool
    let filePreviewsAreSettled: Bool
    let actionOwner: PresentationOwner?
    let actionGeneration: UUID
    let actionScope: ObjectIdentifier?
    let actionRevision: UUID?
    let onOpenAttachment: ((ChatAttachment) -> Void)?

    var body: some View {
        let senderProfile = message.botSender.flatMap { ChatSenderAvatar.profile(for: $0, among: store.bots) }
        let rendered = TranscriptMessageBody(message: message, isStreaming: isStreaming,
                              filePreviewsAreSettled: filePreviewsAreSettled,
                              actionOwner: actionOwner, actionGeneration: actionGeneration,
                              actionScope: actionScope, actionRevision: actionRevision,
                              canOpenAttachment: onOpenAttachment != nil,
                              senderProfile: senderProfile, senderImage: senderProfile.flatMap(store.avatar(for:)),
                              onOpenAttachment: onOpenAttachment)
            .equatable()
            .environment(\.richReplyContext, message.isVisible && message.role == .assistant ? store.richReplyContext(for: botID, messageID: message.id) : .chat(nil))
        if message.notificationPresentation == nil && message.role != .tool && message.role != .system {
            rendered.accessibilityIdentifier("transcript-message-\(message.id)")
        } else {
            rendered
        }
    }
}

/// Context authority can update without rebuilding settled native text. The
/// action's captured owner and generation must change together with its closure.
private struct TranscriptMessageBody: View, Equatable {
    let message: ChatMessage
    let isStreaming: Bool
    let filePreviewsAreSettled: Bool
    let actionOwner: PresentationOwner?
    let actionGeneration: UUID
    let actionScope: ObjectIdentifier?
    let actionRevision: UUID?
    let canOpenAttachment: Bool
    let senderProfile: BotProfile?
    let senderImage: UIImage?
    let onOpenAttachment: ((ChatAttachment) -> Void)?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.isStreaming == rhs.isStreaming,
              lhs.filePreviewsAreSettled == rhs.filePreviewsAreSettled,
              lhs.actionOwner == rhs.actionOwner, lhs.actionGeneration == rhs.actionGeneration,
              lhs.actionScope == rhs.actionScope, lhs.actionRevision == rhs.actionRevision,
              lhs.canOpenAttachment == rhs.canOpenAttachment,
              sameSenderProfile(lhs.senderProfile, rhs.senderProfile), lhs.senderImage === rhs.senderImage,
              TranscriptContentRevision.sameMessage(lhs.message, rhs.message) else { return false }
        return true
    }

    nonisolated private static func sameSenderProfile(_ lhs: BotProfile?, _ rhs: BotProfile?) -> Bool {
        guard lhs == rhs else { return false }
        let first = [lhs?.id, lhs?.name, lhs?.appearance?.rawShape, lhs?.appearance?.color,
                     lhs?.appearance?.imageKind, lhs?.appearance?.expression]
        let second = [rhs?.id, rhs?.name, rhs?.appearance?.rawShape, rhs?.appearance?.color,
                      rhs?.appearance?.imageKind, rhs?.appearance?.expression]
        return first.map { $0.map { Data($0.utf8) } } == second.map { $0.map { Data($0.utf8) } }
    }

    var body: some View {
        MessageView(message: message, isStreaming: isStreaming,
                    filePreviewsAreSettled: filePreviewsAreSettled,
                    senderProfile: senderProfile, senderImage: senderImage, onOpenAttachment: onOpenAttachment)
    }
}

/// A quiet incoming bubble that leaves the transcript and composer steady.
private struct TypingIndicator: View {
    let botName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dot: some View {
        Circle().fill(.secondary).frame(width: 8, height: 8)
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                if reduceMotion {
                    dot.opacity(0.65)
                } else {
                    dot.phaseAnimator([false, true]) { dot, highlighted in
                        dot.opacity(highlighted ? 1 : 0.35)
                    } animation: { highlighted in
                        .easeInOut(duration: 0.55).delay(highlighted ? Double(index) * 0.16 : 0.3)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(BottoTheme.surface, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(botName) is replying")
        .accessibilityIdentifier("chat-typing-indicator")
    }
}
