import CoreGraphics
import Foundation
import Testing
import BottoCore
import WebKit
import SwiftUI
import UIKit
@testable import Botto

@MainActor @Suite(.serialized, RichReplyRuntime()) struct RichReplyCacheTests {
    @Test func retainedPresentationSurvivesOwnersButReconcilesExactBytes() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.finish() }
        let block = try fixture.block()
        let context = fixture.context
        let ticket = try #require(context.begin(block, layout: fixture.layout, onRevoke: {}).ticket)
        #expect(ticket.startCapture())
        let pixels = try #require(ticket.finishCapture(try Self.image(), height: 181))
        #expect(context.lookup(block, layout: fixture.layout) === pixels)
        #expect(pixels.height == 181)
        // A recreated caller obtains authority from the actual current store.
        #expect(fixture.store.richReplyContext(for: fixture.service.bot.id, messageID: "m0")
            .lookup(block, layout: fixture.layout) === pixels)
        fixture.service.chat.messages[0].text += "Appended native prose"
        try fixture.publish()
        #expect(context.lookup(block, layout: fixture.layout) === pixels)
        fixture.service.chat.messages[0].text = RichReplyTestService.text.replacingOccurrences(of: "Start", with: "Café")
        try fixture.publish()
        let composed = try fixture.block()
        let unicodeTicket = try #require(context.begin(composed, layout: fixture.layout, onRevoke: {}).ticket)
        fixture.service.chat.messages[0].text = fixture.service.chat.messages[0].text.replacingOccurrences(of: "Café", with: "Cafe\u{301}")
        try fixture.publish()
        #expect(!unicodeTicket.isCurrent)
        #expect(!pixels.isAvailable)
        #expect(context.lookup(composed, layout: fixture.layout) == nil)
        unicodeTicket.cancel()
    }

    @Test func originalTicketRejectsLateCaptureAndHeldStorageStaysChargedUntilDrain() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.finish() }
        let block = try fixture.block()
        var tickets: [DiagramRenderTicket] = []
        for width in [380.0, 381.0] {
            let layout = try #require(DiagramLayout(dark: false, reduceMotion: false, width: width, viewportHeight: nil))
            let ticket = try #require(fixture.context.begin(block, layout: layout, onRevoke: {}).ticket)
            #expect(ticket.startCapture()); tickets.append(ticket)
        }
        tickets[0].cancel()
        #expect(fixture.context.begin(block, layout: fixture.layout, onRevoke: {}).ticket == nil,
                "Cancellation does not drain a pending native callback or free a permit")
        #expect(tickets[0].finishCapture(try Self.image(), height: 120) == nil)
        await Task.yield()
        let replacement = try #require(fixture.context.begin(block, layout: fixture.layout, onRevoke: {}).ticket)
        replacement.cancel()
        fixture.store.showsConnection = true
        #expect(!tickets[1].isCurrent)
        #expect(tickets[1].finishCapture(try Self.image(), height: 120) == nil)
    }

    @Test func exactLayoutAndCanonicalRoleMissesNeverBorrowKnownPixels() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.finish() }
        let block = try fixture.block()
        let ticket = try #require(fixture.context.begin(block, layout: fixture.layout, onRevoke: {}).ticket)
        #expect(ticket.startCapture())
        let pixels = try #require(ticket.finishCapture(try Self.image(), height: 120))
        for layout in [
            DiagramLayout(dark: true, reduceMotion: false, width: 380, viewportHeight: nil),
            DiagramLayout(dark: false, reduceMotion: true, width: 380, viewportHeight: nil),
            DiagramLayout(dark: false, reduceMotion: false, width: 380.001, viewportHeight: nil),
            DiagramLayout(dark: false, reduceMotion: false, width: 380, viewportHeight: 300)
        ] { #expect(fixture.context.lookup(block, layout: try #require(layout)) == nil) }
        #expect(DiagramLayout(dark: false, reduceMotion: false, width: .infinity, viewportHeight: nil) == nil)
        #expect(DiagramLayout(dark: false, reduceMotion: false, width: 0, viewportHeight: nil) == nil)
        fixture.service.chat.messages[0].role = .user
        try fixture.publish()
        #expect(!pixels.isAvailable)
        #expect(!fixture.context.permits(block))
    }

    @Test func offlineReadingAndSecretRotationPreserveButIdentityAndEpochChangesRevoke() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.finish() }
        let block = try fixture.block()
        var rotated = try #require(fixture.store.configuration)
        rotated.password = "rotated-secret"
        fixture.service.onEvent?(.configuration(rotated))
        #expect(fixture.context.permits(block))
        rotated.username = "Café"
        fixture.service.onEvent?(.configuration(rotated))
        #expect(!fixture.context.permits(block))
        let current = fixture.store.richReplyContext(for: fixture.service.bot.id, messageID: "m0")
        #expect(current.permits(block))
        rotated.username = "Cafe\u{301}"
        fixture.service.onEvent?(.configuration(rotated))
        #expect(!current.permits(block), "Canonically equivalent account names with different bytes retire authority")
        fixture.service.onEvent?(.disconnected("offline"))
        #expect(!current.permits(block))
        #expect(fixture.store.richReplyContext(for: fixture.service.bot.id, messageID: "m0").permits(block),
                "Authorized cached local rendering does not require a live connection")
        let offline = fixture.store.richReplyContext(for: fixture.service.bot.id, messageID: "m0")
        await fixture.store.open(fixture.service.bot)
        #expect(!offline.permits(block), "Even an offline same-bot open starts a new epoch")
    }

    @Test func pressureRevokesHeldResultsAndPendingAuthorityWithoutReleasingCaptureEarly() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.finish() }
        let block = try fixture.block()
        let completed = try #require(fixture.context.begin(block, layout: fixture.layout, onRevoke: {}).ticket)
        #expect(completed.startCapture())
        let pixels = try #require(completed.finishCapture(try Self.image(), height: 120))
        var revoked = false
        let other = try #require(DiagramLayout(dark: true, reduceMotion: false, width: 380, viewportHeight: nil))
        let pending = try #require(fixture.context.begin(block, layout: other, onRevoke: { revoked = true }).ticket)
        #expect(pending.startCapture())
        DiagramMemory.shared.handlePressure()
        #expect(revoked && !pixels.isAvailable && !pending.isCurrent)
        #expect(fixture.context.lookup(block, layout: fixture.layout) == nil)
        #expect(pending.finishCapture(try Self.image(), height: 120) == nil)
    }

    private static func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1_024, height: 323, bitsPerComponent: 8,
            bytesPerRow: 4_096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 323))
        return try #require(context.makeImage())
    }
}

@MainActor private final class CacheFixture {
    let service = RichReplyTestService()
    let configuration = ConnectionConfiguration(serverURL: URL(string: "https://cache-fixture.invalid")!, username: "alice")
    let store: AppStore
    let layout = DiagramLayout(dark: false, reduceMotion: false, width: 380, viewportHeight: nil)!
    var context: RichReplyContext
    init() async throws {
        var saved: ConnectionConfiguration?
        store = AppStore(service: service, persistence: .init(load: { saved }, save: { saved = $0 }, remove: { saved = nil }))
        context = .chat(nil)
        #expect(await store.connect(configuration))
        await store.open(service.bot)
        context = store.richReplyContext(for: service.bot.id, messageID: "m0")
    }
    func block() throws -> ReplyContent.Block { try #require(ReplyContent(message: service.chat.messages[0]).blocks.first) }
    func publish() throws { service.onEvent?(.conversation(try service.authority.opened(service.chat))) }
    func finish() { store.showsConnection = true; LocalHistory.remove(for: configuration.id) }
}

/// Actual renderer seams; use the platform window only for native capture. The
/// public scrolling/first-frame assertion is separately measured optically.
@MainActor @Suite(.serialized, RichReplyRuntime()) struct RichReplyRendererCacheTests {
    @Test func recreatedRendererUsesActualCaptureAndPressureWaitsForNewActivation() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.finish() }
        let block = try fixture.block()
        let first = renderer()
        await first.load(block, context: fixture.context, diagramWidth: 380)
        let window = try await mount(first)
        defer { first.stop(); close(window) }
        try await wait { first.presentation != nil || first.webView == nil }
        let presentation = try #require(first.presentation)
        #expect(presentation.pixelWidth > 0 && presentation.pixelWidth <= 1_024)
        #expect(first.webView == nil)
        first.stop()
        let second = renderer()
        defer { second.stop() }
        await second.load(block, context: fixture.context, diagramWidth: 380)
        #expect(second.presentation === presentation)
        #expect(second.height == presentation.height && second.state == .ready)
        #expect(second.webView == nil, "A new owner must not create a document on a retained hit")
        DiagramMemory.shared.handlePressure()
        #expect(!presentation.isAvailable)
        #expect(second.webView == nil && second.state == .deferred)
        await second.load(block, context: fixture.context, diagramWidth: 380)
        #expect(second.webView == nil, "Pixel loss alone is not a fresh activation")
        second.deactivate()
        await second.load(block, context: fixture.context, diagramWidth: 380)
        #expect(second.webView != nil, "A genuine new activation can resume")
    }

    @Test func capacityIsNonterminalAndProgressesWithoutCappingHTML() async throws {
        let block = try #require(ReplyContent(assistantText: RichReplyTestService.text).blocks.first)
        let html = try #require(ReplyContent(assistantText: "```html\n<button>Local</button>\n```\n").blocks.first)
        let first = renderer(), second = renderer(), deferred = renderer()
        let htmlA = renderer(), htmlB = renderer()
        defer { [first, second, deferred, htmlA, htmlB].forEach { $0.stop() } }
        await first.load(block, diagramWidth: 380)
        await second.load(block, diagramWidth: 380)
        await htmlA.load(html); await htmlB.load(html)
        #expect(first.webView != nil && second.webView != nil)
        #expect(htmlA.webView != nil && htmlB.webView != nil)
        await deferred.load(block, diagramWidth: 380)
        #expect(deferred.state == .deferred && deferred.webView == nil)
        first.suspend()
        try await wait { deferred.webView != nil }
        #expect(deferred.state == .loading)
        #expect(second.webView != nil, "Capacity changes cannot cancel another running load")
    }

    @Test func nativeDrawingCompanionsKeepEvictedStorageChargedUntilRelease() async throws {
        let fixture = try await CacheFixture()
        defer { fixture.finish() }
        let block = try fixture.block()
        var drawings: [UIView] = []
        var presentations: [DiagramPresentation] = []
        for index in 0..<4 {
            let layout = try #require(DiagramLayout(dark: false, reduceMotion: false, width: CGFloat(380 + index), viewportHeight: nil))
            let ticket = try #require(fixture.context.begin(block, layout: layout, onRevoke: {}).ticket)
            #expect(ticket.startCapture())
            let bitmap = try #require(CGContext(data: nil, width: 1_024, height: 1_024, bitsPerComponent: 8,
                bytesPerRow: 4_096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 1_024, height: 1_024))
            let presentation = try #require(ticket.finishCapture(try #require(bitmap.makeImage()), height: 120))
            presentations.append(presentation)
            drawings.append(try await retainedDrawing(presentation))
        }
        let fifth = try #require(DiagramLayout(dark: true, reduceMotion: false, width: 380, viewportHeight: nil))
        #expect(fixture.context.begin(block, layout: fifth, onRevoke: {}).ticket == nil)
        #expect(fixture.context.lookup(block, layout: fixture.layout) == nil, "LRU can drop lookup ownership")
        #expect(presentations[0].isAvailable, "Ordinary eviction preserves a still-held authorized drawing")
        DiagramMemory.shared.handlePressure()
        #expect(presentations.allSatisfy { !$0.isAvailable })
        // Storage releases are enqueued on the main actor. Admission must remain
        // blocked after those releases have had time to run, not just immediately
        // after revocation. Only the native drawing children now own the pixels.
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(25))
            let unexpected = fixture.context.begin(block, layout: fifth, onRevoke: {}).ticket
            #expect(unexpected == nil, "Held native drawing companions remain charged after queued releases drain")
            unexpected?.cancel()
        }
        #expect(drawings.count == 4)
        drawings.removeAll(); presentations.removeAll()
        var resumed: DiagramRenderTicket?
        try await wait {
            resumed = fixture.context.begin(block, layout: fifth, onRevoke: {}).ticket
            return resumed != nil
        }
        resumed?.cancel()
    }

    /// Materialize the real representable, then retain its native drawing child
    /// independently of SwiftUI updates. Revoking a presentation can update the
    /// SwiftUI tree; it must not uncharge storage still owned by a native child.
    private func retainedDrawing(_ presentation: DiagramPresentation) async throws -> UIView {
        try await wait {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .contains { $0.activationState == .foregroundActive }
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        let host = UIHostingController(rootView: DiagramPixelsView(presentation: presentation)
            .frame(width: 128, height: 128).ignoresSafeArea())
        window.rootViewController = container
        container.addChild(host); container.view.addSubview(host.view)
        host.view.frame = CGRect(x: 0, y: 0, width: 128, height: 128)
        host.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer {
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
            window.isHidden = true; window.rootViewController = nil
            previousKey?.makeKey()
        }
        func find(_ view: UIView) -> UIView? {
            if String(reflecting: type(of: view)).contains("DrawingView"),
               view.bounds.width > 0, view.bounds.height > 0 { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        try await wait { host.view.layoutIfNeeded(); return find(host.view) != nil }
        let drawing = try #require(find(host.view), "The fixture must mount the actual native drawing child")
        #expect(drawing.window === window)
        drawing.layer.displayIfNeeded()
        Attachment.record("class=\(type(of: drawing)) bounds=\(drawing.bounds) attached=\(drawing.window != nil)",
                          named: "charged-native-companion.txt")
        drawing.removeFromSuperview()
        return drawing
    }

    private func renderer() -> RichContentRenderer {
        RichContentRenderer()
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(21)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(predicate())
    }
    private func mount(_ renderer: RichContentRenderer) async throws -> UIWindow {
        try await wait { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains { $0.activationState == .foregroundActive } }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let view = try #require(renderer.webView)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 380, height: 480)
        let controller = UIViewController(); window.rootViewController = controller
        window.makeKeyAndVisible(); controller.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 380, height: 480)
        return window
    }
    private func close(_ window: UIWindow) { window.isHidden = true; window.rootViewController = nil }
}

/// Pressure is process-wide. Keep these suites in one native-runtime scope so a
/// deliberate pressure event cannot revoke a different test's in-flight capture.
struct RichReplyRuntime: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }
    private static let gate = Gate()
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        await Self.gate.acquire()
        do {
            try await NativeAccessibilityRuntime.enable()
            try await function()
        }
        catch { await Self.gate.release(); throw error }
        await Self.gate.release()
    }
    private actor Gate {
        private var occupied = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func acquire() async {
            if !occupied { occupied = true; return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            if waiting.isEmpty { occupied = false }
            else { waiting.removeFirst().resume() }
        }
    }
}
