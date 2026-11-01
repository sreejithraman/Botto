import Foundation

/// Read-only chat history. Messages are chronological within a page; the next
/// offset reads older messages. Completeness does not acknowledge a chat as read.
public struct ConversationHistoryPage: Sendable {
    public struct Failure: Error, LocalizedError, Sendable {
        public let identity: SessionIdentity
        public let unavailableMessageIDs: Set<Data>
        public init(identity: SessionIdentity, unavailableMessageIDs: Set<Data>) {
            self.identity = identity; self.unavailableMessageIDs = unavailableMessageIDs
        }
        public var errorDescription: String? { HermesServiceError.incompatible.errorDescription }
    }
    public let messages: [ChatMessage]
    public let nextOffset: Int?
    /// False when content is known to be missing. Older pages can still exist
    /// when this is true; callers must also follow nextOffset.
    public let isComplete: Bool
    /// Message IDs before visible filtering, including omitted rows.
    public let sourceIDs: Set<Data>?
    public let unavailableMessageIDs: Set<Data>

    public init(messages: [ChatMessage], nextOffset: Int?, isComplete: Bool, sourceIDs: Set<Data>? = nil,
                unavailableMessageIDs: Set<Data> = []) {
        self.messages = messages
        self.nextOffset = nextOffset
        self.isComplete = isComplete
        self.sourceIDs = sourceIDs
        self.unavailableMessageIDs = unavailableMessageIDs
    }
}
