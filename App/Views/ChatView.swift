import SwiftUI
import UIKit
import BottoCore

struct ChatView: View {
    @Bindable var store: AppStore
    let bot: BotProfile
    let presentation: WorkspacePresentation
    let isExposed: Bool
    let isEditingExposed: Bool
    let importPaneVisible: Bool
    let rootCovered: Bool
    let onLocalModalPresentation: (Bool) -> Void
    var canPresentToolbar: () -> Bool = { true }
    var canContinueEditing: () -> Bool = { true }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.composerEditing) private var providedEditing
    @State private var localEditing = ComposerEditingHandle()
    private var editing: ComposerEditingHandle { providedEditing ?? localEditing }
    @State private var connectionRequested = false
    @State private var composerHeight: CGFloat = 0
    @State private var paneWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAttachmentPicker = false
    @State private var childModals: Set<UUID> = []
    @State private var importPresentationRevision = UUID()
    @Environment(\.t3Chrome) private var t3Chrome

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
        !showsAttachmentPicker && childModals.isEmpty && !rootCovered &&
            !store.showsConnection && scenePhase == .active
    }
    private var transcriptVisible: Bool { isExposed && chatUncoveredByPresentation }
    private var inputAvailable: Bool {
        isEditingExposed && chatUncoveredByPresentation
    }

    private var localModalPresented: Bool {
        showsAttachmentPicker || !childModals.isEmpty
    }

    var body: some View {
        readerLifecycle
        .onChange(of: store.showsConnection) { _, shown in
            if shown { coverTranscript(); importPresentationRevision = UUID() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                importPresentationRevision = UUID()
            }
        }
        .onChange(of: rootCovered) { _, covered in
            if covered { coverTranscript(); importPresentationRevision = UUID() }
        }
        .onDisappear { hiddenTranscript()() }
    }

    private var messageDisplayRevision: [NativeTranscriptRowValue] {
        (screen?.snapshot?.messages ?? []).map { .message($0, working: false) }
    }

    private var presentationContent: some View {
        let screen = self.screen
        let toolbarRevision = presentation.revision
        let toolbarOwner = screen?.owner
        let editingRevision = presentation.revision
        return chatPane(screen, toolbarRevision: toolbarRevision, toolbarOwner: toolbarOwner, editingRevision: editingRevision)
        .onChange(of: screen?.owner) { _, _ in presentation.reconcile(store: store) }
        .onChange(of: messageDisplayRevision) { _, _ in presentation.reconcile(store: store) }
        .onChange(of: store.isConnected) { _, _ in connectionRequested = false }
        .onChange(of: screen?.selectedChatID) { _, _ in connectionRequested = false }
        .onChange(of: ObjectIdentifier(workspace)) { _, _ in
            editing.cancel()
            childModals = []
            connectionRequested = false
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
        .onAppear { markDisplayed() }
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

    }

    private func chatPane(_ screen: ChatScreen?, toolbarRevision: UUID, toolbarOwner: PresentationOwner?,
                          editingRevision: UUID) -> some View {
        ZStack(alignment: .bottom) {
            ChatTranscript(store: store, bot: bot, workspace: workspace, screen: screen,
                           messageDisplayRevision: messageDisplayRevision, isExposed: transcriptVisible,
                           onOpenArtifact: { presentation.openArtifact($0, store: store) },
                           bottomContentInset: composerHeight,
                           searchFocus: presentation.searchFocus.flatMap {
                               $0.owner == screen?.owner && $0.matches(workspace: workspace) ? $0 : nil
                           },
                           reportSearchFocus: { presentation.reportSearchFocus($0, result: $1) },
                           actionRevision: toolbarRevision, admitsAction: {
                               presentation.revision == toolbarRevision && transcriptVisible && canPresentToolbar()
                           })
                // Keep the reader's position across access refreshes in this chat.
                .id(screen?.selectedChatID)
                .ignoresSafeArea(.container, edges: .top)
            // Older layouts need a backing to obscure transcript text in the status area.
            if #unavailable(iOS 27) {
                    GeometryReader { geometry in
                        Rectangle().fill(.regularMaterial)
                            .frame(height: geometry.safeAreaInsets.top + 24)
                            .mask {
                                VStack(spacing: 0) {
                                    Color.black
                                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                        .frame(height: 24)
                                }
                            }
                            .offset(y: -geometry.safeAreaInsets.top)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 10) {
                if store.isDemo { DemoBanner() }
                if connectionRequested && !store.isConnected {
                    ConnectionStatusView(store: store).padding(.horizontal, 16)
                }
                if let notice = store.notice {
                    InlineNotice(message: notice) { store.notice = nil }.padding(.horizontal, 16)
                }
                if store.canRetryOpening(bot) {
                    Button {
                        guard canPresentToolbar(), let opening = store.prepareBotOpening(bot) else { return }
                        store.notice = nil
                        Task { await store.openBot(opening) }
                    } label: {
                        Label("Retry opening this space", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("chat-opening-retry")
                }
                if let error = screen?.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                }
                if let error = presentation.searchError {
                    InlineNotice(message: error) { presentation.searchError = nil }.padding(.horizontal, 16)
                }
                // Its structural identity stays attached to the bot, preserving editor focus.
                ChatComposer(store: store, bot: bot, workspace: workspace, screen: screen,
                             inputAvailable: inputAvailable,
                             importsAllowed: importPaneVisible && childModals.isEmpty && !rootCovered && scenePhase != .background,
                             importPresentationRevision: importPresentationRevision,
                             editingRevision: editingRevision,
                             onPickerPresentation: { shown in
                                 if shown { coverTranscript() }
                                 showsAttachmentPicker = shown
                             }, canContinueEditing: {
                                 let sameRevision = presentation.revision == editingRevision
                                 let exposed = inputAvailable
                                 let available = canContinueEditing()
                                 return sameRevision && exposed && available
                             }, editingHandle: editing, connectionRequested: $connectionRequested)
            }
            .padding(.top, 8)
            .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { composerHeight = $0 }
        }
        .background(BottoTheme.paper)
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
        .environment(\.reportChatModal, modalReporter())
        .environment(\.composerEditing, editing)
        .toolbar {
            if let t3Chrome {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Spaces", systemImage: "line.3.horizontal") {
                        guard canPresentToolbar() else { return }
                        editing.cancel()
                        t3Chrome.openDrawer()
                    }
                    .accessibilityIdentifier("t3-open-drawer")
                }
                // In the bar itself, so it shares the buttons' center line.
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .principal) {
                        t3Header(screen, revision: toolbarRevision, owner: toolbarOwner)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) {
                        t3Header(screen, revision: toolbarRevision, owner: toolbarOwner)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New space", systemImage: "square.and.pencil") {
                        guard canPresentToolbar() else { return }
                        editing.cancel()
                        t3Chrome.newSpace()
                    }
                    .accessibilityIdentifier("t3-new-space")
                }
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
        guard mayPresent(revision: revision, owner: owner), let t3Chrome else { return }
        editing.cancel()
        t3Chrome.openBotto()
    }

    /// The widest the bar’s title may be without reaching the buttons or leaving the center.
    private var t3HeaderMaxWidth: CGFloat { max(120, paneWidth - 2 * (16 + 44 + 8 + 8)) }

    private func t3Header(_ screen: ChatScreen?, revision: UUID, owner: PresentationOwner?) -> some View {
        let activity = store.avatarPresentation(for: bot, scope: .selectedChat).activity
        let title = store.selectedT3ChannelTitle ?? T3ChannelSummary.untitledDisplayTitle
        let cue = T3ActivityCue.text(for: activity)
        return Button { presentProfile(revision: revision, owner: owner) } label: {
            HStack(spacing: 9) {
                AppBotAvatar(store: store, bot: bot, scope: .selectedChat, size: 32, fitsBody: true)
                    .frame(height: 32, alignment: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.bottoRounded(.subheadline, weight: .bold)).foregroundStyle(BottoTheme.ink)
                        .lineLimit(1).truncationMode(.tail)
                    if let cue {
                        Text(cue).font(.caption.weight(.medium)).foregroundStyle(BottoTheme.action)
                            .lineLimit(1).contentTransition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: cue)
            }
            .padding(.leading, 8).padding(.trailing, 14).frame(minHeight: 44)
            .t3HeaderGlass()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Like a system bar title: it stays one bar tall, and large text shows on a long press.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityShowsLargeContentViewer { Text(title) }
        .frame(maxWidth: t3HeaderMaxWidth)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cue.map { "\(title), \(bot.name) is \($0)" } ?? title)
        .accessibilityHint("Open \(bot.name)’s page.")
        .accessibilityIdentifier("t3-chat-header")
        .disabled(screen == nil)
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

}

struct ChatTranscript: View {
    let store: AppStore
    let bot: BotProfile
    let workspace: ConversationWorkspace
    let screen: ChatScreen?
    // Preserve byte-distinct host updates through SwiftUI's outer value comparison.
    let messageDisplayRevision: [NativeTranscriptRowValue]
    let isExposed: Bool
    let onOpenArtifact: (AppStore.ArtifactDestination) -> Void
    var preview: NativeTranscriptPreview? = nil
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    var searchFocus: SearchMessageFocus? = nil
    var reportSearchFocus: @MainActor (UUID, SearchFocusResult) -> Void = { _, _ in }
    var actionRevision: UUID? = nil
    var admitsAction: @MainActor () -> Bool = { true }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.layoutDirection) private var direction
    @Environment(\.reportChatModal) private var reportModal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    // Legacy SwiftUI comparator for transcript test fixtures. It flips the scroll
    // view and rows and lists rows newest first.
    // Debug and Release product flows use the unchanged native owner.
    var measurementUsesNative = true
    @State private var scrollPolicy = TranscriptScrollPolicy()
    @State private var scrollPosition = ScrollPosition(edge: .top)
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
        NativeTranscriptMessagePlan(chat?.messages ?? [], queuedMessages: chat?.queuedMessages ?? [],
            unavailableMessageIDs: TranscriptMessageIndex(chat).unavailableIDs)
    }
    private var visibleMessages: [ChatMessage] { messagePlan.entries.map(\.message) }
    private var lastVisibleMessageID: String? { messagePlan.entries.last?.message.id }

    private var nativeTranscript: some View {
        NativeTranscript(context: NativeTranscriptContext(workspace: ObjectIdentifier(workspace),
            profile: Data(bot.id.utf8), chat: screen?.selectedChatID, owner: screen?.owner,
            generation: store.artifactGeneration, reviewingConnection: store.showsConnection,
            dynamicType: dynamicType, colorScheme: colorScheme, direction: direction,
            scenePhase: scenePhase, reduceMotion: reduceMotion, actionRevision: actionRevision,
            readerLifetime: screen?.selectedViewLifetime),
            snapshot: chat, rows: nativeRows, active: isExposed, currentTaskSnapshot: taskSnapshot(),
            currentReaderSnapshot: readerSnapshot(),
            admitsAction: admitsAction, preview: preview, topContentInset: topContentInset,
            bottomContentInset: bottomContentInset,
            searchFocus: searchFocus, reportSearchFocus: reportSearchFocus)
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

    // Tool output is read-only. Live access and file-download generations can
    // refresh during the same chat without ending this reader's lifetime.
    private func readerSnapshot() -> @MainActor () -> Conversation? {
        let store = store, workspace = workspace, profile = try? ExactID(bot.id)
        let lifetime = screen?.selectedViewLifetime, chatID = screen?.selectedChatID
        let reviewing = store.showsConnection
        return {
            guard store.chats === workspace,
                  reviewing == store.showsConnection, let profile, let lifetime,
                  let current = workspace.screen(profile: profile), current.selectedViewLifetime == lifetime,
                  current.selectedChatID == chatID else { return nil }
            return current.snapshot
        }
    }

    private func hosted<V: View>(_ content: V) -> AnyView {
        AnyView(content.environment(\.scenePhase, scenePhase)
            .environment(\.colorScheme, colorScheme).environment(\.dynamicTypeSize, dynamicType)
            .environment(\.layoutDirection, direction).environment(\.reportChatModal, reportModal))
    }

    private var workActivity: TranscriptWorkActivity {
        .init(snapshot: chat, phase: screen?.workPhase)
    }

    private func activeWorkDetailsID(in rows: [NativeTranscriptMessagePlan.DisplayRow]) -> NativeTranscriptItemID? {
        guard workActivity == .working, case .workDetails? = rows.last else { return nil }
        return rows.last?.id
    }

    private var nativeRows: [NativeTranscriptRow] {
        var rows: [NativeTranscriptRow] = []
        let messages = messagePlan
        let displayRows = messages.displayRows
        let activeWorkDetailsID = activeWorkDetailsID(in: displayRows)
        let lastMessageID = messages.entries.last?.id
        let requests = NativeTranscriptRequestPlan(screen?.requests ?? [])
        if screen?.hasEarlierMessages == true {
            rows.append(.init(id: .historyNotice, value: .auxiliary("recent-history")) { _, _ in
                hosted(Text("Some earlier history isn’t available on this device yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12))
            })
        }
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
            for displayRow in displayRows {
                if case let .workDetails(tools) = displayRow {
                    let active = displayRow.id == activeWorkDetailsID
                    rows.append(.init(id: displayRow.id, value: .workDetails(tools, active: active)) { _, _ in
                        hosted(WorkDetailsView(messages: tools, isActive: active))
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
                        Text("Opening your space…").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Hello, \(display.profile.name).").font(.title2.weight(.semibold))
                        Text(display.connected ? "A thought, a question, a little job.\nThis is a good place to start."
                             : "No saved messages yet.\nReconnect to pick this space up.")
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
        if workActivity == .working && activeWorkDetailsID == nil {
            rows.append(.init(id: .working, value: .auxiliary(bot.name)) { _, _ in
                hosted(WorkingIndicator(botName: bot.name))
            })
        }
        if workActivity == .typing {
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
                    onOpenAttachment: artifactAction(message: message, isCurrent: isCurrent))
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

    private func artifactAction(message: ChatMessage, isCurrent: @escaping @MainActor () -> Bool = { true }) -> ((ChatAttachment) -> Void)? {
        transcriptArtifactAction(store: store, workspace: workspace, botID: bot.id, owner: screen?.owner, producingMessage: message,
                                 admittedBy: isCurrent, onOpen: onOpenArtifact)
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
            .scaleEffect(x: 1, y: -1)
            .accessibilityIdentifier("chat-transcript")
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(sizeChangesAnchor, for: .sizeChanges)
            .onScrollGeometryChange(for: TranscriptScrollPolicy.Metrics.self) { geometry in
                TranscriptScrollPolicy.Metrics(LatestAtTopGeometry.logical(geometry))
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
                scrollPolicy.phaseChanged(from: previous, to: phase, geometry: LatestAtTopGeometry.logical(context.geometry))
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
                        if reduceMotion { scrollPosition.scrollTo(id: Anchor.latest, anchor: .top) }
                        else { withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(id: Anchor.latest, anchor: .top) } }
                    } label: {
                        Image(systemName: "arrow.down").font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(BottoTheme.action, in: Circle()).foregroundStyle(BottoTheme.onAction)
                    }
                    .accessibilityLabel("Latest messages")
                    .buttonStyle(.plain).padding(.bottom, 8)
                }
            }
        }
    }

    private var sizeChangesAnchor: UnitPoint? {
        return scrollPolicy.followsLatest ? .top : nil
    }

    @ViewBuilder private var transcriptStack: some View {
        LazyVStack(alignment: .leading, spacing: 14) { Group { transcriptRows }.scaleEffect(x: 1, y: -1) }
            .scrollTargetLayout()
    }

    // Newest first. The scroll view and each row are flipped, so the latest row sits at the lazy
    // stack's leading edge, where it is placed exactly, rather than at an estimated far end.
    @ViewBuilder private var transcriptRows: some View {
        let displayRows = messagePlan.displayRows
        let activeWorkDetailsID = activeWorkDetailsID(in: displayRows)
        Color.clear.frame(height: 1)
            .background { if TranscriptMeasurements.current != nil { TranscriptMeasurementPoint(point: .terminal) } }
            .id(Anchor.latest).accessibilityHidden(true)
        if workActivity == .typing { TypingIndicator(botName: bot.name) }
        if workActivity == .working && activeWorkDetailsID == nil { WorkingIndicator(botName: bot.name) }
        if let chat, !visibleMessages.isEmpty {
            requestRows
            ForEach(displayRows.reversed()) { row in
                switch row {
                case .workDetails(let tools):
                    WorkDetailsView(messages: tools, isActive: row.id == activeWorkDetailsID)
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
            if let firstDate = visibleMessages.first?.timestamp {
                Text(firstDate, format: .dateTime.month(.abbreviated).day())
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        } else if screen?.isOpening == true {
            VStack(spacing: 16) {
                AppBotAvatar(store: store, bot: bot, scope: .selectedChat, size: 64)
                Text("Opening your space…").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 44)
        } else {
            requestRows
            VStack(spacing: 16) {
                AppBotAvatar(store: store, bot: bot, scope: .selectedChat, size: 90)
                Text("Hello, \(bot.name).").font(.title2.weight(.semibold))
                Text(store.isConnected ? "A thought, a question, a little job.\nThis is a good place to start."
                     : "No saved messages yet.\nReconnect to pick this space up.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 44)
        }
    }

    @ViewBuilder private func messageLayout(_ message: ChatMessage, in chat: Conversation) -> some View {
        renderedMessage(message, in: chat, streaming: chat.isWorking && lastVisibleMessageID.map { TranscriptContentRevision.exact($0, message.id) } == true)
    }

    @ViewBuilder private var requestRows: some View {
        if let screen, let profile = try? ExactID(bot.id) {
            ForEach(screen.requests.reversed()) { row in
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
            scrollPosition.scrollTo(edge: .top)
        }
    }
    #endif
}

/// Captures file action admission separately from the semantic lifetime of an
/// already-open reader. The native caller supplies its current display gate.
@MainActor func transcriptArtifactAction(store: AppStore, workspace: ConversationWorkspace, botID: String,
                                       owner: PresentationOwner?, producingMessage: ChatMessage? = nil, admittedBy admission: @escaping @MainActor () -> Bool,
                                       onOpen: @escaping (AppStore.ArtifactDestination) -> Void) -> ((ChatAttachment) -> Void)? {
    let generation = store.artifactGeneration
    return { attachment in
        guard admission(), generation == store.artifactGeneration, let owner, workspace.isCurrent(owner) else { return }
        guard let destination = store.artifactDestination(for: attachment, botID: botID, producingMessage: producingMessage) else { return }
        onOpen(destination)
    }
}

#if DEBUG
/// The legacy transcript draws its latest row at the raw top of a flipped scroll view.
/// TranscriptScrollPolicy reads latest at the bottom, so mirror the distance from the
/// latest edge into that space once for every policy caller.
nonisolated enum LatestAtTopGeometry {
    static func logical(_ raw: ScrollGeometry) -> ScrollGeometry {
        let insets = raw.contentInsets
        let range = max(0, raw.contentSize.height + insets.bottom - raw.containerSize.height)
        let fromLatest = raw.contentOffset.y + insets.top
        return ScrollGeometry(contentOffset: CGPoint(x: raw.contentOffset.x, y: range - fromLatest - insets.top),
                              contentSize: raw.contentSize, contentInsets: insets, containerSize: raw.containerSize)
    }
}

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
    @Environment(\.nativeSearchMatch) private var searchMatch
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
                              searchMatch: searchMatch,
                              filePreviewsAreSettled: filePreviewsAreSettled,
                              actionOwner: actionOwner, actionGeneration: actionGeneration,
                              actionScope: actionScope, actionRevision: actionRevision,
                              canOpenAttachment: onOpenAttachment != nil,
                              senderProfile: senderProfile, senderImage: senderProfile.flatMap(store.avatar(for:)),
                              onOpenAttachment: onOpenAttachment, thumbnails: store.chats.thumbnails)
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
    let searchMatch: NativeSearchMatch?
    let filePreviewsAreSettled: Bool
    let actionOwner: PresentationOwner?
    let actionGeneration: UUID
    let actionScope: ObjectIdentifier?
    let actionRevision: UUID?
    let canOpenAttachment: Bool
    let senderProfile: BotProfile?
    let senderImage: UIImage?
    let onOpenAttachment: ((ChatAttachment) -> Void)?
    let thumbnails: AttachmentThumbnails

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.isStreaming == rhs.isStreaming,
              lhs.searchMatch == rhs.searchMatch,
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
                    senderProfile: senderProfile, senderImage: senderImage, onOpenAttachment: onOpenAttachment,
                    thumbnails: thumbnails)
    }
}

private struct WorkingIndicator: View {
    let botName: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(botName) is working")
        .accessibilityIdentifier("chat-working-indicator")
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
