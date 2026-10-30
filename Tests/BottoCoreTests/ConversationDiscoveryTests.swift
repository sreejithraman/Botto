import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [true, false], ["idle", "waiting"])
func remoteChatDiscoveryInvalidatesOnlyChangedInventory(authority: Bool, status: String) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    let original = host.transport.handler
    var fullReads = 0, headReads = 0
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let limit = Int(query.first { $0.name == "limit" }?.value ?? "100")!
            if limit == 1 { headReads += 1 } else { fullReads += 1 }
            return .object(["sessions": .array(Array(host.storedRows.prefix(limit))),
                "total": .number(Double(host.storedRows.count)), "limit": .number(Double(limit)), "offset": .number(0)])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id)
    _ = try await service.bots()
    _ = try await service.conversations(profile: profile)
    var invalidations: [ExactID] = []
    var observations: [SessionIdentity: ObservedActivity] = [:]
    service.onEvent = {
        if case .conversationDirectoryChanged(let changed) = $0 { invalidations.append(changed) }
        for update in $0.activityUpdates where update.profile == profile { observations = update.observations }
    }
    host.storedRows = [.object(["id": .string("remote-chat"), "started_at": .number(20)])]
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.active_list" {
            return .object(["sessions": status == "idle" ? .array([]) : .array([.object([
                "id": .string("remote-runtime"), "session_key": .string("remote-chat"), "status": .string(status)])])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.bots()
    #expect(invalidations == [profile])
    let updated = try await service.conversations(profile: profile)
    let remote = try #require(updated.summaries.first { $0.identity.root.text == "remote-chat" })
    for _ in 0..<3 { _ = try await service.bots() }
    #expect(invalidations == [profile])
    if case .known(let observed, _) = observations[remote.identity] {
        #expect(observed == (status == "waiting" ? .waiting : .idle))
    } else { Issue.record("A newly discovered remote chat must receive current activity") }
    #expect(fullReads == 2)
    #expect(headReads >= 4)
}

@MainActor @Test(arguments: [true, false])
func discoveryFindsSameCountReplacementsAndCompactionAmongPins(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.storedRows = [.object(["id": .string("pinned"), "pinned": .bool(true)]), .object(["id": .string("old-head")])]
    let original = host.transport.handler
    var fullReads = 0
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions" {
            let limit = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "limit" }!.value!)!
            if limit != 1 { fullReads += 1 }
            return .object(["sessions": .array(host.storedRows), "total": .number(2),
                "limit": .number(Double(limit)), "offset": .number(0)])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id)
    _ = try await service.conversations(profile: profile)
    var changes: [ExactID] = []
    service.onEvent = { if case .conversationDirectoryChanged(let profile) = $0 { changes.append(profile) } }
    _ = try await service.bots()
    #expect(changes.isEmpty)
    host.storedRows[1] = .object(["id": .string("new-head")])
    _ = try await service.bots()
    #expect(changes == [profile])
    _ = try await service.conversations(profile: profile)
    host.storedRows[1] = .object(["id": .string("compressed-tip"), "_lineage_root_id": .string("new-head"),
        "_lineage_ids": .array([.string("new-head"), .string("compressed-tip")])])
    _ = try await service.bots()
    #expect(changes == [profile, profile])
    _ = try await service.conversations(profile: profile)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.active_list" {
            return .object(["sessions": .array([.object(["id": .string("cron-runtime"),
                "session_key": .string("excluded-cron"), "status": .string("working")])])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    for index in 0..<3 {
        host.storedRows[1]["preview"] = .string("Streaming \(index)")
        host.storedRows[1]["last_active"] = .number(Double(index))
        _ = try await service.bots()
    }
    #expect(changes.count == 2 && fullReads == 3)
}

@MainActor @Test(arguments: ["foreign", "corrupt", "malformed"])
func invalidDiscoveryProbeCannotReplaceCoveredInventory(failure: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    let original = host.transport.handler
    var invalid = true
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions" {
            let limit = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "limit" }!.value!)!
            if limit == 1, invalid {
                switch failure {
                case "foreign": return .object(["sessions": .array([.object(["id": .string("foreign"), "profile": .string("other")])]),
                    "total": .number(1), "limit": .number(1), "offset": .number(0)])
                case "corrupt": return .object(["sessions": .array([]), "total": .number(0), "limit": .number(1),
                    "offset": .number(0), "storage": .object([host.bot.id: .string("corrupt")])])
                default: return .object(["total": .number(0)])
                }
            }
            return .object(["sessions": .array(host.storedRows), "total": .number(Double(host.storedRows.count)),
                "limit": .number(Double(limit)), "offset": .number(0)])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id)
    host.storedRows = [.object(["id": .string("covered")])]
    _ = try await service.conversations(profile: profile)
    var changes = 0
    service.onEvent = { if case .conversationDirectoryChanged = $0 { changes += 1 } }
    _ = try await service.bots()
    #expect(changes == 0)
    invalid = false; host.storedRows = [.object(["id": .string("remote")])]
    _ = try await service.bots()
    #expect(changes == 1)
}

@MainActor @Test func discoveryRetiresAnOldReadWithoutErasingItsReplacement() async throws {
    let host = try HermesTestHost(), service = host.service()
    var oldGate: CheckedContinuation<HermesJSON, Error>?, newGate: CheckedContinuation<HermesJSON, Error>?
    defer {
        oldGate?.resume(throwing: HermesServiceError.disconnected)
        newGate?.resume(throwing: HermesServiceError.disconnected)
        service.disconnect()
    }
    let original = host.transport.handler
    var fullReads = 0
    host.transport.asyncHandler = { request in
        if request.url?.path == "/api/sessions" {
            let limit = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "limit" }!.value!)!
            if limit != 1 {
                fullReads += 1
                if fullReads == 2 { return try await withCheckedThrowingContinuation { oldGate = $0 } }
                if fullReads == 3 { return try await withCheckedThrowingContinuation { newGate = $0 } }
            }
            return .object(["sessions": .array(host.storedRows), "total": .number(Double(host.storedRows.count)),
                "limit": .number(Double(limit)), "offset": .number(0)])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id)
    _ = try await service.conversations(profile: profile)
    let old = Task { try await service.conversations(profile: profile) }
    try await eventually { oldGate != nil }
    host.storedRows = [.object(["id": .string("remote")])]
    _ = try await service.bots()
    let current = Task { try await service.conversations(profile: profile) }
    try await eventually { newGate != nil }
    oldGate?.resume(returning: .object(["sessions": .array([]), "total": .number(0), "limit": .number(100), "offset": .number(0)]))
    oldGate = nil
    await #expect(throws: HermesServiceError.disconnected) { try await old.value }
    var joined = false
    let joining = Task { joined = true; return try await service.conversations(profile: profile) }
    while !joined { await Task.yield() }
    #expect(fullReads == 3)
    newGate?.resume(returning: .object(["sessions": .array(host.storedRows), "total": .number(1), "limit": .number(100), "offset": .number(0)]))
    newGate = nil
    #expect(try await current.value.summaries.contains { $0.identity.root.text == "remote" })
    #expect(try await joining.value.summaries.contains { $0.identity.root.text == "remote" })
}
