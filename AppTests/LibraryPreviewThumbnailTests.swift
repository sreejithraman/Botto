import Testing
import SwiftUI
import UIKit
import WebKit
import BottoCore
@testable import Botto

@MainActor @Suite(.serialized, RichReplyRuntime())
struct LibraryPreviewThumbnailTests {
    @Test func galleryHTMLCoverSurvivesOfflineReopenWithoutAWebView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try WorkspaceTestService()
        let source = try #require(service.summaries.first?.identity)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session), covers = LibraryThumbnails()
        let mounted = try mount(covers.previews)
        defer { mounted.close() }
        try await wait { covers.previews.isMounted }
        library.accept(identity: source, snapshot: .init(id: source.root.text, storedID: source.stored.text,
            profileID: source.profile.text, messages: [.init(id: "html-cover", role: .assistant,
                text: "```html\n<style>body{background:#0755df;color:white}</style><h1>Saved cover</h1>\n```")]), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        try await wait { !library.artifacts.isEmpty }
        let item = try #require(library.artifacts.first)
        let image = try #require(await covers.image(for: item, library: library))
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await session.loadChats().count == 1)
        library.retire(); await cache.close()

        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        let offlineCovers = LibraryThumbnails()
        #expect(!offlineCovers.previews.isMounted)
        let restoredItem = try #require(reopened.artifacts.first)
        let saved = try #require(await offlineCovers.image(for: restoredItem, library: reopened))
        #expect(saved.pngData() == image.pngData())
        reopened.retire(); await reopenedCache.close()
    }

    @Test func hiddenHostProducesBoundedHTMLPixelsAndStopsItsDocument() async throws {
        let renderer = LibraryPreviewThumbnailRenderer()
        let mounted = try mount(renderer)
        defer { mounted.close() }
        try await wait { renderer.isMounted }

        let image = try #require(await renderer.render(html("""
        <style>html,body{margin:0;background:#0755df}h1{color:#ffce00;font:40px system-ui;padding:28px}</style>
        <h1 id="title">Starting</h1><script>document.getElementById('title').textContent='Preview cover';</script>
        """)))
        let pixels = try #require(image.cgImage)
        #expect(max(pixels.width, pixels.height) <= 400)
        #expect(pixels.width > 0 && pixels.height > 0)
        let context = try #require(CGContext(data: nil, width: pixels.width, height: pixels.height,
            bitsPerComponent: 8, bytesPerRow: pixels.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var blue = 0, yellow = 0
        for offset in stride(from: 0, to: pixels.width * pixels.height * 4, by: 4) {
            if bytes[offset] < 30 && bytes[offset + 1] < 120 && bytes[offset + 2] > 160 { blue += 1 }
            if bytes[offset] > 200 && bytes[offset + 1] > 140 && bytes[offset + 2] < 60 { yellow += 1 }
        }
        #expect(blue > 1_000 && yellow > 100, "The cover must include real document background and text ink.")
        #expect(webViews(in: mounted.controller.view).isEmpty)
        Attachment.record(try #require(image.pngData()), named: "html-gallery-cover.png")
    }

    @Test func taskCancellationRetiresTheMountedDocumentAndAllowsANewCover() async throws {
        let renderer = LibraryPreviewThumbnailRenderer()
        let mounted = try mount(renderer)
        defer { mounted.close() }
        try await wait { renderer.isMounted }
        let first = Task { await renderer.render(html("<script>while(true){}</script>")) }
        try await wait { !webViews(in: mounted.controller.view).isEmpty }
        first.cancel()
        #expect(await first.value == nil)
        #expect(webViews(in: mounted.controller.view).isEmpty)
        #expect(await renderer.render(html("<h1>Next cover</h1>")) != nil)
        #expect(webViews(in: mounted.controller.view).isEmpty)
    }

    @Test func inactiveAndDetachedHostsCannotKeepExecutingHTML() async throws {
        let renderer = LibraryPreviewThumbnailRenderer()
        let mounted = try mount(renderer)
        defer { mounted.close() }
        try await wait { renderer.isMounted }
        let revision = renderer.mountRevision
        let pending = Task { await renderer.render(html("<script>while(true){}</script>")) }
        try await wait { !webViews(in: mounted.controller.view).isEmpty }
        mounted.setActive(false)
        try await wait { !renderer.isMounted }
        #expect(await pending.value == nil)
        #expect(renderer.mountRevision != revision)
        #expect(webViews(in: mounted.controller.view).isEmpty)
        #expect(await renderer.render(html("<h1>Hidden</h1>")) == nil)

        mounted.setActive(true)
        try await wait { renderer.isMounted }
        let detached = Task { await renderer.render(html("<script>while(true){}</script>")) }
        try await wait { !webViews(in: mounted.controller.view).isEmpty }
        mounted.window.isHidden = true
        mounted.window.rootViewController = nil
        #expect(await detached.value == nil)
        #expect(!renderer.isMounted)
        #expect(webViews(in: mounted.controller.view).isEmpty)
    }

    @Test func renderingDeadlineRetiresAnUnresponsiveDocument() async throws {
        let renderer = LibraryPreviewThumbnailRenderer(timeout: .milliseconds(150))
        let mounted = try mount(renderer)
        defer { mounted.close() }
        try await wait { renderer.isMounted }
        let started = ContinuousClock.now
        #expect(await renderer.render(html("<script>while(true){}</script>")) == nil)
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(webViews(in: mounted.controller.view).isEmpty)
    }

    private func html(_ source: String) -> ReplyContent.Block {
        ReplyContent(assistantText: "```html\n\(source)\n```").blocks.first!
    }

    @MainActor private struct Mounted {
        let window: UIWindow
        let controller: UIHostingController<LibraryPreviewThumbnailHost>
        let previousKey: UIWindow?
        func setActive(_ value: Bool) {
            controller.rootView.isActive = value
            controller.view.layoutIfNeeded()
        }
        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
        }
    }

    private func mount(_ renderer: LibraryPreviewThumbnailRenderer) throws -> Mounted {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let controller = UIHostingController(rootView: LibraryPreviewThumbnailHost(renderer: renderer))
        controller.view.alpha = 0
        let window = UIWindow(windowScene: scene)
        let previousKey = scene.windows.first { $0.isKeyWindow }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return Mounted(window: window, controller: controller, previousKey: previousKey)
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }

    private func wait(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ready())
    }
}
