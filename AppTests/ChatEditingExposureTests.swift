import SwiftUI
import UIKit
import Observation
import Testing
import UniformTypeIdentifiers
import BottoCore
@testable import Botto

@Suite(RichReplyRuntime(), .serialized) @MainActor struct ChatEditingExposureTests {
    @Test func offlinePasteGuidanceClearsWhenTheSocketRecoversWithoutChatAccess() async throws {
        let f = try await fixture()
        defer { f.close() }
        f.service.onEvent?(.disconnected("Offline"))
        f.store.chats.retireConnection()
        try await Task.sleep(for: .milliseconds(100))
        let owner = try #require(f.store.chats.screen(profile: f.service.profile)?.owner)
        let editor = try #require(f.editor)
        try #require(editor.isEditable)
        try pasteImage(in: editor)
        let guidance = "Connect to the bot, then paste again."
        try await ready("offline paste guidance is visible") { self.accessibilityNode(guidance, in: f.host.view) != nil }
        f.service.onEvent?(.connected(.init(version: "test")))
        try await ready { f.store.isConnected }
        #expect(f.store.chats.screen(profile: f.service.profile)?.owner == owner)
        try await ready("offline guidance clears on socket recovery") { self.accessibilityNode(guidance, in: f.host.view) == nil }
        #expect(f.service.uploads.isEmpty)
    }

    @Test func busyPasteGuidanceClearsWhenAnUploadDrainsWithoutChangingOwner() async throws {
        let f = try await fixture()
        defer { f.close() }
        let owner = try #require(f.store.chats.screen(profile: f.service.profile)?.owner)
        let gate = WorkspaceGate()
        defer { gate.release() }
        f.service.uploadGate = gate
        let intent = try #require(f.store.chats.captureImport(owner))
        let upload = Task { await f.store.chats.upload(Data([1]), filename: "held.txt", mimeType: "text/plain", to: intent) }
        await gate.entered()
        try await Task.sleep(for: .milliseconds(100))
        try pasteImage(in: try #require(f.editor))
        let guidance = "Wait for the current attachment to finish."
        try await ready("busy guidance is visible") { self.accessibilityNode(guidance, in: f.host.view) != nil }
        gate.release(); await upload.value
        #expect(f.store.chats.screen(profile: f.service.profile)?.owner == owner)
        try await ready("busy guidance clears without an owner change") { self.accessibilityNode(guidance, in: f.host.view) == nil }
        #expect(f.service.uploads.count == 1)
    }

    private func pasteImage(in editor: NativeComposerTextView) throws {
        let pasteboard = try #require(UIPasteboard(name: .init("botto-feedback-paste-\(UUID())"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        pasteboard.items = [[UTType.png.identifier: try #require(image.pngData())]]
        editor.pasteboard = pasteboard
        editor.paste(nil)
    }

    @Test func pasteGuidanceClearsAfterTheChatFinishesOpening() async throws {
        let f = try await fixture()
        defer { f.close() }
        let gate = WorkspaceGate()
        defer { gate.release() }
        f.service.openGate = gate
        let bot = try #require(f.store.bots.first)
        let opening = Task { await f.store.open(bot) }
        await gate.entered()
        try await Task.sleep(for: .milliseconds(100))
        let editor = try #require(f.editor)
        try #require(editor.isEditable)
        let pasteboard = try #require(UIPasteboard(name: .init("botto-recovery-paste-\(UUID())"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        pasteboard.items = [[UTType.png.identifier: try #require(image.pngData())]]
        editor.pasteboard = pasteboard
        editor.paste(nil)
        let guidance = "The chat is opening. Paste again when it’s ready."
        try await ready("opening paste guidance is visible") { self.accessibilityNode(guidance, in: f.host.view) != nil }
        gate.release(); await opening.value
        try await ready("paste guidance clears after recovery") { self.accessibilityNode(guidance, in: f.host.view) == nil }
        #expect(f.service.uploads.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTTO_RUN_WIDE_IMPORT_TESTS"] == "1"),
          arguments: ["reader", "renew", "cancel", "page"], [false, true])
    func importsFollowPaneExposureAndReportInterruptions(action: String, duringUpload: Bool) async throws {
        let f = try await fixture()
        defer { f.close() }
        try #require(f.window.bounds.width >= 681, "Run wide import checks in an iPad window")
        f.state.width = 950; f.state.compact = false
        let identity = try #require(f.service.completedOpens.last?.identity)
        let files = [ChatAttachment(name: "first.txt", path: "/first.txt", mimeType: "text/plain"),
                     ChatAttachment(name: "second.txt", path: "/second.txt", mimeType: "text/plain")]
        let message = ChatMessage(id: identity.stored.text + ":row:1", role: .assistant, text: "Files", attachments: files)
        f.service.snapshots[identity.root]?.messages = [message]
        f.store.chats.receive(try f.service.publication(identity))
        let destination = try #require(f.store.artifactDestination(for: files[0], botID: f.service.profile.text, producingMessage: message))
        f.state.presentation.openArtifact(destination, store: f.store)
        try await ready("paired editor and loaded reader") { f.editor?.isEditable == true && f.state.presentation.artifact?.file != nil }
        let owner = try #require(f.store.chats.screen(profile: f.service.profile)?.owner)
        let gate = WorkspaceGate()
        defer { gate.release() }
        if duringUpload { f.service.uploadGate = gate }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        let bytes = try #require(image.pngData())
        func item(_ name: String, held: Bool) -> PastedAttachment {
            let provider = NSItemProvider(); provider.suggestedName = name
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                if held { Task { @MainActor in await gate.wait(); completion(bytes, nil) } }
                else { completion(bytes, nil) }
                return nil
            }
            return PastedAttachment(provider: provider, type: .png)
        }
        let paste = try #require(f.editor?.pasteAttachments)
        paste(owner, [item("first.png", held: !duringUpload), item("second.png", held: false)])
        await gate.entered()
        try await ready("visible Cancel All control") { self.accessibilityNode("Cancel All", in: f.host.view) != nil }
        switch action {
        case "reader":
            f.state.presentation.setArtifactExpanded(true, id: destination.id)
            try await ready { f.editor?.isEditable == false }
        case "renew": f.store.chats.receive(try f.service.publication(identity))
        case "cancel":
            let cancel = try #require(accessibilityNode("Cancel All", in: f.host.view))
            try #require(cancel.accessibilityActivate())
            try await ready("Cancel independently shows its notice") {
                self.accessibilityNode("Attachment import stopped. Check the attached files before sending.", in: f.host.view) != nil
            }
            #expect(f.store.chats.screen(profile: f.service.profile)?.isUploading == duringUpload)
            f.state.rootCovered = true
            try await ready { f.editor?.isEditable == false }
            f.state.rootCovered = false
        default:
            f.state.presentation.moveArtifact(by: 1, id: destination.id, store: f.store)
            try await ready { f.state.presentation.artifact?.title == "second.txt" }
        }
        if action != "page", action != "reader" {
            try await ready("interruption notice") { self.accessibilityNode("Attachment import stopped. Check the attached files before sending.", in: f.host.view) != nil }
        }
        f.service.uploadGate = nil
        gate.release()
        try await Task.sleep(for: .milliseconds(150))
        try await ready { f.store.chats.screen(profile: f.service.profile)?.isUploading == false }
        let screen = try #require(f.store.chats.screen(profile: f.service.profile))
        #expect(screen.attachments.count == (action == "page" ? 2 : 0))
        #expect(f.service.uploads.count == (action == "page" ? 2 : duringUpload ? 1 : 0))
        if action == "reader" {
            f.state.presentation.setArtifactExpanded(false, id: destination.id)
            try await ready { f.editor?.isEditable == true }
            try await ready { self.accessibilityNode("Attachment import stopped. Check the attached files before sending.", in: f.host.view) != nil }
        }
        if action != "page" {
            try await ready { f.editor?.isEditable == true }
            let current = try #require(f.store.chats.screen(profile: f.service.profile))
            f.editor?.pasteAttachments?(current.owner, [item("retry.png", held: false)])
            try await ready { f.store.chats.screen(profile: f.service.profile)?.attachments.map(\.name) == ["retry.png"] }
            try await ready { self.accessibilityNode("Attachment import stopped. Check the attached files before sending.", in: f.host.view) == nil }
        }
    }

    private func accessibilityNode(_ label: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.accessibilityLabel == label { return object }
            var children: [NSObject] = (object as? UIView)?.subviews ?? []
            children += (object.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            children += (object.automationElements ?? []).compactMap { $0 as? NSObject }
            let count = object.accessibilityElementCount()
            if count > 0, count < 4096 { children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject } }
            for child in children { if let found = find(child) { return found } }
            return nil
        }
        return find(root)
    }

    @Test func aChatOnlyZeroAllocationFencesReadsWithoutDisablingItsFocusedNativeEditor() async throws {
        let f = try await fixture()
        defer { f.close() }
        let editor = try #require(f.editor)
        try #require(editor.becomeFirstResponder())
        let exact = "  Geometry keeps this draft\n  exact spaces  "
        editor.insertText(exact)
        f.state.width = 0
        try await ready { f.state.observedWidth == 0 }
        #expect(!f.state.readExposed && !f.state.toolbarAvailable)
        try #require(editor.isEditable && editor.isUserInteractionEnabled,
                     "Geometry-only zero allocation must not revoke semantic chat editing")
        try #require(editor.isFirstResponder, "The existing responder remains; no restoration is requested")
        #expect(f.editor === editor && f.store.chats.draft(f.owner) == exact)
        f.state.width = 517
        try await ready { abs(f.state.observedWidth - 517) < 1 }
        #expect(editor.isFirstResponder && editor.isEditable)
        editor.insertText(" + visible")
        #expect(f.store.chats.draft(f.owner) == exact + " + visible")
        #expect(f.service.opens.count == 1 && f.service.sends.isEmpty)
    }

    @Test func editingPolicySeparatesChatOnlyAllocationFromReadingAndRetainsAllCoverRules() {
        for compact in [false, true] {
            for width: CGFloat in [0, 48, 382, 951] {
                let layout = WorkspaceLayout(compact: compact, accessibilityText: false, workspaceWidth: width)
                func editing(file: Bool = false, expanded: Bool = false, browse: Bool = false,
                             root: Bool = false, local: Bool = false, active: Bool = true) -> Bool {
                    layout.editorExposed(browsingBots: browse, hasArtifact: file, expanded: expanded,
                        rootCovered: root, localCovered: local, sceneActive: active, compactShowsSidebar: true)
                }
                #expect(editing())
                #expect(!editing(browse: true) && !editing(root: true) && !editing(local: true) && !editing(active: false))
                #expect(!editing(file: true, expanded: true))
                if width == 0 { #expect(!layout.transcriptExposed(browsingBots: false, hasArtifact: false, expanded: false,
                    rootCovered: false, localCovered: false, sceneActive: true, compactShowsSidebar: false)) }
                if compact || width < 681 { #expect(!editing(file: true)) }
            }
        }
    }

    @Test(arguments: ["root", "bots", "inactive", "file"])
    func semanticCoversStillEndNativeEditingAndFenceDraftWrites(cover: String) async throws {
        let f = try await fixture()
        defer { f.close() }
        let editor = try #require(f.editor)
        try #require(editor.becomeFirstResponder())
        editor.insertText("  Keep this source draft\n")
        switch cover {
        case "root": f.state.rootCovered = true
        case "bots": f.state.presentation.browseBots()
        case "inactive": f.state.active = false
        default:
            let destination = try #require(f.store.artifactDestination(for:
                .init(name: "notes.txt", path: "/notes.txt", mimeType: "text/plain"), botID: f.service.profile.text))
            f.state.presentation.openArtifact(destination, store: f.store)
        }
        try await ready { !editor.isEditable && !editor.isFirstResponder }
        editor.insertText("stale covered input")
        #expect(f.store.chats.draft(f.owner) == "  Keep this source draft\n")
        #expect(f.service.sends.isEmpty)
    }

    private func ready(_ reason: String = "hosted view must settle", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), Comment(rawValue: reason))
    }
    private func fixture() async throws -> Fixture {
        let service = try WorkspaceTestService()
        service.downloadData = Data("Local notes".utf8)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://editing-exposure.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let owner = try #require(store.chats.screen(profile: service.profile)?.owner)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let state = ExposureState()
        let host = ExposureHostingController(rootView: ExposureHost(store: store, bot: try #require(store.bots.first), state: state))
        let f = Fixture(service: service, store: store, owner: owner, cacheID: configuration.id, state: state, scene: scene, host: host)
        f.window.makeKeyAndVisible(); f.window.layoutIfNeeded()
        try await ready { host.hasAppeared && host.transitionCoordinator == nil && f.window.isKeyWindow && f.editor?.isEditable == true && f.state.observedWidth > 0 }
        return f
    }

    @MainActor @Observable final class ExposureState {
        var width: CGFloat = 382
        var observedWidth: CGFloat = -1
        var rootCovered = false
        var active = true
        var compact = true
        let presentation = WorkspacePresentation()
        var layout: WorkspaceLayout { .init(compact: compact, accessibilityText: false, workspaceWidth: width) }
        var allocation: WorkspacePaneAllocation {
            layout.allocation(hasArtifact: presentation.artifact != nil, browsingBots: presentation.isBrowsingBots,
                              expanded: presentation.isArtifactExpanded)
        }
        var readExposed: Bool {
            layout.transcriptExposed(browsingBots: presentation.isBrowsingBots, hasArtifact: presentation.artifact != nil,
                expanded: presentation.isArtifactExpanded, rootCovered: rootCovered, localCovered: false,
                sceneActive: active, compactShowsSidebar: presentation.isBrowsingBots)
        }
        var editingExposed: Bool {
            layout.editorExposed(browsingBots: presentation.isBrowsingBots, hasArtifact: presentation.artifact != nil,
                expanded: presentation.isArtifactExpanded, rootCovered: rootCovered, localCovered: false,
                sceneActive: active, compactShowsSidebar: presentation.isBrowsingBots)
        }
        var toolbarAvailable: Bool { readExposed && width > 0 }
    }
    private struct ExposureHost: View {
        let store: AppStore
        let bot: BotProfile
        let state: ExposureState
        var body: some View {
            GeometryReader { geometry in
                RetainedWorkspacePane(width: state.width, height: geometry.size.height,
                    initialWidth: WorkspaceLayout.minimumChatWidth,
                    isSemanticallyVisible: (state.presentation.artifact == nil || state.allocation.chatVisible) && !state.presentation.isBrowsingBots) {
                    ChatView(store: store, bot: bot, presentation: state.presentation,
                        isExposed: state.readExposed, isEditingExposed: state.editingExposed,
                        importPaneVisible: state.presentation.artifact == nil || state.allocation.chatVisible, rootCovered: state.rootCovered,
                        onLocalModalPresentation: { _ in }, canPresentToolbar: { state.toolbarAvailable },
                        canContinueEditing: { state.editingExposed })
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { state.observedWidth = $0 }
            }
            .environment(\.scenePhase, state.active ? .active : .inactive)
        }
    }

    @MainActor private final class Fixture {
        let service: WorkspaceTestService
        let store: AppStore
        let owner: PresentationOwner
        let cacheID: UUID
        let state: ExposureState
        let window: UIWindow
        let host: ExposureHostingController<ExposureHost>
        weak var previous: UIWindow?
        init(service: WorkspaceTestService, store: AppStore, owner: PresentationOwner, cacheID: UUID,
             state: ExposureState, scene: UIWindowScene, host: ExposureHostingController<ExposureHost>) {
            self.service = service; self.store = store; self.owner = owner; self.cacheID = cacheID; self.state = state; self.host = host
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); window.rootViewController = host
        }
        var editor: NativeComposerTextView? {
            @MainActor func find(_ view: UIView) -> NativeComposerTextView? {
                if let editor = view as? NativeComposerTextView { return editor }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(host.view)
        }
        func close() {
            if let session = state.presentation.artifact { state.presentation.closeArtifact(id: session.id) }
            editor?.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.forgetConnection(); LocalHistory.remove(for: cacheID)
        }
    }
}

@MainActor private final class ExposureHostingController<Content: View>: UIHostingController<Content> {
    private(set) var hasAppeared = false
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); hasAppeared = true }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); hasAppeared = false }
}
