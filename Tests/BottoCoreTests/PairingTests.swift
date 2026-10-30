import Foundation
import Testing
@testable import BottoCore

@Test func pairingReadsExactHermesHQFixtures() throws {
    // mrcharlesiv/hermes-hq at 2eca5a74, connect/test/{connect,qr}.test.mjs.
    #expect(try PairingAddress.parse("hermes://connect?url=https%3A%2F%2Fa.ts.net%3A10000").absoluteString
        == "https://a.ts.net:10000")
    #expect(try PairingAddress.parse("hermes://connect?url=https%3A%2F%2Fyour-mac.tailnet-name.ts.net%3A10000").absoluteString
        == "https://your-mac.tailnet-name.ts.net:10000")
}

@Test(arguments: [
    "", "https://", "https:example.com", "https:///example.com", "ftp://example.com",
    "https://user:password@example.com", "https://user@example.com", "https://example.com?token=private",
    "https://example.com?", "https://example.com#private", "https://example.com#",
    "https://example.com/api", "https://example.com/..", "https://example.com/%2e%2e",
    "https://example.com/%2f", "https://example.com/%5c", "https://example.com/%",
    "https://example.com/%GG", "https://example.com/%00", "https://example.com:0",
    "https://example.com:65536", "https://example.com:", "https://example.com:abc",
    "https://example.com\\@evil.example", " https://example.com", "https://example.com\n",
    "https://exam\tple.com", "https://example.com\u{7f}", "https://example.com\u{200b}",
    "https://%65xample.com", "https://example..com", "https://-example.com", "https://[garbage]",
    "https://127.1", "https://999.999.999.999",
    "hermes://connect?url=https%3A%2F%2Fa.ts.net&url=https%3A%2F%2Fevil.example",
    "hermes://connect?url=https%3A%2F%2Fa.ts.net&secret=private",
    "hermes://connect?url=", "hermes://connect", "hermes://connect?%75rl=https%3A%2F%2Fa.ts.net",
    "hermes://connect:?url=https%3A%2F%2Fa.ts.net", "botto://hermes:/connect?url=https%3A%2F%2Fa.ts.net",
    "hermes://user@connect?url=https%3A%2F%2Fa.ts.net", "hermes://connect:80?url=https%3A%2F%2Fa.ts.net",
    "hermes://connect/path?url=https%3A%2F%2Fa.ts.net", "hermes://connect?url=https%3A%2F%2Fa.ts.net#x",
    "hermes://connect?url=https%253A%252F%252Fa.ts.net",
    "hermes://connect?url=https%3A%2F%2Fuser%3Asecret%40a.ts.net",
    "hermes://connect?url=https%3A%2F%2Fa.ts.net%3Fsecret%3Dprivate",
    "hermes://connect?url=https%3A%2F%2Fa.ts.net%0A",
    "hermes://connect?url=https%3A%2F%2Fa.ts.net%5Cevil",
    "hermes://connect?url=https%3A%2F%2Fa.ts.net%2F%GG",
    "botto://connect?url=https%3A%2F%2Fa.ts.net", "botto://hermes/connect/extra?url=https%3A%2F%2Fa.ts.net",
    "botto://hermes/%63onnect?url=https%3A%2F%2Fa.ts.net", "botto://hermes/connect?url=https%3A%2F%2Fa.ts.net&token=x",
    "hot://hermes/connect?url=https%3A%2F%2Fa.ts.net", "botto-signin://done"
]) func pairingRejectsUntrustedInput(_ input: String) {
    #expect(throws: (any Error).self) { try PairingAddress.parse(input) }
}

@Test func pairingNormalizesOnlyOriginsAndAcceptsBottoLinks() throws {
    #expect(try PairingAddress.parse("https://HERMES.example/").absoluteString == "https://hermes.example")
    #expect(try PairingAddress.parse("botto://hermes/connect?url=https%3A%2F%2Fhermes.example%3A8443%2F").absoluteString
        == "https://hermes.example:8443")
    #expect(try PairingAddress.parse("https://[::1]:9119").absoluteString == "https://[::1]:9119")
    #expect(try PairingAddress.parse("https://my-host.trycloudflare.com").host == "my-host.trycloudflare.com")
    #expect(try PairingAddress.parse("https://192.168.1.2").host == "192.168.1.2")
}

@Test func pairingHTTPNeedsExplicitConsent() throws {
    #expect(throws: PairingAddress.Failure.insecureHTTP) { try PairingAddress.parse("http://192.168.1.2:9119") }
    #expect(try PairingAddress.parse("http://192.168.1.2:9119", allowInsecureHTTP: true).absoluteString
        == "http://192.168.1.2:9119")
    #expect(try PairingAddress.parse("hermes://connect?url=http%3A%2F%2Flocalhost%3A9119", allowInsecureHTTP: true).absoluteString
        == "http://localhost:9119")
    #expect(throws: PairingAddress.Failure.insecureHTTP) {
        try PairingAddress.parse("http://public.example", allowInsecureHTTP: true)
    }
    #expect(throws: PairingAddress.Failure.insecureHTTP) {
        try PairingAddress.parse("http://example.10.0.0.1", allowInsecureHTTP: true)
    }
    #expect(throws: PairingAddress.Failure.insecureHTTP) {
        try PairingAddress.parse("http://[fc::1]", allowInsecureHTTP: true)
    }
}

@Test func pairingBoundsInputWithoutDiscardingSecrets() {
    #expect(throws: PairingAddress.Failure.tooLong) {
        try PairingAddress.parse("https://hermes.example/" + String(repeating: "x", count: 4_096))
    }
    #expect(throws: PairingAddress.Failure.tooLong) {
        try PairingAddress.parse(String(repeating: "🦀", count: 1_025))
    }
    #expect(throws: PairingAddress.Failure.unsupportedPath) { try PairingAddress.parse("https://hermes.example/private-token") }
}

@Test func pairingAcceptsOnlyMatchingNativeCallback() throws {
    let request = Data("GET /callback?code=one_time-code&state=expected HTTP/1.1\r\nHost: 127.0.0.1:49152\r\nUser-Agent: Safari\r\n\r\n".utf8)
    #expect(try NativeSignInCallback.code(in: request, expectedState: "expected", port: 49152) == "one_time-code")
    #expect(throws: (any Error).self) { try NativeSignInCallback.code(in: request, expectedState: "other", port: 49152) }
    #expect(throws: (any Error).self) { try NativeSignInCallback.code(in: request, expectedState: "expected", port: 49153) }
}

@Test(arguments: [
    "GET /wrong?code=x&state=expected HTTP/1.1",
    "POST /callback?code=x&state=expected HTTP/1.1",
    "GET http://127.0.0.1:49152/callback?code=x&state=expected HTTP/1.1",
    "GET //evil.example/callback?code=x&state=expected HTTP/1.1",
    "GET /callback?code=x&state=expected&state=expected HTTP/1.1",
    "GET /callback?code=x&code=y HTTP/1.1",
    "GET /callback?code=x&state=wrong HTTP/1.1",
    "GET /callback?code=&state=expected HTTP/1.1",
    "GET /callback?code=x%00&state=expected HTTP/1.1",
    "GET /callback?code=x%ZZ&state=expected HTTP/1.1",
    "GET /callback?code=x&state=expected#fragment HTTP/1.1",
    "GET /callback?%63ode=x&state=expected HTTP/1.1",
    "GET /callback?code=x&state=expected HTTP/1.1\r\nHost: evil.example",
    "GET /callback?code=x&state=expected HTTP/1.1\r\nContent-Length: 1",
    "GET /callback?code=x&state=expected HTTP/1.1\r\nTransfer-Encoding: chunked"
]) func pairingRejectsUntrustedNativeCallback(_ line: String) {
    let request = Data((line + "\r\nHost: 127.0.0.1:49152\r\n\r\n").utf8)
    #expect(throws: (any Error).self) { try NativeSignInCallback.code(in: request, expectedState: "expected", port: 49152) }
}

@MainActor @Test(arguments: ["0.20.0", "not-a-version", ""])
func pairingNativeProbeRejectsUnsupportedVersionBeforeBrowser(version: String) async throws {
    let transport = PairingTransport()
    transport.override = { request in
        guard request.url!.path == "/api/status" else { return nil }
        var status = try pairingStatus()
        status["version"] = .string(version)
        return (status, 200, request.url!)
    }
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!, transport: transport)
    defer { exchange.close() }
    await #expect(throws: NativeSignInExchange.Failure.invalidResponse) { try await exchange.probe() }
    #expect(transport.requests.map { $0.url!.path } == ["/api/status"])
}

@MainActor @Test(arguments: [true, false])
func pairingNativeExchangeLearnsHiddenInstallationWithAuthenticatedStatus(identityAvailable: Bool) async throws {
    let transport = PairingTransport()
    transport.override = { request in
        guard request.url!.path == "/api/status" else { return nil }
        var status = try pairingStatus()
        if request.value(forHTTPHeaderField: "Authorization") == nil || !identityAvailable { status["install_id"] = .null }
        return (status, 200, request.url!)
    }
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!, transport: transport)
    defer { exchange.close() }
    try await exchange.probe()
    if identityAvailable {
        let result = try await exchange.configuration(code: "fixture-code", verifier: String(repeating: "v", count: 43))
        #expect(result.installID == "fixture-install")
        #expect(result.nativeCredential?.refreshToken == "fixture-refresh")
    } else {
        await #expect(throws: NativeSignInExchange.Failure.invalidResponse) {
            try await exchange.configuration(code: "fixture-code", verifier: String(repeating: "v", count: 43))
        }
    }
    #expect(transport.requests.last?.url?.path == "/api/status")
    #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
    #expect(transport.requests.filter { $0.url!.path == "/api/status" }.count == 3)
}

@MainActor @Test func pairingNativeExchangeProbesThenRedeemsAgainstReviewedOrigin() async throws {
    let transport = PairingTransport()
    let headers = ["CF-Access-Client-Id": "fixture-client-id", "CF-Access-Client-Secret": "fixture-client-secret"]
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example:8443")!,
        connectionHeaders: headers, transport: transport)
    defer { exchange.close() }
    try await exchange.probe()
    #expect(transport.requests.map { $0.url!.path } == ["/api/status", "/api/auth/providers"])
    #expect(transport.requests.allSatisfy { $0.httpBody == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })
    let result = try await exchange.configuration(code: "fixture-code", verifier: String(repeating: "v", count: 43))
    #expect(result.serverURL.absoluteString == "https://hermes.example:8443")
    #expect(result.installID == "fixture-install")
    #expect(result.password.isEmpty && result.username == "fixture-user")
    #expect(result.nativeCredential == NativeCredential(refreshToken: "fixture-refresh", provider: "basic"))
    #expect(result.connectionHeaders == headers)
    #expect(transport.requests.map { $0.url!.path } == [
        "/api/status", "/api/auth/providers", "/api/status", "/auth/native/token", "/api/auth/me"
    ])
    for request in transport.requests {
        #expect(request.url!.scheme == "https" && request.url!.host == "hermes.example" && request.url!.port == 8443)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "fixture-client-id")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "fixture-client-secret")
        #expect(!request.httpShouldHandleCookies)
    }
    let redemption = transport.requests[3]
    #expect(redemption.httpMethod == "POST")
    #expect(try HermesJSON.decode(#require(redemption.httpBody)) == .object([
        "code": .string("fixture-code"), "code_verifier": .string(String(repeating: "v", count: 43))
    ]))
    #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
    await #expect(throws: NativeSignInExchange.Failure.closed) {
        try await exchange.configuration(code: "replay", verifier: String(repeating: "v", count: 43))
    }
    #expect(transport.requests.count == 5)
}

@MainActor @Test func pairingNativeAuthorizationUsesRFC7636S256AndEncodedLoopback() async throws {
    let transport = PairingTransport()
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example:8443")!, transport: transport)
    defer { exchange.close() }
    try await exchange.probe()
    // https://www.rfc-editor.org/rfc/rfc7636.html#appendix-B
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    let url = try exchange.authorizationURL(verifier: verifier, state: "fixture-state-123456", loopbackPort: 49152)
    #expect(url.absoluteString == "https://hermes.example:8443/auth/native/authorize?code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fcallback&state=fixture-state-123456")
    #expect(transport.requests.count == 2) // Constructing the browser URL performs no request.
    #expect(!url.absoluteString.contains(verifier))
    #expect(throws: NativeSignInExchange.Failure.invalidResponse) {
        try exchange.authorizationURL(verifier: verifier, state: "bad state", loopbackPort: 49152)
    }
}

@MainActor @Test func pairingNativeExchangeNeedsProbeAndClosesExplicitly() async throws {
    let transport = PairingTransport()
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!, transport: transport)
    await #expect(throws: NativeSignInExchange.Failure.closed) {
        try await exchange.configuration(code: "unsolicited", verifier: String(repeating: "v", count: 43))
    }
    #expect(transport.requests.isEmpty)
    exchange.close()
    #expect(transport.invalidated)
    await #expect(throws: NativeSignInExchange.Failure.closed) { try await exchange.probe() }
    #expect(transport.requests.isEmpty)
}

@MainActor @Test func pairingNativeExchangeStopsBeforeRedeemingOnChangedInstall() async throws {
    let transport = PairingTransport()
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!, transport: transport)
    defer { exchange.close() }
    try await exchange.probe()
    transport.override = { request in
        guard request.url!.path == "/api/status" else { return nil }
        var status = try pairingStatus()
        status["install_id"] = .string("replacement-install")
        return (status, 200, request.url!)
    }
    await #expect(throws: NativeSignInExchange.Failure.differentHost) {
        try await exchange.configuration(code: "fixture-code", verifier: String(repeating: "v", count: 43))
    }
    #expect(!transport.requests.contains { $0.httpMethod == "POST" })
}

@MainActor @Test(arguments: [301, 302, 307, 308]) func pairingNativeExchangeRejectsRedirectsBeforeBrowser(_ status: Int) async throws {
    let transport = PairingTransport()
    transport.override = { request in (.object([:]), status, request.url!) }
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!, transport: transport)
    defer { exchange.close() }
    await #expect(throws: NativeSignInExchange.Failure.redirected) { try await exchange.probe() }
    #expect(transport.requests.count == 1 && transport.requests[0].httpBody == nil)
}

@MainActor @Test func pairingNativeExchangeRejectsCrossOriginResponseAndWrongIdentity() async throws {
    let transport = PairingTransport()
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!, transport: transport)
    defer { exchange.close() }
    transport.override = { _ in (try pairingStatus(), 200, URL(string: "https://evil.example/api/status")!) }
    await #expect(throws: NativeSignInExchange.Failure.redirected) { try await exchange.probe() }
    transport.override = nil
    try await exchange.probe()
    transport.override = { request in
        guard request.url!.path == "/api/auth/me" else { return nil }
        return (.object(["provider": .string("basic"), "user_id": .string("other-user")]), 200, request.url!)
    }
    await #expect(throws: NativeSignInExchange.Failure.invalidResponse) {
        try await exchange.configuration(code: "fixture-code", verifier: String(repeating: "v", count: 43))
    }
}

@MainActor @Test func pairingNativeExchangeRefusesUnsupportedHostsAndExpiredCode() async throws {
    let transport = PairingTransport()
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!, transport: transport)
    defer { exchange.close() }
    transport.override = { request in
        var status = try pairingStatus()
        status["auth_flows"] = .array([.string("cookie")])
        return (status, 200, request.url!)
    }
    await #expect(throws: NativeSignInExchange.Failure.browserUnsupported) { try await exchange.probe() }
    #expect(transport.requests.count == 1)
    transport.override = nil
    try await exchange.probe()
    transport.override = { request in
        request.url!.path == "/auth/native/token" ? (.object([:]), 400, request.url!) : nil
    }
    await #expect(throws: NativeSignInExchange.Failure.rejected(400)) {
        try await exchange.configuration(code: "expired-code", verifier: String(repeating: "v", count: 43))
    }
    #expect(transport.requests.last?.url?.path == "/auth/native/token")
}

@MainActor @Test func pairingNativeExchangeDoesNotContinueAfterTaskCancellation() async throws {
    let transport = PairingTransport()
    transport.override = { request in
        withUnsafeCurrentTask { $0?.cancel() }
        return (try pairingStatus(), 200, request.url!)
    }
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!, transport: transport)
    defer { exchange.close() }
    let task = Task { try await exchange.probe() }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(transport.requests.map { $0.url!.path } == ["/api/status"])
}

@MainActor @Test func pairingNativeExchangeRejectsRedirectedTokenPOST() async throws {
    let transport = PairingTransport()
    let exchange = try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!, transport: transport)
    defer { exchange.close() }
    try await exchange.probe()
    transport.override = { request in
        request.url!.path == "/auth/native/token" ? (.object([:]), 307, request.url!) : nil
    }
    await #expect(throws: NativeSignInExchange.Failure.redirected) {
        try await exchange.configuration(code: "fixture-code", verifier: String(repeating: "v", count: 43))
    }
    #expect(transport.requests.filter { $0.httpMethod == "POST" }.count == 1)
    #expect(transport.requests.last?.url?.absoluteString == "https://hermes.example/auth/native/token")
}

@MainActor @Test(arguments: [
    ["Authorization": "Bearer do-not-forward"],
    ["CF-Access-Client-Secret": "value\r\nInjected: x"],
    ["CF-Access-Client-Id": "a", "cf-access-client-id": "b"]
]) func pairingNativeExchangeValidatesServiceHeaders(_ headers: [String: String]) {
    #expect(throws: PairingAddress.Failure.invalidAddress) {
        try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!, connectionHeaders: headers, transport: PairingTransport())
    }
}

@MainActor @Test func pairingNativeExchangeUsesPairingOriginNormalizationAndHeaderCap() throws {
    let transport = PairingTransport()
    let exchange = try NativeSignInExchange(serverURL: URL(string: "HTTPS://EXAMPLE.COM")!, transport: transport)
    #expect(exchange.serverURL.absoluteString == "https://example.com")
    exchange.close()
    #expect(throws: PairingAddress.Failure.invalidAddress) {
        try NativeSignInExchange(serverURL: URL(string: "https://hermes.example")!,
            connectionHeaders: ["CF-Access-Client-Secret": String(repeating: "x", count: 4_097)], transport: transport)
    }
}

private func pairingStatus() throws -> HermesJSON {
    var status = try fixture("status")
    // The captured fixture redacts flow names. Restore the upstream advertised capability
    // from web_routers/status.py, without treating the redaction as a real auth flow.
    status["auth_flows"] = .array([.string("cookie"), .string("native_pkce")])
    return status
}

@MainActor private final class PairingTransport: HermesTransport {
    var requests: [URLRequest] = []
    var invalidated = false
    var override: ((URLRequest) throws -> (HermesJSON, Int, URL)?)?
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let json: HermesJSON
        var status = 200
        var responseURL = request.url!
        if let response = try override?(request) {
            (json, status, responseURL) = response
        } else {
            switch request.url!.path {
            case "/api/status": json = try pairingStatus()
            case "/api/auth/providers": json = .object(["providers": .array([.object(["name": .string("basic")])])])
            case "/auth/native/token": json = .object([
                "access_token": .string("fixture-access"), "refresh_token": .string("fixture-refresh"),
                "token_type": .string("Bearer"), "provider": .string("basic"), "user_id": .string("fixture-user")
            ])
            case "/api/auth/me": json = .object(["provider": .string("basic"), "user_id": .string("fixture-user")])
            default: throw NativeSignInExchange.Failure.invalidResponse
            }
        }
        return (try json.data, HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func socket(for request: URLRequest) throws -> any HermesSocket { throw NativeSignInExchange.Failure.invalidResponse }
    func invalidate() { invalidated = true }
}

@MainActor @Test func pairingNativeAddressErrorsPreserveParserFailures() throws {
    let transport = PairingTransport()
    #expect(throws: PairingAddress.Failure.unsupportedPath) {
        try NativeSignInExchange(serverURL: URL(string: "https://hermes.example/api")!, transport: transport)
    }
    #expect(throws: PairingAddress.Failure.tooLong) {
        try NativeSignInExchange(serverURL: URL(string: "https://hermes.example/" + String(repeating: "a", count: 4_096))!, transport: transport)
    }
    #expect(throws: PairingAddress.Failure.insecureHTTP) {
        try NativeSignInExchange(serverURL: URL(string: "http://public.example")!, transport: transport)
    }
}
