import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationForegroundLifecycleTests {
    private func fixture() async throws -> (AppStore, WorkspaceTestService, ChatScreen, ConnectionConfiguration) {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.snapshots[identity.root]?.messages = [.init(id: "diagram", role: .assistant, text: "```mermaid\ngraph LR\nA --> B\n```\n")]
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 4)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://foreground.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let screen = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(screen.owner); store.chats.displayed(screen.owner)
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 6)
        await store.chats.refreshDirectory(screen.owner)
        return (store, service, screen, configuration)
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

    @Test func everyReadHandoffRetiresArtifactRichRequestAndPickerActionOwners() async throws {
        let (store, service, initial, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats
        let request = PendingRequest(id: "old-request", kind: .approval, title: "Old approval")
        let publication = try #require(service.completedOpens.last)
        var pending = publication.snapshot; pending.pendingRequests = [request]
        workspace.receive(.init(identity: publication.identity, snapshot: pending, access: publication.access))
        let row = try #require(workspace.screen(profile: service.profile)?.requests.first)
        workspace.receive(publication)
        let oldSelection = try #require(workspace.captureSelection(initial.selectedChatID, owner: initial.owner))
        let destination = try #require(store.artifactDestination(for: .init(name: "old.txt", path: "/old.txt"), botID: service.profile.text))
        store.finishArtifact(destination) // Consumer has installed its result; keep the old callback for rejection.
        let message = try #require(initial.snapshot?.messages.first)
        let block = try #require(ReplyContent(message: message).blocks.first)
        let context = store.richReplyContext(for: service.profile.text, messageID: "diagram")
        #expect(context.permits(block))
        var revocations = 0
        let ticket = try #require(context.begin(block, layout: nil, onRevoke: { revocations += 1 }).ticket)
        let firstGeneration = store.artifactGeneration
        let gate = WorkspaceGate(); service.openGate = gate
        workspace.setTranscriptVisible(true, owner: initial.owner)
        let reading = try #require(workspace.screen(profile: service.profile))
        #expect(store.artifactGeneration != firstGeneration)
        #expect(store.openingID == service.profile.text && reading.isOpening)
        #expect(!context.permits(block) && !ticket.isCurrent && revocations == 1)
        #expect(!store.richReplyContext(for: service.profile.text, messageID: "diagram").permits(block))
        #expect(!store.isCurrentArtifactDestination(destination))
        #expect(workspace.captureSend(reading.owner) == nil && workspace.captureImport(reading.owner) == nil)
        #expect(workspace.captureArtifact(.init(name: "new", path: "/new"), owner: reading.owner) == nil)
        await gate.entered()
        await workspace.answer(row.intent, response: .choice("once"))
        await workspace.select(oldSelection)
        #expect(service.responses.isEmpty && service.opens.count == 2)
        let intermediateGeneration = store.artifactGeneration
        gate.release()
        let installed = try await settled(workspace, service)
        #expect(store.artifactGeneration != intermediateGeneration)
        #expect(installed.selectedViewLifetime == initial.selectedViewLifetime && installed.epoch != reading.epoch)
        #expect(store.openingID == nil && installed.canAct)
        #expect(ticket.finishCapture(nil, height: 200) == nil)
        #expect(!context.permits(block))
        #expect(store.richReplyContext(for: service.profile.text, messageID: "diagram").permits(block))
        await #expect(throws: HermesServiceError.staleConversation) { try await store.downloadArtifact(destination) }
        workspace.setTranscriptVisible(true, owner: installed.owner)
        #expect(workspace.persisted().record(initial.selectedChatID)?.isUnread == false)
    }

    @Test(arguments: ["failure", "profile", "root", "tip", "snapshot", "snapshot-stored"])
    func failedOrWrongResultKeepsInertTranscriptEditableDraftAndRejectsLateGrants(_ failure: String) async throws {
        let (store, service, initial, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats
        workspace.editDraft("kept failure draft", owner: initial.owner)
        if failure == "failure" { service.openError = HermesServiceError.timeout }
        else {
            service.openResult = { result in
                var snapshot = result.snapshot
                if failure == "snapshot" { snapshot.profileID = "foreign" }
                if failure == "snapshot-stored" { snapshot.storedID = "foreign-tip" }
                let identity = SessionIdentity(profile: failure == "profile" ? try! ExactID("foreign") : result.identity.profile,
                    root: failure == "root" ? try! ExactID("foreign-root") : result.identity.root,
                    stored: failure == "tip" ? try! ExactID("foreign-tip") : result.identity.stored, aliases: [])
                return .init(identity: identity, snapshot: snapshot, access: result.access, readEvidence: result.readEvidence)
            }
        }
        let firstGeneration = store.artifactGeneration
        workspace.setTranscriptVisible(true, owner: initial.owner)
        let failed = try await settled(workspace, service)
        #expect(!failed.canAct && failed.canEditDraft && failed.error != nil)
        #expect(failed.snapshot == initial.snapshot && failed.snapshot?.pendingRequests.isEmpty == true)
        #expect(workspace.persisted().record(initial.selectedChatID)?.transcript == initial.snapshot)
        #expect(store.artifactGeneration != firstGeneration && service.opens.count == 2)
        #expect(workspace.captureCreation(failed.owner) == nil && workspace.captureSend(failed.owner) == nil)
        workspace.editDraft("still editable", owner: failed.owner)
        workspace.receive(try service.fullReadPublication(service.summaries[0].identity))
        #expect(workspace.screen(profile: service.profile)?.canAct == false, "A late callback cannot restore the retired read")
        for _ in 0..<3 {
            await workspace.refreshDirectory(failed.owner); workspace.setTranscriptVisible(true, owner: failed.owner)
        }
        #expect(service.opens.count == 2)
        service.openError = nil; service.openResult = nil
        await workspace.openBot(profile: service.profile)
        let explicit = try #require(workspace.screen(profile: service.profile))
        #expect(explicit.canAct && workspace.draft(explicit.owner) == "still editable")
        workspace.setTranscriptVisible(true, owner: explicit.owner)
        #expect(explicit.selectedChatID == initial.selectedChatID)
        #expect(workspace.persisted().record(initial.selectedChatID)?.isUnread == false)
    }

    @Test(arguments: ["selection", "background", "review", "connection", "workspace", "presentation"])
    func retiredReadCannotInstallOrAcknowledgeItsLateResultAndCallback(_ retirement: String) async throws {
        let (store, service, initial, configuration) = try await fixture()
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement-foreground.invalid")!)
        defer { LocalHistory.remove(for: configuration.id); LocalHistory.remove(for: replacement.id) }
        let workspace = store.chats
        workspace.editDraft("retained", owner: initial.owner)
        let gate = WorkspaceGate(); service.openGate = gate
        workspace.setTranscriptVisible(true, owner: initial.owner); await gate.entered()
        let readOwner = try #require(workspace.screen(profile: service.profile)?.owner)
        service.openGate = nil
        switch retirement {
        case "selection":
            let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
            await workspace.select(try #require(workspace.captureSelection(other, owner: readOwner)))
        case "background": await store.setActive(false)
        case "review": store.showsConnection = true
        case "connection": workspace.retireConnection()
        case "workspace": #expect(await store.connect(replacement))
        default: workspace.retirePresentation()
        }
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.selectedViewLifetime != initial.selectedViewLifetime)
        gate.release()
        for _ in 0..<1000 { if service.completedOpens.count >= (retirement == "selection" ? 3 : 2) { break }; await Task.yield() }
        let late = try #require(service.completedOpens.last)
        workspace.receive(late); workspace.displayed(readOwner)
        let current = try #require(workspace.screen(profile: service.profile))
        #expect(current.epoch == after.epoch && current.selectedChatID == after.selectedChatID)
        #expect(workspace.persisted().record(initial.selectedChatID)?.seen?.summary?.messageCount == 4)
        #expect(workspace.persisted().record(initial.selectedChatID)?.draft.text == "retained")
        #expect(workspace !== store.chats || retirement != "workspace")
        #expect(service.sends.isEmpty && service.responses.isEmpty)
        if retirement != "selection" { #expect(!current.canAct) }
    }

    @Test func oldReadCleanupCannotClearNewerReadOrInstallItsLatePublication() async throws {
        let (store, service, initial, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats, firstGate = WorkspaceGate()
        service.openGate = firstGate
        workspace.setTranscriptVisible(true, owner: initial.owner); await firstGate.entered()
        workspace.retirePresentation()
        service.openGate = nil; service.readSummaryAvailable = false
        await workspace.openBot(profile: service.profile)
        let reopened = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(reopened.owner)
        let secondGate = WorkspaceGate(); service.openGate = secondGate
        workspace.setTranscriptVisible(true, owner: reopened.owner); await secondGate.entered()
        let second = try #require(workspace.screen(profile: service.profile))
        firstGate.release()
        for _ in 0..<1000 { if service.completedOpens.count == 3 { break }; await Task.yield() }
        workspace.receive(try #require(service.completedOpens.last))
        #expect(workspace.screen(profile: service.profile)?.isOpening == true)
        #expect(workspace.screen(profile: service.profile)?.epoch == second.epoch)
        secondGate.release()
        let done = try await settled(workspace, service)
        let doneCards = workspace.cards(profile: service.profile)
        #expect(done.canAct && doneCards.first?.unread == true)
        #expect(service.opens.count == 4)
    }
    @Test func cancelledReadCallbackBeforeItsReturnCannotReplaceExplicitNewAttachment() async throws {
        let (store, service, initial, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats, gate = WorkspaceGate()
        service.openGate = gate
        workspace.setTranscriptVisible(true, owner: initial.owner); await gate.entered()
        workspace.retirePresentation()
        service.openGate = nil
        await workspace.openBot(profile: service.profile)
        let explicit = try #require(workspace.screen(profile: service.profile))
        service.beforeOpenReturn = { [weak service] publication in service?.onEvent?(.conversation(publication)) }
        gate.release()
        for _ in 0..<1000 { if service.completedOpens.count == 3 { break }; await Task.yield() }
        #expect(service.completedOpens.count == 3)
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.owner == explicit.owner && after.canAct,
            "An ignored-cancellation callback may precede the canceled open's return")
        workspace.receive(try #require(service.completedOpens.last))
        #expect(workspace.screen(profile: service.profile)?.owner == explicit.owner)
    }

    @Test func genuineConnectionRecoveryRestoresAuthorityAfterFailedOptionalRead() async throws {
        let (store, service, initial, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats
        service.openError = HermesServiceError.timeout
        workspace.setTranscriptVisible(true, owner: initial.owner)
        _ = try await settled(workspace, service)
        #expect(workspace.screen(profile: service.profile)?.canAct == false)
        service.onEvent?(.disconnected("New connection recovery"))
        let recovered = try service.fullReadPublication(service.summaries[0].identity)
        service.onEvent?(.conversation(recovered))
        #expect(workspace.screen(profile: service.profile)?.canAct == false)
        service.onEvent?(.connected(.init(version: "recovered")))
        let current = try #require(workspace.screen(profile: service.profile))
        #expect(current.canAct && current.selectedChatID == initial.selectedChatID)
        #expect(workspace.persisted().record(initial.selectedChatID)?.seen?.summary?.messageCount == 4)
        workspace.setTranscriptVisible(true, owner: current.owner)
        #expect(workspace.persisted().record(initial.selectedChatID)?.seen?.summary?.messageCount == 6)
        #expect(service.opens.count == 2, "Recovery did not retry the optional key")
    }

}
