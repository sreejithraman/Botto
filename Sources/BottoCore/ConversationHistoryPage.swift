import Foundation

/// Holds the history-read failure that the version-dispute handling catches.
public enum ConversationHistoryPage {
    public struct Failure: Error, LocalizedError, Sendable {
        public let identity: SessionIdentity
        public let unavailableMessageIDs: Set<Data>
        /// Bounded raw identities from a rejected, correctly associated page.
        public let sourceIDs: Set<Data>
        public let exceedsRowLimit: Bool
        public init(identity: SessionIdentity, unavailableMessageIDs: Set<Data>, sourceIDs: Set<Data> = [],
                    exceedsRowLimit: Bool = false) {
            self.identity = identity; self.unavailableMessageIDs = unavailableMessageIDs
            self.sourceIDs = sourceIDs; self.exceedsRowLimit = exceedsRowLimit
        }
        public var errorDescription: String? { ConversationServiceError.incompatible.errorDescription }
    }
}
