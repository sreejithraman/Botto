import Foundation
import Testing
import SwiftUI
import UIKit
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) struct ChatPickerPresentationTests {
    @Test @MainActor func nativePreviewFillsTheCardWithoutShowingGeneratedExcerptAtItsSides() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
            $0.activationState == .foregroundActive
        })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let viewport = UIView(frame: root.view.bounds)
        viewport.backgroundColor = .white
        root.view.addSubview(viewport)
        let transition = ChatOverviewTransition()
        transition.selectedID = "current"
        transition.viewportProvider = { id in id == "current" ? viewport : nil }
        let boundsView = UIView()
        let card = AnyView(ChatPickerCard(
            item: .init(id: "current", title: "Main", userPreview: "Generated fallback bubble",
                        replyPreview: String(repeating: "Generated excerpt ", count: 20), isSelected: true),
            transition: transition, preview: nil, onSelect: {}, onSetPreferred: {})
            .frame(width: 200)
            .background(PickerFrameProbe(view: boundsView))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, .dark))
        let controller = ChatOverviewContainer<AnyView>.Controller(transition: transition)
        root.addChild(controller)
        controller.view.frame = root.view.bounds
        root.view.addSubview(controller.view)
        controller.didMove(toParent: root)
        defer {
            controller.tearDown()
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        root.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        controller.update(isPresented: true, content: card, onDismiss: {})
        let deadline = ContinuousClock.now + .milliseconds(250)
        while transition.animatingID == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(transition.animatingID == "current")
        transition.finishImmediately()
        try await Task.sleep(for: .milliseconds(40))
        #expect(boundsView.window === window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.preferredRange = .standard; format.opaque = true
        for x: CGFloat in [14, 186] {
            let point = boundsView.convert(CGPoint(x: x, y: 40), to: window)
            var drew = false
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
                context.cgContext.translateBy(x: -point.x, y: -point.y)
                drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            #expect(drew)
            let pixel = try #require(image.cgImage?.dataProvider?.data) as Data
            #expect(pixel.prefix(3).allSatisfy { $0 > 240 },
                    "The white native viewport must fill both card edges; no narrow centered image or generated text may show beside it.")
        }
    }

    @Test @MainActor func mountedViewportZoomsBeforeAnIdleThumbnailExists() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
            $0.activationState == .foregroundActive
        })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let viewport = UILabel(frame: root.view.bounds)
        viewport.frame.size.width = 200
        viewport.text = "Sharp text from the mounted conversation"
        viewport.backgroundColor = .white
        root.view.addSubview(viewport)
        let transition = ChatOverviewTransition()
        transition.selectedID = "current"
        transition.viewportProvider = { id in id == "current" ? viewport : nil }
        let controller = ChatOverviewContainer<AnyView>.Controller(transition: transition)
        var dismissals = 0
        root.addChild(controller)
        controller.view.frame = CGRect(x: 0, y: 100, width: 200,
                                       height: root.view.bounds.height - 100)
        root.view.addSubview(controller.view)
        controller.didMove(toParent: root)
        defer {
            controller.tearDown()
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        root.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        func pixelUnderHeader(x: CGFloat = 50) throws -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.preferredRange = .standard; format.opaque = true
            var drew = false
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
                context.cgContext.translateBy(x: -x, y: -50)
                drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            #expect(drew)
            let pixels = try #require(image.cgImage?.dataProvider?.data) as Data
            return pixels
        }
        #expect(try pixelUnderHeader().prefix(3).allSatisfy { $0 > 240 }, "The fixture starts with a visible bright reader.")
        let cards = AnyView(HStack {
            ChatOverviewCardAnchor(id: "current", transition: transition).frame(width: 160, height: 240)
            ChatOverviewCardAnchor(id: "destination", transition: transition).frame(width: 160, height: 240)
        })
        controller.update(isPresented: true, content: cards, onDismiss: { dismissals += 1 })
        let deadline = ContinuousClock.now + .milliseconds(250)
        while transition.animatingID == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(transition.animatingID == "current",
                "A mounted conversation must zoom even immediately after scrolling, before its delayed thumbnail exists.")
        transition.finishImmediately()
        let pixels = try pixelUnderHeader()
        #expect(pixels.prefix(3).allSatisfy { $0 < 100 },
                "The overview covers the scroll-under region; the bright full-size reader cannot remain behind the fixed header.")
        viewport.frame.size.width = 360
        controller.view.frame.size.width = 360
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(try pixelUnderHeader(x: 300).prefix(3).allSatisfy { $0 < 100 },
                "Widening an open overview must keep the newly exposed scroll-under region covered.")
        transition.selectedID = "destination"
        controller.update(isPresented: false, content: cards, onDismiss: { dismissals += 1 })
        transition.viewportDidChange?()
        try await Task.sleep(for: .milliseconds(180))
        #expect(dismissals == 0 && transition.animatingID == nil,
                "The previous chat must not expand while the selected destination is still mounting.")
        let destination = UILabel(frame: viewport.frame)
        destination.text = "The selected conversation"
        root.view.insertSubview(destination, belowSubview: controller.view)
        transition.viewportProvider = { id in id == "destination" ? destination : nil }
        transition.viewportDidChange?()
        let readyDeadline = ContinuousClock.now + .milliseconds(250)
        while transition.animatingID == nil, ContinuousClock.now < readyDeadline { await Task.yield() }
        #expect(transition.animatingID == "destination", "The destination starts its zoom once its own viewport commits.")
        transition.finishImmediately()
        #expect(dismissals == 1)
    }

    @Test @MainActor func withdrawnOverviewRequestReleasesCoverageWithoutPresenting() async {
        let controller = ChatOverviewContainer<Text>.Controller(transition: ChatOverviewTransition())
        var dismissals = 0
        controller.update(isPresented: true, content: Text("Overview"), onDismiss: { dismissals += 1 })
        controller.update(isPresented: false, content: Text("Overview"), onDismiss: { dismissals += 1 })
        let deadline = ContinuousClock.now + .seconds(1)
        while dismissals == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(dismissals == 1)
        #expect(controller.presentedViewController == nil)
        controller.tearDown()
        #expect(dismissals == 1, "Teardown cannot release the same coverage twice.")
    }

    @Test @MainActor func overviewPreviewCropsFromTheTopWithoutChangingTheCardRatio() {
        #expect(ChatOverviewTransition.croppedViewportBounds(viewportSize: CGSize(width: 200, height: 400),
            filling: CGSize(width: 400, height: 400)) == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(ChatOverviewTransition.croppedViewportBounds(viewportSize: CGSize(width: 400, height: 200),
            filling: CGSize(width: 400, height: 400)) == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(ChatOverviewTransition.croppedViewportBounds(viewportSize: CGSize(width: 400, height: 800),
            filling: CGSize(width: 200, height: 280)) == CGRect(x: 0, y: 0, width: 400, height: 560))
        #expect(ChatOverviewTransition.croppedViewportBounds(viewportSize: .zero,
            filling: CGSize(width: 100, height: 100)) == nil)
    }

    @Test @MainActor func viewportPreviewsRespectAppearanceRetirementAndMemoryBounds() {
        let cache = ChatTabPreviews()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 560), format: format).image { drawing in
            UIColor.red.setFill(); drawing.fill(CGRect(x: 0, y: 0, width: 300, height: 560))
        }
        cache.capture(image, id: "current", colorScheme: .light, textSize: .large)
        #expect(cache.image(for: "current", colorScheme: .light, textSize: .large) === image)
        #expect(cache.image(for: "current", colorScheme: .dark, textSize: .large) == nil)
        #expect(cache.image(for: "current", colorScheme: .light, textSize: .accessibility5) == nil)
        #expect(cache.image(for: "other", colorScheme: .light, textSize: .large) == nil)
        for index in 0..<30 {
            cache.capture(image, id: "chat-\(index)", colorScheme: .light, textSize: .large)
        }
        #expect(cache.image(for: "current", colorScheme: .light, textSize: .large) == nil)
        #expect(cache.image(for: "chat-29", colorScheme: .light, textSize: .large) === image)
        cache.removeAll()
        #expect(cache.image(for: "chat-29", colorScheme: .light, textSize: .large) == nil)
    }

    @Test func unobservedActivityDoesNotAnnounceAFailure() {
        let item = ChatPickerItem(id: "saved", title: "Saved notes")
        #expect(item.statusLabel == nil)
        #expect(item.accessibilityLabel == "Saved notes")
    }

    @Test func historicalActivityStaysDistinctFromLiveAttentionAndRetainsItsCheckTime() {
        let observation = ActivityObservation(status: .waiting, observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let historical = ChatPickerItem(id: "saved", title: "Saved notes",
                                        activity: .historical(observation))
        let failedRefresh = ChatPickerItem(id: "failed", title: "Other notes",
                                           activity: .unavailable(lastKnown: observation))
        let unavailable = ChatPickerItem(id: "unknown", title: "New notes", activity: .unavailable(lastKnown: nil))
        #expect(historical.statusLabel == "Previously waiting" && historical.status == nil)
        #expect(historical.accessibilityLabel.contains("Previously waiting, last checked"))
        #expect(!historical.accessibilityLabel.contains("Needs you"))
        #expect(failedRefresh.statusLabel == "Previously waiting" && failedRefresh.status == nil)
        #expect(unavailable.statusLabel == "Activity unavailable")
        let idle = ActivityObservation(status: .idle, observedAt: observation.observedAt)
        #expect(ChatPickerItem(id: "idle", title: "Quiet", activity: .historical(idle)).statusLabel == nil)
    }

    @Test func searchFindsDisplayedMainTitleAndBothConversationExcerpts() {
        let items = [
            ChatPickerItem(id: "canonical", title: "Bot Chat", userPreview: "Plan a launch", isMain: true),
            ChatPickerItem(id: "research", title: "Research", replyPreview: "The café opens at eight."),
            ChatPickerItem(id: "travel", title: "Weekend", userPreview: "Take the train")
        ]

        #expect(items.filter { $0.matches(search: "main") }.map(\.id) == ["canonical"])
        #expect(items.filter { $0.matches(search: "LAUNCH") }.map(\.id) == ["canonical"])
        #expect(items.filter { $0.matches(search: "cafe") }.map(\.id) == ["research"])
        #expect(items.filter { $0.matches(search: "weekend") }.map(\.id) == ["travel"])
        #expect(items.filter { $0.matches(search: " \n ") }.map(\.id) == ["canonical", "research", "travel"])
        #expect(items.filter { $0.matches(search: "unrelated") }.isEmpty)
        #expect(items[0].displayTitle == "Main")
        #expect(items[0].title == "Bot Chat")
    }

    @Test func accessibilityDistinguishesChatStateWhileOfflineActivityStaysQuiet() {
        let main = ChatPickerItem(id: "canonical", title: "Bot Chat", isMain: true,
                                  isSelected: true, isPreferred: true, isUnread: true, activity: .current(.waiting))
        let offline = ChatPickerItem(id: "saved", title: "Saved notes")
        let unavailable = ChatPickerItem(id: "missing", title: "Other notes", isAvailable: false)
        let working = ChatPickerItem(id: "active", title: "Research", activity: .current(.working))

        #expect(main.accessibilityLabel == "Main, Current chat, Opens by default, Unread, Needs you")
        #expect(main.preferredActionTitle == "Use last opened chat")
        #expect(offline.accessibilityLabel == "Saved notes")
        #expect(offline.isAvailable)
        #expect(offline.preferredActionTitle == "Open by default")
        #expect(unavailable.accessibilityLabel == "Other notes, Unavailable")
        #expect(working.accessibilityLabel == "Research, Working")
    }
}

private struct PickerFrameProbe: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ view: UIView, context: Context) {}
}
