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
