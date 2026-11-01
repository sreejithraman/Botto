import Foundation
import Testing
@testable import BottoCore

struct HermesResultProjectionTests {
    @MainActor @Test(arguments: [false, true], ["submit", "steer"])
    func directMutationPublicationsCarryTransientIdentity(authority: Bool, kind: String) async throws {
        let host = try HermesTestHost(authority: authority), service = host.service(requestTimeout: .seconds(5))
        defer { service.disconnect() }
        host.snapshot["running"] = .bool(kind == "steer")
        let method = kind == "steer" ? "session.steer" : "prompt.submit"
        host.methodOverride = { frame, socket in
            if frame["method"].text == method { return nil }
            return host.defaultReply(frame, socket: socket)
        }
        _ = try await service.connect(configuration: host.configuration)
        let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
        var latest = opened
        service.onEvent = { if case .conversation(let value) = $0 { latest = value } }
        let operation = UUID(), text = "@file:/pending-report.txt"
        let sending = Task {
            try await service.send(text: text, attachments: [], delivery: kind == "steer" ? .steer : .queue,
                access: opened.access, operationID: operation)
        }
        defer { sending.cancel() }
        try await eventually { host.sockets.first?.sent.contains { $0["method"].text == method } == true }
        let socket = try #require(host.sockets.first)
        let request = try #require(socket.sent.first { $0["method"].text == method })
        let id = (kind == "steer" ? "steer:" : "submission:") + operation.uuidString
        if kind == "steer" {
            #expect(!latest.snapshot.messages.contains { $0.id == id }, "Steering publishes only after its receipt")
            socket.push(.object(["jsonrpc": .string("2.0"), "id": request["id"], "result": .object([
                "status": .string("queued"), "execution_generation": .number(7)])]))
            _ = try await sending.value
        }
        let local = try #require(latest.snapshot.messages.first { $0.id == id })
        #expect(local.text == text && local.transientID != nil)
        #expect(!local.hasStableIdentity(storedID: opened.identity.stored.text))
        if kind == "submit" {
            socket.reject(request, code: -32602)
            await #expect(throws: HermesServiceError.self) { _ = try await sending.value }
            #expect(!latest.snapshot.messages.contains { $0.id == id })
        }
        let row: HermesJSON = .object(["row_id": .number(7), "role": .string("user"), "text": .string(text)])
        host.snapshot["running"] = .bool(false); host.snapshot["messages"] = .array([row]); host.storedRows = [row]
        let refreshed = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
        let durable = try #require(refreshed.snapshot.messages.first { $0.id == opened.identity.stored.text + ":row:7" })
        #expect(durable.transientID == nil && durable.hasStableIdentity(storedID: opened.identity.stored.text))
    }
    @Test(arguments: ["process_complete", "hidden", "model_only", "ordinary"])
    func timestampOnlyInflightAppliesHostProvenanceToItsPersistedRow(_ kind: String) throws {
        let history: [HermesJSON] = [
            .object(["row_id": .number(1), "role": .string("user"), "content": .string("Earlier human input"), "timestamp": .number(100)]),
            .object(["row_id": .number(7), "role": .string("user"), "content": .string("Persisted work"), "timestamp": .number(200)])
        ]
        var inflight: HermesJSON = .object(["user": .string("Persisted work"), "started_at": .number(200)])
        if kind == "model_only" { inflight["display_metadata"] = .object(["model_only": .bool(true)]) }
        else if kind != "ordinary" {
            inflight["display_kind"] = .string(kind)
            inflight["display_metadata"] = .object(["display_text": .string("Background process finished")])
        }
        var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
        try state.restore(.object(["session_id": .string("runtime"), "session_key": .string("stored"), "running": .bool(true), "inflight": inflight]), history: history, authority: false)
        #expect(state.conversation.messages.first?.text == "Earlier human input")
        let restored = state.conversation.messages.first { $0.id == "stored:row:7" }
        if kind == "hidden" || kind == "model_only" { #expect(restored == nil) }
        else {
            #expect(state.conversation.messages.count == 2)
            #expect(restored?.isOutgoingUserMessage == (kind == "ordinary"))
            #expect(restored?.displayKind == (kind == "ordinary" ? nil : kind))
            #expect(restored?.displayText == (kind == "ordinary" ? nil : "Background process finished"))
        }
    }

    @Test(arguments: [
        (###"{"content":"## Worker\nDone","success":true}"###, ###"{"content":"## Worker\nDone","success":true}"###),
        (#"{"output":"failed","exit_code":2,"error":"permission denied","status":"error"}"#, #"{"error":"permission denied","exit_code":2,"output":"failed","status":"error"}"#),
        (#"[{"type":"text","text":"Result"},{"process_id":"proc_1","status":"running"}]"#, #"[{"text":"Result","type":"text"},{"process_id":"proc_1","status":"running"}]"#)
    ])
    func structuredResultsKeepEveryFieldAcrossHistoryAndLive(_ input: String, _ expected: String) throws {
        let result = try HermesJSON.decode(Data(input.utf8))
        let history = HermesConversationState.messages([
            .object(["role": .string("tool"), "name": .string("terminal"), "content": result])
        ], stored: "stored")
        #expect(history.first?.text == expected)
        var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
        state.reduce(.object(["type": .string("tool.complete"), "payload": .object([
            "tool_id": .string("tool-1"), "name": .string("terminal"), "result": result
        ])]), authority: true)
        #expect(state.conversation.messages.last?.text == expected)
        #expect(state.conversation.messages.last?.toolName == "terminal")
    }

    @Test func providedToolTextKeepsItsExactBytes() {
        let raw = " {\n  \"output\" : \"Done\", \"exit_code\":0\n}\n"
        let history = HermesConversationState.messages([
            .object(["role": .string("tool"), "text": .string(raw), "content": .object(["output": .string("other")])])
        ], stored: "stored")
        #expect(history.first?.text == raw)
        var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
        state.reduce(.object(["type": .string("tool.complete"), "payload": .object([
            "tool_id": .string("tool-1"), "result_text": .string(raw), "result": .object(["output": .string("other")])
        ])]), authority: true)
        #expect(state.conversation.messages.last?.text == raw)
    }

    @Test(arguments: [nil, "process_complete", "hidden"] as [String?])
    func restoredInflightRespectsOnlyHostProvenance(_ kind: String?) throws {
        var inflight: HermesJSON = .object(["user": .string("Background process output"), "assistant": .string("Still checking")])
        if let kind {
            inflight["display_kind"] = .string(kind)
            inflight["display_metadata"] = .object(["display_text": .string("Background process finished")])
        }
        var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
        try state.restore(.object(["session_id": .string("runtime"), "session_key": .string("stored"), "running": .bool(true), "inflight": inflight]), history: [], authority: false)
        let user = state.conversation.messages.first { $0.role == .user }
        if kind == "hidden" { #expect(user == nil) }
        else {
            #expect(user?.displayKind == kind)
            #expect(user?.isOutgoingUserMessage == (kind == nil))
            #expect(user?.displayText == (kind == nil ? nil : "Background process finished"))
        }
        #expect(state.conversation.messages.last?.text == "Still checking")
    }
    @Test func repeatedUnidentifiedInflightTurnsHaveCurrentButNotDurableIdentity() throws {
        let snapshot: HermesJSON = .object(["session_id": .string("runtime"), "session_key": .string("stored"),
            "running": .bool(true), "inflight": .object(["user": .string("@file:/report.txt")])])
        var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
        try state.restore(snapshot, history: [], authority: false)
        let first = try #require(state.conversation.messages.first)
        try state.restore(snapshot, history: [], authority: false)
        let second = try #require(state.conversation.messages.first)
        #expect(first.id == second.id && first.timestamp == nil && second.timestamp == nil)
        #expect(first.transientID != nil && second.transientID != first.transientID)
        #expect(!first.hasStableIdentity(storedID: "stored") && !second.hasStableIdentity(storedID: "stored"))
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(second))
        #expect(restored.transientID == second.transientID && !restored.hasStableIdentity(storedID: "stored"))
        let legacy = ChatMessage(id: "inflight-user", role: .user, text: first.text)
        #expect(!legacy.hasStableIdentity(storedID: "stored"))
        try state.restore(.object(["session_id": .string("runtime"), "session_key": .string("stored"), "running": .bool(false)]),
            history: [.object(["row_id": .number(7), "role": .string("user"), "text": .string(first.text)])], authority: false)
        let durable = try #require(state.conversation.messages.first)
        #expect(durable.id == "stored:row:7" && durable.transientID == nil && durable.hasStableIdentity(storedID: "stored"))
    }
    @Test(arguments: [nil, "async_delegation_complete", "hidden"] as [String?])
    func inflightMetadataOverridesOnlyItsIdentifiedHistoryRow(_ override: String?) throws {
        let history: [HermesJSON] = [.object([
            "row_id": .number(7), "role": .string("user"), "content": .string("Persisted work"),
            "display_kind": .string("process_complete"),
            "display_metadata": .object(["display_text": .string("Background process finished")])
        ])]
        var inflight: HermesJSON = .object(["user": .string("Persisted work"), "user_row_id": .number(7)])
        if let override {
            inflight["display_kind"] = .string(override)
            inflight["display_metadata"] = .object(["display_text": .string("Background agents finished")])
        }
        var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
        try state.restore(.object(["session_id": .string("runtime"), "session_key": .string("stored"), "running": .bool(true), "inflight": inflight]), history: history, authority: false)
        if override == "hidden" { #expect(state.conversation.messages.isEmpty) }
        else {
            #expect(state.conversation.messages.count == 1)
            #expect(state.conversation.messages.first?.id == "stored:row:7")
            #expect(state.conversation.messages.first?.displayKind == (override ?? "process_complete"))
            #expect(state.conversation.messages.first?.displayText == (override == nil ? "Background process finished" : "Background agents finished"))
            #expect(state.conversation.messages.first?.isOutgoingUserMessage == false)
        }
    }

}

struct HermesToolIdentityTests {
    @Test(arguments: ["complete", "missing-replay", "reused-call", "changed-output"])
    func completedExecutionNeedsReplayProofWhenTheNextExecutionOutrunsRefresh(proof: String) throws {
        var prior = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        prior.generation = 7
        prior.updateTool(.object(["tool_id": .string("call"), "name": .string("terminal"), "result_text": .string("Result")]), complete: true)
        let original = try #require(prior.conversation.messages.first?.id)
        let row: HermesJSON = .object(["row_id": .number(5), "role": .string("tool"), "tool_call_id": .string("call"),
            "content": .string(proof == "changed-output" ? "Another result" : "Result")])
        var fresh = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        fresh.generation = 8
        try fresh.restore(.object(["session_id": .string("runtime"), "session_key": .string("stored"), "running": .bool(true)]), history: [row], authority: false)
        func event(_ type: String, generation: Int) -> HermesJSON {
            .object(["type": .string(type), "session_id": .string("runtime"), "replay_epoch": .string("epoch"),
                "execution_generation": .number(Double(generation)), "payload": .object(["tool_id": .string("call")])])
        }
        var replay = [event("tool.complete", generation: 7), event("message.complete", generation: 7), event("message.start", generation: 8)]
        if proof == "missing-replay" { replay = [] }
        if proof == "reused-call" { replay.append(event("tool.start", generation: 8)) }
        fresh.retainToolIdentities(from: prior, replay: replay)
        #expect(fresh.conversation.messages.first?.workDetailsID == (proof == "complete" ? original : nil))
    }

    @Test(arguments: [false, true])
    func durableDisclosureSurvivesLaterCallReuseWithoutBorrowingIt(ambiguous: Bool) throws {
        var prior = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        let row: HermesJSON = .object(["row_id": .number(5), "role": .string("tool"), "tool_call_id": .string("call"), "content": .string("First result")])
        try prior.restore(.object(["session_id": .string("runtime"), "session_key": .string("stored")]), history: [row], authority: false)
        prior.conversation.messages[0].workDetailsID = "tool:first:call"
        var later = row; later["row_id"] = .number(6); later["content"] = .string("Later result")
        var fresh = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        try fresh.restore(.object(["session_id": .string("runtime"), "session_key": .string("stored")]), history: [row, later], authority: false)
        if ambiguous { fresh.conversation.unavailableMessageIDs = [Data("stored:row:5".utf8)] }
        fresh.retainToolIdentities(from: prior)
        #expect(fresh.conversation.messages[0].workDetailsID == (ambiguous ? nil : "tool:first:call"))
        #expect(fresh.conversation.messages[1].workDetailsID == nil)
    }

    @Test func absentExecutionCannotConnectDifferentDurableOccurrences() throws {
        var prior = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        var row: HermesJSON = .object(["row_id": .number(5), "role": .string("tool"), "tool_call_id": .string("call"), "content": .string("First result")])
        try prior.restore(.object(["session_id": .string("runtime"), "session_key": .string("stored")]), history: [row], authority: false)
        row["row_id"] = .number(6); row["content"] = .string("Different occurrence")
        var fresh = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        try fresh.restore(.object(["session_id": .string("runtime"), "session_key": .string("stored")]), history: [row], authority: false)
        fresh.retainToolIdentities(from: prior)
        #expect(fresh.conversation.messages.first?.workDetailsID == nil)
    }

    @Test func disclosureIdentityDoesNotChangeDurableMessageBytes() throws {
        let durable = ChatMessage(id: "stored:row:5", role: .tool, text: "MEDIA:/report.txt", toolName: "terminal")
        var displayed = durable; displayed.workDetailsID = "tool:live:call"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(displayed) == encoder.encode(durable))
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoder.encode(displayed))
        #expect(decoded == durable)
    }

    @Test(arguments: ["duplicate-call", "duplicate-row", "missing-call", "different-call", "generation", "epoch", "stored", "profile"])
    func ambiguousOrDifferentSourcesCannotRetainToolIdentity(change: String) throws {
        var prior = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        prior.generation = 7
        prior.updateTool(.object(["tool_id": .string("call"), "name": .string("terminal")]), complete: false)
        var row: HermesJSON = .object(["row_id": .number(5), "role": .string("tool"), "tool_call_id": .string("call"), "content": .string("Result")])
        if change == "missing-call" { row["tool_call_id"] = .null }
        if change == "different-call" { row["tool_call_id"] = .string("another") }
        var history = [row]
        if change == "duplicate-call" { var duplicate = row; duplicate["row_id"] = .number(6); history.append(duplicate) }
        if change == "duplicate-row" { history.append(.object(["row_id": .number(5), "role": .string("assistant"), "content": .string("Duplicate")])) }
        let stored = change == "stored" ? "another" : "stored"
        var fresh = HermesConversationState(profile: change == "profile" ? "another" : "bot", root: "root", stored: stored,
            runtime: "runtime", epoch: change == "epoch" ? "another" : "epoch")
        fresh.generation = change == "generation" ? 8 : 7
        try fresh.restore(.object(["session_id": .string("runtime"), "session_key": .string(stored)]), history: history, authority: false)
        fresh.retainToolIdentities(from: prior)
        #expect(fresh.conversation.messages.first?.id == stored + ":row:5")
        #expect(fresh.conversation.messages.first?.workDetailsID == nil)
    }

    @Test func aNewTurnCannotReuseARetiredToolAlias() throws {
        var prior = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        prior.generation = 7
        let start: HermesJSON = .object(["tool_id": .string("call"), "name": .string("terminal")])
        prior.updateTool(start, complete: false)
        let original = try #require(prior.conversation.messages.first?.id)
        var fresh = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        fresh.generation = 7
        fresh.updateTool(start, complete: false)
        let nextAdmission = "another-turn"
        fresh.retainToolIdentities(from: prior)
        fresh.reduce(.object(["type": .string("message.start"), "execution_generation": .number(8),
            "admission_id": .string(nextAdmission), "payload": .object([:])]), authority: true)
        var next = start; next["args"] = .object(["command": .string("Another turn's work")])
        fresh.updateTool(next, complete: false)
        #expect(fresh.conversation.messages.count == 2)
        #expect(fresh.conversation.messages.first?.workDetailsID == original)
        #expect(fresh.conversation.messages.first?.id != fresh.conversation.messages.last?.id)
        #expect(fresh.conversation.messages.last?.workDetailsID == nil)
        #expect(fresh.conversation.messages.last?.text == "Another turn's work")
    }

    @Test func aRunningRefreshRetainsTheToolThroughItsLaterCompletion() throws {
        var prior = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        prior.generation = 7
        let start: HermesJSON = .object(["tool_id": .string("call"), "name": .string("terminal")])
        prior.updateTool(start, complete: false)
        let original = try #require(prior.conversation.messages.first?.id)
        var fresh = HermesConversationState(profile: "bot", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
        fresh.generation = 7
        fresh.updateTool(start, complete: false)
        let sourceID = fresh.conversation.messages.first?.id
        fresh.retainToolIdentities(from: prior)
        var completed = start; completed["result_text"] = .string("Finished output")
        fresh.updateTool(completed, complete: true)
        #expect(fresh.conversation.messages.count == 1)
        #expect(fresh.conversation.messages.first?.id == sourceID)
        #expect(fresh.conversation.messages.first?.workDetailsID == original)
        #expect(fresh.conversation.messages.first?.text == "Finished output")
    }
}
