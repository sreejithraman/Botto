import Foundation
import Observation
import Testing
import BottoCore
@testable import Botto

@MainActor private final class DisplayObservationEntry {
    var entered = false
}

@MainActor struct ConversationReadEvidenceTests {
    @Test(arguments: ["draft", "publication", "seen", "retirement"])
    func displayCallbacksCannotLoseDraftOrAcknowledgeUnrenderedContent(change: String) async throws {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        let rendered = try #require(screen.snapshot)
        let opened = try #require(service.completedOpens.last)
        var next = rendered
        next.messages.append(.init(id: "not-rendered-yet", role: .assistant, text: "A newer unrendered reply"))
        let publication = OpenedConversation(identity: opened.identity, snapshot: next, access: opened.access)
        let entry = DisplayObservationEntry()
        await confirmation("A guarded observer runs before read bookkeeping") { changed in
            withObservationTracking { _ = workspace.persisted() } onChange: {
                MainActor.assumeIsolated {
                    guard !entry.entered else { return }
                    entry.entered = true
                    changed()
                    switch change {
                    case "draft": workspace.editDraft("Keep this callback draft", owner: screen.owner)
                    case "retirement": workspace.retireConnection()
                    default:
                        workspace.receive(publication)
                        if change == "seen" { workspace.displayed(screen.owner) }
                    }
                }
            }
            workspace.displayed(screen.owner)
        }
        let record = try #require(workspace.persisted().record(screen.owner.chat))
        switch change {
        case "draft":
            #expect(record.draft.text == "Keep this callback draft")
            #expect(record.seen?.content == ChatContentEvidence(rendered))
        case "retirement":
            #expect(record.seen == nil && !workspace.isCurrent(screen.owner))
        case "seen":
            #expect(record.seen?.content == ChatContentEvidence(next))
        default:
            #expect(record.seen?.content == ChatContentEvidence(rendered))
            #expect(record.seen?.content != ChatContentEvidence(next) && record.isUnread)
        }
    }

    private func fixture() async throws -> (ConversationWorkspace, WorkspaceTestService, SessionIdentity) {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.snapshots[identity.root]?.messages = (0..<11).map {
            .init(id: "message-\($0)", role: $0 == 0 ? .user : .assistant,
                  text: $0 == 0 ? "First prompt" : "Reply \($0)", timestamp: Date(timeIntervalSince1970: 100))
        }
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "First prompt", updatedAt: Date(timeIntervalSince1970: 100), messageCount: 3)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let initial = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(initial.owner); workspace.displayed(initial.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
        return (workspace, service, identity)
    }

    @Test(arguments: [99.0, 100.0]) func changedInventoryTipIsUnreadEvenWhenOpaqueFactsAndDisplayedRowsMatch(_ timestamp: Double) async throws {
        let (workspace, service, identity) = try await fixture()
        let replacement = SessionIdentity(profile: identity.profile, root: identity.root,
            stored: try ExactID("compacted-next-tip"), aliases: [identity.stored])
        service.summaries[0] = .init(identity: replacement, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "First prompt", updatedAt: Date(timeIntervalSince1970: timestamp), messageCount: 3)
        let old = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(old.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        workspace.displayed(old.owner); workspace.displayed(old.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        // Positive: an explicit current full read of the new tip can acknowledge it.
        await workspace.openBot(profile: service.profile)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
    }

    @Test func incrementalContentAndAccessRotationCannotAcknowledgeNewDirectoryObservation() async throws {
        let (workspace, service, identity) = try await fixture()
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "First prompt", updatedAt: Date(timeIntervalSince1970: 200), messageCount: 3)
        let old = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(old.owner)
        service.snapshots[identity.root]?.messages.append(.init(id: "delta", role: .assistant, text: "Incremental reply",
            timestamp: Date(timeIntervalSince1970: 200)))
        workspace.receive(try service.publication(identity))
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == true,
            "A delta and a new access grant do not prove a full read after the inventory observation")
        await workspace.openBot(profile: service.profile)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
    }

    enum Mismatch: CaseIterable { case missing, profile, root, tip, previewBytes, count, date }
    @Test(arguments: Mismatch.allCases)
    func missingOrMismatchedWitnessNeverAcknowledgesCurrentInventory(_ mismatch: Mismatch) async throws {
        let (workspace, service, identity) = try await fixture()
        let newAt = Date(timeIntervalSince1970: 200)
        let current = SessionSummary(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "é prompt", updatedAt: newAt, messageCount: 5)
        service.summaries[0] = current
        await workspace.refreshDirectory(try #require(workspace.screen(profile: service.profile)?.owner))
        let wrongIdentity = SessionIdentity(profile: mismatch == .profile ? try ExactID("other-profile") : identity.profile,
            root: mismatch == .root ? try ExactID("other-root") : identity.root,
            stored: mismatch == .tip ? try ExactID("other-tip") : identity.stored, aliases: [])
        let observed = SessionSummary(identity: wrongIdentity, title: "Display title is irrelevant", isCanonical: true, persistence: .durable,
            preview: mismatch == .previewBytes ? "e\u{301} prompt" : current.preview,
            updatedAt: mismatch == .date ? newAt.addingTimeInterval(-1) : newAt,
            messageCount: mismatch == .count ? 4 : 5)
        let evidence = mismatch == .missing ? nil : ConversationReadEvidence(summaryObservedBeforeRead: observed)
        workspace.receive(try service.publication(identity, readEvidence: evidence))
        let screen = try #require(workspace.screen(profile: service.profile))
        workspace.displayed(screen.owner); workspace.displayed(screen.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        // Each rejection has a matching positive through an explicit service full read.
        await workspace.openBot(profile: service.profile)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
    }

    @Test func inventoryArrivingDuringHeldReadCannotBeBackfilledIntoItsWitness() async throws {
        let (workspace, service, identity) = try await fixture()
        let gate = WorkspaceGate(); service.openGate = gate
        let opening = Task { await workspace.openBot(profile: service.profile) }
        await gate.entered()
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "Later directory", messageCount: 99)
        await workspace.refreshDirectory(try #require(workspace.screen(profile: service.profile)?.owner))
        gate.release(); await opening.value; service.openGate = nil
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        await workspace.openBot(profile: service.profile)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
    }

    @Test func firstCanonicalReadSeedsOnlyMissingMetadataAndLaterEnrichmentNeedsMatchingRead() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        // Canonical lookup may know only the opaque count before the read.
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 4)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true); await workspace.openBot(profile: service.profile)
        let initial = try #require(workspace.screen(profile: service.profile))
        let before = workspace.persisted(), preferences = before.preference(service.profile)
        #expect(before.record(initial.selectedChatID)?.summary == nil)
        workspace.displayed(initial.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
        #expect(workspace.persisted().record(initial.selectedChatID)?.summary?.messageCount == 4)
        #expect(workspace.persisted().preference(service.profile)?.main == preferences?.main)
        #expect(workspace.persisted().preference(service.profile)?.lastSelected == preferences?.lastSelected)
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "Enriched first prompt", updatedAt: Date(timeIntervalSince1970: 200), messageCount: 4)
        let seenAt = workspace.persisted().record(initial.selectedChatID)?.seen?.observedAt
        await workspace.refreshDirectory(initial.owner)
        workspace.displayed(initial.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true,
            "Later REST preview/date cannot be retroactively attached to the earlier count-only read")
        #expect(workspace.persisted().record(initial.selectedChatID)?.seen?.observedAt == seenAt)
        await workspace.openBot(profile: service.profile)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
    }

    @Test func staleOwnerAndOfflineRecoveryPublicationCannotAcknowledgeUntilCurrentLiveDisplay() async throws {
        let (workspace, service, identity) = try await fixture()
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "New observation", messageCount: 100)
        let old = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(old.owner)
        let fresh = try service.fullReadPublication(identity)
        workspace.receive(fresh)
        workspace.displayed(old.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        workspace.retireConnection()
        workspace.receive(fresh)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        workspace.setOnline(true); workspace.receive(fresh)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        workspace.receive(try service.fullReadPublication(identity))
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
    }

    @Test(arguments: [2, 99]) func opaqueInventoryCounterChangesRequireMatchingRead(_ counter: Int) async throws {
        let (workspace, service, identity) = try await fixture()
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "First prompt", updatedAt: Date(timeIntervalSince1970: 100), messageCount: counter)
        let old = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(old.owner); workspace.displayed(old.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        workspace.receive(try service.fullReadPublication(identity))
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == false,
            "Opaque inventory counts may be smaller or larger than all eleven projected rows")
    }

    @Test func missingCatalogCannotMintWitnessButCurrentAutomaticFullReadCan() async throws {
        let (workspace, service, identity) = try await fixture()
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "New inventory", messageCount: 40)
        let old = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(old.owner)
        service.readSummaryAvailable = false
        await workspace.openBot(profile: service.profile)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.cards(profile: service.profile).first?.unread == true)
        service.readSummaryAvailable = true
        workspace.receive(try service.fullReadPublication(identity))
        let refreshed = try #require(workspace.screen(profile: service.profile))
        let refreshedCards = workspace.cards(profile: service.profile)
        #expect(refreshedCards.first?.unread == true, "Publication alone never marks read")
        workspace.displayed(refreshed.owner)
        #expect(workspace.cards(profile: service.profile).first?.unread == false)
    }

    @Test func lateSelectionAndCancelledReadCannotAcknowledgeOrigin() async throws {
        let (workspace, service, identity) = try await fixture()
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "New inventory", messageCount: 40)
        let a = try #require(workspace.screen(profile: service.profile))
        let aCards = workspace.cards(profile: service.profile)
        await workspace.refreshDirectory(a.owner)
        let late = try service.fullReadPublication(identity)
        let b = try #require(aCards.first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(b, owner: a.owner)))
        workspace.receive(late)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.persisted().record(a.selectedChatID)?.isUnread == true)
        let gate = WorkspaceGate(); service.openGate = gate
        let ownerB = try #require(workspace.screen(profile: service.profile)?.owner)
        let intent = try #require(workspace.captureSelection(a.selectedChatID, owner: ownerB))
        let cancelled = Task { await workspace.select(intent) }
        await gate.entered(); cancelled.cancel(); gate.release(); await cancelled.value
        service.openGate = nil
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.persisted().record(a.selectedChatID)?.isUnread == true)
        await workspace.openBot(profile: service.profile)
        workspace.displayed(try #require(workspace.screen(profile: service.profile)?.owner))
        #expect(workspace.persisted().record(a.selectedChatID)?.isUnread == false)
    }
}
