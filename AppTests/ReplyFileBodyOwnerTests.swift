import Testing
import SwiftUI
import UIKit
import WebKit
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct ReplyFileBodyOwnerTests {
    @Test func actualAuthorityReplacementKeepsOnlyDimensionsAndAcceptsShorterNewBody() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let state = fixture.state, store = fixture.store, service = fixture.service
        let identity = try identity(for: state.message)
        try await wait("initial rendered HTML and layout writer") {
            state.size.height > 500 && fixture.webViews.count == 1 &&
                state.access[store.artifactGeneration]?.measurement(for: identity) != nil
        }
        let initialHeight = state.size.height, firstGeneration = store.artifactGeneration
        let firstMount = try #require(state.mounts.last)
        let firstAccess = try #require(state.access[firstGeneration])
        try #require(firstAccess.measurement(for: identity) != nil)
        let context = store.richReplyContext(for: service.profile.text, messageID: state.message.id)
        let block = try #require(ReplyContent(message: state.message).blocks.first { $0.filePreview != nil })
        try #require(context.permits(block))

        // A newer directory hint causes the same public read/authority handoff
        // used by production. The stable message stays while its child .id resets.
        let readGate = WorkspaceGate(); service.openGate = readGate
        let session = service.summaries[0].identity
        service.summaries[0] = .init(identity: session, title: "Bot Chat", isCanonical: true,
            persistence: .durable, messageCount: 6)
        let screen = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(screen.owner)
        state.settled = false
        store.chats.setTranscriptVisible(true, owner: screen.owner)
        try #require(store.artifactGeneration != firstGeneration)
        #expect(!context.permits(block), "Dimension retention must not retain old render authority")
        try await wait("replacement child preserves pending body with no document") {
            state.mounts.last != firstMount && fixture.webViews.isEmpty && abs(state.size.height - initialHeight) < 2
        }
        #expect(service.downloads == 1)

        readGate.release()
        try await wait("actual read settles with a new layout writer") {
            store.chats.screen(profile: service.profile)?.isOpening == false && state.access[store.artifactGeneration] != nil
        }
        try await wait("post-read replacement keeps the same space") { abs(state.size.height - initialHeight) < 2 }
        #expect(!context.permits(block))

        let downloadGate = WorkspaceGate(); service.downloadGate = downloadGate
        service.downloadData = Data("<!doctype html><html><body><p>Short replacement.</p></body></html>".utf8)
        state.settled = true
        try await wait("new authority's replacement download is held") { service.downloads == 2 }
        #expect(fixture.webViews.isEmpty)
        #expect(abs(state.size.height - initialHeight) < 2)
        downloadGate.release()
        try await wait("short resolved body takes natural height") {
            fixture.webViews.count == 1 && state.size.height > 70 && state.size.height < initialHeight - 150
        }
        let shorterHeight = state.size.height
        state.settled = false
        try await wait("new pending state keeps the smaller measurement") {
            fixture.webViews.isEmpty && abs(state.size.height - shorterHeight) < 2
        }

        let currentAccess = try #require(state.access[store.artifactGeneration])
        let currentMeasurement = try #require(currentAccess.measurement(for: identity))
        // Exercise the same environment endpoint retained by the retired child.
        #expect(!firstAccess.observe(identity, size: .init(width: 477, height: 999), rendered: true))
        #expect(!firstAccess.observe(identity, size: .init(width: 601, height: 20), rendered: false))
        #expect(currentAccess.measurement(for: identity) == currentMeasurement)
        #expect(abs(state.size.height - shorterHeight) < 2)

        state.width = 601
        try await wait("different pending width discards history") { abs(state.size.width - 601) < 1 && state.size.height < 180 }
        state.width = 477
        try await wait("old width cannot revive history across owner retention") { abs(state.size.width - 477) < 1 && state.size.height < 180 }
        #expect(currentAccess.measurement(for: identity) == nil)
    }

    @Test func historyIsBoundedToCurrentExactDirectivesAndLatestLayout() throws {
        let history = ReplyBodyMeasurements()
        let message = ChatMessage(id: "dimension-message", role: .assistant, text: "::preview{file=\"café.html\"}")
        let original = try identity(for: message)
        history.observe(original, size: .init(width: 477, height: 397), rendered: true)
        history.observe(original, size: .init(width: 477, height: 19), rendered: false)
        #expect(history.measurement(for: original)?.size.height == 397)
        history.observe(original, size: .init(width: 477, height: 120), rendered: true)
        #expect(history.measurement(for: original)?.size.height == 120)

        history.observe(original, size: .init(width: 601, height: 0), rendered: false)
        #expect(history.measurement(for: original) == nil, "A quiet empty body must retire the old width's reservation")
        history.observe(original, size: .init(width: 477, height: 0), rendered: true)
        #expect(history.measurement(for: original) == nil, "An empty body is not a rendered height to reserve")
        history.observe(original, size: .init(width: 477, height: 120), rendered: true)

        let changed = ReplyBodyIdentity(directive: original.directive, dynamicType: .accessibility1,
            direction: original.direction, colorScheme: original.colorScheme, reduceMotion: original.reduceMotion)
        history.observe(changed, size: .init(width: 477, height: 25), rendered: false)
        #expect(history.measurement(for: original) == nil)
        history.observe(original, size: .init(width: 477, height: 397), rendered: true)
        let otherSource = try identity(for: .init(id: message.id, role: .assistant, text: "::preview{file=\"cafe\u{301}.html\"}"))
        #expect(original.directive != otherSource.directive, "Canonical Unicode equality must not alias source bytes")
        history.retainOnly([otherSource.directive])
        #expect(history.measurement(for: original) == nil)
        history.observe(otherSource, size: .init(width: 477, height: 300), rendered: true)
        history.retainOnly([])
        #expect(history.measurement(for: otherSource) == nil)
    }

    private func identity(for message: ChatMessage) throws -> ReplyBodyIdentity {
        let block = try #require(ReplyContent(message: message).blocks.first { $0.filePreview?.isHTML == true })
        return .init(directive: .init(message: Data(message.id.utf8), offset: block.id, raw: Data(block.rawText.utf8)),
            dynamicType: .large, direction: .leftToRight, colorScheme: .light, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    private func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Timed out: \(label)")
    }

    private func fixture() async throws -> Fixture {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        service.downloadData = Data("<!doctype html><html><body><div style='height:560px'>Tall initial preview.</div></body></html>".utf8)
        service.summaries[0] = .init(identity: session, title: "Bot Chat", isCanonical: true,
            persistence: .durable, messageCount: 4)
        let message = ChatMessage(id: "body-owner-message", role: .assistant, text: "::preview{file=\"report.html\"}")
        service.snapshots[session.root] = .init(id: session.root.text, storedID: session.stored.text,
            profileID: session.profile.text, messages: [message])
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://body-owner.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let screen = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(screen.owner); store.chats.displayed(screen.owner)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let state = OwnerState(message: message)
        let host = UIHostingController(rootView: OwnerHost(store: store, profile: service.profile.text, state: state))
        let fixture = Fixture(service: service, store: store, cacheID: configuration.id, scene: scene, host: host, state: state)
        fixture.window.makeKeyAndVisible(); fixture.window.layoutIfNeeded()
        return fixture
    }

    @MainActor @Observable final class OwnerState {
        let message: ChatMessage
        var settled = true
        var width: CGFloat = 477
        var size: CGSize = .zero
        var mounts: [UUID] = []
        var access: [UUID: ReplyBodyLayoutAccess] = [:]
        init(message: ChatMessage) { self.message = message }
    }

    private struct OwnerHost: View {
        let store: AppStore
        let profile: String
        let state: OwnerState
        var body: some View {
            let generation = store.artifactGeneration
            ScrollView {
                ForEach([state.message]) { message in
                    ReplyBodyLayoutOwner(message: message, acceptsWrites: { generation == store.artifactGeneration }) {
                        OwnerChild(state: state, generation: generation)
                            .environment(\.richReplyContext, store.richReplyContext(for: profile, messageID: message.id))
                            .id(generation)
                    }
                }
            }
            .environment(\.scenePhase, .active)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.colorScheme, .light)
        }
    }

    private struct OwnerChild: View {
        let state: OwnerState
        let generation: UUID
        @Environment(\.replyBodyLayout) private var access
        @State private var mount = UUID()
        var body: some View {
            AssistantReplyBody(message: state.message, isStreaming: false, filePreviewsAreSettled: state.settled)
                .frame(width: state.width)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { state.size = $0 }
                .onAppear {
                    state.mounts.append(mount)
                    state.access[generation] = access
                }
        }
    }

    @MainActor private final class Fixture {
        let service: WorkspaceTestService
        let store: AppStore
        let cacheID: UUID
        let state: OwnerState
        let window: UIWindow
        let host: UIHostingController<OwnerHost>
        weak var previous: UIWindow?
        init(service: WorkspaceTestService, store: AppStore, cacheID: UUID, scene: UIWindowScene,
             host: UIHostingController<OwnerHost>, state: OwnerState) {
            self.service = service; self.store = store; self.cacheID = cacheID; self.host = host; self.state = state
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); window.rootViewController = host
        }
        var webViews: [WKWebView] {
            @MainActor func find(_ view: UIView) -> [WKWebView] {
                (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(find)
            }
            return find(host.view)
        }
        func close() {
            service.openGate?.release(); service.downloadGate?.release()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.forgetConnection(); LocalHistory.remove(for: cacheID)
        }
    }
}
