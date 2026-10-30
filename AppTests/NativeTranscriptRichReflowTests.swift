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
        let opened = try await demo.openChat(.canonical(profile: ExactID("canvas"), expectedRoot: nil))
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
    @Test(arguments: [false, true])
    func quietPublicationsHoldRealNativeGeometryThroughHeldFileFittingAndEnvironment(older: Bool) async throws {
        let demo = DemoBotService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-quiet-reflow.invalid")!)
        _ = try await demo.connect(configuration: configuration)
        let opened = try await demo.openChat(.canonical(profile: ExactID("canvas"), expectedRoot: nil))
        var rich = try #require(opened.snapshot.messages.first { ReplyContent(message: $0).blocks.contains { $0.filePreview?.isHTML == true } })
        let reference = try #require(ReplyContent(message: rich).blocks.first { $0.filePreview?.isHTML == true }?.filePreview)
        let html = try await demo.downloadArtifact(reference.attachment, access: opened.access)
        demo.disconnect()
        rich.id = "quiet-reading"
        rich.text += "\n\nQuiet reading landmark.\n\n" + Array(repeating: "The same older paragraph must stay at the same native position.", count: 30).joined(separator: "\n\n")
        let parsed = ReplyContent(message: rich)
        let reading = try #require(parsed.blocks.first { $0.source.contains("Quiet reading landmark.") })
        let file = try #require(parsed.blocks.first { $0.filePreview?.isHTML == true })
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let request = PendingRequest(id: "unchanged-request", kind: .approval, title: "Unchanged request", choices: [.init(id: "once", label: "Allow once")])
        service.snapshots[identity.root] = .init(id: identity.root.text, storedID: identity.stored.text,
            profileID: identity.profile.text, messages: [rich], pendingRequests: [request])
        let gate = WorkspaceGate(); service.downloadGate = gate; service.downloadData = html.data
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); let bot = try #require(store.bots.first); await store.open(bot)
        let screen = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(screen.owner); store.chats.displayed(screen.owner)
        let access = try #require(service.completedOpens.last).access
        let requestRow = try #require(store.chats.screen(profile: service.profile)?.requests.first { $0.request.id == request.id })
        func publish() throws {
            let snapshot = try #require(service.snapshots[identity.root])
            service.onEvent?(.conversation(.init(identity: identity, snapshot: snapshot, access: access)))
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }, viewport = Viewport()
        let measurements = TranscriptMeasurements(), previousMeasurements = TranscriptMeasurements.current
        TranscriptMeasurements.current = measurements
        defer { withExtendedLifetime(measurements) { TranscriptMeasurements.current = previousMeasurements } }
        let host = UIHostingController(rootView: Host(store: store, bot: bot, viewport: viewport)), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { gate.release(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let item = rich.timestamp == nil ? 0 : 1
        try await wait("real quiet fixture has a laid-out native rich row") {
            guard let controller = controller(host), let marker = currentMarker(block: reading.id, item: item, controller: controller) else { return false }
            return marker.bounds.height > 400 && !controller.collection.hasUncommittedUpdates
        }
        let controller = try #require(controller(host)), collection = try #require(controller.collection)
        let retiredScope = try #require((collection.cellForItem(at: IndexPath(item: item, section: 0)) as? NativeTranscriptCell)?.exposure)
        if older {
            let marker = try #require(currentMarker(block: reading.id, item: item, controller: controller))
            controller.collection.setContentOffset(CGPoint(x: 0, y: marker.convert(marker.bounds, to: collection).minY - 30), animated: false)
            controller.scrollViewDidEndDragging(collection, willDecelerate: false)
            try await wait("older reader exposes the actual held file footer") { !controller.followsLatest && service.downloads == 1 }
        } else {
            try await wait("following fixture reaches actual terminal") { controller.nearBottom && controller.followsLatest }
        }
        func landmark() -> CGFloat {
            guard let marker = currentMarker(block: reading.id, item: item, controller: controller) else { return .nan }
            return marker.convert(marker.bounds, to: collection).minY - collection.bounds.minY
        }
        let y = landmark(), oldHeight = try #require(currentMarker(block: file.id, item: item, controller: controller)).bounds.height
        let latest = try #require(controller.view.subviews.compactMap { $0 as? UIButton }.first)
        let payload = "[Cronjob \"Quiet check\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n" + String(repeating: "UNOPENED RAW PAYLOAD\n", count: 200)
        for index in 0..<2 {
            service.snapshots[identity.root]?.messages.append(.init(id: "quiet-\(index)", role: .user, text: payload, displayKind: "internal_notification"))
            service.snapshots[identity.root]?.messages.append(.init(id: "silent-\(index)", role: .assistant, text: "HIDDEN QUIET PAYLOAD", isSilent: true))
            try publish()
            try await wait("quiet publication commits with same landmark and no Latest") {
                self.controller(host) === controller && controller.collection === collection &&
                    !collection.hasUncommittedUpdates && collection.numberOfItems(inSection: 0) == item + 4 + index &&
                    abs(landmark() - y) < 1 && latest.isHidden
            }
        }
        service.snapshots[identity.root]?.isWorking = true
        try publish()
        service.snapshots[identity.root]?.isWorking = false
        try publish()
        service.downloadGate = nil
        gate.release()
        if older {
            try await wait("quiet-held actual preceding file fit preserves older block without Latest") {
                (currentMarker(block: file.id, item: item, controller: controller)?.bounds.height ?? 0) > oldHeight + 200 &&
                    abs(landmark() - y) < 1 && latest.isHidden
            }
        }
        viewport.width = 330; viewport.height = 300
        try await wait("quiet hold survives actual width and viewport reflow") {
            abs(collection.bounds.width - 330) < 1 && abs(collection.bounds.height - 300) < 1 && abs(landmark() - y) < 1 && latest.isHidden
        }
        viewport.type = .accessibility1
        try await wait("quiet hold survives accessibility fitting and unchanged request") { abs(landmark() - y) < 1 && latest.isHidden }
        #expect(service.responses.isEmpty && webViews(host.view).isEmpty)
        service.snapshots[identity.root]?.messages.append(.init(id: "meaningful-after-quiet", role: .assistant, text: "Meaningful continuation after quiet history"))
        try publish()
        try await wait("meaningful publication preserves attention policy after quiet hold") {
            collection.numberOfItems(inSection: 0) == item + 6 && (older ? !latest.isHidden && abs(landmark() - y) < 1 : controller.nearBottom)
        }
        latest.sendActions(for: .touchUpInside)
        let expected = ChatMessage(id: "meaningful-after-quiet", role: .assistant, text: "Meaningful continuation after quiet history")
        let oracle = QuietReadingOracle(controller: controller, window: window, store: store, profile: service.profile,
            owner: screen.owner, message: expected, messageItem: item + 3, request: requestRow)
        try await wait("explicit Latest reaches current actual terminal") {
            controller.nearBottom && latest.isHidden && oracle.terminalVisible(item: item + 5) &&
                (oracle.point(.message) != nil || oracle.point(.request) != nil)
        }
        let baseline = try #require(oracle.point(.message) ?? oracle.point(.request))
        try checkQuietReadingSensitivity(oracle, baseline: baseline, retiredScope: retiredScope, terminalItem: item + 5)
        service.snapshots[identity.root]?.messages.append(.init(id: "quiet-after-latest", role: .user, text: payload, displayKind: "internal_notification"))
        try publish()
        try await wait("the next quiet publication holds again after explicit Latest") {
            collection.numberOfItems(inSection: 0) == item + 7 && baseline.preserves(oracle.point(baseline.target)) && latest.isHidden
        }
    }

    private func checkQuietReadingSensitivity(_ oracle: QuietReadingOracle, baseline: QuietReadingPoint,
                                              retiredScope: NativeTranscriptRowExposure, terminalItem: Int) throws {
        let collection = oracle.collection, offset = collection.contentOffset
        defer { collection.setContentOffset(offset, animated: false) }
        try #require(baseline.preserves(oracle.point(baseline.target)))
        try #require(oracle.terminalVisible(item: terminalItem))
        collection.setContentOffset(CGPoint(x: offset.x, y: offset.y - 8), animated: false)
        try #require(abs(collection.contentOffset.y - offset.y + 8) < 1)
        let displaced = try #require(oracle.point(baseline.target))
        try #require(abs(displaced.visibleY - baseline.visibleY - 8) < 1)
        #expect(!baseline.preserves(displaced), "a real eight-point displacement must fail")
        collection.setContentOffset(offset, animated: false)
        try #require(baseline.preserves(oracle.point(baseline.target)), "restoring the actual offset restores the original semantic point")
        let wrong = QuietReadingOracle(controller: oracle.controller, window: oracle.window, store: oracle.store,
            profile: oracle.profile, owner: oracle.owner,
            message: .init(id: "wrong-reading-message", role: .assistant, text: oracle.message.text),
            messageItem: oracle.messageItem, request: .init(id: UUID(), request: oracle.request.request, intent: oracle.request.intent))
        #expect(wrong.point(baseline.target) == nil, "a different semantic occurrence must fail")
        #expect(!retiredScope.isCurrent)
        #expect(oracle.point(baseline.target, requiring: retiredScope) == nil, "a retired native scope must fail")
        collection.setContentOffset(CGPoint(x: offset.x, y: offset.y - collection.bounds.height * 2), animated: false)
        #expect(oracle.point(baseline.target) == nil, "an offscreen semantic point must fail")
        collection.setContentOffset(offset, animated: false)
        try #require(baseline.preserves(oracle.point(baseline.target)))
        let estimatedEnd = collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.height
        collection.setContentOffset(CGPoint(x: offset.x, y: estimatedEnd - 39), animated: false)
        try #require(abs(collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.maxY - 39) < 1)
        try #require(oracle.controller.nearBottom)
        #expect(!oracle.terminalVisible(item: terminalItem), "nearBottom cannot admit an offscreen actual terminal")
        collection.setContentOffset(offset, animated: false)
        try #require(baseline.preserves(oracle.point(baseline.target)) && oracle.terminalVisible(item: terminalItem))
    }

    @MainActor private struct QuietReadingPoint {
        enum Target: Equatable { case message, request }
        let target: Target
        let frame: CGRect
        let viewport: CGRect
        let visibleY: CGFloat
        func preserves(_ other: Self?) -> Bool {
            guard let other, target == other.target else { return false }
            return abs(visibleY - other.visibleY) < 1 && QuietReadingOracle.equal(frame, other.frame) && QuietReadingOracle.equal(viewport, other.viewport)
        }
    }
    @MainActor private struct QuietReadingOracle {
        let controller: NativeTranscriptController
        let window: UIWindow
        let store: AppStore
        let profile: ExactID
        let owner: PresentationOwner
        let message: ChatMessage
        let messageItem: Int
        let request: RequestRow
        var collection: UICollectionView { controller.collection }
        static func positive(_ rect: CGRect) -> Bool {
            rect.width > 0 && rect.height > 0 && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
        }
        static func equal(_ a: CGRect, _ b: CGRect) -> Bool {
            positive(a) && positive(b) && abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 &&
                abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
        }
        func clippedFrame(_ view: UIView) -> CGRect {
            guard view.window === window, collection.window === window, Self.positive(view.bounds) else { return .null }
            var clipped = view.convert(view.bounds, to: window)
                .intersection(collection.convert(collection.bounds, to: window)).intersection(window.bounds)
            var ancestor: UIView? = view
            while let current = ancestor {
                guard !current.isHidden, current.alpha > 0 else { return .null }
                if current.clipsToBounds { clipped = clipped.intersection(current.convert(current.bounds, to: window)) }
                ancestor = current.superview
            }
            return !clipped.isNull && Self.positive(clipped) ? clipped : .null
        }
        func visible(_ view: UIView) -> Bool { Self.positive(clippedFrame(view)) }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func qualified(_ cell: NativeTranscriptCell) -> Bool {
            guard cell.isDisplayed, collection.visibleCells.contains(cell),
                  let scope = cell.exposure, scope.isCurrent, scope.canPresent, scope.viewport === collection,
                  let root = scope.rowGeometry, root.isDescendant(of: cell.contentView), visible(root),
                  Self.equal(root.convert(root.bounds, to: cell.contentView), cell.contentView.bounds) else { return false }
            return true
        }
        func point(_ target: QuietReadingPoint.Target, requiring scope: NativeTranscriptRowExposure? = nil) -> QuietReadingPoint? {
            guard !collection.hasUncommittedUpdates, store.chats.isCurrent(owner),
                  let screen = store.chats.screen(profile: profile), screen.owner == owner else { return nil }
            let cell: NativeTranscriptCell
            let geometry: UIView
            switch target {
            case .message:
                guard TranscriptContentRevision.uniqueMessage(message, in: screen.snapshot),
                      let current = collection.cellForItem(at: IndexPath(item: messageItem, section: 0)) as? NativeTranscriptCell,
                      qualified(current) else { return nil }
                let tags = descendants(current).compactMap { $0 as? TranscriptMeasurementView }
                let rows = tags.filter { $0.point == .row(Data(message.id.utf8)) }
                let blocks = tags.filter { $0.point == .block(Data(message.id.utf8), 0) }
                guard rows.count == 1, blocks.count == 1,
                      rows[0].revision == Data(message.text.utf8), rows[0].viewport === collection,
                      blocks[0].viewport === collection, visible(rows[0]), visible(blocks[0]) else { return nil }
                cell = current; geometry = blocks[0]
            case .request:
                let rows = screen.requests.filter { $0.id == request.id || Data($0.request.id.utf8) == Data(request.request.id.utf8) }
                guard rows.count == 1, rows[0].id == request.id,
                      TranscriptContentRevision.sameRequest(rows[0].request, request.request) else { return nil }
                let cells = collection.visibleCells.compactMap { $0 as? NativeTranscriptCell }.filter {
                    $0.exposure?.requestState?.input.row.id == request.id
                }
                guard cells.count == 1, qualified(cells[0]), let state = cells[0].exposure?.requestState,
                      state.isCurrent, state.input.owner == owner, state.input.workspace === store.chats,
                      TranscriptContentRevision.sameRequest(state.input.row.request, request.request),
                      let root = cells[0].exposure?.rowGeometry else { return nil }
                cell = cells[0]; geometry = root
            }
            guard scope == nil || (scope?.isCurrent == true && cell.exposure === scope), visible(geometry) else { return nil }
            let frame = geometry.convert(geometry.bounds, to: collection).offsetBy(dx: -collection.bounds.minX, dy: -collection.bounds.minY)
            let localY = frame.minY >= 0 ? geometry.bounds.minY + 0.5 : geometry.bounds.maxY - 0.5
            let point = geometry.convert(CGPoint(x: geometry.bounds.midX, y: localY), to: window)
            guard clippedFrame(geometry).contains(point) else { return nil }
            let visibleY = window.convert(point, to: collection).y - collection.bounds.minY
            return QuietReadingPoint(target: target, frame: frame, viewport: collection.convert(collection.bounds, to: window), visibleY: visibleY)
        }
        func terminalVisible(item: Int) -> Bool {
            guard let cell = collection.cellForItem(at: IndexPath(item: item, section: 0)) as? NativeTranscriptCell,
                  qualified(cell), let root = cell.exposure?.rowGeometry else { return false }
            let tags = descendants(cell).compactMap { $0 as? TranscriptMeasurementView }.filter { $0.point == .terminal }
            return tags.count == 1 && tags[0].viewport === collection && visible(tags[0]) &&
                collection.bounds.insetBy(dx: -1, dy: -1).contains(cell.frame) &&
                collection.bounds.insetBy(dx: -1, dy: -1).contains(root.convert(root.bounds, to: collection))
        }
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
            transcriptFixture(store: store, bot: bot, presentation: presentation, native: true)
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
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Timed out: \(reason)")
    }
}
