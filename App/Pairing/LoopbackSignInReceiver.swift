// Loopback broker adapted from Hermex, Copyright (c) 2026 Uzair Ansar (MIT).
// See LICENSES/Hermex.txt. Botto adds strict callbacks and bounded socket lifetimes.
import Foundation
import BottoCore
import Network

@MainActor final class LoopbackSignInReceiver {
    private(set) var code: String?
    private let state: String
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, any Error>?
    private var port: UInt16?
    private var connections: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    init(state: String) { self.state = state }

    func start() async throws -> UInt16 {
        guard !stopped, listener == nil else { throw BrowserSignIn.Failure.unavailable }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw BrowserSignIn.Failure.unavailable }
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
        let continuation = startup
        startup = nil
        continuation?.resume(throwing: CancellationError())
        for id in Array(connections.keys) { close(id) }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let value = listener?.port?.rawValue else { return }
            port = value
            let continuation = startup
            startup = nil
            continuation?.resume(returning: value)
        case .failed:
            let continuation = startup
            startup = nil
            continuation?.resume(throwing: BrowserSignIn.Failure.unavailable)
            stop()
        case .cancelled:
            let continuation = startup
            startup = nil
            continuation?.resume(throwing: CancellationError())
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, code == nil, connections.count < 4 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        deadlines[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            self?.close(id)
        }
        connection.start(queue: .main)
        receive(id, buffered: Data())
    }

    private func receive(_ id: UUID, buffered: Data) {
        guard let connection = connections[id] else { return }
        let remaining = NativeSignInCallback.maximumRequestBytes - buffered.count
        guard remaining > 0 else { close(id); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                let buffer = buffered + (data ?? Data())
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(id, request: buffer)
                } else if complete || error != nil || buffer.count >= NativeSignInCallback.maximumRequestBytes {
                    self.close(id)
                } else { self.receive(id, buffered: buffer) }
            }
        }
    }

    private func handle(_ id: UUID, request: Data) {
        guard let port, code == nil,
              let value = try? NativeSignInCallback.code(in: request, expectedState: state, port: port)
        else {
            respond(id, status: "400 Bad Request", location: nil)
            return
        }
        code = value
        listener?.cancel()
        for other in Array(connections.keys) where other != id { close(other) }
        respond(id, status: "302 Found", location: "botto-signin://done")
    }

    private func respond(_ id: UUID, status: String, location: String?) {
        guard let connection = connections[id] else { return }
        let destination = location.map { "Location: \($0)\r\n" } ?? ""
        let response = "HTTP/1.1 \(status)\r\n\(destination)Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        deadlines.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}
