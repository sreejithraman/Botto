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
        let other = try #require(workspace.cards(profile: profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(other, owner: a.owner)))
        let b = try #require(workspace.screen(profile: profile))
        let newAt = seenAt.addingTimeInterval(0.001)
        let preview = [.countOnly, .timeOnly].contains(evidence) ? "Old A answer" : "New A answer"
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: preview, updatedAt: [.datedPreviewAndCount, .timeOnly].contains(evidence) ? newAt : oldAt,
            messageCount: evidence == .previewOnly ? nil : evidence == .timeOnly ? 1 : 2)
        await workspace.refreshDirectory(b.owner)
        let updatedA = try #require(workspace.cards(profile: profile).first { $0.id == a.selectedChatID })
        print("R1_UNREAD evidence=\(evidence) unread=\(updatedA.unread) preview=\(updatedA.replyPreview) expected_preview=\(preview)")
        #expect(updatedA.unread, "Fresh directory evidence must outrank a matching older cached seen message ID")
        #expect(updatedA.replyPreview == preview, "The card must not hide newer summary text behind cached transcript text")
        #expect(workspace.persisted().record(a.selectedChatID)?.transcript?.messages.last?.id == "A-old")
        // Displaying an offline cached A must not claim the directory's newer content was read.
        workspace.setOnline(false)
        let offlineB = try #require(workspace.screen(profile: profile))
        await workspace.select(try #require(workspace.captureSelection(a.selectedChatID, owner: offlineB.owner)))
        let staleA = try #require(workspace.screen(profile: profile))
        #expect(staleA.snapshot?.messages.last?.id == "A-old")
        try await Task.sleep(for: .milliseconds(20))
        workspace.displayed(staleA.owner)
        #expect(workspace.cards(profile: profile).first { $0.id == a.selectedChatID }?.unread == true,
            "A later wall-clock seen time for stale cached content cannot consume unseen newer summary evidence")
        // Positive control: only actual new transcript content followed by displayed clears unread.
        service.snapshots[identity.root]?.messages = [oldMessage, .init(id: "A-new", role: .assistant, text: preview, timestamp: newAt)]
        workspace.setOnline(true)
        await workspace.openBot(profile: profile)
        let freshA = try #require(workspace.screen(profile: profile))
        let freshACards = workspace.cards(profile: profile)
        #expect(freshA.snapshot?.messages.last?.id == "A-new")
        #expect(freshACards.first { $0.id == a.selectedChatID }?.unread == true)
        workspace.displayed(freshA.owner)
        #expect(workspace.cards(profile: profile).first { $0.id == a.selectedChatID }?.unread == false)
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
        let seen = try #require(workspace.screen(profile: service.profile))
        let seenCards = workspace.cards(profile: service.profile)
        #expect(seenCards.first?.unread == false)
        #expect(seenCards.first?.replyPreview == text)
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
        let changedCards = workspace.cards(profile: service.profile)
        #expect(changedCards.first?.unread == true)
        #expect(changedCards.first.map { Data($0.replyPreview.utf8) } == Data("e\u{301} answer".utf8))
        workspace.displayed(changed.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        service.snapshots[identity.root]?.messages[0].text = "e\u{301} answer"
        workspace.receive(try service.publication(identity))
        let actual = try #require(workspace.screen(profile: service.profile))
        workspace.displayed(actual.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true,
            "Even changed exact text in a delta cannot manufacture a complete-read witness")
        workspace.receive(try service.fullReadPublication(identity))
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
    }

}
