import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct LibraryNavigationIntegrationTests {
    @Test(arguments: ["current", "failure", "cancelled"])
    func libraryReopensClosedTabsOnlyAfterACommittedAttachment(outcome: String) async throws {
        let (workspace, service) = try await fixture()
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(other, owner: main.owner)))
        let selected = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Keep this closed chat's draft", owner: selected.owner)
        let close = try #require(workspace.captureClose(other, owner: selected.owner))
        _ = try #require(workspace.close(close))
        let originalPreference = workspace.persisted().preference(service.profile)?.lastSelected
        let gate = WorkspaceGate()
        service.openGate = gate
        let intent = try #require(workspace.beginLibraryOpening(service.summaries[1].identity))
        let opening = Task { await workspace.openLibraryChat(intent, commit: { _ in true }) }
        await gate.entered()
        #expect(workspace.screen(profile: service.profile)?.owner.chat == main.owner.chat)
        #expect(workspace.closedChats(profile: service.profile).map(\.id) == [other])
        if outcome == "failure" { service.openError = HermesServiceError.disconnected }
        if outcome == "cancelled" { opening.cancel() }
        service.openGate = nil
        gate.release()

        #expect((await opening.value != nil) == (outcome == "current"))

        let result = try #require(workspace.screen(profile: service.profile))
        if outcome == "current" {
            #expect(result.owner.chat == other && result.canAct)
            #expect(workspace.closedChats(profile: service.profile).isEmpty)
        } else {
            #expect(result.owner.chat == main.owner.chat && result.canEditDraft)
            #expect(workspace.closedChats(profile: service.profile).map(\.id) == [other])
            #expect(workspace.persisted().preference(service.profile)?.lastSelected == originalPreference)
            if outcome == "failure" { #expect(result.canCreate) }
        }
        #expect(workspace.persisted().record(other)?.draft.text == "Keep this closed chat's draft")
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.responses.isEmpty)
    }

    @Test func newerLibraryLookupSupersedesAPendingNotificationLookup() async throws {
        let (workspace, service) = try await fixture()
        let original = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Keep my main draft", owner: original.owner)
        let gate = WorkspaceGate()
        service.directoryGate = gate
        let notification = Task { await workspace.openNotificationChat(service.summaries[1].identity, isCurrent: { true }) }
        await gate.entered()
        service.directoryGate = nil
        let intent = try #require(workspace.beginLibraryOpening(service.summaries[0].identity))
        #expect(await workspace.openLibraryChat(intent, commit: { _ in true }) != nil)
        let openCount = service.opens.count
        gate.release()

        #expect(await !notification.value)

        #expect(service.opens.count == openCount)
        let result = try #require(workspace.screen(profile: service.profile))
        #expect(result.owner.chat == original.owner.chat && result.canAct)
        #expect(workspace.draft(result.owner) == "Keep my main draft")
    }

    @Test func newerNotificationLookupSupersedesAPendingLibraryLookup() async throws {
        let (workspace, service) = try await fixture()
        let original = try #require(workspace.screen(profile: service.profile))
        let gate = WorkspaceGate()
        service.directoryGate = gate
        let intent = try #require(workspace.beginLibraryOpening(service.summaries[1].identity))
        let library = Task { await workspace.openLibraryChat(intent, commit: { _ in true }) }
        await gate.entered()
        service.directoryGate = nil
        #expect(await workspace.openNotificationChat(service.summaries[0].identity, isCurrent: { true }))
        let openCount = service.opens.count
        gate.release()

        #expect(await library.value == nil)

        #expect(service.opens.count == openCount)
        let result = try #require(workspace.screen(profile: service.profile))
        #expect(result.owner.chat == original.owner.chat && result.canAct)
    }

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
        service.directoryError = HermesServiceError.disconnected

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
