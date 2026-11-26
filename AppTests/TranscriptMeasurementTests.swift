#if DEBUG
import Testing
import SwiftUI
import UIKit
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct TranscriptMeasurementTests {
    /// The legacy transcript lists rows newest first inside a flipped scroll view. The mounted
    /// fixture must still expose and draw its messages oldest first.
    @Test func legacyTranscriptExposesMessagesInChronologicalOrder() async throws {
        let texts = ["Alpha question from the reader.", "Bravo answer from the assistant.",
                     "Charlie follow-up from the reader.", "Delta final answer from the assistant."]
        let messages = texts.enumerated().map { index, text in
            ChatMessage(id: "order-\(index)", role: index % 2 == 0 ? .user : .assistant, text: text,
                        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://transcript-order.invalid")!)
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.snapshots[identity.root] = .init(id: identity.root.text, storedID: identity.stored.text,
            profileID: identity.profile.text, messages: messages)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); let bot = try #require(store.bots.first)
        await store.open(bot)
        let screen = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(screen.owner); store.chats.displayed(screen.owner)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        let measurement = TranscriptMeasurements(); TranscriptMeasurements.current = measurement; measurement.start()
        let host = UIHostingController(rootView: Host(store: store, bot: bot, native: false, viewport: Viewport()))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { measurement.stop(); TranscriptMeasurements.current = nil; window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let shown = await endpoint(measurement, message: try #require(messages.last))
        try #require(shown)
        var exposed: [(label: String, frame: CGRect)] = []
        collectAccessibility(host.view, into: &exposed)
        let matches = texts.map { text in exposed.firstIndex { $0.label.contains(text) } }
        let labels = exposed.map(\.label)
        try #require(matches.allSatisfy { $0 != nil }, "Exposed labels: \(labels)")
        let order = matches.compactMap { $0 }
        #expect(order == order.sorted() && Set(order).count == order.count, "Exposed labels: \(labels)")
        let tops = order.map { exposed[$0].frame.minY }
        #expect(tops == tops.sorted(), "Exposed frames: \(order.map { exposed[$0].frame })")
    }
    /// Public UIAccessibility traversal in the order the container reports.
    private func collectAccessibility(_ element: NSObject, into exposed: inout [(label: String, frame: CGRect)], depth: Int = 0) {
        guard depth < 64 else { return }
        if element.isAccessibilityElement {
            if let label = element.accessibilityLabel, !label.isEmpty { exposed.append((label, element.accessibilityFrame)) }
            return
        }
        if let children = element.accessibilityElements, !children.isEmpty {
            for case let child as NSObject in children { collectAccessibility(child, into: &exposed, depth: depth + 1) }
            return
        }
        let count = element.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let child = element.accessibilityElement(at: index) as? NSObject { collectAccessibility(child, into: &exposed, depth: depth + 1) }
            }
            return
        }
        if let view = element as? UIView {
            for child in view.subviews { collectAccessibility(child, into: &exposed, depth: depth + 1) }
        }
    }
    @MainActor @Observable final class Viewport { var height: CGFloat = 434 }
    private struct Host: View {
        let store: AppStore
        let bot: BotProfile
        let native: Bool
        let viewport: Viewport
        @State private var presentation = WorkspacePresentation()
        var body: some View {
            transcriptFixture(store: store, bot: bot, presentation: presentation, native: native)
                .frame(width: 380, height: viewport.height)
                .environment(\.scenePhase, .active).environment(\.dynamicTypeSize, .large)
                .environment(\.colorScheme, .light).environment(\.layoutDirection, .leftToRight)
        }
    }
    private func endpoint(_ measurement: TranscriptMeasurements, message: ChatMessage) async -> Bool {
        await wait(measurement) {
            measurement.visible(.row(Data(message.id.utf8)), revision: Data(message.text.utf8)) && measurement.terminalVisible()
        }
    }
    private func wait(_ measurement: TranscriptMeasurements, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await measurement.nextFrame()
        }
        return condition()
    }
}
#endif
