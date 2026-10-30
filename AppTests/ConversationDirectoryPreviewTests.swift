import Foundation
import Observation
import Testing
import BottoCore
import SwiftUI
import Vision
import XCTest
@testable import Botto

/// Source-shaped from hermes_state_sessions.py first-user selection and
/// hermes_state_common.py _shape_preview; directory text is not a latest-message ID.
@MainActor struct ConversationDirectoryPreviewTests {
    enum Shape: CaseIterable {
        case firstUser, whitespace, ellipsis, skill
        var userText: String {
            switch self {
            case .firstUser: "First user question"
            case .whitespace: "\n  First\r\nquestion  \n"
            case .ellipsis: String(repeating: "x", count: 70)
            case .skill: "[IMPORTANT: The user has invoked the \"work\" skill. The full skill content is loaded below.]\n<skill body>\nThe user has provided the following instruction alongside the skill invocation: show result"
            }
        }
        var preview: String {
            switch self {
            case .firstUser: "First user question"
            case .whitespace: "First  question"
            case .ellipsis: String(repeating: "x", count: 60) + "..."
            case .skill: "/work — show result"
            }
        }
    }

    @Test(arguments: Shape.allCases)
    func firstUserPreviewAtEqualCountCanAcknowledgeActuallyDisplayedFullConversation(_ shape: Shape) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let latestAt = Date(timeIntervalSince1970: 200)
        let messages: [ChatMessage] = [
            .init(id: "first-user", role: .user, text: shape.userText, timestamp: latestAt.addingTimeInterval(-1)),
            .init(id: "last-reply", role: .assistant, text: "The latest assistant reply.", timestamp: latestAt)]
        service.snapshots[identity.root]?.messages = messages
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: shape.preview, updatedAt: latestAt, messageCount: 2)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner)
        workspace.displayed(screen.owner)
        let card = try #require(workspace.cards(profile: service.profile).first)
        #expect(!card.unread)
        #expect(card.replyPreview == "The latest assistant reply.")
        #expect(workspace.persisted().record(screen.selectedChatID)?.summary?.preview == Data(shape.preview.utf8))
        #expect(workspace.screen(profile: service.profile)?.snapshot?.messages == messages)
    }

    @Test(arguments: Shape.allCases)
    func firstOfflineDisplayCannotAcknowledgeNewerSummaryAtEqualCount(_ shape: Shape) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let oldAt = Date(timeIntervalSince1970: 200), newAt = Date(timeIntervalSince1970: 400)
        let old: [ChatMessage] = [.init(id: "first-user", role: .user, text: shape.userText, timestamp: oldAt),
            .init(id: "reply", role: .assistant, text: "Old reply", timestamp: oldAt)]
        var book = ConversationBook()
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: shape.preview, updatedAt: newAt, messageCount: 2)
        let chat = book.merge(service.summaries[0])
        book.cache(.init(id: "cached", storedID: identity.stored.text, profileID: service.profile.text, messages: old), for: chat)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        await workspace.openBot(profile: service.profile)
        let stale = try #require(workspace.screen(profile: service.profile))
        let staleCards = workspace.cards(profile: service.profile)
        #expect(staleCards.first?.unread == true)
        workspace.displayed(stale.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        workspace.displayed(stale.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        service.snapshots[identity.root]?.messages = [old[0],
            .init(id: "reply", role: .assistant, text: "Updated reply", timestamp: newAt)]
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let actual = try #require(workspace.screen(profile: service.profile))
        let actualCards = workspace.cards(profile: service.profile)
        #expect(actualCards.first?.unread == true)
        workspace.displayed(actual.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
        #expect(workspace.cards(profile: service.profile).first?.replyPreview == "Updated reply")
    }

    @Test(arguments: Shape.allCases)
    func sameFirstUserPreviewDoesNotConsumeUnseenGrowthUntilNewContentIsDisplayed(_ shape: Shape) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let oldAt = Date(timeIntervalSince1970: 200), newAt = Date(timeIntervalSince1970: 400)
        let old: [ChatMessage] = [.init(id: "first-user", role: .user, text: shape.userText, timestamp: oldAt),
            .init(id: "old-reply", role: .assistant, text: "Old reply", timestamp: oldAt)]
        service.snapshots[identity.root]?.messages = old
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: shape.preview, updatedAt: oldAt, messageCount: 2)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner); workspace.displayed(a.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
        let b = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(b, owner: a.owner)))
        let ownerB = try #require(workspace.screen(profile: service.profile)?.owner)
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: shape.preview, updatedAt: newAt, messageCount: 4)
        await workspace.refreshDirectory(ownerB)
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        workspace.setOnline(false)
        let offlineB = try #require(workspace.screen(profile: service.profile))
        await workspace.select(try #require(workspace.captureSelection(a.selectedChatID, owner: offlineB.owner)))
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        let fresh = old + [.init(id: "follow-up", role: .user, text: "A follow-up", timestamp: newAt),
            .init(id: "new-reply", role: .assistant, text: "New reply", timestamp: newAt)]
        service.snapshots[identity.root]?.messages = fresh
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let actual = try #require(workspace.screen(profile: service.profile))
        workspace.displayed(actual.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
        #expect(workspace.cards(profile: service.profile).first?.replyPreview == "New reply")
        #expect(workspace.screen(profile: service.profile)?.snapshot?.messages == fresh)
    }
    @Test(arguments: Shape.allCases)
    func directoryGrowthAfterEarlierReadNeedsMatchingCurrentFullRead(_ shape: Shape) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let oldAt = Date(timeIntervalSince1970: 200), newAt = Date(timeIntervalSince1970: 400)
        let old: [ChatMessage] = [.init(id: "first-user", role: .user, text: shape.userText, timestamp: oldAt),
            .init(id: "old-reply", role: .assistant, text: "Old reply", timestamp: oldAt)]
        service.snapshots[identity.root]?.messages = old
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: shape.preview, updatedAt: oldAt, messageCount: 2)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let initial = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(initial.owner); workspace.displayed(initial.owner)
        service.snapshots[identity.root]?.messages = old + [.init(id: "new-user", role: .user, text: "Follow up", timestamp: newAt),
            .init(id: "new-reply", role: .assistant, text: "Already displayed new reply", timestamp: newAt)]
        workspace.receive(try service.fullReadPublication(identity))
        let fresh = try #require(workspace.screen(profile: service.profile))
        workspace.displayed(fresh.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
        let seenBefore = workspace.persisted().record(fresh.selectedChatID)?.seen
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: shape.preview, updatedAt: newAt, messageCount: 4)
        await workspace.refreshDirectory(fresh.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true,
            "The earlier full read did not observe these later directory facts")
        workspace.displayed(fresh.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        #expect(workspace.persisted().record(fresh.selectedChatID)?.seen?.observedAt == seenBefore?.observedAt)
        await workspace.openBot(profile: service.profile)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        let card = try #require(workspace.cards(profile: service.profile).first)
        #expect(!card.unread)
        #expect(card.replyPreview == "Already displayed new reply")
        #expect(workspace.persisted().record(fresh.selectedChatID)?.seen?.observedAt == seenBefore?.observedAt)
    }

    @Test(arguments: Shape.allCases)
    func directoryAfterMatchingFirstEntryReadKeepsAlreadyDisplayedReplyRead(_ shape: Shape) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.snapshots[identity.root]?.messages = [
            .init(id: "first-user", role: .user, text: shape.userText),
            .init(id: "reply", role: .assistant, text: "Already displayed reply")]
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: shape.preview, messageCount: 4)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.displayed(screen.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
        let seenAt = workspace.persisted().record(screen.selectedChatID)?.seen?.observedAt
        await workspace.refreshDirectory(screen.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
        #expect(workspace.cards(profile: service.profile).first?.replyPreview == "Already displayed reply")
        #expect(workspace.persisted().record(screen.selectedChatID)?.seen?.observedAt == seenAt)
    }

}

@MainActor final class InboxPreviewRenderingTests: XCTestCase {
    func testCachedBotRowsUseReadablePreviewsAndHonestFallbacks() async throws {
        let cases: [(String, String, [ChatMessage])] = [
            ("Quiet helper", "Checks your inbox.", [.init(id: "quiet", role: .assistant, text: "[SILENT]")]),
            ("Quiet bot", "", [.init(id: "quiet", role: .assistant, text: "NO_REPLY")]),
            ("Process helper", "", [.init(id: "reply", role: .assistant, text: "The build is ready."),
                .init(id: "process", role: .user, text: "[IMPORTANT: Background process proc_example completed normally.]", displayKind: "process_complete")]),
            ("Ordinary helper", "", [.init(id: "reply", role: .assistant, text: "The report is ready.")]),
            ("New helper", "", [])
        ]
        var stores: [(AppStore, ConnectionConfiguration)] = []
        defer { for (store, configuration) in stores { store.forgetConnection(); LocalHistory.remove(for: configuration.id) } }
        var entries: [AppStore.InboxEntry] = []
        for (name, description, messages) in cases {
            let service = try WorkspaceTestService(), identity = service.summaries[0].identity
            let bot = BotProfile(id: service.profile.text, name: name, description: description, preview: messages.last?.text ?? "")
            service.rosterBot = try JSONDecoder().decode(BotProfile.self, from: JSONEncoder().encode(bot))
            service.snapshots[identity.root]?.messages = messages
            service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
                preview: bot.preview, messageCount: messages.count)
            let configuration = ConnectionConfiguration(serverURL: URL(string: "https://rendered-inbox.invalid")!)
            let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
            stores.append((store, configuration))
            let connected = await store.connect(configuration)
            XCTAssertTrue(connected)
            await store.chats.refreshInboxPreviews(profiles: [service.profile])
            entries.append(try XCTUnwrap(store.inbox.first))
        }
        for scheme in [ColorScheme.light, .dark] {
            let content = VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    BotRow(bot: entry.bot, image: nil, unread: entry.isUnread, aggregate: entry.aggregate)
                }
            }
            .padding(20).frame(width: 390).background(BottoTheme.paper)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Readable inbox previews - \(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
            let text = try XCTUnwrap(request.results).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            for expected in ["Checks your inbox", "No recent message", "The build is ready", "The report is ready", "Start a chat"] {
                XCTAssertTrue(text.contains(expected), "Missing \(expected) in rendered rows: \(text)")
            }
            XCTAssertFalse(text.contains("SILENT") || text.contains("NO_REPLY") || text.contains("IMPORTANT") || text.contains("proc_example"))
        }
    }
}

@MainActor struct InboxMessagePreviewTests {
    @MainActor private final class Callback {
        var entered = false
    }
    private func fixture(_ service: WorkspaceTestService, book: ConversationBook? = nil) -> ConversationWorkspace {
        var book = book ?? ConversationBook()
        for summary in service.summaries { _ = book.merge(summary) }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")])
        workspace.setOnline(true)
        return workspace
    }

    @Test func coldInboxReadsMessagesWithoutOpeningOrAcknowledgingTheChat() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.snapshots[identity.root]?.messages = [
            .init(id: "answer", role: .assistant, text: "The service is healthy.", timestamp: .init(timeIntervalSince1970: 100)),
            .init(id: "process", role: .user, text: "Raw process details", displayKind: "process_complete"),
            .init(id: "silent", role: .assistant, text: "[SILENT]")]
        let workspace = fixture(service)
        let before = workspace.persisted()
        await workspace.refreshInboxPreviews(profiles: [service.profile])
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "The service is healthy.")
        #expect(service.opens.isEmpty)
        #expect(workspace.persisted().records.allSatisfy { $0.seen == nil })
        #expect(workspace.persisted().records.map(\.summary) == before.records.map(\.summary))
        #expect(workspace.persisted().records.allSatisfy { $0.transcript == nil })
        let restored = try JSONDecoder().decode(ConversationBook.self, from: JSONEncoder().encode(workspace.persisted()))
        #expect(fixture(service, book: restored).aggregate(profile: service.profile).preview?.text == "The service is healthy.")
    }

    @Test func inboxReadsThePreferredOpeningChat() async throws {
        let service = try WorkspaceTestService(), other = service.summaries[1].identity
        service.snapshots[other.root]?.messages = [.init(id: "other", role: .assistant, text: "The other chat's latest reply.")]
        var book = ConversationBook()
        for summary in service.summaries { _ = book.merge(summary) }
        let otherID = try #require(book.matching(other))
        book.updatePreference(service.profile) { $0.preferred = otherID }
        let workspace = fixture(service, book: book)
        await workspace.refreshInboxPreviews(profiles: [service.profile])
        #expect(service.previewReads.map(\.root) == [other.root])
        #expect(service.previewReads.map(\.stored) == [other.stored])
        #expect(service.previewReads.map(\.profile) == [other.profile])
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "The other chat's latest reply.")
        await workspace.openBot(profile: service.profile)
        #expect(service.opens.last?.root == other.root)
        #expect(service.opens.last?.stored == other.stored)
    }

    @Test func delayedPreviewCannotReplaceANewerLiveMessage() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let gate = WorkspaceGate(); service.previewGate = gate
        let workspace = fixture(service)
        let read = Task { await workspace.refreshInboxPreviews(profiles: [service.profile]) }
        await gate.entered()
        service.snapshots[identity.root]?.messages.append(.init(id: "new", role: .assistant, text: "A newer live reply."))
        await workspace.openBot(profile: service.profile)
        gate.release(); await read.value
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "A newer live reply.")
        #expect(workspace.persisted().records.allSatisfy { $0.seen == nil })
        workspace.retireWorkspace()
    }

    @Test(arguments: [false, true])
    func unavailableOrIncompleteReadKeepsTheCachedMessage(fails: Bool) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        var book = ConversationBook()
        let id = book.merge(service.summaries[0])
        book.cache(.init(id: "cache", storedID: identity.stored.text, profileID: service.profile.text,
            messages: [.init(id: "cached", role: .assistant, text: "Keep this useful reply.")]), for: id)
        service.previewResult = .init(preview: nil, isComplete: false)
        if fails { service.previewError = HermesServiceError.timeout }
        let workspace = fixture(service, book: book)
        await workspace.refreshInboxPreviews(profiles: [service.profile])
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "Keep this useful reply.")
        service.previewError = nil
        service.previewResult = .init(preview: nil, isComplete: true)
        await workspace.refreshInboxPreviews(profiles: [service.profile])
        #expect(workspace.aggregate(profile: service.profile).preview == nil)
        let restored = try JSONDecoder().decode(ConversationBook.self, from: JSONEncoder().encode(workspace.persisted()))
        #expect(fixture(service, book: restored).aggregate(profile: service.profile).preview == nil)
    }

    @Test func lateReadFromRetiredConnectionCannotReplaceItsSuccessor() async throws {
        let service = try WorkspaceTestService()
        let gate = WorkspaceGate(); service.previewGate = gate
        let workspace = fixture(service)
        let stale = Task { await workspace.refreshInboxPreviews(profiles: [service.profile]) }
        await gate.entered()
        workspace.retireConnection(); workspace.setOnline(true)
        service.previewGate = nil
        service.previewResult = .init(preview: .init(message: .init(id: "new", role: .assistant, text: "The reconnected reply.")), isComplete: true)
        await workspace.refreshInboxPreviews(profiles: [service.profile])
        gate.release(); await stale.value
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "The reconnected reply.")
        #expect(service.opens.isEmpty)
    }

    @Test func observationCallbackCannotPublishAPreviewAfterRetiringItsConnection() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        var book = ConversationBook()
        let id = book.merge(service.summaries[0])
        book.cache(.init(id: "cache", storedID: identity.stored.text, profileID: service.profile.text,
            messages: [.init(id: "old", role: .assistant, text: "Keep the cached reply.")]), for: id)
        service.previewResult = .init(preview: .init(message: .init(id: "new", role: .assistant, text: "A retired result.")), isComplete: true)
        let workspace = fixture(service, book: book), callback = Callback()
        withObservationTracking { _ = workspace.aggregate(profile: service.profile).preview } onChange: {
            MainActor.assumeIsolated {
                guard !callback.entered else { return }
                callback.entered = true
                workspace.retireConnection()
            }
        }
        await workspace.refreshInboxPreviews(profiles: [service.profile])
        #expect(callback.entered)
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "Keep the cached reply.")
    }

    @Test func oldCacheDerivesPreviewFromTypedHistory() throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        var book = ConversationBook()
        let id = book.merge(service.summaries[0])
        book.cache(.init(id: "cache", storedID: identity.stored.text, profileID: service.profile.text, messages: [
            .init(id: "reply", role: .assistant, text: "A useful cached answer."),
            .init(id: "silent", role: .assistant, text: "[SILENT]")]), for: id)
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        var records = try #require(raw["records"] as? [[String: Any]])
        for index in records.indices { records[index].removeValue(forKey: "inboxPreview") }
        raw["records"] = records
        let restored = try JSONDecoder().decode(ConversationBook.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(fixture(service, book: restored).aggregate(profile: service.profile).preview?.text == "A useful cached answer.")
    }
}
