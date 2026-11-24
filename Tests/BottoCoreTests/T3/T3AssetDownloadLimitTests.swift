import Foundation
import Testing
@testable import BottoCore

@Suite(.serialized) @MainActor struct T3AssetDownloadLimitTests {
    @Test(arguments: [nil, "26214401"] as [String?])
    func t3SignedOutputIsBoundedWhileReceiving(_ length: String?) async throws {
        let url = URL(string: "https://t3.invalid/api/assets/signed/report")!
        let fixture = TransportResponse(repeatedBytes: DownloadedArtifact.maximumBytes + 1,
            headers: length.map { ["Content-Length": $0] } ?? [:])
        TransportBodyProtocol.install(fixture, at: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportBodyProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); TransportBodyProtocol.remove(url) }
        await #expect(throws: ConversationServiceError.artifactTooLarge) {
            try await T3PairingExchange.directHTTP(URLRequest(url: url), in: session)
        }
    }
}

private final class TransportResponse: @unchecked Sendable {
    let repeatedBytes: Int
    let headers: [String: String]

    init(repeatedBytes: Int, headers: [String: String]) {
        self.repeatedBytes = repeatedBytes
        self.headers = headers
    }
}

private final class TransportBodyProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [URL: TransportResponse] = [:]
    static func install(_ fixture: TransportResponse, at url: URL) { lock.withLock { fixtures[url] = fixture } }
    static func remove(_ url: URL) { _ = lock.withLock { fixtures.removeValue(forKey: url) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.lock.withLock({ Self.fixtures[request.url!] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: 0x61, count: 64 * 1024)
        for offset in stride(from: 0, to: fixture.repeatedBytes, by: chunk.count) {
            client?.urlProtocol(self, didLoad: chunk.prefix(min(chunk.count, fixture.repeatedBytes - offset)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
