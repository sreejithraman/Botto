import Foundation
import Testing
@testable import BottoCore

/// Requests as the routes saw them: host, path and time limit.
actor RouteRequests {
    private(set) var seen: [(host: String, path: String, timeout: TimeInterval)] = []
    func record(_ request: URLRequest) { seen.append((request.url?.host ?? "", request.url?.path ?? "", request.timeoutInterval)) }
    func at(_ path: String) -> [String] { seen.filter { $0.path == path }.map(\.host) }
}

/// Hosts the service opened sockets to, recorded as the socket is made.
final class SocketHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var hosts: [String] { lock.withLock { recorded } }
    func record(_ request: URLRequest) { lock.withLock { recorded.append(request.url?.host ?? "") } }
}

func routeReply(_ request: URLRequest, _ json: String) throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
}

@Suite(.timeLimit(.minutes(1))) struct T3RouteFallbackTests {
    private let lan = URL(string: "http://192.168.1.20:3774")!
    private let tailscale = URL(string: "http://100.64.1.2:3774")!
    private let tunnel = URL(string: "https://botto.example.com")!

    @Test func pairingExchangesTheCredentialOnceAtTheFirstRouteThatAnswers() async throws {
        let requests = RouteRequests()
        let exchange = T3PairingExchange { request in
            await requests.record(request)
            if request.url?.host == "192.168.1.20" { throw URLError(.cannotConnectToHost) }
            return try routeReply(request, request.url?.path == "/oauth/token"
                ? #"{"token_type":"Bearer","access_token":"access"}"#
                : #"{"environmentId":"env","label":"Host","serverVersion":"2.0","orchestrationProtocolVersion":2}"#)
        }
        let paired = try await exchange.exchangePairingCredential(routes: [lan, tunnel, lan], credential: "code",
                                                                  clientLabel: "Botto")
        #expect(await requests.at("/oauth/token") == ["botto.example.com"])
        #expect(paired.configuration.serverURL == lan)
        #expect(paired.configuration.alternateRoutes == [tunnel])
        #expect(paired.configuration.lastReachedRoute == tunnel)
        #expect(paired.configuration.connectionRoutes == [tunnel, lan])
    }

    @Test func whenNoRouteAnswersTheFailureNamesEachOneTried() async throws {
        let requests = RouteRequests()
        let exchange = T3PairingExchange { request in
            await requests.record(request)
            if request.url?.host == "botto.example.com" { return try routeReply(request, #"{"orchestrationProtocolVersion":1}"#) }
            throw URLError(.timedOut)
        }
        let failure = await #expect(throws: T3UnreachableRoutes.self) {
            try await exchange.exchangePairingCredential(routes: [lan, tailscale, tunnel], credential: "code", clientLabel: "Botto")
        }
        #expect(failure?.attempts.map(\.reason) == [.noAnswer, .noAnswer, .needsUpdate])
        #expect(failure?.localizedDescription == "Couldn’t reach your Mac. Local network (192.168.1.20) didn’t answer; "
            + "Tailscale (100.64.1.2) didn’t answer; botto.example.com needs a newer Botto. "
            + "Check that Botto is running on your Mac, then try again.")
        #expect(await requests.at("/oauth/token").isEmpty)
    }

    @Test func aSingleRouteFailsAsItDidBeforeRoutes() async throws {
        let requests = RouteRequests()
        let exchange = T3PairingExchange { request in
            await requests.record(request)
            throw URLError(.timedOut)
        }
        await #expect(throws: URLError.self) {
            try await exchange.exchangePairingCredential(origin: lan, credential: "code", clientLabel: "Botto")
        }
        #expect(await requests.seen.map(\.timeout) == [30])
    }
}
