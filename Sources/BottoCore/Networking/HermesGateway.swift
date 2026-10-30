// Gateway ordering and lifecycle adapted from Hermex. MIT; see LICENSES/Hermex.txt.
import Foundation

@MainActor final class HermesGateway {
    struct Timing {
        var request: Duration = .seconds(30)
        var heartbeat: Duration = .seconds(15)
        var silence: Duration = .seconds(45)
        var reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
    }
    private struct Pending {
        let continuation: CheckedContinuation<HermesJSON, Error>
        let timer: Task<Void, Never>
        let mutation: Bool
    }
    private let http: HermesHTTPConnection
    private let timing: Timing
    private var socket: (any HermesSocket)?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var pending: [Int: Pending] = [:]
    private var nextID = 0
    private var closed = false
    private var lastRead = ContinuousClock.now
    private(set) var replayEpoch: String?
    private(set) var usesAuthority = false
    private(set) var isOpen = false
    var onFrame: ((HermesJSON) -> Void)?
    var onDisconnect: ((HermesServiceError) -> Void)?

    init(http: HermesHTTPConnection, timing: Timing = Timing()) { self.http = http; self.timing = timing }

    func open() async throws {
        let upgrade = try await http.upgrade()
        guard !closed, !Task.isCancelled else { throw HermesServiceError.disconnected }
        let socket = try http.transport.socket(for: upgrade)
        self.socket = socket
        lastRead = .now
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: self?.timing.heartbeat ?? .seconds(15)) } catch { return }
                guard let self, !self.closed else { return }
                if self.lastRead.duration(to: .now) >= self.timing.silence { self.end(.timeout); return }
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                reader = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let bytes = try await socket.receive()
                            guard let self, !self.closed else { return }
                            self.lastRead = .now
                            self.consume(try HermesJSON.decode(bytes))
                        }
                    } catch { self?.end(error as? HermesServiceError ?? .disconnected) }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.end(.disconnected) } }
        // Mandatory first outbound frame: otherwise upstream silently skips some requests.
        _ = try await call("client.capabilities", ["server_requests": .bool(true)])
        guard !closed else { throw HermesServiceError.disconnected }
        isOpen = true
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: self?.timing.heartbeat ?? .seconds(15)) } catch { return }
                guard let self, !self.closed else { return }
                do { _ = try await self.call("gateway.ping", [:]) }
                catch { self.end(.disconnected); return }
            }
        }
    }

    enum TimeoutPolicy { case disconnect, requestOnly }

    func call(_ method: String, _ params: [String: HermesJSON], mutation: Bool = false,
              timeoutPolicy: TimeoutPolicy = .disconnect,
              validate: (() throws -> Void)? = nil) async throws -> HermesJSON {
        guard let socket, !closed, replayEpoch != nil, !Task.isCancelled else { throw HermesServiceError.disconnected }
        nextID += 1
        let id = nextID
        let frame = HermesJSON.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                      "method": .string(method), "params": .object(params)])
        let data: Data
        if method == "file.attach" || method == "image.attach_bytes" { data = try await Task.detached { try frame.data }.value }
        else { data = try frame.data }
        guard !closed, !Task.isCancelled else { throw HermesServiceError.disconnected }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self, timing] in
                    do { try await Task.sleep(for: timing.request) } catch { return }
                    guard let self, self.pending[id] != nil else { return }
                    if timeoutPolicy == .requestOnly, !mutation {
                        self.settle(id, result: .failure(HermesServiceError.timeout))
                    } else { self.end(.timeout) }
                }
                pending[id] = Pending(continuation: continuation, timer: timer, mutation: mutation)
                Task { [weak self] in
                    guard let self, !self.closed, self.pending[id] != nil else { return }
                    do { try validate?() }
                    catch { self.settle(id, result: .failure(error)); return }
                    do { try await socket.send(data) }
                    catch { self.end(.disconnected) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let entry = self.pending[id] else { return }
                if entry.mutation { self.end(.disconnected) }
                else { self.settle(id, result: .failure(CancellationError())) }
            }
        }
    }

    private func consume(_ frame: HermesJSON) {
        guard !closed else { return }
        if ready != nil {
            guard frame["method"].text == "event", frame["params"]["type"].text == "gateway.ready",
                  let epoch = frame["params"]["payload"]["replay_epoch"].nonempty else { end(.incompatible); return }
            replayEpoch = epoch
            usesAuthority = frame["params"]["payload"]["session_authority"].flag == true
            let waiter = ready; ready = nil; waiter?.resume()
            return
        }
        if frame["method"].text == "event" { onFrame?(frame["params"]); return }
        if frame["id"].text != nil, frame["method"].text != nil { onFrame?(frame); return }
        guard let id = frame["id"].integer, pending[id] != nil else { return }
        if let code = frame["error"]["code"].integer {
            let reason = frame["error"]["data"]["reason"].text
            let error: HermesServiceError
            switch reason {
            case "profile_mismatch": error = .profileUnavailable
            case "stale_generation", "revision_conflict": error = .staleGeneration
            default: error = .rejected(code)
            }
            settle(id, result: .failure(error))
        }
        else if frame.fields?["result"] != nil { settle(id, result: .success(frame["result"])) }
        else { settle(id, result: .failure(HermesServiceError.incompatible)) }
    }

    private func settle(_ id: Int, result: Result<HermesJSON, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel(); entry.continuation.resume(with: result)
    }

    func close() { onDisconnect = nil; end(.disconnected) }

    private func end(_ reason: HermesServiceError) {
        guard !closed else { return }
        closed = true; isOpen = false
        reader?.cancel(); reader = nil
        heartbeat?.cancel(); heartbeat = nil
        watchdog?.cancel(); watchdog = nil
        socket?.close(); socket = nil
        let waiter = ready; ready = nil; waiter?.resume(throwing: reason)
        let entries = pending; pending = [:]
        for entry in entries.values {
            entry.timer.cancel()
            entry.continuation.resume(throwing: entry.mutation ? HermesServiceError.uncertain : reason)
        }
        onDisconnect?(reason)
    }
}
