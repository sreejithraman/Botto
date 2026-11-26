import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct NotificationChatRoutingTests {
    @Test(arguments: ["current", "removed", "failure"])
    func notificationReopensAClosedChatOnlyAfterAnAuthorizedOpen(outcome: String) async throws {
        let service = try WorkspaceTestService()
        var saved = ConversationBook()
        saved.merge(service.summaries[0])
        let other = saved.merge(service.summaries[1])
        saved.update(other) { $0.isClosedLocally = true }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: saved, service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        #expect(main.owner.chat != other && workspace.persisted().record(other)?.isClosedLocally == true)

        let gate = WorkspaceGate(); service.openGate = gate
        if outcome == "failure" { service.openError = ConversationServiceError.disconnected }
        var authorized = true
        var committed: [SessionIdentity] = []
        let destination = service.summaries[1].identity
        let claim = try #require(workspace.captureNavigationClaim())
        let routing = Task {
            await workspace.openNotificationChat(destination, claim: claim, exact: true, isCurrent: { authorized }) {
                committed.append($0)
                return true
            }
        }
        await gate.entered()
        if outcome == "removed" { authorized = false }
        gate.release()
        #expect(await routing.value == (outcome == "current"))

        let result = try #require(workspace.screen(profile: service.profile))
        #expect(committed == (outcome == "current" ? [destination] : []))
        #expect(workspace.persisted().record(other)?.isClosedLocally == (outcome == "current" ? nil : true))
        if outcome == "current" {
            #expect(result.owner.chat == other && result.canAct)
        } else {
            #expect(result.owner.chat == main.owner.chat)
            #expect(workspace.persisted().preference(service.profile)?.lastSelected == main.owner.chat)
        }
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.responses.isEmpty)
    }

    @Test func notificationOpensTheHostVerifiedChatWithoutCreatingOrSending() async throws {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        let destination = service.summaries[1].identity
        let claim = try #require(workspace.captureNavigationClaim())

        #expect(await workspace.openNotificationChat(destination, claim: claim, exact: true, isCurrent: { true }))

        #expect(service.opens.count == 1)
        #expect(service.opens.first?.profile == destination.profile)
        #expect(service.opens.first?.root == destination.root)
        #expect(service.opens.first?.stored == destination.stored)
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.responses.isEmpty)
        #expect(workspace.selection(profile: service.profile)?.identity?.root == destination.root)
        #expect(workspace.selection(profile: service.profile)?.identity?.stored == destination.stored)
    }

    @Test func offlineNotificationDoesNotReadOrOpenTheHost() async throws {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        let claim = try #require(workspace.captureNavigationClaim())

        #expect(await !workspace.openNotificationChat(service.summaries[1].identity,
            claim: claim, exact: true, isCurrent: { true }))
        #expect(service.directoryCalls == 0 && service.opens.isEmpty)
    }

    @Test func retiredDirectoryReadCannotNavigateAfterTheUserChoosesAnotherChat() async throws {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        let destination = service.summaries[1].identity
        let gate = WorkspaceGate(); service.directoryGate = gate
        let claim = try #require(workspace.captureNavigationClaim())
        let routing = Task {
            await workspace.openNotificationChat(destination, claim: claim, exact: true, isCurrent: { true })
        }
        await gate.entered()
        await workspace.openBot(profile: service.profile)
        gate.release()

        #expect(await !routing.value)
        #expect(service.opens.count == 1)
        #expect(service.opens.first?.root == service.summaries[0].identity.root)
        #expect(workspace.selection(profile: service.profile)?.identity?.root == service.summaries[0].identity.root)
    }

    @Test func notificationCannotOpenADifferentHostTip() async throws {
        let service = try WorkspaceTestService()
        let destination = service.summaries[1].identity
        let current = SessionIdentity(profile: destination.profile, root: destination.root,
            stored: try ExactID("compressed-tip"), aliases: [destination.stored])
        service.summaries[1] = .init(identity: current, title: "Other", isCanonical: false, persistence: .durable)
        service.snapshots[current.root]?.storedID = current.stored.text
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        let claim = try #require(workspace.captureNavigationClaim())

        #expect(await !workspace.openNotificationChat(destination, claim: claim, exact: true, isCurrent: { true }))
        #expect(service.opens.isEmpty)
        #expect(workspace.selection(profile: service.profile) == nil)
    }

    @Test func notificationDoesNotOpenAnAliasOfTheExactChat() async throws {
        let service = try WorkspaceTestService()
        let destination = service.summaries[1].identity
        let other = SessionIdentity(profile: destination.profile, root: try ExactID("another-root"),
            stored: try ExactID("another-tip"), aliases: [destination.root])
        service.summaries[1] = .init(identity: other, title: "Other", isCanonical: false, persistence: .durable)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        let claim = try #require(workspace.captureNavigationClaim())

        #expect(await !workspace.openNotificationChat(destination, claim: claim, exact: true, isCurrent: { true }))
        #expect(service.opens.isEmpty && service.creates.isEmpty && service.responses.isEmpty)
    }

    @Test func foregroundSuppressionRequiresTheActualVisibleCurrentChat() async throws {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let before = try #require(workspace.screen(profile: service.profile))
        #expect(workspace.visibleChatIdentity == nil)
        workspace.setTranscriptVisible(true, owner: before.owner)
        #expect(workspace.visibleChatIdentity?.root == service.summaries[0].identity.root)
        #expect(workspace.visibleChatIdentity?.stored == service.summaries[0].identity.stored)
        workspace.setTranscriptVisible(false, owner: before.owner)
        #expect(workspace.visibleChatIdentity == nil)
        workspace.setTranscriptVisible(true, owner: before.owner)
        workspace.retireConnection()
        workspace.setTranscriptVisible(true, owner: before.owner)
        #expect(workspace.visibleChatIdentity == nil)
    }
}
