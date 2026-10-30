import Foundation
import BottoCore

struct ChatID: Hashable, Codable, Sendable, Identifiable {
    let value: UUID
    init(value: UUID = UUID()) { self.value = value }
    var id: UUID { value }
}
struct RemoteIndexKey: Hashable, Sendable { let profile: ExactID; let root: ExactID }
struct ChatDraft: Codable, Sendable {
    var text = ""
    var revision = UUID()
}
struct SeenCursor: Codable, Sendable {
    var messageID: ExactID?
    var observedAt: Date
    var content: ChatContentEvidence? = nil
    var summary: ChatSummaryEvidence? = nil
    var rawMessageCount: Int? = nil
}

/// The content actually rendered, independent of inventory activity and wall-clock reads.
struct ChatContentEvidence: Codable, Equatable, Sendable {
    let messageID: ExactID?
    let preview: Data
    let messageCount: Int
    let latestMessageAt: Date?
    var hasContent: Bool { messageID != nil || messageCount != 0 || !preview.isEmpty || latestMessageAt != nil }
    init(_ snapshot: Conversation) {
        let messages = snapshot.attentionMessages
        let last = messages.last { $0.role == .assistant || $0.role == .user }
        messageID = last.flatMap { try? ExactID($0.id) }
        preview = last.map { Data($0.text.utf8) } ?? Data()
        messageCount = messages.count
        latestMessageAt = last?.timestamp
    }
}

/// Host directory facts never manufacture transcript content or read authority.
struct ChatSummaryEvidence: Codable, Equatable, Sendable {
    let inventoryTip: ExactID?
    let preview: Data
    let updatedAt: Date?
    let messageCount: Int?
    init?(_ summary: SessionSummary) {
        guard !summary.preview.isEmpty || summary.updatedAt != nil || summary.messageCount != nil else { return nil }
        inventoryTip = summary.identity.stored
        preview = Data(summary.preview.utf8); updatedAt = summary.updatedAt; messageCount = summary.messageCount
    }
}
enum RemoteBinding: Codable, Sendable {
    case provisionalMain(legacyStored: ExactID?)
    case identified(SessionIdentity, canonical: Bool, persistence: SessionPersistence)
    var identity: SessionIdentity? {
        if case .identified(let identity, _, _) = self { return identity }
        return nil
    }
}
struct PreservedVariant: Codable, Sendable {
    let draft: ChatDraft
    let transcript: Conversation?
}
struct ActivityObservation: Codable, Equatable, Sendable {
    let status: BotStatus
    let observedAt: Date

    func isPreferredForDisplay(over previous: Self?) -> Bool {
        guard let previous else { return true }
        return displayPriority > previous.displayPriority
            || (status == previous.status && observedAt > previous.observedAt)
    }
    private var displayPriority: Int {
        switch status { case .idle: 0; case .working: 1; case .waiting: 2 }
    }
}
struct ChatRecord: Codable, Sendable {
    let id: ChatID
    let profile: ExactID
    var binding: RemoteBinding
    var transcript: Conversation?
    var draft = ChatDraft()
    var seen: SeenCursor?
    var discoveryOrdinal: UInt64
    var preservedVariants: [PreservedVariant] = []
    var title = "Main"
    var preview = ""
    var updatedAt: Date?
    var summary: ChatSummaryEvidence? = nil
    var lastKnownActivity: ActivityObservation? = nil
    // A full read proved this inventory change added only quiet automation.
    // This does not acknowledge a meaningful reply or replace the user's seen cursor.
    var quietSummary: ChatSummaryEvidence? = nil
    // An empty replacement/display cannot erase actual previously returned content.
    var hasContentHistory: Bool? = nil
    var inboxPreview: CachedInboxPreview? = nil
    var isClosedLocally: Bool? = nil
    // An unresolved legacy transcript never becomes a new remote chat by assumption.
    var isUnverified = false
}
struct CachedInboxPreview: Codable, Sendable {
    let message: ConversationPreview?
}
extension ChatRecord {
    var inboxMessage: ConversationPreview? {
        if let inboxPreview { return inboxPreview.message }
        return transcript.flatMap { ConversationPreview.latest(in: $0.messages) }
    }
    var hasInboxHistory: Bool {
        hasContentHistory == true || (summary?.messageCount ?? 0) > 0 || transcript?.messages.isEmpty == false
    }
    private var isEmptyUnpersistedDraft: Bool {
        guard !isUnverified, hasContentHistory != true, case .identified(let identity, _, .liveOnly) = binding,
              identity.profile == profile, identity.root == identity.stored,
              identity.aliases.allSatisfy({ $0 == identity.stored }),
              let transcript, transcript.messages.isEmpty,
              Data(transcript.profileID.utf8) == profile.bytes,
              Data(transcript.storedID.utf8) == identity.stored.bytes,
              let summary, summary.inventoryTip == identity.stored, summary.messageCount == 0,
              summary.preview.isEmpty, summary.updatedAt == nil,
              preview.utf8.isEmpty, updatedAt == nil, preservedVariants.isEmpty else { return false }
        return seen.map { cursor in
            guard cursor.messageID == nil, cursor.summary == nil, let content = cursor.content else { return false }
            return !content.hasContent
        } ?? true
    }
    var hasUnseenSummary: Bool {
        guard let summary else { return false }
        // Inventory counters describe active physical rows in this tip, not rendered rows.
        return seen?.summary != summary && quietSummary != summary
    }
    var isUnread: Bool {
        if isEmptyUnpersistedDraft { return false }
        if hasUnseenSummary { return true }
        if let snapshot = transcript {
            let content = ChatContentEvidence(snapshot)
            if let seenContent = seen?.content { return seenContent != content }
            if let seenID = seen?.messageID { return seenID != content.messageID }
            if let timestamp = content.latestMessageAt { return timestamp > (seen?.observedAt ?? .distantPast) }
            return seen == nil && content.messageID != nil
        }
        return updatedAt.map { $0 > (seen?.observedAt ?? .distantPast) } ?? false
    }
    // Keep transcript predicates on the record's value interface. Running them in
    // a workspace closure otherwise checks the main executor for every message.
    var userPreview: String {
        transcript?.messages.last(where: { $0.isOutgoingUserMessage && $0.requiresAttention })?.text ?? ""
    }
    var replyPreview: String {
        if let summary, !summary.preview.isEmpty, hasUnseenSummary, !isQuietPreview(summary.preview) {
            return String(decoding: summary.preview, as: UTF8.self)
        }
        if let transcript {
            if let reply = transcript.messages.last(where: { $0.role == .assistant && $0.requiresAttention }) { return reply.text }
            if !transcript.messages.isEmpty, transcript.attentionMessages.isEmpty { return "" }
        }
        return isQuietPreview(Data(preview.utf8)) ? "" : preview
    }
    private func isQuietPreview(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return false }
        if let last = transcript?.messages.last(where: { Data($0.text.utf8).starts(with: bytes) }) {
            return !last.requiresAttention
        }
        return !ChatMessage(id: "preview", role: .assistant, text: String(decoding: bytes, as: UTF8.self)).isVisible
    }
    mutating func displayed(_ snapshot: Conversation, acknowledging observation: ChatSummaryEvidence?, at now: Date) {
        let content = ChatContentEvidence(snapshot), previous = seen
        if content.hasContent || previous?.messageID != nil || previous?.content?.hasContent == true { hasContentHistory = true }
        var acknowledged = previous?.summary
        if let observation, observation == summary { acknowledged = observation }
        let observedAt = previous.flatMap { $0.content == content ? $0.observedAt : nil } ?? now
        seen = .init(messageID: content.messageID, observedAt: observedAt, content: content, summary: acknowledged,
            rawMessageCount: previous?.content == content ? (previous?.rawMessageCount ?? snapshot.messages.count) : snapshot.messages.count)
    }
}

struct ProfilePreferences: Codable, Sendable {
    let profile: ExactID
    var main: ChatID
    var lastSelected: ChatID?
    var preferred: ChatID?
}

/// Durable values only. Live grants, operations and staging belong to the workspace.
struct ConversationBook: Codable, Sendable {
    var records: [ChatRecord] = []
    var preferences: [ProfilePreferences] = []

    func record(_ id: ChatID) -> ChatRecord? { records.first { $0.id == id } }
    func preference(_ profile: ExactID) -> ProfilePreferences? { preferences.first { $0.profile == profile } }
    func ordered(_ profile: ExactID) -> [ChatRecord] {
        let main = preference(profile)?.main
        return records.filter { $0.profile == profile }.sorted {
            if ($0.id == main) != ($1.id == main) { return $0.id == main }
            return $0.discoveryOrdinal < $1.discoveryOrdinal
        }
    }
    func orderedByProfile() -> [ExactID: [ChatRecord]] {
        var mains: [ExactID: ChatID] = [:]
        for preference in preferences where mains[preference.profile] == nil {
            mains[preference.profile] = preference.main
        }
        return Dictionary(grouping: records, by: \.profile).mapValues { records in
            let main = records.first.flatMap { mains[$0.profile] }
            return records.sorted {
                if ($0.id == main) != ($1.id == main) { return $0.id == main }
                return $0.discoveryOrdinal < $1.discoveryOrdinal
            }
        }
    }
    func opening(_ profile: ExactID) -> ChatID? {
        guard let pref = preference(profile) else { return nil }
        let visible = visible(profile)
        return [pref.preferred, pref.lastSelected, pref.main].compactMap { $0 }.first {
            id in visible.contains { $0.id == id }
        } ?? visible.first?.id
    }
    func visible(_ profile: ExactID) -> [ChatRecord] {
        let main = preference(profile)?.main
        return ordered(profile).filter { $0.id == main || $0.isClosedLocally != true }
    }
    mutating func update(_ id: ChatID, _ body: (inout ChatRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index])
    }
    mutating func updatePreference(_ profile: ExactID, _ body: (inout ProfilePreferences) -> Void) {
        guard let index = preferences.firstIndex(where: { $0.profile == profile }) else { return }
        body(&preferences[index])
    }
    @discardableResult mutating func ensureProfile(_ profile: ExactID) -> ChatID {
        if let pref = preference(profile) { return pref.main }
        let record = ChatRecord(id: ChatID(), profile: profile, binding: .provisionalMain(legacyStored: nil),
                                discoveryOrdinal: nextOrdinal)
        records.append(record)
        preferences.append(.init(profile: profile, main: record.id))
        return record.id
    }
    private var nextOrdinal: UInt64 { (records.map(\.discoveryOrdinal).max() ?? 0) + 1 }
    func matching(_ identity: SessionIdentity) -> ChatID? {
        Self.matching(identity, among: records)
    }
    static func matching(_ identity: SessionIdentity, among records: [ChatRecord]) -> ChatID? {
        let aliases = Self.proven(identity)
        var match: ChatID?
        for record in records {
            guard record.profile == identity.profile,
                  let old = record.binding.identity,
                  old.root == identity.root || !Self.proven(old).isDisjoint(with: aliases) else { continue }
            guard match == nil else { return nil }
            match = record.id
        }
        return match
    }
    static func proven(_ identity: SessionIdentity) -> Set<ExactID> {
        identity.aliases.union([identity.root, identity.stored])
    }
    struct InitialMainBinding {
        fileprivate let id: ChatID
    }
    /// Capture when a pristine main enters its workspace, before any local editing.
    func captureInitialMainBinding(_ id: ChatID) -> InitialMainBinding? {
        guard let record = record(id), preference(record.profile)?.main == id,
              case .provisionalMain(nil) = record.binding, !record.isUnverified,
              record.transcript == nil, record.draft.text.utf8.isEmpty, record.seen == nil,
              record.preservedVariants.isEmpty else { return nil }
        return .init(id: id)
    }
    @discardableResult mutating func merge(_ summary: SessionSummary,
                                          initialMainBinding: InitialMainBinding? = nil) -> ChatID {
        let identity = summary.identity
        let main = ensureProfile(identity.profile)
        var id = matching(identity)
        if id == nil, summary.isCanonical, let old = record(main), case .provisionalMain(let legacy) = old.binding {
            let hasImportedState = old.transcript != nil || !old.draft.text.utf8.isEmpty || old.seen != nil
                || !old.preservedVariants.isEmpty
            // Only a main captured pristine in this workspace can keep its local edits.
            // Recheck every other kind of imported state before binding the same record.
            let hasInitialOpenDraft = initialMainBinding?.id == main && !old.isUnverified
                && old.transcript == nil && old.seen == nil && old.preservedVariants.isEmpty
            if (legacy == nil && (!hasImportedState || hasInitialOpenDraft))
                || legacy.map({ Self.proven(identity).contains($0) }) == true {
                id = main
            } else {
                update(main) { $0.isUnverified = true; $0.title = "Recovered history (unverified)" }
            }
        }
        if id == nil {
            let created = ChatRecord(id: ChatID(), profile: identity.profile,
                binding: .identified(identity, canonical: summary.isCanonical, persistence: summary.persistence),
                discoveryOrdinal: nextOrdinal)
            records.append(created); id = created.id
        }
        let bound = id!
        update(bound) { record in
            // Keep every alias only when supplied by the host for this proven lineage.
            let aliases = (record.binding.identity.map(Self.proven) ?? []).union(Self.proven(identity))
            let joined = SessionIdentity(profile: identity.profile, root: identity.root, stored: identity.stored, aliases: aliases)
            var persistence = summary.persistence
            if persistence == .unknown, summary.preview.utf8.isEmpty, summary.updatedAt == nil, summary.messageCount == nil,
               case .identified(let previous, _, let known) = record.binding,
               previous.profile == identity.profile, previous.root == identity.root, previous.stored == identity.stored {
                // Attachment publications carry no new inventory persistence observation.
                persistence = known
            }
            record.binding = .identified(joined, canonical: summary.isCanonical, persistence: persistence)
            record.title = summary.isCanonical ? "Main" : (summary.title.isEmpty ? "New chat" : summary.title)
            if summary.isCanonical { record.isClosedLocally = nil }
            if let incoming = ChatSummaryEvidence(summary) {
                if record.summary?.inventoryTip == incoming.inventoryTip,
                   let oldAt = record.summary?.updatedAt, let newAt = incoming.updatedAt, newAt < oldAt {
                    // Preserve a newer directory observation across a stale read.
                } else {
                    record.summary = incoming
                    record.preview = summary.preview
                    record.updatedAt = summary.updatedAt ?? record.updatedAt
                }
            }
            record.isUnverified = false
        }
        if summary.isCanonical {
            let previousUnverified = record(main)?.isUnverified == true
            updatePreference(identity.profile) { pref in
                let previous = pref.main
                pref.main = bound
                if pref.lastSelected == previous, !previousUnverified { pref.lastSelected = bound }
            }
        }
        return bound
    }
    mutating func cache(_ snapshot: Conversation, for id: ChatID, readEvidence: ConversationReadEvidence? = nil) {
        update(id) { record in
            if let observed = readEvidence?.summaryObservedBeforeRead,
               let identity = record.binding.identity,
               observed.identity.profile == identity.profile, observed.identity.root == identity.root,
               observed.identity.stored == identity.stored,
               Data(snapshot.profileID.utf8) == identity.profile.bytes,
               Data(snapshot.storedID.utf8) == identity.stored.bytes,
               let previous = record.transcript, snapshot.pendingRequests.isEmpty,
               let baselineCount = record.seen?.rawMessageCount, baselineCount >= 0,
               snapshot.messages.count > baselineCount,
               snapshot.messages.starts(with: previous.messages),
               snapshot.messages.dropFirst(baselineCount).allSatisfy({ !$0.requiresAttention }),
               record.seen?.content == ChatContentEvidence(snapshot) {
                record.quietSummary = ChatSummaryEvidence(observed)
            }
            if !snapshot.messages.isEmpty || record.transcript?.messages.isEmpty == false { record.hasContentHistory = true }
            record.transcript = Self.inert(snapshot)
            if let message = ConversationPreview.latest(in: snapshot.messages) {
                record.inboxPreview = .init(message: message)
            }
            if record.summary == nil, let last = snapshot.messages.last(where: { ($0.role == .user || $0.role == .assistant) && $0.requiresAttention }) {
                record.preview = last.text
                record.updatedAt = last.timestamp ?? record.updatedAt
            }
        }
    }
    static func inert(_ snapshot: Conversation) -> Conversation {
        var copy = snapshot; copy.pendingRequests = []; copy.isWorking = false
        return copy
    }
    var withReadContentProof: Self {
        var copy = self
        for index in copy.records.indices {
            guard let seen = copy.records[index].seen, seen.content == nil,
                  let snapshot = copy.records[index].transcript else { continue }
            let content = ChatContentEvidence(snapshot)
            let legacyDateCoversContent = seen.messageID == nil
                && content.latestMessageAt.map({ $0 <= seen.observedAt }) == true
            if content.messageID == seen.messageID || legacyDateCoversContent {
                copy.records[index].seen?.content = content
            }
        }
        return copy
    }
    var readOnly: Self {
        var copy = self
        for index in copy.records.indices {
            if let chat = copy.records[index].transcript { copy.records[index].transcript = Self.inert(chat) }
            copy.records[index].preservedVariants = copy.records[index].preservedVariants.map {
                .init(draft: $0.draft, transcript: $0.transcript.map(Self.inert))
            }
        }
        return copy
    }
    func validate() throws {
        guard Set(records.map(\.id)).count == records.count,
              Set(preferences.map(\.profile)).count == preferences.count,
              Set(records.map(\.discoveryOrdinal)).count == records.count else { throw HistoryFailure.invalidBook }
        var roots: Set<RemoteIndexKey> = []
        var aliases: [RemoteIndexKey: ChatID] = [:]
        for record in records {
            guard !record.profile.bytes.isEmpty else { throw HistoryFailure.invalidBook }
            if let identity = record.binding.identity {
                guard identity.profile == record.profile, !identity.root.bytes.isEmpty, !identity.stored.bytes.isEmpty,
                      roots.insert(.init(profile: identity.profile, root: identity.root)).inserted else {
                    throw HistoryFailure.invalidBook
                }
                for alias in Self.proven(identity) {
                    let key = RemoteIndexKey(profile: identity.profile, root: alias)
                    guard aliases[key] == nil || aliases[key] == record.id else { throw HistoryFailure.invalidBook }
                    aliases[key] = record.id
                }
            }
            if let snapshot = record.transcript {
                guard Data(snapshot.profileID.utf8) == record.profile.bytes else { throw HistoryFailure.invalidBook }
            }
        }
        for pref in preferences {
            guard record(pref.main)?.profile == pref.profile,
                  [pref.lastSelected, pref.preferred].compactMap({ $0 }).allSatisfy({ record($0)?.profile == pref.profile })
            else { throw HistoryFailure.invalidBook }
        }
        guard records.allSatisfy({ preference($0.profile) != nil }) else { throw HistoryFailure.invalidBook }
    }
}

enum HistoryFailure: Error, LocalizedError {
    case unknownVersion(Int), invalidBook, corrupt, migrationWrite
    var errorDescription: String? {
        switch self {
        case .unknownVersion: "This chat cache was saved by a newer Botto. Its original data is preserved."
        case .invalidBook, .corrupt: "Botto couldn’t read this chat cache. Its original data is preserved."
        case .migrationWrite: "Botto couldn’t update this chat cache. Its original data is preserved."
        }
    }
}
