import SwiftUI
import BottoCore

struct RootView: View {
    @Bindable var store: AppStore
    /// Embedded previews cannot pair a host; leaving returns to their owner.
    var onExitDemoPreview: (() -> Void)? = nil
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
    @State private var createdBotOpening: AppStore.BotOpening?
    @State private var deliberateSheet = false
    @State private var notificationPresentation: AppStore.NotificationPresentation?
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
    private func presentSheet(_ destination: Sheet, deliberate: Bool = true) {
        createdBotOpening = nil
        if deliberate { store.retireHeldNotification() }
        if destination == .connection, onExitDemoPreview != nil {
            store.showsConnection = false
            store.pendingConnectionInput = nil
            return
        }
        if let bot = store.selectedBot, let profile = try? ExactID(bot.id),
           let screen = store.chats.screen(profile: profile) {
            store.chats.setTranscriptVisible(false, owner: screen.owner)
        }
        deliberateSheet = deliberate
        sheet = destination
    }

    private func createdBot(_ creation: AppStore.BotCreationResult) {
        guard sheet == .newBot else { return }
        let opening = store.prepareCreatedBotOpening(creation)
        guard sheet == .newBot, !store.showsConnection else { return }
        createdBotOpening = opening
        sheet = nil
        store.notice = "Your bot was created."
    }

    private func sheetDidDismiss() {
        guard let opening = createdBotOpening else { return }
        createdBotOpening = nil
        guard mayOpenCreatedBot(opening) else { return }
        presentation.didChooseConversation()
        Task { @MainActor in
            guard mayOpenCreatedBot(opening) else { return }
            await store.openBot(opening)
        }
    }

    private func mayOpenCreatedBot(_ opening: AppStore.BotOpening) -> Bool {
        sheet == nil && store.canOpenBot(opening)
    }

    var body: some View {
        Group {
            if store.configuration == nil {
                if let onExitDemoPreview {
                    Color.clear.onAppear(perform: onExitDemoPreview)
                } else {
                    OnboardingView(store: store)
                }
            } else {
                WorkspaceTabs(store: store, presentation: presentation,
                              rootCovered: sheet != nil || createdBotOpening != nil || store.showsConnection,
                              onSettings: { presentSheet(.settings) },
                              onNewBot: { presentSheet(.newBot) })
            }
        }
        // Captures only what it settles: holding `self` would keep this receipt alive through its own state.
        .onAppear {
            notificationPresentation = store.bindNotificationPresentation {
                [presentation, sheet = $sheet, createdBotOpening = $createdBotOpening] in
                createdBotOpening.wrappedValue = nil
                sheet.wrappedValue = nil
                presentation.didChooseConversation()
            }
        }
        .tint(BottoTheme.action)
        .background(BottoTheme.paper.ignoresSafeArea())
        .sheet(isPresented: showsSheet, onDismiss: sheetDidDismiss) {
            Group {
                switch sheet {
                case .connection:
                    if onExitDemoPreview == nil {
                        ConnectionView(store: store, input: store.pendingConnectionInput ?? "")
                    }
                case .settings:
                    SettingsView(store: store, onConnection: {
                        presentSheet(.connection)
                        store.showsConnection = true
                    }, onLeaveDemo: onExitDemoPreview)
                case .newBot:
                    NewBotView(store: store, onCreated: createdBot)
                case nil:
                    EmptyView()
                }
            }
            .preferredColorScheme(preferredAppearance)
            .hapticSheet(enabled: deliberateSheet)
        }
        .preferredColorScheme(preferredAppearance)
        .onChange(of: store.showsConnection, initial: true) { _, shown in
            if shown {
                createdBotOpening = nil
                if sheet != .connection { presentSheet(.connection, deliberate: false) }
            }
            else if sheet == .connection { sheet = nil }
        }
        .onChange(of: store.pendingConnectionInput, initial: true) { _, value in
            if value != nil { createdBotOpening = nil; store.showsConnection = true }
        }
        .onChange(of: store.artifactGeneration) { _, _ in presentation.reconcile(store: store) }
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
