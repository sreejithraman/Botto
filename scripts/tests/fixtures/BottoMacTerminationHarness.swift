import AppKit

@main
struct BottoMacTerminationHarness {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        let server = LocalT3ServerManager(
            port: Int(arguments[1])!,
            baseDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true)
        )
        let delegate = MacBottoDelegate(server: server)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.delegate = delegate
        DispatchQueue.main.async {
            server.start()
            Task { @MainActor in
                while !FileManager.default.fileExists(atPath: arguments[3]) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                app.terminate(nil)
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
