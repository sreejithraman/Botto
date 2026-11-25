import AppKit

@MainActor
class MacEngineLifecycle: NSObject, NSApplicationDelegate {
    let server: LocalT3ServerManager
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

    func applicationWillTerminate(_ notification: Notification) {
        server.terminateSync()
    }
}

private nonisolated func deferSIGTERMToDispatch(_: Int32) {}
