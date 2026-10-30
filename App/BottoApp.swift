import SwiftUI

@main struct BottoApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationBridge.self) private var pushBridge
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--developer-menu") {
                DeveloperLaunchView()
            } else if ProcessInfo.processInfo.arguments.contains("--bot-motion-lab") {
                BotMotionPrototype()
            } else {
                BottoWorkspace()
            }
            #else
            BottoWorkspace()
            #endif
        }
    }

}

#if DEBUG
private struct DeveloperLaunchView: View {
    @State private var showsApp = false

    var body: some View {
        if showsApp {
            BottoWorkspace()
        } else {
            NavigationStack {
                DeveloperMenuView(onBackToApp: { showsApp = true })
            }
            .tint(BottoTheme.action)
        }
    }
}
#endif

private struct BottoWorkspace: View {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView(store: store)
            .task {
                PushNotificationBridge.onToken = { [weak store] token in
                    Task { await store?.push.didRegister(token: token) }
                }
                PushNotificationBridge.shouldPresent = { [weak store] envelope in
                    store?.push.shouldPresent(envelope) ?? false
                }
                PushNotificationBridge.onTap = { [weak store] envelope in
                    Task { await store?.openPushNotification(envelope) }
                }
                await store.start()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { Task { await store.setActive(false) } }
                else if phase == .active { Task { await store.setActive(true) } }
            }
            .onOpenURL { url in
                guard url.scheme == "botto" else { return }
                store.pendingConnectionInput = url.absoluteString
                store.showsConnection = true
            }
    }
}
