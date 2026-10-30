// Native broker flow adapted from Hermex, Copyright (c) 2026 Uzair Ansar (MIT).
// See LICENSES/Hermex.txt. Botto adds strict probes, origin pinning and transient tokens.
import CryptoKit
import Foundation

/// One reviewed destination and one native code redemption. Does not save configuration.
@MainActor public final class NativeSignInExchange {
    public enum Failure: Error, Equatable, LocalizedError {
        case browserUnsupported, invalidResponse, redirected, differentHost, network, closed
        case rejected(Int)

        public var errorDescription: String? {
            switch self {
            case .browserUnsupported: "This server does not offer native browser sign-in."
            case .invalidResponse: "The server returned an unsupported sign-in response."
            case .redirected: "The server redirected a native request. Use its final HTTPS origin. Cloudflare Access may require an interactive browser policy."
            case .differentHost: "The server installation changed during sign-in. Review the address and start again."
            case .network: "Couldn’t reach this Hermes server. Check its address and network access."
            case .closed: "This sign-in attempt has ended. Start a new sign-in."
            case .rejected(let status): "The server refused sign-in (HTTP \(status)). Check Hermes and Cloudflare Access settings."
            }
        }
    }

    public let serverURL: URL
    private let headers: [String: String]
    private let transport: any HermesTransport
    private var status: Status?
    private var closed = false
    private var redeemed = false

    /// The caller must obtain explicit HTTP consent before passing a local HTTP URL.
    public convenience init(serverURL: URL, connectionHeaders: [String: String] = [:]) throws {
        let transport = NativeHermesTransport()
        do { try self.init(serverURL: serverURL, connectionHeaders: connectionHeaders, transport: transport) }
        catch { transport.invalidate(); throw error }
    }

    init(serverURL: URL, connectionHeaders: [String: String] = [:], transport: any HermesTransport) throws {
        let origin = try PairingAddress.parse(serverURL.absoluteString, allowInsecureHTTP: true)
        guard HermesHeaderPolicy.isValid(connectionHeaders) else { throw PairingAddress.Failure.invalidAddress }
        self.serverURL = origin
        headers = connectionHeaders
        self.transport = transport
    }

    /// Public, unauthenticated Hermes capability and interactive-provider probes.
    public func probe() async throws {
        try check()
        guard status == nil, !redeemed else { throw Failure.closed }
        let status: Status = try await json("api/status")
        guard status.installID?.isEmpty != true, HermesProtocolVersion.isSupported(status.version) else { throw Failure.invalidResponse }
        guard status.authRequired, status.authFlows.contains("native_pkce"), !status.authProviders.isEmpty else {
            throw Failure.browserUnsupported
        }
        let providers: Providers = try await json("api/auth/providers")
        guard !providers.providers.isEmpty,
              providers.providers.allSatisfy({ !$0.name.isEmpty && status.authProviders.contains($0.name) })
        else { throw Failure.browserUnsupported }
        self.status = status
    }

    /// The native broker's authorize URL. The app owns the matching state and receiver.
    public func authorizationURL(verifier: String, state: String, loopbackPort: UInt16) throws -> URL {
        try check()
        guard status != nil, !redeemed else { throw Failure.closed }
        guard Self.isURLSafe(verifier, minimum: 43, maximum: 128),
              Self.isURLSafe(state, minimum: 16, maximum: 128), loopbackPort > 0 else { throw Failure.invalidResponse }
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard var parts = URLComponents(url: serverURL.appendingPathComponent("auth/native/authorize"), resolvingAgainstBaseURL: false)
        else { throw Failure.invalidResponse }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let fields = [("code_challenge", challenge), ("code_challenge_method", "S256"),
            ("redirect_uri", "http://127.0.0.1:\(loopbackPort)/callback"), ("state", state)]
        parts.percentEncodedQuery = fields.map { name, value in
            name + "=" + value.addingPercentEncoding(withAllowedCharacters: unreserved)!
        }.joined(separator: "&")
        guard let url = parts.url else { throw Failure.invalidResponse }
        return url
    }

    /// Redeems only against the probed origin. Retains only the returned refresh credential.
    public func configuration(code: String, verifier: String) async throws -> ConnectionConfiguration {
        try check()
        guard let status, !redeemed else { throw Failure.closed }
        guard Self.isURLSafe(code, minimum: 1, maximum: 1_024), Self.isURLSafe(verifier, minimum: 43, maximum: 128)
        else { throw Failure.invalidResponse }
        redeemed = true
        let current: Status = try await json("api/status")
        if let expected = status.installID, current.installID != expected { throw Failure.differentHost }
        let body = try JSONEncoder().encode(Redemption(code: code, codeVerifier: verifier))
        let tokens: Tokens = try await json("auth/native/token", body: body)
        guard !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty,
              status.authProviders.contains(tokens.provider), !tokens.userID.isEmpty, tokens.tokenType == "Bearer",
              tokens.accessToken.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw Failure.invalidResponse }
        let identity: Identity = try await json("api/auth/me", bearer: tokens.accessToken)
        guard identity.provider == tokens.provider, identity.userID == tokens.userID else { throw Failure.invalidResponse }
        var installID = current.installID
        if status.installID == nil {
            let authenticated: Status = try await json("api/status", bearer: tokens.accessToken)
            guard let verified = authenticated.installID, !verified.isEmpty else { throw Failure.invalidResponse }
            if let expected = current.installID, verified != expected { throw Failure.differentHost }
            installID = verified
        }
        guard let installID, !installID.isEmpty else { throw Failure.invalidResponse }
        return ConnectionConfiguration(serverURL: serverURL, username: tokens.userID, installID: installID,
            nativeCredential: NativeCredential(refreshToken: tokens.refreshToken, provider: tokens.provider),
            connectionHeaders: headers)
    }

    public func close() {
        closed = true
        status = nil
        transport.invalidate()
    }

    private func check() throws {
        try Task.checkCancellation()
        if closed { throw Failure.closed }
    }

    private static func isURLSafe(_ value: String, minimum: Int, maximum: Int) -> Bool {
        (minimum...maximum).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95, 126].contains($0)
        }
    }

    private func json<Value: Decodable>(_ path: String, body: Data? = nil, bearer: String? = nil) async throws -> Value {
        try check()
        let url = serverURL.appendingPathComponent(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        do {
            let (data, response) = try await transport.data(for: request)
            try check()
            guard response.url == url, !(300..<400).contains(response.statusCode) else { throw Failure.redirected }
            guard (200..<300).contains(response.statusCode) else { throw Failure.rejected(response.statusCode) }
            guard data.count <= 128 * 1_024 else { throw Failure.invalidResponse }
            do { return try JSONDecoder().decode(Value.self, from: data) }
            catch { throw Failure.invalidResponse }
        } catch let error as Failure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch HermesServiceError.redirected { throw Failure.redirected }
        catch { throw Failure.network }
    }

    private struct Status: Decodable {
        let version: String
        let installID: String?
        let authRequired: Bool
        let authProviders: [String]
        let authFlows: [String]
        enum CodingKeys: String, CodingKey {
            case version, installID = "install_id", authRequired = "auth_required"
            case authProviders = "auth_providers", authFlows = "auth_flows"
        }
    }
    private struct Providers: Decodable {
        struct Provider: Decodable { let name: String }
        let providers: [Provider]
    }
    private struct Redemption: Encodable {
        let code: String
        let codeVerifier: String
        enum CodingKeys: String, CodingKey { case code, codeVerifier = "code_verifier" }
    }
    private struct Tokens: Decodable {
        let accessToken: String
        let refreshToken: String
        let tokenType: String
        let provider: String
        let userID: String
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", tokenType = "token_type", provider, userID = "user_id"
        }
    }
    private struct Identity: Decodable {
        let provider: String
        let userID: String
        enum CodingKeys: String, CodingKey { case provider, userID = "user_id" }
    }
}
