import Foundation
import Testing
@testable import BottoCore

struct HermesResultProjectionTests {
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
        let nextAdmission = fresh.turnID
        fresh.retainToolIdentities(from: prior)
        fresh.reduce(.object(["type": .string("message.start"), "execution_generation": .number(8),
            "admission_id": .string(nextAdmission), "payload": .object([:])]), authority: true)
        var next = start; next["args"] = .object(["command": .string("Another turn's work")])
        fresh.updateTool(next, complete: false)
        #expect(fresh.conversation.messages.count == 2)
        #expect(fresh.conversation.messages.first?.id == original)
        #expect(fresh.conversation.messages.last?.id != original)
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
        fresh.retainToolIdentities(from: prior)
        var completed = start; completed["result_text"] = .string("Finished output")
        fresh.updateTool(completed, complete: true)
        #expect(fresh.conversation.messages.count == 1)
        #expect(fresh.conversation.messages.first?.id == original)
        #expect(fresh.conversation.messages.first?.text == "Finished output")
    }
}
