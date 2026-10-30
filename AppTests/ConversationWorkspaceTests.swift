import Foundation
import Observation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationWorkspaceTests {
    @Test func localTabClosurePersistsWithoutChangingReaderOrHistory() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(other, owner: main.owner)))
        let otherScreen = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Keep this draft", owner: otherScreen.owner)
        await workspace.select(try #require(workspace.captureSelection(main.owner.chat, owner: otherScreen.owner)))
        let reader = try #require(workspace.screen(profile: service.profile))
        let openCount = service.opens.count
        #expect(workspace.captureClose(reader.owner.chat, owner: reader.owner) == nil)
        let closeIntent = try #require(workspace.captureClose(other, owner: reader.owner))
        let closed = try #require(workspace.close(closeIntent))
        #expect(closed.id == other)
        #expect(workspace.cards(profile: service.profile).map(\.id) == [reader.owner.chat])
        #expect(workspace.screen(profile: service.profile)?.owner == reader.owner)
        #expect(service.opens.count == openCount)
        await workspace.refreshDirectory(reader.owner)
        #expect(workspace.cards(profile: service.profile).count == 1)
        let saved = try JSONDecoder().decode(ConversationBook.self, from: JSONEncoder().encode(workspace.persisted()))
        #expect(saved.record(other)?.draft.text == "Keep this draft")
        #expect(saved.record(other)?.transcript != nil)
        let restored = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: saved, service: service, onDirty: {})
        await restored.openBot(profile: service.profile)
        let restoredReader = try #require(restored.screen(profile: service.profile))
        #expect(restored.cards(profile: service.profile).count == 1)
        #expect(restored.closedChats(profile: service.profile).map(\.id) == [other])
        restored.reopen(try #require(restored.captureReopening(closed.id, owner: restoredReader.owner)))
        #expect(restored.cards(profile: service.profile).count == 2)
        #expect(restored.screen(profile: service.profile)?.owner == restoredReader.owner)
        #expect(service.opens.count == openCount)
    }

    @Test(arguments: [false, true])
    func closingSelectedTabChoosesCachedMainWithoutAcknowledgingOrStoppingWork(emptyDirectory: Bool) async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(other, owner: main.owner)))
        let otherScreen = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Unsent", owner: otherScreen.owner)
        await workspace.upload(Data([1]), filename: "keep.txt", mimeType: "text/plain",
            to: try #require(workspace.captureImport(otherScreen.owner)))
        let staged = try #require(workspace.screen(profile: service.profile)?.attachments.first)
        workspace.preferOpening(other, owner: otherScreen.owner)
        if emptyDirectory {
            service.summaries = []
            await workspace.refreshDirectory(otherScreen.owner)
        }
        let beforeClose = try #require(workspace.screen(profile: service.profile))
        let openCount = service.opens.count
        let intent = try #require(workspace.captureClose(other, owner: beforeClose.owner))
        let closed = workspace.close(intent)
        #expect(closed?.id == other)
        let fallback = try #require(workspace.screen(profile: service.profile))
        #expect(fallback.owner.chat == main.owner.chat)
        #expect(!workspace.isCurrent(beforeClose.owner))
        #expect(workspace.persisted().opening(service.profile) == main.owner.chat)
        #expect(workspace.persisted().record(main.owner.chat)?.seen == nil)
        #expect(workspace.persisted().record(other)?.draft.text == "Unsent")
        #expect(workspace.persisted().record(other)?.transcript != nil)
        #expect(workspace.cards(profile: service.profile).map(\.id) == [main.owner.chat])
        #expect(workspace.captureClose(main.owner.chat, owner: fallback.owner) == nil)
        #expect(service.opens.count == openCount)
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.stops.isEmpty)
        if emptyDirectory {
            #expect(workspace.captureActivation(fallback.owner) == nil)
            #expect(!fallback.canAct && !fallback.canCreate)
        } else {
            #expect(fallback.canEditDraft && fallback.canCreate && !fallback.canAct)
            workspace.editDraft("Main draft", owner: fallback.owner)
            #expect(workspace.captureSend(fallback.owner) == nil)
            await workspace.select(try #require(workspace.captureActivation(fallback.owner)))
            let active = try #require(workspace.screen(profile: service.profile))
            #expect(active.owner.chat == main.owner.chat && active.canAct && active.canCreate)
            #expect(workspace.draft(active.owner) == "Main draft")
            #expect(workspace.captureActivation(active.owner) == nil)
        }
        let active = try #require(workspace.screen(profile: service.profile))
        #expect(service.opens.count == openCount + (emptyDirectory ? 0 : 1))
        await workspace.select(try #require(workspace.captureSelection(other, owner: active.owner)))
        #expect(workspace.screen(profile: service.profile)?.attachments == [staged])
        #expect(service.uploads.count == 1)
    }

    @Test(arguments: [false, true])
    func localFallbackActivationCannotReviveAnOfflineOrReplacedOwner(offline: Bool) async throws {
        let (workspace, service, main, other) = try await closedSelectedFixture()
        let activation = try #require(workspace.captureActivation(main.owner))
        if offline {
            workspace.retireConnection()
            let cached = try #require(workspace.screen(profile: service.profile))
            #expect(cached.canEditDraft && !cached.canCreate)
            #expect(workspace.captureActivation(cached.owner) == nil)
        } else {
            await workspace.select(try #require(workspace.captureSelection(other, owner: main.owner)))
        }
        let count = service.opens.count
        let owner = workspace.screen(profile: service.profile)?.owner
        await workspace.select(activation)
        #expect(service.opens.count == count)
        #expect(workspace.screen(profile: service.profile)?.owner == owner)
    }

    @Test func failedLocalFallbackActivationKeepsDraftAndAllowsDeliberateRetry() async throws {
        let (workspace, service, main, _) = try await closedSelectedFixture()
        workspace.editDraft("Keep through failure", owner: main.owner)
        service.openError = HermesServiceError.timeout
        await workspace.select(try #require(workspace.captureActivation(main.owner)))
        let failed = try #require(workspace.screen(profile: service.profile))
        #expect(failed.canEditDraft && !failed.canAct && failed.error != nil)
        #expect(workspace.draft(failed.owner) == "Keep through failure")
        service.openError = nil
        await workspace.select(try #require(workspace.captureActivation(failed.owner)))
        let ready = try #require(workspace.screen(profile: service.profile))
        #expect(ready.canAct && ready.error == nil)
        #expect(workspace.draft(ready.owner) == "Keep through failure")
    }

    @Test func explicitCreationFromLocalFallbackNeedsNoReadOfMain() async throws {
        let (workspace, service, main, other) = try await closedSelectedFixture()
        let count = service.opens.count
        let creation = try #require(workspace.captureCreation(main.owner))
        #expect(workspace.screen(profile: service.profile)?.canCreate == false)
        await workspace.create(creation)
        let created = try #require(workspace.screen(profile: service.profile))
        #expect(service.creates.count == 1 && service.opens.count == count + 1)
        #expect(created.canAct && created.owner.chat != main.owner.chat)
        #expect(workspace.closedChats(profile: service.profile).map(\.id) == [other])
        #expect(workspace.persisted().record(main.owner.chat)?.seen == nil)
    }

    private func closedSelectedFixture() async throws -> (ConversationWorkspace, WorkspaceTestService, ChatScreen, ChatID) {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(other, owner: main.owner)))
        let selected = try #require(workspace.screen(profile: service.profile))
        _ = workspace.close(try #require(workspace.captureClose(other, owner: selected.owner)))
        return (workspace, service, try #require(workspace.screen(profile: service.profile)), other)
    }

    @Test(arguments: [false, true])
    func deliberateTargetOpenRevealsClosedTabAndRetainsBotAttention(attention: Bool) async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        let intent = try #require(workspace.captureClose(other, owner: main.owner))
        _ = workspace.close(intent)
        workspace.applyActivity(profile: service.profile, observations: [service.summaries[1].identity: .known(.waiting, .distantFuture)])
        #expect(workspace.aggregate(profile: service.profile).attentionChat == other)
        #expect(workspace.aggregate(profile: service.profile).activity == .current(.waiting))
        if attention { await workspace.openAttention(profile: service.profile) }
        else { await workspace.select(try #require(workspace.captureSelection(other, owner: main.owner))) }
        #expect(workspace.screen(profile: service.profile)?.owner.chat == other)
        #expect(workspace.cards(profile: service.profile).contains { $0.id == other })
        #expect(workspace.closedChats(profile: service.profile).isEmpty)
        #expect(service.stops.isEmpty)
    }

    @Test func staleLocalTabIntentsCannotChangeTheNewReader() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        let staleClose = try #require(workspace.captureClose(other, owner: main.owner))
        await workspace.select(try #require(workspace.captureSelection(other, owner: main.owner)))
        #expect(workspace.close(staleClose) == nil)
        let reader = try #require(workspace.screen(profile: service.profile))
        let close = try #require(workspace.captureClose(other, owner: reader.owner))
        _ = workspace.close(close)
        let fallback = try #require(workspace.screen(profile: service.profile))
        let staleReopen = try #require(workspace.captureReopening(other, owner: fallback.owner))
        await workspace.select(try #require(workspace.captureSelection(fallback.owner.chat, owner: fallback.owner)))
        let current = try #require(workspace.screen(profile: service.profile))
        workspace.reopen(staleReopen)
        #expect(workspace.cards(profile: service.profile).count == 1)
        #expect(workspace.screen(profile: service.profile)?.owner == current.owner)
    }

    @Test(arguments: [false, true])
    func inventoryBookkeepingNotifiesCardsAndPersistenceWithoutInvalidatingSelectedScreen(activity: Bool) async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner)
        let rendered = try #require(screen.snapshot)
        let sibling = service.summaries[1].identity
        try await confirmation("Inventory bookkeeping does not change selected-screen facts", expectedCount: 0) { changed in
            withObservationTracking {
                _ = workspace.screen(profile: service.profile)
                _ = workspace.selection(profile: service.profile)
                _ = workspace.canEditDraft(screen.owner)
                _ = workspace.draft(screen.owner)
            } onChange: { changed() }
            await confirmation("Cards, aggregates and persistence remain observed", expectedCount: 3) { changed in
                withObservationTracking { _ = workspace.cards(profile: service.profile) } onChange: { changed() }
                withObservationTracking { _ = workspace.aggregate(profile: service.profile) } onChange: { changed() }
                withObservationTracking { _ = workspace.persisted() } onChange: { changed() }
                if activity {
                    workspace.applyActivity(profile: service.profile, observations: [sibling: .known(.waiting, .distantFuture)])
                } else { workspace.displayed(screen.owner) }
            }
            #expect(workspace.screen(profile: service.profile)?.owner == screen.owner)
            if activity {
                #expect(workspace.cards(profile: service.profile).first { $0.id != screen.owner.chat }?.activity == .current(.waiting))
                #expect(workspace.persisted().records.first { $0.id != screen.owner.chat }?.lastKnownActivity?.observedAt == .distantFuture)
            } else {
                #expect(workspace.persisted().record(screen.owner.chat)?.seen?.content == ChatContentEvidence(rendered))
                #expect(workspace.cards(profile: service.profile).first { $0.id == screen.owner.chat }?.unread == false)
            }
        }
    }

    @Test(arguments: ["title", "identity", "recovery"])
    func selectedScreenStillObservesStructuralMetadataAndRecovery(change: String) async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(other, owner: main.owner)))
        let screen = try #require(workspace.screen(profile: service.profile))
        let old = service.summaries[1]
        let nextIdentity = SessionIdentity(profile: old.identity.profile, root: old.identity.root,
            stored: try ExactID("replacement-tip"), aliases: [old.identity.stored])
        await confirmation("Selected screen and selection observe normal mutations", expectedCount: 2) { changed in
            withObservationTracking { _ = workspace.screen(profile: service.profile) } onChange: { changed() }
            withObservationTracking { _ = workspace.selection(profile: service.profile) } onChange: { changed() }
            if change == "recovery" { workspace.retireConnection() }
            else {
                service.summaries[1] = .init(identity: change == "identity" ? nextIdentity : old.identity,
                    title: "Updated title", isCanonical: false, persistence: .durable)
                await workspace.refreshDirectory(screen.owner)
            }
        }
        let current = try #require(workspace.screen(profile: service.profile))
        if change == "recovery" { #expect(current.owner != screen.owner && !workspace.isCurrent(screen.owner)) }
        else {
            #expect(current.title == "Updated title")
            if change == "identity" {
                #expect(workspace.selection(profile: service.profile)?.identity?.stored == nextIdentity.stored)
            }
        }
    }

    @Test func draftEditsNotifyDraftReadersWithoutInvalidatingTranscriptOrRoster() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        let original = try #require(workspace.persisted().record(screen.owner.chat)?.draft.revision)
        try await confirmation("Drafts do not change transcript or roster projections", expectedCount: 0) { changed in
            withObservationTracking {
                _ = workspace.screen(profile: service.profile)
                _ = workspace.selection(profile: service.profile)
                _ = workspace.aggregate(profile: service.profile)
                _ = workspace.aggregates(profiles: [service.profile])
            } onChange: { changed() }
            await confirmation("Both draft and persistence readers observe the edit", expectedCount: 2) { changed in
                withObservationTracking { _ = workspace.draft(screen.owner) } onChange: { changed() }
                withObservationTracking { _ = workspace.persisted() } onChange: { changed() }
                workspace.editDraft("e\u{301}", owner: screen.owner)
            }
            #expect(workspace.draft(screen.owner).utf8.elementsEqual("e\u{301}".utf8))
            let edited = try #require(workspace.persisted().record(screen.owner.chat)?.draft)
            #expect(edited.text.utf8.elementsEqual("e\u{301}".utf8) && edited.revision != original)
            await confirmation("An identical edit is silent", expectedCount: 0) { changed in
                withObservationTracking {
                    _ = workspace.draft(screen.owner)
                    _ = workspace.persisted()
                } onChange: { changed() }
                workspace.editDraft("e\u{301}", owner: screen.owner)
            }
            #expect(workspace.persisted().record(screen.owner.chat)?.draft.revision == edited.revision)
        }
    }

    @Test func generalBookChangesStillNotifyDraftAndPersistenceReaders() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        let preferred = screen.owner.chat
        workspace.editDraft("Keep this draft", owner: screen.owner)
        await confirmation("A preference change reaches presentation and complete readers", expectedCount: 3) { changed in
            withObservationTracking { _ = workspace.screen(profile: service.profile) } onChange: { changed() }
            withObservationTracking { _ = workspace.draft(screen.owner) } onChange: { changed() }
            withObservationTracking { _ = workspace.persisted() } onChange: { changed() }
            workspace.preferOpening(preferred, owner: screen.owner)
        }
        #expect(workspace.cards(profile: service.profile).first { $0.id == preferred }?.isPreferred == true)
        #expect(workspace.draft(screen.owner) == "Keep this draft")
        #expect(workspace.persisted().record(screen.owner.chat)?.draft.text == "Keep this draft")
    }

    @Test func generalBookMutationPreservesDraftWrittenDuringItsObservationCallback() async throws {
        let service = try WorkspaceTestService()
        var dirtyReadback: (@MainActor () -> Void)?
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: { dirtyReadback?() })
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        let preferred = screen.owner.chat
        var persistedAtDirty: String?
        dirtyReadback = { [weak workspace] in
            persistedAtDirty = workspace?.persisted().record(screen.owner.chat)?.draft.text
        }
        await confirmation("General mutation notifies before in-place storage access") { changed in
            withObservationTracking { _ = workspace.screen(profile: service.profile) } onChange: {
                MainActor.assumeIsolated {
                    changed()
                    workspace.editDraft("Draft from the callback", owner: screen.owner)
                }
            }
            workspace.preferOpening(preferred, owner: screen.owner)
        }
        #expect(workspace.draft(screen.owner) == "Draft from the callback")
        #expect(persistedAtDirty == "Draft from the callback")
        #expect(workspace.cards(profile: service.profile).first { $0.id == preferred }?.isPreferred == true)
    }

    func fixture() throws -> (ConversationWorkspace, WorkspaceTestService) {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        return (workspace, service)
    }
    @Test func selectionPreservesLiveCachedAndOpeningContent() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        let binding = SessionIdentity(profile: main.profile, root: main.root, stored: main.stored,
                                      aliases: main.aliases.union([main.root, main.stored]))
        service.snapshots[main.root]?.isWorking = true
        await workspace.openBot(profile: service.profile)
        let live = try #require(workspace.selection(profile: service.profile))
        #expect(live.identity == binding && !live.isUnverified && !live.isOpening)
        #expect(live.snapshot?.isWorking == true)
        #expect(workspace.canEditDraft(live.owner))
        #expect(live.owner == workspace.screen(profile: service.profile)?.owner)
        #expect(workspace.selection(profile: try ExactID("unrelated")) == nil)

        workspace.retireConnection()
        let cached = try #require(workspace.selection(profile: service.profile))
        #expect(!workspace.canEditDraft(live.owner) && workspace.canEditDraft(cached.owner))
        #expect(cached.identity == binding && cached.snapshot?.isWorking == false)
        #expect(cached.snapshot?.messages == live.snapshot?.messages)
        #expect(cached.owner == workspace.screen(profile: service.profile)?.owner)

        workspace.setOnline(true)
        let gate = WorkspaceGate(); service.openGate = gate
        defer { gate.release() }
        let opening = Task { await workspace.openBot(profile: service.profile) }
        await gate.entered()
        let pending = try #require(workspace.selection(profile: service.profile))
        #expect(workspace.canEditDraft(pending.owner))
        #expect(pending.isOpening && pending.identity == binding)
        #expect(pending.snapshot?.messages == cached.snapshot?.messages)
        #expect(pending.owner == workspace.screen(profile: service.profile)?.owner)
        gate.release(); await opening.value
        let reopened = try #require(workspace.selection(profile: service.profile))
        #expect(!reopened.isOpening && reopened.snapshot?.isWorking == true)
        #expect(reopened.identity == binding)
        #expect(!workspace.canEditDraft(pending.owner) && workspace.canEditDraft(reopened.owner))
        workspace.retireWorkspace()
        #expect(!workspace.canEditDraft(reopened.owner))
    }

    @Test func storedTipRotationPreservesQueuedEditAndOffersDraftRecovery() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        let item = QueuedMessage(id: "queued-a", text: "Original", canEdit: true)
        service.snapshots[main.root]?.queuedMessages = [item]
        await workspace.openBot(profile: service.profile)
        var screen = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Existing draft", owner: screen.owner)
        workspace.beginQueuedEdit(item, owner: screen.owner)
        workspace.updateQueuedEdit("Edited\nqueued message", owner: screen.owner)
        screen = try #require(workspace.screen(profile: service.profile))
        let editID = try #require(screen.queuedEdit?.id)
        #expect(screen.canReplaceQueuedEdit && screen.canSaveQueuedEdit)

        let rotated = SessionIdentity(profile: main.profile, root: main.root,
            stored: try ExactID("rotated-tip"), aliases: main.aliases.union([main.stored]))
        service.summaries[0] = .init(identity: rotated, title: "Bot Chat", isCanonical: true, persistence: .durable)
        service.snapshots[main.root]?.storedID = rotated.stored.text
        await workspace.openBot(profile: service.profile)
        let reopened = try #require(workspace.screen(profile: service.profile))
        #expect(reopened.selectedChatID == screen.selectedChatID)
        #expect(reopened.snapshot?.queuedMessages == [item])
        #expect(reopened.queuedEdit?.id == editID && reopened.queuedEdit?.text == "Edited\nqueued message")
        #expect(!reopened.canReplaceQueuedEdit && !reopened.canSaveQueuedEdit)
        await workspace.saveQueuedEdit(reopened.owner)
        #expect(service.replacements.isEmpty && service.sends.isEmpty)
        workspace.keepQueuedEditAsDraft(reopened.owner)
        #expect(workspace.draft(reopened.owner) == "Existing draft\n\nEdited\nqueued message")
        #expect(workspace.screen(profile: service.profile)?.queuedEdit == nil)
        #expect(service.replacements.isEmpty && service.sends.isEmpty)
    }

    @Test func queueEditCanSaveByteDistinctUnicodeText() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        let item = QueuedMessage(id: "queued-a", text: "é", canEdit: true)
        service.snapshots[main.root]?.isWorking = true
        service.snapshots[main.root]?.queuedMessages = [item]
        await workspace.openBot(profile: service.profile)
        var screen = try #require(workspace.screen(profile: service.profile))
        workspace.beginQueuedEdit(item, owner: screen.owner)
        #expect(workspace.screen(profile: service.profile)?.canSaveQueuedEdit == false)
        workspace.updateQueuedEdit("e\u{301}", owner: screen.owner)
        screen = try #require(workspace.screen(profile: service.profile))
        #expect(screen.canSaveQueuedEdit)
        await workspace.saveQueuedEdit(screen.owner)
        let replacement = try #require(service.replacements.first)
        #expect(Array(replacement.1.utf8) == [0x65, 0xcc, 0x81])
        #expect(service.replacements.count == 1 && service.sends.isEmpty)
        #expect(workspace.screen(profile: service.profile)?.queuedEdit == nil)
    }

    @Test(arguments: [false, true])
    func queueDeparturePreservesByteDistinctDraftsAndDeduplicatesExactText(matchesExactly: Bool) async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        let item = QueuedMessage(id: "queued-a", text: "Original", canEdit: true)
        service.snapshots[main.root]?.isWorking = true
        service.snapshots[main.root]?.queuedMessages = [item]
        await workspace.openBot(profile: service.profile)
        var screen = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("é", owner: screen.owner)
        workspace.beginQueuedEdit(item, owner: screen.owner)
        workspace.updateQueuedEdit(matchesExactly ? "é" : "e\u{301}", owner: screen.owner)
        service.snapshots[main.root]?.queuedMessages = []
        workspace.receive(try service.publication(main))
        screen = try #require(workspace.screen(profile: service.profile))
        workspace.keepQueuedEditAsDraft(screen.owner)
        let expected: [UInt8] = matchesExactly ? [0xc3, 0xa9] : [0xc3, 0xa9, 0x0a, 0x0a, 0x65, 0xcc, 0x81]
        #expect(Array(workspace.draft(screen.owner).utf8) == expected)
        #expect(workspace.screen(profile: service.profile)?.queuedEdit == nil)
        #expect(service.sends.isEmpty && service.replacements.isEmpty)
    }

    @Test func queueDepartureKeepsMultilineEditAndMergesItIntoAnUnsentDraft() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        let item = QueuedMessage(id: "queued-a", text: "Original", canEdit: true)
        service.snapshots[main.root]?.isWorking = true
        service.snapshots[main.root]?.queuedMessages = [item]
        await workspace.openBot(profile: service.profile)
        var screen = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Existing composer draft", owner: screen.owner)
        workspace.beginQueuedEdit(item, owner: screen.owner)
        workspace.updateQueuedEdit("First line\nSecond line\n\nLast paragraph", owner: screen.owner)
        service.snapshots[main.root]?.queuedMessages = []
        workspace.receive(try service.publication(main))
        screen = try #require(workspace.screen(profile: service.profile))
        #expect(screen.queuedEdit?.text == "First line\nSecond line\n\nLast paragraph")
        #expect(!screen.canSaveQueuedEdit)
        await workspace.saveQueuedEdit(screen.owner)
        #expect(service.replacements.isEmpty && service.sends.isEmpty)
        workspace.keepQueuedEditAsDraft(screen.owner)
        #expect(workspace.draft(screen.owner) == "Existing composer draft\n\nFirst line\nSecond line\n\nLast paragraph")
        #expect(workspace.screen(profile: service.profile)?.queuedEdit == nil)
        #expect(service.sends.isEmpty)
    }

    @Test func queueItemStartsAfterSaveDispatchAndNeverLosesTheEditOrSendsItAgain() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        let item = QueuedMessage(id: "queued-a", text: "Original", canEdit: true)
        service.snapshots[main.root]?.isWorking = true
        service.snapshots[main.root]?.queuedMessages = [item]
        await workspace.openBot(profile: service.profile)
        let before = try #require(workspace.screen(profile: service.profile))
        workspace.beginQueuedEdit(item, owner: before.owner)
        workspace.updateQueuedEdit("Changed\nwhile waiting", owner: before.owner)
        let gate = WorkspaceGate(); service.replacementGate = gate
        let save = Task { await workspace.saveQueuedEdit(before.owner) }
        await gate.entered()
        service.snapshots[main.root]?.queuedMessages = []
        workspace.receive(try service.publication(main))
        let during = try #require(workspace.screen(profile: service.profile))
        #expect(during.queuedEdit?.isSaving == true)
        workspace.keepQueuedEditAsDraft(during.owner)
        #expect(workspace.draft(during.owner).isEmpty)
        gate.release(); await save.value
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.queuedEdit?.text == "Changed\nwhile waiting")
        #expect(after.queuedEdit?.error != nil && after.queuedEdit?.isSaving == false)
        #expect(!after.canSaveQueuedEdit)
        await workspace.saveQueuedEdit(after.owner)
        #expect(service.replacements.count == 1 && service.sends.isEmpty)
        workspace.keepQueuedEditAsDraft(after.owner)
        #expect(workspace.draft(after.owner) == "Changed\nwhile waiting")
        #expect(service.sends.isEmpty)
    }

    @Test func positiveQueueReplacementACKSettlesOriginAfterTheReplacementHasStarted() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        let item = QueuedMessage(id: "queued-a", text: "Original", canEdit: true)
        service.snapshots[main.root]?.isWorking = true
        service.snapshots[main.root]?.queuedMessages = [item]
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.beginQueuedEdit(item, owner: screen.owner)
        workspace.updateQueuedEdit("Confirmed edit", owner: screen.owner)
        service.acceptsReplacementBeforeGate = true
        let gate = WorkspaceGate(); service.replacementGate = gate
        let save = Task { await workspace.saveQueuedEdit(screen.owner) }
        await gate.entered()
        service.snapshots[main.root]?.queuedMessages = []
        workspace.receive(try service.publication(main))
        gate.release(); await save.value
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.queuedEdit == nil)
        #expect(service.replacements.count == 1 && service.sends.isEmpty)
        #expect(workspace.draft(after.owner).isEmpty)
    }

    @Test func uncertainQueueReplacementPreservesTextAndBlocksBlindResubmission() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        let item = QueuedMessage(id: "queued-a", text: "Original", canEdit: true)
        service.snapshots[main.root]?.queuedMessages = [item]
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.beginQueuedEdit(item, owner: screen.owner)
        workspace.updateQueuedEdit("Unconfirmed edit", owner: screen.owner)
        service.replacementError = HermesServiceError.uncertain
        await workspace.saveQueuedEdit(screen.owner)
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.queuedEdit?.text == "Unconfirmed edit" && after.queuedEdit?.isUncertain == true)
        #expect(!after.canSaveQueuedEdit)
        await workspace.saveQueuedEdit(after.owner)
        #expect(service.replacements.count == 1 && service.sends.isEmpty)
    }

    @Test func lateQueueReplacementACKCannotConsumeAnotherChatsDraftOrEdit() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        let other = service.summaries[1].identity
        let item = QueuedMessage(id: "queued-a", text: "Original A", canEdit: true)
        let sibling = QueuedMessage(id: "queued-b", text: "Original B", canEdit: true)
        service.snapshots[main.root]?.queuedMessages = [item]
        service.snapshots[other.root]?.queuedMessages = [sibling]
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        workspace.beginQueuedEdit(item, owner: a.owner)
        workspace.updateQueuedEdit("Saved A", owner: a.owner)
        service.acceptsReplacementBeforeGate = true
        let gate = WorkspaceGate(); service.replacementGate = gate
        let save = Task { await workspace.saveQueuedEdit(a.owner) }
        await gate.entered()
        let target = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(target, owner: a.owner)))
        let b = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Composer B", owner: b.owner)
        workspace.beginQueuedEdit(sibling, owner: b.owner)
        workspace.updateQueuedEdit("Unsaved B", owner: b.owner)
        gate.release(); await save.value
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.selectedChatID == b.selectedChatID)
        #expect(after.queuedEdit?.text == "Unsaved B")
        #expect(workspace.draft(after.owner) == "Composer B")
        #expect(service.replacements.count == 1 && service.sends.isEmpty)
    }

    @Test func failedSteeringPreservesDraftAndExplicitQueueCanSendIt() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        service.snapshots[main.root]?.isWorking = true
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Make it shorter", owner: screen.owner)
        service.sendError = HermesServiceError.steeringUnavailable
        let steer = try #require(workspace.captureSend(screen.owner, delivery: .steer))
        await workspace.send(steer)
        #expect(workspace.draft(screen.owner) == "Make it shorter")
        #expect(workspace.screen(profile: service.profile)?.error != nil)
        service.sendError = nil
        await workspace.send(try #require(workspace.captureSend(screen.owner, delivery: .queue)))
        #expect(service.deliveries == [.steer, .queue])
        #expect(workspace.screen(profile: service.profile)?.error == nil)
        #expect(workspace.draft(screen.owner).isEmpty)
    }

    @Test func switchingKeepsIndependentExactDraftsAndRetiresQueuedActions() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        workspace.editDraft("  A thought \n", owner: a.owner)
        let queued = try #require(workspace.captureSend(a.owner))
        let bID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(bID, owner: a.owner)))
        let b = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("B thought", owner: b.owner)
        await workspace.send(queued)
        #expect(service.sends.isEmpty)
        await workspace.select(try #require(workspace.captureSelection(a.selectedChatID, owner: b.owner)))
        let returned = try #require(workspace.screen(profile: service.profile))
        #expect(workspace.draft(returned.owner) == "  A thought \n")
        #expect(!workspace.isCurrent(a.owner))
        #expect(returned.epoch != a.epoch)
        #expect(workspace.persisted().record(bID)?.draft.text == "B thought")
    }
    @Test(arguments: [false, true])
    func sourceACKSettlesOnlySubmittedRevisionAndUniqueFilesWhileBSelected(retyped: Bool) async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        let initialRevision = try #require(workspace.persisted().record(a.selectedChatID)?.draft.revision)
        await workspace.refreshDirectory(a.owner)
        workspace.editDraft("submitted", owner: a.owner)
        await workspace.upload(Data([1]), filename: "a.txt", mimeType: "text/plain", to: try #require(workspace.captureImport(a.owner)))
        let stagedA = try #require(workspace.screen(profile: service.profile)?.attachments.first)
        let intent = try #require(workspace.captureSend(a.owner))
        let gate = WorkspaceGate(); service.sendGate = gate
        let sending = Task { await workspace.send(intent) }
        await gate.entered()
        let bID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(bID, owner: a.owner)))
        var b = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("B stays", owner: b.owner)
        await workspace.upload(Data([2]), filename: "b.txt", mimeType: "text/plain", to: try #require(workspace.captureImport(b.owner)))
        if retyped {
            await workspace.select(try #require(workspace.captureSelection(a.selectedChatID, owner: b.owner)))
            let returned = try #require(workspace.screen(profile: service.profile))
            workspace.editDraft("", owner: returned.owner)
            workspace.editDraft("submitted", owner: returned.owner)
            workspace.removeAttachment(stagedA, owner: returned.owner)
            await workspace.upload(Data([3]), filename: "a.txt", mimeType: "text/plain", to: try #require(workspace.captureImport(returned.owner)))
            await workspace.select(try #require(workspace.captureSelection(bID, owner: returned.owner)))
            b = try #require(workspace.screen(profile: service.profile))
        }
        let bEpoch = b.epoch
        gate.release(); await sending.value
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.selectedChatID == bID && after.epoch == bEpoch)
        #expect(workspace.draft(after.owner) == "B stays")
        #expect(after.attachments.map(\.name) == ["b.txt"] && after.error == nil)
        #expect(workspace.persisted().record(a.selectedChatID)?.draft.text == (retyped ? "submitted" : ""))
        await workspace.select(try #require(workspace.captureSelection(a.selectedChatID, owner: after.owner)))
        let settled = try #require(workspace.screen(profile: service.profile))
        #expect(settled.attachments.count == (retyped ? 1 : 0))
        #expect(workspace.persisted().record(settled.selectedChatID)?.draft.revision != initialRevision)
        #expect(service.sends.count == 1 && service.sends.first?.0 == "submitted")
    }

    @Test func newRequestGrantRetiresOldRowsEvenWithRepeatedRequestID() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        let request = PendingRequest(id: "same", kind: .approval, title: "Approve?")
        service.snapshots[main.root]?.pendingRequests = [request]
        await workspace.openBot(profile: service.profile)
        let old = try #require(workspace.screen(profile: service.profile)?.requests.first)
        workspace.receive(try service.publication(main))
        let fresh = try #require(workspace.screen(profile: service.profile)?.requests.first)
        await workspace.answer(old.intent, response: .choice("once"))
        #expect(service.responses.isEmpty && old.id != fresh.id)
        await workspace.answer(fresh.intent, response: .choice("once"))
        await workspace.answer(fresh.intent, response: .choice("once"))
        #expect(service.responses == [request])
    }

    @Test func displayedAloneMarksSeenAndOfflineActivityRemainsUnknown() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner)
        #expect(workspace.persisted().record(screen.selectedChatID)?.seen == nil)
        #expect(workspace.aggregate(profile: service.profile).unreadCount == 1)
        workspace.displayed(screen.owner)
        #expect(workspace.aggregate(profile: service.profile).unreadCount == 0)
        workspace.setOnline(false)
        let offline = try #require(workspace.screen(profile: service.profile))
        let offlineCards = workspace.cards(profile: service.profile)
        #expect(!offline.canAct && offline.requests.isEmpty)
        #expect(offline.snapshot?.pendingRequests.isEmpty == true)
        #expect(offlineCards.allSatisfy { $0.isOffline && $0.status == nil })
        #expect(workspace.aggregate(profile: service.profile).hasUnknownActivity)
    }

    @Test func lateCreationIsRetainedWithoutSelectingAndDuplicateCaptureDispatchesOnce() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        let create = try #require(workspace.captureCreation(a.owner))
        #expect(workspace.captureCreation(a.owner) == nil)
        let gate = WorkspaceGate(); service.createGate = gate
        let creating = Task { await workspace.create(create) }
        await gate.entered()
        let bID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(bID, owner: a.owner)))
        let b = try #require(workspace.screen(profile: service.profile))
        gate.release(); await creating.value
        await workspace.create(create)
        let after = try #require(workspace.screen(profile: service.profile))
        let afterCards = workspace.cards(profile: service.profile)
        #expect(service.creates.count == 1 && afterCards.count == 3)
        #expect(after.selectedChatID == bID && after.epoch == b.epoch)
    }

    @Test func pendingImportRetiresButCompletedFilesSurviveSwitchUntilRecovery() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        await workspace.upload(Data([1]), filename: "kept", mimeType: "text/plain", to: try #require(workspace.captureImport(a.owner)))
        let queued = try #require(workspace.captureImport(a.owner))
        let bID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(bID, owner: a.owner)))
        await workspace.upload(Data([2]), filename: "stale", mimeType: "text/plain", to: queued)
        let b = try #require(workspace.screen(profile: service.profile))
        await workspace.select(try #require(workspace.captureSelection(a.selectedChatID, owner: b.owner)))
        let returned = try #require(workspace.screen(profile: service.profile))
        #expect(returned.attachments.map(\.name) == ["kept"] && !returned.needsReattachment)
        #expect(service.uploads.count == 1)
        workspace.retireConnection(); workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let recovered = try #require(workspace.screen(profile: service.profile))
        #expect(recovered.needsReattachment && recovered.attachments.count == 1)
        #expect(workspace.captureSend(recovered.owner) == nil)
    }

    @Test func cachedCardsRemainSelectableOfflineAndMissingRemoteKeepsReadableRecord() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        let aCards = workspace.cards(profile: service.profile)
        await workspace.refreshDirectory(a.owner)
        let bID = try #require(aCards.first { !$0.isMain }?.id ?? workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(bID, owner: a.owner)))
        let b = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("cached B draft", owner: b.owner)
        workspace.setOnline(false)
        let offlineB = try #require(workspace.screen(profile: service.profile))
        let offlineBCards = workspace.cards(profile: service.profile)
        #expect(offlineBCards.allSatisfy { $0.isAvailable })
        await workspace.select(try #require(workspace.captureSelection(a.selectedChatID, owner: offlineB.owner)))
        let offlineA = try #require(workspace.screen(profile: service.profile))
        #expect(offlineA.snapshot?.messages.first?.text == "Bot Chat" && !offlineA.canAct)
        await workspace.select(try #require(workspace.captureSelection(bID, owner: offlineA.owner)))
        let restored = try #require(workspace.screen(profile: service.profile))
        #expect(workspace.draft(restored.owner) == "cached B draft")
        #expect(restored.snapshot?.messages.first?.text == "Other")
        #expect(service.opens.count == 2)
    }

    @Test func unresolvedLegacyCardOpensReadOnlyBesideProvenMain() async throws {
        let service = try WorkspaceTestService()
        var history = LocalHistory()
        try history.fixtureDraft("unverified draft", profile: service.profile.text)
        try history.fixtureConversation(.init(id: "legacy-runtime", storedID: "unproven-tip", profileID: service.profile.text,
            messages: [.init(id: "legacy-message", role: .assistant, text: "Preserved transcript")]), profile: service.profile.text)
        let old = try #require(history.book.opening(service.profile))
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: history.book, service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        let mainCards = workspace.cards(profile: service.profile)
        #expect(main.selectedChatID != old && mainCards.first { $0.id == old }?.isAvailable == true)
        await workspace.select(try #require(workspace.captureSelection(old, owner: main.owner)))
        let recovered = try #require(workspace.screen(profile: service.profile))
        #expect(recovered.snapshot?.messages.first?.text == "Preserved transcript")
        #expect(workspace.draft(recovered.owner) == "unverified draft" && !recovered.canAct)
        #expect(recovered.error?.contains("read-only") == true)
        #expect(workspace.captureSend(recovered.owner) == nil && service.opens.count == 1)
    }

    @Test func draftRevisionTracksExactUnicodeEditsAndUndo() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("é", owner: screen.owner)
        let first = try #require(workspace.screen(profile: service.profile))
        let firstRevision = try #require(workspace.persisted().record(first.selectedChatID)?.draft.revision)
        workspace.editDraft("e\u{301}", owner: first.owner)
        let second = try #require(workspace.screen(profile: service.profile))
        let secondRevision = try #require(workspace.persisted().record(second.selectedChatID)?.draft.revision)
        #expect(Data(workspace.draft(second.owner).utf8) == Data([0x65, 0xcc, 0x81]))
        #expect(secondRevision != firstRevision)
        workspace.editDraft("é", owner: second.owner)
        let undone = try #require(workspace.screen(profile: service.profile))
        let undoneRevision = try #require(workspace.persisted().record(undone.selectedChatID)?.draft.revision)
        #expect(Data(workspace.draft(undone.owner).utf8) == Data([0xc3, 0xa9]))
        #expect(undoneRevision != firstRevision && undoneRevision != secondRevision)
        workspace.editDraft("é", owner: undone.owner)
        #expect(workspace.persisted().record(undone.selectedChatID)?.draft.revision == undoneRevision)
    }

    @Test func uncertainCreationRequiresInventoryBeforeAnotherDeliberateCreate() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        #expect(screen.canCreate)
        service.createError = HermesServiceError.uncertain
        let intent = try #require(workspace.captureCreation(screen.owner))
        #expect(workspace.screen(profile: service.profile)?.canCreate == false)
        await workspace.create(intent)
        await workspace.create(intent)
        let uncertain = try #require(workspace.screen(profile: service.profile))
        #expect(!uncertain.canCreate && workspace.captureCreation(uncertain.owner) == nil)
        #expect(service.creates.count == 1)
        await workspace.refreshDirectory(uncertain.owner)
        #expect(workspace.screen(profile: service.profile)?.canCreate == true)
        #expect(service.creates.count == 1)
    }

    @Test func lightweightActivityClearsRetiredSiblingWaitingWithoutDirectoryPaging() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        service.snapshots[main.root]?.pendingRequests = [.init(id: "approval", kind: .approval, title: "Waiting")]
        service.directoryActivity[main] = .known(.waiting, .now)
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo", status: .waiting)])
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        let bID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(bID, owner: a.owner)))
        let b = try #require(workspace.screen(profile: service.profile))
        let reads = service.directoryCalls
        #expect(workspace.aggregate(profile: service.profile).attentionChat == a.selectedChatID)
        workspace.applyActivity(profile: service.profile, observations: [main: .known(.idle, .now.addingTimeInterval(1))])
        #expect(workspace.aggregate(profile: service.profile).status == .idle)
        #expect(workspace.aggregate(profile: service.profile).attentionChat == nil)
        workspace.applyActivity(profile: service.profile, observations: [main: .unknown("Ambiguous runtime")])
        #expect(workspace.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(workspace.aggregate(profile: service.profile).status == nil)
        #expect(workspace.cards(profile: service.profile).first { $0.id == a.selectedChatID }?.status == nil)
        #expect(service.directoryCalls == reads && workspace.screen(profile: service.profile)?.epoch == b.epoch)
        #expect(workspace.persisted().record(a.selectedChatID)?.seen == nil)
    }

    @Test func activityRejectsForeignProfilesOldSamplesAndSelectedSnapshotOverrides() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        service.snapshots[main.root]?.pendingRequests = [.init(id: "approval", kind: .approval, title: "Waiting")]
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        workspace.applyActivity(profile: service.profile, observations: [main: .known(.idle, .distantFuture)])
        #expect(workspace.aggregate(profile: service.profile).attentionChat == a.selectedChatID)
        let bID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(bID, owner: a.owner)))
        let sampled = Date.now.addingTimeInterval(1)
        workspace.applyActivity(profile: service.profile, observations: [main: .known(.idle, sampled)])
        workspace.applyActivity(profile: service.profile, observations: [main: .known(.waiting, sampled.addingTimeInterval(-10))])
        workspace.applyActivity(profile: try ExactID("foreign"), observations: [main: .known(.waiting, .distantFuture)])
        let foreign = SessionIdentity(profile: try ExactID("foreign"), root: main.root, stored: main.stored, aliases: [])
        workspace.applyActivity(profile: service.profile, observations: [foreign: .known(.waiting, .distantFuture)])
        #expect(workspace.aggregate(profile: service.profile).attentionChat == nil)
        #expect(workspace.cards(profile: service.profile).count == 2)
    }

    @Test func directoryReadsCoalesceAndLateOrPartialResultsPreserveCurrentAndCachedRecords() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        let bID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        let baselineReads = service.directoryCalls
        let gate = WorkspaceGate(); service.directoryGate = gate
        let first = Task { await workspace.refreshDirectory(a.owner) }
        await gate.entered()
        var secondStarted = false
        let second = Task { secondStarted = true; await workspace.refreshDirectory(a.owner) }
        while !secondStarted { await Task.yield() }
        #expect(service.directoryCalls == baselineReads + 1)
        let extra = SessionIdentity(profile: service.profile, root: try ExactID("new-root"), stored: try ExactID("new-tip"), aliases: [])
        service.summaries.append(.init(identity: extra, title: "New", isCanonical: false, persistence: .durable))
        await workspace.select(try #require(workspace.captureSelection(bID, owner: a.owner)))
        let b = try #require(workspace.screen(profile: service.profile))
        gate.release(); await first.value; await second.value
        #expect(workspace.cards(profile: service.profile).count == 2)
        #expect(workspace.screen(profile: service.profile)?.epoch == b.epoch)
        service.directoryGate = nil
        await workspace.refreshDirectory(b.owner)
        #expect(workspace.cards(profile: service.profile).count == 3)
        service.summaries = [service.summaries[0]]; service.directoryComplete = false
        await workspace.refreshDirectory(b.owner)
        #expect(workspace.cards(profile: service.profile).count == 3)
        #expect(workspace.screen(profile: service.profile)?.snapshot?.messages.first?.text == "Other")
        #expect(workspace.screen(profile: service.profile)?.directoryComplete == false)
        service.directoryError = HermesServiceError.timeout
        await workspace.refreshDirectory(b.owner)
        #expect(workspace.cards(profile: service.profile).count == 3)
    }

    @Test func preferredBotEntryAndExactAttentionChooseIndependentChats() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        service.snapshots[main.root]?.pendingRequests = [.init(id: "approval", kind: .approval, title: "Waiting")]
        service.directoryActivity[main] = .known(.waiting, .now)
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        let bID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        workspace.preferOpening(bID, owner: a.owner)
        let opening = try #require(workspace.captureOpening(profile: service.profile))
        await workspace.open(opening)
        #expect(workspace.screen(profile: service.profile)?.selectedChatID == bID)
        let attention = try #require(workspace.captureOpening(profile: service.profile, attention: true))
        await workspace.open(attention)
        #expect(workspace.screen(profile: service.profile)?.selectedChatID == a.selectedChatID)
        #expect(workspace.screen(profile: service.profile)?.requests.first?.request.id == "approval")
        #expect(workspace.persisted().preference(service.profile)?.preferred == bID)
        #expect(service.summaries.first { $0.isCanonical }?.identity == main)
    }

    @Test func lateOpenedSnapshotCannotReplaceNewerSelectionAndCurrentOwnerCanStillSend() async throws {
        let (workspace, service) = try fixture()
        let gate = WorkspaceGate(); service.openGate = gate
        let old = Task { await workspace.openBot(profile: service.profile) }
        await gate.entered()
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        let bID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        service.openGate = nil
        await workspace.select(try #require(workspace.captureSelection(bID, owner: a.owner)))
        let b = try #require(workspace.screen(profile: service.profile))
        gate.release(); await old.value
        #expect(workspace.screen(profile: service.profile)?.selectedChatID == bID)
        #expect(workspace.screen(profile: service.profile)?.epoch == b.epoch)
        workspace.editDraft("current B", owner: b.owner)
        await workspace.send(try #require(workspace.captureSend(b.owner)))
        #expect(service.sends.count == 1)
        #expect(service.sends.first?.2.profile == service.profile)
        #expect(service.sends.first?.2.root.text == "other-root" && service.sends.first?.2.stored.text == "other-tip")
        #expect(workspace.screen(profile: service.profile)?.error == nil)
    }

    @Test func positiveACKWithLocalJournalRepairRemainsAcceptedAndDoesNotEncourageResend() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("accepted", owner: screen.owner)
        let initialRevision = try #require(workspace.persisted().record(screen.selectedChatID)?.draft.revision)
        service.journal = .needsLocalRepair
        let intent = try #require(workspace.captureSend(screen.owner))
        await workspace.send(intent); await workspace.send(intent)
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(workspace.draft(after.owner).isEmpty && workspace.persisted().record(after.selectedChatID)?.draft.revision != initialRevision)
        #expect(after.error?.contains("accepted") == true && after.error?.contains("Don’t resend") == true)
        #expect(service.sends.count == 1)
    }

    @Test func oldDirectorySampleCannotRestoreWaitingAfterNewerActivityClearsIt() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        let bID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(bID, owner: a.owner)))
        let b = try #require(workspace.screen(profile: service.profile))
        let now = Date.now
        workspace.applyActivity(profile: service.profile, observations: [main: .known(.idle, now)])
        service.directoryActivity[main] = .known(.waiting, now.addingTimeInterval(-60))
        await workspace.refreshDirectory(b.owner)
        #expect(workspace.aggregate(profile: service.profile).attentionChat == nil)
        #expect(workspace.cards(profile: service.profile).first { $0.id == a.selectedChatID }?.status == .idle)
    }

    @Test func disappearedCachedChatRemainsReadableWithUnknownActivityAndNoActions() async throws {
        let (workspace, service) = try fixture()
        let other = service.summaries[1].identity
        service.snapshots[other.root]?.pendingRequests = [.init(id: "old-approval", kind: .approval, title: "Old waiting")]
        service.directoryActivity[other] = .known(.waiting, .now)
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let otherID = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(otherID, owner: main.owner)))
        let cached = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("kept unavailable draft", owner: cached.owner)
        await workspace.select(try #require(workspace.captureSelection(main.selectedChatID, owner: cached.owner)))
        let returned = try #require(workspace.screen(profile: service.profile))
        service.summaries.removeAll { !$0.isCanonical }
        await workspace.refreshDirectory(returned.owner)
        #expect(workspace.cards(profile: service.profile).first { $0.id == otherID }?.status == nil)
        #expect(workspace.aggregate(profile: service.profile).attentionChat == nil)
        await workspace.select(try #require(workspace.captureSelection(otherID, owner: returned.owner)))
        let unavailable = try #require(workspace.screen(profile: service.profile))
        let unavailableCards = workspace.cards(profile: service.profile)
        #expect(unavailable.snapshot?.messages.first?.text == "Other")
        #expect(workspace.draft(unavailable.owner) == "kept unavailable draft")
        #expect(!unavailable.canAct && unavailable.requests.isEmpty && unavailableCards.count == 2)
    }

}

@MainActor struct ConversationSummaryTests {
    @Test func canonicallyEquivalentProfileNamesKeepIndependentSummaries() throws {
        let service = try WorkspaceTestService()
        let composed = try ExactID("é"), decomposed = try ExactID("e\u{301}")
        var book = ConversationBook()
        let first = book.ensureProfile(composed), second = book.ensureProfile(decomposed)
        book.cache(.init(id: "one", storedID: "one", profileID: composed.text,
            messages: [.init(id: "one", role: .user, text: "First question")]), for: first)
        book.cache(.init(id: "two", storedID: "two", profileID: decomposed.text,
            messages: [.init(id: "two", role: .assistant, text: "Second reply")]), for: second)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        #expect(workspace.aggregate(profile: composed).count == 1)
        #expect(workspace.aggregate(profile: decomposed).count == 1)
        #expect(workspace.cards(profile: composed).map(\.id) == [first])
        #expect(workspace.cards(profile: decomposed).map(\.id) == [second])
        #expect(workspace.cards(profile: composed).first?.userPreview == "First question")
        #expect(workspace.cards(profile: decomposed).first?.replyPreview == "Second reply")
    }

    @Test func completeKnownDirectorySuppressesRosterFallbackAndPartialOrUnknownDirectoryRetainsIt() async throws {
        let service = try WorkspaceTestService(), profile = service.profile
        let other = service.summaries[1].identity
        service.directoryActivity[other] = .known(.idle, .distantFuture)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.observeProfiles([.init(id: profile.text, name: "Milo", status: .waiting)])
        workspace.setOnline(true)
        await workspace.openBot(profile: profile)
        let owner = try #require(workspace.screen(profile: profile)?.owner)
        await workspace.refreshDirectory(owner)
        #expect(workspace.aggregate(profile: profile).directoryComplete)
        #expect(workspace.aggregate(profile: profile).status == .idle)
        service.directoryComplete = false
        await workspace.refreshDirectory(owner)
        #expect(!workspace.aggregate(profile: profile).directoryComplete)
        #expect(workspace.aggregate(profile: profile).status == .waiting)
        #expect(workspace.aggregate(profile: profile).attentionChat == nil)
        workspace.observeProfiles([.init(id: profile.text, name: "Milo", status: .working)])
        #expect(workspace.aggregate(profile: profile).status == .working)
        workspace.observeProfiles([.init(id: profile.text, name: "Milo", status: .idle)])
        #expect(workspace.aggregate(profile: profile).status == .idle)
        service.directoryComplete = true
        service.directoryActivity[other] = .unknown("Unavailable")
        await workspace.refreshDirectory(owner)
        #expect(workspace.aggregate(profile: profile).status == nil)
        #expect(workspace.aggregate(profile: profile).hasUnknownActivity)
        workspace.observeProfiles([.init(id: profile.text, name: "Milo", status: .waiting)])
        #expect(workspace.aggregate(profile: profile).status == .waiting)
        #expect(workspace.aggregate(profile: profile).attentionChat == nil)
        service.directoryActivity[other] = .known(.working, .distantFuture)
        await workspace.refreshDirectory(owner)
        #expect(workspace.aggregate(profile: profile).status == .working)
        #expect(!workspace.aggregate(profile: profile).hasUnknownActivity)
    }

    @Test func summariesKeepExactProfilesMainOrderingUnreadEvidenceAndActivityFresh() async throws {
        let service = try WorkspaceTestService(), profile = service.profile
        let foreign = try ExactID("foreign"), at = Date(timeIntervalSince1970: 100)
        var book = ConversationBook()
        let mainIdentity = service.summaries[0].identity, otherIdentity = service.summaries[1].identity
        let main = book.merge(service.summaries[0]), other = book.merge(service.summaries[1])
        let emptyKey = try ExactID("empty")
        let emptyIdentity = SessionIdentity(profile: profile, root: emptyKey, stored: emptyKey, aliases: [])
        let empty = book.merge(.init(identity: emptyIdentity, title: "Draft", isCanonical: false, persistence: .liveOnly, messageCount: 0))
        let content = Conversation(id: "cached", storedID: mainIdentity.stored.text, profileID: profile.text,
            messages: [.init(id: "user", role: .user, text: "Question"),
                       .init(id: "reply", role: .assistant, text: "é", timestamp: at)] +
                (0..<100).map { .init(id: "tool-\($0)", role: .tool, text: "Tool output") })
        book.cache(content, for: main)
        book.update(main) { $0.displayed(content, acknowledging: nil, at: at); $0.discoveryOrdinal = 50 }
        var changed = content
        changed.storedID = otherIdentity.stored.text
        book.cache(changed, for: other)
        book.update(other) { $0.displayed(changed, acknowledging: nil, at: at); $0.discoveryOrdinal = 1 }
        changed.messages[1].text = "e\u{301}"
        book.cache(changed, for: other)
        book.cache(.init(id: "empty", storedID: emptyKey.text, profileID: profile.text), for: empty)
        book.updatePreference(profile) { $0.preferred = empty }
        let excluded = book.ensureProfile(foreign)
        book.cache(.init(id: "foreign", storedID: "foreign", profileID: foreign.text,
            messages: [.init(id: "foreign", role: .assistant, text: "Do not include")]), for: excluded)
        book.records.reverse()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        var aggregate = workspace.aggregate(profile: profile)
        #expect(aggregate.count == 3 && aggregate.unreadCount == 1)
        #expect(aggregate.status == nil && aggregate.hasUnknownActivity && aggregate.attentionChat == nil)
        let screen = try #require(workspace.screen(profile: profile))
        let screenCards = workspace.cards(profile: profile)
        #expect(screenCards.map(\.id) == [main, other, empty])
        #expect(screen.selectedChatID == empty && screenCards.last?.isPreferred == true)
        #expect(screenCards.first?.userPreview == "Question" && screenCards.first?.replyPreview == "é")
        #expect(screenCards.first?.unread == false && screenCards[1].unread)
        #expect(screenCards[1].replyPreview.utf8.elementsEqual("e\u{301}".utf8))
        #expect(workspace.aggregate(profile: foreign).count == 1)
        workspace.setOnline(true)
        workspace.observeProfiles([.init(id: profile.text, name: "Milo", status: .waiting)])
        aggregate = workspace.aggregate(profile: profile)
        #expect(aggregate.status == .waiting && aggregate.attentionChat == nil && aggregate.hasUnknownActivity)
        workspace.applyActivity(profile: profile, observations: [mainIdentity: .known(.waiting, at),
            otherIdentity: .known(.waiting, at), emptyIdentity: .known(.idle, at)])
        aggregate = workspace.aggregate(profile: profile)
        #expect(aggregate.attentionChat == main && aggregate.status == .waiting && !aggregate.hasUnknownActivity)
        #expect(workspace.aggregates(profiles: [profile, foreign])[profile]?.attentionChat == main)
        await confirmation("Aggregate reads observe subsequent activity") { changed in
            withObservationTracking { _ = workspace.aggregate(profile: profile) } onChange: { changed() }
            workspace.applyActivity(profile: profile, observations: [mainIdentity: .known(.idle, at.addingTimeInterval(1))])
        }
        #expect(workspace.aggregate(profile: profile).attentionChat == other)
        #expect(workspace.aggregates(profiles: [profile, foreign])[profile]?.attentionChat == other)
        workspace.applyActivity(profile: profile, observations: [otherIdentity: .unknown("Unavailable")])
        aggregate = workspace.aggregate(profile: profile)
        #expect(aggregate.status == nil && aggregate.attentionChat == nil && aggregate.hasUnknownActivity)
        #expect(workspace.cards(profile: profile)[1].status == nil)
        #expect(workspace.aggregate(profile: profile).unreadCount == 1)
        workspace.setOnline(false)
        #expect(workspace.cards(profile: profile).allSatisfy { $0.status == nil && $0.isOffline } == true)
    }

    @Test func batchedOrderingKeepsExactProfilesAndMainBeforeEarlierSiblings() throws {
        var book = ConversationBook()
        let composed = try ExactID("é"), decomposed = try ExactID("e\u{301}")
        let main = book.ensureProfile(composed)
        let distinct = book.ensureProfile(decomposed)
        book.update(main) { $0.discoveryOrdinal = 50 }
        let sibling = ChatRecord(id: ChatID(), profile: composed,
            binding: .provisionalMain(legacyStored: nil), discoveryOrdinal: 1)
        book.records.insert(sibling, at: 0)
        book.records.reverse()
        let grouped = book.orderedByProfile()
        #expect(grouped.count == 2)
        #expect(grouped[composed]?.map(\.id) == [main, sibling.id])
        #expect(grouped[decomposed]?.map(\.id) == [distinct])
    }
}
