import Testing
import SwiftUI
import UIKit
import WebKit
@testable import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct NativeTranscriptIdentityTests {
    @Test func aRepeatedRowIDRevokesActionsGrantedBeforeTheRepeatArrived() async throws {
        let service = try WorkspaceTestService(), source = service.summaries[0].identity
        let message = ChatMessage(id: source.stored.text + ":row:7", role: .assistant, text: "::preview{file='report.html'}")
        service.snapshots[source.root]?.messages = [message]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://raw-ambiguity.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let block = try #require(ReplyContent(message: message).blocks.first)
        let context = store.richReplyContext(for: source.profile.text, messageID: message.id)
        try #require(context.permits(block))
        let attachment = try #require(block.filePreview?.attachment)
        let destination = try #require(store.artifactDestination(for: attachment, botID: source.profile.text, producingMessage: message))
        defer { store.finishArtifact(destination) }
        service.snapshots[source.root]?.messages = [message, message]
        service.onEvent?(.conversation(try service.publication(source)))
        #expect(!context.permits(block))
        #expect(!store.isAuthorizedArtifactPresentation(destination))
        #expect(store.artifactDestination(for: attachment, botID: source.profile.text, producingMessage: message) == nil)
        let snapshot = try #require(store.conversation(for: source.profile.text))
        #expect(NativeTranscriptMessagePlan(snapshot.messages).entries.first?.isAmbiguous == true)
    }

    @Test func consecutiveToolResultsShareOneNativeRowWithoutChangingStoredHistory() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        let messages: [ChatMessage] = [
            .init(id: "reply", role: .assistant, text: "I’m checking the services."),
            .init(id: "tool-one", role: .tool, text: "FIRST-TOOL-OUTPUT", toolName: "terminal"),
            .init(id: "tool-two", role: .tool, text: "SECOND-TOOL-OUTPUT", toolName: "cronjob_manage")
        ]
        service.snapshots[session.root]?.messages = messages
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-work-details.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: Host(store: store)), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await wait("one assistant row, one grouped tool row and terminal") {
            collectionController(host)?.collection.numberOfItems(inSection: 0) == 3
        }
        #expect(store.chats.screen(profile: service.profile)?.snapshot?.messages == messages)
        try await wait("collapsed tools show one named disclosure without output") {
            element("Work details, 2 tools", in: host.view) != nil && element("FIRST-TOOL-OUTPUT", in: host.view) == nil
        }
        let disclosure = try #require(element("Work details, 2 tools", in: host.view))
        #expect(disclosure.accessibilityActivate())
        let controller = try #require(collectionController(host))
        let readerOpened = ContinuousClock.now
        try await wait("one reader opens with collapsed tool summaries") {
            guard let sheet = controller.presentedViewController else { return false }
            return element("Expand terminal", in: sheet.view) != nil && element("Expand cronjob_manage", in: sheet.view) != nil
        }
        let details = try #require(controller.presentedViewController)
        details.sheetPresentationController?.animateChanges {
            details.sheetPresentationController?.selectedDetentIdentifier = .large
        }
        #expect(try #require(element("Expand all", in: details.view)).accessibilityActivate())
        try await wait("one reader shows both tool names and outputs") {
            guard let sheet = controller.presentedViewController else { return false }
            return element("FIRST-TOOL-OUTPUT", in: sheet.view) != nil && element("SECOND-TOOL-OUTPUT", in: sheet.view) != nil
        }
        var updated = messages
        updated[2].text = "UPDATED-SECOND-TOOL-OUTPUT"
        updated.append(.init(id: "tool-three", role: .tool, text: "THIRD-TOOL-OUTPUT", toolName: "read_file"))
        let originalReader = try #require(controller.presentedViewController)
        service.snapshots[session.root]?.messages = updated
        service.onEvent?(.conversation(try service.publication(session)))
        try await wait("growing group keeps the same reader open") {
            controller.presentedViewController === originalReader &&
                element("UPDATED-SECOND-TOOL-OUTPUT", in: originalReader.view) != nil
        }
        let reader = try #require(controller.presentedViewController)
        reader.sheetPresentationController?.animateChanges {
            reader.sheetPresentationController?.selectedDetentIdentifier = .large
        }
        try await wait("new work arrives collapsed without closing expanded work") {
            element("Expand read_file", in: reader.view) != nil && element("Collapse cronjob_manage", in: reader.view) != nil
        }
        #expect(try #require(element("Expand read_file", in: reader.view)).accessibilityActivate())
        try await wait("open group shows current results") {
            guard let sheet = controller.presentedViewController else { return false }
            return element("UPDATED-SECOND-TOOL-OUTPUT", in: sheet.view) != nil && element("THIRD-TOOL-OUTPUT", in: sheet.view) != nil &&
                element("SECOND-TOOL-OUTPUT", in: sheet.view) == nil
        }
        #expect(store.chats.screen(profile: service.profile)?.snapshot?.messages == updated)
        #expect(try #require(element("Collapse all", in: reader.view)).accessibilityActivate())
        try await wait("all work collapses while summaries remain readable") {
            element("Expand terminal", in: reader.view) != nil && element("Expand cronjob_manage", in: reader.view) != nil &&
                element("UPDATED-SECOND-TOOL-OUTPUT", in: reader.view) == nil &&
                element("Preview: UPDATED-SECOND-TOOL-OUTPUT", in: reader.view) != nil
        }
        #expect(try #require(element("Expand cronjob_manage", in: reader.view)).accessibilityActivate())
        try await wait("expanded updated work exposes its copy action") { element("Copy original", in: reader.view) != nil }
        UIPasteboard.general.string = "before-updated-tool-copy"
        #expect(try #require(element("Copy original", in: reader.view)).accessibilityActivate())
        try await wait("copy preserves the exact updated tool output") {
            UIPasteboard.general.string.map { Data($0.utf8) == Data(updated[2].text.utf8) } == true
        }
        // Done's VoiceOver activation is sometimes refused on loaded runners, and the cause is
        // unknown (W21-F1). Record each refusal as a known issue with its state, then require
        // that the current Done still closes the reader.
        let done = try #require(element("Done", in: reader.view))
        let presenting = reader.isBeingPresented, dismissing = reader.isBeingDismissed
        let accepted = done.accessibilityActivate()
        if !accepted {
            let current = element("Done", in: reader.view)
            Attachment.record("presenting=\(presenting) dismissing=\(dismissing) node=\(type(of: done)) " +
                "presented=\(controller.presentedViewController === reader) Done shown=\(current != nil) " +
                "replaced=\(current.map { $0 !== done } ?? false) sinceReaderOpened=\(readerOpened.duration(to: .now))",
                named: "done-refusal.txt")
        }
        withKnownIssue("Done refuses accessibilityActivate intermittently (W21-F1)", isIntermittent: true) {
            #expect(accepted, "Done refused its first accessibility activation.")
        }
        if !accepted {
            try await wait("Done accepts a press") { element("Done", in: reader.view)?.accessibilityActivate() == true }
        }
        try await wait("Done closes the reader") { controller.presentedViewController == nil }
        try await wait("updated work can reopen") { element("Work details, 3 tools", in: host.view) != nil }
        #expect(try #require(element("Work details, 3 tools", in: host.view)).accessibilityActivate())
        try await wait("a fresh reader opens after updates") { controller.presentedViewController != nil }
        store.forgetConnection()
        try await wait("leaving the workspace retires the work reader") { controller.presentedViewController == nil }

    }
    @Test(arguments: ["empty-section", "leading-whitespace", "empty-error", "partial-error"])
    func collapsedWorkPreviewsSkipEmptySectionsAndLeadingWhitespace(payload: String) async throws {
        let text: String = switch payload {
        case "empty-section": "{\"content\":\"\",\"output\":\"Job failed\"}"
        case "empty-error": "{\"output\":\"\",\"error\":\"permission denied\",\"exit_code\":1}"
        case "partial-error": "{\"output\":\"Processed 5 files\",\"error\":\"permission denied\",\"exit_code\":1}"
        default: String(repeating: " \n", count: 500) + "Job failed"
        }
        let expected = switch payload {
        case "empty-error": "Preview: Error: permission denied · Exit code: 1"
        case "partial-error": "Preview: Error: permission denied · Exit code: 1 · Processed 5 files"
        default: "Preview: Job failed"
        }
        let message = ChatMessage(id: "preview", role: .tool, text: text, toolName: "terminal")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: WorkDetailsSheet(document: .init(title: "Work details", messages: [message]),
            isCurrent: { true }, close: {}).environment(\.scenePhase, .active))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await wait("collapsed work retains meaningful output") {
            element("Expand terminal", in: host.view) != nil && element(expected, in: host.view) != nil
        }
    }

    @Test func duplicateDisclosureIdentityCannotManufactureAnActionRow() {
        let first = ChatMessage(id: "stored:row:1", role: .tool, text: "One", workDetailsID: "shared")
        let second = ChatMessage(id: "stored:row:2", role: .tool, text: "Two", workDetailsID: "shared")
        let plan = NativeTranscriptMessagePlan([first, second])
        #expect(plan.hasAmbiguity)
        #expect(plan.displayRows.map(\.id) == [.ambiguousMessage(0), .ambiguousMessage(1)])
    }

    @Test func workIndicatorTracksWorkingToolsReplyingAndWaiting() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        service.snapshots[session.root]?.messages = [.init(id: "question", role: .user, text: "Check the service")]
        service.snapshots[session.root]?.isWorking = true
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-work-indicator.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: Host(store: store)), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let name = try #require(store.bots.first).name
        try await wait("work starts with working feedback") { element("\(name) is working", in: host.view) != nil }
        #expect(element("\(name) is replying", in: host.view) == nil)
        let lineage = UUID()
        func publish(_ phase: ConversationWorkPhase?) throws {
            let publication = try service.publication(session)
            service.onEvent?(.conversation(.init(identity: session, snapshot: publication.snapshot, access: publication.access,
                activity: .init(lineage: lineage, phase: phase, workStartedAt: .now, phaseStartedAt: .now))))
        }
        service.snapshots[session.root]?.messages.append(.init(id: "result", role: .tool, text: "Service is healthy", toolName: "terminal"))
        try publish(.tools)
        try await wait("current tool row shows active work") { element("Work details, 1 tool, Working", in: host.view) != nil }
        #expect(element("\(name) is replying", in: host.view) == nil)
        service.snapshots[session.root]?.messages.append(.init(id: "answer", role: .assistant, text: "The service"))
        try publish(.replying)
        try await wait("reply text has typing feedback and settled tool row") {
            element("\(name) is replying", in: host.view) != nil && element("Work details, 1 tool", in: host.view) != nil
        }
        try publish(.thinking)
        try await wait("thinking stops typing feedback") { element("\(name) is replying", in: host.view) == nil && element("\(name) is working", in: host.view) != nil }
        service.snapshots[session.root]?.pendingRequests = [.init(id: "approval", kind: .approval, title: "Continue?")]
        try publish(.working)
        try await wait("waiting for the user has no working or typing feedback") {
            element("\(name) is replying", in: host.view) == nil && element("\(name) is working", in: host.view) == nil
        }
        service.snapshots[session.root]?.pendingRequests = []
        service.snapshots[session.root]?.isWorking = false
        try publish(nil)
        try await wait("completion clears activity feedback") { element("\(name) is replying", in: host.view) == nil && element("\(name) is working", in: host.view) == nil }
    }

    @Test func workDetailsGroupingPreservesMessageBoundariesAndDuplicateQuarantine() throws {
        let first = ChatMessage(id: "first", role: .tool, text: "One")
        let second = ChatMessage(id: "second", role: .tool, text: "Two")
        let human = ChatMessage(id: "human", role: .user, text: "Please check again")
        let third = ChatMessage(id: "third", role: .tool, text: "Three")
        let plan = NativeTranscriptMessagePlan([first, second, human, third])
        #expect(plan.displayRows.map(\.id) == [.workDetails(Data("first".utf8)), .message(Data("human".utf8)), .workDetails(Data("third".utf8))])
        guard case let .workDetails(grouped)? = plan.displayRows.first else { Issue.record("Expected grouped tool results"); return }
        #expect(grouped.map(\.text) == ["One", "Two"])
        let pending = ChatMessage(id: "submission:queued", role: .user, text: "Queued follow-up")
        let hidden = NativeTranscriptMessagePlan([first, pending, second],
            queuedMessages: [QueuedMessage(id: "queued", text: pending.text, submissionID: "queued")])
        #expect(hidden.displayRows.map(\.id) == [.workDetails(Data("first".utf8)), .workDetails(Data("second".utf8))])
        let duplicated = NativeTranscriptMessagePlan([first, first, second])
        #expect(duplicated.hasAmbiguity)
        #expect(duplicated.displayRows.map(\.id) == [.ambiguousMessage(0), .ambiguousMessage(1), .workDetails(Data("second".utf8))])
        var changed = second; changed.text = "e\u{301}"
        var original = changed; original.text = "é"
        #expect(NativeTranscriptRowValue.workDetails([first, original]) != .workDetails([first, changed]))
    }
    /// A reply is shown as written, even when its whole text looks like an old silence marker.
    @Test(arguments: ["Silent.", "NO REPLY", "[SILENT]"])
    func replyThatLooksLikeASilenceMarkerIsShown(text: String) throws {
        let reply = ChatMessage(id: "reply", role: .assistant, text: text)
        #expect(NativeTranscriptMessagePlan([reply]).entries.map(\.message.id) == [reply.id])
        let stored = try ExactID("stored"), identity = SessionIdentity(profile: try ExactID("bot"), root: stored, stored: stored, aliases: [])
        var book = ConversationBook()
        let chat = book.merge(SessionSummary(identity: identity, title: "Main", isCanonical: true, persistence: .durable, messageCount: 1))
        book.cache(Conversation(id: "runtime", storedID: "stored", profileID: "bot", messages: [reply]), for: chat)
        #expect(book.record(chat)?.inboxMessage?.text == text)
    }
    @Test func queuedSubmissionRowsStayHiddenUntilAdmissionWithoutLosingRawDuplicateQuarantine() {
        let pending = ChatMessage(id: "submission:queued", role: .user, text: "Queued follow-up")
        let reply = ChatMessage(id: "reply", role: .assistant, text: "Current reply")
        let queue = QueuedMessage(id: "queued", text: pending.text, submissionID: "queued")
        let plan = NativeTranscriptMessagePlan([reply, pending], queuedMessages: [queue])
        #expect(plan.entries.map(\.message.id) == [reply.id])
        #expect(NativeTranscriptMessagePlan([reply, pending]).entries.map(\.message.id) == [reply.id, pending.id])
        let duplicate = ChatMessage(id: reply.id, role: .assistant, text: "Duplicate")
        let ambiguous = NativeTranscriptMessagePlan([reply, duplicate, pending], queuedMessages: [queue])
        #expect(ambiguous.entries.count == 2 && ambiguous.entries.allSatisfy(\.isAmbiguous))
        let exactQueue = QueuedMessage(id: "unicode", text: "Exact", submissionID: "é")
        let byteDistinct = ChatMessage(id: "submission:e\u{301}", role: .user, text: "Keep byte-distinct content")
        #expect(NativeTranscriptMessagePlan([byteDistinct], queuedMessages: [exactQueue]).entries.count == 1)
    }
    @Test func realPublicationRetainsDuplicatePayloadsWithoutNativeTrapOrAmbiguousFileExecution() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        let first = ChatMessage(id: "duplicate", role: .assistant, text: "::preview{file=\"report.html\"}")
        service.snapshots[session.root] = .init(id: session.root.text, storedID: session.stored.text,
            profileID: session.profile.text, messages: [first])
        service.downloadData = Data("<!doctype html><html><body><p>Previously trusted document.</p></body></html>".utf8)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-identity.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let owner = try #require(store.chats.screen(profile: service.profile)?.owner)
        await store.chats.refreshDirectory(owner); store.chats.displayed(owner)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: Host(store: store)), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let originalDocument = try await MountedReplyFileDocument.waitForText("Previously trusted document", in: host.view,
            phase: "initial duplicate publication", diagnostics: { "downloads=\(service.downloads) ownerCurrent=\(store.chats.isCurrent(owner)) opening=\(store.chats.screen(profile: service.profile)?.isOpening ?? true) items=\(self.collectionController(host)?.collection.numberOfItems(inSection: 0) ?? -1)" })
        let originalDownloads = service.downloads
        let incoming = [first,
            ChatMessage(id: "duplicate", role: .user, text: "Second duplicate remains literal and visible"),
            ChatMessage(id: "é", role: .assistant, text: "Byte distinct one"),
            ChatMessage(id: "e\u{301}", role: .assistant, text: "Byte distinct two")]
        service.snapshots[session.root]?.messages = incoming
        service.onEvent?(.conversation(try service.publication(session)))
        let screen = try #require(store.chats.screen(profile: service.profile))
        let published = try #require(screen.snapshot)
        #expect(published.messages.map { Data($0.text.utf8) } == incoming.map { Data($0.text.utf8) })
        let unsafeOldIDs = published.messages.map { NativeTranscriptItemID.message(Data($0.id.utf8)) }
        #expect(Set(unsafeOldIDs).count < unsafeOldIDs.count, "the former uniqueKeys/diffable precondition is violated by a real accepted publication")
        let plan = NativeTranscriptMessagePlan(published.messages)
        #expect(plan.hasAmbiguity && plan.entries.filter(\.isAmbiguous).count == 2)
        #expect(plan.entries.map { Data($0.message.text.utf8) } == incoming.map { Data($0.text.utf8) })
        #expect(Set(plan.entries.map(\.id)).count == incoming.count)
        #expect(plan.entries[2].id == .message(Data("é".utf8)))
        #expect(plan.entries[3].id == .message(Data("e\u{301}".utf8)))
        store.chats.displayed(screen.owner)
        let block = try #require(ReplyContent(message: first).blocks.first)
        #expect(!store.richReplyContext(for: service.profile.text, messageID: first.id).permits(block),
            "raw duplicate evidence also revokes the producing context")
        try await wait("native adapter shows every occurrence plus notice without old document") {
            collectionController(host)?.collection.numberOfItems(inSection: 0) == 6 && webViews(host.view).isEmpty
        }
        #expect(service.downloads == originalDownloads)
        // Uniqueness restoration is a new current render, not a forged action for
        // either formerly ambiguous occurrence.
        service.snapshots[session.root]?.messages = [first, incoming[2], incoming[3]]
        service.onEvent?(.conversation(try service.publication(session)))
        let restored = try #require(store.chats.screen(profile: service.profile))
        store.chats.displayed(restored.owner)
        let restoredPlan = NativeTranscriptMessagePlan(try #require(restored.snapshot).messages)
        #expect(!restoredPlan.hasAmbiguity)
        // Scroll the ordinary, now-unique item into view using the native public
        // user-navigation seam; no UI adapter recovery/retry is introduced.
        try await wait("restored current native snapshot") { collectionController(host)?.collection.numberOfItems(inSection: 0) == 4 }
        let controller = try #require(collectionController(host))
        controller.collection.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
        let restoredDocument = try await MountedReplyFileDocument.waitForText("Previously trusted document", in: host.view,
            excluding: originalDocument, phase: "restored duplicate publication",
            diagnostics: { "downloads=\(service.downloads) ownerCurrent=\(store.chats.isCurrent(owner)) opening=\(store.chats.screen(profile: service.profile)?.isOpening ?? true) items=\(self.collectionController(host)?.collection.numberOfItems(inSection: 0) ?? -1)" })
        #expect(restoredDocument !== originalDocument && originalDocument.superview == nil)
        #expect(service.downloads == originalDownloads, "A fresh unique renderer may reuse the original captured bytes")
        // Keep duplicate prompts as distinct rows, without response controls.
        let request = PendingRequest(id: "duplicate-request", kind: .approval, title: "Conflicting request", choices: [.init(id: "once", label: "Allow once")])
        service.snapshots[session.root]?.pendingRequests = [request, request]
        let requests = try service.publication(session)
        service.onEvent?(.conversation(requests)); service.onEvent?(.conversation(requests))
        let requestScreen = try #require(store.chats.screen(profile: service.profile))
        #expect(requestScreen.requests.count == 2)
        #expect(Set(requestScreen.requests.map(\.id)).count == 2)
        let requestPlan = NativeTranscriptRequestPlan(requestScreen.requests)
        #expect(requestPlan.hasAmbiguity && requestPlan.entries.allSatisfy(\.isAmbiguous))
        #expect(Set(requestPlan.entries.map(\.id)).count == 2)
        let repeatedRowPlan = NativeTranscriptRequestPlan([requestScreen.requests[0], requestScreen.requests[0]])
        #expect(repeatedRowPlan.hasAmbiguity && repeatedRowPlan.entries.allSatisfy(\.isAmbiguous))
        #expect(Set(repeatedRowPlan.entries.map(\.id)).count == 2)
        try await wait("both ambiguous requests stay represented without native trap") {
            collectionController(host)?.collection.numberOfItems(inSection: 0) == 7
        }
        #expect(service.responses.isEmpty)
    }
    @Test(arguments: ["duplicate", "differentContent", "auxiliary"])
    func suppliedNativeRowsCannotManufactureMessageAuthorityFromDisplayLookup(shape: String) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let message = ChatMessage(id: "raw-authority", role: .assistant, text: "::preview{file=\"report.html\"}")
        service.snapshots[identity.root]?.messages = [message]
        service.downloadData = Data("<!doctype html><html><body>Raw authority</body></html>".utf8)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-raw-authority.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let workspace = store.chats, owner = try #require(workspace.screen(profile: service.profile)?.owner)
        await workspace.refreshDirectory(owner); workspace.displayed(owner)
        if shape == "duplicate" {
            service.snapshots[identity.root]?.messages.append(message)
            service.onEvent?(.conversation(try service.publication(identity)))
        }
        let screen = try #require(workspace.screen(profile: service.profile))
        let rich = store.richReplyContext(for: service.profile.text, messageID: message.id)
        let block = try #require(ReplyContent(message: message).blocks.first)
        #expect(rich.permits(block) == (shape != "duplicate"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }, controller = NativeTranscriptController(), window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { controller.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        var supplied = message
        if shape == "differentContent" { supplied.text += "\nDifferent supplied content" }
        let value = shape == "auxiliary" ? NativeTranscriptRowValue.auxiliary("geometry-only") : .message(supplied, working: false)
        let row = NativeTranscriptRow(id: .message(Data(message.id.utf8)), value: value) { _, _ in
            AnyView(AssistantReplyBody(message: message, isStreaming: false).environment(\.richReplyContext, rich).environment(\.scenePhase, .active))
        }
        let context = NativeTranscriptContext(workspace: ObjectIdentifier(workspace), profile: Data(service.profile.text.utf8),
            chat: screen.selectedChatID, owner: owner, generation: store.artifactGeneration, reviewingConnection: false)
        controller.apply(context, snapshot: screen.snapshot, rows: [row], active: true, currentTaskSnapshot: {
            guard store.chats === workspace, workspace.isCurrent(owner) else { return nil }
            return workspace.screen(profile: service.profile)?.snapshot
        })
        try await wait("malformed supplied row has a real hosted geometry") {
            guard let cell = controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell,
                  let root = cell.exposure?.rowGeometry else { return false }
            return root.window === window && root.bounds.height > 0 && cell.isDisplayed
        }
        let scope = try #require((controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)?.exposure)
        #expect(!scope.canPresent && scope.isCurrent == (shape == "auxiliary"))
        var reports = 0
        // An unrestricted standalone context cannot bypass native row authority.
        #expect(RichReplyContext.isolated.permits(block))
        scope.present(block: block, context: .isolated, mode: .source) { _, _ in reports += 1 }
        #expect(controller.presentedViewController == nil && reports == 0)
        #expect(service.downloads == 0 && webViews(controller.view).isEmpty)
    }
    private struct Host: View {
        let store: AppStore
        @State private var presentation = WorkspacePresentation()
        var body: some View {
            if let bot = store.selectedBot {
                transcriptFixture(store: store, bot: bot, presentation: presentation)
                    .frame(width: 382, height: 434).environment(\.scenePhase, .active)
            }
        }
    }
    private func collectionController(_ parent: UIViewController) -> NativeTranscriptController? {
        if let controller = parent as? NativeTranscriptController, controller.isViewLoaded, controller.view.window != nil { return controller }
        return parent.children.lazy.compactMap(collectionController).first
    }
    private func element(_ label: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 30, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let view = object as? UIView, view.isHidden || view.alpha == 0 || view.window == nil { return nil }
            if object.accessibilityLabel == label { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let found = find(child, depth: depth + 1) { return found } }
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
    private func webViews(_ view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
    /// Evaluates the condition only inside the shared wait, so a condition that acts runs once per poll.
    private func wait(_ reason: String, until condition: () -> Bool) async throws {
        try #require(await waitWhile(reason) { !condition() }, "Timed out: \(reason)")
    }

    @Test func nativeReconfigurationUsesExactPayloadBytesRatherThanCanonicalStringEquality() {
        let first = ChatMessage(id: "message", role: .assistant, text: "é")
        let second = ChatMessage(id: "message", role: .assistant, text: "e\u{301}")
        #expect(first == second, "the domain's String equality is not a render-byte revision")
        #expect(NativeTranscriptRowValue.message(first, working: false) != .message(second, working: false))
        #expect(NativeTranscriptRowValue.auxiliary("é") != .auxiliary("e\u{301}"))
        let request = PendingRequest(id: "request", kind: .question, title: "é")
        let changed = PendingRequest(id: "request", kind: .question, title: "e\u{301}")
        #expect(NativeTranscriptRowValue.request(request, enabled: true) != .request(changed, enabled: true))
    }
}
