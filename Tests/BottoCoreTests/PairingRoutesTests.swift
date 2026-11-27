import Foundation
import Testing
@testable import BottoCore

@Suite struct PairingRoutesTests {
    private let lan = URL(string: "http://192.168.1.20:3774")!
    private let tailscale = URL(string: "http://100.64.1.2:3774")!
    private let tunnel = URL(string: "https://botto.example.com")!

    private func link() throws -> String {
        try #require(PairingRoutes.link("http://192.168.1.20:3774/pair#token=Ab%2bc", adding: [tailscale, tunnel]))
    }

    @Test func linksCarryEveryRouteAfterTheirOwnOrigin() throws {
        let link = try link()
        #expect(link == "http://192.168.1.20:3774/pair#token=Ab%2bc"
            + "&route=http%3A%2F%2F100.64.1.2%3A3774&route=https%3A%2F%2Fbotto.example.com")
        let parsed = try T3PairingExchange.parse(link)
        #expect(parsed.origin == lan)
        #expect(parsed.credential == "Ab+c")
        #expect(parsed.routes == [lan, tailscale, tunnel])

        let encoded = try #require(link.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        #expect(try T3PairingExchange.parse("t3code://pair?pairingUrl=" + encoded) == parsed)
    }

    @Test func linksDropRoutesThatAreNotWebOriginsAndRepeats() throws {
        let link = "https://botto.example.com/pair#token=A&route=ftp%3A%2F%2Fhost.example"
            + "&route=https%3A%2F%2Fuser%3Apass%40host.example&route=http%3A%2F%2F100.64.1.2%3A3774%2Fprefix%3Fq%3D1"
        // A route's path and query are stripped the same way the primary's are.
        #expect(try T3PairingExchange.parse(link).routes == [tunnel, tailscale])
        #expect(try T3PairingExchange.parse("https://botto.example.com", credential: "typed").routes == [tunnel])
    }

    @Test func olderPhonesPairWithThePrimaryRoute() throws {
        let link = try link()
        let older = try OlderBuild.Review(link)
        #expect(older.origin == lan)
        #expect(older.credential == "Ab+c")
        let encoded = try #require(link.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let nested = try OlderBuild.Review("t3code://pair?pairingUrl=" + encoded)
        #expect(nested.origin == lan && nested.credential == "Ab+c")
    }

    @Test func aRouteIsOneSchemeHostAndEffectivePort() throws {
        let link = "https://botto.example.com/pair#token=A&route=https%3A%2F%2FBotto.Example.com%3A443"
            + "&route=http%3A%2F%2F192.168.1.20%3A80&route=HTTPS%3A%2F%2Fbotto.example.com%3A8443"
        #expect(try T3PairingExchange.parse(link).routes.map(\.absoluteString)
            == ["https://botto.example.com", "http://192.168.1.20", "https://botto.example.com:8443"])
        #expect(PairingRoutes.same(URL(string: "https://x.example:443")!, URL(string: "https://X.example")!))
        #expect(PairingRoutes.same(URL(string: "http://192.168.1.20:80")!, URL(string: "http://192.168.1.20")!))
        #expect(!PairingRoutes.same(URL(string: "http://x.example:443")!, URL(string: "https://x.example")!))
        let configuration = ConnectionConfiguration(serverURL: tunnel, alternateRoutes: [URL(string: "https://BOTTO.example.com:443")!, lan])
        #expect(configuration.connectionRoutes == [tunnel, lan])
    }

    @Test func aLinkCarriesAtMostFourRoutes() throws {
        let three = (1...3).map { "&route=http%3A%2F%2F192.168.1.\($0)%3A3774" }.joined()
        #expect(try T3PairingExchange.parse("http://192.168.1.20:3774/pair#token=A" + three).routes.count == 4)
        let four = three + "&route=https%3A%2F%2Fbotto.example.com"
        #expect(throws: T3PairingError.tooManyRoutes) { try T3PairingExchange.parse("http://192.168.1.20:3774/pair#token=A" + four) }
        let encoded = try #require(("http://192.168.1.20:3774/pair#token=A" + four).addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        #expect(throws: T3PairingError.tooManyRoutes) { try T3PairingExchange.parse("t3code://pair?pairingUrl=" + encoded) }
    }

    @Test func eachRouteKeepsThePairingAddressRule() throws {
        let routes = [lan, URL(string: "http://botto.example.com")!, tailscale, URL(string: "http://8.8.8.8:3774")!,
                      tunnel, URL(string: "https://botto.example.com/")!]
        // HTTP reaches only a local network or Tailscale address, and only with consent.
        #expect(PairingRoutes.allowed(routes, allowingHTTP: true) == [lan, tailscale, tunnel])
        #expect(PairingRoutes.allowed(routes, allowingHTTP: false) == [tunnel])
        #expect(PairingRoutes.allowed([lan], allowingHTTP: false).isEmpty)
    }

    @Test func routesAreNamedInPlainWords() throws {
        #expect(PairingRoutes.describe(lan) == "Local network (192.168.1.20)")
        #expect(PairingRoutes.describe(tailscale) == "Tailscale (100.64.1.2)")
        #expect(PairingRoutes.kind(of: URL(string: "https://mac.tail1234.ts.net")!) == .tailscale)
        #expect(PairingRoutes.describe(tunnel) == "botto.example.com")
        #expect(PairingRoutes.kind(of: URL(string: "http://100.128.0.1:3774")!) == .localNetwork)
    }
}

extension PairingRoutesTests {
    @Test func singleRouteSetupsSavedBeforeRoutesStillReadAndConnectTheSameWay() throws {
        let url = try #require(Bundle.module.url(forResource: "single-route-t3-connection", withExtension: "json",
                                                 subdirectory: "Fixtures/Pairing"))
        let saved = try JSONDecoder().decode(ConnectionConfiguration.self, from: Data(contentsOf: url))
        #expect(saved.serverURL == lan)
        #expect(saved.alternateRoutes == nil && saved.lastReachedRoute == nil)
        #expect(saved.connectionRoutes == [lan])
        #expect(saved.t3?.accessToken == "fixture-access-token")
        #expect(saved.t3?.workspaceRoot == "/Users/fixture/.botto/workspace")

        var reached = saved
        reached.reached(lan)
        #expect(reached == saved)
        let encoded = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(ConnectionConfiguration.self, from: encoded) == saved)
        let keys = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        #expect(!keys.contains("alternateRoutes") && !keys.contains("lastReachedRoute"))
    }

    @Test func withoutAnHTTPSRouteConnectionsTryTheRouteThatLastWorkedFirst() throws {
        var configuration = ConnectionConfiguration(serverURL: lan, alternateRoutes: [tailscale, lan])
        #expect(configuration.connectionRoutes == [lan, tailscale])
        configuration.reached(tailscale)
        #expect(configuration.connectionRoutes == [tailscale, lan])
        let roundTrip = try JSONDecoder().decode(ConnectionConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(roundTrip.connectionRoutes == [tailscale, lan])
        // A remembered route that is no longer one of the pairing's routes is ignored.
        configuration.lastReachedRoute = URL(string: "http://10.0.0.9:3774")
        #expect(configuration.connectionRoutes == [lan, tailscale])
    }

    @Test func everyHTTPSRouteIsTriedBeforeAnyHTTPRoute() throws {
        let secureTailscale = URL(string: "https://mac.tail1234.ts.net")!
        var configuration = ConnectionConfiguration(serverURL: lan, alternateRoutes: [tailscale, tunnel, secureTailscale])
        #expect(configuration.connectionRoutes == [tunnel, secureTailscale, lan, tailscale])
        // The route that last worked leads its own group, never the secure ones.
        configuration.reached(tailscale)
        #expect(configuration.connectionRoutes == [tunnel, secureTailscale, tailscale, lan])
        configuration.reached(secureTailscale)
        #expect(configuration.connectionRoutes == [secureTailscale, tunnel, lan, tailscale])
    }
}

/// `T3PairingExchange.parse` and `T3PairingReview.init` exactly as they shipped on main at fe14e6a, before
/// pairing links carried routes. The bodies are copied verbatim; only the type names differ, so an older
/// phone's reading of a new link stays checked.
private enum OlderBuild {
    struct Input: Equatable, Sendable {
        let origin: URL
        let credential: String
    }

    enum Exchange {
        static func parse(_ input: String, credential manualCredential: String? = nil) throws -> Input {
            let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URLComponents(string: input) else { throw T3PairingError.invalidOrigin }
            let origin: URL
            let credential: String?
            if url.scheme?.lowercased() == "t3code", manualCredential == nil {
                guard url.host?.lowercased() == "pair", url.user == nil, url.password == nil else {
                    throw T3PairingError.invalidOrigin
                }
                if let pairingURL = parameter("pairingUrl", from: url.queryItems) {
                    guard let nested = URLComponents(string: pairingURL),
                          nested.scheme?.lowercased() == "http" || nested.scheme?.lowercased() == "https" else {
                        throw T3PairingError.invalidOrigin
                    }
                    origin = try validatedOrigin(pairingURL)
                    var fragment = URLComponents()
                    fragment.percentEncodedQuery = nested.percentEncodedFragment
                    credential = parameter("token", from: fragment.queryItems)
                        ?? parameter("token", from: url.queryItems)
                        ?? parameter("credential", from: url.queryItems)
                } else if let address = parameter("url", from: url.queryItems) {
                    origin = try validatedOrigin(address)
                    credential = parameter("token", from: url.queryItems) ?? parameter("credential", from: url.queryItems)
                } else {
                    throw T3PairingError.invalidOrigin
                }
            } else {
                origin = try validatedOrigin(input)
                var fragment = URLComponents()
                fragment.percentEncodedQuery = url.percentEncodedFragment
                credential = manualCredential ?? parameter("token", from: fragment.queryItems)
            }
            guard let credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !credential.isEmpty else { throw T3PairingError.missingCredential }
            return Input(origin: origin, credential: credential)
        }

        nonisolated static func validatedOrigin(_ address: String) throws -> URL {
            guard var parts = URLComponents(string: address),
                  let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.port.map({ (1...65535).contains($0) }) ?? true else { throw T3PairingError.invalidOrigin }
            parts.scheme = scheme
            parts.path = ""
            parts.query = nil
            parts.fragment = nil
            guard let origin = parts.url else { throw T3PairingError.invalidOrigin }
            return origin
        }

        private static func parameter(_ name: String, from items: [URLQueryItem]?) -> String? {
            items?.first(where: { $0.name == name })?.value
        }
    }

    struct Review: Equatable {
        let origin: URL
        let credential: String

        init(_ input: String, code: String = "") throws {
            let pairing = try Exchange.parse(input, credential: Self.isPairingLink(input) ? nil : code)
            origin = try PairingAddress.parse(pairing.origin.absoluteString, allowInsecureHTTP: true)
            credential = pairing.credential
        }

        static func isPairingLink(_ input: String) -> Bool {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return URLComponents(string: text)?.scheme?.lowercased() == "t3code" || (try? Exchange.parse(text)) != nil
        }
    }
}
