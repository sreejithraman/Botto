import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [true, false])
func rosterPollingPublishesFreshPerChatActivityWithoutRescanningDirectory(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    let original = host.transport.handler
    var directoryReads = 0
    host.transport.handler = { request in
        if isFullDirectoryRead(request) {
            directoryReads += 1
            return .object(["sessions": .array([.object(["id": .string("ordinary-tip"),
                "_lineage_root_id": .string("ordinary-root"), "_lineage_ids": .array([.string("ordinary-root"), .string("ordinary-tip")])])]),
                "total": .number(1), "limit": .number(100), "offset": .number(0)])
        }
        return try original?(request) ?? .object([:])
    }
    var status = "waiting"
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.active_list" {
            return .object(["sessions": status == "idle" ? .array([]) : .array([.object([
                "id": .string("ordinary-runtime"), "session_key": .string("ordinary-tip"), "status": .string(status)])])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id)
    let directory = try await service.conversations(profile: profile)
    let ordinary = try #require(directory.summaries.first { !$0.isCanonical })
    var observations: [SessionIdentity: ObservedActivity] = [:]
    service.onEvent = { event in
        for update in event.activityUpdates where update.profile == profile { observations = update.observations }
    }
    _ = try await service.bots()
    if case .known(.waiting, _) = observations[ordinary.identity] {} else { Issue.record("The poll must publish waiting for the exact ordinary lineage") }
    status = "idle"
    _ = try await service.bots()
    if case .known(.idle, _) = observations[ordinary.identity] {} else { Issue.record("A later complete idle sample must replace waiting") }
    #expect(directoryReads == 1)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "session.active_list" }.count == 3)
}

@MainActor @Test(arguments: [true, false])
func failedActivityPollPublishesUnknownThenCurrentIdle(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id)
    let directory = try await service.conversations(profile: profile)
    let identity = try #require(directory.summaries.first?.identity)
    var observations: [SessionIdentity: ObservedActivity] = [:]
    service.onEvent = { event in
        for update in event.activityUpdates where update.profile == profile { observations = update.observations }
    }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.active_list" { socket.reject(frame, code: -32601); return nil }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.bots()
    if case .unknown = observations[identity] {} else { Issue.record("A missing sample must not report idle or retain a known working status") }
    host.methodOverride = nil
    _ = try await service.bots()
    if case .known(.idle, _) = observations[identity] {} else { Issue.record("A current complete empty sample establishes idle") }
}

@MainActor @Test func sidecarActivityPublicationKeepsCollisionsUnknownAndUsesVerifiedRuntimeOwners() async throws {
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    host.profiles = .object(["profiles": .array([
        .object(["name": .string(host.bot.id), "canonical_session": .object(["id": .string(host.root)])]),
        .object(["name": .string("other"), "canonical_session": .object(["id": .string("shared")])])])])
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions" {
            return .object(["sessions": .array([.object(["id": .string("shared")])]), "total": .number(1), "limit": .number(100), "offset": .number(0)])
        }
        if request.url?.path == "/api/sessions/shared/messages" {
            return .object(["session_id": .string("shared"), "profile": .string(host.bot.id), "messages": .array([])])
        }
        return try original?(request) ?? .object([:])
    }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.active_list" {
            return .object(["sessions": .array([.object(["id": .string("shared-runtime"), "session_key": .string("shared"), "status": .string("waiting")])])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id)
    _ = try await service.bots() // Learn canonical aliases across both known profiles.
    let directory = try await service.conversations(profile: profile)
    let identity = try #require(directory.summaries.first { !$0.isCanonical }?.identity)
    var observations: [SessionIdentity: ObservedActivity] = [:]
    service.onEvent = { event in
        for update in event.activityUpdates where update.profile == profile { observations = update.observations }
    }
    _ = try await service.bots()
    if case .unknown = observations[identity] {} else { Issue.record("A shared stored alias must remain unknown") }
    let canonical = host.snapshot
    host.snapshot["session_id"] = .string("shared-runtime"); host.snapshot["session_key"] = .string("shared")
    _ = try await service.openChat(.stored(identity))
    _ = try await service.bots()
    if case .known(.idle, _) = observations[identity] {} else { Issue.record("The selected current snapshot must override its stale sampled row") }
    host.snapshot = canonical
    _ = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
    _ = try await service.bots()
    if case .known(.waiting, _) = observations[identity] {} else { Issue.record("A verified background runtime must join its exact source despite a shared alias") }
}

@MainActor @Test(arguments: [1, 2]) func activityBatchPublicationFencesRetirementInsideAnEventCallback(profileCount: Int) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    let rows: [HermesJSON] = [
        .object(["name": .string(host.bot.id), "canonical_session": .object(["id": .string(host.root)])]),
        .object(["name": .string("other"), "canonical_session": .object(["id": .string("other-root")])])]
    host.profiles = .object(["profiles": .array(Array(rows.prefix(profileCount)))])
    let configuration = host.configuration
    _ = try await service.connect(configuration: configuration)
    var publications: [[ExactID]] = []
    service.onEvent = {
        if case .activityBatch(let updates) = $0 { publications.append(updates.map(\.profile)); service.disconnect() }
    }
    await #expect(throws: HermesServiceError.disconnected) { try await service.bots() }
    #expect(publications.count == 1 && publications[0].count == profileCount)
    service.onEvent = { if case .activityBatch(let updates) = $0 { publications.append(updates.map(\.profile)) } }
    _ = try await service.connect(configuration: configuration)
    _ = try await service.bots()
    #expect(publications.count == 2 && publications[1] == publications[0])
}

@MainActor @Test(arguments: [true, false])
func unrecognizedActivityStatusStaysUnknownUntilACompleteRecognizedSample(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id)
    let identity = try #require(try await service.conversations(profile: profile).summaries.first?.identity)
    var status = "future-status"
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.active_list" {
            return .object(["sessions": .array([.object(["id": .string("runtime"), "session_key": .string(host.root), "status": .string(status)])])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    var values: [SessionIdentity: ObservedActivity] = [:]
    service.onEvent = { event in
        for update in event.activityUpdates where update.profile == profile { values = update.observations }
    }
    _ = try await service.bots()
    if case .unknown = values[identity] {} else { Issue.record("An unknown host status cannot establish idle") }
    status = "idle"
    _ = try await service.bots()
    if case .known(.idle, _) = values[identity] {} else { Issue.record("A recognized current owner should establish idle") }
}
