import Testing
import SwiftUI
import UIKit
import WebKit
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct NativeTranscriptRichReflowTests {
    @Test func nativeFileExposureWaitsForPreferredRowToMatchItsAllocation() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let viewport = UIScrollView(frame: CGRect(x: 0, y: 0, width: 380, height: 300))
        viewport.contentSize = CGSize(width: 380, height: 1_000)
        host.view.addSubview(viewport)
        let cell = NativeTranscriptCell(frame: CGRect(x: 20, y: 0, width: 340, height: 400))
        viewport.addSubview(cell)
        cell.contentView.frame = cell.bounds
        let preferred = UIView(frame: CGRect(x: 0, y: 100, width: 340, height: 200))
        cell.contentView.addSubview(preferred)
        let scope = NativeTranscriptRowExposure(viewport: viewport)
        scope.rowGeometry = preferred
        let presence = NativeTranscriptBlockPresence()
        let marker = NativeTranscriptBlockMarker(frame: CGRect(x: 0, y: 150, width: 340, height: 40))
        preferred.addSubview(marker)
        marker.connect(scope: scope, presence: presence, block: 0)
        viewport.contentOffset.y = 200
        scope.setDisplayed(true)
        scope.setActive(true)

        #expect(marker.convert(marker.bounds, to: viewport).intersects(viewport.bounds))
        #expect(!presence.isVisible, "Temporary centering in the old allocation cannot admit offscreen file work.")

        preferred.frame = cell.contentView.bounds
        scope.refresh()
        #expect(!marker.convert(marker.bounds, to: viewport).intersects(viewport.bounds))
        #expect(!presence.isVisible, "Settled geometry confirms that the original marker remains above the viewport.")

        marker.frame.origin.y = 220
        scope.refresh()
        #expect(presence.isVisible, "The same settled row must admit genuinely visible content.")

        preferred.frame = CGRect(x: 0, y: -100, width: 340, height: 600)
        marker.frame.origin.y = 320
        scope.refresh()
        #expect(marker.convert(marker.bounds, to: viewport).intersects(viewport.bounds))
        #expect(presence.isVisible, "Fitting keeps already-admitted visible content alive instead of restarting it.")
        let newPresence = NativeTranscriptBlockPresence()
        let newMarker = NativeTranscriptBlockMarker(frame: marker.frame)
        preferred.addSubview(newMarker)
        newMarker.connect(scope: scope, presence: newPresence, block: 1)
        #expect(!newPresence.isVisible, "The same incomplete allocation cannot admit a fresh visible block.")
        marker.frame.origin.y = 100
        scope.refresh()
        #expect(!presence.isVisible, "Actual native clipping still revokes previously admitted work during fitting.")
        marker.frame.origin.y = 320
        scope.refresh()
        #expect(!presence.isVisible, "Returning after real coverage ends is a new admission and must wait for allocation.")

        cell.frame.size.height = 600
        cell.contentView.frame = cell.bounds
        preferred.frame = cell.contentView.bounds
        scope.refresh()
        #expect(presence.isVisible, "A completed larger allocation must not starve visible content.")
        #expect(newPresence.isVisible, "Completed allocation admits the new visible block.")
        scope.invalidate()
        #expect(!presence.isVisible)
        #expect(!newPresence.isVisible)
    }

    @Test func actualHeldFileGrowthIncomingAndReflowPreserveTheOlderBlockUntilLatest() async throws {
        let demo = DemoBotService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-rich-reflow.invalid")!)
        _ = try await demo.connect(configuration: configuration)
        let opened = try await demo.openChat(.stored(demoSpaceIdentity("canvas")))
        var rich = try #require(opened.snapshot.messages.first { ReplyContent(message: $0).blocks.contains { $0.filePreview?.isHTML == true } })
        let reference = try #require(ReplyContent(message: rich).blocks.first { $0.filePreview?.isHTML == true }?.filePreview)
        let html = try await demo.downloadArtifact(reference.attachment, access: opened.access)
        demo.disconnect()
        rich.id = "rich-reading-owner"
        rich.text += "\n\nReading landmark after the original file.\n\n" + Array(repeating: "This native paragraph keeps the older reading block taller than the viewport.", count: 30).joined(separator: "\n\n")
        let parsed = ReplyContent(message: rich)
        let reading = try #require(parsed.blocks.first { $0.source.contains("Reading landmark after the original file.") })
        let file = try #require(parsed.blocks.first { $0.filePreview?.isHTML == true })
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let earlier = (0..<40).map { ChatMessage(id: "earlier-\($0)", role: .assistant, text: "Earlier native message \($0).", timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double($0))) }
        rich.timestamp = Date(timeIntervalSince1970: 1_700_000_100)
        service.snapshots[identity.root] = .init(id: identity.root.text, storedID: identity.stored.text,
            profileID: identity.profile.text, messages: earlier + [rich])
        let gate = WorkspaceGate(); service.downloadGate = gate; service.downloadData = html.data
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); let bot = try #require(store.bots.first)
        await store.open(bot)
        let screen = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(screen.owner); store.chats.displayed(screen.owner)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }, viewport = Viewport()
        let host = UIHostingController(rootView: Host(store: store, bot: bot, viewport: viewport))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { gate.release(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await wait("actual native rich row") {
            guard let controller = controller(host) else { return false }
            guard let cell = controller.collection.cellForItem(at: IndexPath(item: 41, section: 0)) as? NativeTranscriptCell,
                  cell.isDisplayed, cell.exposure?.isCurrent == true, let root = cell.exposure?.rowGeometry else { return false }
            let rect = root.convert(root.bounds, to: cell.contentView)
            return currentMarker(block: reading.id, item: 41, controller: controller) != nil &&
                abs(rect.minY) < 1 && abs(rect.height - cell.contentView.bounds.height) < 1
        }
        let controller = try #require(controller(host))
        let first = try #require(currentMarker(block: reading.id, item: 41, controller: controller))
        var completed = false
        defer {
            if !completed {
                var rows: [[String: Any]] = []
                for block in parsed.blocks {
                    if let marker = currentMarker(block: block.id, item: 41, controller: controller) {
                        rows.append(["block": block.id, "frame": NSCoder.string(for: marker.convert(marker.bounds, to: controller.collection)),
                            "relative_y": marker.convert(marker.bounds, to: controller.collection).minY - controller.collection.bounds.minY])
                    }
                }
                let geometry: [String: Any] = ["viewport": NSCoder.string(for: controller.collection.bounds),
                    "content": NSCoder.string(for: controller.collection.contentSize), "follow": controller.followsLatest,
                    "downloads": service.downloads, "blocks": rows]
                if let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    Attachment.record(text, named: "Rich file reflow failure geometry.json")
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                Attachment.record(image, named: "Rich file reflow failure.png", as: .png)
            }
        }
        let nativeY = first.convert(first.bounds, to: controller.collection).minY
        controller.collection.setContentOffset(CGPoint(x: 0, y: nativeY - 30), animated: false)
        controller.collection.layoutIfNeeded()
        controller.scrollViewDidEndDragging(controller.collection, willDecelerate: false)
        try await wait("actual older landmark and visible file footer start the held download") {
            !controller.followsLatest && service.downloads == 1 && abs(position(reading.id, in: controller) - 30) < 1
        }
        var originalY = position(reading.id, in: controller)
        let oldHeight = try #require(currentMarker(block: file.id, item: 41, controller: controller)).bounds.height
        #expect(webViews(host.view).isEmpty, "visible footer is not permission to execute offscreen documents")
        gate.release()
        try await wait("actual source installation grows the preceding file block") {
            (currentMarker(block: file.id, item: 41, controller: controller)?.bounds.height ?? 0) > oldHeight + 200
        }
        try await wait("real asynchronous file growth keeps the older native block stationary") {
            abs(position(reading.id, in: controller) - originalY) < 1
        }
        #expect(service.downloads == 1)
        #expect(webViews(host.view).isEmpty)
        // The visible footer admitted the original held download. Move farther
        // into the tall reading block before testing offscreen reconfiguration;
        // otherwise its last pixels legitimately admit a fresh cell's read.
        controller.collection.setContentOffset(CGPoint(x: 0,
            y: controller.collection.contentOffset.y + position(reading.id, in: controller) + 30), animated: false)
        controller.collection.layoutIfNeeded()
        controller.scrollViewDidEndDragging(controller.collection, willDecelerate: false)
        try await wait("the complete preceding file block is actually offscreen") {
            guard let marker = currentMarker(block: file.id, item: 41, controller: controller) else { return false }
            return abs(position(reading.id, in: controller) + 30) < 1 &&
                marker.convert(marker.bounds, to: controller.collection).maxY < controller.collection.bounds.minY
        }
        originalY = position(reading.id, in: controller)
        let incoming = ChatMessage(id: "incoming-after-reading", role: .assistant, text: "Incoming native end point", timestamp: Date(timeIntervalSince1970: 1_700_000_101))
        service.snapshots[identity.root]?.messages.append(incoming)
        service.onEvent?(.conversation(try service.publication(identity)))
        try await wait("real incoming publication is committed without moving older content") {
            store.chats.screen(profile: service.profile)?.snapshot?.messages.last?.id == incoming.id &&
                controller.collection.numberOfItems(inSection: 0) == 44 && !controller.collection.hasUncommittedUpdates &&
                abs(position(reading.id, in: controller) - originalY) < 1
        }
        #expect(!controller.followsLatest)
        viewport.width = 330; viewport.height = 300
        try await wait("actual width and available-height reflow preserves the block") {
            abs(controller.collection.bounds.width - 330) < 1 && abs(controller.collection.bounds.height - 300) < 1 &&
                abs(position(reading.id, in: controller) - originalY) < 1
        }
        #expect(service.downloads == 1, "width reflow does not expose the offscreen file")
        #expect(webViews(host.view).isEmpty)
        let beforeLargeTextHeight = try #require(currentMarker(block: reading.id, item: 41, controller: controller)).bounds.height
        viewport.type = .accessibility1
        try await wait("actual accessibility reconfiguration preserves the block") {
            (currentMarker(block: reading.id, item: 41, controller: controller)?.bounds.height ?? 0) > beforeLargeTextHeight &&
                abs(position(reading.id, in: controller) - originalY) < 1
        }
        #expect(service.downloads == 1, "accessibility reflow does not expose the offscreen file")
        #expect(webViews(host.view).isEmpty)
        let latest = try #require(controller.view.subviews.compactMap { $0 as? UIButton }.first)
        #expect(!latest.isHidden)
        latest.sendActions(for: .touchUpInside)
        try await wait("explicit Latest reveals the actual incoming paragraph and terminal") {
            guard let cell = controller.collection.cellForItem(at: IndexPath(item: 42, section: 0)) as? NativeTranscriptCell,
                  let root = cell.exposure?.rowGeometry,
                  let terminal = controller.collection.cellForItem(at: IndexPath(item: 43, section: 0)) else { return false }
            return root.convert(root.bounds, to: controller.collection).intersects(controller.collection.bounds) &&
                controller.collection.bounds.insetBy(dx: -1, dy: -1).contains(terminal.frame) &&
                accessibilityElement(incoming.text, in: cell) != nil
        }
        #expect(controller.followsLatest)
        #expect(service.downloads == 1)
        completed = true
    }

    @MainActor @Observable final class Viewport {
        var width: CGFloat = 380
        var height: CGFloat = 434
        var type: DynamicTypeSize = .large
    }
    private struct Host: View {
        let store: AppStore
        let bot: BotProfile
        let viewport: Viewport
        @State private var presentation = WorkspacePresentation()
        var body: some View {
            transcriptFixture(store: store, bot: bot, presentation: presentation)
                .frame(width: viewport.width, height: viewport.height)
                .environment(\.dynamicTypeSize, viewport.type).environment(\.scenePhase, .active)
                .environment(\.colorScheme, .light)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
    private func controller(_ root: UIViewController) -> NativeTranscriptController? {
        if let result = root as? NativeTranscriptController { return result }
        return root.children.lazy.compactMap(controller).first
    }
    private func currentMarker(block: Int, item: Int, controller: NativeTranscriptController) -> NativeTranscriptBlockMarker? {
        guard let cell = controller.collection.cellForItem(at: IndexPath(item: item, section: 0)) as? NativeTranscriptCell else { return nil }
        func markers(_ view: UIView) -> [NativeTranscriptBlockMarker] {
            (view as? NativeTranscriptBlockMarker).map { [$0] } ?? view.subviews.flatMap(markers)
        }
        return markers(cell).first { $0.block == block && $0.role == .content && $0.scope === cell.exposure && $0.window != nil }
    }
    private func position(_ block: Int, in controller: NativeTranscriptController) -> CGFloat {
        guard let marker = currentMarker(block: block, item: 41, controller: controller) else { return .infinity }
        return marker.convert(marker.bounds, to: controller.collection).minY - controller.collection.bounds.minY
    }
    private func webViews(_ view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
    private func accessibilityElement(_ label: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 30, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.accessibilityLabel == label { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let found = find(child, depth: depth + 1) { return found } }
            }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let found = find(child, depth: depth + 1) { return found }
                }
            }
            return nil
        }
        return find(root, depth: 0)
    }
    private func wait(_ reason: String, until condition: () -> Bool) async throws {
        await waitWhile(reason) { !condition() }
        try #require(condition(), "Timed out: \(reason)")
    }
}
