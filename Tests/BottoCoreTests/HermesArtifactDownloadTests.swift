import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [true, false], ["complete", "navigate", "cancel"])
func artifactDownloadRequiresRefreshedAccessWithoutRetargeting(authority: Bool, action: String) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    var publications: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { publications.append(value) } }
    var heldResume: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.resume" { heldResume = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    host.sockets[0].push(host.event("message.complete", seq: 1, payload: ["text": .string("Done")]))
    try await eventually { heldResume != nil }
    let request = try #require(heldResume)
    let file = ChatAttachment(name: "report.html", path: "report.html")
    // Multiple-chat authority is deliberately stricter than the former raw
    // Conversation API: a refresh never upgrades an old captured access.
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.downloadArtifact(file, access: chat.access)
    }
    #expect(!host.transport.requests.contains { $0.url?.path == "/api/fs/download" })
    host.methodOverride = nil
    host.sockets[0].push(.object(["jsonrpc": .string("2.0"), "id": request["id"], "result": host.snapshot]))
    try await eventually { publications.last?.access != nil && publications.last?.access != chat.access }
    let refreshed = try #require(publications.last)
    if action == "navigate" {
        _ = try await service.openChat(.stored(refreshed.identity))
        await #expect(throws: HermesServiceError.staleConversation) {
            _ = try await service.downloadArtifact(file, access: refreshed.access)
        }
    } else {
        let loading = Task { try await service.downloadArtifact(file, access: refreshed.access) }
        if action == "cancel" {
            loading.cancel()
            // The access validator maps a canceled connection check to disconnected.
            await #expect(throws: HermesServiceError.disconnected) { _ = try await loading.value }
        } else {
            #expect(try await loading.value.data == Data(#"{"ok":true}"#.utf8))
        }
    }
    #expect(host.transport.requests.filter { $0.url?.path == "/api/fs/download" }.count == (action == "complete" ? 1 : 0))
}

@MainActor @Test(arguments: [true, false])
func artifactDownloadUsesOriginatingProfileAndStoredSession(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let attachment = ChatAttachment(name: "report.txt", path: "./report+draft #1&profile=other.txt")
    let artifact = try await service.downloadArtifact(attachment, access: chat.access)
    let request = try #require(host.transport.requests.last)
    #expect(request.url?.path == "/api/fs/download")
    #expect(request.httpMethod == "GET")
    let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query == [URLQueryItem(name: "path", value: "./report+draft #1&profile=other.txt"),
                      URLQueryItem(name: "profile", value: "inbox-triage"),
                      URLQueryItem(name: "session_id", value: chat.snapshot.storedID)])
    #expect(request.url?.absoluteString.contains("%2B") == true)
    #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
    #expect(artifact.data == Data(#"{"ok":true}"#.utf8))
    #expect(artifact.filename == "report+draft #1&profile=other.txt")
    #expect(artifact.mimeType == "application/octet-stream")
}

@MainActor @Test func artifactDownloadReturnsExactBytesAndResponseMetadata() async throws {
    let host = try HermesTestHost()
    let contract = try HermesJSON.decode(artifactFixture("source-contract", extension: "json"))
    let bytes = try artifactFixture("report", extension: "txt")
    let headers = try #require(contract["headers"].fields).mapValues { $0.text! }
    let transport = ArtifactTransport(host.transport) { request in
        (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
    let service = HermesBotService(transportFactory: { transport })
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let attachment = ChatAttachment(name: "forged.pdf", path: "/host/report.txt", mimeType: "application/pdf", byteCount: 999)
    let result = try await service.downloadArtifact(attachment, access: chat.access)
    #expect(result.data == bytes)
    #expect(result.filename == contract["filename"].text)
    #expect(result.mimeType == contract["mimeType"].text)
}

@MainActor @Test(arguments: ["", "   ", "https://evil.example/file?token=secret", "//evil.example/file", "\\\\host\\file", "file://evil.example/a", "file:///a?token=secret", "file:///a%00b", "bad\nname", "history-image:row-1", "0123-session:row:7:image:0", "data:text/plain,hello"])
func artifactDownloadRejectsInvalidReferencesBeforeRequest(_ path: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let count = host.transport.requests.count
    await #expect(throws: HermesServiceError.invalidAttachment) {
        try await service.downloadArtifact(ChatAttachment(name: "ignored.txt", path: path), access: chat.access)
    }
    #expect(host.transport.requests.count == count)
}

@MainActor @Test(arguments: ["/host/%2F%2Fevil%3Ftoken%3Dstolen%26profile%3Dother.txt", "../project/report.txt", "~/notes.txt", "C:\\Users\\bot\\a+b.txt", "file:///host/a%2Bb%20%23.txt"])
func artifactDownloadKeepsHostPathsInTheEncodedQuery(_ path: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    _ = try await service.downloadArtifact(ChatAttachment(name: "ignored", path: path), access: chat.access)
    let request = try #require(host.transport.requests.last)
    let items = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(request.url?.host == "hermes.example")
    #expect(items.count == 3)
    #expect(items[0].value == (path.hasPrefix("file:") ? "/host/a+b #.txt" : path))
    #expect(items[1].value == "inbox-triage")
    #expect(items[2].value == chat.snapshot.storedID)
    #expect(request.url?.user == nil && request.url?.password == nil)
}

@MainActor @Test(arguments: ["profile", "runtime", "stored"])
func artifactDownloadRejectsAnotherConversationBeforeRequest(_ component: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let foreign = try ConversationIssuer<String>().issue(component)
    let count = host.transport.requests.count
    await #expect(throws: HermesServiceError.staleConversation) {
        try await service.downloadArtifact(ChatAttachment(name: "report", path: "./report.txt"), access: foreign)
    }
    #expect(host.transport.requests.count == count)
}

@MainActor @Test(arguments: ["navigate", "disconnect", "replace", "cancel"])
func artifactDownloadFencesLateCompletions(_ action: String) async throws {
    let host = try HermesTestHost()
    var waiter: CheckedContinuation<Void, Never>?
    let transport = ArtifactTransport(host.transport) { request in
        await withCheckedContinuation { waiter = $0 }
        return (Data("old-host-bytes".utf8), artifactResponse(request))
    }
    let service = HermesBotService(transportFactory: { transport })
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let download = Task { try await service.downloadArtifact(ChatAttachment(name: "report", path: "./report.txt"), access: chat.access) }
    try await eventually { waiter != nil }
    switch action {
    case "navigate": _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    case "disconnect": service.disconnect()
    case "replace":
        var replacement = host.configuration
        replacement.serverURL = URL(string: "https://new-host.example")!
        _ = try await service.connect(configuration: replacement)
        _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    default: download.cancel()
    }
    waiter?.resume(); waiter = nil
    if action == "navigate" {
        await #expect(throws: HermesServiceError.staleConversation) { try await download.value }
    } else if action == "cancel" {
        await #expect(throws: CancellationError.self) { try await download.value }
    } else {
        await #expect(throws: HermesServiceError.disconnected) { try await download.value }
    }
    let requests = host.transport.requests.filter { $0.url?.path == "/api/fs/download" }
    #expect(requests.count == 1)
    #expect(requests.first?.url?.host == "hermes.example")
}

@MainActor @Test(arguments: ["password", "native", "page"])
func artifactDownloadUsesExistingAuthenticationAndCloudflareHeaders(_ authentication: String) async throws {
    let host = try HermesTestHost()
    let original = host.transport.handler
    host.transport.handler = { request in
        if authentication == "page" {
            if request.url?.path == "/api/status" {
                var status = try fixture("status"); status["auth_required"] = .bool(false); return status
            }
        }
        if request.url?.path == "/auth/native/refresh" {
            return .object(["access_token": .string("native-access"), "refresh_token": .string("native-refresh"),
                "provider": .string("basic"), "user_id": .string("alice")])
        }
        return try original?(request) ?? .object([:])
    }
    let transport = ArtifactTransport(host.transport) { request in
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "proxy-id")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == (authentication == "native" ? "Bearer native-access" : nil))
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == (authentication == "page" ? "page-token" : nil))
        #expect(request.url?.absoluteString.contains("token=") == false)
        return (Data("file".utf8), artifactResponse(request))
    }
    transport.page = authentication == "page" ? Data(#"<script>window.__HERMES_SESSION_TOKEN__ = "page-token";</script>"#.utf8) : nil
    let service = HermesBotService(transportFactory: { transport })
    defer { service.disconnect() }
    var configuration = host.configuration
    configuration.connectionHeaders = ["CF-Access-Client-Id": "proxy-id", "CF-Access-Client-Secret": "proxy-secret"]
    if authentication == "native" {
        configuration.password = ""
        configuration.nativeCredential = NativeCredential(refreshToken: "saved-refresh", provider: "basic")
    } else if authentication == "page" { configuration.username = ""; configuration.password = "" }
    _ = try await service.connect(configuration: configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    _ = try await service.downloadArtifact(ChatAttachment(name: "report", path: "./report.txt"), access: chat.access)
    #expect(host.transport.requests.filter { $0.url?.path == "/api/fs/download" }.count == 1)
}

@MainActor @Test(arguments: [302, 307, 401, 403, 404, 413, 206, 500])
func artifactDownloadRefusesRedirectsPartialBodiesAndHTTPFailures(_ status: Int) async throws {
    let host = try HermesTestHost()
    let transport = ArtifactTransport(host.transport) { request in
        (Data("sensitive host body".utf8), artifactResponse(request, status: status,
            headers: ["Location": "https://elsewhere.example/file?token=secret"]))
    }
    let service = HermesBotService(transportFactory: { transport })
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    await #expect(throws: (300..<400).contains(status) ? HermesServiceError.redirected : .rejected(status)) {
        try await service.downloadArtifact(ChatAttachment(name: "report", path: "./report.txt"), access: chat.access)
    }
    #expect(host.transport.requests.filter { $0.url?.path == "/api/fs/download" }.count == 1)
}

private func artifactResponse(_ request: URLRequest, status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
}

@MainActor @Test(arguments: [
    ("attachment; filename=\"semi;colon.txt\"", "Text/Plain; charset=UTF-8", "semi;colon.txt", "text/plain"),
    ("attachment; filename*=UTF-8'en'r%C3%A9sum%C3%A9.txt", "application/pdf", "résumé.txt", "application/pdf"),
    ("attachment; filename=\"../../private.html\"", "not a MIME", "report.bin", "application/octet-stream"),
    ("attachment; filename*=UTF-8''..%2Fprivate.html", "", "report.bin", "application/octet-stream"),
    ("attachment; filename*=UTF-8''bad%ZZ.txt", "application/octet-stream", "report.bin", "application/octet-stream"),
    ("attachment; filename=one.txt; filename=two.txt", "text/plain", "report.bin", "text/plain"),
    ("attachment; filename*=UTF-8''evil%E2%80%AEtxt.exe", "image/png", "report.bin", "image/png")
])
func artifactDownloadValidatesResponseMetadata(_ disposition: String, _ mime: String, _ filename: String, _ expectedMIME: String) async throws {
    let host = try HermesTestHost()
    let transport = ArtifactTransport(host.transport) { request in
        (Data(), artifactResponse(request, headers: ["Content-Disposition": disposition, "Content-Type": mime]))
    }
    let service = HermesBotService(transportFactory: { transport })
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let result = try await service.downloadArtifact(ChatAttachment(name: "fabricated.pdf", path: "/host/report.bin", mimeType: "application/pdf"), access: chat.access)
    #expect(result.data.isEmpty) // Empty files retain their exact bytes for Save and Share.
    #expect(result.filename == filename)
    #expect(result.mimeType == expectedMIME)
}

@MainActor @Test func artifactDownloadRefusesAChangedResponseURL() async throws {
    let host = try HermesTestHost()
    let transport = ArtifactTransport(host.transport) { _ in
        (Data("login page".utf8), HTTPURLResponse(url: URL(string: "https://elsewhere.example/file")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let service = HermesBotService(transportFactory: { transport })
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    await #expect(throws: HermesServiceError.redirected) {
        try await service.downloadArtifact(ChatAttachment(name: "report", path: "./report.txt"), access: chat.access)
    }
}

private func artifactFixture(_ name: String, extension ext: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/ArtifactDownload"))
    return try Data(contentsOf: url)
}

/// Keep the existing host's scripted auth/socket fixtures; add binary replies at
/// the same transport boundary without changing unrelated test infrastructure.
@MainActor private final class ArtifactTransport: HermesTransport {
    let base: ScriptedTransport
    var page: Data?
    var handler: (URLRequest) async throws -> (Data, HTTPURLResponse)
    init(_ base: ScriptedTransport, handler: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.base = base; self.handler = handler
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let page, request.url?.path == "/" || request.url?.path == "" { return (page, artifactResponse(request)) }
        guard request.url?.path == "/api/fs/download" else { return try await base.data(for: request) }
        base.requests.append(request)
        return try await handler(request)
    }
    func socket(for request: URLRequest) throws -> any HermesSocket { try base.socket(for: request) }
    func invalidate() { base.invalidate() }
}
