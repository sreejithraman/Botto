import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [true, false])
func rawHistoryPageProducerCertifiesOnlyProjectedIDsFromOneExhaustiveResponse(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            return identityProofPage(identity, offset: 0, rows: [pageIdentityRow(1, text: "First reply"),
                pageIdentityRow(2, text: "Hidden carrier", kind: "hidden"), pageIdentityRow(3, text: "Latest reply")])
        }
        return try original?(request) ?? .object([:])
    }
    let page = try await service.conversationHistory(identity, offset: 0)
    #expect(page.isComplete && page.nextOffset == nil)
    let proof = try #require(page.identityRead)
    #expect(proof.matches(identity))
    #expect(proof.messageIDs == Set([Data((identity.stored.text + ":row:1").utf8), Data((identity.stored.text + ":row:3").utf8)]))
    #expect(page.sourceIDs?.count == 3)
}

private func pageIdentityRow(_ id: Int, text: String, kind: String? = nil) -> HermesJSON {
    var fields: [String: HermesJSON] = ["id": .number(Double(id)), "role": .string("assistant"), "content": .string(text)]
    if let kind { fields["display_kind"] = .string(kind) }
    return .object(fields)
}

private func identityProofPage(_ identity: SessionIdentity, offset: Int, rows: [HermesJSON]) -> HermesJSON {
    .object(["session_id": .string(identity.stored.text), "profile": .string(identity.profile.text), "messages": .array(rows),
        "pagination": .object(["limit": .number(100), "offset": .number(Double(offset)), "order": .string("latest"),
            "returned": .number(Double(rows.count))])])
}

@Test func completePageAndSourceIDsDoNotImplyProducerIdentityProof() throws {
    let source = SessionIdentity(profile: try ExactID("bot"), root: try ExactID("chat"), stored: try ExactID("chat"), aliases: [])
    let message = ChatMessage(id: "chat:row:1", role: .assistant, text: "Visible candidate")
    let ids: Set<Data> = [Data(message.id.utf8)]
    let weak = ConversationHistoryPage(messages: [message], nextOffset: nil, isComplete: true, sourceIDs: ids)
    #expect(weak.isComplete && weak.unavailableMessageIDs.isEmpty)
    #expect(weak.sourceIDs == ids)
    #expect(weak.identityRead == nil)
    let checked = ConversationHistoryPage(messages: [message], nextOffset: nil, isComplete: true, sourceIDs: ids,
        identityRead: .init(identity: source, messageIDs: ids))
    #expect(checked.identityRead?.matches(source) == true)
    #expect(checked.identityRead?.messageIDs == ids)
}

@MainActor @Test(arguments: [0, 99, 100], [0, 100])
func pageIdentityProofRequiresFirstPageExhaustion(count: Int, offset: Int) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            return identityProofPage(identity, offset: offset, rows: (0..<count).map { pageIdentityRow($0, text: "Available reply") })
        }
        return try original?(request) ?? .object([:])
    }
    let page = try await service.conversationHistory(identity, offset: offset)
    #expect(page.isComplete)
    #expect(page.messages.count == count)
    #expect((page.identityRead != nil) == (offset == 0 && count < 100))
    if let proof = page.identityRead { #expect(proof.messageIDs.count == count) }
}

@MainActor @Test(arguments: ["omitted", "truncated", "hidden-duplicate", "compressed-sidecar"])
func incompleteOrAmbiguousRawPagesCannotIssueIdentityProof(condition: String) async throws {
    let host = try HermesTestHost(authority: condition != "compressed-sidecar"), service = host.service()
    defer { service.disconnect() }
    if condition == "compressed-sidecar" {
        host.methodOverride = { frame, socket in
            if frame["method"].text == "session.list" {
                return .object(["sessions": .array([.object(["id": .string(host.root), "resolved_id": .string("compressed-tip")])])])
            }
            return host.defaultReply(frame, socket: socket)
        }
    }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            var row = pageIdentityRow(1, text: "Visible candidate")
            if condition == "truncated" { row["archived_truncated"] = .bool(true) }
            let rows = condition == "hidden-duplicate" ? [row, pageIdentityRow(1, text: "Conflicting hidden row", kind: "hidden")] : [row]
            var page = identityProofPage(identity, offset: 0, rows: rows)
            if condition == "omitted" { page["messages_omitted"] = .bool(true) }
            return page
        }
        return try original?(request) ?? .object([:])
    }
    let page = try await service.conversationHistory(identity, offset: 0)
    #expect(page.messages.count == 1)
    #expect(page.nextOffset == nil && !page.isComplete)
    #expect(page.identityRead == nil)
}

@MainActor @Test(arguments: ["missing-id", "negative-id", "wrong-profile", "wrong-tip"])
func malformedRawPageCannotPublishIdentityProof(condition: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            var row = pageIdentityRow(condition == "negative-id" ? -1 : 1, text: "Unsafe candidate")
            if condition == "missing-id" { row["id"] = .null }
            var page = identityProofPage(identity, offset: 0, rows: [row])
            if condition == "wrong-profile" { page["profile"] = .string("other") }
            if condition == "wrong-tip" { page["session_id"] = .string("other") }
            return page
        }
        return try original?(request) ?? .object([:])
    }
    await #expect(throws: (any Error).self) { try await service.conversationHistory(identity, offset: 0) }
}
