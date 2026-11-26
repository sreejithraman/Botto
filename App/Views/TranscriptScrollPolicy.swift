import SwiftUI
import BottoCore

/// Reader intent stays separate from programmatic scrolling and content changes.
nonisolated struct TranscriptScrollPolicy {
    private(set) var followsLatest = true
    private(set) var isUserScrolling = false
    private var hasNewMessages = false
    var shouldFollowLatest: Bool { followsLatest && !isUserScrolling }
    var showsLatest: Bool { !followsLatest && hasNewMessages }

    static func attentionChanged(from previous: Conversation?, to current: Conversation?) -> Bool {
        switch (previous, current) {
        case (nil, nil): false
        case let (previous?, current?):
            !previous.messages.elementsEqual(current.messages, by: TranscriptContentRevision.sameMessage) ||
                !previous.pendingRequests.elementsEqual(current.pendingRequests, by: TranscriptContentRevision.sameRequest)
        default: true
        }
    }
    mutating func snapshotChanged(from previous: Conversation?, to current: Conversation?) -> Bool {
        guard Self.attentionChanged(from: previous, to: current) else { return false }
        return snapshotChanged()
    }

    mutating func snapshotChanged() -> Bool {
        if shouldFollowLatest { return true }
        hasNewMessages = true
        return false
    }

    mutating func requestLatest() {
        isUserScrolling = false
        followsLatest = true
        hasNewMessages = false
    }

    /// Native delegates call this only for reader interaction, including its
    /// final position. Programmatic fitting never supplies reader intent.
    mutating func readerChanged(isUserScrolling: Bool, isNearBottom: Bool) {
        self.isUserScrolling = isUserScrolling
        followsLatest = isNearBottom
        if isNearBottom { hasNewMessages = false }
    }
}

nonisolated struct TranscriptMessageIndex {
    private let messages: [Data: ChatMessage]
    let unavailableIDs: Set<Data>

    init(_ snapshot: Conversation?) {
        var messages: [Data: ChatMessage] = [:]
        var ambiguous = snapshot?.unavailableMessageIDs ?? []
        for message in snapshot?.messages ?? [] {
            let id = Data(message.id.utf8)
            if message.transientID == nil && !ChatMessage.isStableID(id, storedID: snapshot?.storedID ?? "") { ambiguous.insert(id) }
            if messages.updateValue(message, forKey: id) != nil { ambiguous.insert(id) }
        }
        for id in ambiguous { messages[id] = nil }
        self.messages = messages
        unavailableIDs = ambiguous
    }

    func matches(_ expected: ChatMessage) -> Bool {
        guard let message = messages[Data(expected.id.utf8)] else { return false }
        return TranscriptContentRevision.sameMessage(message, expected)
    }

    func contains(_ id: Data) -> Bool { messages[id] != nil }
}

/// Exact semantic revisions shared by display, foreground lifetime and attention.
/// No content digest or second history is retained.
nonisolated enum TranscriptContentRevision {
    static func sameMessage(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        a.role == b.role && a.timestamp == b.timestamp && a.transientID == b.transientID &&
        exact(a.id, b.id) && exact(a.text, b.text) && exact(a.toolName, b.toolName) && a.attachments.count == b.attachments.count &&
        zip(a.attachments, b.attachments).allSatisfy { first, second in
            first == second && exact(first.name, second.name) && exact(first.path, second.path) && exact(first.mimeType, second.mimeType)
        }
    }
    static func sameRequest(_ a: PendingRequest, _ b: PendingRequest) -> Bool {
        a.hasSameWireRevision(as: b)
    }
    static func sameSnapshotContent(_ a: Conversation?, _ b: Conversation?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?):
            a.messages.elementsEqual(b.messages, by: sameMessage) && a.pendingRequests.elementsEqual(b.pendingRequests, by: sameRequest)
                && (a.unavailableMessageIDs ?? []) == (b.unavailableMessageIDs ?? [])
        default: false
        }
    }
    static func uniqueMessage(_ expected: ChatMessage, in snapshot: Conversation?) -> Bool {
        guard let snapshot, snapshot.unavailableMessageIDs?.contains(Data(expected.id.utf8)) != true else { return false }
        var found = false
        for message in snapshot.messages where exact(message.id, expected.id) {
            guard !found, sameMessage(message, expected) else { return false }
            found = true
        }
        return found
    }
    static func exact(_ a: String, _ b: String) -> Bool {
        if let comparison = a.utf8.withContiguousStorageIfAvailable({ first in
            b.utf8.withContiguousStorageIfAvailable { second in
                first.count == second.count && (first.baseAddress == second.baseAddress || first.elementsEqual(second))
            }
        }), let sameBytes = comparison { return sameBytes }
        return a.utf8.elementsEqual(b.utf8)
    }
    static func exact(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): exact(a, b)
        default: false
        }
    }
}
