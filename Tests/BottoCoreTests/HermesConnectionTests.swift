import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [false, true], ["fixture-install", "replacement-install", ""])
func signedOutWebappStatusLearnsInstallationAfterAuthentication(native: Bool, authenticatedInstall: String) async throws {
    let transport = ScriptedTransport()
    var authenticated = false
    transport.handler = { request in
        switch request.url!.path {
        case "/api/status":
            var status = try fixture("status")
            status["version"] = .string("0.22.5")
            status["install_id"] = authenticated ? .string(authenticatedInstall) : .null
            return status
        case "/auth/password-login": authenticated = true; return .object(["ok": .bool(true)])
        case "/auth/native/refresh":
            authenticated = true
            return .object(["access_token": .string("new-access"), "refresh_token": .string("new-refresh"),
                "provider": .string("basic"), "user_id": .string("alice")])
        case "/api/auth/me": return .object(["provider": .string("basic"), "user_id": .string("alice")])
        default: throw HermesServiceError.incompatible
        }
    }
    let configuration = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!,
        username: "alice", password: native ? "" : "test-password", installID: "fixture-install",
        nativeCredential: native ? .init(refreshToken: "old-refresh", provider: "basic") : nil)
    let connection = try HermesHTTPConnection(configuration: configuration, transport: transport)
    if authenticatedInstall == "fixture-install" {
        let info = try await connection.authenticate()
        #expect(info.version == "0.22.5" && info.installID == "fixture-install")
    } else {
        let expected: HermesServiceError = authenticatedInstall.isEmpty ? .incompatible : .differentHost
        await #expect(throws: expected) { try await connection.authenticate() }
    }
    #expect(connection.configuration.installID == "fixture-install")
    #expect(transport.requests.map { $0.url!.path } == ["/api/status",
        native ? "/auth/native/refresh" : "/auth/password-login", "/api/auth/me", "/api/status"])
    if native { #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new-access") }
}

@MainActor @Test func savedInstallMismatchNeverSendsCredentials() async throws {
    let transport = ScriptedTransport()
    transport.handler = { request in
        if request.url!.path == "/api/status" { return try fixture("status") }
        return .object(["provider": .string("basic"), "user_id": .string("alice")])
    }
    let configuration = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!,
        username: "alice", password: "private-password", installID: "saved-other-host")
    let connection = try HermesHTTPConnection(configuration: configuration, transport: transport)
    await #expect(throws: HermesServiceError.differentHost) { try await connection.authenticate() }
    #expect(transport.requests.map { $0.url!.path } == ["/api/status"])
    #expect(transport.requests.allSatisfy { $0.httpBody == nil })
}

func fixture(_ name: String) throws -> HermesJSON {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/HermesAgent")!
    return try HermesJSON.decode(Data(contentsOf: url))
}

@MainActor final class ScriptedTransport: HermesTransport {
    var requests: [URLRequest] = []
    var handler: ((URLRequest) throws -> HermesJSON)?
    var asyncHandler: ((URLRequest) async throws -> HermesJSON)?
    var responseStatus = 200
    var responseURL: URL?
    var makeSocket: ((URLRequest) throws -> any HermesSocket)?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let json: HermesJSON
        if let asyncHandler { json = try await asyncHandler(request) }
        else { json = try handler?(request) ?? .object([:]) }
        return (try json.data, HTTPURLResponse(url: responseURL ?? request.url!, statusCode: responseStatus, httpVersion: nil, headerFields: nil)!)
    }
    func socket(for request: URLRequest) throws -> any HermesSocket {
        guard let makeSocket else { throw HermesServiceError.disconnected }
        return try makeSocket(request)
    }
    func invalidate() {}
}

@MainActor @Test func unsupportedVersionStopsBeforePasswordOrRefresh() async throws {
    for native in [false, true] {
        let transport = ScriptedTransport()
        transport.handler = { _ in var status = try fixture("status"); status["version"] = .string("0.20.0"); return status }
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, username: "alice", password: "secret",
            nativeCredential: native ? NativeCredential(refreshToken: "private-refresh", provider: "basic") : nil)
        let connection = try HermesHTTPConnection(configuration: configuration, transport: transport)
        await #expect(throws: HermesServiceError.incompatible) { try await connection.authenticate() }
        #expect(transport.requests.map { $0.url!.path } == ["/api/status"])
    }
}

@MainActor @Test func nativeRotationIsSavedBeforeBearerUseAndCanAbortOnStorageFailure() async throws {
    for abort in [false, true] {
        let transport = ScriptedTransport()
        var persisted = false
        transport.handler = { request in
            switch request.url!.path {
            case "/api/status":
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return try fixture("status")
            case "/auth/native/refresh":
                #expect(!persisted)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                let body = try HermesJSON.decode(request.httpBody!)
                #expect(body["refresh_token"].text == "old-refresh")
                return .object(["access_token": .string("new-access"), "refresh_token": .string("new-refresh"),
                    "provider": .string("basic"), "user_id": .string("alice")])
            case "/api/auth/me":
                #expect(persisted)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
                return .object(["provider": .string("basic"), "user_id": .string("alice")])
            default: return .object([:])
            }
        }
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, username: "alice", installID: "fixture-install",
            nativeCredential: NativeCredential(refreshToken: "old-refresh", provider: "basic"))
        let connection = try HermesHTTPConnection(configuration: configuration, transport: transport)
        connection.onConfiguration = { [weak connection] value in
            #expect(value.nativeCredential?.refreshToken == "new-refresh")
            persisted = true
            if abort { connection?.retire() }
        }
        if abort {
            await #expect(throws: HermesServiceError.disconnected) { try await connection.authenticate() }
            #expect(transport.requests.count == 2)
        } else { _ = try await connection.authenticate(); #expect(transport.requests.count == 3) }
        #expect(persisted)
    }
}

@MainActor @Test func cloudflareHeadersStayAllowlistedAndRedirectsNeverAuthenticate() async throws {
    let transport = ScriptedTransport()
    transport.responseStatus = 302
    transport.responseURL = URL(string: "https://other.example/login")
    let configuration = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, username: "alice", password: "password",
        connectionHeaders: ["CF-Access-Client-Id": "client-id", "CF-Access-Client-Secret": "private-proxy-secret"])
    let connection = try HermesHTTPConnection(configuration: configuration, transport: transport)
    await #expect(throws: HermesServiceError.redirected) { try await connection.authenticate() }
    #expect(transport.requests.count == 1)
    #expect(transport.requests[0].url?.host == "hermes.example")
    #expect(transport.requests[0].httpBody == nil)
    #expect(transport.requests[0].value(forHTTPHeaderField: "CF-Access-Client-Secret") == "private-proxy-secret")
    for bad in [["Authorization": "Bearer stolen"], ["Cookie": "foo=bar"], ["CF-Access-Client-Id": "x\r\nInjected: yes"]] {
        var changed = configuration; changed.connectionHeaders = bad
        #expect(throws: HermesServiceError.invalidAddress) { try HermesHTTPConnection(configuration: changed, transport: transport) }
    }
}

@MainActor @Test func cloudflareHeadersReachAuthAndSocketAtSameOrigin() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    var configuration = host.configuration
    configuration.connectionHeaders = ["CF-Access-Client-Id": "client-id", "CF-Access-Client-Secret": "secret"]
    _ = try await service.connect(configuration: configuration)
    #expect(host.transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client-id" })
    #expect(host.upgrades[0].value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
}

@MainActor @Test func directConfigurationCannotBypassStrictAddressPolicy() throws {
    let transport = ScriptedTransport()
    for text in ["https://user:secret@example.com", "https://example.com/api", "https://example.com?secret=x", "https://example.com/#fragment", "https://999.1.1.1"] {
        let configuration = ConnectionConfiguration(serverURL: URL(string: text)!)
        #expect(throws: HermesServiceError.invalidAddress) { try HermesHTTPConnection(configuration: configuration, transport: transport) }
    }
    #expect(throws: HermesServiceError.insecureAddress) {
        try HermesHTTPConnection(configuration: ConnectionConfiguration(serverURL: URL(string: "http://public.example")!), transport: transport)
    }
    for text in ["http://127.0.0.1:9119", "http://192.168.1.2", "http://[::1]:9119", "http://100.64.0.2", "https://example.com"] {
        _ = try HermesHTTPConnection(configuration: ConnectionConfiguration(serverURL: URL(string: text)!), transport: transport)
    }
}

@MainActor @Test func httpAddressValidationUsesNormalizedPairingOriginGrammar() throws {
    let transport = ScriptedTransport()
    let uppercase = try HermesHTTPConnection(configuration: ConnectionConfiguration(serverURL: URL(string: "HTTPS://EXAMPLE.COM")!), transport: transport)
    #expect(uppercase.configuration.serverURL.absoluteString == "https://example.com")
    _ = try HermesHTTPConnection(configuration: ConnectionConfiguration(serverURL: URL(string: "https://[fc00::1]")!), transport: transport)
    _ = try HermesHTTPConnection(configuration: ConnectionConfiguration(serverURL: URL(string: "http://[fc00::1]")!), transport: transport)
    _ = try HermesHTTPConnection(configuration: ConnectionConfiguration(serverURL: URL(string: "http://[febf::1]")!), transport: transport)
}

@MainActor @Test func httpHeaderPolicyRejectsDuplicateCasefoldedNamesAndOversizedValues() throws {
    let transport = ScriptedTransport()
    var configuration = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!)
    configuration.connectionHeaders = ["CF-Access-Client-Id": "a", "cf-access-client-id": "b"]
    #expect(throws: HermesServiceError.invalidAddress) { try HermesHTTPConnection(configuration: configuration, transport: transport) }
    configuration.connectionHeaders = ["CF-Access-Client-Id": String(repeating: "x", count: 4_097)]
    #expect(throws: HermesServiceError.invalidAddress) { try HermesHTTPConnection(configuration: configuration, transport: transport) }
}

@MainActor @Test func retiringDuringRefreshStillPersistsRotationBeforeReplacementSignsIn() async throws {
    let host = try HermesTestHost()
    var refreshWaiter: CheckedContinuation<Void, Never>?
    var refreshes: [String] = []
    host.transport.asyncHandler = { request in
        switch request.url!.path {
        case "/api/status": return try fixture("status")
        case "/auth/native/refresh":
            let token = try HermesJSON.decode(request.httpBody!)["refresh_token"].text!
            refreshes.append(token)
            if refreshes.count == 1 { await withCheckedContinuation { refreshWaiter = $0 } }
            return .object(["access_token": .string("access"), "refresh_token": .string(token == "initial" ? "rotated-once" : "rotated-twice"),
                "provider": .string("basic"), "user_id": .string("alice")])
        case "/api/auth/me": return .object(["provider": .string("basic"), "user_id": .string("alice")])
        case "/api/auth/ws-ticket": return .object(["ticket": .string("ticket")])
        default: return .object([:])
        }
    }
    let service = host.service(); defer { service.disconnect() }
    var configuration = host.configuration
    configuration.password = ""; configuration.nativeCredential = NativeCredential(refreshToken: "initial", provider: "basic")
    var saved: [String] = []
    service.onEvent = { if case .configuration(let value) = $0 { saved.append(value.nativeCredential!.refreshToken) } }
    let first = Task { try await service.connect(configuration: configuration) }
    try await eventually { refreshWaiter != nil }
    service.disconnect()
    let second = Task { try await service.connect(configuration: configuration) }
    await Task.yield()
    #expect(refreshes == ["initial"])
    refreshWaiter?.resume(); refreshWaiter = nil
    _ = try? await first.value
    _ = try await second.value
    #expect(refreshes == ["initial", "rotated-once"])
    #expect(saved == ["rotated-once", "rotated-twice"])
}

@MainActor @Test func normalizedHTTPSOriginReachesHTTPAndSecureSocket() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    var configuration = host.configuration
    configuration.serverURL = URL(string: "HTTPS://HERMES.EXAMPLE/")!
    _ = try await service.connect(configuration: configuration)
    #expect(host.transport.requests.allSatisfy { $0.url?.absoluteString.hasPrefix("https://hermes.example/") == true })
    #expect(host.upgrades.first?.url?.absoluteString == "wss://hermes.example/api/ws")
}
