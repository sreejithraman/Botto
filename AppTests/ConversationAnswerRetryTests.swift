import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationAnswerRetryTests {
    private func fixture() async throws -> (ConversationWorkspace, WorkspaceTestService, RequestRow) {
        let service = try WorkspaceTestService()
        service.snapshots[service.summaries[0].identity.root]?.pendingRequests = [
            .init(id: "question", kind: .question, title: "Choose a scope")]
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        return (workspace, service, try #require(workspace.screen(profile: service.profile)?.requests.first))
    }

    @Test func initialOpenPreservesDraftIdentityRevisionAndExactBytesWhileRetiringOldCallbacks() async throws {
        let service = try WorkspaceTestService()
        let gate = WorkspaceGate()
        service.openGate = gate
        var book = ConversationBook()
        let otherProfile = try ExactID("other-bot")
        let otherID = book.ensureProfile(otherProfile)
        book.update(otherID) { $0.draft.text = "Unrelated draft" }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        workspace.setOnline(true)
        let opening = Task { await workspace.openBot(profile: service.profile) }
        defer { gate.release() }
        await gate.entered()
        let held = try #require(workspace.screen(profile: service.profile))
        #expect(held.isOpening && held.canEditDraft && !held.canAct)
        let initialRevision = try #require(workspace.persisted().record(held.selectedChatID)?.draft.revision)
        let text = " \tA thought e\u{301} 👩🏽‍💻\r\n  "
        workspace.editDraft(text, owner: held.owner)
        let revision = try #require(workspace.persisted().record(held.selectedChatID)?.draft.revision)
        #expect(revision != initialRevision)
        #expect(Data(workspace.draft(held.owner).utf8) == Data(text.utf8))
        #expect(workspace.captureSend(held.owner) == nil)
        #expect(workspace.captureCreation(held.owner) == nil)
        #expect(workspace.captureImport(held.owner) == nil)

        gate.release()
        await opening.value
        let opened = try #require(workspace.screen(profile: service.profile))
        #expect(!opened.isOpening && opened.canEditDraft && opened.canAct)
        #expect(opened.selectedChatID == held.selectedChatID)
        #expect(workspace.persisted().preference(service.profile)?.main == held.selectedChatID)
        #expect(workspace.persisted().record(opened.selectedChatID)?.isUnverified == false)
        let identity = try #require(workspace.persisted().record(opened.selectedChatID)?.binding.identity)
        #expect(identity.profile == service.profile)
        #expect(identity.root == service.summaries[0].identity.root)
        #expect(identity.stored == service.summaries[0].identity.stored)
        #expect(Data(workspace.draft(opened.owner).utf8) == Data(text.utf8))
        #expect(workspace.persisted().record(opened.selectedChatID)?.draft.revision == revision)
        #expect(!workspace.isCurrent(held.owner))
        workspace.editDraft("", owner: held.owner)
        workspace.editDraft("Late composer callback", owner: held.owner)
        #expect(workspace.captureSend(held.owner) == nil)
        #expect(Data(workspace.draft(opened.owner).utf8) == Data(text.utf8))
        #expect(workspace.persisted().record(opened.selectedChatID)?.draft.revision == revision)
        #expect(workspace.persisted().records.count == 2)
        #expect(workspace.persisted().record(otherID)?.draft.text == "Unrelated draft")
        #expect(service.opens.count == 1)
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.uploads.isEmpty)
        #expect(service.stops.isEmpty && service.responseOperations.isEmpty)
    }

    @Test(arguments: ["new", "existing", "observed"])
    func offlineInitialDraftKeepsIdentityWhenFirstLiveOpenSucceeds(origin: String) async throws {
        let service = try WorkspaceTestService()
        var book = ConversationBook()
        if origin == "existing" { book.ensureProfile(service.profile) }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        if origin == "observed" { workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")]) }
        await workspace.openBot(profile: service.profile)
        let offline = try #require(workspace.screen(profile: service.profile))
        #expect(offline.canEditDraft && !offline.canAct && service.opens.isEmpty)
        let text = " \tOffline e\u{301} 👩🏽‍💻\r\n  "
        workspace.editDraft(text, owner: offline.owner)
        let revision = try #require(workspace.persisted().record(offline.selectedChatID)?.draft.revision)
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let opened = try #require(workspace.screen(profile: service.profile))
        #expect(opened.selectedChatID == offline.selectedChatID && opened.canAct)
        #expect(workspace.persisted().preference(service.profile)?.main == offline.selectedChatID)
        #expect(workspace.persisted().records.count == 1)
        #expect(workspace.persisted().record(offline.selectedChatID)?.isUnverified == false)
        #expect(workspace.persisted().record(opened.selectedChatID)?.draft.revision == revision)
        #expect(Data(workspace.draft(opened.owner).utf8) == Data(text.utf8))
        workspace.editDraft("Retired offline callback", owner: offline.owner)
        #expect(Data(workspace.draft(opened.owner).utf8) == Data(text.utf8))
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.uploads.isEmpty)
    }

    @Test func retiredInitialOpenCannotBindLateAndFreshRetryKeepsLocalDraft() async throws {
        let service = try WorkspaceTestService()
        let oldGate = WorkspaceGate(), retryGate = WorkspaceGate()
        service.openGate = oldGate
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        let oldOpening = Task { await workspace.openBot(profile: service.profile) }
        defer { oldGate.release(); retryGate.release() }
        await oldGate.entered()
        let held = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Typed during initial open", owner: held.owner)
        workspace.retireConnection()
        let offline = try #require(workspace.screen(profile: service.profile))
        let text = " \tKept after disconnect e\u{301}\r\n "
        workspace.editDraft(text, owner: offline.owner)
        let revision = try #require(workspace.persisted().record(held.selectedChatID)?.draft.revision)
        service.openGate = retryGate
        workspace.setOnline(true)
        let retry = Task { await workspace.openBot(profile: service.profile) }
        await retryGate.entered()
        let retrying = try #require(workspace.screen(profile: service.profile))
        oldGate.release()
        await oldOpening.value
        let afterLateCompletion = try #require(workspace.screen(profile: service.profile))
        #expect(afterLateCompletion.owner == retrying.owner && afterLateCompletion.isOpening)
        #expect(!afterLateCompletion.canAct && afterLateCompletion.snapshot == nil)
        #expect(workspace.persisted().record(held.selectedChatID)?.binding.identity == nil)
        #expect(workspace.captureSend(held.owner) == nil && workspace.captureSend(offline.owner) == nil)
        #expect(workspace.captureSend(retrying.owner) == nil)
        workspace.editDraft("Late initial callback", owner: held.owner)
        workspace.editDraft("Late offline callback", owner: offline.owner)
        #expect(Data(workspace.draft(retrying.owner).utf8) == Data(text.utf8))

        retryGate.release()
        await retry.value
        let opened = try #require(workspace.screen(profile: service.profile))
        #expect(opened.canAct && opened.selectedChatID == held.selectedChatID)
        #expect(workspace.persisted().records.count == 1)
        #expect(workspace.persisted().record(opened.selectedChatID)?.draft.revision == revision)
        #expect(Data(workspace.draft(opened.owner).utf8) == Data(text.utf8))
        #expect(!workspace.isCurrent(retrying.owner) && !workspace.isCurrent(held.owner))
        #expect(service.opens.count == 2 && service.completedOpens.count == 2)
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.uploads.isEmpty)
    }

    @Test func failedInitialOpenKeepsLocalDraftForExplicitRetry() async throws {
        let service = try WorkspaceTestService()
        let gate = WorkspaceGate()
        service.openGate = gate
        service.openError = HermesServiceError.timeout
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        let opening = Task { await workspace.openBot(profile: service.profile) }
        defer { gate.release() }
        await gate.entered()
        let held = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Keep after failed first open", owner: held.owner)
        let revision = try #require(workspace.persisted().record(held.selectedChatID)?.draft.revision)
        gate.release()
        await opening.value
        let failed = try #require(workspace.screen(profile: service.profile))
        #expect(!failed.canAct && !failed.canEditDraft && failed.error != nil)
        service.openGate = nil; service.openError = nil
        await workspace.openBot(profile: service.profile)
        let opened = try #require(workspace.screen(profile: service.profile))
        #expect(opened.canAct && opened.selectedChatID == held.selectedChatID && opened.error == nil)
        #expect(workspace.draft(opened.owner) == "Keep after failed first open")
        #expect(workspace.persisted().record(opened.selectedChatID)?.draft.revision == revision)
        #expect(workspace.persisted().records.count == 1)
    }

    @Test func canonicalDirectoryDuringInitialOpenKeepsDraftWithoutGrantingActions() async throws {
        let service = try WorkspaceTestService()
        let gate = WorkspaceGate()
        service.openGate = gate
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        let opening = Task { await workspace.openBot(profile: service.profile) }
        defer { gate.release() }
        await gate.entered()
        let held = try #require(workspace.screen(profile: service.profile))
        let text = " \tDirectory must keep e\u{301} 👩🏽‍💻\r\n "
        workspace.editDraft(text, owner: held.owner)
        let revision = try #require(workspace.persisted().record(held.selectedChatID)?.draft.revision)
        await workspace.refreshDirectory(held.owner)
        let inventoried = try #require(workspace.screen(profile: service.profile))
        #expect(inventoried.selectedChatID == held.selectedChatID && inventoried.isOpening)
        #expect(inventoried.canEditDraft && !inventoried.canAct && !inventoried.canCreate)
        #expect(workspace.persisted().preference(service.profile)?.main == held.selectedChatID)
        #expect(workspace.persisted().record(held.selectedChatID)?.binding.identity?.root == service.summaries[0].identity.root)
        #expect(workspace.persisted().record(held.selectedChatID)?.isUnverified == false)
        #expect(inventoried.snapshot == nil && inventoried.requests.isEmpty)
        #expect(workspace.captureSend(inventoried.owner) == nil)
        #expect(workspace.captureCreation(inventoried.owner) == nil)
        #expect(workspace.captureImport(inventoried.owner) == nil)
        #expect(workspace.persisted().records.count == service.summaries.count)
        #expect(workspace.persisted().record(held.selectedChatID)?.draft.revision == revision)
        #expect(Data(workspace.draft(inventoried.owner).utf8) == Data(text.utf8))
        gate.release()
        await opening.value
        let opened = try #require(workspace.screen(profile: service.profile))
        #expect(opened.canAct && opened.selectedChatID == held.selectedChatID)
        #expect(workspace.persisted().record(opened.selectedChatID)?.draft.revision == revision)
        #expect(Data(workspace.draft(opened.owner).utf8) == Data(text.utf8))
        #expect(workspace.captureSend(inventoried.owner) == nil)
        #expect(workspace.captureSend(opened.owner) != nil)
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.uploads.isEmpty)
    }

    @Test(arguments: ["draft", "legacy", "unverified", "transcript", "seen", "variant"])
    func importedProvisionalHistoryCannotAcquireLocalOriginOnRecovery(imported: String) async throws {
        let service = try WorkspaceTestService()
        var book = ConversationBook()
        let original = book.ensureProfile(service.profile)
        let legacy = try ExactID("unproven-legacy")
        book.update(original) { record in
            switch imported {
            case "draft": record.draft.text = "Imported draft"
            case "legacy": record.binding = .provisionalMain(legacyStored: legacy)
            case "unverified": record.isUnverified = true; record.draft.text = "Unverified draft"
            case "transcript": record.transcript = service.snapshots[service.summaries[0].identity.root]
            case "seen": record.seen = .init(messageID: nil, observedAt: .distantPast)
            default: record.preservedVariants = [.init(draft: .init(text: "Imported variant"), transcript: nil)]
            }
        }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")])
        await workspace.openBot(profile: service.profile)
        let offline = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Locally edited recovered history", owner: offline.owner)
        let preserved = try #require(workspace.persisted().record(original))
        workspace.retireConnection()
        workspace.setOnline(true)
        let owner = try #require(workspace.screen(profile: service.profile)?.owner)
        await workspace.refreshDirectory(owner)
        let recovered = try #require(workspace.screen(profile: service.profile))
        #expect(recovered.selectedChatID == original && !recovered.canAct && !recovered.canEditDraft)
        #expect(workspace.persisted().record(original)?.isUnverified == true)
        #expect(workspace.persisted().record(original)?.binding.identity == nil)
        #expect(workspace.persisted().preference(service.profile)?.main != original)
        #expect(Data(workspace.draft(recovered.owner).utf8) == Data(preserved.draft.text.utf8))
        #expect(workspace.persisted().record(original)?.draft.revision == preserved.draft.revision)
        #expect(workspace.persisted().record(original)?.preservedVariants.count == preserved.preservedVariants.count)
        #expect(workspace.persisted().record(original)?.transcript?.messages.count == preserved.transcript?.messages.count)
        #expect(workspace.captureSend(recovered.owner) == nil && workspace.captureImport(recovered.owner) == nil)
        await workspace.openBot(profile: service.profile)
        #expect(service.opens.isEmpty && service.sends.isEmpty && service.creates.isEmpty && service.uploads.isEmpty)
    }

    @Test func workspaceRetirementRejectsLateOpenAndRemountDoesNotInheritDraftOrigin() async throws {
        let service = try WorkspaceTestService()
        let gate = WorkspaceGate()
        service.openGate = gate
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        let opening = Task { await workspace.openBot(profile: service.profile) }
        defer { gate.release() }
        await gate.entered()
        let held = try #require(workspace.screen(profile: service.profile))
        let text = "Draft from previous workspace"
        workspace.editDraft(text, owner: held.owner)
        let saved = try JSONEncoder().encode(workspace.persisted())
        let revision = try #require(workspace.persisted().record(held.selectedChatID)?.draft.revision)
        workspace.retireWorkspace()
        gate.release()
        await opening.value
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        #expect(!workspace.isCurrent(held.owner) && workspace.captureSend(held.owner) == nil)
        #expect(workspace.persisted().record(held.selectedChatID)?.binding.identity == nil)
        #expect(workspace.persisted().record(held.selectedChatID)?.draft.revision == revision)
        #expect(service.opens.count == 1)

        service.openGate = nil
        let restored = try JSONDecoder().decode(ConversationBook.self, from: saved)
        let remounted = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: restored, service: service, onDirty: {})
        remounted.setOnline(true)
        await remounted.openBot(profile: service.profile)
        let opened = try #require(remounted.screen(profile: service.profile))
        #expect(opened.canAct && opened.selectedChatID != held.selectedChatID)
        #expect(remounted.persisted().record(held.selectedChatID)?.isUnverified == true)
        #expect(remounted.persisted().record(held.selectedChatID)?.binding.identity == nil)
        #expect(remounted.persisted().record(held.selectedChatID)?.draft.text == text)
        #expect(remounted.persisted().record(held.selectedChatID)?.draft.revision == revision)
        #expect(remounted.draft(opened.owner).isEmpty && remounted.persisted().records.count == 2)
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.uploads.isEmpty)
    }

    @Test(arguments: [HermesServiceError.invalidResponse, .responseTooLong])
    func definiteValidationRejectionRenewsOnlyAttemptAndKeepsRowAuthority(rejection: HermesServiceError) async throws {
        let (workspace, service, row) = try await fixture()
        let owner = try #require(workspace.screen(profile: service.profile)?.owner)
        service.responseError = rejection
        await workspace.answer(row.intent, response: .text("invalid"))
        let currentRow = try #require(workspace.screen(profile: service.profile)?.requests.first)
        #expect(currentRow.id == row.id && currentRow.request == row.request)
        #expect(workspace.screen(profile: service.profile)?.owner == owner)
        #expect(service.responses.isEmpty)
        service.responseError = nil
        await workspace.answer(row.intent, response: .text("old queued intent"))
        #expect(service.responseOperations.count == 1)
        await workspace.answer(currentRow.intent, response: .text("corrected"))
        #expect(service.responses == [row.request])
        #expect(service.responseOperations.count == 2 && Set(service.responseOperations).count == 2)
        #expect(workspace.screen(profile: service.profile)?.error == nil)
    }

    @Test func uncertainOutcomeDoesNotRenewOrResubmitSameRow() async throws {
        let (workspace, service, row) = try await fixture()
        service.responseError = HermesServiceError.uncertain
        await workspace.answer(row.intent, response: .text("answer"))
        let current = try #require(workspace.screen(profile: service.profile)?.requests.first)
        service.responseError = nil
        await workspace.answer(current.intent, response: .text("retry"))
        #expect(service.responseOperations.count == 1 && service.responses.isEmpty)
        #expect(workspace.screen(profile: service.profile)?.error == HermesServiceError.uncertain.localizedDescription)
    }
    @Test func offlineDraftingRetainsRequestRowsWithoutAuthorizingRetiredAnswers() async throws {
        let (workspace, service, original) = try await fixture()
        let originalOwner = try #require(workspace.screen(profile: service.profile)?.owner)
        workspace.editRequestDraft("Keep this answer", row: original, owner: originalOwner)
        workspace.retireConnection()
        let offline = try #require(workspace.screen(profile: service.profile))
        let offlineRow = try #require(offline.requests.first)
        #expect(offline.canEditDraft && !offline.canAct)
        #expect(offlineRow.id != original.id)
        #expect(workspace.requestDraft(offlineRow, owner: offline.owner) == "Keep this answer")
        workspace.editRequestDraft("stale input", row: original, owner: originalOwner)
        workspace.editRequestDraft("Keep this offline answer", row: offlineRow, owner: offline.owner)
        workspace.editDraft("Keep this offline thought", owner: offline.owner)
        await workspace.answer(offlineRow.intent, response: .text("blocked offline"))
        #expect(service.responseOperations.isEmpty)

        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let recovered = try #require(workspace.screen(profile: service.profile))
        let current = try #require(recovered.requests.first)
        #expect(recovered.canAct && current.id != original.id && current.id != offlineRow.id)
        #expect(workspace.draft(recovered.owner) == "Keep this offline thought")
        workspace.editRequestDraft("retired input", row: offlineRow, owner: offline.owner)
        workspace.editRequestDraft("retired row with current owner", row: offlineRow, owner: recovered.owner)
        workspace.editDraft("retired composer input", owner: offline.owner)
        #expect(workspace.requestDraft(current, owner: recovered.owner) == "Keep this offline answer")
        #expect(workspace.draft(recovered.owner) == "Keep this offline thought")
        await workspace.answer(offlineRow.intent, response: .text("retired callback"))
        #expect(service.responseOperations.isEmpty)
        await workspace.answer(current.intent, response: .text("deliberate answer"))
        await workspace.answer(current.intent, response: .text("duplicate answer"))
        #expect(service.responseOperations.count == 1)
        #expect(service.responses == [current.request])
    }

    @Test(arguments: [false, true])
    func changedOrDisappearedRequestRevokesDraftAndOldRow(replaced: Bool) async throws {
        let (workspace, service, original) = try await fixture()
        let screen = try #require(workspace.screen(profile: service.profile))
        let opened = try #require(service.completedOpens.last)
        workspace.editRequestDraft("Old answer", row: original, owner: screen.owner)
        var snapshot = opened.snapshot
        snapshot.pendingRequests = replaced
            ? [.init(id: original.request.id, kind: .question, title: "A different question")]
            : []
        workspace.receive(.init(identity: opened.identity, snapshot: snapshot, access: opened.access))
        let changed = try #require(workspace.screen(profile: service.profile))
        #expect(changed.owner == screen.owner)
        if replaced {
            let replacement = try #require(changed.requests.first)
            #expect(replacement.id != original.id)
            #expect(workspace.requestDraft(replacement, owner: changed.owner).isEmpty)
        } else {
            #expect(changed.requests.isEmpty)
        }
        workspace.editRequestDraft("Stale text", row: original, owner: changed.owner)
        workspace.receive(opened)
        let returned = try #require(workspace.screen(profile: service.profile)?.requests.first)
        #expect(returned.id != original.id)
        #expect(workspace.requestDraft(returned, owner: changed.owner).isEmpty)
        await workspace.answer(original.intent, response: .text("Stale callback"))
        #expect(service.responseOperations.isEmpty)
        workspace.editRequestDraft("New answer", row: returned, owner: changed.owner)
        #expect(workspace.requestDraft(returned, owner: changed.owner) == "New answer")
        await workspace.answer(returned.intent, response: .text("New answer"))
        #expect(service.responses == [returned.request])
    }

    @Test(arguments: [false, true])
    func sourceChangeRevokesQuestionDraftEvenWhenRequestIsIdentical(changedRoot: Bool) async throws {
        let (workspace, service, original) = try await fixture()
        let screen = try #require(workspace.screen(profile: service.profile))
        let source = service.summaries[0].identity
        workspace.editRequestDraft("Old source answer", row: original, owner: screen.owner)
        let changedSource = SessionIdentity(profile: source.profile,
            root: changedRoot ? try ExactID("new-root") : source.root,
            stored: changedRoot ? source.stored : try ExactID("new-tip"), aliases: [source.root, source.stored])
        service.summaries[0] = .init(identity: changedSource, title: "Main", isCanonical: true, persistence: .durable)
        await workspace.refreshDirectory(screen.owner)
        #expect(workspace.screen(profile: service.profile)?.requests.isEmpty == true)
        workspace.retireConnection()
        #expect(workspace.screen(profile: service.profile)?.requests.isEmpty == true)
        var snapshot = try #require(service.snapshots[source.root])
        snapshot.id = changedSource.root.text; snapshot.storedID = changedSource.stored.text
        service.snapshots[changedSource.root] = snapshot
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let recovered = try #require(workspace.screen(profile: service.profile))
        let current = try #require(recovered.requests.first)
        #expect(current.request == original.request && current.id != original.id)
        #expect(workspace.requestDraft(current, owner: recovered.owner).isEmpty)
        workspace.editRequestDraft("Old source input", row: original, owner: screen.owner)
        await workspace.answer(original.intent, response: .text("Old source callback"))
        #expect(workspace.requestDraft(current, owner: recovered.owner).isEmpty)
        #expect(service.responseOperations.isEmpty)
    }

    @Test func confirmedUnavailableChatRevokesPromptsAndEditingWithoutLosingComposer() async throws {
        let (workspace, service, original) = try await fixture()
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Preserved composer", owner: screen.owner)
        workspace.editRequestDraft("Revoked answer", row: original, owner: screen.owner)
        let summaries = service.summaries
        service.summaries = []
        await workspace.refreshDirectory(screen.owner)
        let unavailable = try #require(workspace.screen(profile: service.profile))
        #expect(unavailable.requests.isEmpty && !unavailable.canEditDraft && !unavailable.canAct)
        workspace.editDraft("Blocked composer", owner: unavailable.owner)
        workspace.editRequestDraft("Blocked answer", row: original, owner: unavailable.owner)
        await workspace.answer(original.intent, response: .text("Blocked answer"))
        #expect(workspace.draft(unavailable.owner) == "Preserved composer")
        #expect(service.responseOperations.isEmpty)
        workspace.retireConnection()
        let offline = try #require(workspace.screen(profile: service.profile))
        #expect(offline.requests.isEmpty && !offline.canEditDraft)
        workspace.editDraft("Blocked offline composer", owner: offline.owner)
        #expect(workspace.draft(offline.owner) == "Preserved composer")
        workspace.setOnline(true)
        service.summaries = summaries
        await workspace.refreshDirectory(offline.owner)
        #expect(workspace.screen(profile: service.profile)?.requests.isEmpty == true)
        await workspace.openBot(profile: service.profile)
        let recovered = try #require(workspace.screen(profile: service.profile))
        let current = try #require(recovered.requests.first)
        #expect(recovered.canEditDraft && recovered.canAct)
        #expect(workspace.requestDraft(current, owner: recovered.owner).isEmpty)
        #expect(workspace.draft(recovered.owner) == "Preserved composer")
    }

    @Test func failedOnlineOpenDoesNotAuthorizeDraftEditing() async throws {
        let (workspace, service, original) = try await fixture()
        let owner = try #require(workspace.screen(profile: service.profile)?.owner)
        workspace.editDraft("Composer", owner: owner)
        workspace.editRequestDraft("Answer", row: original, owner: owner)
        workspace.retireConnection()
        workspace.setOnline(true)
        service.openError = HermesServiceError.wrongConversation
        await workspace.openBot(profile: service.profile)
        let failed = try #require(workspace.screen(profile: service.profile))
        let row = try #require(failed.requests.first)
        #expect(!failed.canEditDraft && !failed.canAct)
        workspace.editDraft("Blocked composer", owner: failed.owner)
        workspace.editRequestDraft("Blocked answer", row: row, owner: failed.owner)
        #expect(workspace.draft(failed.owner) == "Composer")
        #expect(workspace.requestDraft(row, owner: failed.owner) == "Answer")
    }

}
