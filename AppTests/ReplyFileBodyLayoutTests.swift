import Testing
import SwiftUI
import UIKit
import WebKit
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct ReplyFileBodyLayoutTests {
    @Test func mountedFileBodyKeepsPendingSpaceWithoutRetainingTheDocumentAndAcceptsShorterReplacement() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        try await wait("actual tall HTML body") { fixture.state.size.height > 500 && fixture.webViews.count == 1 }
        let initial = fixture.state.size.height
        fixture.state.settled = false
        try await wait("incomplete directive withdraws native document") { fixture.webViews.isEmpty }
        try await wait("pending body keeps its measured space") { abs(fixture.state.size.height - initial) < 2 }
        #expect(fixture.service.downloads == 1)

        let gate = WorkspaceGate(); fixture.service.downloadGate = gate
        fixture.service.downloadData = Data("<!doctype html><html><body><p>Short replacement.</p></body></html>".utf8)
        let message = try #require(fixture.store.conversation(for: fixture.service.profile.text)?.messages.first)
        let reference = try #require(ReplyContent(message: message).blocks.first { $0.filePreview != nil }?.filePreview)
        let destination = try #require(fixture.store.artifactDestination(for: reference.attachment,
            botID: fixture.service.profile.text, producingMessage: message))
        let reload = Task {
            defer { fixture.store.finishArtifact(destination) }
            return try await fixture.store.downloadArtifact(destination, force: true)
        }
        defer { gate.release(); reload.cancel() }
        try await wait("explicit host reload is held") { fixture.service.downloads == 2 }
        #expect(fixture.webViews.isEmpty)
        #expect(abs(fixture.state.size.height - initial) < 2)
        gate.release()
        let refreshed = try await reload.value
        #expect(refreshed.data == fixture.service.downloadData)
        fixture.service.downloadGate = nil
        fixture.state.settled = true
        try await wait("shorter resolved HTML takes natural height") {
            fixture.webViews.count == 1 && fixture.state.size.height > 70 && fixture.state.size.height < initial - 150
        }
        #expect(fixture.service.downloads == 2, "The resumed inline preview must use the explicitly refreshed capture")
        let smaller = fixture.state.size.height
        fixture.state.settled = false
        try await wait("replacement document is withdrawn") { fixture.webViews.isEmpty }
        try await wait("pending space uses new measurement rather than historical maximum") {
            abs(fixture.state.size.height - smaller) < 2
        }
    }

    @Test func pendingWidthChangeClearsTheOldReservationBeforeReturningToTheOriginalWidth() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        try await wait("actual tall HTML body") { fixture.state.size.height > 500 && fixture.webViews.count == 1 }
        fixture.state.settled = false
        try await wait("document withdrawn") { fixture.webViews.isEmpty }
        fixture.state.width = 601
        try await wait("different width uses natural pending body") {
            abs(fixture.state.size.width - 601) < 1 && fixture.state.size.height < 180
        }
        fixture.state.width = 477
        try await wait("old width cannot revive obsolete measurement") {
            abs(fixture.state.size.width - 477) < 1 && fixture.state.size.height < 180
        }
        #expect(fixture.service.downloads == 1)
    }

    private func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Timed out: \(label)")
    }
    private func fixture() async throws -> Fixture {
        let service = try WorkspaceTestService()
        service.downloadData = Data("<!doctype html><html><body><div style='height:560px'>Tall initial preview.</div></body></html>".utf8)
        let identity = service.summaries[0].identity
        let message = ChatMessage(id: "body-layout-message", role: .assistant, text: "::preview{file=\"report.html\"}")
        service.snapshots[identity.root] = .init(id: identity.root.text, storedID: identity.stored.text,
            profileID: identity.profile.text, messages: [message])
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://body-layout.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let state = BodyState()
        let view = BodyHost(state: state, message: message,
            context: store.richReplyContext(for: service.profile.text, messageID: message.id))
        let host = UIHostingController(rootView: view)
        let fixture = Fixture(service: service, store: store, cacheID: configuration.id, scene: scene, host: host, state: state)
        fixture.window.makeKeyAndVisible(); fixture.window.layoutIfNeeded()
        return fixture
    }

    @MainActor @Observable final class BodyState {
        var settled = true
        var width: CGFloat = 477
        var size: CGSize = .zero
    }
    private struct BodyHost: View {
        let state: BodyState
        let message: ChatMessage
        let context: RichReplyContext
        var body: some View {
            ScrollView {
                AssistantReplyBody(message: message, isStreaming: false, filePreviewsAreSettled: state.settled)
                    .environment(\.richReplyContext, context)
                    .environment(\.scenePhase, .active)
                    .frame(width: state.width)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { state.size = $0 }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    @MainActor private final class Fixture {
        let service: WorkspaceTestService
        let store: AppStore
        let cacheID: UUID
        let window: UIWindow
        let host: UIHostingController<BodyHost>
        let state: BodyState
        weak var previous: UIWindow?
        init(service: WorkspaceTestService, store: AppStore, cacheID: UUID, scene: UIWindowScene,
             host: UIHostingController<BodyHost>, state: BodyState) {
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
            service.downloadGate?.release()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.forgetConnection(); LocalHistory.remove(for: cacheID)
        }
    }
}
