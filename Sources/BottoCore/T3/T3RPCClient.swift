import Foundation

public protocol T3WebSocketTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

nonisolated public final class T3URLSessionWebSocketTransport: T3WebSocketTransport {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask

    public init(request: URLRequest) {
        session = URLSession(configuration: .ephemeral, delegate: T3RejectRedirects(), delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 32 * 1024 * 1024
        socket.resume()
    }

    deinit {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    public func send(_ data: Data) async throws {
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func receive() async throws -> Data {
        switch try await socket.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw T3RPCError.invalidFrame
        }
    }

    public func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

public enum T3RPCError: Error, Equatable, LocalizedError, Sendable {
    case invalidFrame, closed, timeout, interrupted
    case remote(tag: String, message: String)
    case defect(String)
    case transport

    public var errorDescription: String? {
        switch self {
        case .invalidFrame: "T3 Code returned an invalid RPC frame."
        case .closed: "The T3 Code connection is closed."
        case .timeout: "T3 Code took too long to respond."
        case .interrupted: "T3 Code interrupted the request."
        case .remote(_, let message), .defect(let message): message
        case .transport: "The T3 Code WebSocket failed."
        }
    }
}

actor T3RPCClient {
    typealias Stream = AsyncThrowingStream<JSONValue, Error>
    static let orchestrationProtocol = "2"

    private struct Pending {
        let continuation: Stream.Continuation
        let isStream: Bool
        let timeout: Task<Void, Never>?
    }

    private let transport: any T3WebSocketTransport
    private let heartbeatInterval: Duration
    private let pongTimeout: Duration
    private let requestTimeout: Duration
    private var pending: [String: Pending] = [:]
    private var nextID = 0
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var awaitingPong = false
    private var failure: T3RPCError?

    init(transport: any T3WebSocketTransport, heartbeatInterval: Duration = .seconds(15),
         pongTimeout: Duration = .seconds(15), requestTimeout: Duration = .seconds(30)) {
        self.transport = transport
        self.heartbeatInterval = heartbeatInterval
        self.pongTimeout = pongTimeout
        self.requestTimeout = requestTimeout
    }

    deinit {
        receiver?.cancel()
        heartbeat?.cancel()
        for request in pending.values {
            request.timeout?.cancel()
            request.continuation.finish(throwing: T3RPCError.closed)
        }
    }

    static func socketRequest(origin: URL, ticket: String?, accessToken: String) throws -> URLRequest {
        let origin = try T3PairingExchange.validatedOrigin(origin.absoluteString)
        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw T3PairingError.invalidOrigin
        }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path = "/ws"
        parts.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: orchestrationProtocol)]
        if let ticket { parts.queryItems?.append(URLQueryItem(name: "wsTicket", value: ticket)) }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw T3PairingError.invalidOrigin }
        var request = URLRequest(url: url)
        if ticket == nil { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        return request
    }

    func call(_ method: String, payload: JSONValue = .object([:]), firstStreamValue: Bool = false) async throws -> JSONValue {
        let (id, stream) = try await request(method, payload: payload, isStream: firstStreamValue, timed: true)
        var iterator = stream.makeAsyncIterator()
        if let result = try await iterator.next() {
            if firstStreamValue { interrupt(id) }
            return result
        }
        try Task.checkCancellation()
        throw T3RPCError.invalidFrame
    }

    func subscribe(_ method: String, payload: JSONValue = .object([:])) async throws -> Stream {
        try await request(method, payload: payload, isStream: true, timed: false).stream
    }

    func close() async { await terminate(with: .closed) }

    private func request(_ method: String, payload: JSONValue, isStream: Bool,
                         timed: Bool) async throws -> (id: String, stream: Stream) {
        try Task.checkCancellation()
        if let failure { throw failure }
        start()
        nextID += 1
        let id = String(nextID)
        let (stream, continuation) = Stream.makeStream(bufferingPolicy: .bufferingOldest(2048))
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { Task { await self?.interrupt(id) } }
        }
        let timeout = timed ? Task { [weak self, requestTimeout] in
            do {
                try await Task.sleep(for: requestTimeout)
                await self?.interrupt(id, with: .timeout)
            } catch {}
        } : nil
        pending[id] = Pending(continuation: continuation, isStream: isStream, timeout: timeout)
        let frame: JSONValue = .object([
            "_tag": .string("Request"), "id": .string(id), "tag": .string(method),
            "payload": payload, "headers": .array([])
        ])
        do {
            try await send(frame)
        } catch {
            let error = failure ?? .transport
            await terminate(with: error)
            throw error
        }
        if Task.isCancelled {
            interrupt(id)
            throw CancellationError()
        }
        return (id, stream)
    }

    private func start() {
        guard receiver == nil else { return }
        receiver = Task { [weak self, transport] in
            do {
                while !Task.isCancelled {
                    let data = try await transport.receive()
                    guard let self else { return }
                    try await self.receive(data)
                }
            } catch {
                await self?.terminate(with: error as? T3RPCError ?? .transport)
            }
        }
        heartbeat = Task { [weak self, heartbeatInterval, pongTimeout] in
            do {
                var nextPing = ContinuousClock.now + heartbeatInterval
                while !Task.isCancelled {
                    try await Task.sleep(until: nextPing, clock: .continuous)
                    guard try await self?.ping() == true else { return }
                    let sentAt = ContinuousClock.now
                    nextPing = sentAt + heartbeatInterval
                    try await Task.sleep(until: sentAt + pongTimeout, clock: .continuous)
                    guard await self?.checkPong() == true else { return }
                }
            } catch {
                if !Task.isCancelled { await self?.terminate(with: .transport) }
            }
        }
    }

    private func ping() async throws -> Bool {
        guard failure == nil else { return false }
        awaitingPong = true
        try await send(.object(["_tag": .string("Ping")]), timeout: pongTimeout)
        return true
    }

    private func checkPong() async -> Bool {
        if awaitingPong { await terminate(with: .timeout) }
        return failure == nil
    }

    private func send(_ frame: JSONValue, timeout: Duration? = nil) async throws {
        if let failure { throw failure }
        let deadline = ContinuousClock.now + (timeout ?? requestTimeout)
        let writeTimeout = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            // Writes can wait for an upgrade or network progress. Closing releases the transport's waiter.
            await self?.terminate(with: .timeout)
        }
        defer { writeTimeout.cancel() }
        try await transport.send(frame.data)
    }

    private func receive(_ data: Data) async throws {
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: data),
              let tag = frame["_tag"].text, !tag.isEmpty else { throw T3RPCError.invalidFrame }
        switch tag {
        case "Ping": try await send(.object(["_tag": .string("Pong")]))
        case "Pong": awaitingPong = false
        case "Defect":
            let defect = frame["defect"]
            throw T3RPCError.defect(defect["message"].text ?? defect.text ?? "T3 Code reported an RPC failure.")
        case "Chunk":
            guard let id = frame["requestId"].text, let values = frame["values"].list else {
                throw T3RPCError.invalidFrame
            }
            guard let request = pending[id] else { return }
            guard request.isStream else { throw T3RPCError.invalidFrame }
            for value in values {
                if case .dropped = request.continuation.yield(value) {
                    throw T3RPCError.invalidFrame
                }
            }
            try await send(.object(["_tag": .string("Ack"), "requestId": .string(id)]))
        case "Exit":
            guard let id = frame["requestId"].text else { throw T3RPCError.invalidFrame }
            guard let request = pending.removeValue(forKey: id) else { return }
            request.timeout?.cancel()
            let exit = frame["exit"]
            switch exit["_tag"].text {
            case "Success":
                if !request.isStream { request.continuation.yield(exit["value"]) }
                request.continuation.finish()
            case "Failure": request.continuation.finish(throwing: Self.remoteError(exit["cause"]))
            default: request.continuation.finish(throwing: T3RPCError.invalidFrame)
            }
        default: return // Additive server notifications do not invalidate outstanding requests.
        }
    }

    private static func remoteError(_ cause: JSONValue) -> T3RPCError {
        let reasons = cause.list ?? cause["reasons"].list ?? [cause]
        for reason in reasons {
            switch reason["_tag"].text {
            case "Fail":
                let error = reason["error"]
                return .remote(tag: error["_tag"].text ?? "Failure",
                               message: error["message"].text ?? error["reason"].text ?? error.text ?? "T3 Code rejected the request.")
            case "Die":
                let defect = reason["defect"]
                return .defect(defect["message"].text ?? defect.text ?? "T3 Code reported an RPC failure.")
            default: continue
            }
        }
        return reasons.contains { $0["_tag"].text == "Interrupt" } ? .interrupted : .invalidFrame
    }

    private func interrupt(_ id: String, with error: T3RPCError = .interrupted) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout?.cancel()
        request.continuation.finish(throwing: error)
        Task { [weak self] in
            do {
                try await self?.send(.object(["_tag": .string("Interrupt"), "requestId": .string(id)]))
            } catch {
                await self?.terminate(with: .transport)
            }
        }
    }

    private func terminate(with error: T3RPCError) async {
        guard failure == nil else { return }
        failure = error
        receiver?.cancel()
        heartbeat?.cancel()
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeout?.cancel()
            request.continuation.finish(throwing: error)
        }
        await transport.close()
    }
}
