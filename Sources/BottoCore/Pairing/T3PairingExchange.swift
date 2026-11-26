import Foundation

public struct T3PairingInput: Equatable, Sendable {
    public let origin: URL
    public let credential: String
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
    case invalidOrigin, missingCredential, redirected, incompatibleProtocol, invalidResponse, unsupportedToken
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: "Enter a valid HTTP or HTTPS environment address."
        case .missingCredential: "Enter a T3 Code pairing credential."
        case .redirected: "The T3 Code environment redirected the request."
        case .incompatibleProtocol: "This environment must support T3 orchestration protocol 2."
        case .invalidResponse: "The T3 Code environment returned an invalid response."
        case .unsupportedToken: "This pairing credential requires a different authentication method."
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
        return T3PairingInput(origin: origin, credential: credential)
    }

    public func probeEnvironment(origin: URL) async throws -> T3EnvironmentDescriptor {
        let data = try await request(origin: origin, path: "/.well-known/t3/environment")
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
        let input = try Self.parse(origin.absoluteString, credential: credential)
        let descriptor = try await probeEnvironment(origin: input.origin)
        let fields = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", input.credential),
            ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
            ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
            ("client_label", clientLabel), ("client_device_type", "mobile"), ("client_os", "ios")
        ]
        let form = fields.map { Self.formEncode($0.0) + "=" + Self.formEncode($0.1) }.joined(separator: "&")
        let data = try await request(origin: input.origin, path: "/oauth/token", method: "POST",
                                     body: Data(form.utf8), headers: ["Content-Type": "application/x-www-form-urlencoded"])
        struct Token: Decodable { let access_token: String; let token_type: String }
        guard let token = try? JSONDecoder().decode(Token.self, from: data),
              !token.access_token.isEmpty else { throw T3PairingError.invalidResponse }
        guard token.token_type == "Bearer" else { throw T3PairingError.unsupportedToken }
        let t3 = T3Connection(environmentID: descriptor.environmentId, label: descriptor.label, accessToken: token.access_token)
        let configuration = ConnectionConfiguration(serverURL: input.origin, installID: descriptor.environmentId, t3: t3)
        return T3PairingResult(accessToken: token.access_token, environmentDescriptor: descriptor, configuration: configuration)
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

    func request(origin: URL, path: String, method: String = "GET", token: String? = nil,
                 body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        let origin = try Self.validatedOrigin(origin.absoluteString)
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              let endpoint = URL(string: path, relativeTo: origin)?.absoluteURL,
              try Self.validatedOrigin(endpoint.absoluteString) == origin,
              let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.fragment == nil else { throw T3PairingError.invalidOrigin }
        guard let url = components.url else { throw T3PairingError.invalidOrigin }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport(request)
        if (300..<400).contains(response.statusCode) || response.url != url { throw T3PairingError.redirected }
        guard (200..<300).contains(response.statusCode) else { throw T3PairingError.httpStatus(response.statusCode) }
        return data
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
