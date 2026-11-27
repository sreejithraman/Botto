// Exact remote identity, observable inventory, and revocable live access.
// Cached Conversation values remain inert; only the owning service resolves access.
import Foundation

public struct ExactID: Hashable, Codable, Sendable {
    public let bytes: Data
    public init(_ text: String) throws {
        guard !text.isEmpty else { throw ConversationServiceError.wrongConversation }
        bytes = Data(text.utf8)
    }
    public var text: String { String(decoding: bytes, as: UTF8.self) }
    private enum CodingKeys: String, CodingKey { case bytes }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let data = try values.decode(Data.self, forKey: .bytes)
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .bytes, in: values, debugDescription: "Expected a nonempty UTF-8 identity")
        }
        bytes = data
    }
}

public struct SessionIdentity: Hashable, Codable, Sendable {
    public let profile: ExactID
    public let root: ExactID
    public let stored: ExactID
    public let aliases: Set<ExactID>
    public init(profile: ExactID, root: ExactID, stored: ExactID, aliases: Set<ExactID>) {
        self.profile = profile; self.root = root; self.stored = stored; self.aliases = aliases
    }
}
public enum SessionPersistence: String, Codable, Sendable { case durable, liveOnly, unknown }
public struct SessionSummary: Codable, Equatable, Sendable {
    public let identity: SessionIdentity
    public let title: String
    public let isCanonical: Bool
    public let persistence: SessionPersistence // display fact; never grants a history-404 exception
    public let preview: String
    public let hasPreview: Bool?
    public let updatedAt: Date?
    public let messageCount: Int?
    public init(identity: SessionIdentity, title: String, isCanonical: Bool, persistence: SessionPersistence,
                preview: String? = nil, updatedAt: Date? = nil, messageCount: Int? = nil) {
        self.identity = identity; self.title = title; self.isCanonical = isCanonical; self.persistence = persistence
        self.preview = preview ?? ""; hasPreview = preview != nil
        self.updatedAt = updatedAt; self.messageCount = messageCount
    }
}
public enum ObservedActivity: Sendable { case known(BotStatus, Date), unknown(String) }
public struct ProfileActivityUpdate: Sendable {
    public let profile: ExactID
    public let observations: [SessionIdentity: ObservedActivity]
    public init(profile: ExactID, observations: [SessionIdentity: ObservedActivity]) {
        self.profile = profile; self.observations = observations
    }
}
/// Botto's current inventory of the Spaces it can list for one bot. A Space missing from it
/// is unavailable here until a later directory lists it; that says nothing about whether its
/// thread still exists on the host.
public struct ConversationDirectory: Sendable {
    public let summaries: [SessionSummary]
    public let activity: [SessionIdentity: ObservedActivity]
    public init(summaries: [SessionSummary], activity: [SessionIdentity: ObservedActivity]) {
        self.summaries = summaries; self.activity = activity
    }
}
public enum SessionTarget: Sendable {
    case canonical(profile: ExactID, expectedRoot: ExactID?)
    case stored(SessionIdentity)
}

// No public initializer or Codable. Only the owning issuer resolves a grant.
public struct ConversationAccess: Hashable, Sendable {
    fileprivate let issuer: UUID
    fileprivate let nonce: UUID
}
// Adapter-private Context carries validated identity, runtime/replay/generation and routes.
// The public generic construction path works in the App target and in test modules.
@MainActor public final class ConversationIssuer<Context> {
    private let identity = UUID()
    private var current: (nonce: UUID, context: Context)?
    private var closed = false
    public init() {}
    public func issue(_ context: Context) throws -> ConversationAccess {
        guard !closed else { throw ConversationServiceError.staleConversation }
        let nonce = UUID()
        current = (nonce, context)
        return ConversationAccess(issuer: identity, nonce: nonce)
    }
    public func resolve(_ access: ConversationAccess) throws -> Context {
        guard !closed, access.issuer == identity, let current,
              current.nonce == access.nonce else { throw ConversationServiceError.staleConversation }
        return current.context
    }
    public func retireAttachment() { current = nil }
    public func close() { closed = true; current = nil }
}
public struct OpenedConversation: Sendable {
    public let identity: SessionIdentity
    public let snapshot: Conversation
    public let access: ConversationAccess
    /// Process-local causal ordering for this read; absent on incremental publications.
    public let historyReadStartedAt: ContinuousClock.Instant?
    public let observedSource: SessionIdentity?
    public let activity: ConversationActivity?
    public init(identity: SessionIdentity, snapshot: Conversation, access: ConversationAccess,
                activity: ConversationActivity? = nil,
                historyReadStartedAt: ContinuousClock.Instant? = nil, observedSource: SessionIdentity? = nil) {
        self.identity = identity; self.snapshot = snapshot; self.access = access
        self.activity = activity
        self.historyReadStartedAt = historyReadStartedAt
        self.observedSource = observedSource
    }
}
public struct CreatedSession: Sendable {
    public let operationID: UUID
    public let summary: SessionSummary
    public init(operationID: UUID, summary: SessionSummary) {
        self.operationID = operationID; self.summary = summary
    }
}
public struct MutationReceipt: Sendable {
    public let operationID: UUID
    public let source: SessionIdentity
    public let admissionID: String?
    // Receipt is created only after validating a positive host ACK, not turn completion.
    public init(operationID: UUID, source: SessionIdentity, admissionID: String?) {
        self.operationID = operationID; self.source = source; self.admissionID = admissionID
    }
}
