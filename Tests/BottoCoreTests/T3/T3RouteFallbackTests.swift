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

    enum UnknownOutcome: CaseIterable {
        case timedOut, connectionLost, gateway, unavailable, serverError, requestError, redirected, unreadableSuccess, unsupportedToken
    }

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
            case .unavailable: return try routeReply(request, "Service Unavailable", status: 503)
            // T3 can fail after it consumed the code.
            case .serverError:
                return try routeReply(request, #"{"code":"internal_error","reason":"access_token_issuance_failed","traceId":"t"}"#,
                                      status: 500)
            case .requestError:
                return try routeReply(request, #"{"code":"invalid_request","reason":"invalid_scope","traceId":"t"}"#, status: 400)
            case .redirected: return try routeReply(request, "", status: 307)
            case .unreadableSuccess: return try routeReply(request, "<html>")
            case .unsupportedToken: return try routeReply(request, #"{"token_type":"DPoP","access_token":"access"}"#)
            }
        }
        await #expect(throws: T3PairingError.codeMayBeUsed) {
            try await exchange.exchangePairingCredential(routes: [lan, tunnel], credential: "code", clientLabel: "Botto")
        }
        #expect(await requests.at("/oauth/token") == ["botto.example.com"])
        #expect(T3PairingError.codeMayBeUsed.localizedDescription.contains("may already have used this pairing code"))
    }

    enum Cancelled: CaseIterable { case whileProbing, afterSendingTheCode }

    /// URLSession reports a cancelled request as URLError.cancelled; a test transport as CancellationError.
    @Test(arguments: Cancelled.allCases, [true, false])
    func aCancelledExchangeIsSpentOnceTheCodeWasSent(_ stage: Cancelled, asURLError: Bool) async throws {
        let requests = RouteRequests()
        let (waiting, waiter) = AsyncStream<Void>.makeStream()
        let exchange = T3PairingExchange { request in
            await requests.record(request)
            let held = (stage == .whileProbing) == (request.url?.path != "/oauth/token")
            if held {
                waiter.yield()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { throw asURLError ? URLError(.cancelled) : error }
            }
            return try routeReply(request, request.url?.path == "/oauth/token" ? token : environment)
        }
        let attempt = Task {
            try await exchange.exchangePairingCredential(routes: [lan, tunnel], credential: "code", clientLabel: "Botto")
        }
        for await _ in waiting { break }
        attempt.cancel()
        switch stage {
        case .whileProbing: await #expect(throws: CancellationError.self) { try await attempt.value }
        case .afterSendingTheCode: await #expect(throws: T3PairingError.codeMayBeUsed) { try await attempt.value }
        }
        #expect(await requests.at("/oauth/token") == (stage == .whileProbing ? [] : ["botto.example.com"]))
    }

    /// T3 answers a credential it doesn't know, or one already used, with 401 `auth_invalid`. It can
    /// also answer so after spending the code, when a session revocation won the race.
    @Test func aCodeT3RefusedEndsTheExchangeAsARefusal() async throws {
        let requests = RouteRequests()
        let exchange = T3PairingExchange { request in
            await requests.record(request)
            guard request.url?.path == "/oauth/token" else { return try routeReply(request, environment) }
            return try routeReply(request, #"{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid","reason":"invalid_credential","traceId":"t"}"#,
                                  status: 401)
        }
        await #expect(throws: T3PairingError.credentialRefused) {
            try await exchange.exchangePairingCredential(routes: [lan, tunnel], credential: "code", clientLabel: "Botto")
        }
        #expect(await requests.at("/oauth/token") == ["botto.example.com"])
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
