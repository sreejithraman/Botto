import AppKit
import BottoCore
import SwiftUI

enum MacWindowID {
    static let main = "botto"
    static let pairPhone = "pair-phone"
    static let serverLog = "server-log"
}

@main
struct MacBottoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: MacBottoDelegate

    var body: some Scene {
        let store = delegate.store
        Window("Botto", id: MacWindowID.main) {
            MacRootView(server: delegate.server, store: store)
                .frame(minWidth: 680, minHeight: 480)
        }
        .defaultSize(width: 1040, height: 700)
        .commands { MacBottoCommands(server: delegate.server, store: store) }

        Window("Pair Phone", id: MacWindowID.pairPhone) {
            MacPairPhoneSheet(server: delegate.server)
        }
        .windowResizability(.contentSize)

        Window("Server Log", id: MacWindowID.serverLog) {
            MacServerLogView(server: delegate.server)
        }
        .defaultSize(width: 720, height: 460)

        MenuBarExtra {
            MacEngineMenu(server: delegate.server, store: store, showsOpenWindow: true)
        } label: {
            Image(systemName: delegate.server.state == .running ? "face.smiling" : "moon.zzz")
                .accessibilityLabel("Botto")
        }

        Settings {
            MacEngineSettings(server: delegate.server, delegate: delegate)
        }
    }
}

/// Engine and pairing controls live in the menus, not the window.
private struct MacBottoCommands: Commands {
    let server: LocalT3ServerManager
    let store: MacBottoStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Space") { store.showFreshPage() }
                .keyboardShortcut("n")
                .disabled(!store.canStartSpace)
        }
        CommandGroup(after: .sidebar) {
            Button(store.showsInspector ? "Hide Botto" : "Show Botto") { store.showsInspector.toggle() }
                .keyboardShortcut("i")
                .disabled(!store.isConnected)
        }
        CommandMenu("Engine") {
            MacEngineMenu(server: server, store: store, showsOpenWindow: false)
        }
    }
}

/// The same engine items for the app menu and the menu bar extra.
struct MacEngineMenu: View {
    let server: LocalT3ServerManager
    let store: MacBottoStore
    let showsOpenWindow: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(status)
        Divider()
        switch server.state {
        case .stopped, .failed:
            Button("Wake Botto") { server.start() }
        case .starting, .running:
            Button("Put Botto to Sleep") { Task { await store.flushProse(); server.stop() } }
        }
        Button("Restart Engine") { Task { await store.flushProse(); server.restart() } }
            .disabled(server.state == .stopped)
        Divider()
        Button("Pair Phone…") { openWindow(id: MacWindowID.pairPhone) }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        Button("View Server Log") { openWindow(id: MacWindowID.serverLog) }
        if showsOpenWindow {
            Divider()
            Button("Open Botto") {
                openWindow(id: MacWindowID.main)
                NSApp.activate()
            }
            Button("Quit Botto") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private var status: String {
        switch server.state {
        case .running: "Botto is awake"
        case .starting: "Botto is waking up…"
        case .stopped: "Botto is asleep"
        case .failed: "Botto couldn’t wake up"
        }
    }
}

@MainActor
final class MacBottoDelegate: MacEngineLifecycle {
    let store = MacBottoStore()
    private(set) var pushListener: T3PushListener?
    private(set) var pushBridge: T3PushBridge?
    private(set) var pushSetupFailed = false
    private var pushEvents: AsyncStream<T3PushActivity>.Continuation?
    private var connectionTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let configuredOrigin = UserDefaults.standard.string(forKey: "T3PushRelayURL"), !configuredOrigin.isEmpty {
            do {
                guard let origin = URL(string: configuredOrigin) else { throw T3PushRegistrationError.relayUnavailable }
                let file = FileManager.default.homeDirectoryForCurrentUser.appending(
                    path: ".botto/t3-push/bridge.json")
                let bridge = try T3PushBridge(relay: origin, file: file)
                pushListener = try T3PushListener(bridge: bridge, port: 3775)
                pushBridge = bridge
                let (activities, events) = AsyncStream<T3PushActivity>.makeStream(bufferingPolicy: .bufferingNewest(256))
                pushEvents = events
                store.observePush { events.yield($0) }
                store.onPushScope = { scope in Task { await bridge.setScope(scope) } }
                Task { for await activity in activities { await bridge.publish(activity) } }
            } catch {
                pushSetupFailed = true
            }
        }
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            self.connectionTask?.cancel()
            if state == .running {
                self.connectionTask = Task { await self.store.connect(to: self.server) }
            } else {
                self.store.disconnect()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.hasUnsavedProse else { return .terminateNow }
        Task {
            await store.flushProse()
            guard store.hasUnsavedProse else { sender.reply(toApplicationShouldTerminate: true); return }
            let alert = NSAlert()
            alert.messageText = "Botto couldn’t save your changes."
            alert.informativeText = "Keep Botto open to retry or copy the unsaved text."
            alert.addButton(withTitle: "Keep Botto Open")
            alert.addButton(withTitle: "Quit Without Saving")
            sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
        }
        return .terminateLater
    }

    override func applicationWillTerminate(_ notification: Notification) {
        pushEvents?.finish()
        pushListener?.stop()
        super.applicationWillTerminate(notification)
    }
}

private struct MacEngineSettings: View {
    @Bindable var server: LocalT3ServerManager
    let delegate: MacBottoDelegate
    @State private var pushNotice: String?

    var body: some View {
        Form {
            TextField("T3 executable", text: $server.executableOverride, prompt: Text("Find automatically"))
            LabeledContent("Server port", value: String(server.port))
            LabeledContent("Server data", value: server.baseDirectory.path)
                .textSelection(.enabled)
            Section("Phone notifications") {
                if delegate.pushSetupFailed {
                    Text("Check the relay configuration and restart Botto.")
                } else if delegate.pushBridge == nil {
                    Text("Set up a Botto push relay to enable phone notifications.")
                } else {
                    Button("Copy LAN Notification Code") { copyPushCode(host: server.lanOrigin?.host) }
                        .disabled(!delegate.store.isConnected || server.lanOrigin == nil)
                    if let host = server.tailscaleOrigin?.host {
                        Button("Copy Tailscale Notification Code") { copyPushCode(host: host) }
                            .disabled(!delegate.store.isConnected)
                    }
                    if let pushNotice { Text(pushNotice).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460)
        .task { await server.refreshRoutes() }
    }

    private func copyPushCode(host: String?) {
        guard let host, let port = delegate.pushListener?.port, let bridge = delegate.pushBridge,
              let scope = delegate.store.pushScope else {
            pushNotice = "Wake Botto and check your Mac’s network connection."
            return
        }
        Task {
            do {
                let invitation = try await bridge.makeInvitation(host: host, port: port, scope: scope)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(try invitation.code(), forType: .string)
                pushNotice = "Code copied. Paste it in Notifications on your phone within five minutes."
            } catch {
                pushNotice = error.localizedDescription
            }
        }
    }
}
