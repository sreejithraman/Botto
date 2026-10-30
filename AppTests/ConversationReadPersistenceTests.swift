import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationReadPersistenceTests {
    @Test func alreadyWrittenV2WithoutOptionalReadEvidenceLoadsUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheID = UUID(), profile = try ExactID("milo"), readAt = Date.now
        var history = LocalHistory()
        try history.fixtureConversation(.init(id: "runtime", storedID: "stored", profileID: profile.text,
            messages: [.init(id: "old", role: .assistant, text: "Old V2 answer", timestamp: readAt.addingTimeInterval(-60))]), profile: profile.text)
        let chat = try #require(history.book.opening(profile))
        history.book.update(chat) { $0.seen = .init(messageID: try? ExactID("old"), observedAt: readAt) }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var book = try #require(json["book"] as? [String: Any])
        var records = try #require(book["records"] as? [[String: Any]])
        for index in records.indices {
            records[index].removeValue(forKey: "summary")
            if var seen = records[index]["seen"] as? [String: Any] {
                seen.removeValue(forKey: "summary"); seen.removeValue(forKey: "content")
                records[index]["seen"] = seen
            }
        }
        book["records"] = records; json["book"] = book
        let raw = try JSONSerialization.data(withJSONObject: json)
        let url = try LocalHistory.file(for: cacheID, directory: directory)
        try raw.write(to: url)
        let loaded = try LocalHistory.load(for: cacheID, directory: directory)
        #expect(try Data(contentsOf: url) == raw, "Optional defaults must not require a destructive V2 migration")
        #expect(loaded.book.record(chat)?.summary == nil && loaded.book.record(chat)?.seen?.content == nil)
        #expect(loaded.book.record(chat)?.seen?.observedAt == readAt)
        let workspace = ConversationWorkspace(scope: .init(cacheID: cacheID, exactAccount: [], incarnation: UUID()),
            book: loaded.book, service: try WorkspaceTestService(), onDirty: {})
        await workspace.openBot(profile: profile)
        #expect(workspace.cards(profile: profile).first?.unread == false)
        #expect(workspace.screen(profile: profile)?.snapshot?.messages.first?.text == "Old V2 answer")
    }

    @Test func newerExactSummaryAndUnconsumedReadEvidenceSurviveIndependentDiskReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheID = UUID(), service = try WorkspaceTestService(), profile = service.profile
        let identity = service.summaries[0].identity, oldAt = Date.now.addingTimeInterval(-60)
        let old = ChatMessage(id: "old", role: .assistant, text: "Old answer", timestamp: oldAt)
        service.snapshots[identity.root]?.messages = [old]
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: old.text, updatedAt: oldAt, messageCount: 1)
        let workspace = ConversationWorkspace(scope: .init(cacheID: cacheID, exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: profile)
        let a = try #require(workspace.screen(profile: profile))
        await workspace.refreshDirectory(a.owner); workspace.displayed(a.owner)
        let b = try #require(workspace.cards(profile: profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(b, owner: a.owner)))
        let ownerB = try #require(workspace.screen(profile: profile)?.owner)
        let exact = "New e\u{301} answer", newAt = Date.now.addingTimeInterval(1)
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: exact, updatedAt: newAt, messageCount: 2)
        await workspace.refreshDirectory(ownerB)
        try LocalHistory(book: workspace.persisted()).save(for: cacheID, directory: directory)
        let fresh = try LocalHistory.load(for: cacheID, directory: directory)
        let reloaded = ConversationWorkspace(scope: .init(cacheID: cacheID, exactAccount: [], incarnation: UUID()),
            book: fresh.book, service: service, onDirty: {})
        await reloaded.openBot(profile: profile)
        let freshB = try #require(reloaded.screen(profile: profile))
        let freshBCards = reloaded.cards(profile: profile)
        let card = try #require(freshBCards.first { $0.id == a.selectedChatID })
        #expect(card.unread && Data(card.replyPreview.utf8) == Data(exact.utf8))
        #expect(fresh.book.record(a.selectedChatID)?.summary?.messageCount == 2)
        #expect(fresh.book.record(a.selectedChatID)?.transcript?.messages.last?.id == "old")
        await reloaded.select(try #require(reloaded.captureSelection(a.selectedChatID, owner: freshB.owner)))
        reloaded.displayed(try #require(reloaded.screen(profile: profile)?.owner))
        try LocalHistory(book: reloaded.persisted()).save(for: cacheID, directory: directory)
        let stillUnread = try LocalHistory.load(for: cacheID, directory: directory)
        #expect(stillUnread.book.record(a.selectedChatID)?.isUnread == true)
        service.snapshots[identity.root]?.messages = [old, .init(id: "new", role: .assistant, text: exact, timestamp: newAt)]
        reloaded.setOnline(true); await reloaded.openBot(profile: profile)
        let visible = try #require(reloaded.screen(profile: profile))
        let visibleCards = reloaded.cards(profile: profile)
        #expect(visibleCards.first { $0.id == a.selectedChatID }?.unread == true)
        reloaded.displayed(visible.owner)
        try LocalHistory(book: reloaded.persisted()).save(for: cacheID, directory: directory)
        let seen = try LocalHistory.load(for: cacheID, directory: directory)
        #expect(seen.book.record(a.selectedChatID)?.isUnread == false)
        #expect(seen.book.record(a.selectedChatID)?.transcript?.messages.last?.id == "new")
        #expect(seen.book.record(a.selectedChatID)?.title == "Main")
    }
    @Test func legacyDateCursorKeepsAlreadyReadContentWhenFirstDirectoryArrives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let oldAt = Date(timeIntervalSince1970: 100), readAt = Date(timeIntervalSince1970: 200)
        let message = ChatMessage(id: "legacy-message", role: .assistant, text: "Already read", timestamp: oldAt)
        let chat = Conversation(id: "legacy-runtime", storedID: identity.stored.text, profileID: service.profile.text, messages: [message])
        let legacy = LegacyHistoryFixture(bots: [.init(id: service.profile.text, name: "Milo", preview: message.text, updatedAt: oldAt)],
            conversations: [service.profile.text: chat], drafts: [service.profile.text: " exact draft \n"], seen: [service.profile.text: readAt])
        try JSONEncoder().encode(legacy).write(to: LocalHistory.file(for: id, directory: directory))
        let loaded = try LocalHistory.load(for: id, directory: directory)
        let main = try #require(loaded.book.opening(service.profile))
        #expect(loaded.book.record(main)?.seen?.observedAt == readAt)
        service.snapshots[identity.root]?.messages = [message]
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: message.text, updatedAt: oldAt, messageCount: 1)
        let workspace = ConversationWorkspace(scope: .init(cacheID: id, exactAccount: [], incarnation: UUID()),
            book: loaded.book, service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true,
            "Legacy seen dates cannot acknowledge an inventory observation by themselves")
        workspace.displayed(screen.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
        #expect(workspace.persisted().record(main)?.seen?.observedAt == readAt)
        #expect(workspace.draft(screen.owner) == " exact draft \n")
    }

    @Test func v2SummaryWithoutInventoryTipStaysBytePreservedAndCannotMintRuntimeEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheID = UUID(), service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "Known preview", messageCount: 4)
        let workspace = ConversationWorkspace(scope: .init(cacheID: cacheID, exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.displayed(screen.owner)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalHistory(book: workspace.persisted()))) as? [String: Any])
        var book = try #require(json["book"] as? [String: Any])
        var records = try #require(book["records"] as? [[String: Any]])
        for index in records.indices {
            if var summary = records[index]["summary"] as? [String: Any] {
                summary.removeValue(forKey: "inventoryTip"); records[index]["summary"] = summary
            }
            if var seen = records[index]["seen"] as? [String: Any], var summary = seen["summary"] as? [String: Any] {
                summary.removeValue(forKey: "inventoryTip"); seen["summary"] = summary; records[index]["seen"] = seen
            }
        }
        book["records"] = records; json["book"] = book
        let raw = try JSONSerialization.data(withJSONObject: json), url = try LocalHistory.file(for: cacheID, directory: directory)
        try raw.write(to: url)
        let loaded = try LocalHistory.load(for: cacheID, directory: directory)
        #expect(try Data(contentsOf: url) == raw)
        #expect(loaded.book.record(screen.selectedChatID)?.summary?.inventoryTip == nil)
        let restored = ConversationWorkspace(scope: .init(cacheID: cacheID, exactAccount: [], incarnation: UUID()),
            book: loaded.book, service: service, onDirty: {})
        await restored.openBot(profile: service.profile)
        let cached = try #require(restored.screen(profile: service.profile))
        restored.displayed(cached.owner); restored.displayed(cached.owner)
        #expect(restored.persisted().record(screen.selectedChatID)?.seen?.summary?.inventoryTip == nil)
        restored.setOnline(true); await restored.openBot(profile: service.profile)
        let current = try #require(restored.screen(profile: service.profile))
        await restored.refreshDirectory(current.owner)
        #expect(restored.cards(profile: service.profile).first?.unread == true)
        restored.setOnline(false)
        restored.displayed(try #require(restored.screen(profile: service.profile)?.owner))
        #expect(restored.cards(profile: service.profile).first?.unread == true)
        restored.setOnline(true); await restored.openBot(profile: service.profile)
        restored.displayed(try #require(restored.screen(profile: service.profile)?.owner))
        #expect(restored.cards(profile: service.profile).first?.unread == false)
    }

}
