import SwiftUI
import BottoCore

struct RootView: View {
    @Bindable var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentation = WorkspacePresentation()
    @AppStorage("botto.appearance") private var appearance = "system"
    private var preferredAppearance: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
    private enum Sheet: Equatable { case connection, settings, newBot }
    @State private var sheet: Sheet?
    private var showsSheet: Binding<Bool> {
        let renderedSheet = sheet
        return Binding(get: { sheet != nil }, set: { shown in
            guard !shown, sheet == renderedSheet else { return }
            sheet = nil
            if renderedSheet == .connection {
                store.showsConnection = false
                store.pendingConnectionInput = nil
            }
        })
    }
    private func presentSheet(_ destination: Sheet) {
        if let bot = store.selectedBot, let profile = try? ExactID(bot.id),
           let screen = store.chats.screen(profile: profile) {
            store.chats.setTranscriptVisible(false, owner: screen.owner)
        }
        sheet = destination
    }

    var body: some View {
        Group {
            if store.configuration == nil {
                OnboardingView(store: store)
            } else {
                WorkspaceTabs(store: store, presentation: presentation,
                              rootCovered: sheet != nil || store.showsConnection,
                              onSettings: { presentSheet(.settings) },
                              onNewBot: { presentSheet(.newBot) })
            }
        }
        .tint(BottoTheme.action)
        .background(BottoTheme.paper.ignoresSafeArea())
        .sheet(isPresented: showsSheet) {
            Group {
                switch sheet {
                case .connection:
                    ConnectionView(store: store, input: store.pendingConnectionInput ?? "")
                case .settings:
                    SettingsView(store: store, onConnection: { store.showsConnection = true })
                case .newBot:
                    NewBotView(store: store)
                case nil:
                    EmptyView()
                }
            }
            .preferredColorScheme(preferredAppearance)
        }
        .preferredColorScheme(preferredAppearance)
        .onChange(of: store.showsConnection, initial: true) { _, shown in
            if shown { presentSheet(.connection) }
            else if sheet == .connection { sheet = nil }
        }
        .onChange(of: store.pendingConnectionInput, initial: true) { _, value in
            if value != nil { store.showsConnection = true }
        }
        .onChange(of: store.artifactGeneration) { _, _ in presentation.reconcile(store: store) }
        .onChange(of: store.notificationNavigationRevision) { _, _ in
            sheet = nil
            presentation.didChooseConversation()
        }
        .onChange(of: store.selectedBotID) { _, _ in presentation.reconcile(store: store) }
        .onChange(of: ObjectIdentifier(store.chats)) { _, _ in presentation.reconcile(store: store) }
        .onChange(of: scenePhase) { _, _ in presentation.reconcile(store: store) }
        #if DEBUG
        .modifier(AvatarMotionTestOverride())
        #endif
    }
}

#if DEBUG
/// Native UI verification can force the same environment value as the system setting.
private struct AvatarMotionTestOverride: ViewModifier {
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.arguments.contains("--reduce-motion") {
            content.environment(\.avatarMotionDisabledForTesting, true)
        } else { content }
    }
}
#endif
