import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ChatNavigationIntegrationTests {
    @Test func anOlderQueuedCreationCannotRetireANewerNotificationRoute() async throws {
        let (workspace, service) = try await fixture()
        let original = try #require(workspace.screen(profile: service.profile))
        let creation = try #require(workspace.captureCreation(original.owner))
        var navigations = 0
        workspace.onUserNavigation = { navigations += 1 }
        let gate = WorkspaceGate()
        service.directoryGate = gate
        let notification = Task { await workspace.openNotificationChat(service.summaries[1].identity, isCurrent: { true }) }
        await gate.entered()

        await workspace.create(creation)

        #expect(service.creates.count == 1)
        #expect(navigations == 0, "An older mutation cannot cancel a newer notification's navigation")
        #expect(workspace.screen(profile: service.profile)?.owner.chat == original.owner.chat)
        gate.release()
        #expect(await notification.value)
        #expect(workspace.selection(profile: service.profile)?.identity?.root == service.summaries[1].identity.root)
    }

    @Test func automaticRestorationDoesNotRetirePendingUserNavigation() async throws {
        let (workspace, service) = try await fixture()
        workspace.retireConnection()
        workspace.setOnline(true)
        let restoration = try #require(workspace.captureOpening(profile: service.profile))
        var navigations = 0
        workspace.onUserNavigation = { navigations += 1 }

        await workspace.restoreAttachment(restoration)

        #expect(navigations == 0)
        #expect(workspace.screen(profile: service.profile)?.canAct == true)
        let explicit = try #require(workspace.captureOpening(profile: service.profile))
        await workspace.open(explicit)
        #expect(navigations == 1)
    }

    @Test func aFailedNotificationLookupAfterReconnectKeepsTheOriginalDraftEditable() async throws {
        let (workspace, service) = try await fixture()
        let original = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Retained through reconnect", owner: original.owner)
        let oldPublication = try #require(service.completedOpens.last)
        workspace.retireConnection()
        workspace.setOnline(true)
        service.directoryError = ConversationServiceError.disconnected

        #expect(await !workspace.openNotificationChat(service.summaries[1].identity, isCurrent: { true }))

        let result = try #require(workspace.screen(profile: service.profile))
        #expect(result.owner.chat == original.owner.chat && result.canEditDraft && !result.canAct)
        #expect(workspace.draft(result.owner) == "Retained through reconnect")
        workspace.editDraft("Still editable", owner: result.owner)
        #expect(workspace.draft(result.owner) == "Still editable")
        #expect(workspace.captureSend(result.owner) == nil)
        workspace.receive(oldPublication)
        #expect(workspace.isCurrent(result.owner))
        #expect(workspace.screen(profile: service.profile)?.canAct == false)
    }

    @Test func aColdNotificationOpeningRetainsACurrentLocalPickerDuringRecovery() async throws {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo")])
        workspace.setOnline(true)
        let gate = WorkspaceGate()
        service.openGate = gate
        let notification = Task { await workspace.openNotificationChat(service.summaries[1].identity, isCurrent: { true }) }
        await gate.entered()
        workspace.retireConnection()
        workspace.setOnline(true)
        let cached = try #require(workspace.screen(profile: service.profile))
        let main = try #require(workspace.cards(profile: service.profile).first { $0.isMain }?.id)
        let manual = try #require(workspace.captureSelection(main, owner: cached.owner))
        service.openGate = nil

        await workspace.select(manual)
        gate.release()

        #expect(await !notification.value)
        #expect(service.opens.count == 2)
        #expect(workspace.selection(profile: service.profile)?.identity?.root == service.summaries[0].identity.root)
        #expect(workspace.screen(profile: service.profile)?.canAct == true)
    }

    private func fixture() async throws -> (ConversationWorkspace, WorkspaceTestService) {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        return (workspace, service)
    }
}
