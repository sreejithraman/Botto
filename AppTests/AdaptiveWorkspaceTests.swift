import SwiftUI
import UIKit
import QuickLook
import Observation
import Foundation
import Testing
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct AdaptiveWorkspaceTests {
    @Test func retainedWorkspaceKeepsNativeEditorAndTranscriptAcrossFullStreamAndRosterUpdates() async throws {
        let service = try NativeTranscriptReviewService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://shell-retention.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let window = try await attach(AdaptiveWorkspace(store: store, presentation: presentation,
            rootCovered: false, onSettings: {}, onNewBot: {}), logicalSize: CGSize(width: 1000, height: 700))
        defer { window.close() }
        let root = try #require(window.rootViewController)
        try await waitUntil("The retained chat has an eligible editor and native transcript") {
            nativeTextViews(in: root.view).contains { $0 is NativeComposerTextView && $0.isEditable }
                && !shellTranscripts(in: root).isEmpty
        }
        let editor = try #require(nativeTextViews(in: root.view).first { $0 is NativeComposerTextView && $0.isEditable })
        let transcript = try #require(shellTranscripts(in: root).first)
        let split = try #require(splitControllers(in: root).first)
        let owner = try #require(store.chats.screen(profile: service.base.profile)?.owner)
        store.chats.editDraft("Keep focus and this draft", owner: owner)
        try await waitUntil { editor.text == "Keep focus and this draft" }
        // Keep responder retention independent of the Simulator's remote keyboard service.
        editor.inputView = UIView(frame: .zero)
        try #require(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: 4, length: 5)
        let selectedRange = editor.selectedRange
        @MainActor final class FocusProbe { var events: [String] = [] }
        let focusProbe = FocusProbe()
        @MainActor func recordFocus(_ reason: String) {
            guard focusProbe.events.count < 8 else { return }
            let state = """
            \(reason)
            keyWindow=\(window.isKeyWindow) editorAttached=\(editor.window === window)
            editable=\(editor.isEditable) firstResponder=\(editor.isFirstResponder)
            selection=\(editor.selectedRange) expectedSelection=\(selectedRange)
            scene=\(window.windowScene?.activationState.rawValue ?? -1) app=\(UIApplication.shared.applicationState.rawValue)
            split=\(split.displayMode.rawValue) collapsed=\(split.isCollapsed) transition=\(split.transitionCoordinator != nil)
            currentOwner=\(store.chats.screen(profile: service.base.profile)?.owner == owner) revision=\(presentation.revision)
            """
            focusProbe.events.append(state + "\n" + Thread.callStackSymbols.prefix(40).joined(separator: "\n"))
        }
        let endedEditing = NotificationCenter.default.addObserver(forName: UITextView.textDidEndEditingNotification,
            object: editor, queue: .main) { _ in MainActor.assumeIsolated { recordFocus("editor-ended") } }
        let resignedKey = NotificationCenter.default.addObserver(forName: UIWindow.didResignKeyNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { recordFocus("window-resigned-key") } }
        defer {
            NotificationCenter.default.removeObserver(endedEditing)
            NotificationCenter.default.removeObserver(resignedKey)
        }
        let opened = try #require(service.base.completedOpens.last)
        for index in 0..<4 {
            var chat = try #require(store.conversation(for: service.profile.id))
            chat.messages.append(.init(id: "shell-stream-\(index)", role: .assistant, text: "Current reply \(index)"))
            service.onEvent?(.conversation(.init(identity: opened.identity, snapshot: chat, access: opened.access)))
            service.profile.preview = "Latest roster preview \(index)"
            service.profile.updatedAt = Date(timeIntervalSince1970: Double(100 + index))
            await store.refresh()
            window.layoutIfNeeded()
            try await waitUntil { store.conversation(for: service.profile.id)?.messages.last?.id == "shell-stream-\(index)" }
            #expect(shellTranscripts(in: root).first === transcript && splitControllers(in: root).first === split)
            #expect(nativeTextViews(in: root.view).contains { $0 === editor })
            #expect(editor.isFirstResponder && editor.selectedRange == selectedRange)
            #expect(store.chats.draft(owner) == "Keep focus and this draft")
        }
        service.profile.name = "Renamed e\u{301} bot"
        service.profile.description = "Current profile description"
        service.profile.model = "current-model"
        service.profile.appearance = .init(shape: .cloud, color: "#ef4444", custom: true, expression: "happy")
        service.profile.lookRevision = 9
        await store.refresh(); window.layoutIfNeeded()
        try await waitUntil("The existing native header receives the changed profile name") {
            shellAccessibilityLabels(in: root.view).contains { $0.contains("Profile for Renamed e\u{301} bot") }
        }
        #expect(splitControllers(in: root).first === split && shellTranscripts(in: root).first === transcript)
        if !editor.isFirstResponder || editor.selectedRange != selectedRange {
            recordFocus("final-focus-state")
            Attachment.record(focusProbe.events.joined(separator: "\n\n"), named: "native-editor-focus-loss.txt")
        }
        #expect(editor.isFirstResponder && editor.selectedRange == selectedRange)
        #expect(store.bot(withID: service.profile.id)?.appearance == service.profile.appearance)
        presentation.browseBots(); window.layoutIfNeeded()
        var inboxRow: NSObject?
        try await waitUntil("Returning to Inbox reveals current bot metadata and its latest chat preview", diagnostics: {
            "publicPreview=\(store.bot(withID: service.profile.id)?.preview ?? "nil") historyPreview=\(store.history.bots.first?.preview ?? "nil") labels=\(shellAccessibilityLabels(in: root.view))"
        }) {
            inboxRow = shellAccessibilityNodes(in: root.view).first {
                guard $0.accessibilityTraits.contains(.button), let label = $0.accessibilityLabel else { return false }
                return label.contains("Renamed e\u{301} bot") && label.contains("Current reply 3")
            }
            return inboxRow != nil
        }
        #expect(!shellAccessibilityLabels(in: try #require(inboxRow)).contains { $0.contains("Latest roster preview 3") },
                "A current chat preview takes precedence over the unrelated roster excerpt")
        #expect(store.history.bots.first?.preview == "Latest roster preview 3")
        #expect(store.history.bots.first?.updatedAt == Date(timeIntervalSince1970: 103))
    }

    @Test func nativeRootControlsUseReplacementOpaqueCallbacksWithOtherwiseEqualInputs() async throws {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://shell-callbacks.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let state = ShellCallbackFixture()
        let presentation = WorkspacePresentation()
        let window = try await attach(ShellCallbackHost(store: store, presentation: presentation, state: state))
        defer { window.close() }
        let root = try #require(window.rootViewController)
        try await waitUntil("Both native root controls are available", diagnostics: {
            shellAccessibilityLabels(in: root.view).joined(separator: "\n")
        }) {
            shellHasControl(named: "Settings", in: root) && shellHasControl(named: "New bot", in: root)
        }
        state.replacement = true
        try await waitUntil { state.renderedReplacement }
        let display = ShellCallbackDisplayFrames()
        defer { display.stop() }
        await display.nextFrame()
        window.layoutIfNeeded()
        try await waitUntil("The replacement host reached native layout", diagnostics: {
            "probeVersion=\(state.renderProbe?.laidOutVersion.description ?? "nil") attached=\(state.renderProbe?.window === window)"
        }) { state.renderProbe?.window === window && state.renderProbe?.laidOutVersion == 2 }
        await display.nextFrame()
        window.layoutIfNeeded()
        try activateShellBarButton(named: "Settings", in: root)
        try activateShellBarButton(named: "New bot", in: root)
        try await waitUntil("Both native actions deliver their callbacks", diagnostics: {
            "settings=\(state.settings) newBots=\(state.newBots)"
        }) { !state.settings.isEmpty && !state.newBots.isEmpty }
        #expect(state.settings == [2] && state.newBots == [2],
            "Only replacement callbacks may run: settings=\(state.settings), newBots=\(state.newBots)")
    }

    @Test(arguments: [false, true])
    func retainedEditorRechecksRosterPresenceBeforeTheNextNativeLayout(compact: Bool) async throws {
        let service = try ShellRosterService()
        service.base.base.directoryComplete = false
        let main = service.base.base.summaries[0].identity
        service.base.base.snapshots[main.root]?.pendingRequests = [.init(id: "shell-held-request", kind: .approval, title: "Held request")]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://shell-roster-removal.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let window = try await attach(AdaptiveWorkspace(store: store, presentation: presentation,
            rootCovered: false, onSettings: {}, onNewBot: {}), compact: compact,
            logicalSize: compact ? nil : CGSize(width: 1000, height: 700))
        defer { window.close() }
        let root = try #require(window.rootViewController)
        await store.open(try #require(store.bots.first))
        try await waitUntil("The existing editor admits native input") {
            nativeTextViews(in: root.view).contains { $0 is NativeComposerTextView && $0.isEditable }
        }
        let editor = try #require(nativeTextViews(in: root.view).compactMap { $0 as? NativeComposerTextView }.first { $0.isEditable })
        let owner = try #require(store.chats.screen(profile: service.base.base.profile)?.owner)
        try await waitUntil("The actual native request action is enabled before roster removal") {
            shellRequestActions(in: root).contains { $0.enabled }
        }
        let request = try #require(shellRequestActions(in: root).first { $0.enabled })
        editor.text = "Before removal"
        editor.textViewDidChange(editor)
        try #require(store.chats.draft(owner) == "Before removal", "The retained native callback must admit a positive edit before roster removal")
        service.includesProfile = false
        let entry = ShellRosterCallback(store: store, profile: service.base.base.profile)
        await confirmation("Roster commit invokes the retained editor before the native tree can replace it") { changed in
            entry.onRemoval = { [weak entry] in
                guard let entry else { return }
                changed()
                #expect(store.selectedBotID == service.base.profile.id && store.selectedBot == nil)
                #expect(editor.window === window && request.lifetime.isCurrent)
                editor.text = "After removal"
                editor.textViewDidChange(editor)
                entry.draft = store.chats.draft(owner)
                entry.requestEnabled = request.enabled
            }
            entry.arm()
            await store.refresh()
            entry.onRemoval = nil
        }
        #expect(entry.entered)
        #expect(entry.draft == "After removal", "Chat-only editing preserves the existing unknown-handoff policy at either width")
        #expect(entry.requestEnabled == !compact, "Compact row actions recheck fresh roster presence; wide policy does not add a presence restriction")
    }

    @Test func allocationUsesReadableDetailWidthsWithoutChoosingAModal() {
        func panes(_ width: CGFloat, compact: Bool = false, largeText: Bool = false,
                   browsing: Bool = false, expanded: Bool = false) -> WorkspacePaneAllocation {
            WorkspaceLayout(compact: compact, accessibilityText: largeText, workspaceWidth: width)
                .allocation(hasArtifact: true, browsingBots: browsing, expanded: expanded)
        }
        #expect(panes(951) == WorkspacePaneAllocation(chatWidth: 570, artifactWidth: 380))
        #expect(panes(681) == WorkspacePaneAllocation(chatWidth: 360, artifactWidth: 320))
        #expect(panes(680) == WorkspacePaneAllocation(chatWidth: 0, artifactWidth: 680))
        #expect(panes(669) == WorkspacePaneAllocation(chatWidth: 0, artifactWidth: 669))
        #expect(panes(466, compact: true) == WorkspacePaneAllocation(chatWidth: 0, artifactWidth: 466))
        #expect(panes(1200, largeText: true) == WorkspacePaneAllocation(chatWidth: 0, artifactWidth: 1200))
        #expect(panes(951, expanded: true) == WorkspacePaneAllocation(chatWidth: 0, artifactWidth: 951))
        #expect(panes(951, browsing: true, expanded: true) == WorkspacePaneAllocation(chatWidth: 951, artifactWidth: 0))
    }

    @Test func onlyActuallyReadableChatCanSupplyReadEvidence() {
        let wide = WorkspaceLayout(compact: false, accessibilityText: false, workspaceWidth: 951)
        let narrow = WorkspaceLayout(compact: true, accessibilityText: false, workspaceWidth: 466)
        func exposed(_ layout: WorkspaceLayout, browse: Bool = false, file: Bool = false, expand: Bool = false,
                     root: Bool = false, local: Bool = false, active: Bool = true) -> Bool {
            layout.transcriptExposed(browsingBots: browse, hasArtifact: file, expanded: expand,
                rootCovered: root, localCovered: local, sceneActive: active, compactShowsSidebar: browse)
        }
        #expect(exposed(wide, file: true))
        #expect(exposed(wide, browse: true, file: true))
        #expect(!exposed(narrow, browse: true))
        #expect(!exposed(narrow, file: true))
        #expect(!exposed(wide, file: true, expand: true))
        #expect(!exposed(wide, root: true))
        #expect(!exposed(wide, local: true))
        #expect(!exposed(wide, active: false))
        #expect(exposed(narrow))
    }
    /// Mount the production split and both outgoing/incoming ChatViews. This
    /// catches disappearance retirement invalidating the incoming opening intent.
    @Test func nativeSplitSelectionKeepsIncomingOpeningCaptureValid() async throws {
        let store = AppStore(service: DemoBotService(), persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-split-demo.invalid")!)
        #expect(await store.connect(configuration))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await waitUntil {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .contains { $0.activationState == .foregroundActive }
        }
        let presentation = WorkspacePresentation()
        let window = try await attach(AdaptiveWorkspace(store: store, presentation: presentation,
            rootCovered: false, onSettings: {}, onNewBot: {}))
        defer { window.close() }
        let firstRevision = presentation.revision
        await store.open(try #require(store.bots.first { $0.id == "milo" }))
        try await waitUntil { presentation.revision != firstRevision }
        let milo = try #require(store.chats.screen(profile: try ExactID("milo")))
        store.chats.editDraft("  Milo keeps this draft\n", owner: milo.owner)
        window.layoutIfNeeded()
        let selectedRevision = presentation.revision
        store.selectedBotID = "canvas"
        let workspace = store.chats
        let opening = try #require(workspace.captureOpening(profile: try ExactID("canvas"), attention: false))
        presentation.didChooseConversation()
        let capturedGeneration = store.artifactGeneration
        let capturedRevision = presentation.revision
        try await waitUntil { presentation.revision != capturedRevision }
        #expect(store.artifactGeneration == capturedGeneration, "Outgoing view disappearance must not retire the captured opening")
        await workspace.open(opening)
        try await waitUntil {
            presentation.revision != selectedRevision &&
                workspace.screen(profile: try! ExactID("canvas"))?.canAct == true
        }
        window.layoutIfNeeded()
        for _ in 0..<100 { await Task.yield() }
        let canvas = try #require(workspace.screen(profile: try ExactID("canvas")))
        #expect(canvas.canAct && !canvas.isOpening && canvas.snapshot?.messages.isEmpty == false)
        #expect(workspace.draft(canvas.owner).isEmpty)
        await store.open(try #require(store.bots.first { $0.id == "milo" }))
        let returned = try #require(workspace.screen(profile: try ExactID("milo")))
        #expect(returned.canAct && workspace.draft(returned.owner) == "  Milo keeps this draft\n")
    }


    @Test(arguments: [false, true])
    func openingCachedChatClearsUnreadAfterIdenticalLiveReadCompletes(covered: Bool) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true,
            persistence: .durable, messageCount: 4)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-unread-open.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        let bot = try #require(store.bots.first)
        await store.open(bot)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let before = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(before.owner)
        try #require(store.chats.cards(profile: service.profile).first?.unread == true)

        let read = WorkspaceGate(); service.openGate = read
        defer { read.release() }
        let opening = Task { await store.chats.openBot(profile: service.profile) }
        await read.entered()
        let coverage = ChatCoverageFixture(); coverage.covered = covered
        let window = try await attach(ChatCoverageHost(store: store, bot: bot, state: coverage))
        defer { window.close() }
        try #require(store.chats.screen(profile: service.profile)?.isOpening == true)
        #expect(store.chats.cards(profile: service.profile).first?.unread == true)
        let directoryCalls = service.directoryCalls
        read.release(); await opening.value; service.openGate = nil
        #expect(store.chats.screen(profile: service.profile)?.snapshot == before.snapshot)
        try await waitUntil("The completed opening refreshes the chat directory") {
            service.directoryCalls > directoryCalls
        }
        if covered {
            #expect(store.chats.cards(profile: service.profile).first?.unread == true)
            coverage.covered = false
        }
        try await waitUntil("A visible completed read clears unread even when cached content is identical") {
            store.chats.cards(profile: service.profile).first?.unread == false
        }
    }

    @Test func visibleChatClearsUnreadWhenDirectoryEvidenceArrivesAfterOpening() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true,
            persistence: .durable, messageCount: 4)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-unread-directory.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let directory = WorkspaceGate(); service.directoryGate = directory
        defer { directory.release() }
        let window = try await attach(ChatCoverageHost(store: store, bot: try #require(store.bots.first), state: ChatCoverageFixture()))
        defer { window.close() }
        await directory.entered()
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true,
            persistence: .durable, messageCount: 6)
        directory.release(); service.directoryGate = nil
        try await waitUntil("The visible chat reads and acknowledges the newer directory observation") {
            store.chats.persisted().records.first?.seen?.summary?.messageCount == 6
                && store.chats.cards(profile: service.profile).first?.unread == false
        }
        #expect(service.opens.count == 2)
    }

    @Test func coveredChatCannotStartReadWhenItsHeldDirectoryTaskReturns() async throws {
        let service = try WorkspaceTestService(), main = service.summaries[0].identity
        service.summaries[0] = .init(identity: main, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 4)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-covered-chat.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let directory = WorkspaceGate(); service.directoryGate = directory
        let state = ChatCoverageFixture()
        let window = try await attach(ChatCoverageHost(store: store, bot: try #require(store.bots.first), state: state))
        defer { directory.release(); window.close() }
        await directory.entered()
        state.covered = true
        try await waitUntil { state.observedCover }
        service.summaries[0] = .init(identity: main, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 6)
        directory.release(); service.directoryGate = nil
        try await waitUntil { store.chats.screen(profile: service.profile)?.isLoadingDirectory == false }
        for _ in 0..<100 { await Task.yield() }
        try #require(service.opens.count == 1, "An old async completion cannot expose a covered chat")
        #expect(store.chats.cards(profile: service.profile).first?.unread == true)
        let read = WorkspaceGate(); service.openGate = read
        state.covered = false
        await read.entered()
        #expect(service.opens.count == 2, "Returning to a readable chat may admit the deferred read")
        read.release()
    }

    @Test func actualNativeSidebarOverlayCannotSupplyReadEvidenceFromHeldInventory() async throws {
        let service = try WorkspaceTestService(), main = service.summaries[0].identity
        service.summaries[0] = .init(identity: main, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 4)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-overlay-read.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        await store.open(try #require(store.bots.first))
        let native = WorkspaceNativeDetailState()
        let directory = WorkspaceGate(); service.directoryGate = directory
        defer { directory.release() }
        let window = try await attach(Color.clear)
        defer { window.close() }
        let split = UISplitViewController(style: .doubleColumn)
        split.traitOverrides.horizontalSizeClass = .regular
        split.minimumPrimaryColumnWidth = 160; split.maximumPrimaryColumnWidth = 160
        split.preferredSplitBehavior = .overlay; split.preferredDisplayMode = .oneOverSecondary
        split.setViewController(UINavigationController(rootViewController: UIViewController()), for: .primary)
        let host = UIHostingController(rootView: NativeReadCoverageHost(store: store,
            bot: try #require(store.bots.first), presentation: presentation, native: native))
        split.setViewController(UINavigationController(rootViewController: host), for: .secondary)
        let projection = NativeReadProjection(state: native)
        split.delegate = projection
        window.rootViewController = split; window.makeKeyAndVisible(); window.layoutIfNeeded()
        await directory.entered()
        try await waitUntil("Native regular split settled before overlay") { !split.isCollapsed && host.view.window === window && split.transitionCoordinator == nil }
        split.show(.primary)
        try await waitUntil("Actual native primary covers the detail") { split.displayMode == .oneOverSecondary }
        service.summaries[0] = .init(identity: main, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 6)
        let read = WorkspaceGate(); service.openGate = read
        defer { read.release() }
        directory.release(); service.directoryGate = nil
        try await waitUntil("Held inventory completed behind actual native overlay") {
            store.chats.screen(profile: service.profile)?.isLoadingDirectory == false
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(service.opens.count == 1, "The native overlay must fence optional read admission before held inventory returns")
        #expect(store.chats.cards(profile: service.profile).first?.unread == true)
        split.hide(.primary)
        try await waitUntil("Actual native sidebar dismissed") { split.displayMode == .secondaryOnly }
        try await waitUntil("Uncovered native detail admits the deferred read") { service.opens.count == 2 }
        #expect(!presentation.isBrowsingBots && presentation.artifact == nil)
        #expect(split.delegate === projection)
    }

    @Test func nativeCompactBackParksTheTaskAndReturnKeepsItsOwnerAndDraft() async throws {
        #if DEBUG
        let store = AvatarDecodeLedger.$testOwner.withValue(Test.current.map { "AdaptiveWorkspaceTests/\($0.name)" }) {
            AppStore(service: DemoBotService(), persistence: MemoryConnectionStorage().persistence)
        }
        #else
        let store = AppStore(service: DemoBotService(), persistence: MemoryConnectionStorage().persistence)
        #endif
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-back-demo.invalid")!)
        #expect(await store.connect(configuration))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let window = try await attach(AdaptiveWorkspace(store: store, presentation: presentation,
            rootCovered: false, onSettings: {}, onNewBot: {}), compact: true)
        defer { window.close() }
        let firstRevision = presentation.revision
        await store.open(try #require(store.bots.first { $0.id == "milo" }))
        let diagnostics = { nativeNavigationState(window: window, presentation: presentation, store: store) }
        try await waitUntil("Selected detail entered the native stack", diagnostics: diagnostics) {
            presentation.revision != firstRevision &&
                navigationControllers(in: window.rootViewController!).contains { $0.viewControllers.count > 1 }
        }
        Attachment.record(diagnostics(), named: "native-back-before-settle.txt")
        // Stack membership changes when the declarative push starts. A native
        // Back action must wait until that push and initial layout have finished.
        try await waitUntil("Selected detail completed its native transition", diagnostics: diagnostics) {
            settledDetailNavigation(in: window) != nil
        }
        let owner = try #require(store.chats.screen(profile: try ExactID("milo"))?.owner)
        store.chats.editDraft("  Native Back keeps this draft\n", owner: owner)
        let generation = store.artifactGeneration
        let editor = try #require(nativeTextViews(in: window).compactMap { $0 as? NativeComposerTextView }.first)
        try await waitUntil("The actual native composer is editable before Back") { editor.isEditable && editor.window === window }
        #expect(editor.becomeFirstResponder())
        try await waitUntil("Focused composer and native navigation settled before Back") {
            editor.isFirstResponder && settledDetailNavigation(in: window) != nil
        }
        let navigation = try #require(settledDetailNavigation(in: window))
        Attachment.record(diagnostics(), named: "native-back-ready.txt")
        _ = try #require(navigation.popViewController(animated: false))
        Attachment.record(diagnostics(), named: "native-back-popped.txt")
        try await waitUntil("Native Back reported temporary browsing", diagnostics: diagnostics) {
            presentation.isBrowsingBots && navigation.transitionCoordinator == nil
        }
        #expect(store.selectedBotID == "milo" && store.artifactGeneration == generation)
        #expect(!editor.isFirstResponder, "Native Back ends the actual editing session")
        #expect(store.chats.isCurrent(owner))
        presentation.resumeTask()
        try await waitUntil("Return restored a settled native detail", diagnostics: {
            diagnostics() + "\n" + nativeTransitionProgress(in: window)
        }) {
            settledDetailNavigation(in: window) != nil
        }
        Attachment.record(diagnostics(), named: "native-back-returned.txt")
        #expect(store.chats.draft(owner) == "  Native Back keeps this draft\n")
        #expect(store.chats.isCurrent(owner) && store.artifactGeneration == generation)
    }

    private func settledDetailNavigation(in window: UIWindow) -> UINavigationController? {
        guard window.isKeyWindow, !window.isHidden, let root = window.rootViewController else { return nil }
        window.layoutIfNeeded()
        return navigationControllers(in: root).first { navigation in
            guard navigation.viewControllers.count > 1, let top = navigation.topViewController else { return false }
            return navigation.viewIfLoaded?.window === window && top.viewIfLoaded?.window === window &&
                navigation.transitionCoordinator == nil && top.transitionCoordinator == nil &&
                !top.isBeingPresented && !top.isMovingToParent &&
                navigation.navigationBar.topItem === top.navigationItem
        }
    }

    private func nativeNavigationState(window: UIWindow, presentation: WorkspacePresentation, store: AppStore) -> String {
        guard let root = window.rootViewController else { return "Fixture has no root controller" }
        let controllers = navigationControllers(in: root).map { navigation in
            let top = navigation.topViewController
            return "navigation=\(type(of: navigation)) count=\(navigation.viewControllers.count) attached=\(navigation.viewIfLoaded?.window === window) transition=\(navigation.transitionCoordinator != nil) top=\(top.map { String(reflecting: type(of: $0)) } ?? "nil") topAttached=\(top?.viewIfLoaded?.window === window) topTransition=\(top?.transitionCoordinator != nil)"
        }
        return "key=\(window.isKeyWindow) hidden=\(window.isHidden) bounds=\(window.bounds) rootAppeared=\((root as? WorkspaceHostingAppearance)?.hasAppeared == true) rootTransition=\(root.transitionCoordinator != nil) selected=\(store.selectedBotID ?? "nil") browsing=\(presentation.isBrowsingBots) revision=\(presentation.revision)\n" + controllers.joined(separator: "\n")
    }

    private func nativeTransitionProgress(in window: UIWindow) -> String {
        guard let root = window.rootViewController else { return "No root for transition progress" }
        func state(_ coordinator: (any UIViewControllerTransitionCoordinator)?) -> String {
            guard let coordinator else { return "none" }
            return "duration=\(coordinator.transitionDuration) percent=\(coordinator.percentComplete) interactive=\(coordinator.isInteractive) initiallyInteractive=\(coordinator.initiallyInteractive) cancelled=\(coordinator.isCancelled)"
        }
        return navigationControllers(in: root).map { navigation in
            let top = navigation.topViewController
            return "topPresented=\(top?.isBeingPresented ?? false) topMovingToParent=\(top?.isMovingToParent ?? false) barTopMatches=\(top.map { navigation.navigationBar.topItem === $0.navigationItem } ?? false) navigationTransition={\(state(navigation.transitionCoordinator))} topTransition={\(state(top?.transitionCoordinator))}"
        }.joined(separator: "\n")
    }

    private func navigationControllers(in controller: UIViewController) -> [UINavigationController] {
        ((controller as? UINavigationController).map { [$0] } ?? [])
            + controller.children.flatMap { navigationControllers(in: $0) }
    }

    @Test func nativeSplitWithNoSelectionShowsTheInbox() async throws {
        let store = AppStore(service: DemoBotService(), persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-inbox-demo.invalid")!)
        #expect(await store.connect(configuration))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let window = try await attach(AdaptiveWorkspace(store: store, presentation: presentation,
            rootCovered: false, onSettings: {}, onNewBot: {}))
        defer { window.close() }
        try await waitUntil {
            splitControllers(in: window.rootViewController!).contains { split in
                split.displayMode != .secondaryOnly && split.viewController(for: .primary)?.viewIfLoaded?.window === window
            }
        }
        #expect(store.selectedBotID == nil && presentation.artifact == nil)
    }

    private func splitControllers(in controller: UIViewController) -> [UISplitViewController] {
        ((controller as? UISplitViewController).map { [$0] } ?? [])
            + controller.children.flatMap { splitControllers(in: $0) }
    }

    @Test func allocationRespondsToTraitOnlyChangesAtFixedBounds() async throws {
        let state = LayoutObservationFixture()
        let window = try await attach(LayoutObservationHost(state: state), logicalSize: CGSize(width: 1000, height: 700))
        defer { window.close() }
        try await waitUntil("Initial regular geometry observed") { state.latest?.compact == false }
        let width = try #require(state.latest?.workspaceWidth)
        #expect(state.latest?.allocation(hasArtifact: true, browsingBots: false, expanded: false).paired == true)
        let controller = try #require(window.rootViewController?.children.first)
        controller.traitOverrides.horizontalSizeClass = .compact
        try await waitUntil("Trait-only compact change observed") { state.latest?.compact == true }
        #expect(state.latest?.workspaceWidth == width)
        #expect(state.latest?.allocation(hasArtifact: true, browsingBots: false, expanded: false).chatVisible == false)
        controller.traitOverrides.horizontalSizeClass = .regular
        try await waitUntil("Regular allocation restored without resizing") { state.latest?.compact == false }
        #expect(state.latest?.allocation(hasArtifact: true, browsingBots: false, expanded: false).paired == true)
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await waitUntil("Trait-only accessibility text change observed") { state.latest?.accessibilityText == true }
        #expect(state.latest?.workspaceWidth == width)
        #expect(state.latest?.allocation(hasArtifact: true, browsingBots: false, expanded: false).chatVisible == false)
    }

    @Test func nativeWideSidebarFeedbackDoesNotParkTheRetainedFile() async throws {
        let service = try WorkspaceTestService()
        service.downloadData = nativePDFBytes()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-sidebar-feedback.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let window = try await attach(AdaptiveWorkspace(store: store, presentation: presentation,
            rootCovered: false, onSettings: {}, onNewBot: {}), logicalSize: CGSize(width: 1000, height: 700))
        defer { window.close() }
        let selectionRevision = presentation.revision
        await store.open(try #require(store.bots.first))
        try await waitUntil("Hosted selection finished before the file tap") { presentation.revision != selectionRevision }
        let destination = try #require(store.artifactDestination(for: .init(name: "report.pdf", path: "/report.pdf", mimeType: "application/pdf"), botID: service.profile.text))
        presentation.openArtifact(destination, store: store)
        let session = try #require(presentation.artifact)
        try await waitUntil("File loaded in the retained task", diagnostics: {
            "current=\(session.isCurrent) loading=\(session.isLoading) file=\(session.file != nil) error=\(session.errorMessage ?? "nil") presented=\(presentation.artifact === session) downloads=\(service.downloads)\n\(self.nativeNavigationState(window: window, presentation: presentation, store: store))"
        }) { session.file != nil }
        let split = try #require(splitControllers(in: window.rootViewController!).first)
        try await waitUntil("File presentation has hidden the native sidebar") { split.displayMode == .secondaryOnly }
        UIView.performWithoutAnimation {
            split.show(.primary)
            window.layoutIfNeeded()
        }
        try await waitUntil("Native visibility feedback leaves primary hidden and both content panes readable", diagnostics: {
            "displayMode=\(split.displayMode.rawValue) readerBounds=\(self.readers(in: window.rootViewController!).map { $0.view.bounds }) browsing=\(presentation.isBrowsingBots)"
        }) {
            split.displayMode == .secondaryOnly &&
                self.readers(in: window.rootViewController!).contains { $0.view.bounds.width >= 320 && $0.view.bounds.width <= 380 }
        }
        #expect(!presentation.isBrowsingBots, "Native visibility feedback is not a deliberate Bots action")
        #expect(presentation.artifact === session && session.isCurrent && service.downloads == 1)
        presentation.browseBots()
        #expect(presentation.isBrowsingBots && presentation.artifact === session, "The explicit Bots action still parks the task")
        presentation.resumeTask()
        #expect(!presentation.isBrowsingBots && presentation.artifact === session)
        presentation.closeArtifact(id: session.id)
    }

    @Test func oneQuickLookPDFSurvivesFullWidthReturnAndParking() async throws {
        let service = try WorkspaceTestService()
        service.downloadData = nativePDFBytes()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://retained-native-reader.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let window = try await attach(AdaptiveWorkspace(store: store, presentation: presentation,
            rootCovered: false, onSettings: {}, onNewBot: {}), logicalSize: CGSize(width: 1000, height: 700))
        defer { window.close() }
        let selectedRevision = presentation.revision
        await store.open(try #require(store.bots.first))
        try await waitUntil("Hosted bot selection settled") { presentation.revision != selectedRevision }
        let destination = try #require(store.artifactDestination(for: .init(name: "report.pdf", path: "/report.pdf", mimeType: "application/pdf"), botID: service.profile.text))
        presentation.openArtifact(destination, store: store)
        let session = try #require(presentation.artifact)
        try await waitUntil("One native reader loaded in the paired workspace", diagnostics: {
            "current=\(session.isCurrent) loading=\(session.isLoading) file=\(session.file != nil) error=\(session.errorMessage ?? "nil") presented=\(presentation.artifact === session) downloads=\(service.downloads) readers=\(self.readers(in: window.rootViewController!).count)\n\(self.nativeNavigationState(window: window, presentation: presentation, store: store))"
        }) {
            session.file != nil && self.readers(in: window.rootViewController!).count == 1
        }
        let original = try #require(readers(in: window.rootViewController!).first)
        let nativeOwner = try #require(original.navigationController)
        try #require(nativeOwner.topViewController === original,
            "The retained reader has its own native pushed navigation owner")
        #expect(nativeOwner.isNavigationBarHidden && nativeOwner.isToolbarHidden)
        try verifyReaderBarVisibilityPolicy(nativeOwner)
        presentation.setArtifactExpanded(true, id: session.id)
        try await waitUntil("Reader received full detail bounds") {
            self.readers(in: window.rootViewController!).contains { $0 !== original || $0.view.bounds.width > 600 }
        }
        let expanded = readers(in: window.rootViewController!)
        try #require(expanded.count == 1 && expanded.first === original,
            "Full width reallocates the original QL controller; it must not create a second reader")
        presentation.setArtifactExpanded(false, id: session.id)
        try await waitUntil("Reader returned to readable paired bounds") { original.view.bounds.width <= 520 }
        let host = try #require(window.rootViewController?.children.first)
        let geometryRevision = presentation.revision
        let generation = store.artifactGeneration
        let owner = try #require(store.chats.screen(profile: service.profile)?.owner)
        store.chats.editDraft("  Retained across real bounds changes\n", owner: owner)
        // These are actual callback-free view-bounds changes, not fabricated
        // layout-policy values or native transition-coordinator completions.
        let narrowDetailWidth: CGFloat = 680
        host.view.bounds.size = CGSize(width: narrowDetailWidth, height: 700)
        host.view.setNeedsLayout(); window.layoutIfNeeded()
        try await waitUntil("A narrow regular detail allocates the original reader full width", diagnostics: {
            "hostBounds=\(host.view.bounds) hostFrame=\(host.view.frame) readerBounds=\(original.view.bounds) splitMode=\(splitControllers(in: window.rootViewController!).first?.displayMode.rawValue.description ?? "nil")"
        }) {
            original.view.bounds.width > 520
        }
        #expect(abs(original.view.bounds.width - narrowDetailWidth) < 1,
                "Below the paired-layout threshold, the retained PDF occupies the actual detail width")
        #expect(readers(in: window.rootViewController!).count == 1)
        #expect(host.presentedViewController == nil, "Fit never creates a modal presenter")
        host.view.bounds.size = CGSize(width: 1000, height: 700)
        host.view.setNeedsLayout(); window.layoutIfNeeded()
        try await waitUntil("Widening restores paired allocation without a coordinator") { original.view.bounds.width <= 520 }
        #expect(presentation.revision == geometryRevision && store.artifactGeneration == generation)
        #expect(service.downloads == 1 && store.chats.draft(owner) == "  Retained across real bounds changes\n")
        presentation.browseBots()
        let split = try #require(splitControllers(in: window.rootViewController!).first)
        try await waitUntil("Wide Bots completed native sidebar presentation") {
            presentation.isBrowsingBots && split.displayMode != .secondaryOnly &&
                self.navigationControllers(in: window.rootViewController!).allSatisfy { $0.transitionCoordinator == nil }
        }
        #expect(original.parent != nil && original.view.bounds.width > 0,
                "Parking retains the native reader and useful bounds")
        presentation.resumeTask()
        try await waitUntil("Wide Return exposes the exact original paired reader") {
            split.displayMode == .secondaryOnly && original.view.bounds.width <= 380 &&
                self.readers(in: window.rootViewController!).contains { $0 === original }
        }
        #expect(readers(in: window.rootViewController!).count == 1)
        #expect(original.navigationController === nativeOwner && nativeOwner.topViewController === original)
        #expect(service.downloads == 1 && presentation.artifact === session)
        presentation.closeArtifact(id: session.id)
    }

    /// Compact navigation uses the actual scene-sized window. Forcing a compact
    /// UIKit split into the scaled 1000-point geometry fixture produces overlapping
    /// native push/pop transitions and is not a valid compact navigation setup.
    @Test func compactBotsAndReturnKeepTheSameQuickLookPDFAndDraft() async throws {
        let service = try WorkspaceTestService()
        service.downloadData = nativePDFBytes()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://compact-retained-reader.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let window = try await attach(AdaptiveWorkspace(store: store, presentation: presentation,
            rootCovered: false, onSettings: {}, onNewBot: {}), compact: true)
        defer { window.close() }
        await store.open(try #require(store.bots.first))
        try await waitUntil("Compact detail settled before opening its file") { self.settledDetailNavigation(in: window) != nil }
        let navigation = try #require(settledDetailNavigation(in: window))
        let owner = try #require(store.chats.screen(profile: service.profile)?.owner)
        store.chats.editDraft("  Compact file keeps this draft\n", owner: owner)
        let destination = try #require(store.artifactDestination(for: .init(name: "report.pdf", path: "/report.pdf", mimeType: "application/pdf"), botID: service.profile.text))
        presentation.openArtifact(destination, store: store)
        let session = try #require(presentation.artifact)
        try await waitUntil("Compact native reader loaded") {
            session.file != nil && self.readers(in: window.rootViewController!).count == 1
        }
        let original = try #require(readers(in: window.rootViewController!).first)
        let nativeOwner = try #require(original.navigationController)
        try #require(nativeOwner.topViewController === original)
        #expect(nativeOwner.isNavigationBarHidden && nativeOwner.isToolbarHidden)
        try verifyReaderBarVisibilityPolicy(nativeOwner)
        presentation.browseBots()
        try await waitUntil("Compact Bots completed its native pop") {
            presentation.isBrowsingBots && navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil
        }
        #expect(original.parent != nil && original.view.bounds.width > 0)
        #expect(presentation.artifact === session && session.isCurrent)
        presentation.resumeTask()
        try await waitUntil("Compact Return reattached the original reader") {
            self.settledDetailNavigation(in: window) != nil &&
                self.readers(in: window.rootViewController!).contains { $0 === original }
        }
        #expect(readers(in: window.rootViewController!).count == 1 && service.downloads == 1)
        #expect(original.navigationController === nativeOwner && nativeOwner.topViewController === original)
        #expect(store.chats.draft(owner) == "  Compact file keeps this draft\n")
        presentation.closeArtifact(id: session.id)
    }

    @Test func plainTextUsesOneLocalSelectableViewAcrossExtentAndParking() async throws {
        let service = try WorkspaceTestService()
        let text = "Canvas demo\n\nNative notes remain readable. café 🦊\n"
        service.downloadData = Data(text.utf8)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-plain-text.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let window = try await attach(AdaptiveWorkspace(store: store, presentation: presentation,
            rootCovered: false, onSettings: {}, onNewBot: {}), logicalSize: CGSize(width: 1000, height: 700))
        defer { window.close() }
        let selected = presentation.revision
        await store.open(try #require(store.bots.first))
        try await waitUntil("Selected native text workspace settled") { presentation.revision != selected }
        let destination = try #require(store.artifactDestination(for: .init(name: "notes.txt", path: "/notes.txt", mimeType: "text/plain"), botID: service.profile.text))
        presentation.openArtifact(destination, store: store)
        let session = try #require(presentation.artifact)
        try await waitUntil("Actual local native text is readable without a recovery toggle", diagnostics: {
            "current=\(session.isCurrent) loading=\(session.isLoading) file=\(session.file != nil) error=\(session.errorMessage ?? "nil") presented=\(presentation.artifact === session) downloads=\(service.downloads) textViews=\(self.nativeTextViews(in: window).count)\n\(self.nativeNavigationState(window: window, presentation: presentation, store: store))"
        }) {
            self.nativeTextViews(in: window).contains { $0.text == text && !$0.isHidden }
        }
        let original = try #require(nativeTextViews(in: window).first { $0.text == text })
        #expect(!original.isEditable && original.isSelectable && original.dataDetectorTypes.isEmpty)
        #expect(readers(in: window.rootViewController!).isEmpty, "Plain text must not enter the failing QL text backend")
        original.selectedRange = NSRange(location: 0, length: 11)
        presentation.setArtifactExpanded(true, id: session.id)
        try await waitUntil("Native text expanded in place") { original.bounds.width > 600 }
        #expect(original.text == text && original.selectedRange == NSRange(location: 0, length: 11))
        presentation.setArtifactExpanded(false, id: session.id)
        try await waitUntil("Native text returned to paired width") { original.bounds.width <= 380 }
        presentation.browseBots(); presentation.resumeTask()
        try await waitUntil("Native text returned without reconstruction") {
            self.nativeTextViews(in: window).contains { $0 === original }
        }
        #expect(original.text == text && service.downloads == 1 && presentation.artifact === session)
        #expect(session.file?.data == Data(text.utf8))
        presentation.closeArtifact(id: session.id)
    }

    private func shellTranscripts(in controller: UIViewController) -> [NativeTranscriptController] {
        ((controller as? NativeTranscriptController).map { [$0] } ?? [])
            + controller.children.flatMap { shellTranscripts(in: $0) }
    }
    private func shellRequestActions(in controller: UIViewController) -> [RequestCardActions] {
        shellTranscripts(in: controller).flatMap { transcript in
            transcript.collection.visibleCells.compactMap { ($0 as? NativeTranscriptCell)?.exposure?.requestActions }
        }
    }
    private func shellAccessibilityNodes(in root: NSObject) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        func visit(_ object: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            var children: [NSObject] = []
            if let view = object as? UIView { children += view.subviews }
            children += (object.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            children += (object.automationElements ?? []).compactMap { $0 as? NSObject }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 4096 {
                children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
            return [object] + children.flatMap(visit)
        }
        return visit(root)
    }
    private func shellAccessibilityLabels(in root: NSObject) -> [String] {
        shellAccessibilityNodes(in: root).flatMap { object in
            [object.accessibilityLabel, object.accessibilityValue, (object as? UILabel)?.text].compactMap { $0 }
        }
    }
    private func shellToolbarItems(in controller: UIViewController) -> [UIBarButtonItem] {
        var seen: Set<ObjectIdentifier> = []
        return navigationControllers(in: controller).flatMap { navigation in
            let items = (navigation.navigationBar.items ?? []) + navigation.viewControllers.map(\.navigationItem)
            var buttons: [UIBarButtonItem] = []
            for item in items {
                buttons.append(contentsOf: item.leftBarButtonItems ?? [])
                buttons.append(contentsOf: item.rightBarButtonItems ?? [])
                buttons.append(contentsOf: item.leadingItemGroups.flatMap(\.barButtonItems))
                buttons.append(contentsOf: item.centerItemGroups.flatMap(\.barButtonItems))
                buttons.append(contentsOf: item.trailingItemGroups.flatMap(\.barButtonItems))
            }
            buttons.append(contentsOf: navigation.toolbar.items ?? [])
            return buttons.filter { seen.insert(ObjectIdentifier($0)).inserted }
        }
    }
    private func shellButtonMatches(_ name: String, object: NSObject) -> Bool {
        object.accessibilityLabel == name || (object as? UIButton)?.currentTitle == name
            || (object as? UILabel)?.text == name
    }
    private func shellBarButton(named name: String, in controller: UIViewController) -> UIBarButtonItem? {
        shellToolbarItems(in: controller).first { button in
            button.title == name || button.accessibilityLabel == name
                || button.customView.map { view in shellAccessibilityNodes(in: view).contains { shellButtonMatches(name, object: $0) } } == true
        }
    }
    private func shellHasControl(named name: String, in controller: UIViewController) -> Bool {
        shellBarButton(named: name, in: controller) != nil || shellAccessibilityNodes(in: controller.view).contains {
            shellButtonMatches(name, object: $0) && $0.accessibilityTraits.contains(.button)
        }
    }
    private func activateShellBarButton(named name: String, in controller: UIViewController) throws {
        let button = shellBarButton(named: name, in: controller)
        if let button, let action = button.action {
            #expect(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil))
            return
        }
        let nodes = button?.customView.map { shellAccessibilityNodes(in: $0) }
            ?? shellAccessibilityNodes(in: controller.view)
        if let control = nodes.compactMap({ $0 as? UIControl }).first(where: {
            shellButtonMatches(name, object: $0) && !$0.allTargets.isEmpty
        }) {
            control.sendActions(for: control.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside)
            return
        }
        for element in nodes where shellButtonMatches(name, object: element) && element.accessibilityTraits.contains(.button) {
            if element.accessibilityActivate() { return }
        }
        Issue.record("The native toolbar bridge exposes neither target/action nor an activatable accessibility control; use the UI-test route for callback replacement")
    }

    private func nativeTextViews(in view: UIView) -> [UITextView] {
        ((view as? UITextView).map { [$0] } ?? []) + view.subviews.flatMap { nativeTextViews(in: $0) }
    }

    /// QL lifecycle coverage now uses a real PDF. Notes have independent local
    /// UITextView content/selection tests; they must never return to QL text.
    private func nativePDFBytes() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            ("Native retained PDF fixture" as NSString).draw(at: CGPoint(x: 36, y: 36),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
    }

    /// QL can request chrome after remote content arrives, beyond willShow.
    /// Exercise both public request routes; setup-time hidden flags are weaker.
    private func verifyReaderBarVisibilityPolicy(_ owner: UINavigationController) throws {
        owner.setNavigationBarHidden(false, animated: false)
        try #require(owner.isNavigationBarHidden, "A late child request cannot expose reader navigation chrome")
        owner.setToolbarHidden(false, animated: false)
        try #require(owner.isToolbarHidden, "A late child request cannot expose unfenced native Share")
        owner.isNavigationBarHidden = false
        owner.isToolbarHidden = false
        #expect(owner.isNavigationBarHidden && owner.isToolbarHidden)
        owner.setNavigationBarHidden(false, animated: true)
        owner.setToolbarHidden(false, animated: true)
        #expect(owner.isNavigationBarHidden && owner.isToolbarHidden)
    }

    private func readers(in controller: UIViewController) -> [QLPreviewController] {
        ((controller as? QLPreviewController).map { [$0] } ?? [])
            + controller.children.flatMap { readers(in: $0) }
            + (controller.presentedViewController.map { readers(in: $0) } ?? [])
    }

    private func attach<V: View>(_ view: V, compact: Bool = false, logicalSize: CGSize? = nil) async throws -> WorkspaceTestWindow {
        try await waitUntil("A foreground scene is available") {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .contains { $0.activationState == .foregroundActive }
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let host = WorkspaceHostingController(rootView: view.environment(\.scenePhase, .active))
        host.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
        let window = WorkspaceTestWindow(windowScene: scene)
        window.previousKeyWindow = previousKey
        window.frame = scene.coordinateSpace.bounds
        if let logicalSize {
            let container = UIViewController()
            window.rootViewController = container
            container.addChild(host)
            container.view.addSubview(host.view)
            host.view.frame = CGRect(origin: .zero, size: logicalSize)
            host.view.autoresizingMask = []
            let scale = min(1, min(window.bounds.width / logicalSize.width, window.bounds.height / logicalSize.height))
            host.view.transform = CGAffineTransform(scaleX: scale, y: scale)
            host.view.frame.origin = .zero
            host.didMove(toParent: container)
        } else { window.rootViewController = host }
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        do {
            try await waitUntil("The fixture completed appearance in its key window", diagnostics: {
                "key=\(window.isKeyWindow) appeared=\(host.hasAppeared) attached=\(host.viewIfLoaded?.window === window) bounds=\(window.bounds) transition=\(host.transitionCoordinator != nil)"
            }) {
                window.isKeyWindow && host.hasAppeared && host.viewIfLoaded?.window === window &&
                    host.transitionCoordinator == nil && host.view.bounds.width > 0 && host.view.bounds.height > 0
            }
            return window
        } catch {
            window.close()
            throw error
        }
    }

    private func waitUntil(_ message: String = "Condition became true", diagnostics: () -> String = { "" },
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        var polls = 0, maximumGap = Duration.zero
        var previousPoll = ContinuousClock.now
        while !condition() && ContinuousClock.now < deadline {
            polls += 1
            try await Task.sleep(for: .milliseconds(5))
            let resumed = ContinuousClock.now
            maximumGap = max(maximumGap, previousPoll.duration(to: resumed)); previousPoll = resumed
        }
        if !condition() {
            maximumGap = max(maximumGap, previousPoll.duration(to: .now))
            #if DEBUG
            let decoding = AvatarDecodeLedger.shared.failureSnapshot()
            #else
            let decoding = "Decoder metadata is excluded from Release"
            #endif
            Attachment.record("\(message)\npolls=\(polls) maximumPollGap=\(maximumGap)\n\(diagnostics())\n\(decoding)",
                              named: "native-workspace-wait-failure.txt")
        }
        try #require(condition(), Comment(rawValue: message), sourceLocation: sourceLocation)
    }

}

@MainActor @Observable private final class ChatCoverageFixture {
    var covered = false
    var observedCover = false
}

private struct ChatCoverageHost: View {
    let store: AppStore
    let bot: BotProfile
    let state: ChatCoverageFixture
    @State private var presentation = WorkspacePresentation()
    var body: some View {
        ChatView(store: store, bot: bot, presentation: presentation, isExposed: !state.covered, isEditingExposed: !state.covered,
                 rootCovered: state.covered, onLocalModalPresentation: { _ in })
            .onChange(of: state.covered) { _, _ in state.observedCover = true }
    }
}

@MainActor private protocol WorkspaceHostingAppearance: AnyObject {
    var hasAppeared: Bool { get }
}

private final class WorkspaceHostingController<Content: View>: UIHostingController<Content>, WorkspaceHostingAppearance {
    private(set) var hasAppeared = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hasAppeared = false
    }
}

@MainActor private final class WorkspaceTestWindow: UIWindow {
    weak var previousKeyWindow: UIWindow?
    func close() {
        rootViewController?.viewIfLoaded?.endEditing(true)
        isHidden = true
        rootViewController = nil
        if let previousKeyWindow, !previousKeyWindow.isHidden { previousKeyWindow.makeKey() }
    }
}

@MainActor @Observable private final class LayoutObservationFixture {
    var latest: WorkspaceLayout?
}

private struct LayoutObservationHost: View {
    let state: LayoutObservationFixture
    var body: some View {
        Color.clear.modifier(WorkspaceLayoutObservation { state.latest = $0 })
    }
}

private struct NativeReadCoverageHost: View {
    let store: AppStore
    let bot: BotProfile
    let presentation: WorkspacePresentation
    let native: WorkspaceNativeDetailState
    var body: some View {
        ChatView(store: store, bot: bot, presentation: presentation, isExposed: true, isEditingExposed: true,
                 rootCovered: false, onLocalModalPresentation: { _ in })
            .environment(\.scenePhase, .active)
            .environment(\.workspaceNativeDetail, native)
            .background(WorkspaceNativeDetailObservation(state: native, projection: native.requestedProjection,
                layout: .init(compact: false, accessibilityText: false, workspaceWidth: 466),
                onUnavailable: {
                    if let owner = (try? ExactID(bot.id)).flatMap({ store.chats.screen(profile: $0)?.owner }) {
                        store.chats.setTranscriptVisible(false, owner: owner)
                    }
                }))
    }
}

@MainActor private final class NativeReadProjection: NSObject, UISplitViewControllerDelegate {
    let state: WorkspaceNativeDetailState
    init(state: WorkspaceNativeDetailState) { self.state = state }
    func splitViewController(_ svc: UISplitViewController, willChangeTo displayMode: UISplitViewController.DisplayMode) {
        // This fixture owns its native delegate; production receives the same
        // native projection through NavigationSplitView's public binding.
        state.requestRefresh(projection: displayMode == .secondaryOnly ? .detailOnly : .all)
    }
}

@MainActor @Observable private final class ShellCallbackFixture {
    @ObservationIgnored weak var renderProbe: ShellCallbackRenderProbeView?
    var replacement = false
    var renderedReplacement = false
    var settings: [Int] = []
    var newBots: [Int] = []
}
private struct ShellCallbackHost: View {
    let store: AppStore
    let presentation: WorkspacePresentation
    let state: ShellCallbackFixture
    var body: some View {
        let version = state.replacement ? 2 : 1
        AdaptiveWorkspace(store: store, presentation: presentation, rootCovered: false,
            onSettings: { state.settings.append(version) }, onNewBot: { state.newBots.append(version) })
            .background(ShellCallbackRenderProbe(version: version, state: state).allowsHitTesting(false).accessibilityHidden(true))
            .onChange(of: state.replacement, initial: true) { _, value in state.renderedReplacement = value }
    }
}

@MainActor private final class ShellRosterService: BotService {
    let base: NativeTranscriptReviewService
    var includesProfile = true
    var onEvent: ((BotServiceEvent) -> Void)? {
        get { base.onEvent }
        set { base.onEvent = newValue }
    }
    init() throws { base = try NativeTranscriptReviewService() }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo { try await base.connect(configuration: configuration) }
    func disconnect() { base.disconnect() }
    func bots() async throws -> [BotProfile] { includesProfile ? [base.profile] : [] }
    func createBot(_ draft: BotDraft) async throws -> BotProfile { try await base.createBot(draft) }
    func avatarAsset(for bot: BotProfile) async throws -> BotAvatarAsset? { nil }
    func conversations(profile: ExactID) async throws -> ConversationDirectory { try await base.conversations(profile: profile) }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { try await base.createConversation(profile: profile, operationID: operationID) }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation { try await base.openChat(target) }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        try await base.send(text: text, attachments: attachments, delivery: delivery, access: access, operationID: operationID)
    }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try await base.stop(access: access, operationID: operationID) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        try await base.respond(to: request, response: response, access: access, operationID: operationID)
    }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        try await base.upload(data: data, filename: filename, mimeType: mimeType, access: access)
    }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        try await base.downloadArtifact(attachment, access: access)
    }
}

@MainActor private final class ShellRosterCallback {
    private weak var store: AppStore?
    private let profile: ExactID
    var entered = false
    var draft: String?
    var requestEnabled: Bool?
    var onRemoval: (@MainActor () -> Void)?
    init(store: AppStore, profile: ExactID) { self.store = store; self.profile = profile }
    func arm() {
        guard !entered, let store else { return }
        withObservationTracking { _ = store.chats.aggregate(profile: profile) } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.entered, let store = self.store else { return }
                guard store.selectedBot == nil else { self.arm(); return }
                self.entered = true
                self.onRemoval?()
            }
        }
    }
}

@MainActor private final class ShellCallbackRenderProbeView: UIView {
    var requestedVersion = 0
    private(set) var laidOutVersion = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        laidOutVersion = requestedVersion
    }
}
private struct ShellCallbackRenderProbe: UIViewRepresentable {
    let version: Int
    let state: ShellCallbackFixture
    func makeUIView(context: Context) -> ShellCallbackRenderProbeView {
        let view = ShellCallbackRenderProbeView()
        state.renderProbe = view
        return view
    }
    func updateUIView(_ view: ShellCallbackRenderProbeView, context: Context) {
        view.requestedVersion = version
        view.setNeedsLayout()
    }
}
@MainActor private final class ShellCallbackDisplayFrames: NSObject {
    private var link: CADisplayLink?
    private var waiting: CheckedContinuation<Void, Never>?
    func nextFrame() async {
        await withCheckedContinuation { continuation in
            waiting = continuation
            let link = CADisplayLink(target: self, selector: #selector(tick))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
    }
    @objc private func tick() { stop() }
    func stop() {
        link?.invalidate(); link = nil
        let pending = waiting; waiting = nil
        pending?.resume()
    }
}
