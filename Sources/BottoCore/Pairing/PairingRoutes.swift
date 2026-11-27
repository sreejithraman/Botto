import Foundation

/// The routes one pairing reaches its Mac by. A pairing link's own origin is its primary route, read
/// the same way by every Botto build. Further routes ride beside the credential in the link's
/// fragment as `route` items, which older builds ignore and which never reach a server.
public enum PairingRoutes {
    public enum Kind: Equatable, Sendable { case localNetwork, tailscale, secure }

    static let parameter = "route"

    /// The pairing link with `routes` added after its own origin.
    public static func link(_ pairingURL: String, adding routes: [URL]) -> String? {
        guard var link = URLComponents(string: pairingURL), let fragment = link.percentEncodedFragment else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let items = routes.compactMap { route in
            route.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed).map { "\(parameter)=\($0)" }
        }
        link.percentEncodedFragment = ([fragment] + items).joined(separator: "&")
        return link.string
    }

    /// The routes a device may use, in order: each passes the pairing address rule, so plain HTTP
    /// only reaches a local network or Tailscale address, and only with the person's consent.
    /// A route that fails is dropped.
    public static func allowed(_ routes: [URL], allowingHTTP: Bool) -> [URL] {
        unique(routes.compactMap { try? PairingAddress.parse($0.absoluteString, allowInsecureHTTP: allowingHTTP) })
    }

    public nonisolated static func kind(of route: URL) -> Kind {
        let host = route.host?.lowercased() ?? ""
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if host.hasSuffix(".ts.net") || (octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])) {
            return .tailscale
        }
        return route.scheme == "https" ? .secure : .localNetwork
    }

    /// Plain words for a route, such as "Tailscale (100.64.1.2)".
    public nonisolated static func describe(_ route: URL) -> String {
        let host = route.host ?? route.absoluteString
        return switch kind(of: route) {
        case .localNetwork: "Local network (\(host))"
        case .tailscale: "Tailscale (\(host))"
        case .secure: host
        }
    }

    /// The link's own origin, then each further route that is a web origin, once.
    static func routes(primary: URL, items: [URLQueryItem]?) -> [URL] {
        let others = (items ?? []).filter { $0.name == parameter }
            .compactMap { $0.value.flatMap { try? T3PairingExchange.validatedOrigin($0) } }
        return unique([primary] + others)
    }

    static func unique(_ routes: [URL]) -> [URL] {
        var seen = Set<URL>()
        return routes.filter { seen.insert($0).inserted }
    }
}

public extension ConnectionConfiguration {
    /// Every route to try, in order: the one that last worked, then the primary, then the rest as paired.
    /// The last one to work comes first because a phone's network rarely changes between connections.
    var connectionRoutes: [URL] {
        var routes = PairingRoutes.unique([serverURL] + (alternateRoutes ?? []))
        if let last = lastReachedRoute, let index = routes.firstIndex(of: last) {
            routes.insert(routes.remove(at: index), at: 0)
        }
        return routes
    }

    /// Remembers the route a connection reached. A single-route pairing has nothing to remember.
    mutating func reached(_ route: URL) {
        lastReachedRoute = alternateRoutes?.isEmpty == false ? route : nil
    }
}
