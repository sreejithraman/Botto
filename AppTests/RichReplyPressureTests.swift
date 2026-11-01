import Foundation
import BottoCore
import Testing
import WebKit
@testable import Botto

/// Exercise admission through real, detached WebKit owners. No window or native
/// capture is needed to observe a forbidden reservation and document creation.
@MainActor @Suite(.serialized, RichReplyRuntime())
struct RichReplyPressureTests {
    @Test func canonicalCancellationAllowsFreshAuthorizedAWithoutNewActivation() async throws {
        let service = RichReplyTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://pressure-fixture.invalid")!, username: "alice")
        var saved: ConnectionConfiguration?
        let store = AppStore(service: service, persistence: .init(load: { saved }, save: { saved = $0 }, remove: { saved = nil }))
        defer { store.showsConnection = true; LocalHistory.remove(for: configuration.id) }
        try #require(await store.connect(configuration))
        await store.open(service.bot)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let renderer = renderer()
        defer { renderer.stop() }
        await renderer.load(block, context: context, diagramWidth: 380)
        let oldView = try #require(renderer.webView)
        let oldTicket = try #require(context.begin(block, layout: nil, onRevoke: {}).ticket)
        defer { oldTicket.cancel() }

        service.chat.messages[0].text = RichReplyTestService.text.replacingOccurrences(of: "Start", with: "Changed")
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(!oldTicket.isCurrent && renderer.webView == nil)
        service.chat.messages[0].text = RichReplyTestService.text
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(context.permits(block) && !oldTicket.isCurrent,
                "Restoring canonical A authorizes a fresh attempt, never the retired A ticket")
        await renderer.load(block, context: context, diagramWidth: 380)
        #expect(renderer.webView != nil && renderer.webView !== oldView)
        #expect(renderer.state == .loading)
        #expect(oldView.navigationDelegate == nil && oldView.window == nil)

        store.showsConnection = true
        #expect(!context.permits(block) && renderer.webView == nil)
        await renderer.load(block, context: context, diagramWidth: 380)
        #expect(renderer.webView == nil && renderer.state == .deferred,
                "Retired workspace authority cannot resume")
    }

    @Test func pressureDoesNotRefillADeferredRendererUntilNewActivation() async throws {
        let block = try diagram()
        let first = renderer(), second = renderer(), deferred = renderer()
        defer { [first, second, deferred].forEach { $0.stop() } }
        await first.load(block, diagramWidth: 380)
        await second.load(block, diagramWidth: 380)
        try await wait { first.webView != nil && second.webView != nil }
        try #require(first.webView != nil && second.webView != nil)
        #expect(first.webView?.window == nil && second.webView?.window == nil)
        #expect(!DiagramMemory.shared.canReserve())
        await deferred.load(block, diagramWidth: 380)
        try #require(deferred.state == .deferred && deferred.webView == nil)

        DiagramMemory.shared.handlePressure()
        #expect(first.webView == nil && second.webView == nil)
        try await drainRetries()
        #expect(deferred.webView == nil, "Pressure must not create a WK owner for deferred work")
        #expect(deferred.state == .deferred)
        await deferred.load(block, diagramWidth: 380)
        #expect(deferred.webView == nil, "Repeating active input is not a new activation")

        deferred.deactivate()
        await deferred.load(block, diagramWidth: 380)
        try await wait { deferred.webView != nil }
        #expect(deferred.webView != nil && deferred.state == .loading)
        #expect(deferred.webView?.window == nil)
    }

    @Test func pressureFencesAnAlreadyQueuedCapacityRetry() async throws {
        let block = try diagram()
        let first = renderer(), second = renderer(), deferred = renderer()
        defer { [first, second, deferred].forEach { $0.stop() } }
        await first.load(block, diagramWidth: 380)
        await second.load(block, diagramWidth: 380)
        try #require(first.webView != nil && second.webView != nil)
        await deferred.load(block, diagramWidth: 380)
        try #require(deferred.state == .deferred && deferred.webView == nil)

        // These synchronous main-actor operations cannot interleave with the
        // observation callback's queued task. Pressure must fence that task too.
        first.suspend()
        DiagramMemory.shared.handlePressure()
        try await drainRetries()
        #expect(deferred.webView == nil && deferred.state == .deferred)
        try requireBothPermitsAvailable(block)
        deferred.deactivate()
        await deferred.load(block, diagramWidth: 380)
        #expect(deferred.webView != nil)
    }

    @Test func repeatedLoadBeforeQueuedRetryCannotBypassPressure() async throws {
        let block = try diagram()
        let first = renderer(), second = renderer(), deferred = renderer()
        defer { [first, second, deferred].forEach { $0.stop() } }
        await first.load(block, diagramWidth: 380)
        await second.load(block, diagramWidth: 380)
        try #require(first.webView != nil && second.webView != nil)
        await deferred.load(block, diagramWidth: 380)
        try #require(deferred.state == .deferred && deferred.webView == nil)
        DiagramMemory.shared.handlePressure()
        await deferred.load(block, diagramWidth: 380)
        #expect(deferred.webView == nil && deferred.state == .deferred)
        try await drainRetries()
        #expect(deferred.webView == nil)
        try requireBothPermitsAvailable(block)
    }

    @Test func ordinaryReleaseProgressesAndLeavesTwoHTMLDocumentsIndependent() async throws {
        let block = try diagram()
        let html = try #require(ReplyContent(assistantText: "```html\n<button>Local</button>\n```\n").blocks.first)
        let first = renderer(), second = renderer(), deferred = renderer()
        let htmlA = renderer(), htmlB = renderer()
        defer { [first, second, deferred, htmlA, htmlB].forEach { $0.stop() } }
        await first.load(block, diagramWidth: 380)
        await second.load(block, diagramWidth: 380)
        await htmlA.load(html, diagramWidth: 380)
        await htmlB.load(html, diagramWidth: 380)
        let secondView = try #require(second.webView)
        let htmlViewA = try #require(htmlA.webView), htmlViewB = try #require(htmlB.webView)
        try #require(first.webView != nil && !DiagramMemory.shared.canReserve())
        await deferred.load(block, diagramWidth: 380)
        try #require(deferred.state == .deferred && deferred.webView == nil)
        first.suspend()
        try await wait { deferred.webView != nil }
        #expect(deferred.state == .loading && deferred.webView?.window == nil)
        #expect(second.webView === secondView)
        #expect(htmlA.webView === htmlViewA && htmlB.webView === htmlViewB)
        #expect(htmlViewA.window == nil && htmlViewB.window == nil)
    }

    @Test(arguments: [false, true])
    func cancelledDeferredWorkNeverRevives(retryAlreadyQueued: Bool) async throws {
        let block = try diagram()
        let first = renderer(), second = renderer(), deferred = renderer()
        defer { [first, second, deferred].forEach { $0.stop() } }
        await first.load(block, diagramWidth: 380)
        await second.load(block, diagramWidth: 380)
        try #require(first.webView != nil && second.webView != nil)
        await deferred.load(block, diagramWidth: 380)
        try #require(deferred.state == .deferred && deferred.webView == nil)
        if retryAlreadyQueued { first.suspend() }
        deferred.stop()
        if !retryAlreadyQueued { first.suspend() }
        try await drainRetries()
        #expect(deferred.webView == nil && deferred.state == .idle)
    }

    @Test func retiredContextCannotReviveQueuedDeferredWork() async throws {
        let service = RichReplyTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://pressure-retirement.invalid")!, username: "alice")
        var saved: ConnectionConfiguration?
        let store = AppStore(service: service, persistence: .init(load: { saved }, save: { saved = $0 }, remove: { saved = nil }))
        defer { store.showsConnection = true; LocalHistory.remove(for: configuration.id) }
        try #require(await store.connect(configuration))
        await store.open(service.bot)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let first = renderer(), second = renderer(), deferred = renderer()
        defer { [first, second, deferred].forEach { $0.stop() } }
        await first.load(block, context: context, diagramWidth: 380)
        await second.load(block, context: context, diagramWidth: 380)
        try #require(first.webView != nil && second.webView != nil)
        await deferred.load(block, context: context, diagramWidth: 380)
        try #require(deferred.state == .deferred && deferred.webView == nil)
        first.suspend()
        store.showsConnection = true
        try await drainRetries()
        #expect(!context.permits(block))
        #expect(deferred.webView == nil && deferred.state == .deferred)
        try requireBothPermitsAvailable(block)
    }

    @Test func admittedPressureStillRequiresNewActivation() async throws {
        let block = try diagram()
        let renderer = renderer()
        defer { renderer.stop() }
        await renderer.load(block, diagramWidth: 380)
        let oldView = try #require(renderer.webView)
        DiagramMemory.shared.handlePressure()
        #expect(renderer.webView == nil && renderer.state == .deferred)
        await renderer.load(block, diagramWidth: 380)
        #expect(renderer.webView == nil)
        renderer.deactivate()
        await renderer.load(block, diagramWidth: 380)
        #expect(renderer.webView != nil && renderer.webView !== oldView)
        #expect(oldView.navigationDelegate == nil && oldView.window == nil)
    }

    @Test func ordinaryPermitReleaseWakesDeferredRenderer() async throws {
        let block = try diagram()
        let first = renderer(), second = renderer(), deferred = renderer()
        defer { [first, second, deferred].forEach { $0.stop() } }
        await first.load(block, diagramWidth: 380)
        await second.load(block, diagramWidth: 380)
        try await wait { first.webView != nil && second.webView != nil }
        await deferred.load(block, diagramWidth: 380)
        #expect(deferred.state == .deferred && deferred.webView == nil)
        first.suspend()
        try await wait { deferred.webView != nil }
        #expect(deferred.state == .loading)
        #expect(second.webView != nil, "A normal capacity retry cannot cancel other active work")
    }

    @Test func staticPressureDoesNotCapIndependentHTMLDocuments() async throws {
        let block = try diagram()
        let html = try #require(ReplyContent(assistantText: "```html\n<p>local</p>\n```\n").blocks.first)
        let first = renderer(), second = renderer(), htmlA = renderer(), htmlB = renderer()
        defer { [first, second, htmlA, htmlB].forEach { $0.stop() } }
        await first.load(block, diagramWidth: 380)
        await second.load(block, diagramWidth: 380)
        try await wait { first.webView != nil && second.webView != nil }
        await htmlA.load(html); await htmlB.load(html)
        try await wait { htmlA.webView != nil && htmlB.webView != nil }
        #expect(htmlA.webView != nil && htmlB.webView != nil)
        #expect(!DiagramMemory.shared.canReserve(), "Two active static requests occupy both static permits")
    }

    private func diagram() throws -> ReplyContent.Block {
        try #require(ReplyContent(assistantText: "```mermaid\ngraph TD\nA-->B\n```\n").blocks.first)
    }

    private func renderer() -> RichContentRenderer {
        RichContentRenderer()
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate())
    }

    private func drainRetries() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    private func requireBothPermitsAvailable(_ block: ReplyContent.Block) throws {
        let scope = RichReplyPresentations()
        let layout = try #require(DiagramLayout(dark: false, reduceMotion: false, width: 380, viewportHeight: nil))
        let first = try #require(scope.begin(block, messageID: Data(), layout: layout, onRevoke: {}).ticket)
        defer { first.cancel() }
        let second = try #require(scope.begin(block, messageID: Data(), layout: layout, onRevoke: {}).ticket)
        defer { second.cancel() }
        #expect(!DiagramMemory.shared.canReserve(), "Both real static permits must be accounted for")
    }

}
