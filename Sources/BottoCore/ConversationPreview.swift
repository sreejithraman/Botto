import Foundation

public struct ConversationPreview: Codable, Equatable, Sendable {
    public let messageID: String
    public let text: String
    public let timestamp: Date?

    public init?(message: ChatMessage) {
        guard message.role == .user || message.role == .assistant else { return nil }
        let summary = ReplyContent.summary(message.text)
        if !summary.isEmpty { text = summary }
        else if !message.attachments.isEmpty {
            text = message.attachments.allSatisfy { $0.mimeType.hasPrefix("image/") } ? "Shared a photo" : "Shared a file"
        } else { return nil }
        messageID = message.id
        timestamp = message.timestamp
    }

    public static func latest(in messages: [ChatMessage]) -> Self? {
        for message in messages.reversed() {
            if let preview = Self(message: message) { return preview }
        }
        return nil
    }
}

/// A validated newest slice of stored chat history. It carries no live access or read acknowledgment.
public struct ConversationHistoryWindow: Sendable {
    /// Messages remain in chronological order, with their full display content.
    public let messages: [ChatMessage]
    /// Older messages may exist outside this bounded read.
    public let hasEarlierMessages: Bool
    public var preview: ConversationPreview? { ConversationPreview.latest(in: messages) }
    /// Producer-checked evidence from an exhaustive response; bounded windows carry none.
    public let identityRead: ConversationIdentityRead?

    public init(messages: [ChatMessage], hasEarlierMessages: Bool, identityRead: ConversationIdentityRead? = nil) {
        self.messages = messages
        self.hasEarlierMessages = hasEarlierMessages
        self.identityRead = identityRead
    }
}
