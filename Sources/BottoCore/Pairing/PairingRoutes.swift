import Foundation

/// The routes one pairing reaches its Mac by. A pairing link's own origin is its primary route, read
/// the same way by every Botto build. Further routes ride beside the credential in the link's
/// fragment as `route` items, which older builds ignore and which never reach a server.
public enum PairingRoutes {
    public enum Kind: Equatable, Sendable { case localNetwork, tailscale, secure }

    static let parameter = "route"
    /// The most routes a link may carry, its own origin included. The Mac writes at most three (LAN,
    /// Tailscale and an HTTPS tunnel), so a fourth leaves room for one more without a format change.
    /// Every route can add a wait to each connection, so the cap also bounds how long a connection
    /// with dead routes takes, and keeps the list short enough for a person to review.
    public static let maximumCount = 4
    /// How long a route's environment probe may go without receiving data before the next route is
    /// tried. These are URLRequest idle timeouts, not limits on the whole request. A direct LAN or
    /// Tailscale address that is there answers in well under a second, so 5 seconds of silence means
    /// it isn't. An HTTPS route can need a DNS lookup, a TLS handshake and a relay that wakes on
    /// demand, often over cellular, so it gets 15. The last route keeps the usual 30.
    nonisolated static func probeTimeout(for route: URL, isLast: Bool) -> TimeInterval {
        isLast ? T3PairingExchange.requestTimeout : route.scheme == "https" ? 15 : 5
    }

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

    /// Routes in the order to try them. Every HTTPS route comes before any plain HTTP one, so the
    /// token isn't sent over HTTP while a secure route answers. Within each group the route that last
    /// worked leads, then the rest keep their paired order.
    public static func ordered(_ routes: [URL], lastReached: URL?) -> [URL] {
        var routes = unique(routes)
        if let last = lastReached, let index = routes.firstIndex(where: { same($0, last) }) {
            routes.insert(routes.remove(at: index), at: 0)
        }
        return routes.filter { $0.scheme == "https" } + routes.filter { $0.scheme != "https" }
    }

    /// Whether two addresses are one route: the same scheme, host in any case, and effective port.
    public static func same(_ route: URL, _ other: URL) -> Bool { canonical(route) == canonical(other) }

    /// The link's own origin, then each further route that is a web origin, once. A path or query on
    /// a route is stripped, the same way the primary's is.
    static func routes(primary: URL, items: [URLQueryItem]?) throws -> [URL] {
        let items = (items ?? []).filter { $0.name == parameter }
        guard items.count < maximumCount else { throw T3PairingError.tooManyRoutes }
        let others = items.compactMap { $0.value.flatMap { try? T3PairingExchange.validatedOrigin($0) } }
        return unique([primary] + others.map(canonical))
    }

    /// Each route once, in its first spelling.
    static func unique(_ routes: [URL]) -> [URL] {
        var seen = Set<URL>()
        return routes.filter { seen.insert(canonical($0)).inserted }
    }

    /// One spelling per route: a lowercase scheme and host, and no port where it is the scheme's default.
    static func canonical(_ route: URL) -> URL {
        guard var parts = URLComponents(url: route, resolvingAgainstBaseURL: false) else { return route }
        parts.scheme = parts.scheme?.lowercased()
        parts.percentEncodedHost = parts.percentEncodedHost?.lowercased()
        if parts.port == (parts.scheme == "https" ? 443 : 80) { parts.port = nil }
        return parts.url ?? route
    }
}

public extension ConnectionConfiguration {
    /// Every route to try, in order: HTTPS routes before plain HTTP ones, and within each, the one
    /// that last worked, then the primary, then the rest as paired. The last one to work leads its
    /// group because a phone's network rarely changes between connections.
    var connectionRoutes: [URL] {
        PairingRoutes.ordered([serverURL] + (alternateRoutes ?? []), lastReached: lastReachedRoute)
    }

    /// Remembers the route a connection reached. A single-route pairing has nothing to remember.
    mutating func reached(_ route: URL) {
        lastReachedRoute = alternateRoutes?.isEmpty == false ? route : nil
    }
}

/// No route reached the paired Mac. Names each route tried and what happened there.
public struct T3UnreachableRoutes: Error, Equatable, LocalizedError, Sendable {
    public enum Reason: Equatable, Sendable {
        case noAnswer, differentMac, needsUpdate, unexpectedReply, wouldNotConnect
        case httpError(Int)
    }
    public struct Attempt: Equatable, Sendable {
        public let route: URL
        public let reason: Reason
        public init(route: URL, reason: Reason) { self.route = route; self.reason = reason }
    }

    public let attempts: [Attempt]
    public init(attempts: [Attempt]) { self.attempts = attempts }

    public var errorDescription: String? {
        let tried = attempts.map { attempt in
            let route = PairingRoutes.describe(attempt.route)
            return switch attempt.reason {
            case .noAnswer: "\(route) didn’t answer"
            case .differentMac: "\(route) is a different Mac"
            case .needsUpdate: "\(route) needs a newer Botto"
            case .unexpectedReply: "\(route) isn’t Botto"
            case .wouldNotConnect: "\(route) answered but wouldn’t connect"
            case .httpError(let status): "\(route) answered with an error (HTTP \(status))"
            }
        }
        return "Couldn’t reach your Mac. " + tried.joined(separator: "; ")
            + ". Check that Botto is running on your Mac, then try again."
    }

    /// What a route's failure says about it, before (`answered` false) or after it answered the probe.
    nonisolated static func reason(for error: any Error, answered: Bool) -> Reason {
        switch error {
        case T3PairingError.httpStatus(let status): .httpError(status)
        case T3ServiceError.differentEnvironment: .differentMac
        case _ where answered: .wouldNotConnect
        case is URLError: .noAnswer
        case T3PairingError.incompatibleProtocol: .needsUpdate
        default: .unexpectedReply
        }
    }

    /// Whether a failure after a route answered as the paired environment belongs to that route, so
    /// the next one is worth trying. Any failure of the reads a connection makes before it writes
    /// anything (ticket, socket, `server.getConfig`, projects) does, including a relay's own 401 or
    /// 403. Only T3's own refusal of the token, which every route would repeat, and a cancelled or
    /// superseded attempt end the search.
    nonisolated static func isRouteFailure(_ error: any Error) -> Bool {
        switch error {
        case T3PairingError.credentialRefused, is CancellationError, T3ServiceError.disconnected: false
        default: true
        }
    }
}

extension T3PairingExchange {
    /// Uses the first route, in order, that answers as `environmentID` (or as any T3 environment when
    /// nil) and that `use` succeeds on. A route that doesn't answer, answers as another environment,
    /// or fails `use` with an error `isRouteFailure` accepts is skipped for the next. Nothing reaches a
    /// route through `use` before it has answered as the environment. A single route fails with its
    /// own error, as before routes existed.
    func reach<Value>(_ routes: [URL], environmentID: String?,
                      isRouteFailure: (any Error) -> Bool,
                      isolation: isolated (any Actor)? = #isolation,
                      use: (_ origin: URL, _ descriptor: T3EnvironmentDescriptor) async throws -> Value) async throws -> Value {
        guard !routes.isEmpty else { throw T3PairingError.invalidOrigin }
        var attempts: [T3UnreachableRoutes.Attempt] = []
        for (index, route) in routes.enumerated() {
            var answered = false
            do {
                let origin = try Self.validatedOrigin(route.absoluteString)
                let timeout = PairingRoutes.probeTimeout(for: origin, isLast: index == routes.count - 1)
                let descriptor = try await probeEnvironment(origin: origin, timeout: timeout)
                if let environmentID, descriptor.environmentId != environmentID { throw T3ServiceError.differentEnvironment }
                answered = true
                return try await use(origin, descriptor)
            } catch {
                // What a route that answered says about the attempt stands even when it was cancelled
                // meanwhile, such as a pairing code that may now be spent.
                if answered && !isRouteFailure(error) { throw error }
                try Task.checkCancellation()
                if routes.count == 1 || error is CancellationError { throw error }
                attempts.append(.init(route: route, reason: T3UnreachableRoutes.reason(for: error, answered: answered)))
            }
        }
        throw T3UnreachableRoutes(attempts: attempts)
    }
}
