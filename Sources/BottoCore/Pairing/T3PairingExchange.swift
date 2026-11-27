import Foundation

public struct T3PairingInput: Equatable, Sendable {
    /// The primary route, which every Botto build reads from the link.
    public let origin: URL
    public let credential: String
    /// Every route the link carries, primary first.
    public let routes: [URL]
}

public struct T3EnvironmentDescriptor: Codable, Equatable, Sendable {
    public let environmentId: String
    public let label: String
    public let serverVersion: String
    public let orchestrationProtocolVersion: Int
}

public struct T3PairingResult: Sendable {
    public let accessToken: String
    public let environmentDescriptor: T3EnvironmentDescriptor
    public let configuration: ConnectionConfiguration
}

public struct T3WebSocketTicket: Equatable, Sendable {
    public let ticket: String
    public let expiresAt: Date
}

public enum T3PairingError: Error, Equatable, LocalizedError, Sendable {
    case invalidOrigin, missingCredential, redirected, incompatibleProtocol, invalidResponse
    case tooManyRoutes
    /// The code was sent, but whether it was redeemed is unknown, so it can't be tried again.
    case codeMayBeUsed
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: "Enter a valid HTTP or HTTPS environment address."
        case .missingCredential: "Enter a T3 Code pairing credential."
        case .redirected: "The T3 Code environment redirected the request."
        case .incompatibleProtocol: "This environment must support T3 orchestration protocol 2."
        case .invalidResponse: "The T3 Code environment returned an invalid response."
        case .codeMayBeUsed: "Your Mac may already have used this pairing code. Get a fresh link from Botto on your Mac, then try again."
        case .tooManyRoutes: "That pairing link lists more addresses than Botto accepts. Get a fresh link from Botto on your Mac."
        case .httpStatus(let status): "The T3 Code environment returned HTTP \(status)."
        }
    }
}

public struct T3PairingExchange: Sendable {
    public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: HTTPTransport

    public init(transport: @escaping HTTPTransport = Self.directHTTP) {
        self.transport = transport
    }

    public static func parse(_ input: String, credential manualCredential: String? = nil) throws -> T3PairingInput {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: input) else { throw T3PairingError.invalidOrigin }
        let origin: URL
        let credential: String?
        let items: [URLQueryItem]?
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
                items = fragment.queryItems
            } else if let address = parameter("url", from: url.queryItems) {
                origin = try validatedOrigin(address)
                credential = parameter("token", from: url.queryItems) ?? parameter("credential", from: url.queryItems)
                items = url.queryItems
            } else {
                throw T3PairingError.invalidOrigin
            }
        } else {
            origin = try validatedOrigin(input)
            var fragment = URLComponents()
            fragment.percentEncodedQuery = url.percentEncodedFragment
            credential = manualCredential ?? parameter("token", from: fragment.queryItems)
            items = manualCredential == nil ? fragment.queryItems : nil
        }
        guard let credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines),
              !credential.isEmpty else { throw T3PairingError.missingCredential }
        return T3PairingInput(origin: origin, credential: credential,
                              routes: try PairingRoutes.routes(primary: origin, items: items))
    }

    public func probeEnvironment(origin: URL, timeout: TimeInterval = requestTimeout) async throws -> T3EnvironmentDescriptor {
        let data = try await request(origin: origin, path: "/.well-known/t3/environment", timeout: timeout)
        struct ProtocolVersion: Decodable { let orchestrationProtocolVersion: Int? }
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(ProtocolVersion.self, from: data) else {
            throw T3PairingError.invalidResponse
        }
        guard version.orchestrationProtocolVersion == 2 else { throw T3PairingError.incompatibleProtocol }
        guard let descriptor = try? decoder.decode(T3EnvironmentDescriptor.self, from: data),
              !descriptor.environmentId.isEmpty else { throw T3PairingError.invalidResponse }
        return descriptor
    }

    public func exchangePairingCredential(origin: URL, credential: String, clientLabel: String) async throws -> T3PairingResult {
        try await exchangePairingCredential(routes: [origin], credential: credential, clientLabel: clientLabel)
    }

    /// Exchanges the one-time credential at the first route that answers, HTTPS routes first. The
    /// credential works at every route, but only once. Once it may have reached T3, it is never sent
    /// again: anything but a usable token or T3's own refusal of the credential ends with
    /// `codeMayBeUsed`, including a cancellation after sending. Only an exchange that couldn't be sent
    /// moves on to the next route.
    public func exchangePairingCredential(routes: [URL], credential: String, clientLabel: String) async throws -> T3PairingResult {
        guard let primary = routes.first else { throw T3PairingError.invalidOrigin }
        let input = try Self.parse(primary.absoluteString, credential: credential)
        let alternates = PairingRoutes.unique(try routes.map { try Self.validatedOrigin($0.absoluteString) })
            .filter { !PairingRoutes.same($0, input.origin) }
        let fields = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", input.credential),
            ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
            ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
            ("client_label", clientLabel), ("client_device_type", "mobile"), ("client_os", "ios")
        ]
        let form = fields.map { Self.formEncode($0.0) + "=" + Self.formEncode($0.1) }.joined(separator: "&")
        let ordered = PairingRoutes.ordered([input.origin] + alternates, lastReached: nil)
        let (origin, descriptor, token) = try await reach(ordered, environmentID: nil, isRouteFailure: Self.wasNotSent) { origin, descriptor in
            let post = try Self.prepare(origin: origin, path: "/oauth/token", method: "POST", body: Data(form.utf8),
                                        headers: ["Content-Type": "application/x-www-form-urlencoded"])
            try Task.checkCancellation()
            let data: Data, response: HTTPURLResponse
            do { (data, response) = try await transport(post) }
            catch {
                if Self.wasNotSent(error) { throw error }
                throw T3PairingError.codeMayBeUsed
            }
            // From here T3 may have redeemed the code, unless the reply is its own refusal.
            guard response.url == post.url, (200..<300).contains(response.statusCode) else {
                if Self.isCredentialRefusal(data, status: response.statusCode) { throw T3PairingError.httpStatus(response.statusCode) }
                throw T3PairingError.codeMayBeUsed
            }
            struct Token: Decodable { let access_token: String; let token_type: String }
            // A success spends the code, even when its token can't be read or used.
            guard let token = try? JSONDecoder().decode(Token.self, from: data), !token.access_token.isEmpty,
                  token.token_type == "Bearer" else { throw T3PairingError.codeMayBeUsed }
            return (origin, descriptor, token.access_token)
        }
        let t3 = T3Connection(environmentID: descriptor.environmentId, label: descriptor.label, accessToken: token)
        var configuration = ConnectionConfiguration(serverURL: input.origin, installID: descriptor.environmentId, t3: t3,
                                                    alternateRoutes: alternates.isEmpty ? nil : alternates)
        configuration.reached(origin)
        return T3PairingResult(accessToken: token, environmentDescriptor: descriptor, configuration: configuration)
    }

    /// The request failed before any of it could reach the host.
    nonisolated static func wasNotSent(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .badURL, .unsupportedURL,
                .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection,
                .internationalRoamingOff, .dataNotAllowed, .callIsActive].contains(error.code)
    }

    /// T3 itself refused the credential, so this request didn't redeem it. T3's token endpoint answers
    /// an unknown or already used credential with 401 `auth_invalid` (`EnvironmentAuthInvalidError` in
    /// packages/contracts/src/environmentHttp.ts, raised from the token handler in
    /// apps/server/src/auth/http.ts). Other errors aren't this: T3 can return 400 `invalid_request` or
    /// 500 `internal_error` after the credential was consumed, and a relay's error may follow a request
    /// it passed on.
    nonisolated static func isCredentialRefusal(_ data: Data, status: Int) -> Bool {
        struct Refusal: Decodable { let code: String }
        return status == 401 && (try? JSONDecoder().decode(Refusal.self, from: data))?.code == "auth_invalid"
    }

    public func mintWebSocketTicket(origin: URL, accessToken: String) async throws -> T3WebSocketTicket {
        let data = try await request(origin: origin, path: "/api/auth/websocket-ticket/rpc",
                                     method: "POST", token: accessToken)
        struct Ticket: Decodable { let ticket: String; let expiresAt: String }
        guard let value = try? JSONDecoder().decode(Ticket.self, from: data), !value.ticket.isEmpty,
              let expiration = Self.date(value.expiresAt) else { throw T3PairingError.invalidResponse }
        return T3WebSocketTicket(ticket: value.ticket, expiresAt: expiration)
    }

    nonisolated static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
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

    public nonisolated static let requestTimeout: TimeInterval = 30

    func request(origin: URL, path: String, method: String = "GET", token: String? = nil,
                 body: Data? = nil, headers: [String: String] = [:], timeout: TimeInterval = requestTimeout) async throws -> Data {
        let request = try Self.prepare(origin: origin, path: path, method: method, token: token, body: body,
                                       headers: headers, timeout: timeout)
        let (data, response) = try await transport(request)
        if (300..<400).contains(response.statusCode) || response.url != request.url { throw T3PairingError.redirected }
        guard (200..<300).contains(response.statusCode) else { throw T3PairingError.httpStatus(response.statusCode) }
        return data
    }

    nonisolated static func prepare(origin: URL, path: String, method: String, token: String? = nil, body: Data?,
                                    headers: [String: String], timeout: TimeInterval = requestTimeout) throws -> URLRequest {
        let origin = try validatedOrigin(origin.absoluteString)
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              let endpoint = URL(string: path, relativeTo: origin)?.absoluteURL,
              try validatedOrigin(endpoint.absoluteString) == origin,
              let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.fragment == nil else { throw T3PairingError.invalidOrigin }
        guard let url = components.url else { throw T3PairingError.invalidOrigin }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func parameter(_ name: String, from items: [URLQueryItem]?) -> String? {
        items?.first(where: { $0.name == name })?.value
    }

    private static func formEncode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._")
        return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(of: "%20", with: "+")
    }

    private static let directSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: T3RejectRedirects(), delegateQueue: nil)
    }()

    public static func directHTTP(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await directHTTP(request, in: directSession)
    }

    static func directHTTP(_ request: URLRequest, in session: URLSession) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path.hasPrefix("/api/assets/") == true {
            return try await BoundedHTTPReceiver.receive(request, in: session, limit: DownloadedArtifact.maximumBytes,
                                                         limitError: .artifactTooLarge)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw T3PairingError.invalidResponse }
        return (data, response)
    }
}

nonisolated final class T3RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
