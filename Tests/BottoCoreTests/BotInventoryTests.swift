import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [true, false])
func unopenedBotReportsAllProfileScopedAuthorityActivity(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority)
    let contract = try inventoryFixture(authority: authority)
    host.profiles = contract["profiles"]
    host.methodOverride = { [weak host] frame, socket in
        guard let host else { return nil }
        if frame["method"].text == "session.active_list" {
            return authority ? contract["activity"][frame["params"]["profile"].text ?? ""] : contract["activity"]
        }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bots = try await service.bots()
    #expect(bots.map(\.id) == ["inbox-triage", "research"])
    #expect(bots.map(\.status) == [.waiting, authority ? .waiting : .idle])
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "session.resume" })
}

private func inventoryFixture(authority: Bool) throws -> HermesJSON {
    let url = Bundle.module.url(forResource: authority ? "authority" : "sidecar", withExtension: "json", subdirectory: "Fixtures/InventoryContract")!
    return try HermesJSON.decode(Data(contentsOf: url))
}

@MainActor @Test func authorityInventoryScopesRepeatedCanonicalIDsToTheirProfiles() async throws {
    let host = try HermesTestHost()
    var contract = try inventoryFixture(authority: true)
    var profiles = try #require(contract["profiles"]["profiles"].list)
    profiles[1]["canonical_session"] = profiles[0]["canonical_session"]
    host.profiles = .object(["profiles": .array(profiles)])
    var other = try #require(contract["activity"]["inbox-triage"]["sessions"].list?.first)
    other["status"] = .string("working")
    contract["activity"]["research"] = .object(["sessions": .array([other])])
    let replies = contract["activity"]
    host.methodOverride = { [weak host] frame, socket in
        guard let host else { return nil }
        if frame["method"].text == "session.active_list" { return replies[frame["params"]["profile"].text ?? ""] }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    #expect(try await service.bots().map(\.status) == [.waiting, .working])
}

@MainActor @Test func sidecarInventoryMapsEveryBotFromOneUnscopedReply() async throws {
    let host = try HermesTestHost(authority: false)
    var contract = try inventoryFixture(authority: false)
    var activity = try #require(contract["activity"]["sessions"].list)
    activity[0]["status"] = .string("idle")
    activity[1]["status"] = .string("working")
    contract["activity"]["sessions"] = .array(activity)
    host.profiles = contract["profiles"]
    let reply = contract["activity"]
    host.methodOverride = { [weak host] frame, socket in
        guard let host else { return nil }
        if frame["method"].text == "session.active_list" { return reply }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    #expect(try await service.bots().map(\.status) == [.idle, .working])
    #expect(host.sockets[0].sent.filter { $0["method"].text == "session.active_list" }.count == 1)
}

@MainActor @Test func sidecarInventoryDoesNotGuessOwnerOfRepeatedCanonicalIDs() async throws {
    let host = try HermesTestHost(authority: false)
    let contract = try inventoryFixture(authority: false)
    var profiles = try #require(contract["profiles"]["profiles"].list)
    profiles[1]["canonical_session"] = profiles[0]["canonical_session"]
    host.profiles = .object(["profiles": .array(profiles)])
    host.methodOverride = { [weak host] frame, socket in
        guard let host else { return nil }
        if frame["method"].text == "session.active_list" { return contract["activity"] }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    #expect(try await service.bots().map(\.status) == [.idle, .idle])
}

@MainActor @Test(arguments: [true, false])
func unavailableBotInventoryPreservesIdleRosterMetadata(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority)
    host.profiles = try inventoryFixture(authority: authority)["profiles"]
    host.methodOverride = { [weak host] frame, socket in
        guard let host else { return nil }
        if frame["method"].text == "session.active_list" { socket.reject(frame, code: -32601); return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bots = try await service.bots()
    #expect(bots.map(\.status) == [.idle, .idle])
    #expect(bots.map(\.preview) == ["Waiting for approval", "Ready"])
}

@MainActor @Test(arguments: [true, false], [BotStatus.idle, .working, .waiting])
func selectedChatStatusOverridesInventory(authority: Bool, status: BotStatus) async throws {
    let host = try HermesTestHost(authority: authority)
    var profiles = try #require(try inventoryFixture(authority: true)["profiles"]["profiles"].list)
    profiles[0]["canonical_session"] = .object(["id": .string(host.root), "resolved_id": .string(host.root)])
    host.profiles = .object(["profiles": .array(profiles)])
    host.snapshot["running"] = .bool(status != .idle)
    if status == .waiting, authority {
        host.snapshot["prompts"] = .array([.object(["kind": .string("approval"), "prompt_id": .string("approval-1"),
            "execution_generation": .number(7), "choices": .array([.string("once"), .string("deny")])])])
    } else if status == .waiting {
        var approval = try #require(try fixture("turn-tool-approval-frames")["frames"].list?.first { $0["method"].text == "approval" })
        approval["params"]["session_id"] = .string(host.runtime)
        host.snapshot["open_requests"] = .array([approval])
    }
    host.methodOverride = { [weak host] frame, socket in
        guard let host else { return nil }
        if frame["method"].text == "session.active_list" {
            return .object(["sessions": .array([.object(["session_key": .string(host.root), "status": .string("waiting")])])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    #expect(try await service.bots().first?.status == status)
}

@MainActor @Test func authorityInventoryReadsProfilesTogetherAndRejectsRetiredConnection() async throws {
    let host = try HermesTestHost()
    let contract = try inventoryFixture(authority: true)
    host.profiles = contract["profiles"]
    var pending: [HermesJSON] = []
    host.methodOverride = { [weak host] frame, socket in
        guard let host else { return nil }
        if frame["method"].text == "session.active_list" { pending.append(frame); return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(requestTimeout: .seconds(5)); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let inventory = Task { try await service.bots() }
    try await eventually { pending.count == 2 }
    // Both requests must be in flight before either reply; profile reads cannot queue
    // behind an unrelated slow profile. Disconnect retires the entire pending inventory.
    #expect(Set(pending.compactMap { $0["params"]["profile"].text }) == ["inbox-triage", "research"])
    service.disconnect()
    await #expect(throws: HermesServiceError.disconnected) { try await inventory.value }
    #expect(host.sockets[0].sent.allSatisfy { !["session.resume", "prompt.submit"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: [true, false], [
    ("working", BotStatus.working), ("starting", .working), ("streaming", .working),
    ("waiting", .waiting), ("idle", .idle), ("resuming", .idle), ("future-status", .idle)
]) func botInventoryDecodesHostStatus(authority: Bool, sample: (String, BotStatus)) async throws {
    let host = try HermesTestHost(authority: authority)
    let contract = try inventoryFixture(authority: authority)
    host.profiles = contract["profiles"]
    var item = try #require((authority ? contract["activity"]["inbox-triage"] : contract["activity"])["sessions"].list?.first)
    item["status"] = .string(sample.0)
    let activity: HermesJSON = .object(["sessions": .array([item])])
    host.methodOverride = { [weak host] frame, socket in
        guard let host else { return nil }
        if frame["method"].text == "session.active_list" {
            if authority, frame["params"]["profile"].text == "research" { return .object(["sessions": .array([])]) }
            return activity
        }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    #expect(try await service.bots().map(\.status) == [sample.1, .idle])
}

@MainActor @Test func retiredSelectedChatCannotOverrideReplacementCanonicalChat() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    var profiles = try #require(try inventoryFixture(authority: true)["profiles"]["profiles"].list)
    profiles[0]["canonical_session"] = .object(["id": .string(host.root), "resolved_id": .string(host.root)])
    host.profiles = .object(["profiles": .array(profiles)])
    host.snapshot["running"] = .bool(true)
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    // Another client replaces the canonical chat while this client remains attached.
    profiles[0]["canonical_session"] = .object(["id": .string("replacement"), "resolved_id": .string("replacement")])
    host.profiles = .object(["profiles": .array(profiles)])
    let bots = try await service.bots()
    #expect(bots.first?.status == .idle)
}
