import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationUnreadTests {
    enum Evidence: CaseIterable { case datedPreviewAndCount, countOnly, previewOnly, timeOnly }

    @Test(arguments: Evidence.allCases)
    func newerDirectoryEvidenceStaysUnreadUntilActuallyDisplayedContent(_ evidence: Evidence) async throws {
        let service = try WorkspaceTestService(), profile = service.profile
        let identity = service.summaries[0].identity, oldAt = Date.now.addingTimeInterval(-60)
        let oldMessage = ChatMessage(id: "A-old", role: .assistant, text: "Old A answer", timestamp: oldAt)
        service.snapshots[identity.root]?.messages = [oldMessage]
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "Old A answer", updatedAt: oldAt, messageCount: 1)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: profile)
        let a = try #require(workspace.screen(profile: profile))
        await workspace.refreshDirectory(a.owner)
        workspace.displayed(a.owner)
        #expect(workspace.aggregate(profile: profile).unreadCount == 0)
        let seenAt = try #require(workspace.persisted().record(a.selectedChatID)?.seen?.observedAt)
        #expect(await workspace.openSaved(service.summaries[1]))
        let b = try #require(workspace.screen(profile: profile))
        let newAt = seenAt.addingTimeInterval(0.001)
        let preview = [.countOnly, .timeOnly].contains(evidence) ? "Old A answer" : "New A answer"
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: preview, updatedAt: [.datedPreviewAndCount, .timeOnly].contains(evidence) ? newAt : oldAt,
            messageCount: evidence == .previewOnly ? nil : evidence == .timeOnly ? 1 : 2)
        await workspace.refreshDirectory(b.owner)
        #expect(workspace.persisted().record(a.selectedChatID)?.isUnread == true,
                "Fresh directory evidence must outrank a matching older cached seen message ID")
        #expect(workspace.persisted().record(a.selectedChatID)?.transcript?.messages.last?.id == "A-old")
        // Displaying an offline cached A must not claim the directory's newer content was read.
        workspace.setOnline(false)
        #expect(await workspace.openSaved(service.summaries[0]))
        let staleA = try #require(workspace.screen(profile: profile))
        #expect(staleA.snapshot?.messages.last?.id == "A-old")
        try await Task.sleep(for: .milliseconds(20))
        workspace.displayed(staleA.owner)
        #expect(workspace.chats(profile).first { $0.id == a.selectedChatID }?.isUnread == true,
            "A later wall-clock seen time for stale cached content cannot consume unseen newer summary evidence")
        // Positive control: only actual new transcript content followed by displayed clears unread.
        service.snapshots[identity.root]?.messages = [oldMessage, .init(id: "A-new", role: .assistant, text: preview, timestamp: newAt)]
        workspace.setOnline(true)
        await workspace.openBot(profile: profile)
        let freshA = try #require(workspace.screen(profile: profile))
        let freshAChats = workspace.chats(profile)
        #expect(freshA.snapshot?.messages.last?.id == "A-new")
        #expect(freshAChats.first { $0.id == a.selectedChatID }?.isUnread == true)
        workspace.displayed(freshA.owner)
        #expect(workspace.chats(profile).first { $0.id == a.selectedChatID }?.isUnread == false)
    }
    /// T3 never marks a reply quiet, so a reply whose whole text is "Silent." is new content like any other.
    @Test(arguments: [false, true])
    func aSilentLookingReplyMarksAReadChatUnreadUntilDisplayed(directoryCountsTheReply: Bool) async throws {
        let service = try WorkspaceTestService(), profile = service.profile, identity = service.summaries[0].identity
        let oldAt = Date.now.addingTimeInterval(-60)
        let old = ChatMessage(id: "answer", role: .assistant, text: "The report is ready.", timestamp: oldAt)
        service.snapshots[identity.root]?.messages = [old]
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: old.text, updatedAt: oldAt, messageCount: 1)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: profile)
        let read = try #require(workspace.screen(profile: profile))
        await workspace.refreshDirectory(read.owner)
        workspace.displayed(read.owner)
        let chat = read.selectedChatID
        #expect(workspace.chats(profile).first { $0.id == chat }?.isUnread == false)

        let silentAt = Date.now
        service.snapshots[identity.root]?.messages = [old, .init(id: "silent", role: .assistant, text: "Silent.", timestamp: silentAt)]
        if directoryCountsTheReply {
            service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
                preview: "Silent.", updatedAt: silentAt, messageCount: 2)
        }
        await workspace.openBot(profile: profile)
        let fresh = try #require(workspace.screen(profile: profile))
        await workspace.refreshDirectory(fresh.owner)
        #expect(fresh.snapshot?.messages.last?.id == "silent")
        #expect(workspace.chats(profile).first { $0.id == chat }?.isUnread == true,
                "A reply that looks like an old silence marker still counts as unread")
        #expect(workspace.persisted().record(chat)?.inboxMessage?.text == "Silent.")
        workspace.displayed(try #require(workspace.screen(profile: profile)).owner)
        #expect(workspace.chats(profile).first { $0.id == chat }?.isUnread == false)
    }
    @Test func directoryPreviewMayBeAnExactTruncatedPrefixOfDisplayedContent() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let text = "A complete answer with more detail than the directory preview."
        service.snapshots[identity.root]?.messages = [.init(id: "answer", role: .assistant, text: text)]
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "A complete answer", messageCount: 1)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner)
        workspace.displayed(screen.owner)
        #expect(workspace.screen(profile: service.profile) != nil)
        let seenChats = workspace.chats(service.profile)
        #expect(seenChats.first?.isUnread == false)
    }

    @Test func canonicallyEquivalentPreviewBytesStillNeedActualChangedContentDisplay() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let oldAt = Date(timeIntervalSince1970: 100)
        service.snapshots[identity.root]?.messages = [.init(id: "same", role: .assistant, text: "é answer", timestamp: oldAt)]
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "é answer", updatedAt: oldAt, messageCount: 1)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let initial = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(initial.owner); workspace.displayed(initial.owner)
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "e\u{301} answer", updatedAt: oldAt, messageCount: 1)
        await workspace.refreshDirectory(initial.owner)
        let changed = try #require(workspace.screen(profile: service.profile))
        let changedChats = workspace.chats(service.profile)
        #expect(changedChats.first?.isUnread == true)
        workspace.displayed(changed.owner)
        #expect(workspace.chats(service.profile).first?.isUnread == true)
        service.snapshots[identity.root]?.messages[0].text = "e\u{301} answer"
        workspace.receive(try service.publication(identity))
        let actual = try #require(workspace.screen(profile: service.profile))
        workspace.displayed(actual.owner)
        #expect(workspace.chats(service.profile).first?.isUnread == true,
            "Even changed exact text in a delta cannot manufacture a complete-read witness")
        workspace.receive(try service.fullReadPublication(identity))
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.chats(service.profile).first?.isUnread == false)
    }

}
