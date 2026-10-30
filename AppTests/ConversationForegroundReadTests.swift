import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationForegroundReadTests {
    private func fixture() async throws -> (ConversationWorkspace, WorkspaceTestService, ChatScreen) {
        let service = try WorkspaceTestService()
        let old = service.summaries[0]
        service.summaries[0] = summary(old.identity, count: 4)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner); workspace.displayed(screen.owner)
        #expect(workspace.persisted().record(screen.selectedChatID)?.isUnread == false)
        service.summaries[0] = summary(old.identity, count: 6)
        return (workspace, service, screen)
    }
    private func summary(_ identity: SessionIdentity, count: Int? = 6, preview: String = "First prompt", date: Date? = nil,
                         title: String = "Bot Chat") -> SessionSummary {
        .init(identity: identity, title: title, isCanonical: true, persistence: .durable,
              preview: preview, updatedAt: date, messageCount: count)
    }
    private func current(_ workspace: ConversationWorkspace, _ service: WorkspaceTestService) throws -> ChatScreen {
        try #require(workspace.screen(profile: service.profile))
    }
    private func settled(_ workspace: ConversationWorkspace, _ service: WorkspaceTestService) async throws -> ChatScreen {
        for _ in 0..<1000 {
            if workspace.screen(profile: service.profile)?.isOpening == false { return try current(workspace, service) }
            await Task.yield()
        }
        Issue.record("Workspace read did not settle"); return try current(workspace, service)
    }

    @Test(arguments: [true, false])
    func pickerCoverageWaitsAndReadInstallationRequiresFreshVisibleDisplay(_ directoryFirst: Bool) async throws {
        let (workspace, service, before) = try await fixture()
        workspace.editDraft("  draft e\u{301}\n", owner: before.owner)
        let draft = workspace.persisted().record(before.selectedChatID)?.draft
        let preferences = workspace.persisted().preference(service.profile)
        var retirements = 0; workspace.onPresentationChange = { retirements += 1 }
        workspace.setTranscriptVisible(false, owner: before.owner)
        let gate = WorkspaceGate(); service.openGate = gate
        if directoryFirst { await workspace.refreshDirectory(before.owner) }
        else {
            // A full natural read with the old catalog may arrive before the directory.
            workspace.receive(try service.publication(service.summaries[0].identity))
            await workspace.refreshDirectory(try current(workspace, service).owner)
        }
        let covered = try current(workspace, service)
        let coveredCards = workspace.cards(profile: service.profile)
        #expect(service.opens.count == 1 && coveredCards.first?.unread == true)
        workspace.setTranscriptVisible(true, owner: covered.owner)
        let reading = try current(workspace, service)
        #expect(reading.isOpening && !reading.canAct && reading.canEditDraft)
        #expect(reading.selectedViewLifetime == before.selectedViewLifetime)
        #expect(!workspace.isCurrent(covered.owner))
        await gate.entered()
        workspace.setTranscriptVisible(false, owner: reading.owner) // User opens picker during read.
        await workspace.refreshDirectory(reading.owner)
        #expect(workspace.persisted().record(before.selectedChatID)?.seen?.summary?.messageCount == 4)
        gate.release()
        let installed = try await settled(workspace, service)
        let installedCards = workspace.cards(profile: service.profile)
        #expect(installed.snapshot == before.snapshot, "Identical transcript still gets a fresh owner callback")
        #expect(installed.epoch != reading.epoch && installed.selectedViewLifetime == reading.selectedViewLifetime)
        #expect(retirements == (directoryFirst ? 2 : 3))
        #expect(installedCards.first?.unread == true && installed.canAct)
        workspace.setTranscriptVisible(true, owner: reading.owner) // Queued old callback cannot display.
        #expect(workspace.persisted().record(before.selectedChatID)?.seen?.summary?.messageCount == 4)
        workspace.setTranscriptVisible(true, owner: installed.owner)
        #expect(workspace.persisted().record(before.selectedChatID)?.seen?.summary?.messageCount == 6)
        #expect(workspace.persisted().record(before.selectedChatID)?.isUnread == false)
        #expect(workspace.persisted().record(before.selectedChatID)?.draft.revision == draft?.revision)
        #expect(workspace.draft(installed.owner) == draft?.text)
        #expect(workspace.persisted().preference(service.profile)?.lastSelected == preferences?.lastSelected)
        #expect(workspace.persisted().preference(service.profile)?.preferred == preferences?.preferred)
        #expect(service.opens.count == 2 && service.sends.isEmpty && service.creates.isEmpty)
    }

    @Test(arguments: [true, false])
    func matchingCurrentWitnessNeedsNoOptionalReadInEitherCallbackOrder(_ directoryFirst: Bool) async throws {
        let (workspace, service, initial) = try await fixture()
        if directoryFirst { await workspace.refreshDirectory(initial.owner) }
        workspace.receive(try service.fullReadPublication(service.summaries[0].identity))
        let read = try current(workspace, service)
        if !directoryFirst { await workspace.refreshDirectory(read.owner) }
        #expect(workspace.persisted().record(initial.selectedChatID)?.isUnread == true)
        workspace.setTranscriptVisible(true, owner: read.owner)
        #expect(workspace.persisted().record(initial.selectedChatID)?.isUnread == false)
        #expect(service.opens.count == 1)
    }

    @Test func naturalCompleteReadThenNilDeltaDoesNotStrandTheOptionalAttempt() async throws {
        let (workspace, service, initial) = try await fixture()
        await workspace.refreshDirectory(initial.owner)
        workspace.receive(try service.fullReadPublication(service.summaries[0].identity))
        workspace.receive(try service.publication(service.summaries[0].identity))
        let gate = WorkspaceGate(); service.openGate = gate
        workspace.setTranscriptVisible(true, owner: try current(workspace, service).owner)
        await gate.entered()
        #expect(service.opens.count == 2)
        #expect(workspace.persisted().record(initial.selectedChatID)?.isUnread == true)
        gate.release()
        let installed = try await settled(workspace, service)
        workspace.setTranscriptVisible(true, owner: installed.owner)
        #expect(workspace.persisted().record(initial.selectedChatID)?.isUnread == false)
    }

    @Test func nilEvidenceConsumesEachExactKeyAcrossOwnAndOrdinaryRotationsAndABA() async throws {
        let (workspace, service, initial) = try await fixture()
        service.readSummaryAvailable = false
        let identity = service.summaries[0].identity
        for (count, expectedOpens) in [(6, 2), (8, 3), (6, 3)] {
            service.summaries[0] = summary(identity, count: count)
            let before = try current(workspace, service)
            await workspace.refreshDirectory(before.owner)
            workspace.setTranscriptVisible(true, owner: before.owner)
            let after = try await settled(workspace, service)
            let afterCards = workspace.cards(profile: service.profile)
            #expect(after.selectedViewLifetime == initial.selectedViewLifetime)
            #expect(afterCards.first?.unread == true)
            for _ in 0..<5 {
                await workspace.refreshDirectory(try current(workspace, service).owner)
                workspace.setTranscriptVisible(true, owner: try current(workspace, service).owner)
            }
            workspace.receive(try service.publication(identity))
            workspace.setTranscriptVisible(true, owner: try current(workspace, service).owner)
            #expect(service.opens.count == expectedOpens)
        }
    }

    @Test func bytePreviewOpaqueCountAndDateEarnAttemptsButTitleAndActivityDoNot() async throws {
        let (workspace, service, initial) = try await fixture()
        service.readSummaryAvailable = false
        let identity = service.summaries[0].identity
        let variants = [summary(identity, preview: "é"), summary(identity, preview: "e\u{301}"),
            summary(identity, count: nil, preview: "e\u{301}"),
            summary(identity, count: nil, preview: "e\u{301}", date: Date(timeIntervalSince1970: 1))]
        for (index, value) in variants.enumerated() {
            service.summaries[0] = value
            await workspace.refreshDirectory(try current(workspace, service).owner)
            workspace.setTranscriptVisible(true, owner: try current(workspace, service).owner)
            _ = try await settled(workspace, service)
            #expect(service.opens.count == index + 2)
        }
        service.summaries[0] = summary(identity, count: nil, preview: "e\u{301}", date: Date(timeIntervalSince1970: 1), title: "Renamed")
        service.directoryActivity[identity] = .known(.idle, .distantFuture)
        await workspace.refreshDirectory(try current(workspace, service).owner)
        workspace.setTranscriptVisible(true, owner: try current(workspace, service).owner)
        #expect(service.opens.count == 5)
        #expect(workspace.persisted().record(initial.selectedChatID)?.seen?.summary?.messageCount == 4)
    }

    @Test func directoryDuringReadCannotBackfillAndLatestObservationGetsItsOwnRead() async throws {
        let (workspace, service, initial) = try await fixture()
        await workspace.refreshDirectory(initial.owner)
        let gate = WorkspaceGate(); service.openGate = gate
        workspace.setTranscriptVisible(true, owner: initial.owner); await gate.entered()
        service.summaries[0] = summary(service.summaries[0].identity, count: 9)
        await workspace.refreshDirectory(try current(workspace, service).owner)
        gate.release(); service.openGate = nil
        let first = try await settled(workspace, service)
        #expect(workspace.persisted().record(initial.selectedChatID)?.seen?.summary?.messageCount == 4)
        workspace.displayed(first.owner)
        #expect(workspace.persisted().record(initial.selectedChatID)?.seen?.summary?.messageCount == 4)
        workspace.setTranscriptVisible(true, owner: first.owner)
        let next = try await settled(workspace, service)
        workspace.setTranscriptVisible(true, owner: next.owner)
        #expect(workspace.persisted().record(initial.selectedChatID)?.seen?.summary?.messageCount == 9)
        #expect(service.opens.count == 3)
    }

    @Test(arguments: ["profile", "root", "tip"])
    func namespaceMismatchNeverAutoFollowsOrChangesPreferences(_ mismatch: String) async throws {
        let (workspace, service, initial) = try await fixture()
        let old = service.summaries[0].identity
        let changed = SessionIdentity(profile: mismatch == "profile" ? try ExactID("foreign") : old.profile,
            root: mismatch == "root" ? try ExactID("foreign-root") : old.root,
            stored: mismatch == "tip" ? try ExactID("foreign-tip") : old.stored, aliases: [])
        service.summaries[0] = summary(changed)
        await workspace.refreshDirectory(initial.owner)
        workspace.setTranscriptVisible(true, owner: initial.owner)
        #expect(service.opens.count == 1)
        #expect(workspace.screen(profile: service.profile)?.selectedChatID == initial.selectedChatID)
        #expect(workspace.persisted().preference(service.profile)?.lastSelected == initial.selectedChatID)
    }

    @Test func activityAndPersistedSummaryAloneCannotRequestARead() async throws {
        let (workspace, service, initial) = try await fixture()
        await workspace.refreshDirectory(initial.owner)
        let book = workspace.persisted()
        let restored = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        restored.setOnline(true); service.readSummaryAvailable = false
        await restored.openBot(profile: service.profile)
        let owner = try #require(restored.screen(profile: service.profile)?.owner)
        restored.applyActivity(profile: service.profile, observations: [service.summaries[0].identity: .known(.idle, .now)])
        restored.setTranscriptVisible(true, owner: owner)
        #expect(service.opens.count == 2)
        #expect(restored.screen(profile: service.profile)?.isOpening == false)
        await restored.refreshDirectory(owner)
        restored.setTranscriptVisible(true, owner: owner)
        _ = try await settled(restored, service)
        #expect(service.opens.count == 3)
    }
}
