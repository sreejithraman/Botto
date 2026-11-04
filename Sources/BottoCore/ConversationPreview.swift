import Foundation

public struct ConversationPreview: Codable, Equatable, Sendable {
    public let messageID: String
    public let text: String
    public let timestamp: Date?

    public init?(message: ChatMessage) {
        guard message.role == .user || message.role == .assistant,
              message.isVisible, message.displayKind != "hidden" else { return nil }
        if message.role == .assistant, message.displayKind != "failed_turn", message.isSilent == true,
           HermesMessagePresentation.isSilence(message.text, partial: true) { return nil }
        let summary: String
        if HermesMessagePresentation.isMachinery(message.displayKind), message.botSender == nil {
            guard let notification = message.notificationPresentation,
                  message.displayKind != "internal_notification",
                  notification.title.lowercased().hasSuffix(" failed")
                    || notification.title.lowercased().hasPrefix("subagent task failed: ") else { return nil }
            summary = notification.title
        } else if message.displayKind == "failed_turn",
                  message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || HermesMessagePresentation.isSilence(message.text) {
            summary = "Reply failed"
        } else {
            var displayMessage = message
            displayMessage.text = message.role == .assistant && HermesMessagePresentation.isSilence(message.text) ? "" : message.attributedText
            let display = AttachmentPresentation.display(displayMessage)
            let text = ReplyContent.summary(display.text)
            if !text.isEmpty { summary = text }
            else if !display.attachments.isEmpty {
                summary = display.attachments.allSatisfy { $0.mimeType.hasPrefix("image/") } ? "Shared a photo" : "Shared a file"
            } else { return nil }
        }
        messageID = message.id
        text = summary
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
