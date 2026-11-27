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
            + "&route=https%3A%2F%2Fuser%3Apass%40host.example&route=https%3A%2F%2Fbotto.example.com"
            + "&route=http%3A%2F%2F100.64.1.2%3A3774%2Fprefix%3Fq%3D1&route=http%3A%2F%2F100.64.1.2%3A3774"
        // A route's path and query are dropped the same way the primary's are.
        #expect(try T3PairingExchange.parse(link).routes == [tunnel, tailscale])
        #expect(try T3PairingExchange.parse("https://botto.example.com", credential: "typed").routes == [tunnel])
    }

    /// `T3PairingExchange.parse` and `T3PairingReview` as they shipped before routes, frozen so an older
    /// phone's reading of a new link stays checked.
    private func olderBuildReads(_ input: String) throws -> (origin: URL, credential: String) {
        func origin(_ address: String) throws -> URL {
            guard var parts = URLComponents(string: address),
                  let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.port.map({ (1...65535).contains($0) }) ?? true else { throw T3PairingError.invalidOrigin }
            parts.scheme = scheme; parts.path = ""; parts.query = nil; parts.fragment = nil
            guard let origin = parts.url else { throw T3PairingError.invalidOrigin }
            return origin
        }
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: input) else { throw T3PairingError.invalidOrigin }
        var fragment = URLComponents()
        let primary: URL
        if url.scheme?.lowercased() == "t3code" {
            let pairingURL = try #require(url.queryItems?.first { $0.name == "pairingUrl" }?.value)
            primary = try origin(pairingURL)
            fragment.percentEncodedQuery = URLComponents(string: pairingURL)?.percentEncodedFragment
        } else {
            primary = try origin(input)
            fragment.percentEncodedQuery = url.percentEncodedFragment
        }
        let credential = try #require(fragment.queryItems?.first { $0.name == "token" }?.value)
        return (try PairingAddress.parse(primary.absoluteString, allowInsecureHTTP: true), credential)
    }

    @Test func olderPhonesPairWithThePrimaryRoute() throws {
        let link = try link()
        let older = try olderBuildReads(link)
        #expect(older.origin == lan)
        #expect(older.credential == "Ab+c")
        let encoded = try #require(link.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        #expect(try olderBuildReads("t3code://pair?pairingUrl=" + encoded).origin == lan)
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

    @Test func connectionsTryTheRouteThatLastWorkedFirst() throws {
        var configuration = ConnectionConfiguration(serverURL: lan, alternateRoutes: [tailscale, tunnel, lan])
        #expect(configuration.connectionRoutes == [lan, tailscale, tunnel])
        configuration.reached(tunnel)
        #expect(configuration.connectionRoutes == [tunnel, lan, tailscale])
        let roundTrip = try JSONDecoder().decode(ConnectionConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(roundTrip.connectionRoutes == [tunnel, lan, tailscale])
        // A remembered route that is no longer one of the pairing's routes is ignored.
        configuration.lastReachedRoute = URL(string: "http://10.0.0.9:3774")
        #expect(configuration.connectionRoutes == [lan, tailscale, tunnel])
    }
}
