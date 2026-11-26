import Foundation
import BottoCore
@testable import Botto

/// The retired Search screen's query over the Library index. Index tests read
/// through it until the index itself is removed.
struct LibrarySearchResults {
    struct MessageMatch: Identifiable {
        struct ID: Hashable { let chat: LibraryChat.ID; let message: Data }
        let chat: LibraryChat
        let message: ChatMessage
        let snippet: String
        var id: ID { ID(chat: chat.id, message: Data(message.id.utf8)) }
    }

    let bots: [BotProfile]
    let chats: [LibraryChat]
    let artifacts: [LibraryArtifact]
    let messages: [MessageMatch]
    let hasMoreMessages: Bool
    var isEmpty: Bool { bots.isEmpty && chats.isEmpty && artifacts.isEmpty && messages.isEmpty }

    init(query: String, bots: [BotProfile], chats: [LibraryChat], artifacts: [LibraryArtifact]) {
        guard !query.isEmpty else {
            self.bots = []; self.chats = []; self.artifacts = []; messages = []; hasMoreMessages = false
            return
        }
        self.bots = bots.filter { $0.name.localizedStandardContains(query) || $0.description.localizedStandardContains(query) }
        self.chats = chats.filter { $0.title.localizedStandardContains(query) }
        self.artifacts = artifacts.filter {
            $0.artifact.title.localizedStandardContains(query) || $0.artifact.searchableText.localizedStandardContains(query)
        }
        var matches: [MessageMatch] = []
        var overflow = false
        for chat in chats {
            for message in chat.messages.reversed() {
                guard let readable = chat.searchableText[Data(message.id.utf8)]?.first(where: {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
                }) else { continue }
                guard matches.count < 50 else { overflow = true; break }
                matches.append(MessageMatch(chat: chat, message: message, snippet: Self.snippet(readable, query: query)))
            }
            if overflow { break }
        }
        messages = matches
        hasMoreMessages = overflow
    }

    private static func snippet(_ text: String, query: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let range = collapsed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(collapsed.prefix(160))
        }
        let start = collapsed.index(range.lowerBound, offsetBy: -45, limitedBy: collapsed.startIndex) ?? collapsed.startIndex
        let end = collapsed.index(range.upperBound, offsetBy: 100, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        return (start == collapsed.startIndex ? "" : "…") + collapsed[start..<end] + (end == collapsed.endIndex ? "" : "…")
    }
}
