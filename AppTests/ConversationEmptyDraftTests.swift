import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationEmptyDraftTests {
    private func fixture(persistence: SessionPersistence = .liveOnly) throws -> (ConversationBook, ChatID, SessionIdentity, Conversation) {
        let key = try ExactID("new-unpersisted"), profile = try ExactID("milo")
        let identity = SessionIdentity(profile: profile, root: key, stored: key, aliases: [key])
        var book = ConversationBook()
        let id = book.merge(.init(identity: identity, title: "New Chat", isCanonical: false, persistence: persistence, messageCount: 0))
        let empty = Conversation(id: "runtime", storedID: key.text, profileID: profile.text)
        book.cache(empty, for: id)
        return (book, id, identity, empty)
    }

    @Test func originalEmptyUnpersistedDraftHasNoUnreadBadgeWithoutAcknowledgingSummary() throws {
        var (book, id, _, empty) = try fixture()
        let summary = try #require(book.record(id)?.summary)
        #expect(book.record(id)?.isUnread == false)
        #expect(book.record(id)?.seen == nil)
        book.update(id) { $0.draft.text = "My local unsent draft" }
        for _ in 0..<2 { book.update(id) { $0.displayed(empty, acknowledging: nil, at: .now) } }
        #expect(book.record(id)?.isUnread == false)
        #expect(book.record(id)?.summary == summary && book.record(id)?.seen?.summary == nil)
        #expect(book.record(id)?.draft.text == "My local unsent draft")
    }

    @Test(arguments: [SessionPersistence.liveOnly, .durable])
    func syntheticUnknownRetainsPersistenceOnlyWithinExactOriginalNamespace(_ known: SessionPersistence) throws {
        var (book, id, identity, _) = try fixture(persistence: known)
        _ = book.merge(.init(identity: identity, title: "New Chat", isCanonical: false, persistence: .unknown))
        guard case .identified(_, _, let retained) = book.record(id)?.binding else { Issue.record("Missing binding"); return }
        #expect(retained == known)
        let next = SessionIdentity(profile: identity.profile, root: identity.root, stored: try ExactID("new-tip"), aliases: [identity.stored])
        _ = book.merge(.init(identity: next, title: "New Chat", isCanonical: false, persistence: .unknown))
        guard case .identified(_, _, let replacement) = book.record(id)?.binding else { Issue.record("Missing replacement"); return }
        #expect(replacement == .unknown)
    }

    @Test func realDurableInventoryUpgradesAndRealUnknownObservationDoesNotRetainLocalProvenance() throws {
        var (book, id, identity, empty) = try fixture()
        _ = book.merge(.init(identity: identity, title: "New Chat", isCanonical: false, persistence: .durable, messageCount: 0))
        guard case .identified(_, _, let persistence) = book.record(id)?.binding else { Issue.record("Missing binding"); return }
        #expect(persistence == .durable)
        book.update(id) { $0.displayed(empty, acknowledging: nil, at: .now) }
        #expect(book.record(id)?.isUnread == true)
        _ = book.merge(.init(identity: identity, title: "New Chat", isCanonical: false, persistence: .unknown, messageCount: 0))
        guard case .identified(_, _, let unknown) = book.record(id)?.binding else { Issue.record("Missing unknown binding"); return }
        #expect(unknown == .unknown && book.record(id)?.isUnread == true)
    }

    enum ChangedNamespace: CaseIterable { case profile, root, stored }
    @Test(arguments: [SessionPersistence.liveOnly, .durable], ChangedNamespace.allCases)
    func syntheticUnknownCannotBorrowPersistenceAcrossAnyIdentityBoundary(_ known: SessionPersistence, _ changed: ChangedNamespace) throws {
        var (book, id, identity, _) = try fixture(persistence: known)
        let replacement = SessionIdentity(profile: changed == .profile ? try ExactID("other-profile") : identity.profile,
            root: changed == .root ? try ExactID("other-root") : identity.root,
            stored: changed == .stored ? try ExactID("other-tip") : identity.stored, aliases: [identity.stored])
        let target = book.merge(.init(identity: replacement, title: "Other", isCanonical: false, persistence: .unknown))
        guard case .identified(_, _, let result) = book.record(target)?.binding else { Issue.record("Missing replacement"); return }
        #expect(result == .unknown)
        if changed == .profile {
            #expect(target != id)
            guard case .identified(_, _, let original) = book.record(id)?.binding else { Issue.record("Missing origin"); return }
            #expect(original == known)
        }
    }

    @Test func priorContentRemainsDisqualifyingAfterEmptyDisplayAndIndependentDiskReload() throws {
        var (book, id, identity, empty) = try fixture()
        let populated = Conversation(id: empty.id, storedID: identity.stored.text, profileID: identity.profile.text,
            messages: [.init(id: "prior", role: .assistant, text: "Previously returned")])
        book.cache(populated, for: id)
        book.update(id) { $0.displayed(populated, acknowledging: nil, at: .now) }
        book.cache(empty, for: id)
        for _ in 0..<2 { book.update(id) { $0.displayed(empty, acknowledging: nil, at: .now) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheID = UUID()
        try LocalHistory(book: book).save(for: cacheID, directory: directory)
        let loaded = try LocalHistory.load(for: cacheID, directory: directory)
        #expect(loaded.book.record(id)?.isUnread == true)
        #expect(loaded.book.record(id)?.hasContentHistory == true)
        #expect(loaded.book.record(id)?.seen?.summary == nil)
        #expect(loaded.book.record(id)?.transcript?.messages.isEmpty == true)
    }

    enum Exclusion: CaseIterable {
        case returnedContent, priorReturnedContent, priorSeenContent, preservedContent, oldSeenNamespace
        case durable, unknown, differentAlias, changedTip, changedRoot, missingInventoryTip, missingSnapshot
        case nonemptyPreview, datedSummary, nonzeroCount, previousMetadata, unverified, unknownLegacySeen
    }
    @Test(arguments: Exclusion.allCases)
    func emptyDraftDisplayExceptionNeverHidesContentOrOtherNamespaces(_ exclusion: Exclusion) throws {
        var (book, id, identity, empty) = try fixture()
        var actual = empty
        let populated = Conversation(id: empty.id, storedID: identity.stored.text, profileID: identity.profile.text,
            messages: [.init(id: "prior", role: .assistant, text: "Returned history")])
        switch exclusion {
        case .returnedContent:
            book.cache(populated, for: id); actual = populated
        case .priorReturnedContent:
            book.cache(populated, for: id); book.cache(empty, for: id)
        case .priorSeenContent:
            book.cache(populated, for: id)
            book.update(id) { $0.displayed(populated, acknowledging: nil, at: .now) }
            book.cache(empty, for: id)
        case .preservedContent:
            book.update(id) { $0.preservedVariants = [.init(draft: .init(), transcript: populated)] }
        case .oldSeenNamespace:
            let old = SessionIdentity(profile: identity.profile, root: identity.root, stored: try ExactID("old-tip"), aliases: [])
            book.update(id) { $0.seen = .init(messageID: nil, observedAt: .now, content: ChatContentEvidence(empty),
                summary: ChatSummaryEvidence(.init(identity: old, title: "Old", isCanonical: false, persistence: .durable, messageCount: 0))) }
        case .durable, .unknown:
            _ = book.merge(.init(identity: identity, title: "New Chat", isCanonical: false,
                persistence: exclusion == .durable ? .durable : .unknown, messageCount: 0))
        case .differentAlias, .changedTip, .changedRoot:
            let different = try ExactID("other-namespace")
            let replacement = SessionIdentity(profile: identity.profile,
                root: exclusion == .changedRoot ? different : identity.root,
                stored: exclusion == .changedTip ? different : identity.stored, aliases: [identity.stored, different])
            _ = book.merge(.init(identity: replacement, title: "New Chat", isCanonical: false, persistence: .liveOnly, messageCount: 0))
        case .missingInventoryTip:
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(book.record(id))) as? [String: Any])
            var summary = try #require(json["summary"] as? [String: Any]); summary.removeValue(forKey: "inventoryTip"); json["summary"] = summary
            let legacy = try JSONDecoder().decode(ChatRecord.self, from: JSONSerialization.data(withJSONObject: json))
            book.update(id) { $0 = legacy }
        case .missingSnapshot:
            book.update(id) { $0.transcript = nil }
        case .nonemptyPreview, .datedSummary, .nonzeroCount:
            _ = book.merge(.init(identity: identity, title: "New Chat", isCanonical: false, persistence: .liveOnly,
                preview: exclusion == .nonemptyPreview ? " " : "", updatedAt: exclusion == .datedSummary ? .now : nil,
                messageCount: exclusion == .nonzeroCount ? 1 : 0))
        case .previousMetadata:
            book.update(id) { $0.preview = "Earlier content" }
        case .unverified:
            book.update(id) { $0.isUnverified = true }
        case .unknownLegacySeen:
            book.update(id) { $0.seen = .init(messageID: try? ExactID("prior-message"), observedAt: .now) }
        }
        #expect(book.record(id)?.isUnread == true)
        let oldAcknowledgement = book.record(id)?.seen?.summary
        for _ in 0..<2 { book.update(id) { $0.displayed(actual, acknowledging: nil, at: .now) } }
        #expect(book.record(id)?.isUnread == true)
        #expect(book.record(id)?.seen?.summary == oldAcknowledgement)
    }
}
