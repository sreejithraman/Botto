import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [false, true])
func authorityAvatarDiscoveryReadsOwnMetadataWithoutReplacingCanonicalInventory(hasImage: Bool) async throws {
    let fixture = try contractFixture("avatar-roster")
    let profile = try #require(fixture["discovered"]["name"].text)
    var discovered = fixture["discovered"], own = fixture["own"]
    discovered["canonical_session"] = .object(["id": .string("canonical"), "preview": .string("Keep this preview")])
    own["has_avatar"] = .bool(hasImage)
    // Scoped metadata is not a replacement roster or a source of canonical sessions.
    own["canonical_session"] = .object(["id": .string("unrelated"), "preview": .string("Wrong preview")])
    let host = try HermesTestHost()
    host.profiles = .object(["profiles": .array([discovered])])
    let scoped = own
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "profiles.list" where frame["params"]["profile"].text == profile:
            #expect(frame["params"]["include_sessions"].flag == false)
            return .object(["profiles": .array([scoped])])
        case "session.active_list":
            #expect(frame["params"]["profile"].text == profile)
            return .object(["sessions": .array([
                .object(["session_key": .string("canonical"), "status": .string("waiting")]),
                .object(["session_key": .string("unrelated"), "status": .string("working")])])])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    #expect(bot.id == profile)
    #expect(bot.lookRevision == 1)
    #expect(bot.hasAvatar == hasImage)
    #expect(bot.face == BotFace(shape: .cloud, color: "#14b8a6"))
    #expect(bot.preview == "Keep this preview" && bot.status == .waiting)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "profiles.list" && $0["params"]["profile"].text == profile }.count == 1)
}

@MainActor @Test func authorityAvatarSaveUsesFreshOwnRevisionFromCapturedSiblingRoster() async throws {
    let fixture = try contractFixture("avatar-roster")
    let profile = try #require(fixture["own"]["name"].text)
    let host = try HermesTestHost()
    host.profiles = .object(["profiles": .array([fixture["discovered"]])])
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "profiles.list" where frame["params"]["profile"].text == profile:
            return .object(["profiles": .array([fixture["own"]])])
        case "profiles.configure":
            let revision = frame["params"]["ui_meta_expected_revisions"]["hermes-bots"]
            #expect(revision.integer == 1)
            guard revision.integer == 1 else {
                return .object(["applied": .object(["ui_meta": .bool(false),
                    "ui_meta_conflicts": .object(["hermes-bots": .object(["expected": revision, "actual": .number(1)])])])])
            }
            #expect(frame["params"]["name"].text == profile)
            #expect(frame["params"]["ui_meta"]["hermes-bots"]["title"].text == "Hot Core Probe 8c008ace")
            return .object(["applied": .object(["ui_meta": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(2)])])])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let baseline = try #require(try await service.bots().first)
    let saved = try await service.setAvatar(.face(.init(shape: .drop, color: "#22c55e")), for: baseline)
    #expect(saved.lookRevision == 2 && saved.hasAvatar == false)
    #expect(saved.face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
    #expect(host.sockets[0].sent.filter { $0["method"].text == "profiles.configure" }.count == 1)
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "profiles.set_asset" })
}

@MainActor @Test(arguments: ["missing-map", "missing-flag", "wrong-name", "duplicate-name", "invalid-revision", "wrong-install"])
func authorityAvatarSaveRefusesUnprovenMetadata(problem: String) async throws {
    let fixture = try contractFixture("avatar-roster"), host = try HermesTestHost()
    let profile = try #require(fixture["own"]["name"].text)
    var row = fixture["own"]
    switch problem {
    case "missing-map": row["ui_meta_revisions"] = .null
    case "missing-flag": row["has_avatar"] = .null
    case "wrong-name": row["name"] = .string("some-other-profile")
    case "invalid-revision": row["ui_meta_revisions"]["hermes-bots"] = .number(-1)
    default: break
    }
    let reply: HermesJSON = .object(["install_id": .string(problem == "wrong-install" ? "other-host" : "fixture-install"),
        "profiles": .array(problem == "duplicate-name" ? [row, row] : [row])])
    host.profiles = .object(["profiles": .array([fixture["discovered"]])])
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.list", frame["params"]["profile"].text == profile { return reply }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    // An unavailable/mismatched optional metadata read cannot remove the discovered bot.
    #expect(bot.hasAvatar == nil && bot.lookRevision == nil)
    let expected: HermesServiceError = problem == "wrong-install" ? .differentHost
        : ["wrong-name", "duplicate-name"].contains(problem) ? .profileUnavailable : .incompatible
    await #expect(throws: expected) { _ = try await service.setAvatar(.automatic, for: bot) }
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: [true, false])
func avatarSaveMatchesExactProfileAndFeatureDetectsZeroRevision(authority: Bool) async throws {
    let fixture = try contractFixture("avatar-roster"), host = try HermesTestHost(authority: authority)
    let profile = try #require(fixture["own"]["name"].text)
    var row = fixture["own"]
    row["ui_meta_revisions"] = .object([:]); row["ui_meta"] = .null
    let own = row
    let decoy: HermesJSON = .object(["name": .string("decoy"), "has_avatar": .bool(true),
        "ui_meta_revisions": .object(["hermes-bots": .number(99)])])
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "profiles.list":
            #expect(frame["params"]["profile"].text == (authority ? profile : nil))
            #expect(frame["params"]["include_sessions"].flag == false)
            return .object(["profiles": .array([decoy, own])])
        case "profiles.configure":
            #expect(frame["params"]["name"].text == profile)
            #expect(frame["params"]["ui_meta_expected_revisions"]["hermes-bots"].integer == 0)
            return .object(["applied": .object(["ui_meta": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(1)])])])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let saved = try await service.setAvatar(.automatic, for: BotProfile(id: profile, name: "New"))
    #expect(saved.id == profile && saved.lookRevision == 1)
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "profiles.set_asset" })
}

@MainActor @Test func authorityAvatarReadsRunTogetherAndRetiredConnectionCannotPublish() async throws {
    let fixture = try contractFixture("avatar-roster"), host = try HermesTestHost()
    var other = fixture["discovered"]; other["name"] = .string("second")
    host.profiles = .object(["profiles": .array([fixture["discovered"], other])])
    var pending: [HermesJSON] = []
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.list", frame["params"]["profile"].text != nil { pending.append(frame); return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(requestTimeout: .seconds(5)); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let reading = Task { try await service.bots() }
    try await eventually { pending.count == 2 }
    #expect(Set(pending.compactMap { $0["params"]["profile"].text }) == ["hot-core-probe-8c008ace", "second"])
    service.disconnect()
    host.profiles = .object(["profiles": .array([])])
    _ = try await service.connect(configuration: host.configuration)
    for frame in pending {
        host.sockets[0].push(.object(["id": frame["id"], "result": .object(["profiles": .array([fixture["own"]])])]))
    }
    await #expect(throws: HermesServiceError.disconnected) { _ = try await reading.value }
    #expect(try await service.bots().isEmpty)
}

@MainActor @Test(arguments: [false, true])
func optionalAuthorityAvatarMetadataFailureKeepsRosterAndChatAvailable(timeout: Bool) async throws {
    let host = try HermesTestHost()
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.list", frame["params"]["profile"].text != nil {
            if !timeout { socket.reject(frame, code: -32601) }
            return nil
        }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(requestTimeout: .milliseconds(60)); defer { service.disconnect() }
    var disconnected = false
    service.onEvent = { if case .disconnected = $0 { disconnected = true } }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    #expect(bot.id == host.bot.id && bot.hasAvatar == nil)
    #expect(try await service.openChat(.canonical(profile: try ExactID(bot.id), expectedRoot: nil)).snapshot.profileID == bot.id)
    #expect(!disconnected && host.sockets.count == 1)
}
