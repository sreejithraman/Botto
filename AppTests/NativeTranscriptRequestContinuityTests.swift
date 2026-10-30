import Testing
import SwiftUI
import UIKit
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct NativeTranscriptRequestContinuityTests {
    @Test func unfinishedExactAnswerSurvivesActualReuseAndSameOwnerPublicationWithoutSubmitting() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let original = try await fixture.requestCell()
        let scope = try #require(original.exposure)
        let state = try #require(scope.requestState)
        let editor = state.responseBinding
        let text = "  A unique answer e\u{301}\n  keep these spaces  "
        try await continuityWait("actual native question editor is mounted") { !continuityTextViews(original).isEmpty }
        let nativeEditor = try #require(continuityTextViews(original).first)
        nativeEditor.text = text
        nativeEditor.delegate?.textViewDidChange?(nativeEditor)
        try await continuityWait("native editing publishes the byte-exact unfinished answer") { Data(state.response.utf8) == Data(text.utf8) }

        fixture.controller.collection.setContentOffset(.zero, animated: false)
        fixture.controller.collection.layoutIfNeeded()
        fixture.controller.scrollViewDidEndDragging(fixture.controller.collection, willDecelerate: false)
        try await continuityWait("request's original native host is recycled") { !scope.isCurrent }
        #expect(state.isCurrent && fixture.service.base.responses.isEmpty)
        fixture.publish { $0.lastSequence += 1 }
        let returned = try await fixture.requestCell()
        #expect(returned.exposure?.requestState === state)
        try await continuityWait("recreated native editor displays the byte-exact unfinished answer") { continuityTextViews(returned).contains { Data($0.text.utf8) == Data(text.utf8) } }
        #expect(Data(editor.wrappedValue.utf8) == Data(text.utf8))
        #expect(Data(fixture.store.chats.requestDraft(state.input.row, owner: state.input.owner).utf8) == Data(text.utf8))
        #expect(fixture.service.base.responses.isEmpty && fixture.service.base.responseOperations.isEmpty)
        try #require(returned.exposure?.requestActions).submitText()
        try await continuityWait("only deliberate Submit sends the retained answer with existing edge trimming") {
            fixture.service.responseValues == [.text("A unique answer e\u{301}\n  keep these spaces")]
        }
        #expect(fixture.service.base.responseOperations.count == 1)
    }

    @Test(arguments: ["removed", "replaced", "ambiguous", "owner"])
    func retiredQuestionRejectsCapturedEditorWritesAndSubmitCallbacks(reason: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let cell = try await fixture.requestCell()
        let scope = try #require(cell.exposure), state = try #require(scope.requestState)
        let binding = state.responseBinding, submit = try #require(scope.requestActions).submitText
        binding.wrappedValue = "Unsent original answer"
        if reason == "owner" {
            await fixture.store.open(try #require(fixture.store.selectedBot))
        } else {
            fixture.publish { conversation in
                switch reason {
                case "removed": conversation.pendingRequests = []
                case "replaced": conversation.pendingRequests[0].title = "A different question with the same remote ID"
                default: conversation.pendingRequests.append(conversation.pendingRequests[0])
                }
            }
        }
        // Reject stale publication immediately, before SwiftUI has a chance to
        // destroy or reconfigure the old native host.
        #expect(!state.isCurrent)
        binding.wrappedValue = "Late old editor mutation"
        submit()
        try await continuityWait("native reconciliation retires the captured request lifetime") { !scope.isCurrent && state.response.isEmpty }
        #expect(fixture.service.base.responseOperations.isEmpty)
        if reason != "owner" {
            fixture.publish { $0.pendingRequests = [.init(id: "question", kind: .question, title: "What should happen next?")] }
        }
        let fresh = try #require((try await fixture.requestCell()).exposure?.requestState)
        // Main owns draft persistence: a same-source owner refresh or temporary
        // duplicate retains existing text, while removal/replacement clears it.
        let expected = reason == "owner" || reason == "ambiguous" ? "Unsent original answer" : ""
        #expect(fresh !== state && fresh.response == expected)
        binding.wrappedValue = "Still late after the same request ID returns"
        submit()
        #expect(fresh.response == expected && fixture.service.base.responseOperations.isEmpty)
    }

    @Test(arguments: ["covered", "parked", "offscreen"])
    func retainedInitialRequestCallbacksCannotActOnAnInactiveCurrentRow(condition: String) async throws {
        let choice = RequestChoice(id: "suggested", label: "Use suggested answer")
        let fixture = try await Fixture(request: .init(id: "question", kind: .question, title: "What should happen next?", choices: [choice]))
        defer { fixture.close() }
        let cell = try await fixture.requestCell()
        let scope = try #require(cell.exposure), state = try #require(scope.requestState)
        state.responseBinding.wrappedValue = "  Deliberate answer  "
        let actions = try #require(scope.requestActions)
        #expect(actions.enabled)
        if condition == "parked" {
            // The semantic surface guard must reject immediately, even before
            // the next native apply has withdrawn this row's display flag.
            fixture.presentation.browseBots()
            actions.submitText()
        } else if condition == "covered" {
            fixture.coverage.covered = true
        } else {
            fixture.controller.collection.setContentOffset(.zero, animated: false)
            fixture.controller.collection.layoutIfNeeded()
            fixture.controller.scrollViewDidEndDragging(fixture.controller.collection, willDecelerate: false)
        }
        try await continuityWait("initial action admission is withdrawn without retiring request authority") { !actions.enabled }
        #expect(state.isCurrent)
        actions.submitText()
        #expect(actions.choose(choice) == nil)
        #expect(fixture.service.base.responseOperations.isEmpty)
        if condition == "parked" { #expect(fixture.presentation.isBrowsingBots); fixture.presentation.resumeTask() }
        fixture.coverage.covered = false
        let returned = try await fixture.requestCell()
        let current = try #require(returned.exposure?.requestActions)
        current.submitText()
        try await continuityWait("a new deliberate displayed gesture dispatches exactly one trimmed answer") { fixture.service.responseValues == [.text("Deliberate answer")] }
        current.submitText()
        #expect(fixture.service.base.responseOperations.count == 1)
    }

    @Test func offlineOwnerRetainsWorkspaceDraftAndRequiresDeliberateFreshActionAfterRecovery() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let originalScope = try #require((try await fixture.requestCell()).exposure)
        let original = try #require(originalScope.requestState)
        let oldEditor = original.responseBinding
        let oldAction = try #require(originalScope.requestActions)
        oldEditor.wrappedValue = "  Before disconnect e\u{301}  "
        fixture.service.onEvent?(.disconnected("Offline for request continuity"))
        try await continuityWait("disconnect retires native exposure and request authority") { !originalScope.isCurrent && !original.isCurrent }
        let offlineScope = try #require((try await fixture.requestCell()).exposure)
        let offline = try #require(offlineScope.requestState)
        let offlineActions = try #require(offlineScope.requestActions)
        #expect(!fixture.store.isConnected && !offline.canAct && offline.canEditDraft && offlineActions.enabled)
        #expect(offline.response == "  Before disconnect e\u{301}  ")
        // Offline rows live outside the intentionally inert cached transcript.
        #expect(fixture.store.chats.screen(profile: fixture.service.base.profile)?.snapshot?.pendingRequests.isEmpty == true)
        oldEditor.wrappedValue = "Retired editor mutation"
        offline.responseBinding.wrappedValue = "  Edited offline e\u{301}  "
        oldAction.submitText(); offlineActions.submitText()
        #expect(fixture.service.base.responseOperations.isEmpty)
        #expect(offline.response == "  Edited offline e\u{301}  ")
        fixture.service.onEvent?(.connected(.init(version: "test")))
        await fixture.store.open(try #require(fixture.store.selectedBot))
        try await continuityWait("recovery retires offline action authority") { !offlineScope.isCurrent && !offline.isCurrent }
        let currentScope = try #require((try await fixture.requestCell()).exposure)
        let current = try #require(currentScope.requestState)
        #expect(current.canAct && current.response == "  Edited offline e\u{301}  ")
        oldAction.submitText(); offlineActions.submitText()
        #expect(fixture.service.base.responseOperations.isEmpty && fixture.service.responseValues.isEmpty)
        let deliberate = try #require(currentScope.requestActions)
        deliberate.submitText()
        try await continuityWait("only deliberate current Submit sends the preserved offline answer") {
            fixture.service.responseValues == [.text("Edited offline e\u{301}")]
        }
        #expect(fixture.service.base.responseOperations.count == 1)
    }

    @Test(arguments: [HermesServiceError.invalidResponse, .responseTooLong], ["text", "choice", "confirmation"])
    func validationRetryRequiresNewRenderedActionsAndNeverReplaysRetainedCallbacks(rejection: HermesServiceError, action: String) async throws {
        let choice = RequestChoice(id: action == "confirmation" ? "always" : "suggested", label: "Use this answer")
        let fixture = try await Fixture(request: .init(id: "question", kind: .question, title: "What should happen next?", choices: [choice]))
        defer { fixture.close() }
        let scope = try #require((try await fixture.requestCell()).exposure)
        let state = try #require(scope.requestState)
        let captured = try #require(scope.requestActions)
        let retainedSubmit = captured.submitText
        state.responseBinding.wrappedValue = "  First attempt  "
        fixture.service.base.responseError = rejection
        let firstConfirmation: RequestCardConfirmation?
        if action == "text" { firstConfirmation = nil; retainedSubmit() }
        else { firstConfirmation = captured.choose(choice); firstConfirmation?.confirm() }
        try await continuityWait("validation rejection completes without retiring the row") {
            fixture.service.base.responseOperations.count == 1 && !state.busy
        }
        #expect(state.isCurrent && state.response == "  First attempt  ")
        #expect(fixture.service.base.responses.isEmpty)
        fixture.service.base.responseError = nil
        state.responseBinding.wrappedValue = "  Corrected answer  "
        // Keep invoking the actual old action value after Core renews the
        // request attempt. It must never borrow the fresh operation.
        if action == "text" { retainedSubmit() }
        else { captured.choose(choice)?.confirm(); firstConfirmation?.confirm() }
        try await continuityWait("retained action has finished without dispatching a renewed attempt") { !state.busy }
        #expect(fixture.service.base.responseOperations.count == 1)
        #expect(fixture.service.base.responses.isEmpty)
        let current = try #require(scope.requestActions)
        if action == "text" { current.submitText() }
        else { current.choose(choice)?.confirm() }
        try await continuityWait("a new rendered gesture dispatches the deliberate correction exactly once") {
            fixture.service.base.responses.count == 1 && !state.busy
        }
        #expect(fixture.service.base.responseOperations.count == 2)
        #expect(Set(fixture.service.base.responseOperations).count == 2)
        #expect(fixture.service.responseValues == (action == "text"
            ? [.text("First attempt"), .text("Corrected answer")]
            : [.choice(choice.id), .choice(choice.id)]))
        if action == "text" { current.submitText() }
        else { current.choose(choice)?.confirm() }
        try await continuityWait("repeated successful gesture has finished without duplicate dispatch") { !state.busy }
        #expect(fixture.service.base.responseOperations.count == 2)
    }

    @Test(arguments: ["id", "title", "detail", "queueID", "choiceID", "choiceLabel"])
    func sameAccessWireOnlyRequestRevisionRetiresOldActionsAndConfirmation(field: String) async throws {
        let choice = RequestChoice(id: "always-\u{e9}", label: "Caf\u{e9}")
        let request = PendingRequest(id: "approval-\u{e9}", kind: .approval, title: "Approve \u{e9}",
            detail: "Detail \u{e9}", choices: [choice], queueID: "queue-\u{e9}")
        let fixture = try await Fixture(request: request)
        defer { fixture.close() }
        let scope = try #require((try await fixture.requestCell()).exposure)
        let state = try #require(scope.requestState), actions = try #require(scope.requestActions)
        let confirmation = try #require(actions.choose(choice))
        let workspace = fixture.store.chats, owner = state.input.owner, intent = state.input.row.intent
        var revised = request
        switch field {
        case "id": revised.id = "approval-e\u{301}"
        case "title": revised.title = "Approve e\u{301}"
        case "detail": revised.detail = "Detail e\u{301}"
        case "queueID": revised.queueID = "queue-e\u{301}"
        case "choiceID": revised.choices[0].id = "always-e\u{301}"
        default: revised.choices[0].label = "Cafe\u{301}"
        }
        try #require(request == revised, "The raw revision changes bytes while remaining canonically equal")
        fixture.publish { $0.pendingRequests = [revised] }
        try #require(workspace.isCurrent(owner), "The publication retains the original attachment")
        let wasCurrent = state.isCurrent, confirmationWasCurrent = confirmation.isCurrent
        confirmation.confirm()
        await workspace.answer(intent, response: .choice(choice.id))
        await Task.yield()
        #expect(!wasCurrent && !confirmationWasCurrent)
        try #require(fixture.service.base.responseOperations.isEmpty && fixture.service.responseValues.isEmpty,
                     "Neither a held confirmation nor direct final dispatch may use the old wire revision")

        let freshScope = try #require((try await fixture.requestCell()).exposure)
        let fresh = try #require(freshScope.requestState), current = try #require(freshScope.requestActions)
        try #require(fresh !== state && fresh.isCurrent)
        let newChoice = revised.choices[0]
        try #require(current.choose(newChoice)).confirm()
        try await continuityWait("a deliberate fresh action sends only the current raw revision once") {
            fixture.service.base.responses.count == 1 && !fresh.busy
        }
        let sent = try #require(fixture.service.base.responses.first)
        #expect(Data(sent.id.utf8) == Data(revised.id.utf8))
        #expect(Data(sent.title.utf8) == Data(revised.title.utf8) && Data(sent.detail.utf8) == Data(revised.detail.utf8))
        #expect(sent.queueID.map { Data($0.utf8) } == revised.queueID.map { Data($0.utf8) })
        #expect(Data(sent.choices[0].id.utf8) == Data(newChoice.id.utf8))
        #expect(Data(sent.choices[0].label.utf8) == Data(newChoice.label.utf8))
        guard case let .choice(value) = try #require(fixture.service.responseValues.first) else {
            Issue.record("The fresh approval must send its current choice"); return
        }
        #expect(Data(value.utf8) == Data(newChoice.id.utf8))
        #expect(fixture.service.base.responseOperations.count == 1)
    }

    @Test func cancelledPersistentConfirmationCannotBeDispatchedByItsRetainedCallback() async throws {
        let choice = RequestChoice(id: "always", label: "Always allow")
        let fixture = try await Fixture(request: .init(id: "approval", kind: .approval, title: "Approve?", choices: [choice]))
        defer { fixture.close() }
        let scope = try #require((try await fixture.requestCell()).exposure)
        let actions = try #require(scope.requestActions)
        let confirmation = try #require(actions.choose(choice))
        confirmation.cancel()
        confirmation.confirm()
        #expect(fixture.service.base.responseOperations.isEmpty && scope.requestState?.confirmation == nil)
    }

    @Test(arguments: [false, true])
    func admittedPersistentConfirmationSurvivesCoverageAndReuseButRejectsRetirement(retire: Bool) async throws {
        let choice = RequestChoice(id: "always", label: "Always allow")
        let fixture = try await Fixture(request: .init(id: "approval", kind: .approval, title: "Approve this scope?", choices: [choice]))
        defer { fixture.close() }
        let cell = try await fixture.requestCell()
        let scope = try #require(cell.exposure), state = try #require(scope.requestState)
        let actions = try #require(scope.requestActions)
        let confirmation = try #require(actions.choose(choice))
        #expect(fixture.service.base.responseOperations.isEmpty)
        let present = try #require(scope.presentRequestConfirmation)
        present(confirmation) { _, covered in fixture.coverage.covered = covered }
        try await continuityWait("native confirmation is actually presented and covers new gestures") {
            fixture.controller.presentedViewController is UIAlertController && !actions.enabled &&
                fixture.controller.presentedViewController?.isBeingPresented == false
        }
        let foreground = try #require(fixture.controller.presentedViewController)
        #expect(state.isCurrent && state.confirmation != nil)
        #expect(actions.choose(choice) == nil)
        // Native reuse destroys the original host, while the admitted prompt
        // and its captured response intent still belong to this request.
        cell.prepareForReuse()
        #expect(!scope.isCurrent && state.confirmation != nil)
        #expect(fixture.controller.presentedViewController === foreground)
        if retire { fixture.publish { $0.pendingRequests = [] } }
        confirmation.confirm()
        if retire {
            try await continuityWait("retirement clears the admitted confirmation") { state.confirmation == nil }
            try await continuityWait("retirement dismisses the actual native confirmation") { fixture.controller.presentedViewController == nil }
            #expect(fixture.service.base.responseOperations.isEmpty)
        } else {
            try await continuityWait("admitted confirmation sends its captured choice despite covered recycled host") { fixture.service.responseValues == [.choice("always")] }
            confirmation.confirm()
            #expect(fixture.service.base.responseOperations.count == 1)
        }
    }

    @Test(arguments: ["covered", "parked", "offscreen"])
    func capturedFileCallbackDeniesNewDownloadsAndTaskSwitchesFromInactiveRows(condition: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let cell = try await fixture.requestCell()
        let scope = try #require(cell.exposure)
        let owner = try #require(fixture.store.chats.screen(profile: fixture.service.base.profile)?.owner)
        let attachment = ChatAttachment(name: "report.txt", path: "report.txt", mimeType: "text/plain", byteCount: 8)
        let revision = fixture.presentation.revision
        var opened = 0
        let capturedAction = transcriptArtifactAction(store: fixture.store, workspace: fixture.store.chats,
            botID: fixture.service.base.profile.text, owner: owner,
            admittedBy: { scope.canPresent && fixture.presentation.revision == revision && !fixture.presentation.isBrowsingBots },
            onOpen: { destination in opened += 1; fixture.presentation.openArtifact(destination, store: fixture.store) })
        let action = try #require(capturedAction)
        #expect(scope.canPresent && fixture.store.chats.isCurrent(owner))
        if condition == "parked" { fixture.presentation.browseBots() }
        else if condition == "covered" {
            fixture.coverage.covered = true
            try await continuityWait("covered file callback loses native display admission") { !scope.canPresent }
        } else {
            fixture.controller.collection.setContentOffset(.zero, animated: false)
            fixture.controller.collection.layoutIfNeeded()
            fixture.controller.scrollViewDidEndDragging(fixture.controller.collection, willDecelerate: false)
            try await continuityWait("file callback's originating native row leaves the viewport") { !scope.canPresent }
        }
        action(attachment)
        #expect(opened == 0 && fixture.service.base.downloads == 0 && fixture.presentation.artifact == nil)
        #expect(fixture.store.chats.isCurrent(owner), "denial must come from action admission, while conversation authority remains current")
        if condition == "parked" {
            #expect(fixture.presentation.isBrowsingBots)
            fixture.presentation.resumeTask()
            action(attachment)
            #expect(opened == 0, "the old surface revision cannot become admissible again after Return")
        }
        fixture.coverage.covered = false
        let current = try #require((try await fixture.requestCell()).exposure)
        let currentRevision = fixture.presentation.revision
        let currentAction = transcriptArtifactAction(store: fixture.store, workspace: fixture.store.chats,
            botID: fixture.service.base.profile.text, owner: owner,
            admittedBy: { current.canPresent && fixture.presentation.revision == currentRevision && !fixture.presentation.isBrowsingBots },
            onOpen: { destination in opened += 1; fixture.presentation.openArtifact(destination, store: fixture.store) })
        let deliberate = try #require(currentAction)
        deliberate(attachment)
        try await continuityWait("a new displayed current file gesture opens the reader and downloads") { opened == 1 && fixture.service.base.downloads == 1 }
        #expect(fixture.presentation.artifact != nil && !fixture.presentation.isBrowsingBots)
    }

    @MainActor private final class Fixture {
        let service: NativeTranscriptReviewService
        let store: AppStore
        let session: SessionIdentity
        let access: ConversationAccess
        let configuration: ConnectionConfiguration
        let window: UIWindow
        let host: UIHostingController<Host>
        let previous: UIWindow?
        let presentation = WorkspacePresentation()
        let coverage = Coverage()
        var controller: NativeTranscriptController { continuityController(host)! }
        init(request: PendingRequest = .init(id: "question", kind: .question, title: "What should happen next?")) async throws {
            service = try NativeTranscriptReviewService(); session = service.base.summaries[0].identity
            service.base.snapshots[session.root]?.messages = (0..<40).map {
                .init(id: "message-\($0)", role: .user, text: "A separate message \($0)\n" + String(repeating: "Context for scrolling. ", count: 10), timestamp: Date(timeIntervalSince1970: 1))
            }
            service.base.snapshots[session.root]?.pendingRequests = [request]
            configuration = .init(serverURL: URL(string: "https://native-request-continuity.invalid")!)
            store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
            try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
            access = try #require(service.base.completedOpens.last).access
            let screen = try #require(store.chats.screen(profile: service.base.profile))
            await store.chats.refreshDirectory(screen.owner); store.chats.displayed(screen.owner)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            host = UIHostingController(rootView: Host(store: store, presentation: presentation, coverage: coverage))
            window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
            try await continuityWait("real native request transcript is installed") { continuityController(self.host) != nil }
        }
        func publish(_ change: (inout Conversation) -> Void) {
            var snapshot = service.base.snapshots[session.root]!
            change(&snapshot); service.base.snapshots[session.root] = snapshot
            service.onEvent?(.conversation(.init(identity: session, snapshot: snapshot, access: access)))
        }
        func requestCell() async throws -> NativeTranscriptCell {
            try await continuityWait("native snapshot contains the unique current request") { self.controller.collection.numberOfItems(inSection: 0) == 43 }
            let index = IndexPath(item: 41, section: 0)
            controller.collection.scrollToItem(at: index, at: .bottom, animated: false)
            controller.collection.layoutIfNeeded()
            try await continuityWait("native request host is displayed and admits gestures") {
                guard let scope = (self.controller.collection.cellForItem(at: index) as? NativeTranscriptCell)?.exposure else { return false }
                return scope.canPresent && scope.requestActions?.enabled == true
            }
            return try #require(controller.collection.cellForItem(at: index) as? NativeTranscriptCell)
        }
        func close() {
            if let artifact = presentation.artifact { presentation.closeArtifact(id: artifact.id) }
            continuityController(host)?.retire(); window.isHidden = true; window.rootViewController = nil
            previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id)
        }
    }
    @MainActor @Observable final class Coverage { var covered = false }
    private struct Host: View {
        let store: AppStore
        let presentation: WorkspacePresentation
        let coverage: Coverage
        var body: some View {
            if let bot = store.selectedBot {
                ChatView(store: store, bot: bot, presentation: presentation,
                         isExposed: !presentation.isBrowsingBots, isEditingExposed: !presentation.isBrowsingBots,
                         rootCovered: coverage.covered, onLocalModalPresentation: { _ in })
                    .frame(width: 382, height: 434).environment(\.scenePhase, .active)
            }
        }
    }
}

/// The protocol is the external boundary. Keep real workspace/publication and
/// file authority underneath it; record only outgoing responses and roster data.
@MainActor final class NativeTranscriptReviewService: BotService {
    let base: WorkspaceTestService
    var profile: BotProfile
    var responseValues: [RequestResponse] = []
    var onEvent: ((BotServiceEvent) -> Void)? {
        get { base.onEvent }
        set { base.onEvent = newValue }
    }
    init() throws {
        base = try WorkspaceTestService(); profile = .init(id: base.profile.text, name: "Milo")
    }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo { try await base.connect(configuration: configuration) }
    func disconnect() { base.disconnect() }
    func bots() async throws -> [BotProfile] { [profile] }
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
        responseValues.append(response)
        return try await base.respond(to: request, response: response, access: access, operationID: operationID)
    }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        try await base.upload(data: data, filename: filename, mimeType: mimeType, access: access)
    }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        try await base.downloadArtifact(attachment, access: access)
    }
}

@MainActor private func continuityController(_ parent: UIViewController) -> NativeTranscriptController? {
    if let controller = parent as? NativeTranscriptController, controller.isViewLoaded, controller.view.window != nil { return controller }
    return parent.children.lazy.compactMap(continuityController).first
}
@MainActor private func continuityTextViews(_ view: UIView) -> [UITextView] {
    (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(continuityTextViews)
}
@MainActor private func continuityWait(_ reason: String, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    try #require(condition(), "Timed out: \(reason)")
}

// These mounted-controller contracts exercise policy replacement on no-op
// applies. The unchanged public ChatView journey supplies the regression red.
extension NativeTranscriptRequestContinuityTests {
    @Test func heldActualFileCardCallbackReadsLatestAdmissionWithoutReplacingItsNativeRow() async throws {
        let bytes = Data("Original notes e\u{301}\n  Preserve these bytes.  \n".utf8)
        let attachment = ChatAttachment(name: "notes.txt", path: "/notes.txt", mimeType: "text/plain", byteCount: bytes.count)
        let message = ChatMessage(id: "live-file-admission", role: .assistant, text: "", attachments: [attachment])
        let fixture = try await MountedAdmissionFixture(message: message, bytes: bytes)
        defer { fixture.close() }
        let store = fixture.store, presentation = fixture.presentation, owner = fixture.owner
        let profile = fixture.service.base.profile
        let generation = store.artifactGeneration, revision = presentation.revision
        let context = fixture.context
        let presence = NativeTranscriptBlockPresence()
        var heldOpen: (() -> Void)?
        var heldScope: NativeTranscriptRowExposure?
        var originalCallbackBuilds = 0, opened = 0
        let row = NativeTranscriptRow(id: .message(Data(message.id.utf8)), value: .message(message, working: false)) { scope, _ in
            let open: (() -> Void)?
            if heldScope === scope {
                open = heldOpen
            } else {
                let action = transcriptArtifactAction(store: store, workspace: store.chats, botID: profile.text,
                    owner: owner, admittedBy: { scope.canPresent }, onOpen: { destination in
                        opened += 1; presentation.openArtifact(destination, store: store)
                    })
                open = action.map { action in { action(attachment) } }
                if heldOpen == nil {
                    heldOpen = open; heldScope = scope; originalCallbackBuilds += 1
                }
            }
            return AnyView(ArtifactCard(attachment: attachment, open: open)
                .background(NativeTranscriptMarker(scope: scope, presence: presence, block: 0))
                .environment(\.scenePhase, .active))
        }
        // Each apply receives a different value capture, never a shared Bool box.
        fixture.apply(context, row: row, admitted: false)
        let cell = try await fixture.mountedCell(presence: presence)
        let scope = try #require(cell.exposure), geometry = try #require(scope.rowGeometry)
        let open = try #require(heldOpen)
        let frame = geometry.convert(geometry.bounds, to: fixture.window)
        try #require(heldScope === scope && scope.isCurrent && !scope.canPresent)
        open()
        #expect(opened == 0 && fixture.service.base.downloads == 0 && presentation.artifact == nil)

        fixture.apply(context, row: row, admitted: true)
        fixture.expectSameMountedRow(cell, scope: scope, geometry: geometry, frame: frame)
        try #require(scope.canPresent, "A no-op apply must replace the initially false policy before returning")
        #expect(originalCallbackBuilds == 1)
        #expect(opened == 0 && fixture.service.base.downloads == 0, "Uncover must not replay the denied gesture")
        fixture.apply(context, row: row, admitted: false)
        fixture.expectSameMountedRow(cell, scope: scope, geometry: geometry, frame: frame)
        #expect(!scope.canPresent && scope.isCurrent)
        #expect(presence.isVisible, "Action coverage must remain separate from native block read exposure")
        #expect(store.chats.isCurrent(owner) && store.artifactGeneration == generation && presentation.revision == revision)
        open()
        #expect(opened == 0 && fixture.service.base.downloads == 0 && presentation.artifact == nil)

        fixture.apply(context, row: row, admitted: true)
        fixture.expectSameMountedRow(cell, scope: scope, geometry: geometry, frame: frame)
        try #require(scope.canPresent && originalCallbackBuilds == 1)
        open()
        try await continuityWait("held actual card callback opens one real reader with original bytes") {
            opened == 1 && fixture.service.base.downloads == 1 && presentation.artifact?.file != nil
        }
        let reader = try #require(presentation.artifact), file = try #require(reader.file)
        #expect(reader.isCurrent && reader.title == attachment.name)
        #expect(file.data == bytes && file.mimeType == attachment.mimeType)
        #expect(try Data(contentsOf: file.url) == bytes)
        #expect(fixture.service.base.opens.count == 1)
        presentation.closeArtifact(id: reader.id)
        try #require(presentation.artifact == nil)

        var replacement = context; replacement.actionRevision = UUID()
        fixture.apply(replacement, row: row, admitted: true)
        #expect(!scope.isCurrent && !scope.canPresent)
        open()
        #expect(opened == 1 && fixture.service.base.downloads == 1 && presentation.artifact == nil)
        // Even returning to the exact old context cannot revive its old scope.
        fixture.apply(context, row: row, admitted: true)
        let returned = try #require((try await fixture.mountedCell(presence: presence)).exposure)
        try #require(returned !== scope && returned.canPresent && store.chats.isCurrent(owner))
        open()
        #expect(!scope.canPresent && opened == 1 && fixture.service.base.downloads == 1 && presentation.artifact == nil)
    }

    @Test func heldRequestActionsReadLatestAdmissionAndKeepExactDraftUntilDeliberateCurrentSubmit() async throws {
        let choice = RequestChoice(id: "always", label: "Always use this answer")
        let request = PendingRequest(id: "question", kind: .question, title: "What should happen next?", choices: [choice])
        let fixture = try await MountedAdmissionFixture(request: request)
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.base.profile))
        let requestRow = try #require(screen.requests.first)
        let input = RequestCardInput(row: requestRow, store: fixture.store, workspace: fixture.store.chats,
                                     owner: fixture.owner, profile: fixture.service.base.profile)
        let context = fixture.context
        let presence = NativeTranscriptBlockPresence()
        let row = NativeTranscriptRow(id: .request(requestRow.id), value: .request(request, enabled: screen.canAct), request: input) { scope, _ in
            AnyView(RequestCard(input: input, canAct: screen.canAct, canEditDraft: screen.canEditDraft,
                                lifetime: scope.requestState)
                .background(NativeTranscriptMarker(scope: scope, presence: presence, block: 0))
                .environment(\.scenePhase, .active))
        }
        fixture.apply(context, row: row, admitted: false)
        let cell = try await fixture.mountedCell(presence: presence)
        let scope = try #require(cell.exposure), state = try #require(scope.requestState)
        let actions = try #require(scope.requestActions), binding = state.responseBinding
        try #require(scope.isCurrent && state.canAct && !scope.canPresent && !actions.enabled)
        try await continuityWait("actual question editor is mounted while action policy denies") { !continuityTextViews(cell).isEmpty }
        let editor = try #require(continuityTextViews(cell).first)
        let text = "  A deliberate e\u{301} answer\n  keep these spaces  "
        editor.text = text; editor.delegate?.textViewDidChange?(editor)
        try await continuityWait("native editor publishes the exact draft under denied action admission") {
            Data(state.response.utf8) == Data(text.utf8)
        }
        fixture.controller.collection.layoutIfNeeded()
        let geometry = try #require(scope.rowGeometry), frame = geometry.convert(geometry.bounds, to: fixture.window)
        actions.submitText()
        #expect(actions.choose(choice) == nil && state.confirmation == nil)
        #expect(fixture.service.base.responseOperations.isEmpty)

        fixture.apply(context, row: row, admitted: true)
        fixture.expectSameMountedRow(cell, scope: scope, geometry: geometry, frame: frame)
        try #require(scope.canPresent && actions.enabled, "The original rendered actions must read the new policy immediately")
        let confirmation = try #require(actions.choose(choice), "The originally denied actions can now enter confirmation")
        #expect(confirmation.isCurrent)
        confirmation.cancel()
        #expect(scope.requestState === state && continuityTextViews(cell).contains { $0 === editor })
        #expect(Data(editor.text.utf8) == Data(text.utf8) && Data(binding.wrappedValue.utf8) == Data(text.utf8))
        #expect(Data(fixture.store.chats.requestDraft(requestRow, owner: fixture.owner).utf8) == Data(text.utf8))
        #expect(fixture.service.base.responseOperations.isEmpty, "Uncover must not submit an unfinished draft")
        fixture.apply(context, row: row, admitted: false)
        fixture.expectSameMountedRow(cell, scope: scope, geometry: geometry, frame: frame)
        #expect(scope.isCurrent && state.isCurrent && !actions.enabled && !scope.canPresent)
        actions.submitText()
        #expect(actions.choose(choice) == nil && state.confirmation == nil)
        #expect(fixture.store.chats.isCurrent(fixture.owner) && fixture.service.base.responseOperations.isEmpty)
        #expect(Data(state.response.utf8) == Data(text.utf8))
        fixture.apply(context, row: row, admitted: true)
        fixture.expectSameMountedRow(cell, scope: scope, geometry: geometry, frame: frame)
        try #require(actions.enabled && state.isCurrent)

        // Retire before sending so stale-action denial cannot be explained by
        // consuming its intent. The same request lifetime and draft stay current.
        var replacement = context; replacement.actionRevision = UUID()
        fixture.apply(replacement, row: row, admitted: true)
        try #require(!scope.isCurrent && state.isCurrent && !actions.enabled)
        actions.submitText()
        #expect(actions.choose(choice) == nil && fixture.service.base.responseOperations.isEmpty)
        fixture.apply(context, row: row, admitted: true)
        let returned = try #require((try await fixture.mountedCell(presence: presence)).exposure)
        try #require(returned !== scope && returned.canPresent && returned.requestState === state)
        #expect(Data(state.response.utf8) == Data(text.utf8) && !actions.enabled)
        actions.submitText()
        #expect(fixture.service.base.responseOperations.isEmpty)
        let deliberate = try #require(returned.requestActions)
        try #require(deliberate.enabled)
        deliberate.submitText()
        try await continuityWait("only a deliberate current action sends the retained draft once with edge trimming") {
            fixture.service.base.responses.count == 1 && !state.busy
        }
        actions.submitText(); deliberate.submitText()
        try await continuityWait("repeated retained and current gestures finish without a second dispatch") { !state.busy }
        #expect(fixture.service.responseValues == [.text("A deliberate e\u{301} answer\n  keep these spaces")])
        #expect(fixture.service.base.responseOperations.count == 1 && !scope.canPresent)
    }

    @Test func mountedRequestButtonTracksAdmissionOnUnchangedRows() async throws {
        let choice = RequestChoice(id: "once", label: "Allow once")
        let request = PendingRequest(id: "mounted-admission", kind: .approval,
                                     title: "Approve this harmless fixture?", choices: [choice])
        let fixture = try await MountedAdmissionFixture(request: request)
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.base.profile))
        let requestRow = try #require(screen.requests.first)
        let input = RequestCardInput(row: requestRow, store: fixture.store, workspace: fixture.store.chats,
                                     owner: fixture.owner, profile: fixture.service.base.profile)
        let context = fixture.context
        let presence = NativeTranscriptBlockPresence()
        let row = NativeTranscriptRow(id: .request(requestRow.id),
            value: .request(request, enabled: screen.canAct), request: input) { scope, _ in
            AnyView(RequestCard(input: input, canAct: screen.canAct, canEditDraft: screen.canEditDraft,
                                lifetime: scope.requestState)
                .background(NativeTranscriptMarker(scope: scope, presence: presence, block: 0))
                .environment(\.scenePhase, .active))
        }
        fixture.apply(context, row: row, admitted: false)
        let cell = try await fixture.mountedCell(presence: presence)
        let scope = try #require(cell.exposure), state = try #require(scope.requestState)
        let geometry = try #require(scope.rowGeometry)
        let frame = geometry.convert(geometry.bounds, to: fixture.window)
        let hostViews = cell.contentView.subviews
        try #require(!hostViews.isEmpty && state.isCurrent && state.canAct)

        func requireSameMount() throws {
            fixture.expectSameMountedRow(cell, scope: scope, geometry: geometry, frame: frame)
            try #require(cell.exposure === scope && scope.requestState === state)
            try #require(cell.contentView.subviews.count == hostViews.count)
            try #require(zip(cell.contentView.subviews, hostViews).allSatisfy { $0.0 === $0.1 },
                         "Admission updates must preserve the original native host")
            try #require(scope.isCurrent && state.isCurrent && state.canAct && presence.isVisible)
        }
        func waitForButton(enabled: Bool, stage: String) async throws -> NSObject {
            func matchesRenderedState() -> Bool {
                guard let button = self.renderedRequestButton(choice.label, in: cell) else { return false }
                let accessibleEnabled = !button.accessibilityTraits.contains(.notEnabled)
                if let control = button as? UIControl, control.isEnabled != enabled { return false }
                return accessibleEnabled == enabled
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while !matchesRenderedState(), ContinuousClock.now < deadline { await Task.yield() }
            try requireSameMount()
            let button = try #require(renderedRequestButton(choice.label, in: cell),
                "Public UIKit accessibility container must expose the actual request button at \(stage); do not substitute a production callback")
            let accessibleEnabled = !button.accessibilityTraits.contains(.notEnabled)
            try #require(accessibleEnabled == enabled, "Actual mounted public button state at \(stage)")
            if let control = button as? UIControl {
                try #require(control.isEnabled == enabled, "Actual mounted public control state at \(stage)")
            }
            return button
        }
        func expectNoResponse() async throws {
            // Allow an accidentally dispatched MainActor Task to reach the service.
            try await Task.sleep(for: .milliseconds(200))
            #expect(fixture.service.responseValues.isEmpty)
            #expect(fixture.service.base.responseOperations.isEmpty && fixture.service.base.responses.isEmpty)
            try requireSameMount()
        }

        let initiallyDisabled = try await waitForButton(enabled: false, stage: "initial denied admission")
        try #require(!scope.canPresent)
        _ = initiallyDisabled.accessibilityActivate()
        try await expectNoResponse()

        // The row, snapshot, context, active flag, host and scope stay the same.
        // Only the value-captured admission closure supplied to apply changes.
        fixture.apply(context, row: row, admitted: true)
        try #require(scope.canPresent, "The action policy must already be current before checking rendered enablement")
        _ = try await waitForButton(enabled: true, stage: "first unchanged-row recovery")
        try await expectNoResponse() // Enabling must not replay the denied action.

        fixture.apply(context, row: row, admitted: false)
        try #require(!scope.canPresent)
        let disabledAgain = try await waitForButton(enabled: false, stage: "second denial")
        _ = disabledAgain.accessibilityActivate()
        try await expectNoResponse()

        fixture.apply(context, row: row, admitted: true)
        try #require(scope.canPresent)
        let enabledAgain = try await waitForButton(enabled: true, stage: "second unchanged-row recovery")
        try await expectNoResponse()
        let responseGate = WorkspaceGate()
        fixture.service.base.responseGate = responseGate
        defer { responseGate.release(); fixture.service.base.responseGate = nil }
        try #require(enabledAgain.accessibilityActivate(),
                     "The ordinary public accessibility activation must work; a missing seam is a harness failure")
        try await continuityWait("one public button activation reaches the service while its response is held") {
            fixture.service.responseValues == [.choice("once")] &&
                fixture.service.base.responseOperations.count == 1 && state.busy
        }
        #expect(fixture.service.base.responses.isEmpty)
        try await continuityWait("the mounted public button is disabled while sending") {
            self.renderedRequestButton(choice.label, in: cell)?.accessibilityTraits.contains(.notEnabled) == true
        }
        let busyButton = try #require(renderedRequestButton(choice.label, in: cell))
        _ = busyButton.accessibilityActivate()
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.service.responseValues == [.choice("once")])
        #expect(fixture.service.base.responseOperations.count == 1)
        responseGate.release(); fixture.service.base.responseGate = nil
        try await continuityWait("exactly one answer completes through the service boundary") {
            fixture.service.base.responses.count == 1 && !state.busy
        }
        let completed = try #require(fixture.service.base.responses.first)
        #expect(Data(completed.id.utf8) == Data("mounted-admission".utf8))
        #expect(completed.kind == .approval && completed.title == request.title && completed.choices == [choice])
        // Another public activation after completion cannot dispatch this intent twice.
        let completedButton = try #require(renderedRequestButton(choice.label, in: cell))
        _ = completedButton.accessibilityActivate()
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.service.responseValues == [.choice("once")])
        #expect(fixture.service.base.responses.count == 1 && fixture.service.base.responseOperations.count == 1)
        try await continuityWait("the settled request returns to its original mounted geometry") {
            geometry.convert(geometry.bounds, to: fixture.window) == frame
        }
        try requireSameMount()
    }

    private func renderedRequestButton(_ label: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 30, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.accessibilityLabel == label, object.accessibilityTraits.contains(.button) {
                return object
            }
            if let view = object as? UIView {
                for child in view.subviews {
                    if let found = find(child, depth: depth + 1) { return found }
                }
            }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let found = find(child, depth: depth + 1) { return found }
                }
            }
            return nil
        }
        return find(root, depth: 0)
    }

    @MainActor private final class MountedAdmissionFixture {
        let service: NativeTranscriptReviewService
        let store: AppStore
        let configuration: ConnectionConfiguration
        let owner: PresentationOwner
        let context: NativeTranscriptContext
        let controller = NativeTranscriptController()
        let presentation = WorkspacePresentation()
        let window: UIWindow
        let previous: UIWindow?

        init(message: ChatMessage? = nil, bytes: Data = Data(), request: PendingRequest? = nil) async throws {
            service = try NativeTranscriptReviewService()
            let session = service.base.summaries[0].identity
            service.base.snapshots[session.root]?.messages = message.map { [$0] } ?? []
            service.base.snapshots[session.root]?.pendingRequests = request.map { [$0] } ?? []
            service.base.downloadData = bytes
            configuration = .init(serverURL: URL(string: "https://mounted-live-admission.invalid")!)
            store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
            try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
            let screen = try #require(store.chats.screen(profile: service.base.profile))
            owner = screen.owner
            await store.chats.refreshDirectory(owner); store.chats.displayed(owner)
            try #require(store.chats.isCurrent(owner) && screen.canAct)
            let access = try #require(service.base.completedOpens.last).access
            try #require(try service.base.issuer.resolve(access) == session)
            context = .init(workspace: ObjectIdentifier(store.chats), profile: Data(service.base.profile.text.utf8),
                chat: screen.selectedChatID, owner: owner, generation: store.artifactGeneration,
                reviewingConnection: store.showsConnection, actionRevision: presentation.revision)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            window.rootViewController = controller; window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()
        }

        func apply(_ context: NativeTranscriptContext, row: NativeTranscriptRow, admitted: Bool) {
            let workspace = store.chats, store = store, profile = service.base.profile
            let generation = context.generation, owner = owner, reviewing = context.reviewingConnection
            controller.apply(context, snapshot: workspace.screen(profile: profile)?.snapshot, rows: [row], active: true,
                currentTaskSnapshot: {
                    guard store.chats === workspace, store.artifactGeneration == generation,
                          store.showsConnection == reviewing, workspace.isCurrent(owner) else { return nil }
                    return workspace.screen(profile: profile)?.snapshot
                }, admitsAction: { [admitted] in admitted })
        }

        func mountedCell(presence: NativeTranscriptBlockPresence) async throws -> NativeTranscriptCell {
            let index = IndexPath(item: 0, section: 0)
            try await continuityWait("owned native controller has committed an attached visible row without requiring action admission") {
                guard self.window.isKeyWindow, self.controller.view.window === self.window, presence.isVisible,
                      let cell = self.controller.collection.cellForItem(at: index) as? NativeTranscriptCell,
                      cell.isDisplayed, let scope = cell.exposure, scope.isCurrent,
                      let geometry = scope.rowGeometry, geometry.window === self.window,
                      geometry.bounds.width > 0, geometry.bounds.height > 0 else { return false }
                let frame = geometry.convert(geometry.bounds, to: self.window)
                return frame.intersects(self.window.bounds) && cell.frame.intersects(self.controller.collection.bounds)
            }
            return try #require(controller.collection.cellForItem(at: index) as? NativeTranscriptCell)
        }

        func expectSameMountedRow(_ cell: NativeTranscriptCell, scope: NativeTranscriptRowExposure, geometry: UIView, frame: CGRect) {
            #expect(controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) === cell)
            #expect(cell.exposure === scope && scope.rowGeometry === geometry && cell.isDisplayed && scope.isCurrent)
            #expect(geometry.window === window && geometry.convert(geometry.bounds, to: window) == frame)
        }

        func close() {
            if let artifact = presentation.artifact { presentation.closeArtifact(id: artifact.id) }
            controller.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.forgetConnection(); LocalHistory.remove(for: configuration.id)
        }
    }
}
