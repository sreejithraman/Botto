import Foundation

extension HermesBotService {
    public func conversationHistory(_ identity: SessionIdentity, offset: Int) async throws -> ConversationHistoryPage {
        guard offset >= 0, offset <= 100_000, offset.isMultiple(of: 100) else {
            throw HermesServiceError.incompatible
        }
        let owner = connectionGeneration
        try validateHistorySource(identity, connection: owner)
        guard let http, Self.safeSegment(identity.stored.text) else { throw HermesServiceError.wrongConversation }
        let page = try await http.json("api/sessions/\(identity.stored.text)/messages", query: [
            URLQueryItem(name: "profile", value: identity.profile.text),
            URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "include_compacted", value: "true"),
            URLQueryItem(name: "inline_images", value: "false")])
        try validateHistorySource(identity, connection: owner)
        guard exact(page["session_id"].text, identity.stored.text),
              exact(page["profile"].text, identity.profile.text),
              let rows = page["messages"].list else { throw HermesServiceError.wrongConversation }
        guard rows.count <= 100 else { throw HermesServiceError.incompatible }
        let pagination = page["pagination"]
        if pagination != .null {
            guard pagination["offset"].integer == offset, pagination["limit"].integer == 100,
                  pagination["order"].text == "latest", pagination["returned"].integer == rows.count else {
                throw HermesServiceError.incompatible
            }
        }
        // A library needs stable row identities across pages and refreshes. The
        // active transcript's index fallback cannot identify separate pages.
        var ids = Set<Int>()
        for row in rows {
            guard let id = row["row_id"].integer ?? row["_row_id"].integer ?? row["id"].integer,
                  id >= 0 else { throw HermesServiceError.incompatible }
            ids.insert(id)
        }
        let unavailable = HermesConversationState.unavailableMessageIDs(rows, stored: identity.stored.text)
        let projected = rows.map { raw -> HermesJSON in
            guard raw["display_content"] != .null else { return raw }
            var display = raw
            display["content"] = raw["display_content"]
            display["text"] = .null
            return display
        }
        let hasMore = rows.count == 100
        let nextOffset = hasMore && offset < 100_000 ? offset + 100 : nil
        let complete = unavailable.isEmpty && page["messages_omitted"].flag != true
            && !rows.contains { $0["archived_truncated"].flag == true }
            && (adapter == .authority || identity.root == identity.stored)
            && !(hasMore && nextOffset == nil)
        return ConversationHistoryPage(messages: HermesConversationState.messages(projected, stored: identity.stored.text),
            nextOffset: nextOffset, isComplete: complete,
            sourceIDs: Set(ids.map { Data((identity.stored.text + ":row:" + String($0)).utf8) }),
            unavailableMessageIDs: unavailable)
    }

    public func downloadArtifact(_ attachment: ChatAttachment, in identity: SessionIdentity) async throws -> DownloadedArtifact {
        let owner = connectionGeneration
        try validateHistorySource(identity, connection: owner)
        guard let http else { throw HermesServiceError.disconnected }
        let artifact = try await http.downloadArtifact(path: attachment.path, profile: identity.profile.text,
                                                     sessionID: identity.stored.text)
        try validateHistorySource(identity, connection: owner)
        return artifact
    }

    private func validateHistorySource(_ identity: SessionIdentity, connection: Int) throws {
        try Task.checkCancellation()
        try checkConnection(connection)
        _ = try readyGateway()
        guard knownIdentityProof(identity) != nil, !catalogTipChanged(for: identity) else {
            throw HermesServiceError.wrongConversation
        }
        let aliases = identity.aliases.union([identity.root, identity.stored])
        guard catalogs[identity.profile]?.summaries.contains(where: {
            !$0.identity.aliases.union([$0.identity.root, $0.identity.stored]).isDisjoint(with: aliases)
                && $0.identity.stored != identity.stored
        }) != true else { throw HermesServiceError.wrongConversation }
    }
}
