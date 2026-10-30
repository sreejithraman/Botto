import Foundation

extension HermesBotService {
    /// Searches up to three newest pages without attaching or acknowledging the chat.
    public func conversationPreview(_ identity: SessionIdentity) async throws -> ConversationPreviewRead {
        try Task.checkCancellation()
        _ = try readyGateway()
        let owner = connectionGeneration
        guard let http, Self.safeSegment(identity.stored.text),
              knownIdentityProof(identity) != nil, !catalogTipChanged(for: identity) else {
            throw HermesServiceError.wrongConversation
        }
        let limit = 100
        for offset in stride(from: 0, to: 300, by: limit) {
            try Task.checkCancellation()
            let page = try await http.json("api/sessions/\(identity.stored.text)/messages", query: [
                URLQueryItem(name: "profile", value: identity.profile.text),
                URLQueryItem(name: "order", value: "latest"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
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
                guard pagination["offset"].integer == offset, pagination["limit"].integer == limit,
                      pagination["order"].text == "latest", pagination["returned"].integer == rows.count else {
                    throw HermesServiceError.incompatible
                }
            }
            guard page["messages_omitted"].flag != true,
                  !rows.contains(where: { $0["archived_truncated"].flag == true }) else {
                return .init(preview: nil, isComplete: false)
            }
            let displayRows = rows.map { raw -> HermesJSON in
                guard raw["display_content"] != .null else { return raw }
                var display = raw
                display["content"] = raw["display_content"]
                display["text"] = .null
                return display
            }
            let messages = HermesConversationState.messages(displayRows, stored: identity.stored.text)
            if let preview = ConversationPreview.latest(in: messages) {
                return .init(preview: preview, isComplete: true)
            }
            if rows.count < limit {
                // Legacy REST history stops at the current compression segment.
                return .init(preview: nil, isComplete: adapter == .authority || identity.root == identity.stored)
            }
        }
        return .init(preview: nil, isComplete: false)
    }
}
