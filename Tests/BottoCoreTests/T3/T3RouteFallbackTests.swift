import Foundation
import Testing
@testable import BottoCore

/// Requests as the routes saw them: host, path, time limit, and whether they carried a token.
actor RouteRequests {
    private(set) var seen: [(host: String, path: String, timeout: TimeInterval, authorized: Bool)] = []
    func record(_ request: URLRequest) {
        seen.append((request.url?.host ?? "", request.url?.path ?? "", request.timeoutInterval,
                     request.value(forHTTPHeaderField: "Authorization") != nil))
    }
    func at(_ path: String) -> [String] { seen.filter { $0.path == path }.map(\.host) }
}

/// Hosts the service opened sockets to, recorded as the socket is made.
final class SocketHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var hosts: [String] { lock.withLock { recorded } }
    func record(_ request: URLRequest) { lock.withLock { recorded.append(request.url?.host ?? "") } }
}

func routeReply(_ request: URLRequest, _ json: String, status: Int = 200) throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
}

private let environment = #"{"environmentId":"env","label":"Host","serverVersion":"2.0","orchestrationProtocolVersion":2}"#
private let token = #"{"token_type":"Bearer","access_token":"access"}"#

@Suite(.timeLimit(.minutes(1))) struct T3RouteFallbackTests {
    private let lan = URL(string: "http://192.168.1.20:3774")!
    private let tailscale = URL(string: "http://100.64.1.2:3774")!
    private let tunnel = URL(string: "https://botto.example.com")!

    @Test func pairingSendsTheCodeToHTTPSFirstAndMovesOnOnlyWhenItCouldNotBeSent() async throws {
        let requests = RouteRequests()
        let exchange = T3PairingExchange { request in
            await requests.record(request)
            // The tunnel answers its probe, then drops before the exchange can be sent.
            if request.url?.host == "botto.example.com", request.url?.path == "/oauth/token" {
                throw URLError(.cannotConnectToHost)
            }
            return try routeReply(request, request.url?.path == "/oauth/token" ? token : environment)
        }
        let paired = try await exchange.exchangePairingCredential(routes: [lan, tunnel, lan], credential: "code",
                                                                  clientLabel: "Botto")
        #expect(await requests.seen.map(\.host) == ["botto.example.com", "botto.example.com", "192.168.1.20", "192.168.1.20"])
        #expect(await requests.at("/oauth/token") == ["botto.example.com", "192.168.1.20"])
        #expect(paired.configuration.serverURL == lan)
        #expect(paired.configuration.alternateRoutes == [tunnel])
        #expect(paired.configuration.lastReachedRoute == lan)
    }

    enum UnknownOutcome: CaseIterable { case timedOut, connectionLost, gateway, unreadableSuccess }

    @Test(arguments: UnknownOutcome.allCases)
    func aCodeWhoseExchangeOutcomeIsUnknownIsNeverSentAgain(_ outcome: UnknownOutcome) async throws {
        let requests = RouteRequests()
        let exchange = T3PairingExchange { request in
            await requests.record(request)
            guard request.url?.path == "/oauth/token" else { return try routeReply(request, environment) }
            switch outcome {
            case .timedOut: throw URLError(.timedOut)
            case .connectionLost: throw URLError(.networkConnectionLost)
            case .gateway: return try routeReply(request, "", status: 504)
            case .unreadableSuccess: return try routeReply(request, "<html>")
            }
        }
        await #expect(throws: T3PairingError.codeMayBeUsed) {
            try await exchange.exchangePairingCredential(routes: [lan, tunnel], credential: "code", clientLabel: "Botto")
        }
        #expect(await requests.at("/oauth/token") == ["botto.example.com"])
        #expect(T3PairingError.codeMayBeUsed.localizedDescription.contains("may already have used this pairing code"))
    }

    @Test func aCodeTheMacRefusedIsReportedAsBefore() async throws {
        let exchange = T3PairingExchange { request in
            try routeReply(request, request.url?.path == "/oauth/token" ? "" : environment,
                           status: request.url?.path == "/oauth/token" ? 400 : 200)
        }
        await #expect(throws: T3PairingError.httpStatus(400)) {
            try await exchange.exchangePairingCredential(routes: [lan, tunnel], credential: "code", clientLabel: "Botto")
        }
    }

    @Test func whenNoRouteAnswersTheFailureNamesEachOneTried() async throws {
        let requests = RouteRequests()
        let exchange = T3PairingExchange { request in
            await requests.record(request)
            switch request.url?.host {
            case "botto.example.com": return try routeReply(request, #"{"orchestrationProtocolVersion":1}"#)
            case "100.64.1.2": return try routeReply(request, "Service Unavailable", status: 503)
            default: throw URLError(.timedOut)
            }
        }
        let failure = await #expect(throws: T3UnreachableRoutes.self) {
            try await exchange.exchangePairingCredential(routes: [lan, tailscale, tunnel], credential: "code", clientLabel: "Botto")
        }
        #expect(failure?.attempts.map(\.reason) == [.needsUpdate, .noAnswer, .httpError(503)])
        #expect(failure?.localizedDescription == "Couldn’t reach your Mac. botto.example.com needs a newer Botto; "
            + "Local network (192.168.1.20) didn’t answer; Tailscale (100.64.1.2) answered with an error (HTTP 503). "
            + "Check that Botto is running on your Mac, then try again.")
        #expect(await requests.seen.map(\.timeout) == [15, 5, 30])
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
