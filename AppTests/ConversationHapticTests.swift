import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationHapticTests {
    @MainActor private final class FeedbackLog { var events: [ChatHapticFeedback] = [] }

    @MainActor private struct Fixture {
        let feedback: FeedbackLog
        let workspace: ConversationWorkspace
        let service: WorkspaceTestService
        let lineage: UUID
        var identity: SessionIdentity { service.summaries[0].identity }

        func publish(phase: ConversationWorkPhase? = nil, reaction: TurnReaction? = nil,
                     signal: ConversationActivity.Signal? = nil) throws {
            let value = try service.publication(identity)
            workspace.receive(.init(identity: value.identity, snapshot: value.snapshot, access: value.access,
                activity: .init(lineage: lineage, phase: phase, workStartedAt: nil,
                                phaseStartedAt: nil, reaction: reaction, signal: signal)))
        }

        func screen() throws -> ChatScreen {
            try #require(workspace.screen(profile: service.profile))
        }
    }

    private func fixture(requests: [PendingRequest] = []) async throws -> Fixture {
        let service = try WorkspaceTestService(), lineage = UUID()
        service.snapshots[service.summaries[0].identity.root]?.pendingRequests = requests
        service.openResult = { value in
            .init(identity: value.identity, snapshot: value.snapshot, access: value.access,
                  readEvidence: value.readEvidence,
                  activity: .init(lineage: lineage, phase: nil, workStartedAt: nil, phaseStartedAt: nil))
        }
        var book = ConversationBook()
        for summary in service.summaries { _ = book.merge(summary) }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let feedback = FeedbackLog()
        workspace.onHapticFeedback = { feedback.events.append($0) }
        let result = Fixture(feedback: feedback, workspace: workspace, service: service, lineage: lineage)
        workspace.setTranscriptVisible(true, owner: try result.screen().owner)
        return result
    }

    @Test func acceptedSendWaitsForItsReceiptAndRepeatedSendsHaveDistinctFeedback() async throws {
        let f = try await fixture(), gate = WorkspaceGate()
        let screen = try f.screen()
        f.workspace.editDraft("First", owner: screen.owner)
        let intent = try #require(f.workspace.captureSend(screen.owner))
        f.service.sendGate = gate
        let sending = Task { await f.workspace.send(intent) }
        await gate.entered()
        #expect(f.feedback.events.last == nil)
        gate.release()
        await sending.value
        let first = try #require(f.feedback.events.last)
        #expect(first.event == .accepted && first.chat == screen.selectedChatID)
        #expect(first.viewLifetime == screen.selectedViewLifetime)
        let next = try f.screen()
        f.service.sendGate = nil
        f.workspace.editDraft("Second", owner: next.owner)
        await f.workspace.send(try #require(f.workspace.captureSend(next.owner)))
        let second = try #require(f.feedback.events.last)
        #expect(second.event == .accepted && second.id != first.id)
        #expect(f.service.sends.map(\.0) == ["First", "Second"])
    }

    @Test func hiddenSendReceiptDoesNotPlayWhenTheChatReturns() async throws {
        let f = try await fixture(), gate = WorkspaceGate()
        let screen = try f.screen()
        f.workspace.editDraft("Accepted while covered", owner: screen.owner)
        let intent = try #require(f.workspace.captureSend(screen.owner))
        f.service.sendGate = gate
        let sending = Task { await f.workspace.send(intent) }
        await gate.entered()
        f.workspace.setTranscriptVisible(false, owner: screen.owner)
        gate.release()
        await sending.value
        #expect(f.feedback.events.last == nil)
        f.workspace.setTranscriptVisible(true, owner: try f.screen().owner)
        #expect(f.feedback.events.last == nil)
        #expect(f.service.sends.count == 1)
    }

    @Test func uncertainSendWarnsWithoutClaimingAcceptanceOrDefiniteFailure() async throws {
        let f = try await fixture(), screen = try f.screen()
        f.workspace.editDraft("Keep until reconciled", owner: screen.owner)
        f.service.sendError = HermesServiceError.uncertain
        await f.workspace.send(try #require(f.workspace.captureSend(screen.owner)))
        #expect(f.feedback.events.last?.event == .warning)
        #expect(f.workspace.draft(try f.screen().owner) == "Keep until reconciled")
    }

    @Test(arguments: [false, true])
    func lateSendReceiptCannotBorrowAnotherChatOrConnection(retireConnection: Bool) async throws {
        let f = try await fixture(), gate = WorkspaceGate()
        let screen = try f.screen()
        f.workspace.editDraft("Old reader", owner: screen.owner)
        let intent = try #require(f.workspace.captureSend(screen.owner))
        f.service.sendGate = gate
        let sending = Task { await f.workspace.send(intent) }
        await gate.entered()
        if retireConnection {
            f.workspace.retireConnection()
        } else {
            let other = try #require(f.workspace.cards(profile: f.service.profile).first { !$0.isMain }?.id)
            await f.workspace.select(try #require(f.workspace.captureSelection(other, owner: screen.owner)))
            f.workspace.setTranscriptVisible(true, owner: try f.screen().owner)
        }
        gate.release()
        await sending.value
        #expect(f.feedback.events.last == nil)
    }

    @Test func accessRefreshDuringSendDoesNotSuppressTheCurrentReadersReceipt() async throws {
        let f = try await fixture(), gate = WorkspaceGate()
        let screen = try f.screen()
        f.workspace.editDraft("Same visible reader", owner: screen.owner)
        let intent = try #require(f.workspace.captureSend(screen.owner))
        f.service.sendGate = gate
        let sending = Task { await f.workspace.send(intent) }
        await gate.entered()
        try f.publish()
        let refreshed = try f.screen()
        #expect(refreshed.owner != screen.owner)
        #expect(refreshed.selectedViewLifetime == screen.selectedViewLifetime)
        gate.release()
        await sending.value
        #expect(f.feedback.events.last?.event == .accepted)
        #expect(f.feedback.events.last?.viewLifetime == screen.selectedViewLifetime)
    }

    @Test(arguments: [TurnReaction.Kind.succeeded, .failed])
    func aLiveTurnOutcomeIsConsumedOnceAcrossRefreshAndCoverage(_ kind: TurnReaction.Kind) async throws {
        let f = try await fixture()
        let reaction = TurnReaction(kind: kind, occurredAt: .now)
        try f.publish(reaction: reaction)
        let first = try #require(f.feedback.events.last)
        #expect(first.event == (kind == .succeeded ? .replyFinished : .error))
        #expect(first.event != .celebration)
        try f.publish(reaction: reaction)
        #expect(f.feedback.events.last?.id == first.id)
        f.workspace.setTranscriptVisible(false, owner: try f.screen().owner)
        try f.publish(reaction: reaction)
        f.workspace.setTranscriptVisible(true, owner: try f.screen().owner)
        try f.publish(reaction: reaction)
        #expect(f.feedback.events.last?.id == first.id)
    }

    @Test func anOutcomeObservedWhileHiddenIsNotReplayedOnReturn() async throws {
        let f = try await fixture()
        f.workspace.setTranscriptVisible(false, owner: try f.screen().owner)
        let reaction = TurnReaction(kind: .succeeded, occurredAt: .now)
        try f.publish(reaction: reaction)
        #expect(f.feedback.events.last == nil)
        f.workspace.setTranscriptVisible(true, owner: try f.screen().owner)
        try f.publish(reaction: reaction)
        #expect(f.feedback.events.last == nil)
    }

    @Test func restoredRequestsStayQuietAndANewLiveRequestKnocksOnlyOnce() async throws {
        let restored = PendingRequest(id: "restored", kind: .question, title: "Already waiting")
        let f = try await fixture(requests: [restored])
        #expect(f.feedback.events.last == nil)
        try f.publish()
        #expect(f.feedback.events.last == nil)
        let fresh = PendingRequest(id: "fresh", kind: .question, title: "New question")
        f.service.snapshots[f.identity.root]?.pendingRequests.append(fresh)
        let signal = ConversationActivity.Signal(kind: .request)
        try f.publish(signal: signal)
        let first = try #require(f.feedback.events.last)
        #expect(first.event == .attention)
        try f.publish(signal: signal)
        #expect(f.feedback.events.last?.id == first.id)
    }

    @Test(arguments: [false, true])
    func stopRequiresBothAcknowledgmentAndAStoppedSignal(signalFirst: Bool) async throws {
        let f = try await fixture(), gate = WorkspaceGate()
        f.service.snapshots[f.identity.root]?.isWorking = true
        try f.publish(phase: .working)
        let intent = try #require(f.workspace.captureStop(try f.screen().owner))
        f.service.stopGate = gate
        let stopping = Task { await f.workspace.stop(intent) }
        await gate.entered()
        if signalFirst {
            f.service.snapshots[f.identity.root]?.isWorking = false
            try f.publish(signal: .init(kind: .stopped))
            #expect(f.feedback.events.last == nil)
        }
        gate.release()
        await stopping.value
        if !signalFirst {
            #expect(f.feedback.events.last == nil)
            f.service.snapshots[f.identity.root]?.isWorking = false
            try f.publish()
            #expect(f.feedback.events.last == nil, "Idle alone cannot confirm cancellation")
            try f.publish(signal: .init(kind: .stopped))
        }
        let feedback = try #require(f.feedback.events.last)
        #expect(feedback.event == .stopped)
        #expect(f.service.stops.count == 1)
    }

    @Test func stoppedWhileCoveredCannotReplayAfterTheDelayedReceipt() async throws {
        let f = try await fixture(), gate = WorkspaceGate()
        f.service.snapshots[f.identity.root]?.isWorking = true
        try f.publish(phase: .working)
        let owner = try f.screen().owner
        let intent = try #require(f.workspace.captureStop(owner))
        f.service.stopGate = gate
        let stopping = Task { await f.workspace.stop(intent) }
        await gate.entered()
        f.workspace.setTranscriptVisible(false, owner: owner)
        f.service.snapshots[f.identity.root]?.isWorking = false
        try f.publish(signal: .init(kind: .stopped))
        f.workspace.setTranscriptVisible(true, owner: try f.screen().owner)
        gate.release()
        await stopping.value
        #expect(f.feedback.events.last == nil)
    }

    @Test(arguments: [false, true])
    func warningReachesPlaybackBeforeAnImmediatelyFollowingStreamingUpdate(streaming: Bool) async throws {
        let f = try await fixture(), screen = try f.screen()
        var played: [HapticPlayback] = []
        let haptics = BottoHaptics(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            output: .init(play: { played.append($0) }, cancel: {}),
            now: { 10 }, isActive: { true })
        haptics.streamingEnabled = streaming
        f.workspace.onHapticFeedback = { haptics.play($0.event) }
        f.workspace.editDraft("Uncertain", owner: screen.owner)
        f.service.sendError = HermesServiceError.uncertain
        await f.workspace.send(try #require(f.workspace.captureSend(screen.owner)))
        try f.publish(phase: .replying, signal: .init(kind: .replyText))
        #expect(played == [.notification(.warning)])
    }
}
