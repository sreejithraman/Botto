import Foundation
import Observation
import Testing
import BottoCore
import SwiftUI
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
            await store.chats.refreshInboxHistory(profiles: [service.profile])
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
            let expected = ["Checks your inbox", "No recent message", "The build is ready", "The report is ready", "Start a chat"]
            let text = try await renderedText(expected: expected, scheme: scheme) {
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                return renderer.uiImage
            }
            for phrase in expected {
                XCTAssertTrue(text.contains(phrase), "Missing \(phrase) in rendered rows: \(text)")
            }
        }
    }

    private func renderedText(expected: [String], scheme: ColorScheme, render: () -> UIImage?) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(30)
        var firstImage: UIImage?, lastImage: UIImage?
        var text = "", attempts = 0
        defer {
            if attempts > 1, let firstImage { attach(firstImage, named: "Initial inbox previews - \(scheme)") }
            if let lastImage { attach(lastImage, named: "Readable inbox previews - \(scheme)") }
            let diagnostic = XCTAttachment(string: "scheme=\(scheme) attempts=\(attempts) text=\(text)")
            diagnostic.name = "Inbox render readiness"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            attempts += 1
            if let image = render(), let cgImage = image.cgImage {
                if firstImage == nil { firstImage = image }
                lastImage = image
                let recognized: Result<[String], Error>? = await NativeRecognitionDeadline.run(until: deadline) {
                    do {
                        return .success(try await NativeTextRecognition.recognize(cgImage,
                            usesLanguageCorrection: true, onRecognition: { isMainThread in
                                XCTAssertFalse(isMainThread, "Vision recognition must not block the native UI thread")
                            }))
                    } catch { return .failure(error) }
                }
                try Task.checkCancellation()
                guard let recognized else { break }
                text = try recognized.get().joined(separator: " ")
                XCTAssertFalse(text.contains("SILENT") || text.contains("NO_REPLY") || text.contains("IMPORTANT") || text.contains("proc_example"))
                if expected.allSatisfy({ text.contains($0) }) { return text }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return text
    }

    private func attach(_ image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor struct InboxMessagePreviewTests {
    @Test func inboxReplyIsAlreadyInChatWhileLiveAttachmentWaits() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let old = ChatMessage(id: "old", role: .assistant, text: "Previous reply")
        let fresh = ChatMessage(id: "fresh", role: .assistant, text: "The **latest** reply, in full.",
            attachments: [.init(name: "report.pdf", path: "/report.pdf", mimeType: "application/pdf")])
        var book = ConversationBook()
        let id = book.merge(service.summaries[0])
        book.cache(.init(id: "cached", storedID: identity.stored.text, profileID: service.profile.text, messages: [old]), for: id)
        book.update(id) { $0.draft = .init(text: "Keep my draft", revision: UUID()) }
        service.snapshots[identity.root]?.messages = [old, fresh]
        let workspace = fixture(service, book: book)
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "The latest reply, in full.")
        let gate = WorkspaceGate(); service.openGate = gate
        let opening = Task { await workspace.openBot(profile: service.profile) }
        await gate.entered()
        let waiting = try #require(workspace.screen(profile: service.profile))
        #expect(waiting.snapshot?.messages == [old, fresh])
        #expect(workspace.draft(waiting.owner) == "Keep my draft")
        #expect(waiting.isOpening && !waiting.canAct)
        #expect(workspace.persisted().record(id)?.seen == nil)
        gate.release(); await opening.value
        #expect(workspace.screen(profile: service.profile)?.snapshot?.messages == [old, fresh])
        #expect(workspace.draft(try #require(workspace.screen(profile: service.profile)?.owner)) == "Keep my draft")
        workspace.retireWorkspace()
    }

    @Test(arguments: [true, false])
    func boundedHistoryPreservesAProvenPrefixAndQualifiesAnUnjoinedWindow(overlaps: Bool) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let older = ChatMessage(id: "older", role: .user, text: "An older question")
        let anchor = ChatMessage(id: "anchor", role: .assistant, text: "Old revision")
        let removed = ChatMessage(id: "removed", role: .assistant, text: "Removed from the new suffix")
        let revised = ChatMessage(id: "anchor", role: .assistant, text: "Revised answer")
        let latest = ChatMessage(id: "latest", role: .assistant, text: "Newest answer")
        var book = ConversationBook()
        let id = book.merge(service.summaries[0])
        book.cache(.init(id: "cached", storedID: identity.stored.text, profileID: service.profile.text,
            messages: [older, anchor, removed]), for: id)
        service.previewResult = .init(messages: overlaps ? [revised, latest] : [latest], hasEarlierMessages: true)
        let workspace = fixture(service, book: book)
        await workspace.refreshInboxHistory(profiles: [service.profile])
        workspace.setOnline(false)
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        #expect(screen.snapshot?.messages == (overlaps ? [older, revised, latest] : [latest]))
        #expect(screen.hasEarlierMessages == !overlaps)
        #expect(screen.snapshot?.pendingRequests.isEmpty == true)
        #expect(!screen.canAct)
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "Newest answer")
        let restored = try JSONDecoder().decode(ConversationBook.self, from: JSONEncoder().encode(workspace.persisted()))
        let cold = fixture(service, book: restored)
        cold.setOnline(false); await cold.openBot(profile: service.profile)
        #expect(cold.screen(profile: service.profile)?.snapshot?.messages == screen.snapshot?.messages)
        #expect(cold.screen(profile: service.profile)?.hasEarlierMessages == !overlaps)
    }

    @Test func anUnavailableAnchorCannotProvePrefixContinuity() throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let older = ChatMessage(id: "older", role: .assistant, text: "Old prefix")
        let anchor = ChatMessage(id: "anchor", role: .assistant, text: "Disputed old anchor")
        var snapshot = Conversation(id: "cache", storedID: identity.stored.text, profileID: service.profile.text,
            messages: [older, anchor])
        snapshot.unavailableMessageIDs = [Data(anchor.id.utf8)]
        var book = ConversationBook()
        let id = book.merge(service.summaries[0]); book.cache(snapshot, for: id)
        let observed = ChatMessage(id: anchor.id, role: .assistant, text: "Newly fetched row")
        book.cache(.init(messages: [observed], hasEarlierMessages: true), for: id)
        #expect(book.record(id)?.transcript?.messages == [observed])
        #expect(book.record(id)?.transcript?.hasEarlierMessages == true)
        let index = TranscriptMessageIndex(book.record(id)?.transcript)
        #expect(!index.matches(observed))
    }

    @Test func incompleteLiveHistoryKeepsItsQualifierThroughIncrementalsAndDisk() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.snapshots[identity.root]?.hasEarlierMessages = true
        let workspace = fixture(service)
        await workspace.openBot(profile: service.profile)
        #expect(workspace.screen(profile: service.profile)?.hasEarlierMessages == true)
        service.snapshots[identity.root]?.messages.append(.init(id: "delta", role: .assistant, text: "A new reply"))
        workspace.receive(try service.publication(identity))
        #expect(workspace.screen(profile: service.profile)?.hasEarlierMessages == true)
        let restored = try JSONDecoder().decode(ConversationBook.self, from: JSONEncoder().encode(workspace.persisted()))
        let cold = fixture(service, book: restored)
        cold.setOnline(false); await cold.openBot(profile: service.profile)
        #expect(cold.screen(profile: service.profile)?.hasEarlierMessages == true)
        service.snapshots[identity.root]?.hasEarlierMessages = false
        await workspace.openBot(profile: service.profile)
        #expect(workspace.screen(profile: service.profile)?.hasEarlierMessages == false)
        workspace.retireWorkspace(); cold.retireWorkspace()
    }

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
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "The service is healthy.")
        #expect(service.opens.isEmpty)
        #expect(workspace.persisted().records.allSatisfy { $0.seen == nil })
        #expect(workspace.persisted().records.map(\.summary) == before.records.map(\.summary))
        #expect(workspace.persisted().records.first { $0.binding.identity?.root == identity.root }?.transcript?.messages == service.snapshots[identity.root]?.messages)
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
        await workspace.refreshInboxHistory(profiles: [service.profile])
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
        let read = Task { await workspace.refreshInboxHistory(profiles: [service.profile]) }
        await gate.entered()
        service.snapshots[identity.root]?.messages.append(.init(id: "new", role: .assistant, text: "A newer live reply."))
        await workspace.openBot(profile: service.profile)
        gate.release(); await read.value
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "A newer live reply.")
        #expect(workspace.persisted().records.allSatisfy { $0.seen == nil })
        workspace.retireWorkspace()
    }

    @Test func attachingRetiresAnOlderOptionalHistoryRead() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let cached = ChatMessage(id: "cached", role: .assistant, text: "Cached reply")
        var book = ConversationBook()
        let id = book.merge(service.summaries[0])
        book.cache(.init(id: "cache", storedID: identity.stored.text, profileID: service.profile.text,
            messages: [cached]), for: id)
        service.snapshots[identity.root]?.messages = [.init(id: "intermediate", role: .assistant, text: "Older optional read")]
        let previewGate = WorkspaceGate(); service.previewGate = previewGate
        let workspace = fixture(service, book: book)
        let preview = Task { await workspace.refreshInboxHistory(profiles: [service.profile]) }
        await previewGate.entered()
        let latest = ChatMessage(id: "latest", role: .assistant, text: "Current attachment reply")
        service.snapshots[identity.root]?.messages = [latest]
        let openGate = WorkspaceGate(); service.openGate = openGate
        let opening = Task { await workspace.openBot(profile: service.profile) }
        await openGate.entered()
        previewGate.release(); await preview.value
        #expect(workspace.screen(profile: service.profile)?.snapshot?.messages == [cached])
        openGate.release(); await opening.value
        #expect(workspace.screen(profile: service.profile)?.snapshot?.messages == [latest])
        #expect(workspace.aggregate(profile: service.profile).preview?.text == latest.text)
        workspace.retireWorkspace()
    }

    @Test(arguments: ["success", "failure", "cancel"])
    func delayedSelectionFencesHistoryForItsActualAttachmentTarget(outcome: String) async throws {
        let service = try WorkspaceTestService(), target = service.summaries[0].identity
        var book = ConversationBook()
        for summary in service.summaries { _ = book.merge(summary) }
        let mainID = try #require(book.matching(target))
        book.updatePreference(service.profile) { $0.preferred = mainID }
        let workspace = fixture(service, book: book)
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(other, owner: main.owner)))
        let gate = WorkspaceGate(); service.openGate = gate
        let cancellation = Callback()
        let opening = Task { await workspace.openNotificationChat(target, isCurrent: { !cancellation.entered }) }
        await gate.entered()
        let count = service.previewReads.count
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(service.previewReads.count == count)
        if outcome == "failure" { service.openError = HermesServiceError.timeout }
        if outcome == "cancel" { cancellation.entered = true; opening.cancel() }
        gate.release()
        #expect(await opening.value == (outcome == "success"))
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
        service.previewUnavailable = true
        if fails { service.previewError = HermesServiceError.timeout }
        let workspace = fixture(service, book: book)
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(workspace.aggregate(profile: service.profile).preview?.text == "Keep this useful reply.")
        service.previewError = nil
        service.previewUnavailable = false
        service.previewResult = .init(messages: [], hasEarlierMessages: false)
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(workspace.aggregate(profile: service.profile).preview == nil)
        let restored = try JSONDecoder().decode(ConversationBook.self, from: JSONEncoder().encode(workspace.persisted()))
        #expect(fixture(service, book: restored).aggregate(profile: service.profile).preview == nil)
    }

    @Test func lateReadFromRetiredConnectionCannotReplaceItsSuccessor() async throws {
        let service = try WorkspaceTestService()
        let gate = WorkspaceGate(); service.previewGate = gate
        let workspace = fixture(service)
        let stale = Task { await workspace.refreshInboxHistory(profiles: [service.profile]) }
        await gate.entered()
        workspace.retireConnection(); workspace.setOnline(true)
        service.previewGate = nil
        service.previewResult = .init(messages: [.init(id: "new", role: .assistant, text: "The reconnected reply.")], hasEarlierMessages: false)
        await workspace.refreshInboxHistory(profiles: [service.profile])
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
        service.previewResult = .init(messages: [.init(id: "new", role: .assistant, text: "A retired result.")], hasEarlierMessages: false)
        let workspace = fixture(service, book: book), callback = Callback()
        withObservationTracking { _ = workspace.aggregate(profile: service.profile).preview } onChange: {
            MainActor.assumeIsolated {
                guard !callback.entered else { return }
                callback.entered = true
                workspace.retireConnection()
            }
        }
        await workspace.refreshInboxHistory(profiles: [service.profile])
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
        for index in records.indices {
            records[index]["inboxPreview"] = ["message": ["messageID": "stale", "text": "An old excerpt"]]
        }
        raw["records"] = records
        let restored = try JSONDecoder().decode(ConversationBook.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(fixture(service, book: restored).aggregate(profile: service.profile).preview?.text == "A useful cached answer.")
    }
}

@MainActor private final class InboxWindowPublicationProbe {
    var dirtyCount = 0
    var displayChanges = 0
    var enteredCallback = false
    var publications: [ChatTranscriptPublication] = []
}

extension InboxMessagePreviewTests {
    @Test func identicalHistoryWindowKeepsDisplayQuietAndPublishesFreshReadEvidence() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let probe = InboxWindowPublicationProbe()
        var book = ConversationBook()
        let id = book.merge(service.summaries[0])
        let rowID = identity.stored.text + ":row:1"
        let proof = ConversationIdentityRead(identity: identity, messageIDs: [Data(rowID.utf8)])
        service.previewResult = .init(messages: [.init(id: rowID, role: .assistant, text: "Caf\u{e9}")],
            hasEarlierMessages: false, identityRead: proof)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: { probe.dirtyCount += 1 })
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")])
        workspace.setOnline(true)
        workspace.onAcceptedTranscript = { probe.publications.append($0) }
        defer { workspace.retireWorkspace() }

        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.dirtyCount == 1)
        #expect(probe.publications.count == 1)
        let first = try #require(probe.publications.first?.evidence.readContext)
        withObservationTracking { _ = workspace.aggregate(profile: service.profile).preview } onChange: {
            MainActor.assumeIsolated { probe.displayChanges += 1 }
        }
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.displayChanges == 0)
        #expect(probe.dirtyCount == 1)
        #expect(service.previewReads.count == 2)
        #expect(probe.publications.count == 2)
        let secondPublication = try #require(probe.publications.last)
        guard case .window(let startedAt, let source, let identityRead) = secondPublication.evidence else {
            Issue.record("A repeated history read must still publish window evidence")
            return
        }
        #expect(startedAt > first.startedAt)
        #expect(source == service.previewReads.last)
        #expect(identityRead?.matches(identity) == true)
        #expect(identityRead?.messageIDs == proof.messageIDs)

        service.previewResult = .init(messages: [.init(id: rowID, role: .assistant, text: "Cafe\u{301}")],
            hasEarlierMessages: false, identityRead: proof)
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.displayChanges == 1)
        #expect(probe.dirtyCount == 2)
        #expect(probe.publications.count == 3)
        #expect(workspace.persisted().record(id)?.transcript?.messages.first.map { Data($0.text.utf8) }
            == Data("Cafe\u{301}".utf8))
    }

    @Test func changedHistoryWindowPreservesCallbackDraftAndSiblingQueue() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let sibling = service.summaries[1].identity
        let probe = InboxWindowPublicationProbe()
        var book = ConversationBook()
        for summary in service.summaries { _ = book.merge(summary) }
        let mainID = try #require(book.matching(identity)), siblingID = try #require(book.matching(sibling))
        book.updatePreference(service.profile) { $0.preferred = mainID }
        book.cache(.init(id: "cache", storedID: identity.stored.text, profileID: service.profile.text,
            messages: [.init(id: "old", role: .assistant, text: "Old answer")]), for: mainID)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")])
        workspace.setOnline(true)
        defer { workspace.retireWorkspace() }
        await workspace.openBot(profile: service.profile)
        let mainOwner = try #require(workspace.screen(profile: service.profile)?.owner)
        await workspace.select(try #require(workspace.captureSelection(siblingID, owner: mainOwner)))
        let siblingOwner = try #require(workspace.screen(profile: service.profile)?.owner)
        let queued = QueuedMessage(id: "queued", text: "Keep the sibling queue", canEdit: true)
        service.snapshots[sibling.root]?.queuedMessages = [queued]
        let siblingPublication = try service.publication(sibling)
        service.previewResult = .init(messages: [.init(id: "new", role: .assistant, text: "Fresh answer")], hasEarlierMessages: false)
        workspace.onAcceptedTranscript = { probe.publications.append($0) }
        withObservationTracking { _ = workspace.aggregate(profile: service.profile).preview } onChange: {
            MainActor.assumeIsolated {
                guard !probe.enteredCallback else { return }
                probe.enteredCallback = true
                workspace.editDraft("Keep the callback draft", owner: siblingOwner)
                workspace.receive(siblingPublication)
            }
        }
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.enteredCallback)
        #expect(workspace.draft(siblingOwner) == "Keep the callback draft")
        #expect(workspace.persisted().record(siblingID)?.transcript?.queuedMessages == [queued])
        #expect(workspace.persisted().record(mainID)?.transcript?.messages.last?.text == "Fresh answer")
        #expect(probe.publications.contains { $0.identity == service.previewReads.last && $0.snapshot.messages.last?.text == "Fresh answer" })
    }

    @Test func changedHistoryWindowCannotCrossCallbackRecovery() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let probe = InboxWindowPublicationProbe()
        var book = ConversationBook()
        let id = book.merge(service.summaries[0])
        book.cache(.init(id: "cache", storedID: identity.stored.text, profileID: service.profile.text,
            messages: [.init(id: "old", role: .assistant, text: "Keep the original answer")]), for: id)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: { probe.dirtyCount += 1 })
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")])
        workspace.setOnline(true)
        defer { workspace.retireWorkspace() }
        service.previewResult = .init(messages: [.init(id: "new", role: .assistant, text: "Retired read")], hasEarlierMessages: false)
        workspace.onAcceptedTranscript = { probe.publications.append($0) }
        withObservationTracking { _ = workspace.aggregate(profile: service.profile).preview } onChange: {
            MainActor.assumeIsolated {
                guard !probe.enteredCallback else { return }
                probe.enteredCallback = true
                workspace.setOnline(false)
                workspace.setOnline(true)
            }
        }
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.enteredCallback)
        #expect(workspace.persisted().record(id)?.transcript?.messages.last?.text == "Keep the original answer")
        #expect(probe.publications.isEmpty)
        #expect(probe.dirtyCount == 0)
    }
}

extension InboxMessagePreviewTests {
    enum RejectedReadControl: CaseIterable, Sendable {
        case reconnected, offline, opened, tipMoved, foreignProfile, foreignRoot, foreignTip, unknownFailure, noDisputes
    }

    private func disputedFixture(_ service: WorkspaceTestService, probe: InboxWindowPublicationProbe)
        -> (workspace: ConversationWorkspace, chat: ChatID) {
        let identity = service.summaries[0].identity
        var book = ConversationBook()
        let chat = book.merge(service.summaries[0])
        book.updatePreference(service.profile) { $0.preferred = chat }
        book.cache(.init(id: "cache", storedID: identity.stored.text, profileID: service.profile.text,
            messages: [.init(id: "disputed", role: .assistant, text: "Cached answer"),
                .init(id: "sibling", role: .assistant, text: "Sibling answer")]), for: chat)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: { probe.dirtyCount += 1 })
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")])
        workspace.setOnline(true)
        workspace.onAcceptedTranscript = { probe.publications.append($0) }
        return (workspace, chat)
    }

    @Test func rejectedHistoryPublishesOnlyItsDisputesUnderTheReadStart() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let probe = InboxWindowPublicationProbe(), disputed = Data("disputed".utf8)
        let (workspace, chat) = disputedFixture(service, probe: probe)
        defer { workspace.retireWorkspace() }
        let requested = ContinuousClock.now
        // Evidence for one row cannot widen to the other rows of its rejected response.
        service.previewError = ConversationHistoryPage.Failure(identity: identity, unavailableMessageIDs: [disputed],
            sourceIDs: [Data("sibling".utf8)], exceedsRowLimit: true)
        await workspace.refreshInboxHistory(profiles: [service.profile])
        let publication = try #require(probe.publications.first)
        #expect(probe.publications.count == 1)
        #expect(probe.dirtyCount == 1)
        #expect(publication.identity == workspace.persisted().record(chat)?.binding.identity)
        #expect(publication.snapshot.messages.isEmpty, "A rejected read vouches for no rows")
        #expect(publication.snapshot.unavailableMessageIDs == [disputed])
        let read = try #require(publication.evidence.readContext)
        #expect(read.startedAt >= requested)
        #expect(read.identityRead == nil)
        #expect(read.observedSource == nil, "A rejected read cannot adopt a source")
        let retained = workspace.persisted().record(chat)?.transcript
        #expect(retained?.unavailableMessageIDs == [disputed])
        #expect(retained?.messages.map(\.text) == ["Cached answer", "Sibling answer"], "Disputed rows stay in the chat as ambiguous")

        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.publications.count == 2, "Repeated evidence still reaches a consumer that restarted")
        #expect(probe.dirtyCount == 1, "Unchanged evidence writes nothing")
    }

    @Test func onlyAProducerCertifiedWindowResolvesADispute() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let probe = InboxWindowPublicationProbe(), disputed = Data("disputed".utf8)
        let (workspace, chat) = disputedFixture(service, probe: probe)
        defer { workspace.retireWorkspace() }
        let rows = try #require(workspace.persisted().record(chat)?.transcript?.messages)
        service.previewError = ConversationHistoryPage.Failure(identity: identity, unavailableMessageIDs: [disputed])
        await workspace.refreshInboxHistory(profiles: [service.profile])
        service.previewError = nil
        for window in [ConversationHistoryWindow(messages: rows, hasEarlierMessages: true),
                       ConversationHistoryWindow(messages: rows, hasEarlierMessages: false)] {
            service.previewResult = window
            await workspace.refreshInboxHistory(profiles: [service.profile])
            #expect(workspace.persisted().record(chat)?.transcript?.unavailableMessageIDs == [disputed])
        }
        service.previewResult = .init(messages: rows, hasEarlierMessages: false,
            identityRead: .init(identity: identity, messageIDs: Set(rows.map { Data($0.id.utf8) })))
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(workspace.persisted().record(chat)?.transcript?.unavailableMessageIDs?.contains(disputed) != true)
    }

    @Test func rejectedHistoryWithoutACachedTranscriptOnlyReachesLibrary() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let probe = InboxWindowPublicationProbe()
        var book = ConversationBook()
        let chat = book.merge(service.summaries[0])
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: { probe.dirtyCount += 1 })
        defer { workspace.retireWorkspace() }
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")])
        workspace.setOnline(true)
        workspace.onAcceptedTranscript = { probe.publications.append($0) }
        service.previewError = ConversationHistoryPage.Failure(identity: identity, unavailableMessageIDs: [Data("disputed".utf8)])
        await workspace.refreshInboxHistory(profiles: [service.profile])
        let publication = try #require(probe.publications.first)
        #expect(publication.snapshot.unavailableMessageIDs == [Data("disputed".utf8)])
        #expect(workspace.persisted().record(chat)?.transcript == nil, "Evidence cannot invent a cached transcript")
        #expect(probe.dirtyCount == 0)
    }

    @Test(arguments: RejectedReadControl.allCases)
    func rejectedHistoryCannotDisputeAnotherOwner(control: RejectedReadControl) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let probe = InboxWindowPublicationProbe(), disputed = Data("disputed".utf8)
        let (workspace, chat) = disputedFixture(service, probe: probe)
        defer { workspace.retireWorkspace() }
        let foreign = try ExactID("foreign")
        var source = identity
        switch control {
        case .foreignProfile: source = .init(profile: foreign, root: identity.root, stored: identity.stored, aliases: [])
        case .foreignRoot: source = .init(profile: identity.profile, root: foreign, stored: identity.stored, aliases: [])
        case .foreignTip: source = .init(profile: identity.profile, root: identity.root, stored: foreign, aliases: [])
        default: break
        }
        service.previewError = switch control {
        case .unknownFailure: HermesServiceError.incompatible
        case .noDisputes: ConversationHistoryPage.Failure(identity: identity, unavailableMessageIDs: [], exceedsRowLimit: true)
        default: ConversationHistoryPage.Failure(identity: source, unavailableMessageIDs: [disputed])
        }
        let gate = WorkspaceGate(); service.previewGate = gate
        let refreshing = Task { await workspace.refreshInboxHistory(profiles: [service.profile]) }
        await gate.entered()
        switch control {
        case .reconnected: workspace.setOnline(false); workspace.setOnline(true)
        case .offline: workspace.setOnline(false)
        case .opened: await workspace.openBot(profile: service.profile)
        case .tipMoved:
            let moved = SessionIdentity(profile: identity.profile, root: identity.root, stored: try ExactID("moved-tip"), aliases: [])
            service.summaries[0] = .init(identity: moved, title: "Bot Chat", isCanonical: true, persistence: .durable)
            await workspace.refreshActivityDirectories(for: [.init(id: service.profile.text, name: "Milo")])
        default: break
        }
        gate.release(); await refreshing.value
        let disputes = probe.publications.filter { $0.evidence.readContext?.identityRead == nil && $0.snapshot.messages.isEmpty }
        #expect(disputes.isEmpty)
        #expect(workspace.persisted().record(chat)?.transcript?.unavailableMessageIDs == nil)
    }

    @Test(arguments: ["profile", "root", "tip"])
    func coherentProofResolvesOnlyTheNamedDisputesOfItsExactSource(foreign: String) async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let probe = InboxWindowPublicationProbe(), disputed = Data("disputed".utf8), other = Data("other".utf8)
        let (workspace, chat) = disputedFixture(service, probe: probe)
        defer { workspace.retireWorkspace() }
        service.previewError = ConversationHistoryPage.Failure(identity: identity, unavailableMessageIDs: [disputed, other])
        await workspace.refreshInboxHistory(profiles: [service.profile])
        let outsider = try ExactID("foreign"), dirty = probe.dirtyCount
        let elsewhere: SessionIdentity = switch foreign {
        case "profile": .init(profile: outsider, root: identity.root, stored: identity.stored, aliases: [])
        case "root": .init(profile: identity.profile, root: outsider, stored: identity.stored, aliases: [])
        default: .init(profile: identity.profile, root: identity.root, stored: outsider, aliases: [])
        }
        workspace.resolveDisputes([disputed, other], on: elsewhere)
        #expect(workspace.persisted().record(chat)?.transcript?.unavailableMessageIDs == [disputed, other])
        #expect(probe.dirtyCount == dirty, "Another source's proof writes nothing")
        workspace.resolveDisputes([disputed], on: identity)
        #expect(workspace.persisted().record(chat)?.transcript?.unavailableMessageIDs == [other])
        #expect(probe.dirtyCount == dirty + 1)
        workspace.resolveDisputes([other], on: identity)
        #expect(workspace.persisted().record(chat)?.transcript?.unavailableMessageIDs == nil)
    }

    @Test func resolvingADisputeLeavesDraftReadStateAndChatAccessAlone() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let probe = InboxWindowPublicationProbe(), disputed = Data("disputed".utf8)
        let (workspace, chat) = disputedFixture(service, probe: probe)
        defer { workspace.retireWorkspace() }
        service.previewError = ConversationHistoryPage.Failure(identity: identity, unavailableMessageIDs: [disputed])
        await workspace.refreshInboxHistory(profiles: [service.profile])
        await workspace.openBot(profile: service.profile)
        let owner = try #require(workspace.screen(profile: service.profile)?.owner)
        workspace.displayed(owner); workspace.editDraft("Keep this draft", owner: owner)
        let before = try #require(workspace.persisted().record(chat))
        try #require(before.transcript?.unavailableMessageIDs == [disputed] && before.seen != nil)
        let opens = service.opens.count

        workspace.resolveDisputes([disputed], on: identity)
        let after = try #require(workspace.persisted().record(chat))
        #expect(after.transcript?.unavailableMessageIDs == nil)
        #expect(after.draft.text == "Keep this draft" && after.draft.revision == before.draft.revision)
        #expect(after.seen?.observedAt == before.seen?.observedAt && after.seen?.content == before.seen?.content)
        #expect(workspace.isCurrent(owner), "Cache evidence retires no live access")
        #expect(workspace.screen(profile: service.profile)?.canAct == true)
        #expect(service.opens.count == opens)
    }
}
