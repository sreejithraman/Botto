import SwiftUI
import UIKit
import Observation
import Testing
import BottoCore
@testable import Botto

@Suite(.serialized) @MainActor struct ChatEditingExposureTests {
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

    private func ready(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
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
        let presentation = WorkspacePresentation()
        var layout: WorkspaceLayout { .init(compact: true, accessibilityText: false, workspaceWidth: width) }
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
                    isSemanticallyVisible: state.presentation.artifact == nil && !state.presentation.isBrowsingBots) {
                    ChatView(store: store, bot: bot, presentation: state.presentation,
                        isExposed: state.readExposed, isEditingExposed: state.editingExposed, rootCovered: state.rootCovered,
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
