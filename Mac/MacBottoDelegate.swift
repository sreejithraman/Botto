import AppKit

@MainActor
final class MacBottoDelegate: NSObject, NSApplicationDelegate {
    let server: LocalT3ServerManager
    let store = MacBottoStore()
    private var terminationSignal: DispatchSourceSignal?

    override convenience init() {
        self.init(server: LocalT3ServerManager())
    }

    init(server: LocalT3ServerManager) {
        self.server = server
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.server.terminateSync()
                exit(EXIT_SUCCESS)
            }
        }
        // A caught signal resets on exec, so child processes retain normal SIGTERM behavior.
        signal(SIGTERM, deferSIGTERMToDispatch)
        terminationSignal = source
        source.activate()
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

    func applicationWillTerminate(_ notification: Notification) {
        server.terminateSync()
    }
}

private nonisolated func deferSIGTERMToDispatch(_: Int32) {}
