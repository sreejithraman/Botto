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

/// Choose storage before AppStore initializes and loads its saved setup.
@MainActor func makeWorkspaceStore(arguments: [String] = ProcessInfo.processInfo.arguments,
                                  persistence: ConnectionPersistence? = nil) -> AppStore {
    #if targetEnvironment(simulator)
    if arguments.contains("--isolated-ui-test") {
        return AppStore(persistence: .init(load: { nil }, save: { _ in }, remove: {}))
    }
    #endif
    return AppStore(persistence: persistence)
}

private struct BottoWorkspace: View {
    @State private var store = makeWorkspaceStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView(store: store)
            #if DEBUG
            .environment(\.scenePhase, ProcessInfo.processInfo.arguments.contains("--inactive-root-scene") ? .inactive : scenePhase)
            #endif
            .task { [store] in
                PushNotificationBridge.onToken = { [weak store] token in
                    Task { [weak store] in
                        guard let store else { return }
                        await store.push.didRegister(token: token)
                        await store.t3Push.didRegister(token: token, scope: store.t3PushScope)
                    }
                }
                PushNotificationBridge.shouldPresent = { [weak store] envelope in
                    store?.shouldPresentPush(envelope) ?? false
                }
                PushNotificationBridge.onTap = { [weak store] envelope in
                    guard let store, store.admitPushNotification(envelope) else { return }
                    Task { await store.resumePushNavigation() }
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
