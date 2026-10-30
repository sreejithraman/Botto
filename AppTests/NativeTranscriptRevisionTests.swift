import Testing
import SwiftUI
import UIKit
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct NativeTranscriptRevisionTests {
    @Test func expandedRawDetailsCopyTheCurrentExactBytesAfterEquivalentUnicodeRevision() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        let oldText = "RAW é", newText = "RAW e\u{301}"
        var message = ChatMessage(id: "exact-raw", role: .user, text: oldText, displayKind: "process_complete")
        service.snapshots[session.root]?.messages = [message]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-exact-raw.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let fixture = try Window(store: store, bot: try #require(store.selectedBot))
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await revisionWait("raw event disclosure is available") {
            revisionElement("Show details for Background process finished", in: fixture.host.view) != nil
        }
        #expect(try #require(revisionElement("Show details for Background process finished", in: fixture.host.view)).accessibilityActivate())
        let controller = try #require(revisionController(fixture.host))
        try await revisionWait("original exact raw text is visible in the sheet") {
            controller.presentedViewController.map { revisionElement(oldText, in: $0.view) != nil } == true
        }
        let oldScope = try #require((controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)?.exposure)
        message.text = newText
        service.snapshots[session.root]?.messages = [message]
        service.onEvent?(.conversation(.init(identity: session, snapshot: try #require(service.snapshots[session.root]),
            access: try #require(service.completedOpens.last).access)))
        #expect(store.chats.screen(profile: service.profile)?.snapshot?.messages.first.map { Data($0.text.utf8) == Data(newText.utf8) } == true)
        try await revisionWait("native raw revision retires the old row scope") {
            guard !oldScope.isCurrent,
                  let cell = controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell,
                  let scope = cell.exposure else { return false }
            return scope !== oldScope && scope.canPresent && controller.presentedViewController == nil
        }
        let currentCell = try #require(controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        #expect(try #require(revisionElement("Show details for Background process finished", in: currentCell)).accessibilityActivate())
        try await revisionWait("current raw details expose an enabled copy action") {
            controller.presentedViewController.map { revisionElement("Copy original", in: $0.view).map { !$0.accessibilityTraits.contains(.notEnabled) } == true } == true
        }
        let sheet = try #require(controller.presentedViewController)
        UIPasteboard.general.string = "before-equivalent-revision-copy"
        #expect(try #require(revisionElement("Copy original", in: sheet.view)).accessibilityActivate())
        try await revisionWait("copy exports the current exact raw bytes") {
            UIPasteboard.general.string.map { Data($0.utf8) == Data(newText.utf8) } == true
        }
    }

    @Test func routineSystemNotesUseWorkDetailsWhileFailuresRemainVisible() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        service.snapshots[session.root]?.messages = [
            .init(id: "routine", role: .system, text: "ROUTINE-GATEWAY-DETAIL"),
            .init(id: "error:current-turn", role: .system, text: "The turn failed. Check the host.")
        ]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-system-details.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let fixture = try Window(store: store, bot: try #require(store.selectedBot))
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await revisionWait("routine details collapse while the failure stays visible") {
            revisionElement("Work details", in: fixture.host.view) != nil &&
                revisionElement("ROUTINE-GATEWAY-DETAIL", in: fixture.host.view) == nil &&
                revisionElement("The turn failed. Check the host.", in: fixture.host.view) != nil
        }
        let details = try #require(revisionElement("Work details", in: fixture.host.view))
        #expect(details.accessibilityActivate())
        let controller = try #require(revisionController(fixture.host))
        try await revisionWait("routine note opens through the shared sheet") {
            controller.presentedViewController.map { revisionElement("ROUTINE-GATEWAY-DETAIL", in: $0.view) != nil } == true
        }
        #expect(controller.presentedViewController?.sheetPresentationController != nil)
    }

    @Test func backgroundAndBotRowsUseTheirSourceAndMetadataOnlyUpdatesReachTheNativeView() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        let payload = "[ASYNC DELEGATION BATCH COMPLETE — deleg_example]\nPRIVATE-RAW-BACKGROUND-RESULT"
        let background = ChatMessage(id: "background", role: .user, text: payload,
            displayKind: "async_delegation_complete", displayText: "Background review finished")
        let sender = ChatMessage(id: "gustavo", role: .user,
            text: "Message from 🤖 Gustavo (@hermes): Please own this follow-up.", displayKind: "internal_notification")
        service.snapshots[session.root]?.messages = [background, sender]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-attribution.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let fixture = try Window(store: store, bot: try #require(store.selectedBot))
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await revisionWait("compact event and attributed sender render") {
            revisionElement("Show details for Background review finished", in: fixture.host.view) != nil &&
                revisionElement("From Gustavo · @hermes", in: fixture.host.view) != nil &&
                revisionElement("Please own this follow-up.", in: fixture.host.view) != nil
        }
        #expect(revisionElement(payload, in: fixture.host.view) == nil)
        let controller = try #require(revisionController(fixture.host))
        let details = try #require(revisionElement("Show details for Background review finished", in: fixture.host.view))
        #expect(details.accessibilityActivate())
        try await revisionWait("background event opens the details sheet") {
            controller.presentedViewController.map { revisionElement("PRIVATE-RAW-BACKGROUND-RESULT", in: $0.view) != nil } == true
        }
        let sheet = try #require(controller.presentedViewController)
        try await revisionWait("raw reader exposes the bounded payload sections") {
            revisionElement("[ASYNC DELEGATION BATCH COMPLETE — deleg_example]", in: sheet.view) != nil &&
                revisionElement("PRIVATE-RAW-BACKGROUND-RESULT", in: sheet.view) != nil
        }
        var changed = background; changed.displayText = "Background review failed"
        service.snapshots[session.root]?.messages = [changed, sender]
        let access = try #require(service.completedOpens.last).access
        service.onEvent?(.conversation(.init(identity: session, snapshot: try #require(service.snapshots[session.root]), access: access)))
        try await revisionWait("metadata-only update retires details and changes event title") {
            controller.presentedViewController == nil &&
                revisionElement("Show details for Background review failed", in: fixture.host.view) != nil
        }
    }

    @Test func initialMessageStartsBelowTheFloatingProfileHeader() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        let text = "The first message stays readable below the bot."
        service.snapshots[session.root]?.messages = [.init(id: "first-readable-message", role: .user, text: text)]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://initial-header.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let fixture = try Window(store: store, bot: try #require(store.selectedBot), fullChat: true)
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        func header(in controller: UIViewController) -> NativeTranscriptHeaderController? {
            if let header = controller as? NativeTranscriptHeaderController { return header }
            return controller.children.lazy.compactMap(header).first
        }
        try await revisionWait("the initial message and floating profile header are mounted") {
            revisionElement(text, in: fixture.host.view).map { !$0.accessibilityFrame.isEmpty } == true &&
                header(in: fixture.host)?.view.window != nil && revisionController(fixture.host)?.previewState != nil
        }
        var headerFrame = CGRect.zero, messageFrame = CGRect.zero
        defer {
            Attachment.record("message=\(messageFrame)\nheader=\(headerFrame)", named: "initial-chat-header-geometry.txt")
        }
        try await revisionWait("the initial message clears the visible floating profile header") {
            guard let profileHeader = header(in: fixture.host),
                  let message = revisionElement(text, in: fixture.host.view) else { return false }
            headerFrame = profileHeader.view.convert(profileHeader.view.bounds, to: fixture.window)
            messageFrame = fixture.window.convert(message.accessibilityFrame, from: nil)
            return !headerFrame.isEmpty && !messageFrame.isEmpty && messageFrame.minY >= headerFrame.maxY
        }
        #expect(messageFrame.minY >= headerFrame.maxY,
                "message=\(messageFrame), header=\(headerFrame)")
    }

    @Test func floatingHeaderBindsTheMountedScrollViewAndReleasesItOnRetirement() async throws {
        guard #available(iOS 26, *) else { return }
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-header.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let fixture = try Window(store: store, bot: try #require(store.selectedBot), fullChat: true)
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        func header(in controller: UIViewController) -> NativeTranscriptHeaderController? {
            if let header = controller as? NativeTranscriptHeaderController { return header }
            for child in controller.children { if let found = header(in: child) { return found } }
            return nil
        }
        try await revisionWait("the floating header observes the mounted transcript") {
            guard let transcript = revisionController(fixture.host),
                  let header = header(in: fixture.host),
                  let edge = header.view.interactions.compactMap({ $0 as? UIScrollEdgeElementContainerInteraction }).first else { return false }
            return edge.scrollView === transcript.collection
        }
        let transcript = try #require(revisionController(fixture.host))
        let floatingHeader = try #require(header(in: fixture.host))
        let edge = try #require(floatingHeader.view.interactions.compactMap { $0 as? UIScrollEdgeElementContainerInteraction }.first)
        let bar = try #require(floatingHeader.navigationController?.navigationBar)
        var nativeTarget: UIButton?
        try await revisionWait("the real floating header routes its native-bar overlap") {
            let overlap = floatingHeader.view.convert(floatingHeader.view.bounds, to: bar).intersection(bar.bounds)
            guard !overlap.isNull, !overlap.isEmpty else { return false }
            nativeTarget = bar.hitTest(CGPoint(x: overlap.midX, y: overlap.midY), with: nil) as? UIButton
            return nativeTarget != nil
        }
        let target = try #require(nativeTarget)
        #expect(!target.isAccessibilityElement)
        floatingHeader.retire()
        #expect(target.superview == nil)
        #expect(floatingHeader.onActivate == nil)
        floatingHeader.view.setNeedsLayout(); floatingHeader.view.layoutIfNeeded()
        #expect(target.superview == nil)
        transcript.retire()
        #expect(edge.scrollView == nil)
    }

    @Test func viewportCaptureCoalescesAndRetiresWithItsActualNativeOwner() async throws {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://preview-owner.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let fixture = try Window(store: store, bot: try #require(store.selectedBot))
        fixture.window.overrideUserInterfaceStyle = .light
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await revisionWait("the mounted transcript is eligible for a viewport capture") {
            revisionController(fixture.host)?.previewState != nil
        }
        let controller = try #require(revisionController(fixture.host))
        let capture = NativeTranscriptPreview()
        var images: [UIImage] = []
        capture.didCapture = { _, image, _, _ in images.append(image) }
        capture.bind(controller)
        let chatID = try #require(controller.previewState).owner.chat.value.uuidString
        #expect(capture.viewportView(for: chatID) === controller.collection)
        #expect(capture.viewportView(for: UUID().uuidString) == nil)
        for _ in 0..<10 { capture.requestCapture(from: controller) }
        try await revisionWait("one coalesced capture contains the real mounted viewport") { images.count == 1 }
        #expect(capture.hasCurrentViewportCapture)
        let originalOffset = controller.collection.contentOffset
        controller.collection.setContentOffset(CGPoint(x: originalOffset.x, y: originalOffset.y + 12), animated: false)
        #expect(!capture.hasCurrentViewportCapture, "The idle thumbnail no longer represents the current viewport.")
        #expect(capture.viewportView(for: chatID) === controller.collection,
                "The mounted pane remains available for a sharp zoom before the thumbnail refreshes.")
        controller.collection.setContentOffset(originalOffset, animated: false)
        #expect(capture.hasCurrentViewportCapture)
        let image = try #require(images.first?.cgImage)
        #expect(image.width <= 300 && image.height <= 560)
        let bytes = try #require(image.dataProvider?.data) as Data
        #expect(Set(bytes).count > 4, "An actual transcript capture must contain more than a blank surface")
        let corner = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let sampled = pixel.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        #expect(sampled)
        #expect(pixel[0] > 245 && pixel[1] > 240 && pixel[2] > 235,
                "Light transcript captures preserve their paper background: \(pixel)")
        print("[SNAPSHOT-RESEARCH] mountedViewportMS=\(capture.lastCaptureMilliseconds ?? -1)")
        for _ in 0..<10 { capture.requestCapture(from: controller) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(images.count == 1, "Unchanged views reuse their previous capture")
        for expected in 2...3 {
            capture.invalidate(); capture.requestCapture(from: controller)
            try await revisionWait("a warm mounted viewport can refresh its capture") { images.count == expected }
            print("[SNAPSHOT-RESEARCH] mountedViewportMS=\(capture.lastCaptureMilliseconds ?? -1)")
        }
        capture.invalidate(); capture.requestCapture(from: controller)
        let replacement = NativeTranscriptPreview()
        var replacementCount = 0
        replacement.didCapture = { _, _, _, _ in replacementCount += 1 }
        replacement.bind(controller)
        replacement.requestCapture(from: controller)
        capture.unbind(controller)
        #expect(!capture.hasCurrentViewportCapture)
        try await revisionWait("a replacement capture handle owns the same mounted view") { replacementCount == 1 }
        #expect(images.count == 3, "An obsolete handle cannot publish or retire its replacement")
        replacement.invalidate(); replacement.requestCapture(from: controller)
        controller.retire()
        #expect(replacement.viewportView(for: chatID) == nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(images.count == 3, "A retired native owner cannot publish a delayed capture")
        #expect(replacementCount == 1)
    }

    @Test func sameWorkingPublicationFinalizesFormerTailRichFenceWithoutFinalNewline() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        // Canonically equivalent Swift strings remain distinct message IDs.
        let message = ChatMessage(id: "\u{e9}", role: .assistant, text: "```html\n<p>A complete former tail.</p>\n```")
        service.snapshots[session.root]?.messages = [message]
        service.snapshots[session.root]?.isWorking = true
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-tail-revision.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let original = try #require(store.chats.screen(profile: service.profile))
        let access = try #require(service.completedOpens.last).access
        let fixture = try Window(store: store, bot: try #require(store.selectedBot))
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await revisionWait("actual incomplete streaming code is displayed") {
            revisionElement("Code: <p>A complete former tail.</p>\n```", in: fixture.host.view) != nil
        }
        #expect(revisionElement("Show HTML source", in: fixture.host.view) == nil)
        let controller = try #require(revisionController(fixture.host))
        let old = try #require((controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)?.exposure)
        var incoming = try #require(service.snapshots[session.root])
        incoming.messages.append(.init(id: "e\u{301}", role: .tool, text: "Tool is still working"))
        service.snapshots[session.root] = incoming
        service.onEvent?(.conversation(.init(identity: session, snapshot: incoming, access: access)))
        #expect(store.chats.screen(profile: service.profile)?.owner == original.owner)
        #expect(store.chats.screen(profile: service.profile)?.snapshot?.isWorking == true)
        try await revisionWait("same native controller reconfigures the unchanged former tail into an HTML preview") {
            revisionController(fixture.host) === controller && revisionElement("Show HTML source", in: fixture.host.view) != nil
        }
        #expect(!old.isCurrent, "the stale streaming host must be replaced without retiring message foreground authority")
    }

    @Test func cachedWrapperReclassifiesOnFreshMetadataThenTimestampAndVisibilityThroughBothRenderGates() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        let payload = "[Cronjob \"Daily review\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\nRAW-SCHEDULED-BODY"
        let encoded = try JSONEncoder().encode(ChatMessage(id: "metadata-only", role: .user, text: payload, timestamp: Date(timeIntervalSince1970: 10)))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "displayKind"); object.removeValue(forKey: "isSilent")
        let cached = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(cached.scheduledJobName == nil && cached.isVisible)
        service.snapshots[session.root]?.messages = [cached]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-cached-metadata.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let fixture = try Window(store: store, bot: try #require(store.selectedBot))
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await revisionWait("cached wrapper really renders as ordinary text") { revisionElement(payload, in: fixture.host.view) != nil }
        let controller = try #require(revisionController(fixture.host))
        let access = try #require(service.completedOpens.last).access
        var fresh = cached; fresh.displayKind = "internal_notification"
        func publish(_ message: ChatMessage) throws {
            service.snapshots[session.root]?.messages = [message]
            let snapshot = try #require(service.snapshots[session.root])
            service.onEvent?(.conversation(.init(identity: session, snapshot: snapshot, access: access)))
        }
        try publish(fresh)
        try await revisionWait("metadata-only update reaches compact scheduled branch in same controller") {
            revisionController(fixture.host) === controller && revisionElement("Show details for scheduled check, Daily review", in: fixture.host.view) != nil &&
                revisionElement(payload, in: fixture.host.view) == nil && !controller.collection.hasUncommittedUpdates &&
                (controller.collection.cellForItem(at: IndexPath(item: 1, section: 0)) as? NativeTranscriptCell)?.exposure?.canPresent == true
        }
        let details = try #require(revisionElement("Show details for scheduled check, Daily review", in: fixture.host.view))
        #expect(details.accessibilityActivate())
        try await revisionWait("fresh metadata opens the details sheet") {
            controller.presentedViewController.map { revisionElement("RAW-SCHEDULED-BODY", in: $0.view) != nil } == true
        }
        let scheduledCell = try #require(controller.collection.cellForItem(at: IndexPath(item: 1, section: 0)) as? NativeTranscriptCell)
        let firstScope = try #require(scheduledCell.exposure)
        fresh.timestamp = Date(timeIntervalSince1970: 20)
        try publish(fresh)
        try await revisionWait("timestamp-only revision replaces hosted row and retires Details") { !firstScope.isCurrent && controller.presentedViewController == nil }
        fresh.displayKind = nil; try publish(fresh)
        try await revisionWait("reverse provenance restores ordinary body") {
            revisionElement(payload, in: fixture.host.view) != nil && revisionElement("Show details for scheduled check, Daily review", in: fixture.host.view) == nil
        }
        fresh.isSilent = true; try publish(fresh)
        try await revisionWait("visibility-only revision removes body while retaining raw date semantics") {
            controller.collection.numberOfItems(inSection: 0) == 2 && revisionElement(payload, in: fixture.host.view) == nil
        }
    }

    @Test func sameOwnerRosterRefreshUpdatesActualEmptyGreetingAndFaceWithoutAuthorityRetirement() async throws {
        let service = try NativeTranscriptReviewService(), session = service.base.summaries[0].identity
        service.base.snapshots[session.root]?.messages = []
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-empty-revision.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.selectedBot ?? store.bots.first))
        let owner = try #require(store.chats.screen(profile: service.base.profile)?.owner)
        let fixture = try Window(store: store, bot: try #require(store.selectedBot))
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await revisionWait("original empty greeting in a real native host") { revisionElement("Hello, Milo.", in: fixture.host.view) != nil }
        let controller = try #require(revisionController(fixture.host))
        let old = try #require((controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)?.exposure)
        service.profile.name = "Renamed Milo"
        service.profile.appearance = .init(shape: .triangle, color: "#ef4444", expression: "happy")
        service.profile.lookRevision = 2
        await store.refresh()
        fixture.profile.bot = try #require(store.selectedBot)
        #expect(store.chats.screen(profile: service.base.profile)?.owner == owner)
        try await revisionWait("same native controller displays refreshed greeting") {
            revisionController(fixture.host) === controller && revisionElement("Hello, Renamed Milo.", in: fixture.host.view) != nil
        }
        #expect(!old.isCurrent)
        let renamed = try #require((controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)?.exposure)
        // Appearance-only refresh has no visible text change to accidentally
        // force reconfiguration. It must still replace the empty row payload.
        service.profile.appearance = .init(shape: .cloud, color: "#22c55e", expression: "focused")
        await store.refresh()
        fixture.profile.bot = try #require(store.selectedBot)
        try await revisionWait("same-name appearance refresh replaces its native hosted payload") { !renamed.isCurrent }
        #expect(store.chats.screen(profile: service.base.profile)?.owner == owner)
        #expect(revisionElement("Hello, Renamed Milo.", in: fixture.host.view) != nil)
    }

    @Test func exactEmptyProfileAndThumbnailInputsAndStreamingProjectionChangeDisplayRevisionOnly() throws {
        let message = ChatMessage(id: "same", role: .assistant, text: "```html\n<p>Done</p>\n```")
        let streaming = NativeTranscriptRowValue.message(message, working: true, streaming: true)
        let formerTail = NativeTranscriptRowValue.message(message, working: true, streaming: false)
        #expect(streaming != formerTail && streaming.hasSameForegroundContent(as: formerTail))
        var profile = BotProfile(id: "same", name: "é", appearance: .init(shape: .circle, color: "#ef4444"))
        let original = NativeTranscriptEmptyDisplay(profile: profile, image: nil, opening: false, connected: true)
        profile.name = "e\u{301}"
        #expect(original != .init(profile: profile, image: nil, opening: false, connected: true))
        #expect(original != .init(profile: original.profile, image: nil, opening: true, connected: true))
        #expect(original != .init(profile: original.profile, image: nil, opening: false, connected: false))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        #expect(original != .init(profile: original.profile, image: image, opening: false, connected: true))
        let withImage = NativeTranscriptEmptyDisplay(profile: original.profile, image: image, opening: false, connected: true)
        #expect(withImage == .init(profile: original.profile, image: image, opening: false, connected: true))
        let replacement = UIImage(cgImage: try #require(image.cgImage))
        #expect(withImage != .init(profile: original.profile, image: replacement, opening: false, connected: true))
    }

    @Test func sharedAndIndependentTextStoragePreserveExactWireRevisions() {
        let text = String(repeating: "Unchanged history 🧑🏽‍💻.\n", count: 400)
        let original = ChatMessage(id: "same", role: .assistant, text: text)
        let copied = original
        let rebuilt = ChatMessage(id: "same", role: .assistant,
                                  text: String(decoding: Array(text.utf8), as: UTF8.self))
        #expect(NativeTranscriptRowValue.message(original, working: false) == .message(copied, working: false))
        #expect(NativeTranscriptRowValue.message(original, working: false) == .message(rebuilt, working: false))
        for (first, second) in [("é", "e\u{301}"), ("a\0b", "a\0c"), ("👩‍💻", "👨‍💻"), ("", " ")] {
            let firstMessage = ChatMessage(id: "same", role: .assistant, text: first)
            let secondMessage = ChatMessage(id: "same", role: .assistant, text: second)
            #expect(NativeTranscriptRowValue.message(firstMessage, working: false) != .message(secondMessage, working: false))
        }
    }

    @MainActor private final class Window {
        let host: UIHostingController<Host>
        let window: UIWindow
        let previous: UIWindow?
        let profile: Profile
        init(store: AppStore, bot: BotProfile, fullChat: Bool = false) throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            profile = Profile(bot)
            host = UIHostingController(rootView: Host(store: store, profile: profile, fullChat: fullChat))
            window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        }
        func close() {
            revisionController(host)?.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
    }
    @MainActor @Observable final class Profile {
        var bot: BotProfile
        init(_ bot: BotProfile) { self.bot = bot }
    }
    private struct Host: View {
        let store: AppStore
        let profile: Profile
        let fullChat: Bool
        @State private var presentation = WorkspacePresentation()
        var body: some View {
            Group {
                if fullChat {
                    NavigationStack {
                        ChatView(store: store, bot: profile.bot, presentation: presentation,
                                 isExposed: true, isEditingExposed: true, rootCovered: false,
                                 onLocalModalPresentation: { _ in })
                    }
                } else {
                    transcriptFixture(store: store, bot: profile.bot, presentation: presentation, native: true)
                }
            }
            .frame(width: 382, height: 434).environment(\.scenePhase, .active)
        }
    }
}

@MainActor private func revisionController(_ parent: UIViewController) -> NativeTranscriptController? {
    if let controller = parent as? NativeTranscriptController, controller.isViewLoaded, controller.view.window != nil { return controller }
    return parent.children.lazy.compactMap(revisionController).first
}
@MainActor private func revisionElement(_ label: String, in root: NSObject) -> NSObject? {
    var visited = Set<ObjectIdentifier>()
    func find(_ object: NSObject, depth: Int) -> NSObject? {
        guard depth < 30, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        // UIKit can retain hidden hosts for retired transcript cells.
        if let view = object as? UIView, view.isHidden || view.alpha == 0 || view.window == nil { return nil }
        if object.accessibilityLabel.map({ Data($0.utf8) == Data(label.utf8) }) == true { return object }
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
@MainActor private func revisionWait(_ reason: String, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    let passed = condition()
    if !passed {
        // Observe only after the original verdict. Do not force layout to make
        // a host, accessibility element or pixel endpoint become ready.
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for (index, window) in scene.windows.enumerated() where !window.isHidden {
                guard let root = window.rootViewController else { continue }
                if let controller = revisionController(root) {
                    let collection = controller.collection!
                    print("REVISION-FAIL reason=\(reason) window=\(index) attached=\(controller.view.window === window) items=\(collection.numberOfSections > 0 ? collection.numberOfItems(inSection: 0) : 0) viewport=\(collection.bounds) content=\(collection.contentSize)")
                    for case let cell as NativeTranscriptCell in collection.visibleCells {
                        let geometry = cell.exposure?.rowGeometry
                        print("REVISION-CELL index=\(String(describing: collection.indexPath(for: cell))) displayed=\(cell.isDisplayed) current=\(cell.exposure?.isCurrent == true) geometry=\(String(describing: geometry?.bounds)) rootAttached=\(geometry?.window === window) cellFrame=\(cell.frame) axCount=\(cell.accessibilityElementCount())")
                    }
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
                let name = reason.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
                Attachment.record(image, named: "revision-failure-\(name)-\(index).png", as: .png)
            }
        }
    }
    try #require(passed, "Timed out: \(reason)")
}
