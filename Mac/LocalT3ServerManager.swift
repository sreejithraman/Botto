import Darwin
import Foundation
import Observation

struct T3PairingOutput {
    private(set) var pairingURL: String?
    private(set) var appLink: String?

    @discardableResult
    mutating func consume(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = line.removingPrefix("Pairing URL:") {
            pairingURL = value.trimmingCharacters(in: .whitespaces)
        } else if let value = line.removingPrefix("App link:") {
            appLink = value.trimmingCharacters(in: .whitespaces)
        } else {
            return false
        }
        return true
    }
}

enum T3RouteFormatter {
    static func pairingURL(from rawPairingURL: String, routeOrigin: URL) -> String? {
        guard var pairing = URLComponents(string: rawPairingURL),
              hasWebAuthority(pairing),
              let fragment = pairing.percentEncodedFragment else { return nil }
        var credential = URLComponents()
        credential.percentEncodedQuery = fragment
        guard credential.queryItems?.contains(where: { $0.name == "token" && $0.value?.isEmpty == false }) == true,
              let route = URLComponents(url: routeOrigin, resolvingAgainstBaseURL: false),
              hasWebAuthority(route), route.percentEncodedPath.isEmpty || route.percentEncodedPath == "/",
              route.query == nil, route.fragment == nil else { return nil }
        pairing.scheme = route.scheme?.lowercased()
        pairing.percentEncodedHost = route.percentEncodedHost
        pairing.port = route.port
        return pairing.string
    }

    private static func hasWebAuthority(_ components: URLComponents) -> Bool {
        let scheme = components.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") &&
            components.host?.isEmpty == false && components.user == nil && components.password == nil &&
            (components.port.map { (1...65535).contains($0) } ?? true)
    }
}

struct T3EngineExecutable {
    enum Source { case settings, bundled, path }

    struct Pin: Decodable {
        struct Runtime: Decodable {
            let name: String
            let version: String
        }

        let version: String
        let commit: String
        let runtime: Runtime
    }

    let url: URL
    let source: Source
    let pin: Pin?

    var logMessage: String {
        switch source {
        case .settings: "T3 engine: Settings override at \(url.path)"
        case .path: "T3 engine: PATH fallback at \(url.path)"
        case .bundled:
            if let pin {
                "T3 engine: bundled v\(pin.version) (\(pin.commit.prefix(12)), \(pin.runtime.name) \(pin.runtime.version))"
            } else {
                "T3 engine: bundled at \(url.path) (pin metadata unavailable)"
            }
        }
    }

    static func resolve(override: String, resources: URL?, searchDirectories: [String]) throws -> Self {
        let custom = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw T3LocalError.invalidExecutable }
            let executable = URL(fileURLWithPath: path)
            guard isExecutable(executable) else { throw T3LocalError.invalidExecutable }
            return Self(url: executable, source: .settings, pin: nil)
        }
        if let directory = resources?.appending(path: "T3Engine"),
           let executable = find("t3", in: [directory.path]) {
            let pin = (try? Data(contentsOf: directory.appending(path: "pin.json")))
                .flatMap { try? JSONDecoder().decode(Pin.self, from: $0) }
            return Self(url: executable, source: .bundled, pin: pin)
        }
        guard let executable = find("t3", in: searchDirectories) else { throw T3LocalError.executableNotFound }
        return Self(url: executable, source: .path, pin: nil)
    }

    static func find(_ name: String, in directories: [String]) -> URL? {
        directories.lazy.map { URL(fileURLWithPath: $0, isDirectory: true).appending(path: name) }
            .first(where: isExecutable)
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path) &&
            (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

@MainActor @Observable
final class LocalT3ServerManager {
    enum State: Equatable {
        case stopped, starting, running, failed(String)
    }

    let port: Int
    let baseDirectory: URL
    var loopbackOrigin: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private(set) var state: State = .stopped
    var logTail: [String] { (engineLogMessage.map { [$0] } ?? []) + serverLogTail }
    private(set) var startupLinks = T3PairingOutput()
    private(set) var lanOrigin: URL?
    private(set) var tailscaleOrigin: URL?
    var executableOverride: String {
        didSet { defaults.set(executableOverride, forKey: "t3ExecutableOverride") }
    }

    private let defaults: UserDefaults
    private var engineLogMessage: String?
    private var serverLogTail: [String] = []
    private var server: T3Command?
    private var pairingCommand: T3Command?
    private var tailscaleCommand: T3Command?
    private var startupDeadline: Task<Void, Never>?

    init(port: Int = 3774, baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".botto/t3-server", directoryHint: .isDirectory), defaults: UserDefaults = .standard) {
        self.port = port
        self.baseDirectory = baseDirectory
        self.defaults = defaults
        executableOverride = defaults.string(forKey: "t3ExecutableOverride") ?? ""
    }

    func start() {
        guard server == nil else { return }
        engineLogMessage = nil
        serverLogTail.removeAll()
        startupLinks = T3PairingOutput()
        state = .starting
        do {
            #if arch(arm64)
            let resources = Bundle.main.resourceURL
            #else
            let resources: URL? = nil
            #endif
            let engine = try T3EngineExecutable.resolve(
                override: executableOverride, resources: resources, searchDirectories: Self.executableDirectories
            )
            engineLogMessage = engine.logMessage
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let command = try T3Command(executable: engine.url, arguments: [
                "serve", "--port", String(port), "--lan", "--base-dir", baseDirectory.path
            ], directory: baseDirectory)
            server = command
            startupDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.server === command, self.state == .starting else { return }
                self.terminateSync()
                self.state = .failed("T3 did not print a pairing URL within 30 seconds.")
            }
            Task { [weak self] in
                for await line in command.lines {
                    guard let self, self.server === command else { return }
                    self.receiveServerLine(line)
                }
            }
            Task { [weak self] in
                for await status in command.exitCodes {
                    guard let self, self.server === command else { return }
                    self.startupDeadline?.cancel()
                    self.server = nil
                    self.pairingCommand?.stop()
                    command.stop()
                    self.startupLinks = T3PairingOutput()
                    self.state = .failed("T3 exited with status \(status).")
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() { terminateSync() }

    func restart() {
        stop()
        start()
    }

    func terminateSync() {
        startupDeadline?.cancel()
        startupDeadline = nil
        pairingCommand?.stop()
        tailscaleCommand?.stop()
        let running = server
        server = nil
        running?.stop()
        startupLinks = T3PairingOutput()
        state = .stopped
    }

    func mintPairingLink() async throws -> String {
        guard state == .running, let server else { throw T3LocalError.serverStopped }
        guard pairingCommand == nil else { throw T3LocalError.pairingInProgress }
        let command = try T3Command(executable: server.process.executableURL!, arguments: [
            "pair", "--base-dir", baseDirectory.path
        ], directory: baseDirectory)
        pairingCommand = command
        defer { pairingCommand = nil }
        var links = T3PairingOutput()
        let finished = await command.collect(timeout: .seconds(12)) { links.consume($0) }
        try Task.checkCancellation()
        guard self.server === server, state == .running else { throw T3LocalError.serverStopped }
        guard finished, command.process.terminationStatus == 0,
              let url = links.pairingURL, T3RouteFormatter.pairingURL(from: url, routeOrigin: loopbackOrigin) != nil else {
            throw T3LocalError.pairingFailed
        }
        return url
    }

    func refreshRoutes() async {
        let addresses = Self.ipv4Addresses()
        let lan = addresses.filter { $0.interface.hasPrefix("en") && !Self.isTailscaleIP($0.address) }
        lanOrigin = (lan.first { $0.interface == "en0" } ?? lan.first).flatMap { origin(for: $0.address) }
        tailscaleOrigin = addresses.first { Self.isTailscaleIP($0.address) }.flatMap { origin(for: $0.address) }
        guard tailscaleOrigin == nil, tailscaleCommand == nil,
              let executable = T3EngineExecutable.find("tailscale", in: Self.executableDirectories),
              let command = try? T3Command(executable: executable, arguments: ["ip", "-4"]) else { return }
        tailscaleCommand = command
        defer { tailscaleCommand = nil }
        var tailnetAddress: String?
        let finished = await command.collect(timeout: .seconds(4)) { line in
            if Self.isTailscaleIP(line) { tailnetAddress = line }
        }
        if finished, !Task.isCancelled, command.process.terminationStatus == 0 {
            tailscaleOrigin = tailnetAddress.flatMap { origin(for: $0) }
        }
    }

    private func receiveServerLine(_ output: String) {
        let line = output.replacingOccurrences(of: "\\u001B\\[[0-9;]*m", with: "", options: .regularExpression)
        if startupLinks.consume(line) {
            if state == .starting, let raw = startupLinks.pairingURL,
               T3RouteFormatter.pairingURL(from: raw, routeOrigin: loopbackOrigin) != nil {
                state = .running
                startupDeadline?.cancel()
            }
            return
        }
        // CLI output also renders the pairing credential as text and terminal QR art.
        let normalized = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty, !normalized.hasPrefix("token:"), !normalized.hasPrefix("pairing token:"),
              !normalized.hasPrefix("pairing code:"), !normalized.contains("#token="),
              !line.contains(where: { " ▀▄█".dropFirst().contains($0) }) else { return }
        serverLogTail.append(String(line.prefix(1_000)))
        if serverLogTail.count > 100 { serverLogTail.removeFirst() }
    }

    fileprivate static var executableDirectories: [String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") } +
            ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }

    private func origin(for address: String) -> URL? { URL(string: "http://\(address):\(port)") }

    private static func isTailscaleIP(_ address: String) -> Bool {
        var ipv4 = in_addr()
        guard inet_pton(AF_INET, address, &ipv4) == 1 else { return false }
        return UInt32(bigEndian: ipv4.s_addr) & 0xffc0_0000 == 0x6440_0000
    }

    private static func ipv4Addresses() -> [(interface: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        return sequence(first: head, next: { $0.pointee.ifa_next }).compactMap { entry in
            let interface = entry.pointee
            guard let socket = interface.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { return nil }
            var bytes = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &bytes, socklen_t(bytes.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            let address = String(decoding: bytes.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            return (String(cString: interface.ifa_name), address)
        }
    }
}

enum T3LocalError: LocalizedError {
    case executableNotFound, invalidExecutable, serverStopped, pairingInProgress, pairingFailed

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "Couldn’t find the bundled T3 engine or a t3 executable on PATH. Set the T3 executable in Botto Settings."
        case .invalidExecutable: "The t3 path in Botto Settings must point to an executable file."
        case .serverStopped: "Start the local T3 server first."
        case .pairingInProgress: "A pairing link is already being generated. Try again in a moment."
        case .pairingFailed: "T3 couldn’t generate a pairing link. Try again or restart the local server."
        }
    }
}

@MainActor
private final class T3Command {
    let process = Process()
    let lines: AsyncStream<String>
    let exitCodes: AsyncStream<Int32>
    private let output: AsyncStream<String>.Continuation

    init(executable: URL, arguments: [String], directory: URL? = nil) throws {
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LocalT3ServerManager.executableDirectories.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.lines = lines
        output = continuation
        let (exitCodes, reportExit) = AsyncStream.makeStream(of: Int32.self)
        self.exitCodes = exitCodes
        process.terminationHandler = { process in
            reportExit.yield(process.terminationStatus)
            reportExit.finish()
        }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [process] in
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0a) {
                    continuation.yield(String(decoding: pending[..<newline], as: UTF8.self))
                    pending.removeSubrange(...newline)
                }
            }
            if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
            process.waitUntilExit()
            continuation.finish()
        }
    }

    func collect(timeout: Duration, consume: (String) -> Void) async -> Bool {
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            stop()
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            for await line in lines { consume(line) }
            return !process.isRunning
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    func stop() {
        defer { output.finish() }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let target = getpgid(pid) == pid ? -pid : pid
        kill(target, SIGTERM)
        let deadline = ContinuousClock.now + .seconds(1)
        while process.isRunning, ContinuousClock.now < deadline { usleep(20_000) }
        if process.isRunning { kill(target, SIGKILL) }
        process.waitUntilExit()
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
