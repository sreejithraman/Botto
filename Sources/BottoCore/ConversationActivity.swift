import Foundation

public enum ConversationWorkPhase: Sendable, Equatable {
    case working, thinking, tools, replying
}

public struct TurnReaction: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case succeeded, failed }
    public let id: UUID
    public let kind: Kind
    public let occurredAt: Date
    public init(id: UUID = UUID(), kind: Kind, occurredAt: Date) {
        self.id = id; self.kind = kind; self.occurredAt = occurredAt
    }
}

public struct ConversationActivity: Sendable, Equatable {
    public let lineage: UUID
    public let phase: ConversationWorkPhase?
    public let workStartedAt: Date?
    public let phaseStartedAt: Date?
    public let reaction: TurnReaction?
    public init(lineage: UUID, phase: ConversationWorkPhase?, workStartedAt: Date?,
                phaseStartedAt: Date?, reaction: TurnReaction? = nil) {
        self.lineage = lineage; self.phase = phase; self.workStartedAt = workStartedAt
        self.phaseStartedAt = phaseStartedAt; self.reaction = reaction
    }
}
