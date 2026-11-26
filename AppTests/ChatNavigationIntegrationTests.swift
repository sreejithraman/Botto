import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ChatNavigationIntegrationTests {
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
        #expect(workspace.screen(profile: service.profile) != nil)
        service.openGate = nil

        #expect(await workspace.openSaved(service.summaries[0]))
        gate.release()

        #expect(await !notification.value)
        #expect(service.opens.count == 2)
        #expect(workspace.selection(profile: service.profile)?.identity?.root == service.summaries[0].identity.root)
        #expect(workspace.screen(profile: service.profile)?.canAct == true)
    }

    // Opening a stored chat is how a Space opens (AppStore.openT3Channel). When it
    // fails or is cancelled, the chat the user left comes back with its draft and a
    // fresh attachment; the retired one is never reused.
    @Test(arguments: [false, true])
    func unsuccessfulStoredChatOpeningRestoresTheOriginalEditableChat(cancel: Bool) async throws {
        let (workspace, service) = try await fixture()
        let before = try #require(workspace.screen(profile: service.profile))
        let oldAccess = try #require(service.completedOpens.last?.access)
        workspace.editDraft("Keep my original draft", owner: before.owner)
        let target = service.summaries[1]
        let gate = WorkspaceGate(); service.openGate = gate
        let claim = try #require(workspace.captureNavigationClaim())
        let opening = Task { await workspace.openStoredChat(target, claim: claim) }
        await gate.entered()
        service.openGate = nil
        if cancel { opening.cancel() }
        else {
            let failing = target.identity.root
            service.openResult = { opened in
                if opened.identity.root == failing { throw ConversationServiceError.disconnected }
                return opened
            }
        }
        gate.release()

        #expect(!(await opening.value))

        let returned = try #require(workspace.screen(profile: service.profile))
        #expect(returned.owner.chat == before.owner.chat)
        #expect(returned.canEditDraft)
        #expect(returned.canAct)
        #expect(workspace.draft(returned.owner) == "Keep my original draft")
        let restored = try #require(service.completedOpens.last)
        #expect(restored.identity.root == service.summaries[0].identity.root)
        #expect(restored.access != oldAccess)
        #expect(throws: (any Error).self) { try service.issuer.resolve(oldAccess) }
    }

    @Test func cancelledStoredChatOpeningCannotRestoreOverANewerChoice() async throws {
        let (workspace, service) = try await fixture()
        let third = SessionIdentity(profile: service.profile, root: try ExactID("third-root"), stored: try ExactID("third-tip"), aliases: [])
        service.summaries.append(.init(identity: third, title: "Third", isCanonical: false, persistence: .durable))
        service.snapshots[third.root] = .init(id: third.root.text, storedID: third.stored.text, profileID: service.profile.text,
                                              messages: [.init(id: "third-message", role: .assistant, text: "Third")])
        let gate = WorkspaceGate(); service.openGate = gate
        let claim = try #require(workspace.captureNavigationClaim())
        let opening = Task { await workspace.openStoredChat(service.summaries[1], claim: claim) }
        await gate.entered()
        opening.cancel()
        service.openGate = nil
        let newer = try #require(workspace.captureNavigationClaim())
        #expect(await workspace.openStoredChat(service.summaries[2], claim: newer))
        let newerAccess = try #require(service.completedOpens.last?.access)
        let opens = service.opens.count
        gate.release()

        #expect(!(await opening.value))

        #expect(workspace.selection(profile: service.profile)?.identity?.root == third.root)
        #expect(workspace.screen(profile: service.profile)?.canAct == true)
        #expect(service.opens.count == opens, "The cancelled opening restores nothing over the newer choice")
        #expect(try service.issuer.resolve(newerAccess) == third)
    }

    @Test func failedRestorationKeepsTheOriginalDraftEditableWithoutRevivingAccess() async throws {
        let (workspace, service) = try await fixture()
        let before = try #require(workspace.screen(profile: service.profile))
        let oldAccess = try #require(service.completedOpens.last?.access)
        workspace.editDraft("Keep editing locally", owner: before.owner)
        let gate = WorkspaceGate(); service.openGate = gate
        let claim = try #require(workspace.captureNavigationClaim())
        let opening = Task { await workspace.openStoredChat(service.summaries[1], claim: claim) }
        await gate.entered()
        service.openGate = nil
        let original = service.summaries[0].identity.root
        service.openResult = { opened in
            if opened.identity.root == original { throw ConversationServiceError.disconnected }
            return opened
        }
        opening.cancel(); gate.release()

        #expect(!(await opening.value))

        let returned = try #require(workspace.screen(profile: service.profile))
        #expect(returned.owner.chat == before.owner.chat)
        #expect(returned.canEditDraft)
        #expect(!returned.canAct)
        #expect(returned.error != nil)
        #expect(workspace.draft(returned.owner) == "Keep editing locally")
        #expect(throws: (any Error).self) { try service.issuer.resolve(oldAccess) }
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
