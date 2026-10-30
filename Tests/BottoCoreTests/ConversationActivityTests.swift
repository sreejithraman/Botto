import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [false, true])
func liveConversationActivityPublishesStableWorkAndOneSuccessfulReaction(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["running"] = .bool(false)
    var values: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { values.append(value) } }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    host.sockets[0].push(liveActivityEvent(host, "message.start", seq: 1))
    try await eventually { values.last?.snapshot.lastSequence == 1 }
    let start = try #require(values.last?.activity)
    #expect(start.phase == .working)
    host.sockets[0].push(host.event("thinking.delta", seq: 2, payload: ["text": .string("Considering")]))
    try await eventually { values.last?.snapshot.lastSequence == 2 }
    #expect(values.last?.activity?.phase == .thinking)
    #expect(values.last?.activity?.workStartedAt == start.workStartedAt)
    let thinking = values.last?.activity
    host.sockets[0].push(host.event("thinking.delta", seq: 3, payload: ["text": .string("Still considering")]))
    try await eventually { values.last?.snapshot.lastSequence == 3 }
    #expect(values.last?.activity?.phaseStartedAt == thinking?.phaseStartedAt)
    host.sockets[0].push(host.event("message.delta", seq: 4, payload: ["text": .string("Answer")]))
    try await eventually { values.last?.snapshot.lastSequence == 4 }
    #expect(values.last?.activity?.phase == .replying)
    host.sockets[0].push(liveActivityEvent(host, "message.complete", seq: 5, payload: ["status": .string("complete")]))
    try await eventually { values.contains { $0.activity?.reaction?.kind == .succeeded } }
    #expect(values.filter { $0.activity?.reaction != nil }.count == 1)
}

@MainActor @Test
func conversationActivityRejectsForeignSettlementAndKeepsOverlappingTools() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["running"] = .bool(false)
    var values: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { values.append(value) } }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    func push(_ type: String, _ seq: Int, _ payload: [String: HermesJSON] = [:], generation: Int? = 7, admission: String = "active") async throws {
        var frame = host.event(type, seq: seq, payload: payload)
        frame["params"]["execution_generation"] = generation.map { .number(Double($0)) } ?? .null
        frame["params"]["admission_id"] = .string(admission)
        host.sockets[0].push(frame)
        try await eventually { values.last?.snapshot.lastSequence == seq }
    }
    try await push("message.start", 1)
    let clock = values.last?.activity?.workStartedAt
    try await push("tool.start", 2, ["tool_id": .string("e\u{301}")])
    try await push("tool.start", 3, ["tool_id": .string("\u{e9}")])
    try await push("tool.complete", 4, ["tool_id": .string("e\u{301}")])
    #expect(values.last?.activity?.phase == .tools)
    try await push("message.delta", 5, ["text": .string("obsolete")], generation: 6)
    #expect(values.last?.activity?.phase == .tools)
    try await push("tool.complete", 6, ["tool_id": .string("\u{e9}")])
    #expect(values.last?.activity?.phase == .working)
    #expect(values.last?.activity?.workStartedAt == clock)
    try await push("thinking.delta", 7, ["text": .string("")])
    try await push("message.complete", 8, ["status": .string("complete"), "outcome": .string("cancelled")], generation: nil, admission: "queued")
    #expect(values.last?.activity?.phase == .working)
    #expect(values.allSatisfy { $0.activity?.reaction == nil })
}

@MainActor @Test(arguments: [false, true], ["complete", "error", "interrupted", "cancelled", "unknown", ""])
func conversationActivityOnlyExplicitLiveOutcomesReact(authority: Bool, status: String) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["running"] = .bool(false)
    var values: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { values.append(value) } }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    host.sockets[0].push(liveActivityEvent(host, "message.start", seq: 1))
    try await eventually { values.last?.snapshot.lastSequence == 1 }
    host.snapshot["last_sequence"] = .number(2)
    host.replay["latest_seq"] = .number(2)
    let terminal = liveActivityEvent(host, "message.complete", seq: 2, payload: ["status": .string(status)])
    host.sockets[0].push(terminal)
    try await eventually { values.last?.snapshot.lastSequence == 2 }
    let reaction = values.last?.activity?.reaction
    #expect(reaction?.kind == (status == "complete" ? .succeeded : status == "error" ? .failed : nil))
    let count = values.count
    host.sockets[0].push(terminal)
    try await eventually { values.count > count }
    #expect(values.last?.activity?.lineage == opened.activity?.lineage)
    #expect(values.last?.activity?.reaction == nil)
    #expect(values.compactMap { $0.activity?.reaction }.count == (reaction == nil ? 0 : 1))
    let oldLineage = values.last?.activity?.lineage
    host.sockets[0].close()
    try await eventually { host.sockets.count == 2 && values.last?.activity?.lineage != oldLineage }
    #expect(values.last?.activity?.reaction == nil)
}

@MainActor @Test(arguments: [false, true])
func conversationActivityCapturedTurnsReachConsumerWithoutReplayingSuccess(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["running"] = .bool(false)
    var values: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { values.append(value) } }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let captured: [HermesJSON]
    if authority {
        let url = try #require(Bundle.module.url(forResource: "turn-events", withExtension: "json", subdirectory: "Fixtures/AuthorityCaptured"))
        let all = try #require(HermesJSON.decode(Data(contentsOf: url)).list)
        let second = try #require(all.lastIndex { $0["type"].text == "message.start" })
        captured = Array(all[second...])
    } else {
        captured = try #require(fixture("turn-tool-approval-frames")["frames"].list).map { $0["params"] }
    }
    var sequence = 0, started = false
    for event in captured {
        let type = event["type"].text ?? ""
        if type == "message.start" { started = true }
        guard started, !type.isEmpty else { continue }
        sequence += 1
        var frame = host.event(type, seq: sequence, payload: event["payload"].fields ?? [:])
        if authority { frame["params"]["admission_id"] = event["admission_id"] }
        host.sockets[0].push(frame)
        try await eventually { values.last?.snapshot.lastSequence == sequence }
        if type == "thinking.delta", event["payload"]["text"].nonempty != nil { #expect(values.last?.activity?.phase == .thinking) }
        if type == "tool.start" { #expect(values.last?.activity?.phase == .tools) }
        if type == "message.complete" { break }
    }
    #expect(values.contains { $0.activity?.phase == .thinking })
    #expect(values.contains { $0.activity?.phase == .tools })
    if authority { #expect(values.contains { $0.activity?.phase == .replying }) }
    #expect(values.compactMap { $0.activity?.reaction }.map(\.kind) == [.succeeded])
    host.snapshot["last_sequence"] = .number(Double(sequence))
    host.replay["latest_seq"] = .number(Double(sequence))
    let count = values.count
    try await eventually { values.count > count }
    #expect(values.last?.activity?.reaction == nil)
}

@MainActor @Test(arguments: [false, true])
func conversationActivityRecoveryNeverCreatesReactions(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["running"] = .bool(false)
    var values: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { values.append(value) } }
    let start = host.event("message.start", seq: 1)["params"]
    let complete = host.event("message.complete", seq: 2, payload: ["status": .string("complete")])["params"]
    host.replay["events"] = .array([start, complete])
    host.replay["latest_seq"] = .number(2)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.events.since" {
            socket.push(host.event("message.start", seq: 3))
            socket.push(host.event("message.complete", seq: 4, payload: ["status": .string("complete")]))
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    #expect(opened.snapshot.lastSequence == 4)
    #expect(opened.activity?.phase == nil)
    #expect(values.allSatisfy { $0.activity?.reaction == nil })
}

@MainActor @Test(arguments: [false, true])
func conversationActivitySameAttachmentRefreshKeepsWorkClock(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["running"] = .bool(false)
    var values: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { values.append(value) } }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    host.sockets[0].push(host.event("message.start", seq: 1))
    try await eventually { values.last?.snapshot.lastSequence == 1 }
    let working = try #require(values.last?.activity)
    let startEvent = host.event("message.start", seq: 1)["params"]
    let replyEvent = host.event("message.delta", seq: 2, payload: ["text": .string("Current reply")])["params"]
    host.sockets[0].push(.object(["jsonrpc": .string("2.0"), "method": .string("event"), "params": replyEvent]))
    try await eventually { values.last?.snapshot.lastSequence == 2 }
    let replying = try #require(values.last?.activity)
    host.snapshot["running"] = .bool(true)
    host.snapshot["inflight"]["assistant"] = .string("Current reply")
    host.snapshot["last_sequence"] = .number(2)
    host.replay["latest_seq"] = .number(2)
    host.replay["events"] = .array([startEvent, replyEvent])
    let count = values.count
    host.sockets[0].push(host.event("session.replay_gap", seq: 3))
    try await eventually { values.count > count }
    #expect(values.last?.activity?.lineage == working.lineage)
    #expect(values.last?.activity?.workStartedAt == working.workStartedAt)
    #expect(values.last?.activity?.phase == .replying)
    #expect(values.last?.activity?.phaseStartedAt == replying.phaseStartedAt)
    #expect(values.last?.activity?.reaction == nil)
    let refreshed = try #require(values.last)
    let switched = try await service.openChat(.stored(refreshed.identity))
    #expect(switched.activity?.lineage == working.lineage)
    #expect(switched.activity?.workStartedAt == replying.workStartedAt)
    #expect(switched.activity?.phaseStartedAt == replying.phaseStartedAt)
}

@MainActor @Test(arguments: [false, true])
func conversationActivitySameChatOpenAfterCompletionKeepsLineageWithoutReaction(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["running"] = .bool(false)
    var values: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { values.append(value) } }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    host.sockets[0].push(liveActivityEvent(host, "message.start", seq: 1))
    try await eventually { values.last?.snapshot.lastSequence == 1 }
    host.snapshot["last_sequence"] = .number(2)
    host.replay["latest_seq"] = .number(2)
    host.sockets[0].push(liveActivityEvent(host, "message.complete", seq: 2, payload: ["status": .string("complete")]))
    try await eventually { values.contains { $0.activity?.reaction?.kind == .succeeded } }
    let completed = try #require(values.last { $0.activity?.reaction != nil })
    let count = values.count
    try await eventually { values.count > count }
    let reread = try await service.openChat(.stored(opened.identity))
    #expect(reread.activity?.lineage == completed.activity?.lineage)
    #expect(reread.activity?.workStartedAt == completed.activity?.workStartedAt)
    #expect(reread.activity?.phaseStartedAt == completed.activity?.phaseStartedAt)
    #expect(reread.activity?.reaction == nil)
    #expect(values.compactMap { $0.activity?.reaction }.map(\.id) == [try #require(completed.activity?.reaction?.id)])
    #expect(reread.access != completed.access)
}

@MainActor @Test(arguments: ["runtime", "target", "epoch"])
func conversationActivityChangedAttachmentRetiresLineage(change: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["running"] = .bool(false)
    _ = try await service.connect(configuration: host.configuration)
    let first = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    switch change {
    case "runtime": host.snapshot["session_id"] = .string("replacement-runtime")
    case "target":
        host.root = "another-stored-chat"
        host.snapshot["stored_session_id"] = .string(host.root)
        host.snapshot["session_key"] = .string(host.root)
    default:
        host.snapshot["replay_epoch"] = .string("replacement-epoch")
        host.replay["replay_epoch"] = .string("replacement-epoch")
    }
    let next = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    #expect(next.activity?.lineage != first.activity?.lineage)
    #expect(next.activity?.reaction == nil)
    #expect(next.access != first.access)
}

@MainActor @Test(arguments: ["unstarted", "foreign-admission", "foreign-generation", "contradictory-outcome", "missing-admission"])
func conversationActivityUnprovenCompletionStaysQuiet(reason: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["running"] = .bool(false)
    var values: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { values.append(value) } }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    var sequence = 1
    if reason != "unstarted" {
        var start = host.event("message.start", seq: sequence)
        start["params"]["admission_id"] = reason == "missing-admission" ? .null : .string("active")
        host.sockets[0].push(start)
        try await eventually { values.last?.snapshot.lastSequence == sequence }
        sequence += 1
    }
    if reason == "foreign-admission" || reason == "foreign-generation" {
        host.sockets[0].push(host.event("message.delta", seq: sequence, payload: ["text": .string("Current reply")]))
        try await eventually { values.last?.snapshot.lastSequence == sequence }
        sequence += 1
    }
    let beforeTerminal = values.last?.snapshot
    var terminal = host.event("message.complete", seq: sequence, payload: ["status": .string("complete")])
    if reason == "foreign-admission" || reason == "foreign-generation" {
        terminal["params"]["payload"]["text"] = .string("Foreign completion")
    }
    terminal["params"]["admission_id"] = .string(reason == "foreign-admission" ? "other" : "active")
    if reason == "missing-admission" { terminal["params"]["admission_id"] = .null }
    if reason == "foreign-generation" { terminal["params"]["execution_generation"] = .number(6) }
    if reason == "contradictory-outcome" { terminal["params"]["payload"]["outcome"] = .string("cancelled") }
    host.sockets[0].push(terminal)
    try await eventually { values.last?.snapshot.lastSequence == sequence }
    #expect(values.allSatisfy { $0.activity?.reaction == nil })
    if reason == "foreign-admission" || reason == "foreign-generation" {
        #expect(values.last?.activity?.phase == .replying)
        #expect(values.last?.snapshot.isWorking == true)
        #expect(values.last?.snapshot.messages == beforeTerminal?.messages)
    }
}

@MainActor private func liveActivityEvent(_ host: HermesTestHost, _ type: String, seq: Int,
                                         payload: [String: HermesJSON] = [:]) -> HermesJSON {
    var frame = host.event(type, seq: seq, payload: payload)
    if host.authority { frame["params"]["admission_id"] = .string("live-admission") }
    return frame
}
