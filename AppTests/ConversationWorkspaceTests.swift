import Foundation
import Observation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationWorkspaceTests {
    @Test(arguments: [false, true])
    func inventoryBookkeepingNotifiesAggregatesAndPersistenceWithoutInvalidatingSelectedScreen(activity: Bool) async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner)
        let rendered = try #require(screen.snapshot)
        let sibling = service.summaries[1].identity
        await confirmation("Inventory bookkeeping does not change selected-screen facts", expectedCount: 0) { changed in
            withObservationTracking {
                _ = workspace.screen(profile: service.profile)
                _ = workspace.selection(profile: service.profile)
                _ = workspace.canEditDraft(screen.owner)
                _ = workspace.draft(screen.owner)
            } onChange: { changed() }
            await confirmation("Aggregates and persistence remain observed", expectedCount: 2) { changed in
                withObservationTracking { _ = workspace.aggregate(profile: service.profile) } onChange: { changed() }
                withObservationTracking { _ = workspace.persisted() } onChange: { changed() }
                if activity {
                    workspace.applyActivity(profile: service.profile, observations: [sibling: .known(.waiting, .distantFuture)])
                } else { workspace.displayed(screen.owner) }
            }
            #expect(workspace.screen(profile: service.profile)?.owner == screen.owner)
            if activity {
                #expect(workspace.aggregate(profile: service.profile).attentionChat == workspace.chats(service.profile).last?.id)
                #expect(workspace.persisted().records.first { $0.id != screen.owner.chat }?.lastKnownActivity?.observedAt == .distantFuture)
            } else {
                #expect(workspace.persisted().record(screen.owner.chat)?.seen?.content == ChatContentEvidence(rendered))
                #expect(workspace.persisted().record(screen.owner.chat)?.isUnread == false)
            }
        }
    }

    @Test(arguments: ["title", "identity", "recovery"])
    func selectedScreenStillObservesStructuralMetadataAndRecovery(change: String) async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        #expect(await workspace.openSaved(service.summaries[1]))
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
        let newcomer = try ExactID("newcomer")
        workspace.editDraft("Keep this draft", owner: screen.owner)
        await confirmation("A newly observed bot reaches presentation and complete readers", expectedCount: 4) { changed in
            withObservationTracking { _ = workspace.screen(profile: service.profile) } onChange: { changed() }
            withObservationTracking { _ = workspace.draft(screen.owner) } onChange: { changed() }
            withObservationTracking { _ = workspace.persisted() } onChange: { changed() }
            withObservationTracking { _ = workspace.openingDraft(profile: service.profile) } onChange: { changed() }
            workspace.observeProfiles([.init(id: service.profile.text, name: "Milo"), .init(id: newcomer.text, name: "Newcomer")])
        }
        #expect(workspace.persisted().preference(newcomer) != nil)
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
        let newcomer = try ExactID("newcomer")
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
            workspace.observeProfiles([.init(id: service.profile.text, name: "Milo"), .init(id: newcomer.text, name: "Newcomer")])
        }
        #expect(workspace.draft(screen.owner) == "Draft from the callback")
        #expect(persistedAtDirty == "Draft from the callback")
        #expect(workspace.persisted().preference(newcomer) != nil)
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
        service.replacementError = ConversationServiceError.uncertain
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
        #expect(await workspace.openSaved(service.summaries[1]))
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
        service.sendError = ConversationServiceError.steeringUnavailable
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
        let bID = try #require(workspace.chats(service.profile).dropFirst().first?.id)
        #expect(await workspace.openSaved(service.summaries[1]))
        let b = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("B thought", owner: b.owner)
        await workspace.send(queued)
        #expect(service.sends.isEmpty)
        #expect(await workspace.openSaved(service.summaries[0]))
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
        let bID = try #require(workspace.chats(service.profile).dropFirst().first?.id)
        #expect(await workspace.openSaved(service.summaries[1]))
        var b = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("B stays", owner: b.owner)
        await workspace.upload(Data([2]), filename: "b.txt", mimeType: "text/plain", to: try #require(workspace.captureImport(b.owner)))
        if retyped {
            #expect(await workspace.openSaved(service.summaries[0]))
            let returned = try #require(workspace.screen(profile: service.profile))
            workspace.editDraft("", owner: returned.owner)
            workspace.editDraft("submitted", owner: returned.owner)
            workspace.removeAttachment(stagedA, owner: returned.owner)
            await workspace.upload(Data([3]), filename: "a.txt", mimeType: "text/plain", to: try #require(workspace.captureImport(returned.owner)))
            #expect(await workspace.openSaved(service.summaries[1]))
            b = try #require(workspace.screen(profile: service.profile))
        }
        let bEpoch = b.epoch
        gate.release(); await sending.value
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.selectedChatID == bID && after.epoch == bEpoch)
        #expect(workspace.draft(after.owner) == "B stays")
        #expect(after.attachments.map(\.name) == ["b.txt"] && after.error == nil)
        #expect(workspace.persisted().record(a.selectedChatID)?.draft.text == (retyped ? "submitted" : ""))
        #expect(await workspace.openSaved(service.summaries[0]))
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
        #expect(!offline.canAct && offline.requests.isEmpty)
        #expect(offline.snapshot?.pendingRequests.isEmpty == true)
        #expect(workspace.aggregate(profile: service.profile).status == nil)
        #expect(workspace.aggregate(profile: service.profile).hasUnknownActivity)
    }

    @Test func pendingImportRetiresButCompletedFilesSurviveSwitchUntilRecovery() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        await workspace.upload(Data([1]), filename: "kept", mimeType: "text/plain", to: try #require(workspace.captureImport(a.owner)))
        let queued = try #require(workspace.captureImport(a.owner))
        #expect(await workspace.openSaved(service.summaries[1]))
        await workspace.upload(Data([2]), filename: "stale", mimeType: "text/plain", to: queued)
        #expect(await workspace.openSaved(service.summaries[0]))
        let returned = try #require(workspace.screen(profile: service.profile))
        #expect(returned.attachments.map(\.name) == ["kept"] && !returned.needsReattachment)
        #expect(service.uploads.count == 1)
        workspace.retireConnection(); workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let recovered = try #require(workspace.screen(profile: service.profile))
        #expect(recovered.needsReattachment && recovered.attachments.count == 1)
        #expect(workspace.captureSend(recovered.owner) == nil)
    }

    @Test func cachedChatsRemainOpenableOfflineWithTheirDrafts() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        #expect(await workspace.openSaved(service.summaries[1]))
        let b = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("cached B draft", owner: b.owner)
        workspace.setOnline(false)
        #expect(await workspace.openSaved(service.summaries[0]))
        let offlineA = try #require(workspace.screen(profile: service.profile))
        #expect(offlineA.snapshot?.messages.first?.text == "Bot Chat" && !offlineA.canAct)
        #expect(await workspace.openSaved(service.summaries[1]))
        let restored = try #require(workspace.screen(profile: service.profile))
        #expect(workspace.draft(restored.owner) == "cached B draft")
        #expect(restored.snapshot?.messages.first?.text == "Other")
        #expect(service.opens.count == 2)
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

    @Test func lightweightActivityClearsRetiredSiblingWaitingWithoutDirectoryPaging() async throws {
        let (workspace, service) = try fixture()
        let main = service.summaries[0].identity
        service.snapshots[main.root]?.pendingRequests = [.init(id: "approval", kind: .approval, title: "Waiting")]
        service.directoryActivity[main] = .known(.waiting, .now)
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo", status: .waiting)])
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        #expect(await workspace.openSaved(service.summaries[1]))
        let b = try #require(workspace.screen(profile: service.profile))
        let reads = service.directoryCalls
        #expect(workspace.aggregate(profile: service.profile).attentionChat == a.selectedChatID)
        workspace.applyActivity(profile: service.profile, observations: [main: .known(.idle, .now.addingTimeInterval(1))])
        #expect(workspace.aggregate(profile: service.profile).status == .idle)
        #expect(workspace.aggregate(profile: service.profile).attentionChat == nil)
        workspace.applyActivity(profile: service.profile, observations: [main: .unknown("Ambiguous runtime")])
        #expect(workspace.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(workspace.aggregate(profile: service.profile).status == nil)
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
        #expect(await workspace.openSaved(service.summaries[1]))
        let sampled = Date.now.addingTimeInterval(1)
        workspace.applyActivity(profile: service.profile, observations: [main: .known(.idle, sampled)])
        workspace.applyActivity(profile: service.profile, observations: [main: .known(.waiting, sampled.addingTimeInterval(-10))])
        workspace.applyActivity(profile: try ExactID("foreign"), observations: [main: .known(.waiting, .distantFuture)])
        let foreign = SessionIdentity(profile: try ExactID("foreign"), root: main.root, stored: main.stored, aliases: [])
        workspace.applyActivity(profile: service.profile, observations: [foreign: .known(.waiting, .distantFuture)])
        #expect(workspace.aggregate(profile: service.profile).attentionChat == nil)
        #expect(workspace.chats(service.profile).count == 2)
    }

    @Test func directoryReadsCoalesceAndLateOrPartialResultsPreserveCurrentAndCachedRecords() async throws {
        let (workspace, service) = try fixture()
        await workspace.openBot(profile: service.profile)
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
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
        #expect(await workspace.openSaved(service.summaries[1]))
        let b = try #require(workspace.screen(profile: service.profile))
        gate.release(); await first.value; await second.value
        #expect(workspace.chats(service.profile).count == 2)
        #expect(workspace.screen(profile: service.profile)?.epoch == b.epoch)
        service.directoryGate = nil
        await workspace.refreshDirectory(b.owner)
        #expect(workspace.chats(service.profile).count == 3)
        service.summaries = [service.summaries[0]]; service.directoryComplete = false
        await workspace.refreshDirectory(b.owner)
        #expect(workspace.chats(service.profile).count == 3)
        #expect(workspace.screen(profile: service.profile)?.snapshot?.messages.first?.text == "Other")
        #expect(workspace.screen(profile: service.profile)?.directoryComplete == false)
        service.directoryError = ConversationServiceError.timeout
        await workspace.refreshDirectory(b.owner)
        #expect(workspace.chats(service.profile).count == 3)
    }

    @Test func lateOpenedSnapshotCannotReplaceNewerSelectionAndCurrentOwnerCanStillSend() async throws {
        let (workspace, service) = try fixture()
        let gate = WorkspaceGate(); service.openGate = gate
        let old = Task { await workspace.openBot(profile: service.profile) }
        await gate.entered()
        let a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        let bID = try #require(workspace.chats(service.profile).dropFirst().first?.id)
        service.openGate = nil
        #expect(await workspace.openSaved(service.summaries[1]))
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
        #expect(await workspace.openSaved(service.summaries[1]))
        let b = try #require(workspace.screen(profile: service.profile))
        let now = Date.now
        workspace.applyActivity(profile: service.profile, observations: [main: .known(.idle, now)])
        service.directoryActivity[main] = .known(.waiting, now.addingTimeInterval(-60))
        await workspace.refreshDirectory(b.owner)
        #expect(workspace.aggregate(profile: service.profile).attentionChat == nil)
    }

    @Test func disappearedCachedChatKeepsItsRecordAndDraftAndLosesItsActivity() async throws {
        let (workspace, service) = try fixture()
        let other = service.summaries[1].identity
        service.snapshots[other.root]?.pendingRequests = [.init(id: "old-approval", kind: .approval, title: "Old waiting")]
        service.directoryActivity[other] = .known(.waiting, .now)
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let otherID = try #require(workspace.chats(service.profile).dropFirst().first?.id)
        #expect(await workspace.openSaved(service.summaries[1]))
        let cached = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("kept unavailable draft", owner: cached.owner)
        #expect(await workspace.openSaved(service.summaries[0]))
        let returned = try #require(workspace.screen(profile: service.profile))
        service.summaries.removeAll { !$0.isCanonical }
        await workspace.refreshDirectory(returned.owner)
        #expect(workspace.aggregate(profile: service.profile).attentionChat == nil)
        #expect(workspace.chats(service.profile).count == 2)
        #expect(workspace.persisted().record(otherID)?.transcript?.messages.first?.text == "Other")
        #expect(workspace.persisted().record(otherID)?.draft.text == "kept unavailable draft")
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
        #expect(workspace.chats(composed).map(\.id) == [first])
        #expect(workspace.chats(decomposed).map(\.id) == [second])
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
        let screenChats = workspace.chats(profile)
        #expect(screenChats.map(\.id) == [main, other, empty])
        #expect(screen.selectedChatID == empty, "A saved opening choice from an older build still opens")
        #expect(screenChats.first?.isUnread == false && screenChats[1].isUnread)
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
        #expect(workspace.aggregate(profile: profile).unreadCount == 1)
        workspace.setOnline(false)
        #expect(workspace.aggregate(profile: profile).status == nil)
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
