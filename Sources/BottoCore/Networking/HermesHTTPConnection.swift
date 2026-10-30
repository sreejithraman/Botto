import Foundation

@MainActor final class HermesHTTPConnection {
    let transport: any HermesTransport
    private(set) var configuration: ConnectionConfiguration
    private var pageToken: String?
    private var accessToken: String?
    private var refreshing = false
    private var refreshTask: Task<HermesJSON, Error>?
    var onConfiguration: ((ConnectionConfiguration) -> Void)?
    private var retired = false

    init(configuration: ConnectionConfiguration, transport: any HermesTransport) throws {
        var normalized = configuration
        normalized.serverURL = try Self.validate(configuration.serverURL)
        guard HermesHeaderPolicy.isValid(configuration.connectionHeaders) else { throw HermesServiceError.invalidAddress }
        self.configuration = normalized
        self.transport = transport
    }

    func authenticate() async throws -> ServerInfo {
        let status = try await json("api/status")
        guard let version = status["version"].nonempty,
              let required = status["auth_required"].flag else { throw HermesServiceError.incompatible }
        var install = status["install_id"].nonempty
        guard status["install_id"] == .null || install != nil else { throw HermesServiceError.incompatible }
        if let install, let expected = configuration.installID, expected != install { throw HermesServiceError.differentHost }
        guard HermesProtocolVersion.isSupported(version) else { throw HermesServiceError.incompatible }
        if required, let credential = configuration.nativeCredential {
            guard !credential.refreshToken.isEmpty, !credential.provider.isEmpty else { throw HermesServiceError.authentication }
            // The unstructured exchange survives cancellation of its waiting connect task.
            // It owns saving the rotation; a replacement connection waits for it below.
            let rotation = refreshTask ?? Task { try await self.rotate(credential, install: install) }
            refreshTask = rotation
            let tokens = try await rotation.value
            try check()
            let identity = try await json("api/auth/me")
            guard identity["provider"].text == credential.provider,
                  identity["user_id"].text == tokens["user_id"].text,
                  configuration.username.isEmpty || identity["user_id"].text == configuration.username
            else { throw HermesServiceError.authentication }
        } else if required {
            guard status["auth_providers"].list?.contains(.string("basic")) == true else {
                throw HermesServiceError.browserAuthentication
            }
            guard !configuration.username.isEmpty, !configuration.password.isEmpty else { throw HermesServiceError.authentication }
            do {
                _ = try await json("auth/password-login", body: ["provider": .string("basic"),
                    "username": .string(configuration.username), "password": .string(configuration.password)])
            } catch HermesServiceError.rejected(401) { throw HermesServiceError.authentication }
            let identity = try await json("api/auth/me")
            guard identity["provider"].text == "basic", identity["user_id"].text == configuration.username else { throw HermesServiceError.authentication }
        } else {
            guard install != nil else { throw HermesServiceError.incompatible }
            guard configuration.username.isEmpty, configuration.password.isEmpty, configuration.nativeCredential == nil else { throw HermesServiceError.authentication }
            let page = try await request("")
            let html = String(decoding: page, as: UTF8.self)
            guard let match = html.firstMatch(of: /__HERMES_SESSION_TOKEN__\s*=\s*"([^"\\]+)"/),
                  !match.1.isEmpty else { throw HermesServiceError.incompatible }
            pageToken = String(match.1)
            _ = try await json("api/profiles/active")
        }
        // Webapp's signed-out status hides the installation identity (Hermes fd9ff2a0).
        // Authenticate only at the reviewed origin, then verify identity before releasing access.
        if install == nil { install = try await json("api/status")["install_id"].nonempty }
        guard let install else { throw HermesServiceError.incompatible }
        if let expected = configuration.installID, expected != install { throw HermesServiceError.differentHost }
        let info = ServerInfo(version: version, installID: install)
        if configuration.installID == nil { configuration.installID = install; onConfiguration?(configuration) }
        try check()
        return info
    }

    func upgrade() async throws -> URLRequest {
        var parts = URLComponents(url: configuration.serverURL.appendingPathComponent("api/ws"), resolvingAgainstBaseURL: false)!
        parts.scheme = configuration.serverURL.scheme == "https" ? "wss" : "ws"
        var ticket: String?
        if let pageToken { parts.queryItems = [URLQueryItem(name: "token", value: pageToken)] }
        else {
            let reply = try await json("api/auth/ws-ticket", body: [:])
            guard let value = reply["ticket"].nonempty,
                  value.utf8.allSatisfy({ (33...126).contains($0) && $0 != 44 }) else { throw HermesServiceError.incompatible }
            ticket = value
        }
        try check()
        guard let url = parts.url else { throw HermesServiceError.invalidAddress }
        var request = URLRequest(url: url)
        applyHeaders(to: &request)
        if let ticket { request.setValue("hermes-gateway-v1, hermes-gateway-ticket." + ticket, forHTTPHeaderField: "Sec-WebSocket-Protocol") }
        return request
    }

    func json(_ path: String, body: [String: HermesJSON]? = nil, query: [URLQueryItem] = [],
              validate: (() throws -> Void)? = nil) async throws -> HermesJSON {
        try HermesJSON.decode(await request(path, body: body, query: query, validate: validate))
    }

    // Native artifact route and reference rules adapted from Hermex HermesREST.swift
    // and BotArtifact.swift. MIT; see LICENSES/Hermex.txt.
    func downloadArtifact(path: String, profile: String, sessionID: String) async throws -> DownloadedArtifact {
        try Task.checkCancellation()
        try check()
        let path = try HermesArtifactMetadata.path(path)
        guard !profile.isEmpty, !sessionID.isEmpty else { throw HermesServiceError.invalidAttachment }
        var parts = URLComponents(url: configuration.serverURL.appendingPathComponent("api/fs/download"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "profile", value: profile),
                            URLQueryItem(name: "session_id", value: sessionID)]
        // Hermes form-decodes the query: literal plus signs must survive that hop.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw HermesServiceError.invalidAttachment }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        applyHeaders(to: &request)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let pageToken { request.setValue(pageToken, forHTTPHeaderField: "X-Hermes-Session-Token") }
        do {
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            try check()
            guard !(300..<400).contains(response.statusCode), response.url == request.url else { throw HermesServiceError.redirected }
            guard response.statusCode == 200 else { throw HermesServiceError.rejected(response.statusCode) }
            guard data.count <= DownloadedArtifact.maximumBytes, response.expectedContentLength <= DownloadedArtifact.maximumBytes
            else { throw HermesServiceError.artifactTooLarge }
            return DownloadedArtifact(data: data, filename: HermesArtifactMetadata.filename(response: response, path: path),
                                      mimeType: HermesArtifactMetadata.mimeType(response: response))
        } catch let error as HermesServiceError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw HermesServiceError.disconnected }
    }

    private func request(_ path: String, body: [String: HermesJSON]? = nil, query: [URLQueryItem] = [],
                         validate: (() throws -> Void)? = nil) async throws -> Data {
        try check()
        var parts = URLComponents(url: path.isEmpty ? configuration.serverURL : configuration.serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw HermesServiceError.invalidAddress }
        var request = URLRequest(url: url)
        applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let pageToken { request.setValue(pageToken, forHTTPHeaderField: "X-Hermes-Session-Token") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try await Task.detached { try HermesJSON.object(body).data }.value
            try check()
        }
        try validate?()
        do {
            let (data, response) = try await transport.data(for: request)
            if path != "auth/native/refresh" { try check() }
            guard !(300..<400).contains(response.statusCode), response.url == request.url else { throw HermesServiceError.redirected }
            guard (200..<300).contains(response.statusCode) else { throw HermesServiceError.rejected(response.statusCode) }
            return data
        } catch let error as HermesServiceError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw HermesServiceError.disconnected }
    }

    private func applyHeaders(to request: inout URLRequest) {
        for (key, value) in configuration.connectionHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let accessToken { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
    }

    private func rotate(_ credential: NativeCredential, install: String?) async throws -> HermesJSON {
        refreshing = true
        defer { refreshing = false; if retired { transport.invalidate() } }
        let tokens = try await json("auth/native/refresh", body: ["refresh_token": .string(credential.refreshToken), "provider": .string(credential.provider)])
        guard let access = tokens["access_token"].nonempty, let refresh = tokens["refresh_token"].nonempty,
              let provider = tokens["provider"].nonempty, tokens["user_id"].nonempty != nil,
              access.utf8.allSatisfy({ (33...126).contains($0) }) else { throw HermesServiceError.incompatible }
        configuration.nativeCredential = NativeCredential(refreshToken: refresh, provider: provider)
        if let install { configuration.installID = install }
        // The host consumed the previous refresh token. Deliver this even after retirement.
        onConfiguration?(configuration)
        try check()
        guard provider == credential.provider else { throw HermesServiceError.authentication }
        accessToken = access
        return tokens
    }

    func finishRefresh() async { if let refreshTask { _ = try? await refreshTask.value } }

    func retire() { retired = true; pageToken = nil; accessToken = nil; if !refreshing { transport.invalidate() } }
    private func check() throws { if retired || Task.isCancelled { throw HermesServiceError.disconnected } }

    static func validate(_ url: URL) throws -> URL {
        // Share the QR/manual parser's strict origin grammar. Callers can construct
        // ConnectionConfiguration without going through the pairing UI.
        do { return try PairingAddress.parse(url.absoluteString, allowInsecureHTTP: true) }
        catch PairingAddress.Failure.insecureHTTP { throw HermesServiceError.insecureAddress }
        catch { throw HermesServiceError.invalidAddress }
    }
}

/// Interpret only file metadata. Neither attachment hints nor a filename imply a MIME type.
private enum HermesArtifactMetadata {
    /// File references are server paths, not addresses to fetch or local iOS URLs.
    /// Leave relative paths and ~ for Hermes to resolve in the originating session.
    static func path(_ raw: String) throws -> String {
        guard raw.utf8.count <= 16_384,
              !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
        else { throw HermesServiceError.invalidAttachment }
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.hasPrefix("//"), !value.hasPrefix("\\") else { throw HermesServiceError.invalidAttachment }
        if value.firstMatch(of: /^[A-Za-z]:[\\\/]/) != nil { return value }
        // History embeds descriptors with stable IDs when the host supplied no path.
        guard value.wholeMatch(of: /.+:(?:row|index):[0-9]+:image:[0-9]+/) == nil else { throw HermesServiceError.invalidAttachment }
        if value.lowercased().hasPrefix("file:") {
            guard let parts = URLComponents(string: value), parts.user == nil, parts.password == nil,
                  parts.port == nil, parts.query == nil, parts.fragment == nil,
                  parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost",
                  let decoded = parts.percentEncodedPath.removingPercentEncoding,
                  decoded.hasPrefix("/"), !decoded.hasPrefix("//") else { throw HermesServiceError.invalidAttachment }
            return try path(decoded)
        }
        guard value.firstMatch(of: /^[A-Za-z][A-Za-z0-9+\.\-]*:/) == nil else { throw HermesServiceError.invalidAttachment }
        return value
    }

    static func filename(response: HTTPURLResponse, path: String) -> String {
        let parameters = dispositionParameters(response.value(forHTTPHeaderField: "Content-Disposition") ?? "")
        if let extended = parameters["filename*"] {
            let pieces = extended.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if pieces.count == 3, pieces[0].lowercased() == "utf-8",
               let decoded = String(pieces[2]).removingPercentEncoding, safeFilename(decoded) { return decoded }
        }
        if let name = parameters["filename"], safeFilename(name) { return name }
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return safeFilename(name) ? name : "download"
    }

    static func mimeType(response: HTTPURLResponse) -> String {
        let value = (response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).lowercased()
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        let punctuation = "!#$%&'*+-.^_`|~"
        guard value.utf8.count <= 255, pieces.count == 2,
              pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
                  (48...57).contains($0) || (97...122).contains($0) || punctuation.utf8.contains($0)
              } }) else { return "application/octet-stream" }
        return value
    }

    private static func safeFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 240 &&
        !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" }) &&
        !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
    }

    private static func dispositionParameters(_ header: String) -> [String: String] {
        guard header.utf8.count <= 4096 else { return [:] }
        var fields: [String] = [], field = "", quoted = false, escaped = false
        for character in header {
            if escaped { field.append(character); escaped = false }
            else if character == "\\", quoted { escaped = true }
            else if character == "\"" { quoted.toggle() }
            else if character == ";", !quoted { fields.append(field); field = "" }
            else { field.append(character) }
        }
        guard !quoted, !escaped else { return [:] }
        fields.append(field)
        var result: [String: String] = [:]
        for field in fields.dropFirst() {
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            // Ambiguous duplicate metadata is not an authoritative name.
            guard result[key] == nil else { return [:] }
            result[key] = pieces[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
