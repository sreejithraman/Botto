import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationOperationReservationTests {
    private func fixture() async throws -> (ConversationWorkspace, WorkspaceTestService, ChatScreen) {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 4)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner); workspace.displayed(screen.owner)
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 6)
        await workspace.refreshDirectory(screen.owner)
        return (workspace, service, screen)
    }
    private func idlePublication(_ workspace: ConversationWorkspace, _ service: WorkspaceTestService, working: Bool = false,
                                 requests: [PendingRequest] = []) throws {
        let old = try #require(service.completedOpens.last)
        var snapshot = old.snapshot; snapshot.isWorking = working; snapshot.pendingRequests = requests
        workspace.receive(.init(identity: old.identity, snapshot: snapshot, access: old.access))
    }
    private func settled(_ workspace: ConversationWorkspace, _ service: WorkspaceTestService) async throws -> ChatScreen {
        for _ in 0..<1000 {
            if workspace.screen(profile: service.profile)?.isOpening == false {
                return try #require(workspace.screen(profile: service.profile))
            }
            await Task.yield()
        }
        Issue.record("Foreground read did not settle"); return try #require(workspace.screen(profile: service.profile))
    }

    @Test func discardedImportCaptureCannotLeaveAnImmortalReadBarrier() async throws {
        let (workspace, service, screen) = try await fixture()
        var intent: ImportIntent? = try #require(workspace.captureImport(screen.owner)) as ImportIntent
        workspace.setTranscriptVisible(true, owner: screen.owner)
        #expect(service.opens.count == 1 && intent != nil)
        intent = nil
        for _ in 0..<1000 { if service.opens.count > 1 { break }; await Task.yield() }
        #expect(service.opens.count == 2)
        _ = try await settled(workspace, service)
    }

    @Test func sendCaptureServiceAndSourceResultInstallationDeferReadWithoutPolling() async throws {
        let (workspace, service, screen) = try await fixture()
        workspace.editDraft("send exactly once", owner: screen.owner)
        let intent = try #require(workspace.captureSend(screen.owner))
        let sendGate = WorkspaceGate(), readGate = WorkspaceGate()
        service.sendGate = sendGate; service.openGate = readGate
        workspace.setTranscriptVisible(true, owner: screen.owner)
        #expect(workspace.isCurrent(screen.owner) && service.opens.count == 1)
        let sending = Task { await workspace.send(intent) }
        await sendGate.entered()
        workspace.setTranscriptVisible(true, owner: screen.owner)
        #expect(service.opens.count == 1 && service.sends.count == 1)
        sendGate.release(); await sending.value
        await readGate.entered()
        #expect(workspace.persisted().record(screen.selectedChatID)?.draft.text == "")
        #expect(service.sends.count == 1 && service.opens.count == 2)
        await workspace.send(intent)
        #expect(service.sends.count == 1)
        readGate.release(); _ = try await settled(workspace, service)
    }

    @Test func capturedStopStaysValidWhileItsTurnBecomesIdleAndUntilReceiptReturns() async throws {
        let (workspace, service, screen) = try await fixture()
        try idlePublication(workspace, service, working: true)
        let intent = try #require(workspace.captureStop(screen.owner))
        try idlePublication(workspace, service)
        let stopGate = WorkspaceGate(), readGate = WorkspaceGate()
        service.stopGate = stopGate; service.openGate = readGate
        workspace.setTranscriptVisible(true, owner: screen.owner)
        #expect(service.opens.count == 1)
        let stopping = Task { await workspace.stop(intent) }; await stopGate.entered()
        #expect(service.stops.count == 1 && service.opens.count == 1)
        stopGate.release(); await stopping.value; await readGate.entered()
        #expect(service.opens.count == 2)
        readGate.release(); _ = try await settled(workspace, service)
    }

    @Test func requestRowsDoNotReserveButPendingRequestAndHeldAnswerProtectDeliberateAction() async throws {
        let (workspace, service, screen) = try await fixture()
        let request = PendingRequest(id: "approval", kind: .approval, title: "Approve?")
        try idlePublication(workspace, service, requests: [request])
        let row = try #require(workspace.screen(profile: service.profile)?.requests.first)
        workspace.setTranscriptVisible(true, owner: screen.owner)
        #expect(service.opens.count == 1)
        let answerGate = WorkspaceGate(), readGate = WorkspaceGate()
        service.responseGate = answerGate; service.openGate = readGate
        let answer = Task { await workspace.answer(row.intent, response: .choice("once")) }
        await answerGate.entered()
        try idlePublication(workspace, service)
        workspace.setTranscriptVisible(true, owner: screen.owner)
        #expect(service.opens.count == 1)
        answerGate.release(); await answer.value; await readGate.entered()
        #expect(service.responses == [request] && service.opens.count == 2)
        readGate.release(); _ = try await settled(workspace, service)
    }

    @Test func failedCreateReservationSpansCaptureAndServiceThenReleasesForRead() async throws {
        let (workspace, service, screen) = try await fixture()
        let intent = try #require(workspace.captureCreation(screen.owner))
        let createGate = WorkspaceGate(), readGate = WorkspaceGate()
        service.createGate = createGate; service.createError = HermesServiceError.rejected(-32601); service.openGate = readGate
        workspace.setTranscriptVisible(true, owner: screen.owner)
        #expect(service.opens.count == 1)
        let creation = Task { await workspace.create(intent) }; await createGate.entered()
        #expect(service.opens.count == 1)
        createGate.release(); await creation.value; await readGate.entered()
        #expect(service.creates.count == 1 && service.opens.count == 2)
        readGate.release(); _ = try await settled(workspace, service)
    }

    @Test(arguments: [true, false]) func importPreflightEitherCancelsOrInstallsStagingBeforeRead(_ cancel: Bool) async throws {
        let (workspace, service, screen) = try await fixture()
        let intent = try #require(workspace.captureImport(screen.owner))
        let readGate = WorkspaceGate(); service.openGate = readGate
        workspace.setTranscriptVisible(true, owner: screen.owner)
        #expect(service.opens.count == 1)
        if cancel { workspace.cancelImport(intent) }
        else {
            let uploadGate = WorkspaceGate(); service.uploadGate = uploadGate
            let upload = Task { await workspace.upload(Data([1, 2, 3]), filename: "kept.txt", mimeType: "text/plain", to: intent) }
            await uploadGate.entered()
            workspace.setTranscriptVisible(true, owner: screen.owner)
            #expect(service.opens.count == 1)
            uploadGate.release(); await upload.value
            #expect(workspace.screen(profile: service.profile)?.attachments.map(\.name) == ["kept.txt"])
        }
        await readGate.entered()
        #expect(service.opens.count == 2)
        readGate.release()
        let after = try await settled(workspace, service)
        #expect(!after.needsReattachment && after.attachments.count == (cancel ? 0 : 1))
    }

    @Test func artifactReservationCoversCaptureDownloadAndConsumerInstallation() async throws {
        let (workspace, service, screen) = try await fixture()
        let artifact = try #require(workspace.captureArtifact(.init(name: "report.txt", path: "/report.txt"), owner: screen.owner))
        let downloadGate = WorkspaceGate(), readGate = WorkspaceGate()
        service.downloadGate = downloadGate; service.openGate = readGate
        workspace.setTranscriptVisible(true, owner: screen.owner)
        #expect(service.opens.count == 1)
        let loading = Task { try await workspace.download(artifact) }; await downloadGate.entered()
        #expect(service.opens.count == 1)
        downloadGate.release(); let bytes = try await loading.value
        #expect(service.opens.count == 1, "Service return is not consumer installation")
        let file = try await ArtifactPreviewFile.write(bytes)
        #expect(file.data == Data("artifact".utf8) && service.opens.count == 1)
        workspace.finishArtifact(artifact)
        await readGate.entered()
        #expect(service.opens.count == 2)
        readGate.release(); _ = try await settled(workspace, service)
    }

    @Test(arguments: ["send", "stop", "create", "artifact"])
    func discardedCapturedIntentReleasesItsBarrier(_ kind: String) async throws {
        let (workspace, service, screen) = try await fixture()
        if kind == "stop" { try idlePublication(workspace, service, working: true) }
        workspace.editDraft("queued", owner: screen.owner)
        var keep: Any?
        switch kind {
        case "send": keep = try #require(workspace.captureSend(screen.owner)) as SendIntent
        case "stop": keep = try #require(workspace.captureStop(screen.owner)) as StopIntent; try idlePublication(workspace, service)
        case "create": keep = try #require(workspace.captureCreation(screen.owner)) as CreationIntent
        default: keep = try #require(workspace.captureArtifact(.init(name: "x", path: "/x"), owner: screen.owner)) as ArtifactIntent
        }
        workspace.setTranscriptVisible(true, owner: screen.owner)
        #expect(service.opens.count == 1 && keep != nil)
        keep = nil
        for _ in 0..<1000 { if service.opens.count > 1 { break }; await Task.yield() }
        #expect(service.opens.count == 2)
        _ = try await settled(workspace, service)
        #expect(service.sends.isEmpty && service.stops.isEmpty && service.creates.isEmpty)
    }

    @Test func cancelledQueuedSendReleasesReservationWithoutDispatchingMutation() async throws {
        let (workspace, service, screen) = try await fixture()
        workspace.editDraft("not dispatched", owner: screen.owner)
        let intent = try #require(workspace.captureSend(screen.owner))
        workspace.setTranscriptVisible(true, owner: screen.owner)
        let queued = Task { await workspace.send(intent) }; queued.cancel(); await queued.value
        _ = try await settled(workspace, service)
        #expect(service.sends.isEmpty && service.opens.count == 2)
        #expect(workspace.persisted().record(screen.selectedChatID)?.draft.text == "not dispatched")
    }
    @Test func duplicateQueuedSendCannotReleaseTheOriginalInFlightReservation() async throws {
        let (workspace, service, screen) = try await fixture()
        workspace.editDraft("accepted once", owner: screen.owner)
        let intent = try #require(workspace.captureSend(screen.owner))
        let gate = WorkspaceGate(); service.sendGate = gate
        workspace.setTranscriptVisible(true, owner: screen.owner)
        let first = Task { await workspace.send(intent) }; await gate.entered()
        await workspace.send(intent)
        #expect(workspace.isCurrent(screen.owner), "Rejected duplicate must not release its running original")
        #expect(workspace.screen(profile: service.profile)?.isOpening == false)
        gate.release(); await first.value
        _ = try await settled(workspace, service)
        #expect(service.sends.count == 1 && service.opens.count == 2)
    }

}
