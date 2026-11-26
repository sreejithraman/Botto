import Testing
import SwiftUI
import UIKit
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct NativeTranscriptRevisionTests {
    @Test func expandedRawDetailsCopyTheCurrentExactBytesAfterEquivalentUnicodeRevision() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        let oldText = "RAW é", newText = "RAW e\u{301}"
        var message = ChatMessage(id: "exact-raw", role: .system, text: oldText)
        service.snapshots[session.root]?.messages = [message]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-exact-raw.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let fixture = try Window(store: store, bot: try #require(store.selectedBot))
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await revisionWait("raw note disclosure is available") {
            revisionElement("Work details", in: fixture.host.view) != nil
        }
        #expect(try #require(revisionElement("Work details", in: fixture.host.view)).accessibilityActivate())
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
        #expect(try #require(revisionElement("Work details", in: currentCell)).accessibilityActivate())
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

    @Test func systemNotesUseWorkDetails() async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        service.snapshots[session.root]?.messages = [.init(id: "routine", role: .system, text: "ROUTINE-GATEWAY-DETAIL")]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-system-details.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let fixture = try Window(store: store, bot: try #require(store.selectedBot))
        defer { fixture.close(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try await revisionWait("routine details collapse") {
            revisionElement("Work details", in: fixture.host.view) != nil &&
                revisionElement("ROUTINE-GATEWAY-DETAIL", in: fixture.host.view) == nil
        }
        let details = try #require(revisionElement("Work details", in: fixture.host.view))
        #expect(details.accessibilityActivate())
        let controller = try #require(revisionController(fixture.host))
        try await revisionWait("routine note opens through the shared sheet") {
            controller.presentedViewController.map { revisionElement("ROUTINE-GATEWAY-DETAIL", in: $0.view) != nil } == true
        }
        #expect(controller.presentedViewController?.sheetPresentationController != nil)
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

    @Test func exactEmptyProfileInputsAndStreamingProjectionChangeDisplayRevisionOnly() throws {
        let message = ChatMessage(id: "same", role: .assistant, text: "```html\n<p>Done</p>\n```")
        let streaming = NativeTranscriptRowValue.message(message, working: true, streaming: true)
        let formerTail = NativeTranscriptRowValue.message(message, working: true, streaming: false)
        #expect(streaming != formerTail && streaming.canContinueForeground(with: formerTail))
        var profile = BotProfile(id: "same", name: "é", appearance: .init(shape: .circle, color: "#ef4444"))
        let original = NativeTranscriptEmptyDisplay(profile: profile, opening: false, connected: true)
        profile.name = "e\u{301}"
        #expect(original != .init(profile: profile, opening: false, connected: true))
        #expect(original != .init(profile: original.profile, opening: true, connected: true))
        #expect(original != .init(profile: original.profile, opening: false, connected: false))
        #expect(original == .init(profile: original.profile, opening: false, connected: true))
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
        init(store: AppStore, bot: BotProfile) throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            profile = Profile(bot)
            host = UIHostingController(rootView: Host(store: store, profile: profile))
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
        @State private var presentation = WorkspacePresentation()
        var body: some View {
            transcriptFixture(store: store, bot: profile.bot, presentation: presentation)
                .frame(width: 382, height: 434)
                .environment(\.scenePhase, .active)
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
    await waitWhile(reason) { !condition() }
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
