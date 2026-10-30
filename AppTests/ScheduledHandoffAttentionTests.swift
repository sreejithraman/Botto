import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ScheduledHandoffAttentionTests {
    static let handoff = ChatMessage(id: "scheduled", role: .user,
        text: "[Cronjob \"Mac service incident diagnosis\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n{\"diagnostic\":true}",
        displayKind: "internal_notification")

    @Test func botAndInternalEventsNeverReplaceTheAuthoredUserPreview() throws {
        let profile = try ExactID("bot"), stored = try ExactID("stored")
        let identity = SessionIdentity(profile: profile, root: stored, stored: stored, aliases: [])
        let summary = SessionSummary(identity: identity, title: "Main", isCanonical: true, persistence: .durable)
        let messages: [ChatMessage] = [
            .init(id: "human", role: .user, text: "Please check the service."),
            .init(id: "bot-dm", role: .user, text: "Message from 🤖 Gustavo (@hermes): I checked it.", displayKind: "internal_notification"),
            .init(id: "gateway", role: .user, text: "An internal note", displayKind: "internal_notification"),
            .init(id: "failure", role: .user, text: "The process failed", displayKind: "process_complete")
        ]
        var book = ConversationBook()
        let id = book.merge(summary)
        book.cache(.init(id: "runtime", storedID: "stored", profileID: "bot", messages: messages), for: id)
        #expect(book.record(id)?.userPreview == "Please check the service.")
        #expect(ChatContentEvidence(.init(id: "runtime", storedID: "stored", profileID: "bot", messages: messages)).messageID?.text == "failure")
    }

    @Test func quietRowsDoNotChangeUnreadContentButRepliesAndFailuresDo() {
        var snapshot = Conversation(id: "runtime", storedID: "stored", profileID: "bot",
            messages: [.init(id: "reply", role: .assistant, text: "Earlier answer")])
        let before = ChatContentEvidence(snapshot)
        snapshot.messages.append(Self.handoff)
        snapshot.messages.append(.init(id: "silent", role: .assistant, text: "[SILENT]", isSilent: true))
        #expect(ChatContentEvidence(snapshot) == before)
        snapshot.messages.append(.init(id: "failure", role: .system, text: "The turn failed"))
        #expect(ChatContentEvidence(snapshot) != before)
        snapshot.messages.append(.init(id: "useful", role: .assistant, text: "The service recovered."))
        #expect(ChatContentEvidence(snapshot).messageID?.text == "useful")
    }
    @Test func fullReadCanProveQuietInventoryChangeWithoutMarkingRepliesRead() throws {
        let profile = try ExactID("bot"), stored = try ExactID("stored")
        let identity = SessionIdentity(profile: profile, root: stored, stored: stored, aliases: [])
        var book = ConversationBook()
        let initial = SessionSummary(identity: identity, title: "Main", isCanonical: true, persistence: .durable,
            preview: "Earlier answer", messageCount: 1)
        let id = book.merge(initial)
        var snapshot = Conversation(id: "runtime", storedID: "stored", profileID: "bot",
            messages: [.init(id: "reply", role: .assistant, text: "Earlier answer")])
        book.cache(snapshot, for: id)
        book.update(id) { $0.displayed(snapshot, acknowledging: ChatSummaryEvidence(initial), at: .now) }
        snapshot.messages.append(Self.handoff)
        let quiet = SessionSummary(identity: identity, title: "Main", isCanonical: true, persistence: .durable,
            preview: "Earlier answer", messageCount: 2)
        _ = book.merge(quiet)
        // Unverified directory counts must remain conservative.
        #expect(book.record(id)?.isUnread == true)
        // Live delivery can cache the new row before a full read carries the current witness.
        book.cache(snapshot, for: id)
        #expect(book.record(id)?.isUnread == true)
        book.cache(snapshot, for: id, readEvidence: ConversationReadEvidence(summaryObservedBeforeRead: quiet))
        #expect(book.record(id)?.isUnread == false)
        let restored = try JSONDecoder().decode(ConversationBook.self, from: JSONEncoder().encode(book))
        #expect(restored.record(id)?.isUnread == false)
        #expect(restored.record(id)?.transcript?.messages.last?.text == Self.handoff.text)
        // A later meaningful response is unread without requiring a new directory sample.
        snapshot.messages.append(.init(id: "new-reply", role: .assistant, text: "Please check the service."))
        book.cache(snapshot, for: id)
        #expect(book.record(id)?.isUnread == true)
    }

    @Test func quietSnapshotDoesNotRequestScrollingButApprovalsAndRepliesDo() {
        let initial = Conversation(id: "runtime", storedID: "stored", profileID: "bot")
        var quiet = initial
        quiet.messages = [Self.handoff]
        var policy = TranscriptScrollPolicy()
        let followsQuiet = policy.snapshotChanged(from: initial, to: quiet)
        #expect(!followsQuiet && !policy.showsLatest)
        var approval = quiet
        approval.pendingRequests = [.init(id: "decision", kind: .approval, title: "Restart service?")]
        let followsApproval = policy.snapshotChanged(from: quiet, to: approval)
        #expect(followsApproval)
        var reply = quiet
        reply.messages.append(.init(id: "answer", role: .assistant, text: "Action is needed."))
        let followsReply = policy.snapshotChanged(from: quiet, to: reply)
        #expect(followsReply)
    }

    @Test(arguments: ["profile", "root", "stored", "missing"])
    func mismatchedFullReadCannotQuietDirectoryActivity(_ mismatch: String) throws {
        let profile = try ExactID("bot"), stored = try ExactID("stored")
        let identity = SessionIdentity(profile: profile, root: stored, stored: stored, aliases: [])
        let initial = SessionSummary(identity: identity, title: "Main", isCanonical: true, persistence: .durable, messageCount: 1)
        var book = ConversationBook()
        let id = book.merge(initial)
        var snapshot = Conversation(id: "runtime", storedID: "stored", profileID: "bot",
            messages: [.init(id: "reply", role: .assistant, text: "Read answer")])
        book.cache(snapshot, for: id)
        book.update(id) { $0.displayed(snapshot, acknowledging: ChatSummaryEvidence(initial), at: .now) }
        snapshot.messages.append(Self.handoff)
        let current = SessionSummary(identity: identity, title: "Main", isCanonical: true, persistence: .durable, messageCount: 2)
        _ = book.merge(current)
        let wrong = SessionIdentity(profile: mismatch == "profile" ? try ExactID("other") : profile,
            root: mismatch == "root" ? try ExactID("other") : stored,
            stored: mismatch == "stored" ? try ExactID("other") : stored, aliases: [])
        let observed = SessionSummary(identity: wrong, title: "Main", isCanonical: true, persistence: .durable, messageCount: 2)
        book.cache(snapshot, for: id, readEvidence: mismatch == "missing" ? nil : ConversationReadEvidence(summaryObservedBeforeRead: observed))
        #expect(book.record(id)?.isUnread == true)
    }

    @Test func oldCachesDecodeWithoutInventingAutomationProvenance() throws {
        let data = Data(#"{"id":"old","role":"user","text":"cron scheduled {}","attachments":[]}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(message.requiresAttention && message.isVisible)
        #expect(message.displayKind == nil && message.isSilent == nil)
    }

    @Test(arguments: [false, true])
    func acknowledgedAutomationOnlyHistoryNeverFallsBackToRawPreview(_ silent: Bool) throws {
        let profile = try ExactID("bot"), stored = try ExactID("stored")
        let identity = SessionIdentity(profile: profile, root: stored, stored: stored, aliases: [])
        let messages = silent ? [Self.handoff, .init(id: "silent", role: .assistant, text: "[SILENT]", isSilent: true)] : [Self.handoff]
        let snapshot = Conversation(id: "runtime", storedID: "stored", profileID: "bot", messages: messages)
        let summary = SessionSummary(identity: identity, title: "Main", isCanonical: true, persistence: .durable,
            preview: silent ? "[SILENT]" : Self.handoff.text, messageCount: messages.count)
        var book = ConversationBook()
        let id = book.merge(summary)
        book.cache(snapshot, for: id)
        book.update(id) { $0.displayed(snapshot, acknowledging: ChatSummaryEvidence(summary), at: .now) }
        #expect(book.record(id)?.userPreview == "")
        #expect(book.record(id)?.replyPreview == "")
        #expect(book.record(id)?.transcript?.messages == messages)
    }

    @Test func coveredTranscriptDoesNotReadMeaningfulReplyDuringDetailsInspection() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.snapshots[identity.root]?.messages = [Self.handoff]
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.setTranscriptVisible(true, owner: screen.owner)
        workspace.setTranscriptVisible(false, owner: screen.owner)
        service.snapshots[identity.root]?.messages.append(.init(id: "meaningful", role: .assistant, text: "Action is needed."))
        workspace.receive(try service.publication(identity))
        let covered = try #require(workspace.screen(profile: service.profile))
        let coveredCards = workspace.cards(profile: service.profile)
        workspace.setTranscriptVisible(false, owner: covered.owner)
        #expect(coveredCards.first { $0.id == covered.selectedChatID }?.unread == true)
        workspace.setTranscriptVisible(true, owner: covered.owner)
        #expect(workspace.cards(profile: service.profile).first { $0.id == covered.selectedChatID }?.unread == false)
    }

    @Test(arguments: [false, true])
    func mixedHistoryNeverFallsBackToVerifiedQuietPreview(_ silent: Bool) throws {
        let profile = try ExactID("bot"), stored = try ExactID("stored")
        let identity = SessionIdentity(profile: profile, root: stored, stored: stored, aliases: [])
        let messages: [ChatMessage] = [Self.handoff, .init(id: "silent", role: .assistant, text: "[SILENT]", isSilent: true),
            .init(id: "human", role: .user, text: "Any update on cron?")]
        let snapshot = Conversation(id: "runtime", storedID: "stored", profileID: "bot", messages: messages)
        let summary = SessionSummary(identity: identity, title: "Main", isCanonical: true, persistence: .durable,
            preview: silent ? "[SILENT]" : Self.handoff.text, messageCount: messages.count)
        var book = ConversationBook()
        let id = book.merge(summary)
        book.cache(snapshot, for: id)
        #expect(book.record(id)?.replyPreview == "")
        book.update(id) { $0.displayed(snapshot, acknowledging: ChatSummaryEvidence(summary), at: .now) }
        #expect(book.record(id)?.replyPreview == "")
        #expect(book.record(id)?.userPreview == "Any update on cron?")
        var quoted = snapshot
        quoted.messages.append(.init(id: "human-quote", role: .user, text: summary.preview))
        book.cache(quoted, for: id)
        #expect(book.record(id)?.replyPreview == summary.preview)
    }

    @Test(arguments: [false, true])
    func controlOnlyDirectoryAndOldCacheNeverShowMarkerPreview(_ hasCache: Bool) throws {
        let profile = try ExactID("bot"), stored = try ExactID("stored")
        let identity = SessionIdentity(profile: profile, root: stored, stored: stored, aliases: [])
        let summary = SessionSummary(identity: identity, title: "Main", isCanonical: true, persistence: .durable,
            preview: "[SILENT]", messageCount: 2)
        var book = ConversationBook()
        let id = book.merge(summary)
        if hasCache {
            let data = Data(#"{"id":"old","role":"assistant","text":"[SILENT]","attachments":[],"isSilent":false}"#.utf8)
            let cached = try JSONDecoder().decode(ChatMessage.self, from: data)
            book.cache(.init(id: "runtime", storedID: "stored", profileID: "bot", messages: [
                .init(id: "greeting", role: .user, text: "Hi"), cached]), for: id)
        }
        #expect(book.record(id)?.replyPreview == "")
        var restored = try JSONDecoder().decode(ConversationBook.self, from: JSONEncoder().encode(book))
        #expect(restored.record(id)?.replyPreview == "")
        for message in [ChatMessage(id: "human", role: .user, text: "[SILENT]"),
                        .init(id: "failed", role: .assistant, text: "[SILENT]", displayKind: "failed_turn")] {
            restored.cache(.init(id: "runtime", storedID: "stored", profileID: "bot", messages: [message]), for: id)
            #expect(restored.record(id)?.replyPreview == "[SILENT]")
        }
    }

    @Test func largeRawDetailsUseBoundedSectionsWithoutLosingBytes() {
        let payload = Self.handoff.text + String(repeating: "Diagnostic: healthy 🦊\n", count: 5000) + String(repeating: "x", count: 2000)
        let sections = RawMessagePayload.sections(payload)
        #expect(sections.count > 100)
        #expect(sections.allSatisfy { !$0.isEmpty && $0.count <= 512 })
        #expect(Data(sections.joined().utf8) == Data(payload.utf8))
        #expect(sections.first?.hasPrefix("[Cronjob") == true)
    }

}
