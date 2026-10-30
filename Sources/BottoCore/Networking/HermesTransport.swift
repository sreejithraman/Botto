import Foundation

@MainActor protocol HermesSocket: AnyObject {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close()
}

@MainActor protocol HermesTransport: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func socket(for request: URLRequest) throws -> any HermesSocket
    func invalidate()
}

/// Reject every redirect, including same-origin redirects of password POSTs and upgrades.
/// A new ephemeral session per connection keeps cookies out of the shared browser jar.
final class HermesRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum HermesTransportLimits {
    // 50 MiB of images becomes 66 2/3 MiB of base64. Leave about 29 MiB
    // for JSON, text and other rows, without allowing unbounded histories.
    static let history = 96 * 1024 * 1024
    static let ordinary = 32 * 1024 * 1024

    static func httpBody(for request: URLRequest) -> Int {
        if isArtifact(request) { return DownloadedArtifact.maximumBytes }
        let path = request.url?.path.split(separator: "/") ?? []
        if request.httpMethod == "GET", path.count == 4,
           path[0] == "api", path[1] == "sessions", path[3] == "messages" {
            return history
        }
        return ordinary
    }

    static func isArtifact(_ request: URLRequest) -> Bool {
        request.httpMethod == "GET" && request.url?.path == "/api/fs/download"
    }
}

@MainActor final class NativeHermesTransport: HermesTransport {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: HermesRedirectGuard(), delegateQueue: nil)
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let receiver = HermesHTTPReceiver(url: request.url, limit: HermesTransportLimits.httpBody(for: request),
            limitError: HermesTransportLimits.isArtifact(request) ? .artifactTooLarge : .incompatible)
        let task = session.dataTask(with: request)
        task.delegate = receiver
        return try await withTaskCancellationHandler {
            try await receiver.result(starting: task)
        } onCancel: {
            receiver.finish(.failure(CancellationError()))
            task.cancel()
        }
    }
    func socket(for request: URLRequest) throws -> any HermesSocket {
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = HermesTransportLimits.history
        task.resume()
        return NativeHermesSocket(task: task)
    }
    func invalidate() { session.invalidateAndCancel() }
}

/// Accumulate URLSession chunks off the main actor. All mutable state is locked;
/// cancellation may race the serial delegate callbacks, including before start.
private final class HermesHTTPReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Response = (Data, HTTPURLResponse)
    private let url: URL?
    private let limit: Int
    private let limitError: HermesServiceError
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<Response, any Error>?
    private var completed = false
    private var earlyResult: Result<Response, any Error>?

    init(url: URL?, limit: Int, limitError: HermesServiceError) {
        self.url = url; self.limit = limit; self.limitError = limitError
    }

    func result(starting task: URLSessionDataTask) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            let early: Result<Response, any Error>? = lock.withLock {
                if let earlyResult { self.earlyResult = nil; return earlyResult }
                self.continuation = continuation
                return nil
            }
            if let early { continuation.resume(with: early) }
            else { task.resume() }
        }
    }

    func finish(_ result: Result<Response, any Error>) {
        let waiting = lock.withLock {
            guard !completed else { return nil as CheckedContinuation<Response, any Error>? }
            completed = true
            data = Data()
            response = nil
            let waiting = continuation
            continuation = nil
            if waiting == nil { earlyResult = result }
            return waiting
        }
        waiting?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        finish(.failure(HermesServiceError.redirected))
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            finish(.failure(HermesServiceError.disconnected)); completionHandler(.cancel); return
        }
        guard response.url == url, !(300..<400).contains(response.statusCode) else {
            finish(.failure(HermesServiceError.redirected)); completionHandler(.cancel); return
        }
        // This is only an early refusal. The actual delivered bytes remain bounded
        // when Content-Length is missing, false, or describes compressed bytes.
        guard response.expectedContentLength <= limit else {
            finish(.failure(limitError)); completionHandler(.cancel); return
        }
        let active = lock.withLock {
            guard !completed else { return false }
            self.response = response
            return true
        }
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let overflow = lock.withLock {
            guard !completed else { return false }
            guard chunk.count <= limit - data.count else { return true }
            data.append(chunk)
            return false
        }
        if overflow {
            finish(.failure(limitError))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result: Result<Response, any Error> = lock.withLock {
            if let error { return .failure(error) }
            guard let response else { return .failure(HermesServiceError.disconnected) }
            return .success((data, response))
        }
        finish(result)
    }
}

@MainActor final class NativeHermesSocket: HermesSocket {
    private let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }
    var messageLimit: Int { task.maximumMessageSize }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw HermesServiceError.incompatible
        }
    }
    func send(_ data: Data) async throws { try await task.send(.string(String(decoding: data, as: UTF8.self))) }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}
