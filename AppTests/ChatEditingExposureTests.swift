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
        let guidance = "The space is opening. Paste again when it’s ready."
        try await ready("opening paste guidance is visible") { self.accessibilityNode(guidance, in: f.host.view) != nil }
        gate.release(); await opening.value
        try await ready("paste guidance clears after recovery") { self.accessibilityNode(guidance, in: f.host.view) == nil }
        #expect(f.service.uploads.isEmpty)
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

    @Test(arguments: [false, true])
    func cancelAllStopsAHeldPasteAndKeepsItsNoticeUntilRetry(duringUpload: Bool) async throws {
        let f = try await fixture()
        defer { f.close() }
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
        let notice = "Attachment import stopped. Check the attached files before sending."
        try await ready("visible Cancel All control") { self.accessibilityNode("Cancel All", in: f.host.view) != nil }
        let cancel = try #require(accessibilityNode("Cancel All", in: f.host.view))
        try #require(cancel.accessibilityActivate())
        try await ready("Cancel All shows its notice") { self.accessibilityNode(notice, in: f.host.view) != nil }
        #expect(f.store.chats.screen(profile: f.service.profile)?.isUploading == duringUpload)
        // Release the held import before any cover: a cover also stops imports, so only
        // checking afterwards could not tell Cancel All apart from the cover.
        f.service.uploadGate = nil
        gate.release()
        try await Task.sleep(for: .milliseconds(150))
        try await ready { f.store.chats.screen(profile: f.service.profile)?.isUploading == false }
        #expect(f.store.chats.screen(profile: f.service.profile)?.attachments.isEmpty == true)
        #expect(f.service.uploads.count == (duringUpload ? 1 : 0))
        f.state.rootCovered = true
        try await ready { f.editor?.isEditable == false }
        f.state.rootCovered = false
        try await ready("the notice outlasts a cover") { self.accessibilityNode(notice, in: f.host.view) != nil }
        try await ready { f.editor?.isEditable == true }
        let current = try #require(f.store.chats.screen(profile: f.service.profile))
        f.editor?.pasteAttachments?(current.owner, [item("retry.png", held: false)])
        try await ready { f.store.chats.screen(profile: f.service.profile)?.attachments.map(\.name) == ["retry.png"] }
        try await ready("a retry clears the notice") { self.accessibilityNode(notice, in: f.host.view) == nil }
    }

    @Test(arguments: ["root", "inactive", "file"])
    func semanticCoversStillEndNativeEditingAndFenceDraftWrites(cover: String) async throws {
        let f = try await fixture()
        defer { f.close() }
        let editor = try #require(f.editor)
        try #require(editor.becomeFirstResponder())
        editor.insertText("  Keep this source draft\n")
        switch cover {
        case "root": f.state.rootCovered = true
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
        await waitWhile(reason) { !condition() }
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
        try await ready { host.hasAppeared && host.transitionCoordinator == nil && f.window.isKeyWindow && f.editor?.isEditable == true }
        return f
    }

    /// Mirrors T3Workspace: an open file covers the conversation, and actions need an active scene.
    @MainActor @Observable final class ExposureState {
        var rootCovered = false
        var active = true
        let presentation = WorkspacePresentation()
        var covered: Bool { rootCovered || presentation.artifact != nil }
        var actionsAvailable: Bool { !covered && active }
    }
    private struct ExposureHost: View {
        let store: AppStore
        let bot: BotProfile
        let state: ExposureState
        var body: some View {
            ChatView(store: store, bot: bot, presentation: state.presentation,
                    isExposed: !state.covered, isEditingExposed: !state.covered,
                    importPaneVisible: state.presentation.artifact == nil, rootCovered: state.covered,
                    onLocalModalPresentation: { _ in }, canPresentToolbar: { state.actionsAvailable },
                    canContinueEditing: { state.actionsAvailable })
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
