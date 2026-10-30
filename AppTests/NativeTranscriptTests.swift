import Testing
import SwiftUI
import UIKit
import BottoCore
import WebKit
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct NativeTranscriptTests {
    @Test func asynchronousSameCellGrowthKeepsTheActualTerminalVisibleWithoutAnotherApply() async throws {
        let fixture = try growthFixture()
        defer { fixture.close() }
        try await wait("initial actual terminal") { fixture.terminalIsVisible }
        fixture.state.height = 900
        try await wait("hosted same cell grew") { fixture.leadingHeight > 899 }
        try await wait("actual terminal after asynchronous same-cell growth") { fixture.terminalIsVisible }
        try await wait("content extent matches the rendered terminal after growth") { fixture.hasExactContentExtent }
        fixture.state.height = 120
        try await wait("shrinking content keeps the actual terminal and extent together") {
            abs(fixture.leadingHeight - 120) < 1 && fixture.terminalIsVisible && fixture.hasExactContentExtent
        }
    }

    @Test func asynchronousPrecedingBlockGrowthPreservesAnOlderBlockInsideTheSameCell() async throws {
        let fixture = try growthFixture()
        defer { fixture.close() }
        try await wait("initial actual terminal") { fixture.terminalIsVisible }
        let marker = try #require(fixture.markers.first { $0.block == 1 })
        let position = marker.convert(marker.bounds, to: fixture.controller.collection).minY
        fixture.controller.collection.setContentOffset(CGPoint(x: 0, y: position), animated: false)
        fixture.controller.scrollViewDidEndDragging(fixture.controller.collection, willDecelerate: false)
        let originalY = marker.convert(marker.bounds, to: fixture.window).minY
        fixture.state.height = 700
        try await wait("preceding native block grew") { fixture.leadingHeight > 699 }
        try await wait("older visible block remains at its real viewport landmark") {
            abs(marker.convert(marker.bounds, to: fixture.window).minY - originalY) < 1
        }
        let readingOffset = fixture.controller.collection.contentOffset.y
        fixture.state.tailHeight = 1600
        try await wait("content below the older block grew") {
            (fixture.controller.collection.cellForItem(at: IndexPath(item: 0, section: 0))?.frame.height ?? 0) > 2400
        }
        #expect(abs(marker.convert(marker.bounds, to: fixture.window).minY - originalY) < 1)
        #expect(abs(fixture.controller.collection.contentOffset.y - readingOffset) < 1,
            "growth below the landmark must not apply the whole-cell delta")
        fixture.state.height = 300
        try await wait("shorter preceding block preserves actual older position") {
            abs(fixture.leadingHeight - 300) < 1 && abs(marker.convert(marker.bounds, to: fixture.window).minY - originalY) < 1
        }
        let latest = try #require(fixture.controller.view.subviews.compactMap { $0 as? UIButton }.first)
        #expect(!latest.isHidden)
        latest.sendActions(for: .touchUpInside)
        try await wait("explicit native Latest shows actual terminal") { fixture.terminalIsVisible }
    }

    @MainActor @Observable final class GrowthState {
        var height: CGFloat = 80
        var tailHeight: CGFloat = 1200
    }
    private struct GrowingRow: View {
        let state: GrowthState
        var body: some View {
            VStack(spacing: 0) {
                NativeTranscriptBlock(block: 0) { Color.clear.frame(height: state.height) }
                NativeTranscriptBlock(block: 1) { NativeText(text: "Older actual reading landmark").frame(height: 120) }
                Color.clear.frame(height: state.tailHeight)
            }
        }
    }
    private func growthFixture() throws -> GrowthFixture {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let fixture = GrowthFixture(scene: scene)
        let context = NativeTranscriptContext(workspace: ObjectIdentifier(fixture.state), profile: Data("same-cell".utf8),
            chat: ChatID(), owner: nil, generation: UUID(), reviewingConnection: false)
        let state = fixture.state
        let rows: [NativeTranscriptRow] = [
            .init(id: .message(Data("same-cell".utf8)), value: .auxiliary("unchanged"), content: { _, _ in AnyView(GrowingRow(state: state)) }),
            .init(id: .terminal, value: .auxiliary("terminal"), content: { _, _ in AnyView(Color.clear.frame(height: 1)) })]
        let snapshot = Conversation(id: "growth", storedID: "growth", profileID: "same-cell",
            messages: [.init(id: "same-cell", role: .assistant, text: "Actual growing native body")])
        fixture.controller.apply(context, snapshot: snapshot, rows: rows, active: true, currentTaskSnapshot: { snapshot })
        return fixture
    }
    @MainActor private final class GrowthFixture {
        let state = GrowthState(), controller = NativeTranscriptController()
        let window: UIWindow
        weak var previous: UIWindow?
        init(scene: UIWindowScene) {
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        }
        var terminalIsVisible: Bool {
            guard let cell = controller.collection.cellForItem(at: IndexPath(item: 1, section: 0)) else { return false }
            return cell.frame.intersects(controller.collection.bounds)
        }
        var hasExactContentExtent: Bool {
            guard let cell = controller.collection.cellForItem(at: IndexPath(item: 1, section: 0)),
                  let leading = controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell,
                  let root = leading.exposure?.rowGeometry,
                  abs(root.bounds.height - leading.bounds.height) < 1,
                  let layout = controller.collection.collectionViewLayout as? NativeTranscriptLayout else { return false }
            return abs(controller.collection.contentSize.height - cell.frame.maxY - layout.sectionInset.bottom) < 1
        }
        var markers: [NativeTranscriptBlockMarker] {
            func find(_ view: UIView) -> [NativeTranscriptBlockMarker] {
                (view as? NativeTranscriptBlockMarker).map { [$0] } ?? view.subviews.flatMap(find)
            }
            return find(controller.view)
        }
        var leadingHeight: CGFloat { markers.first { $0.block == 0 }?.bounds.height ?? 0 }
        func close() { controller.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    }

    @Test func coveredHeldFileCannotInstallAndAuthorityReplacementWithdrawsTheActualDocument() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        let message = ChatMessage(id: "native-file", role: .assistant, text: "::preview{file=\"report.html\"}")
        service.snapshots[session.root] = .init(id: session.root.text, storedID: session.stored.text,
            profileID: session.profile.text, messages: [message])
        service.downloadData = Data("<!doctype html><html><body><p>Native visible document.</p></body></html>".utf8)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-transcript.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = NativeTranscriptController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            service.downloadGate?.release(); controller.retire(); window.isHidden = true
            window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id)
        }
        func apply(active: Bool) {
            let screen = store.chats.screen(profile: service.profile), generation = store.artifactGeneration
            let richContext = store.richReplyContext(for: service.profile.text, messageID: message.id)
            let context = NativeTranscriptContext(workspace: ObjectIdentifier(store.chats), profile: Data(service.profile.text.utf8),
                chat: screen?.selectedChatID, owner: screen?.owner, generation: generation, reviewingConnection: store.showsConnection)
            let row = NativeTranscriptRow(id: .message(Data(message.id.utf8)), value: .message(message, working: false)) { scope, history in
                AnyView(ReplyBodyLayoutOwner(message: message, acceptsWrites: { scope.isCurrent && store.artifactGeneration == generation }, content: {
                    VStack(spacing: 0) {
                        AssistantReplyBody(message: message, isStreaming: false)
                            .environment(\.richReplyContext, richContext).id(generation)
                        Color.clear.frame(height: 1400)
                    }
                }, providedHistory: history).environment(\.scenePhase, .active))
            }
            let workspace = store.chats, owner = screen?.owner
            controller.apply(context, snapshot: screen?.snapshot, rows: [row, .init(id: .terminal, value: .auxiliary("terminal"), content: { _, _ in AnyView(Color.clear.frame(height: 1)) })], active: active, currentTaskSnapshot: {
                guard store.chats === workspace, store.artifactGeneration == generation,
                      let owner, workspace.isCurrent(owner) else { return nil }
                return workspace.screen(profile: service.profile)?.snapshot
            })
        }
        apply(active: false)
        await Task.yield()
        #expect(service.downloads == 0)
        let gate = WorkspaceGate(); service.downloadGate = gate
        apply(active: true)
        try await wait("native terminal committed while rich block is offscreen") {
            controller.collection.cellForItem(at: IndexPath(item: 1, section: 0))?.frame.intersects(controller.collection.bounds) == true
        }
        #expect(service.downloads == 0, "visible tall cell must not download its offscreen block")
        controller.collection.setContentOffset(.zero, animated: false)
        controller.scrollViewDidEndDragging(controller.collection, willDecelerate: false)
        try await wait("visible native block starts held file") { service.downloads == 1 }
        apply(active: false); gate.release(); service.downloadGate = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(webViews(controller.view).isEmpty, "late covered download cannot install a document")
        apply(active: true)
        try await wait("actual native hosted document") { service.downloads == 2 && !webViews(controller.view).isEmpty }
        store.forgetConnection(); apply(active: true)
        try await wait("real workspace retirement withdraws old document") { webViews(controller.view).isEmpty }
    }
    private func webViews(_ view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }

    @Test func nativeApplyReconfiguresAndAppendsActualSelfSizedContentAtLatest() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = NativeTranscriptController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { controller.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let workspace = NSObject()
        let context = NativeTranscriptContext(workspace: ObjectIdentifier(workspace), profile: Data("exact".utf8),
            chat: ChatID(), owner: nil, generation: UUID(), reviewingConnection: false)
        func rows(_ values: [String]) -> [NativeTranscriptRow] {
            values.enumerated().map { index, value in
                NativeTranscriptRow(id: .message(Data(String(index).utf8)), value: .auxiliary(value)) { _, _ in
                    AnyView(NativeText(text: value))
                }
            } + [.init(id: .terminal, value: .auxiliary("terminal"), content: { _, _ in AnyView(Color.clear.frame(height: 1)) })]
        }
        let initial = (0..<30).map { "Row \($0)\n" + String(repeating: "measured native content ", count: 8) }
        func snapshot(_ values: [String]) -> Conversation {
            .init(id: "native", storedID: "native", profileID: "exact", messages: values.enumerated().map {
                .init(id: String($0.offset), role: .assistant, text: $0.element)
            })
        }
        let firstSnapshot = snapshot(initial)
        controller.apply(context, snapshot: firstSnapshot, rows: rows(initial), active: true, currentTaskSnapshot: { firstSnapshot })
        try await wait("actual last initial row") { textViews(controller.view).contains { $0.text == initial.last && $0.convert($0.bounds, to: controller.collection).intersects(controller.collection.bounds) } }
        let replacement = initial.dropLast() + ["Short replacement", "Actual appended answer\n" + String(repeating: "new reply ", count: 20)]
        let nextSnapshot = snapshot(Array(replacement))
        controller.apply(context, snapshot: nextSnapshot, rows: rows(Array(replacement)), active: true, currentTaskSnapshot: { nextSnapshot })
        try await wait("actual appended native text and terminal inside viewport") {
            let index = IndexPath(item: replacement.count, section: 0)
            return textViews(controller.view).contains { $0.text == replacement.last && $0.convert($0.bounds, to: controller.collection).intersects(controller.collection.bounds) }
                && controller.collection.cellForItem(at: index)?.frame.intersects(controller.collection.bounds) == true
        }
        #expect(NativeTranscriptItemID.message(Data("é".utf8)) != .message(Data("e\u{301}".utf8)))
    }

    private struct NativeText: UIViewRepresentable {
        let text: String
        func makeUIView(context: Context) -> UITextView {
            let view = UITextView(); view.isScrollEnabled = false; view.isEditable = false
            view.font = .preferredFont(forTextStyle: .body); return view
        }
        func updateUIView(_ view: UITextView, context: Context) { view.text = text }
    }
    private func textViews(_ view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
    private func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Timed out: \(label)")
    }

    @Test func onlyDisplayedIntersectingBlocksReceiveExposureAndRetiredScopesCannotReturn() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let viewport = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        root.view.addSubview(viewport)
        let scope = NativeTranscriptRowExposure(viewport: viewport)
        let visible = NativeTranscriptBlockPresence(), below = NativeTranscriptBlockPresence()
        let first = NativeTranscriptBlockMarker(frame: CGRect(x: 0, y: 20, width: 300, height: 100))
        let second = NativeTranscriptBlockMarker(frame: CGRect(x: 0, y: 350, width: 300, height: 100))
        viewport.addSubview(first); viewport.addSubview(second)
        first.connect(scope: scope, presence: visible, block: 0)
        second.connect(scope: scope, presence: below, block: 1)
        scope.refresh()
        #expect(!visible.isVisible && !below.isVisible, "prefetch is not display")
        scope.setDisplayed(true); scope.setActive(true); scope.refresh()
        #expect(visible.isVisible && !below.isVisible, "cell presence cannot expose its offscreen block")
        viewport.bounds.origin.y = 300; scope.refresh()
        #expect(!visible.isVisible && below.isVisible)
        scope.setActive(false)
        #expect(!visible.isVisible && !below.isVisible, "covered chat withdraws all documents")
        scope.invalidate(); scope.setActive(true); scope.setDisplayed(true); scope.refresh()
        #expect(!visible.isVisible && !below.isVisible, "late reuse callbacks cannot revive retired content")
    }
}
