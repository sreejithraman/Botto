import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [false, true])
func lateResumeSubscriptionIsDetachedWithoutTakingNewSelection(cancel: Bool) async throws {
    let host = try HermesTestHost(), service = host.service(requestTimeout: .seconds(5))
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    var delayed: HermesJSON?
    var oldSnapshot = host.snapshot
    oldSnapshot["session_id"] = .string("runtime-A")
    oldSnapshot["stored_session_id"] = .string("stored-A")
    oldSnapshot["subscription_id"] = .string("late-subscription-A")
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.resume", frame["params"]["session_id"].text == "stored-A" {
            delayed = frame; return nil
        }
        return host.defaultReply(frame, socket: socket)
    }
    let identity = try SessionIdentity(profile: ExactID(host.bot.id), root: ExactID("stored-A"), stored: ExactID("stored-A"), aliases: [ExactID("stored-A")])
    host.storedRows = [.object(["id": .string("stored-A")])]
    let opening = Task { try await service.openChat(.stored(identity)) }
    try await eventually { delayed != nil }
    if cancel { opening.cancel() }
    let b = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    var latest = b
    service.onEvent = { if case .conversation(let opened) = $0 { latest = opened } }
    let socket = host.sockets[0]
    let delayedReply = try #require(delayed)
    socket.push(.object(["jsonrpc": .string("2.0"), "id": delayedReply["id"], "result": oldSnapshot]))
    do { _ = try await opening.value; Issue.record("Superseded opening must fail") } catch {}
    try await eventually { socket.sent.contains { $0["method"].text == "session.detach" && $0["params"]["subscription_id"].text == "late-subscription-A" } }
    #expect(latest.identity == b.identity)
    let receipt = try await service.send(text: "still current", attachments: [], access: b.access, operationID: UUID())
    #expect(receipt.source == b.identity)
    #expect(!socket.sent.contains { ["session.close", "session.interrupt"].contains($0["method"].text ?? "") })
}

@MainActor @Test func canceledLateCreationRemainsIdentifiedAndCleansOnlyOriginSubscription() async throws {
    let host = try HermesTestHost(), service = host.service(requestTimeout: .seconds(5))
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    var pending: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.create" { pending = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let operation = UUID()
    let creation = Task { try await service.createConversation(profile: ExactID(host.bot.id), operationID: operation) }
    try await eventually { pending != nil }
    creation.cancel()
    let selected = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    var latest = selected
    service.onEvent = { if case .conversation(let value) = $0 { latest = value } }
    var created = host.snapshot
    created["session_id"] = .string("created-runtime")
    created["stored_session_id"] = .string("created-stored")
    created["subscription_id"] = .string("created-subscription")
    let socket = host.sockets[0]
    socket.push(.object(["id": pending!["id"], "result": created]))
    let identified = try await creation.value
    #expect(identified.operationID == operation)
    #expect(identified.summary.identity.stored.text == "created-stored")
    #expect(latest.identity == selected.identity)
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    #expect(directory.summaries.contains { $0.identity == identified.summary.identity })
    #expect(socket.sent.contains { $0["method"].text == "session.detach" && $0["params"]["subscription_id"].text == "created-subscription" })
    #expect(!socket.sent.contains { $0["method"].text == "session.detach" && $0["params"]["subscription_id"].text == "subscription-1" })
    #expect(socket.sent.filter { $0["method"].text == "session.create" }.count == 1)
    let receipt = try await service.send(text: "selection retained", attachments: [], access: selected.access, operationID: UUID())
    #expect(receipt.source == selected.identity)
}

@MainActor @Test func selectedOrdinaryRecoveryResumesItsStoredTargetAndNeverCanonical() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    host.snapshot["session_id"] = .string("ordinary-runtime")
    host.snapshot["stored_session_id"] = .string("ordinary-tip")
    let identity = try SessionIdentity(profile: ExactID(host.bot.id), root: ExactID("ordinary-root"), stored: ExactID("ordinary-tip"), aliases: [ExactID("ordinary-root"), ExactID("ordinary-tip")])
    host.storedRows = [.object(["id": .string("ordinary-tip"), "_lineage_root_id": .string("ordinary-root"),
        "_lineage_ids": .array([.string("ordinary-root"), .string("ordinary-tip")])])]
    let original = try await service.openChat(.stored(identity))
    var current: OpenedConversation?, recovered = false
    service.onEvent = {
        if case .conversation(let value) = $0 { current = value }
        if case .connected = $0 { recovered = true }
    }
    host.sockets[0].close()
    try await eventually { recovered }
    let next = try #require(current)
    #expect(next.identity == identity)
    #expect(next.access != original.access)
    #expect(host.sockets.count == 2)
    let frames = host.sockets[1].sent
    #expect(frames.contains { $0["method"].text == "session.resume" && $0["params"]["session_id"].text == "ordinary-tip" })
    #expect(!frames.contains { ["session.list", "session.create", "session.close", "session.interrupt"].contains($0["method"].text ?? "") })
    await #expect(throws: HermesServiceError.staleConversation) { try await service.stop(access: original.access, operationID: UUID()) }
    _ = try await service.send(text: "recovered owner", attachments: [], access: next.access, operationID: UUID())
}

@MainActor @Test func lostCreationReplyIsUncertainAndNeverAutomaticallyRetried() async throws {
    let host = try HermesTestHost(), service = host.service(requestTimeout: .milliseconds(30))
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    var recovered = false
    service.onEvent = { if case .connected = $0 { recovered = true } }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.create" { return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let operation = UUID()
    await #expect(throws: HermesServiceError.uncertain) { try await service.createConversation(profile: ExactID(host.bot.id), operationID: operation) }
    try await eventually { recovered }
    #expect(host.sockets.flatMap(\.sent).filter { $0["method"].text == "session.create" }.count == 1)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.create" { return host.snapshot }
        return host.defaultReply(frame, socket: socket)
    }
    await #expect(throws: HermesServiceError.staleConversation) { try await service.createConversation(profile: ExactID(host.bot.id), operationID: operation) }
    let identified = try await service.createConversation(profile: ExactID(host.bot.id), operationID: UUID())
    #expect(identified.summary.identity.stored.text == host.root)
}
