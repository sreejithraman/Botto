import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct BotAvatarPresentationTests {
    final class Clock {
        var date = Date(timeIntervalSince1970: 1_000)
    }

    @Test func startupUsesNeutralFaceUntilActivityIsObserved() throws {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")])
        for scope in [BotAvatarScope.profile, .selectedChat] {
            #expect(workspace.avatarPresentation(profile: service.profile, scope: scope).activity == .idle)
        }
        workspace.setOnline(true)
        for scope in [BotAvatarScope.profile, .selectedChat] {
            #expect(workspace.avatarPresentation(profile: service.profile, scope: scope).activity == .idle)
        }
        #expect(workspace.aggregate(profile: service.profile).activity == .unobserved)
    }

    @Test(arguments: [BotStatus.idle, .working, .waiting])
    func openingKeepsTheTargetChatsObservedActivityAndClock(status: BotStatus) async throws {
        let service = try WorkspaceTestService(), clock = Clock()
        var book = ConversationBook()
        for summary in service.summaries { _ = book.merge(summary) }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, now: { clock.date }, onDirty: {})
        workspace.setOnline(true)
        workspace.applyActivity(profile: service.profile, observations: [
            service.summaries[0].identity: .known(status, clock.date),
            service.summaries[1].identity: .known(.idle, clock.date)
        ])
        let before = workspace.avatarPresentation(profile: service.profile, scope: .selectedChat)
        #expect(before.activity == .observed(status))
        #expect(before.workStartedAt == (status == .working ? clock.date : nil))
        let gate = WorkspaceGate(); service.openGate = gate
        clock.date = clock.date.addingTimeInterval(5)
        let opening = Task { await workspace.openBot(profile: service.profile) }
        await gate.entered()
        #expect(workspace.screen(profile: service.profile)?.isOpening == true)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat) == before)
        workspace.applyActivity(profile: service.profile, observations: [
            service.summaries[0].identity: .known(.waiting, clock.date)
        ])
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .waiting)
        gate.release()
        await opening.value
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .idle)
        #expect(workspace.screen(profile: service.profile)?.canAct == true)
    }

    @Test func restoredActivityStaysHistoricalWithoutSleepingOrReplayingWork() throws {
        let service = try WorkspaceTestService(), clock = Clock()
        var book = ConversationBook()
        let id = book.merge(service.summaries[0])
        let observation = ActivityObservation(status: .working, observedAt: clock.date)
        book.update(id) { $0.lastKnownActivity = observation }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        for online in [false, true] {
            workspace.setOnline(online)
            #expect(workspace.aggregate(profile: service.profile).activity == .historical(observation))
            for scope in [BotAvatarScope.profile, .selectedChat] {
                let presentation = workspace.avatarPresentation(profile: service.profile, scope: scope)
                #expect(presentation.activity == .idle)
                #expect(presentation.workStartedAt == nil)
                #expect(presentation.reactionID == nil)
            }
        }
    }

    @Test func explicitActivityFailureSleepsAndRecoveryClearsIt() throws {
        let service = try WorkspaceTestService(), clock = Clock()
        var book = ConversationBook()
        _ = book.merge(service.summaries[0])
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, now: { clock.date }, onDirty: {})
        workspace.setOnline(true)
        let identity = service.summaries[0].identity
        workspace.applyActivity(profile: service.profile, observations: [identity: .unknown("Activity unavailable")])
        for scope in [BotAvatarScope.profile, .selectedChat] {
            #expect(workspace.avatarPresentation(profile: service.profile, scope: scope).activity == .unavailable)
        }
        workspace.applyActivity(profile: service.profile, observations: [identity: .known(.working, clock.date)])
        for scope in [BotAvatarScope.profile, .selectedChat] {
            #expect(workspace.avatarPresentation(profile: service.profile, scope: scope).activity == .working)
        }
        workspace.setOnline(false)
        workspace.setOnline(true)
        for scope in [BotAvatarScope.profile, .selectedChat] {
            #expect(workspace.avatarPresentation(profile: service.profile, scope: scope).activity == .idle)
        }
    }

    @Test func switchingToAnUnobservedChatDoesNotBorrowSiblingOrHistoricalWork() async throws {
        let service = try WorkspaceTestService(), clock = Clock()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, now: { clock.date }, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let main = service.summaries[0].identity
        service.snapshots[main.root]?.isWorking = true
        workspace.receive(try service.publication(main))
        let owner = try #require(workspace.screen(profile: service.profile)?.owner)
        service.directoryActivity[service.summaries[1].identity] = .known(.working, clock.date)
        await workspace.refreshDirectory(owner)
        service.directoryActivity = [:]
        await workspace.refreshDirectory(owner)
        let sibling = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        let intent = try #require(workspace.captureSelection(sibling, owner: owner))
        let gate = WorkspaceGate(); service.openGate = gate
        let opening = Task { await workspace.select(intent) }
        await gate.entered()
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile).activity == .working)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .idle)
        gate.release()
        await opening.value
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .idle)
    }

    @Test(arguments: [TurnReaction.Kind.succeeded, .failed], [false, true])
    func profileReactionsRequireCurrentIdleAcrossEveryChat(kind: TurnReaction.Kind, historical: Bool) async throws {
        let service = try WorkspaceTestService(), clock = Clock()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, now: { clock.date }, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let owner = try #require(workspace.screen(profile: service.profile)?.owner)
        let main = service.summaries[0].identity, sibling = service.summaries[1].identity
        if historical { service.directoryActivity[sibling] = .known(.working, clock.date) }
        await workspace.refreshDirectory(owner)
        service.directoryActivity = [:]
        await workspace.refreshDirectory(owner)
        let value = try service.publication(main)
        let reaction = TurnReaction(kind: kind, occurredAt: clock.date)
        workspace.receive(.init(identity: main, snapshot: value.snapshot, access: value.access,
            activity: .init(lineage: UUID(), phase: nil, workStartedAt: nil, phaseStartedAt: nil, reaction: reaction)))
        #expect(workspace.aggregate(profile: service.profile).status == nil)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile).activity == .idle)
        let selected = workspace.avatarPresentation(profile: service.profile, scope: .selectedChat)
        #expect(selected.activity == (kind == .succeeded ? .finished : .failed))
        #expect(selected.reactionID == reaction.id)
        workspace.applyActivity(profile: service.profile, observations: [sibling: .known(.idle, clock.date)])
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile) == selected)
    }

    @Test func profileAndChatShareWorkClockAcrossPhaseChanges() async throws {
        let service = try WorkspaceTestService(), clock = Clock()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, now: { clock.date }, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let identity = service.summaries[0].identity
        service.snapshots[identity.root]?.isWorking = true
        let lineage = UUID(), start = clock.date
        var publication = try service.publication(identity)
        workspace.receive(.init(identity: identity, snapshot: publication.snapshot, access: publication.access,
            activity: .init(lineage: lineage, phase: .thinking, workStartedAt: start, phaseStartedAt: start)))
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile).activity == .thinking)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).workStartedAt == start)
        clock.date = start.addingTimeInterval(5)
        publication = try service.publication(identity)
        workspace.receive(.init(identity: identity, snapshot: publication.snapshot, access: publication.access,
            activity: .init(lineage: lineage, phase: .tools, workStartedAt: start, phaseStartedAt: clock.date)))
        let profile = workspace.avatarPresentation(profile: service.profile, scope: .profile)
        #expect(profile == workspace.avatarPresentation(profile: service.profile, scope: .selectedChat))
        #expect(profile.activity == .tools)
        #expect(profile.enteredAt == clock.date)
        #expect(profile.workStartedAt == start)
    }
    @Test func completionKeepsOriginalIdentityAndTimeAcrossGrantRefreshUntilNewWorkOrLineage() async throws {
        let service = try WorkspaceTestService(), clock = Clock()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, now: { clock.date }, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let identity = service.summaries[0].identity, lineage = UUID()
        let reaction = TurnReaction(kind: .succeeded, occurredAt: clock.date)
        func publish(_ facts: ConversationActivity) throws {
            let value = try service.publication(identity)
            workspace.receive(.init(identity: identity, snapshot: value.snapshot, access: value.access, activity: facts))
        }
        try publish(.init(lineage: lineage, phase: nil, workStartedAt: nil, phaseStartedAt: nil, reaction: reaction))
        let completed = workspace.avatarPresentation(profile: service.profile, scope: .selectedChat)
        #expect(completed.activity == .finished)
        #expect(completed.reactionID == reaction.id)
        #expect(completed.enteredAt == reaction.occurredAt)
        workspace.retirePresentation()
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat) == completed)
        clock.date = clock.date.addingTimeInterval(30)
        try publish(.init(lineage: lineage, phase: nil, workStartedAt: nil, phaseStartedAt: nil))
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat) == completed)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile) == completed)
        try publish(.init(lineage: UUID(), phase: nil, workStartedAt: nil, phaseStartedAt: nil))
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .idle)
        let failure = TurnReaction(kind: .failed, occurredAt: clock.date)
        try publish(.init(lineage: lineage, phase: nil, workStartedAt: nil, phaseStartedAt: nil, reaction: failure))
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .failed)
        service.snapshots[identity.root]?.isWorking = true
        try publish(.init(lineage: lineage, phase: .working, workStartedAt: clock.date, phaseStartedAt: clock.date))
        service.snapshots[identity.root]?.isWorking = false
        try publish(.init(lineage: lineage, phase: nil, workStartedAt: nil, phaseStartedAt: nil))
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .idle)
    }

    @Test func siblingAttentionPrecedesProfileWorkWithoutChangingSelectedChatPhase() async throws {
        let service = try WorkspaceTestService(), clock = Clock()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, now: { clock.date }, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let owner = try #require(workspace.screen(profile: service.profile)?.owner)
        await workspace.refreshDirectory(owner)
        let identity = service.summaries[0].identity, sibling = service.summaries[1].identity
        service.snapshots[identity.root]?.isWorking = true
        let publication = try service.publication(identity)
        workspace.receive(.init(identity: identity, snapshot: publication.snapshot, access: publication.access,
            activity: .init(lineage: UUID(), phase: .replying, workStartedAt: clock.date, phaseStartedAt: clock.date)))
        workspace.applyActivity(profile: service.profile, observations: [sibling: .known(.waiting, clock.date)])
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile).activity == .waiting)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .replying)
        service.snapshots[identity.root]?.isWorking = false
        workspace.receive(try service.publication(identity))
        workspace.applyActivity(profile: service.profile, observations: [sibling: .known(.working, clock.date)])
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile).activity == .working)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .idle)
        let work = workspace.avatarPresentation(profile: service.profile, scope: .profile)
        clock.date = clock.date.addingTimeInterval(10)
        workspace.applyActivity(profile: service.profile, observations: [sibling: .known(.working, clock.date)])
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile) == work)
        workspace.applyActivity(profile: service.profile, observations: [sibling: .known(.idle, clock.date.addingTimeInterval(-20))])
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile) == work)
    }

    @Test func selectionAndConnectionRetireReactionsAndForeignProfilesCannotAnimate() async throws {
        let service = try WorkspaceTestService(), clock = Clock()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, now: { clock.date }, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        var screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner)
        let identity = service.summaries[0].identity
        let value = try service.publication(identity)
        let facts = ConversationActivity(lineage: UUID(), phase: nil, workStartedAt: nil, phaseStartedAt: nil,
            reaction: .init(kind: .succeeded, occurredAt: clock.date))
        workspace.receive(.init(identity: identity, snapshot: value.snapshot, access: value.access, activity: facts))
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .finished)
        #expect(workspace.avatarPresentation(profile: try ExactID("foreign"), scope: .selectedChat).activity == .unavailable)
        screen = try #require(workspace.screen(profile: service.profile))
        let sibling = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(sibling, owner: screen.owner)))
        let other = try #require(workspace.screen(profile: service.profile))
        await workspace.select(try #require(workspace.captureSelection(screen.selectedChatID, owner: other.owner)))
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .idle)
        workspace.setOnline(false)
        workspace.receive(.init(identity: identity, snapshot: value.snapshot, access: value.access, activity: facts))
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile).activity == .idle)
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat).activity == .idle)
    }

    @Test func automaticForegroundReadPreservesCompletionElapsedTimeAcrossFreshAccess() async throws {
        let service = try WorkspaceTestService(), clock = Clock(), lineage = UUID()
        let identity = service.summaries[0].identity
        func summary(_ count: Int) -> SessionSummary {
            .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
                  preview: "First prompt", messageCount: count)
        }
        service.summaries[0] = summary(4)
        service.openResult = { value in
            .init(identity: value.identity, snapshot: value.snapshot, access: value.access, readEvidence: value.readEvidence,
                  activity: .init(lineage: lineage, phase: nil, workStartedAt: nil, phaseStartedAt: nil))
        }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, now: { clock.date }, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let initial = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(initial.owner)
        workspace.displayed(initial.owner)
        let publication = try service.publication(identity)
        let reaction = TurnReaction(kind: .succeeded, occurredAt: clock.date)
        workspace.receive(.init(identity: identity, snapshot: publication.snapshot, access: publication.access,
            activity: .init(lineage: lineage, phase: nil, workStartedAt: nil, phaseStartedAt: nil, reaction: reaction)))
        let completed = workspace.avatarPresentation(profile: service.profile, scope: .selectedChat)
        service.summaries[0] = summary(6)
        var screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner)
        screen = try #require(workspace.screen(profile: service.profile))
        clock.date = clock.date.addingTimeInterval(30)
        workspace.setTranscriptVisible(true, owner: screen.owner)
        for _ in 0..<1000 {
            if workspace.screen(profile: service.profile)?.isOpening == false { break }
            await Task.yield()
        }
        #expect(service.opens.count == 2)
        #expect(workspace.screen(profile: service.profile)?.isOpening == false)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .selectedChat) == completed)
        #expect(completed.enteredAt == reaction.occurredAt)
        #expect(completed.reactionID == reaction.id)
    }

}
