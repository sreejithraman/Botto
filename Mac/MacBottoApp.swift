import AppKit
import SwiftUI

enum MacWindowID {
    static let main = "botto"
    static let pairPhone = "pair-phone"
    static let serverLog = "server-log"
}

@main
struct MacBottoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: MacBottoDelegate
    @State private var store = MacBottoStore()

    var body: some Scene {
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
            MacEngineMenu(server: delegate.server, showsOpenWindow: true)
        } label: {
            Image(systemName: delegate.server.state == .running ? "face.smiling" : "moon.zzz")
                .accessibilityLabel("Botto")
        }

        Settings {
            MacEngineSettings(server: delegate.server)
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
                .disabled(!store.isConnected)
        }
        CommandGroup(after: .sidebar) {
            Button(store.showsInspector ? "Hide Botto" : "Show Botto") { store.showsInspector.toggle() }
                .keyboardShortcut("i")
                .disabled(!store.isConnected)
        }
        CommandMenu("Engine") {
            MacEngineMenu(server: server, showsOpenWindow: false)
        }
    }
}

/// The same engine items for the app menu and the menu bar extra.
struct MacEngineMenu: View {
    let server: LocalT3ServerManager
    let showsOpenWindow: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(status)
        Divider()
        switch server.state {
        case .stopped, .failed:
            Button("Wake Botto") { server.start() }
        case .starting, .running:
            Button("Put Botto to Sleep") { server.stop() }
        }
        Button("Restart Engine") { server.restart() }
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
final class MacBottoDelegate: NSObject, NSApplicationDelegate {
    let server = LocalT3ServerManager()

    func applicationWillTerminate(_ notification: Notification) {
        server.terminateSync()
    }
}

private struct MacEngineSettings: View {
    @Bindable var server: LocalT3ServerManager

    var body: some View {
        Form {
            TextField("T3 executable", text: $server.executableOverride, prompt: Text("Find automatically"))
            LabeledContent("Server port", value: String(server.port))
            LabeledContent("Server data", value: server.baseDirectory.path)
                .textSelection(.enabled)
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460)
    }
}
