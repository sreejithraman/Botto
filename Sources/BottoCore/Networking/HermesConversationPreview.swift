import Foundation

extension HermesBotService {
    /// Reads one newest window without attaching or acknowledging the chat.
    public func recentConversationHistory(_ identity: SessionIdentity) async throws -> ConversationHistoryWindow? {
        try Task.checkCancellation()
        _ = try readyGateway()
        let owner = connectionGeneration
        guard let http, Self.safeSegment(identity.stored.text),
              knownIdentityProof(identity) != nil, !catalogTipChanged(for: identity) else {
            throw HermesServiceError.wrongConversation
        }
        // One response avoids offset drift when messages change between page reads.
        let limit = 300
        let page = try await http.json("api/sessions/\(identity.stored.text)/messages", query: [
            URLQueryItem(name: "profile", value: identity.profile.text),
            URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "include_compacted", value: "true"),
            URLQueryItem(name: "inline_images", value: "false")])
        try checkConnection(owner)
        guard !catalogTipChanged(for: identity),
              exact(page["session_id"].text, identity.stored.text),
              exact(page["profile"].text, identity.profile.text),
              let rows = page["messages"].list else { throw HermesServiceError.wrongConversation }
        guard rows.count <= limit else { throw HermesServiceError.incompatible }
        let pagination = page["pagination"]
        if pagination != .null {
            guard pagination["offset"].integer == 0, pagination["limit"].integer == limit,
                  pagination["order"].text == "latest", pagination["returned"].integer == rows.count else {
                throw HermesServiceError.incompatible
            }
        }
        guard page["messages_omitted"].flag != true,
              !rows.contains(where: { $0["archived_truncated"].flag == true }) else { return nil }
        var sourceIDs = Set<Int>()
        for row in rows {
            guard let id = row["row_id"].integer ?? row["_row_id"].integer ?? row["id"].integer,
                  id >= 0, sourceIDs.insert(id).inserted else { throw HermesServiceError.incompatible }
        }
        let displayRows = rows.map { raw -> HermesJSON in
            guard raw["display_content"] != .null else { return raw }
            var display = raw
            display["content"] = raw["display_content"]
            display["text"] = .null
            return display
        }
        let messages = HermesConversationState.messages(displayRows, stored: identity.stored.text)
        // Legacy REST history stops at the current compression segment.
        let hasEarlierMessages = rows.count == limit || (adapter != .authority && identity.root != identity.stored)
        let window = ConversationHistoryWindow(messages: messages, hasEarlierMessages: hasEarlierMessages)
        return window.preview != nil || !hasEarlierMessages ? window : nil
    }
}
