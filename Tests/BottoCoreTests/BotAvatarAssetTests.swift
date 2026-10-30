import Foundation
import Testing
@testable import BottoCore

// A one-pixel PNG, independent of the decoder under test.
private let avatarPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII="

@MainActor @Test(arguments: [true, false])
func avatarAssetUsesNamedProfileAndOnlyBoundedInlineImages(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority)
    let data = try #require(Data(base64Encoded: avatarPNG))
    var reply: HermesJSON = .object(["found": .bool(true), "mime": .string("image/png"),
        "size": .number(Double(data.count)), "data": .string("data:image/png;base64," + avatarPNG)])
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.get_asset" {
            #expect(frame["params"] == .object(["name": .string("inbox-triage"), "asset": .string("avatar")]))
            return reply
        }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let asset = try #require(try await service.avatarAsset(for: host.bot))
    #expect(asset.data == data && asset.mimeType == "image/png")
    let good = reply
    for malformed in [
        HermesJSON.string("https://example.com/avatar.png"),
        .string("data:image/svg+xml;base64," + avatarPNG),
        .string("data:image/jpeg;base64," + avatarPNG),
        .string("data:image/png;base64,%%%"),
        .string("data:image/png;base64," + String(repeating: "A", count: 3_000_001))
    ] {
        reply = good; reply["data"] = malformed
        #expect(try await service.avatarAsset(for: host.bot) == nil)
    }
    reply = good; reply["size"] = .number(2_000_001)
    #expect(try await service.avatarAsset(for: host.bot) == nil)
    reply = good; reply["mime"] = .string("image/webp")
    #expect(try await service.avatarAsset(for: host.bot) == nil)
    reply = .object(["found": .bool(false)])
    #expect(try await service.avatarAsset(for: host.bot) == nil)
}

@MainActor @Test func disconnectedAssetReadCannotReturnOldHostBytes() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    var held: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.get_asset" { held = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    let reading = Task { try await service.avatarAsset(for: host.bot) }
    try await eventually { held != nil }
    service.disconnect()
    await #expect(throws: HermesServiceError.disconnected) { _ = try await reading.value }
}

@MainActor @Test func optionalAvatarTimeoutDoesNotDisconnectChatOrBlockRoster() async throws {
    let host = try HermesTestHost()
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.get_asset" { return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(requestTimeout: .milliseconds(60)); defer { service.disconnect() }
    var disconnected = false
    service.onEvent = { if case .disconnected = $0 { disconnected = true } }
    _ = try await service.connect(configuration: host.configuration)
    await #expect(throws: HermesServiceError.timeout) { _ = try await service.avatarAsset(for: host.bot) }
    #expect(!disconnected)
    #expect(try await service.bots().first?.id == host.bot.id)
    #expect(try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil)).snapshot.profileID == host.bot.id)
    #expect(host.sockets.count == 1)
}
