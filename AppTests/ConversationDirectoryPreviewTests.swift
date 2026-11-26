import Foundation
import Observation
import Testing
import BottoCore
@testable import Botto

/// Directory text can come from the first user message and does not identify the latest message.
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
        #expect(workspace.chats(service.profile).first?.isUnread == false)
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
        let staleChats = workspace.chats(service.profile)
        #expect(staleChats.first?.isUnread == true)
        workspace.displayed(stale.owner)
        #expect(workspace.chats(service.profile).first?.isUnread == true)
        workspace.displayed(stale.owner)
        #expect(workspace.chats(service.profile).first?.isUnread == true)
        service.snapshots[identity.root]?.messages = [old[0],
            .init(id: "reply", role: .assistant, text: "Updated reply", timestamp: newAt)]
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let actual = try #require(workspace.screen(profile: service.profile))
        let actualChats = workspace.chats(service.profile)
        #expect(actualChats.first?.isUnread == true)
        workspace.displayed(actual.owner)
        #expect(workspace.chats(service.profile).first?.isUnread == false)
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
        #expect(workspace.chats(service.profile).first?.isUnread == false)
        #expect(await workspace.openSaved(service.summaries[1]))
        let ownerB = try #require(workspace.screen(profile: service.profile)?.owner)
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: shape.preview, updatedAt: newAt, messageCount: 4)
        await workspace.refreshDirectory(ownerB)
        #expect(workspace.chats(service.profile).first?.isUnread == true)
        workspace.setOnline(false)
        #expect(await workspace.openSaved(service.summaries[0]))
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.chats(service.profile).first?.isUnread == true)
        let fresh = old + [.init(id: "follow-up", role: .user, text: "A follow-up", timestamp: newAt),
            .init(id: "new-reply", role: .assistant, text: "New reply", timestamp: newAt)]
        service.snapshots[identity.root]?.messages = fresh
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let actual = try #require(workspace.screen(profile: service.profile))
        workspace.displayed(actual.owner)
        #expect(workspace.chats(service.profile).first?.isUnread == false)
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
        #expect(workspace.chats(service.profile).first?.isUnread == false)
        let seenBefore = workspace.persisted().record(fresh.selectedChatID)?.seen
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: shape.preview, updatedAt: newAt, messageCount: 4)
        await workspace.refreshDirectory(fresh.owner)
        #expect(workspace.chats(service.profile).first?.isUnread == true,
            "The earlier full read did not observe these later directory facts")
        workspace.displayed(fresh.owner)
        #expect(workspace.chats(service.profile).first?.isUnread == true)
        #expect(workspace.persisted().record(fresh.selectedChatID)?.seen?.observedAt == seenBefore?.observedAt)
        await workspace.openBot(profile: service.profile)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.chats(service.profile).first?.isUnread == false)
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
        #expect(workspace.chats(service.profile).first?.isUnread == false)
        let seenAt = workspace.persisted().record(screen.selectedChatID)?.seen?.observedAt
        await workspace.refreshDirectory(screen.owner)
        #expect(workspace.chats(service.profile).first?.isUnread == false)
        #expect(workspace.persisted().record(screen.selectedChatID)?.seen?.observedAt == seenAt)
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
            .init(id: "check", role: .tool, text: "uptime\nup 3 days", toolName: "Command"),
            .init(id: "empty", role: .assistant, text: "")]
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
        #expect(workspace.screen(profile: service.profile) != nil)
        #expect(await workspace.openSaved(service.summaries[1]))
        let gate = WorkspaceGate(); service.openGate = gate
        let cancellation = Callback()
        let opening = Task { await workspace.openNotificationChat(target, isCurrent: { !cancellation.entered }) }
        await gate.entered()
        let count = service.previewReads.count
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(service.previewReads.count == count)
        if outcome == "failure" { service.openError = ConversationServiceError.timeout }
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
        if fails { service.previewError = ConversationServiceError.timeout }
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
            .init(id: "check", role: .tool, text: "uptime\nup 3 days", toolName: "Command")]), for: id)
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
    var insideCallback = false
    var publications = 0
    /// What a file card would see when it rechecks: the chat's cached transcript as each notification fired.
    var observed: [(text: String?, unavailable: Set<Data>?, insideCallback: Bool)] = []
    func record(_ transcript: Conversation?) {
        publications += 1
        observed.append((transcript?.messages.last?.text, transcript?.unavailableMessageIDs, insideCallback))
    }
}

extension InboxMessagePreviewTests {
    @Test func identicalHistoryWindowKeepsDisplayQuietAndStillNotifiesCaptures() async throws {
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
        workspace.onAcceptedTranscript = { probe.publications += 1 }
        defer { workspace.retireWorkspace() }

        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.dirtyCount == 1)
        #expect(probe.publications == 1)
        withObservationTracking { _ = workspace.aggregate(profile: service.profile).preview } onChange: {
            MainActor.assumeIsolated { probe.displayChanges += 1 }
        }
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.displayChanges == 0)
        #expect(probe.dirtyCount == 1)
        #expect(service.previewReads.count == 2)
        #expect(probe.publications == 2, "A repeated history read still lets file cards recheck their rows")

        service.previewResult = .init(messages: [.init(id: rowID, role: .assistant, text: "Cafe\u{301}")],
            hasEarlierMessages: false, identityRead: proof)
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.displayChanges == 1)
        #expect(probe.dirtyCount == 2)
        #expect(probe.publications == 3)
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
        #expect(workspace.screen(profile: service.profile)?.owner.chat == mainID)
        #expect(await workspace.openSaved(service.summaries[1]))
        let siblingOwner = try #require(workspace.screen(profile: service.profile)?.owner)
        let queued = QueuedMessage(id: "queued", text: "Keep the sibling queue", canEdit: true)
        service.snapshots[sibling.root]?.queuedMessages = [queued]
        let siblingPublication = try service.publication(sibling)
        service.previewResult = .init(messages: [.init(id: "new", role: .assistant, text: "Fresh answer")], hasEarlierMessages: false)
        workspace.onAcceptedTranscript = { [weak workspace] in probe.record(workspace?.persisted().record(mainID)?.transcript) }
        withObservationTracking { _ = workspace.aggregate(profile: service.profile).preview } onChange: {
            MainActor.assumeIsolated {
                guard !probe.enteredCallback else { return }
                probe.enteredCallback = true
                probe.insideCallback = true; defer { probe.insideCallback = false }
                workspace.editDraft("Keep the callback draft", owner: siblingOwner)
                workspace.receive(siblingPublication)
            }
        }
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.enteredCallback)
        #expect(workspace.draft(siblingOwner) == "Keep the callback draft")
        #expect(workspace.persisted().record(siblingID)?.transcript?.queuedMessages == [queued])
        #expect(workspace.persisted().record(mainID)?.transcript?.messages.last?.text == "Fresh answer")
        #expect(service.previewReads.contains { $0.profile == identity.profile && $0.root == identity.root },
            "The main chat's history was read: \(service.previewReads)")
        // The sibling's publication notifies from inside the callback; the fresh read must notify on its own.
        #expect(probe.observed.contains { !$0.insideCallback && $0.text == "Fresh answer" },
            "The accepted fresh read lets file cards recheck against it")
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
        workspace.onAcceptedTranscript = { probe.publications += 1 }
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
        #expect(probe.publications == 0)
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
        workspace.onAcceptedTranscript = { [weak workspace] in probe.record(workspace?.persisted().record(chat)?.transcript) }
        return (workspace, chat)
    }

    @Test func rejectedHistoryRecordsOnlyItsDisputes() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let probe = InboxWindowPublicationProbe(), disputed = Data("disputed".utf8)
        let (workspace, chat) = disputedFixture(service, probe: probe)
        defer { workspace.retireWorkspace() }
        // Evidence for one row cannot widen to the other rows of its rejected response.
        service.previewError = ConversationHistoryPage.Failure(identity: identity, unavailableMessageIDs: [disputed],
            sourceIDs: [Data("sibling".utf8)], exceedsRowLimit: true)
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.observed.map(\.unavailable) == [[disputed]], "The notification follows the recorded dispute, and only its row")
        #expect(probe.dirtyCount == 1)
        let retained = workspace.persisted().record(chat)?.transcript
        #expect(retained?.unavailableMessageIDs == [disputed])
        #expect(retained?.messages.map(\.text) == ["Cached answer", "Sibling answer"], "Disputed rows stay in the chat as ambiguous")

        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.publications == 2, "Repeated evidence still reaches a consumer that restarted")
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

    @Test func rejectedHistoryWithoutACachedTranscriptInventsNone() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let probe = InboxWindowPublicationProbe()
        var book = ConversationBook()
        let chat = book.merge(service.summaries[0])
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: { probe.dirtyCount += 1 })
        defer { workspace.retireWorkspace() }
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")])
        workspace.setOnline(true)
        workspace.onAcceptedTranscript = { probe.publications += 1 }
        service.previewError = ConversationHistoryPage.Failure(identity: identity, unavailableMessageIDs: [Data("disputed".utf8)])
        await workspace.refreshInboxHistory(profiles: [service.profile])
        #expect(probe.publications == 1)
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
        case .unknownFailure: ConversationServiceError.incompatible
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
        // Opening the chat may still notify for its accepted transcript; no notification may follow a dispute.
        #expect(probe.observed.allSatisfy { $0.unavailable == nil })
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
