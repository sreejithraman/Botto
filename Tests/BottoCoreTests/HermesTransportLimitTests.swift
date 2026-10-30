import Foundation
import Testing
@testable import BottoCore

@Suite(.serialized) @MainActor struct HermesTransportLimitTests {
    @Test(arguments: [nil, "1", "26214401"] as [String?])
    func refusesOversizedArtifactRegardlessOfContentLength(_ length: String?) async throws {
        let fixture = TransportResponse(repeatedBytes: 25 * 1024 * 1024 + 1,
            headers: length.map { ["Content-Length": $0] } ?? [:])
        let (transport, request) = makeTransport(fixture, path: "/api/fs/download?path=%2Fhost%2Freport.pdf&profile=bot&session_id=stored")
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        await #expect(throws: HermesServiceError.artifactTooLarge) { try await transport.data(for: request) }
    }

    @Test func acceptsExactArtifactBoundaryAndRefusesOversizedDeclaredBody() async throws {
        let (transport, request) = makeTransport(TransportResponse(repeatedBytes: 25 * 1024 * 1024), path: "/api/fs/download?path=report")
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        let (body, _) = try await transport.data(for: request)
        #expect(body.count == 26_214_400)
        #expect(body.first == 0x61 && body.last == 0x61)
        TransportBodyProtocol.install(TransportResponse(headers: ["Content-Length": "26214401"]), at: request.url!)
        await #expect(throws: HermesServiceError.artifactTooLarge) { try await transport.data(for: request) }
    }

    @Test func cancellationStopsArtifactReceiveAndAllowsAnotherRead() async throws {
        let fixture = TransportResponse(body: Data("partial".utf8), stalls: true)
        let (transport, request) = makeTransport(fixture, path: "/api/fs/download?path=report")
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        let read = Task { try await transport.data(for: request) }
        try await eventually { fixture.started }
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        try await eventually { fixture.stopped }
        TransportBodyProtocol.install(TransportResponse(body: Data("complete".utf8)), at: request.url!)
        let (body, _) = try await transport.data(for: request)
        #expect(body == Data("complete".utf8))
    }

    @Test(arguments: ["https://hermes.invalid/login", "https://elsewhere.invalid/download"])
    func artifactRedirectNeverForwardsCredentials(_ destination: String) async throws {
        let target = URL(string: destination)!
        let next = TransportResponse(body: Data("must not read".utf8))
        TransportBodyProtocol.install(next, at: target)
        let fixture = TransportResponse(redirect: target)
        var (transport, request) = makeTransport(fixture, path: "/api/fs/download?path=report")
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!); TransportBodyProtocol.remove(target) }
        request.setValue("Bearer native-secret", forHTTPHeaderField: "Authorization")
        request.setValue("page-secret", forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("proxy-secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        await #expect(throws: HermesServiceError.redirected) { try await transport.data(for: request) }
        #expect(fixture.starts == 1)
        #expect(next.starts == 0)
    }

    @Test(arguments: [13, 25]) func restoresStructuredImageHistory(imageMiB: Int) async throws {
        // ca678285 REST rows preserve content[].image_url.url. Two 25 MiB
        // images reach Botto's supported 50 MiB prompt budget before encoding.
        let body = structuredHistory(imageMiB: imageMiB)
        print("Structured history: two \(imageMiB) MiB images, \(body.count) wire bytes")
        let fixture = TransportResponse(body: body)
        let (transport, request) = makeTransport(fixture)
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        let (received, response) = try await transport.data(for: request)
        #expect(response.statusCode == 200)
        #expect(received == body)
        let decoded = try HermesJSON.decode(received)
        #expect(decoded["messages"].list?.count == 2)
        #expect(decoded["messages"].list?.first?["content"].list?.count == 3)
    }

    @Test(arguments: [nil, "1", "100663297"] as [String?])
    func refusesOversizedHistoryRegardlessOfContentLength(_ length: String?) async throws {
        let fixture = TransportResponse(repeatedBytes: 96 * 1024 * 1024 + 1,
            headers: length.map { ["Content-Length": $0] } ?? [:])
        let (transport, request) = makeTransport(fixture)
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        await #expect(throws: HermesServiceError.incompatible) { try await transport.data(for: request) }
    }

    @Test func acceptsExactHistoryBoundary() async throws {
        let fixture = TransportResponse(repeatedBytes: 96 * 1024 * 1024)
        let (transport, request) = makeTransport(fixture)
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        let (body, _) = try await transport.data(for: request)
        #expect(body.count == 100_663_296)
        #expect(body.first == 0x61 && body.last == 0x61)
    }

    @Test func ordinaryEndpointsKeepTheirSmallerBudget() async throws {
        let fixture = TransportResponse(repeatedBytes: 32 * 1024 * 1024 + 1)
        let (transport, request) = makeTransport(fixture, path: "/api/status")
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        await #expect(throws: HermesServiceError.incompatible) { try await transport.data(for: request) }
    }

    @Test func nativeSignInKeepsItsIndependentSmallResponseBoundary() async throws {
        // A valid probe padded beyond 128 KiB fits the ordinary transport budget,
        // but must still fail NativeSignInExchange's separate auth boundary.
        var body = Data(#"{"version":"0.21.5","install_id":"fixture","auth_required":true,"auth_providers":["basic"],"auth_flows":["native_pkce"],"padding":""#.utf8)
        body.append(Data(repeating: 0x61, count: 128 * 1024))
        body.append(Data(#""}"#.utf8))
        let (transport, request) = makeTransport(TransportResponse(body: body), path: "/api/status")
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.invalid")!, transport: transport)
        defer { exchange.close() }
        await #expect(throws: NativeSignInExchange.Failure.invalidResponse) { try await exchange.probe() }
    }

    @Test func cancellationStopsAnIncompleteBodyAndAllowsAnotherRead() async throws {
        let fixture = TransportResponse(body: Data("partial".utf8), stalls: true)
        let (transport, request) = makeTransport(fixture)
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        let read = Task { try await transport.data(for: request) }
        try await eventually { fixture.started }
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        try await eventually { fixture.stopped }
        TransportBodyProtocol.install(TransportResponse(body: Data("complete".utf8)), at: request.url!)
        let (body, _) = try await transport.data(for: request)
        #expect(String(decoding: body, as: UTF8.self) == "complete")
    }

    @Test func invalidationFinishesOutstandingReads() async throws {
        let fixture = TransportResponse(body: Data("partial".utf8), stalls: true)
        let (transport, request) = makeTransport(fixture)
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        let read = Task { try await transport.data(for: request) }
        try await eventually { fixture.started }
        transport.invalidate()
        await #expect(throws: URLError.self) { try await read.value }
        try await eventually { fixture.stopped }
    }

    @Test func alreadyCancelledReadDoesNotHang() async throws {
        let (transport, request) = makeTransport(TransportResponse(body: Data("unused".utf8), stalls: true))
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        let read = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.data(for: request)
        }
        await #expect(throws: CancellationError.self) { try await read.value }
    }

    @Test(arguments: ["https://hermes.invalid/auth/next", "https://elsewhere.invalid/auth/next"])
    func refusesRedirectedPasswordPosts(_ destination: String) async throws {
        let fixture = TransportResponse(body: Data(), redirect: URL(string: destination)!)
        var (transport, request) = makeTransport(fixture, path: "/auth/password-login")
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"password":"fixture-secret"}"#.utf8)
        await #expect(throws: HermesServiceError.redirected) { try await transport.data(for: request) }
        #expect(fixture.starts == 1)
    }

    @Test func refusesUnexpectedResponseOrigin() async throws {
        let fixture = TransportResponse(body: Data("{}".utf8), responseURL: URL(string: "https://elsewhere.invalid/api/status")!)
        let (transport, request) = makeTransport(fixture)
        defer { transport.invalidate(); TransportBodyProtocol.remove(request.url!) }
        await #expect(throws: HermesServiceError.redirected) { try await transport.data(for: request) }
    }

    @Test func configuresNativeWebSocketToCarryTheSameHistoryBudget() throws {
        let transport = NativeHermesTransport()
        defer { transport.invalidate() }
        let socket = try #require(transport.socket(for: URLRequest(url: URL(string: "wss://hermes.invalid/api/ws")!)) as? NativeHermesSocket)
        defer { socket.close() }
        // Reads URLSessionWebSocketTask.maximumMessageSize, not a parallel constant.
        #expect(socket.messageLimit == 100_663_296)
    }
}

private func structuredHistory(imageMiB: Int) -> Data {
    let encoded = Data(repeating: 0x61, count: imageMiB * 1024 * 1024).base64EncodedData()
    var body = Data(#"{"session_id":"stored","profile":"bot","messages":[{"id":7,"role":"user","content":[{"type":"text","text":"Compare these images"}"#.utf8)
    for _ in 0..<2 {
        body.append(Data(#",{"type":"image_url","image_url":{"url":"data:image/png;base64,"#.utf8))
        body.append(encoded)
        body.append(Data(#""}}"#.utf8))
    }
    body.append(Data(#"]},{"id":8,"role":"assistant","content":""#.utf8))
    body.append(Data(repeating: 0x74, count: 1024 * 1024))
    body.append(Data(#""}],"pagination":{"limit":100,"offset":0,"order":"latest","returned":2}}"#.utf8))
    return body
}

@MainActor private func makeTransport(_ fixture: TransportResponse, path: String? = nil) -> (NativeHermesTransport, URLRequest) {
    let url = URL(string: "https://hermes.invalid" + (path ?? "/api/sessions/\(UUID().uuidString)/messages?profile=bot&limit=100&order=latest"))!
    TransportBodyProtocol.install(fixture, at: url)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TransportBodyProtocol.self]
    return (NativeHermesTransport(configuration: configuration), URLRequest(url: url))
}

private final class TransportResponse: @unchecked Sendable {
    let body: Data
    let repeatedBytes: Int
    let headers: [String: String]
    let stalls: Bool
    let redirect: URL?
    let responseURL: URL?
    private let lock = NSLock()
    private var startCount = 0
    private var didStop = false
    var starts: Int { lock.withLock { startCount } }
    var started: Bool { starts > 0 }
    var stopped: Bool { lock.withLock { didStop } }
    func start() { lock.withLock { startCount += 1 } }
    func stop() { lock.withLock { didStop = true } }
    init(body: Data = Data(), repeatedBytes: Int = 0, headers: [String: String] = [:],
         stalls: Bool = false, redirect: URL? = nil, responseURL: URL? = nil) {
        self.body = body; self.repeatedBytes = repeatedBytes; self.headers = headers
        self.stalls = stalls; self.redirect = redirect; self.responseURL = responseURL
    }
}

private final class TransportBodyProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [URL: TransportResponse] = [:]
    private var fixture: TransportResponse?
    static func install(_ fixture: TransportResponse, at url: URL) { lock.withLock { fixtures[url] = fixture } }
    static func remove(_ url: URL) { _ = lock.withLock { fixtures.removeValue(forKey: url) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.lock.withLock({ Self.fixtures[request.url!] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        self.fixture = fixture
        fixture.start()
        if let redirect = fixture.redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: fixture.responseURL ?? request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: fixture.body.count, by: 64 * 1024) {
            client?.urlProtocol(self, didLoad: fixture.body.subdata(in: offset..<min(offset + 64 * 1024, fixture.body.count)))
        }
        let chunk = Data(repeating: 0x61, count: 64 * 1024)
        for offset in stride(from: 0, to: fixture.repeatedBytes, by: chunk.count) {
            client?.urlProtocol(self, didLoad: chunk.prefix(min(chunk.count, fixture.repeatedBytes - offset)))
        }
        if !fixture.stalls { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { fixture?.stop() }
}
