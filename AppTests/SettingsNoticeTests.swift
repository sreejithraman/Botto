import SwiftUI
import Testing
import UIKit
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct SettingsNoticeTests {
    @Test(arguments: [false, true])
    func failedForgetKeepsTheConnectionAndShowsItsErrorInSettings(largeText: Bool) async throws {
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://settings-notice.invalid")!)
        let store = AppStore(service: try WorkspaceTestService(),
            persistence: .init(load: { configuration }, save: { _ in }, remove: { throw RemovalFailure() }),
            push: PushCoordinator(persistence: .init(load: { .init() }, save: { _ in })))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: SettingsView(store: store, onConnection: {})
            .dynamicTypeSize(largeText ? .accessibility5 : .large))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while (collection(in: host.view)?.numberOfSections ?? 0) == 0,
              ContinuousClock.now < deadline { await Task.yield() }
        let form = try #require(collection(in: host.view))
        let section = try #require((0..<form.numberOfSections).last { form.numberOfItems(inSection: $0) > 0 })
        let action = IndexPath(item: form.numberOfItems(inSection: section) - 1, section: section)
        form.scrollToItem(at: action, at: .top, animated: false)
        _ = try await visibleElement("Forget this connection", in: window)
        await store.forgetConnectionWithPush()

        let failureDeadline = ContinuousClock.now + .seconds(5)
        while store.notice == nil, ContinuousClock.now < failureDeadline { await Task.yield() }
        #expect(store.configuration == configuration)
        let notice = try #require(store.notice)
        let error = try await visibleElement(notice, in: window)
        #expect(window.frame.contains(error.accessibilityFrame), "The complete error must stay inside the viewport after the scrolled Forget action.")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image {
            _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        Attachment.record(image, named: largeText ? "Failed Forget at largest text" : "Failed Forget after scrolling", as: .png)
    }

    private func collection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        return view.subviews.lazy.compactMap { collection(in: $0) }.first
    }

    private func visibleElement(_ label: String, in window: UIWindow) async throws -> NSObject {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let found = element(label, in: window), found.accessibilityFrame.intersects(window.frame) { return found }
            await Task.yield()
        }
        let diagnostic = UIGraphicsImageRenderer(bounds: window.bounds).image {
            _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        Attachment.record(diagnostic, named: "Settings missing \(label)", as: .png)
        let found = try #require(element(label, in: window), "Missing Settings action or feedback: \(label)")
        try #require(found.accessibilityFrame.intersects(window.frame), "Settings element is offscreen: \(label)")
        return found
    }

    private func element(_ label: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 30, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if let view = object as? UIView, view.isHidden || view.alpha == 0 || (!(view is UIWindow) && view.window == nil) { return nil }
            if object.accessibilityLabel == label { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let found = find(child, depth: depth + 1) { return found } }
            }
            let count = object.accessibilityElementCount()
            if count > 0, count < 1_000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let found = find(child, depth: depth + 1) { return found }
                }
            }
            return nil
        }
        return find(root, depth: 0)
    }

    private struct RemovalFailure: LocalizedError {
        var errorDescription: String? { "Secure storage could not remove the saved setup." }
    }
}
