import Foundation

/// Read-only chat history. Messages are chronological within a page; the next
/// offset reads older messages. Completeness does not acknowledge a chat as read.
public struct ConversationHistoryPage: Sendable {
    public let messages: [ChatMessage]
    public let nextOffset: Int?
    /// False when content is known to be missing. Older pages can still exist
    /// when this is true; callers must also follow nextOffset.
    public let isComplete: Bool

    public init(messages: [ChatMessage], nextOffset: Int?, isComplete: Bool) {
        self.messages = messages
        self.nextOffset = nextOffset
        self.isComplete = isComplete
    }
}
