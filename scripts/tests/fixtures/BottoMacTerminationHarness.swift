import AppKit

@main
struct BottoMacTerminationHarness {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        let defaults = UserDefaults.standard
        defaults.setVolatileDomain(
            ["t3ExecutableOverride": arguments.dropFirst(4).first ?? ""],
            forName: UserDefaults.argumentDomain
        )
        let server = LocalT3ServerManager(
            port: Int(arguments[1])!,
            baseDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true),
            defaults: defaults
        )
        let delegate = MacEngineLifecycle(server: server)
        let failureMarker = URL(fileURLWithPath: arguments[3]).deletingLastPathComponent()
            .appending(path: "startup-failure")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.delegate = delegate
        DispatchQueue.main.async {
            server.start()
            Task { @MainActor in
                while !FileManager.default.fileExists(atPath: arguments[3]) {
                    if case .failed(let reason) = server.state {
                        try? Data(reason.utf8).write(to: failureMarker)
                        exit(EXIT_FAILURE)
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                app.terminate(nil)
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
