import Testing
import SwiftUI
import UIKit
import WebKit
import Vision
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct NativeTranscriptContentTests {
    @Test func actualCanvasGenerationAndSendKeepEveryHostedRowInsideItsNativeAllocation() async throws {
        let service = DemoBotService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-canvas.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration))
        let canvas = try #require(store.bots.first { $0.id == "canvas" })
        let milo = try #require(store.bots.first { $0.id == "milo" })
        await store.open(canvas)
        let profile = try ExactID(canvas.id)
        let initial = try #require(store.chats.screen(profile: profile))
        await store.chats.refreshDirectory(initial.owner); store.chats.displayed(initial.owner)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let viewport = Viewport()
        let host = UIHostingController(rootView: CanvasHost(store: store, viewport: viewport))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let richMessage = try #require(initial.snapshot?.messages.last)
        let fileBlock = try #require(ReplyContent(message: richMessage).blocks.first { $0.filePreview?.isHTML == true })
        do {
            try await requirePaintedFile(fileBlock.id, host: host, window: window)
        } catch {
            if let controller = collectionController(host) {
                let rows: [[String: Any]] = controller.collection.visibleCells.map { cell in
                    let scope = (cell as? NativeTranscriptCell)?.exposure
                    let root = scope?.rowGeometry
                    let blockGeometry: [[String: Any]] = markers(cell).map { marker in
                        ["block": marker.block, "role": String(describing: marker.role),
                         "bounds": NSCoder.string(for: marker.bounds),
                         "viewport_frame": NSCoder.string(for: marker.convert(marker.bounds, to: controller.collection)),
                         "visible": marker.presence?.isVisible ?? false,
                         "current_scope": marker.scope === scope]
                    }
                    return ["index": controller.collection.indexPath(for: cell)?.item ?? -1,
                            "cell": NSCoder.string(for: cell.frame),
                            "allocation": NSCoder.string(for: cell.contentView.bounds),
                            "root": root.map { NSCoder.string(for: $0.convert($0.bounds, to: cell.contentView)) } ?? "missing",
                            "current": scope?.isCurrent ?? false, "can_present": scope?.canPresent ?? false,
                            "admits_content": scope?.admitsContent ?? false,
                            "root_descends_from_content": root?.isDescendant(of: cell.contentView) ?? false,
                            "root_same_window": root?.window === cell.window,
                            "blocks": blockGeometry]
                }
                let geometry: [String: Any] = ["viewport": NSCoder.string(for: controller.collection.bounds),
                    "web_views": webViews(host.view).count, "rows": rows]
                if let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    Attachment.record(text, named: "Canvas initial file failure geometry.json")
                }
            }
            throw error
        }
        let first = try #require(collectionController(host))
        await store.open(milo)
        try await wait("Milo actually replaced the native Canvas subtree") { collectionController(host).map { $0 !== first } ?? false }
        let middle = try #require(collectionController(host))
        await store.open(canvas)
        try await wait("Canvas actual selected subtree returned") { collectionController(host).map { $0 !== middle } ?? false }
        try await wait("returned rich body is actually placed inside its current native allocation before Send") {
            guard let controller = collectionController(host),
                  let cell = controller.collection.cellForItem(at: IndexPath(item: 2, section: 0)) as? NativeTranscriptCell,
                  let root = cell.exposure?.rowGeometry else { return false }
            let rect = root.convert(root.bounds, to: cell.contentView)
            return markers(cell).contains { $0.block == fileBlock.id && $0.role == .document &&
                $0.scope === cell.exposure && $0.bounds.height > 300 } &&
                !webViews(cell).isEmpty && abs(rect.minY) < 1 && abs(rect.height - cell.contentView.bounds.height) < 1
        }
        try await requirePaintedFile(fileBlock.id, host: host, window: window)
        let screen = try #require(store.chats.screen(profile: profile))
        store.chats.displayed(screen.owner)
        store.chats.editDraft("Canvas tail after rich preview\n  keep this source draft  ", owner: screen.owner)
        viewport.height = 380
        try await wait("actual short composer viewport applied") { collectionController(host)?.view.bounds.height == 380 }
        let intent = try #require(store.chats.captureSend(screen.owner))
        await store.chats.send(intent)
        viewport.height = 434
        try await wait("actual local demo reply delivered") { store.chats.screen(profile: profile)?.snapshot?.messages.count == 4 }
        let controller = try #require(collectionController(host))
        try await wait("actual latest native reply root") {
            guard let reply = controller.collection.cellForItem(at: IndexPath(item: 4, section: 0)) as? NativeTranscriptCell,
                  let root = reply.exposure?.rowGeometry else { return false }
            return root.bounds.height > 100 && root.convert(root.bounds, to: controller.collection).intersects(controller.collection.bounds)
        }
        try await wait("settled rendered roots fit native cell allocations") {
            controller.collection.visibleCells.allSatisfy { cell in
                guard let cell = cell as? NativeTranscriptCell, let root = cell.exposure?.rowGeometry else { return true }
                let rect = root.convert(root.bounds, to: cell.contentView)
                return cell.contentView.bounds.insetBy(dx: -1, dy: -1).contains(rect)
            }
        }
    }
    @MainActor @Observable final class Viewport { var height: CGFloat = 434 }
    private struct CanvasHost: View {
        let store: AppStore
        let viewport: Viewport
        @State private var presentation = WorkspacePresentation()
        var body: some View {
            if let bot = store.selectedBot {
                transcriptFixture(store: store, bot: bot, presentation: presentation, native: true)
                    .frame(width: 382, height: viewport.height)
                    .environment(\.scenePhase, .active)
            }
        }
    }
    private func requirePaintedFile(_ block: Int, host: UIViewController, window: UIWindow) async throws {
        let display = NativeContentDisplayFrames()
        defer { display.stop() }
        let deadline = ContinuousClock.now + .seconds(10)
        var painted = false
        while ContinuousClock.now < deadline {
            guard let controller = collectionController(host),
                  let cell = controller.collection.cellForItem(at: IndexPath(item: 2, section: 0)) as? NativeTranscriptCell,
                  let document = markers(cell).first(where: { $0.block == block && $0.role == .document && $0.scope === cell.exposure }) else {
                await display.nextFrame(); continue
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let visible = document.convert(document.bounds, to: window)
                .intersection(controller.collection.convert(controller.collection.bounds, to: window)).intersection(window.bounds)
            painted = try RenderedTranscriptFile.observe(image, in: visible).isComplete
            if painted { break }
            await display.nextFrame()
        }
        try #require(painted, "actual visible file body must paint its known bars; WK presence and measured height alone do not pass")
    }
    private func collectionController(_ parent: UIViewController) -> NativeTranscriptController? {
        if let controller = parent as? NativeTranscriptController, controller.isViewLoaded, controller.view.window != nil { return controller }
        return parent.children.lazy.compactMap(collectionController).first
    }
    private func markers(_ view: UIView) -> [NativeTranscriptBlockMarker] {
        (view as? NativeTranscriptBlockMarker).map { [$0] } ?? view.subviews.flatMap(markers)
    }
    private func webViews(_ view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
    private func wait(_ reason: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Timed out: \(reason)")
    }
}

@Suite(.serialized, RichReplyRuntime()) @MainActor struct InboxPresentationTests {
    @Test func cachedInboxCountDoesNotFlashAnExtraChatDuringDirectoryRefresh() async throws {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://count-badge.invalid")!)
        var history = LocalHistory()
        history.bots = [.init(id: service.profile.text, name: "Milo")]
        for summary in service.summaries { history.book.merge(summary) }
        try history.save(for: configuration.id)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: InboxView(store: store, onSettings: {}, onNewBot: {}))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.forgetConnection(); LocalHistory.remove(for: configuration.id)
        }
        func renderedCount() throws -> String? {
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: #require(image.cgImage)).perform([request])
            return request.results?.compactMap { $0.topCandidates(1).first?.string }.first { $0.contains("chats") }
        }
        var cached: String?
        let deadline = ContinuousClock.now + .seconds(5)
        while cached == nil, ContinuousClock.now < deadline { await Task.yield(); cached = try renderedCount() }
        try #require(cached != nil, "The cached bot row must actually paint its chat count")
        #expect(!store.chats.aggregate(profile: service.profile).directoryComplete)
        #expect(cached == "2 chats")
        try #require(await store.connect(configuration))
        #expect(store.chats.aggregate(profile: service.profile).directoryComplete)
        #expect(store.chats.aggregate(profile: service.profile).count == 2)
        await Task.yield()
        #expect(try renderedCount() == cached)
        let discovered = SessionIdentity(profile: service.profile, root: try ExactID("discovered-root"),
            stored: try ExactID("discovered-tip"), aliases: [])
        service.summaries.append(.init(identity: discovered, title: "Discovered chat", isCanonical: false,
                                      persistence: .durable))
        store.chats.invalidateActivityDirectory(service.profile)
        await store.chats.refreshActivityDirectories(for: store.bots)
        #expect(store.chats.aggregate(profile: service.profile).count == 3)
        await Task.yield()
        #expect(try renderedCount() == "3 chats")
    }

}

@MainActor struct MarkdownSelectionTests {
    @Test(arguments: [2, 3, 4, 5])
    func headingStyleSurvivesParagraphSeparators(_ newlines: Int) throws {
        let separator = String(repeating: "\n", count: newlines)
        let source = "Intro" + separator + "# Heading\n\nBody"
        let rendered = MarkdownBody(text: source, isReply: true).attributed(source)
        let heading = try #require(rendered.range(of: "Heading"))
        #expect(rendered[heading].font == .title3.weight(.semibold))
        #expect(String(rendered.characters) == "Intro" + separator + "Heading\n\nBody")
    }
}

/// Test-only display readiness, with no sleeps, product mutations or DEBUG API.
@MainActor private final class NativeContentDisplayFrames: NSObject {
    private var link: CADisplayLink?
    private var waiting: CheckedContinuation<Void, Never>?
    func nextFrame() async {
        await withCheckedContinuation { continuation in
            waiting = continuation
            let link = CADisplayLink(target: self, selector: #selector(tick))
            self.link = link; link.add(to: .main, forMode: .common)
        }
    }
    @objc private func tick() { stop() }
    func stop() {
        link?.invalidate(); link = nil
        let pending = waiting; waiting = nil; pending?.resume()
    }
}
