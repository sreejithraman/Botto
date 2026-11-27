import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationOperationReservationTests {
    private func fixture() async throws -> (ConversationWorkspace, WorkspaceTestService, ChatScreen) {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.setTranscriptVisible(true, owner: screen.owner)
        return (workspace, service, screen)
    }
    private func idlePublication(_ workspace: ConversationWorkspace, _ service: WorkspaceTestService, working: Bool = false,
                                 requests: [PendingRequest] = []) throws {
        let old = try #require(service.completedOpens.last)
        var snapshot = old.snapshot; snapshot.isWorking = working; snapshot.pendingRequests = requests
        workspace.receive(.init(identity: old.identity, snapshot: snapshot, access: old.access))
    }

    @Test func capturedSendIsDispatchedOnceAndClearsItsDraft() async throws {
        let (workspace, service, screen) = try await fixture()
        workspace.editDraft("send exactly once", owner: screen.owner)
        let intent = try #require(workspace.captureSend(screen.owner))
        let sendGate = WorkspaceGate(); service.sendGate = sendGate
        let sending = Task { await workspace.send(intent) }
        await sendGate.entered()
        #expect(service.sends.count == 1)
        sendGate.release(); await sending.value
        #expect(workspace.persisted().record(screen.selectedChatID)?.draft.text == "")
        await workspace.send(intent)
        #expect(service.sends.count == 1 && service.opens.count == 1)
    }

    @Test func capturedStopStaysValidWhileItsTurnBecomesIdleAndUntilReceiptReturns() async throws {
        let (workspace, service, screen) = try await fixture()
        try idlePublication(workspace, service, working: true)
        let intent = try #require(workspace.captureStop(screen.owner))
        try idlePublication(workspace, service)
        let stopGate = WorkspaceGate(); service.stopGate = stopGate
        let stopping = Task { await workspace.stop(intent) }; await stopGate.entered()
        #expect(service.stops.count == 1)
        stopGate.release(); await stopping.value
        #expect(service.stops.count == 1 && service.opens.count == 1)
    }

    @Test func heldAnswerIsDeliveredOnceAfterItsRequestLeavesTheSnapshot() async throws {
        let (workspace, service, _) = try await fixture()
        let request = PendingRequest(id: "approval", kind: .approval, title: "Approve?")
        try idlePublication(workspace, service, requests: [request])
        let row = try #require(workspace.screen(profile: service.profile)?.requests.first)
        let answerGate = WorkspaceGate(); service.responseGate = answerGate
        let answer = Task { await workspace.answer(row.intent, response: .choice("once")) }
        await answerGate.entered()
        try idlePublication(workspace, service)
        answerGate.release(); await answer.value
        #expect(service.responses == [request] && service.opens.count == 1)
    }

    @Test(arguments: [true, false]) func importPreflightEitherCancelsOrInstallsStaging(_ cancel: Bool) async throws {
        let (workspace, service, screen) = try await fixture()
        let intent = try #require(workspace.captureImport(screen.owner))
        if cancel { workspace.cancelImport(intent) }
        else {
            let uploadGate = WorkspaceGate(); service.uploadGate = uploadGate
            let upload = Task { await workspace.upload(Data([1, 2, 3]), filename: "kept.txt", mimeType: "text/plain", to: intent) }
            await uploadGate.entered()
            uploadGate.release(); await upload.value
        }
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(!after.needsReattachment && after.attachments.map(\.name) == (cancel ? [] : ["kept.txt"]))
    }

    @Test(arguments: ["send", "stop"])
    func discardedCapturedIntentReleasesItsSlot(_ kind: String) async throws {
        let (workspace, service, screen) = try await fixture()
        if kind == "stop" { try idlePublication(workspace, service, working: true) }
        workspace.editDraft("queued", owner: screen.owner)
        var keep: Any?
        func capture() -> Any? {
            kind == "send" ? workspace.captureSend(screen.owner) as Any? : workspace.captureStop(screen.owner) as Any?
        }
        keep = try #require(capture())
        #expect(capture() == nil, "A held capture owns its chat's slot")
        keep = nil
        var next: Any?
        await waitWhile { next = capture(); return next == nil }
        #expect(next != nil && keep == nil, "Discarding the held capture frees the slot")
        #expect(service.sends.isEmpty && service.stops.isEmpty && service.creates.isEmpty)
    }

    @Test func cancelledQueuedSendReleasesReservationWithoutDispatchingMutation() async throws {
        let (workspace, service, screen) = try await fixture()
        workspace.editDraft("not dispatched", owner: screen.owner)
        let intent = try #require(workspace.captureSend(screen.owner))
        let queued = Task { await workspace.send(intent) }; queued.cancel(); await queued.value
        #expect(service.sends.isEmpty)
        #expect(workspace.persisted().record(screen.selectedChatID)?.draft.text == "not dispatched")
        #expect(workspace.captureSend(screen.owner) != nil)
    }
    @Test func duplicateQueuedSendCannotReleaseTheOriginalInFlightReservation() async throws {
        let (workspace, service, screen) = try await fixture()
        workspace.editDraft("accepted once", owner: screen.owner)
        let intent = try #require(workspace.captureSend(screen.owner))
        let gate = WorkspaceGate(); service.sendGate = gate
        let first = Task { await workspace.send(intent) }; await gate.entered()
        await workspace.send(intent)
        workspace.editDraft("second", owner: screen.owner)
        #expect(workspace.captureSend(screen.owner) == nil, "Rejected duplicate must not release its running original")
        gate.release(); await first.value
        #expect(service.sends.count == 1)
    }
}
