import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct NotificationChatRoutingTests {
    @Test(arguments: ["current", "removed", "failure"])
    func notificationReopensAClosedTabOnlyAfterAnAuthorizedOpen(outcome: String) async throws {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(other, owner: main.owner)))
        let reader = try #require(workspace.screen(profile: service.profile))
        let close = try #require(workspace.captureClose(other, owner: reader.owner))
        _ = try #require(workspace.close(close))
        #expect(workspace.screen(profile: service.profile)?.owner.chat == main.owner.chat)
        #expect(workspace.closedChats(profile: service.profile).map(\.id) == [other])

        let gate = WorkspaceGate(); service.openGate = gate
        if outcome == "failure" { service.openError = HermesServiceError.disconnected }
        var authorized = true
        let routing = Task { await workspace.openNotificationChat(service.summaries[1].identity, isCurrent: { authorized }) }
        await gate.entered()
        if outcome == "removed" { authorized = false }
        gate.release()
        #expect(await routing.value == (outcome == "current"))

        let result = try #require(workspace.screen(profile: service.profile))
        if outcome == "current" {
            #expect(result.owner.chat == other && result.canAct)
            #expect(workspace.closedChats(profile: service.profile).isEmpty)
        } else {
            #expect(result.owner.chat == main.owner.chat && result.canCreate)
            #expect(workspace.closedChats(profile: service.profile).map(\.id) == [other])
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

        #expect(await workspace.openNotificationChat(destination, isCurrent: { true }))

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

        #expect(await !workspace.openNotificationChat(service.summaries[1].identity, isCurrent: { true }))
        #expect(service.directoryCalls == 0 && service.opens.isEmpty)
    }

    @Test func retiredDirectoryReadCannotNavigateAfterTheUserChoosesAnotherChat() async throws {
        let service = try WorkspaceTestService()
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        let destination = service.summaries[1].identity
        let gate = WorkspaceGate(); service.directoryGate = gate
        let routing = Task { await workspace.openNotificationChat(destination, isCurrent: { true }) }
        await gate.entered()
        await workspace.openBot(profile: service.profile)
        gate.release()

        #expect(await !routing.value)
        #expect(service.opens.count == 1)
        #expect(service.opens.first?.root == service.summaries[0].identity.root)
        #expect(workspace.selection(profile: service.profile)?.identity?.root == service.summaries[0].identity.root)
    }

    @Test func notificationUsesTheCurrentHostTipInsteadOfTheOldPayloadTip() async throws {
        let service = try WorkspaceTestService()
        let destination = service.summaries[1].identity
        let current = SessionIdentity(profile: destination.profile, root: destination.root,
            stored: try ExactID("compressed-tip"), aliases: [destination.stored])
        service.summaries[1] = .init(identity: current, title: "Other", isCanonical: false, persistence: .durable)
        service.snapshots[current.root]?.storedID = current.stored.text
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)

        #expect(await workspace.openNotificationChat(destination, isCurrent: { true }))
        #expect(service.opens.count == 1)
        #expect(service.opens.first?.root == current.root && service.opens.first?.stored == current.stored)
        #expect(workspace.selection(profile: service.profile)?.identity?.root == current.root)
        #expect(workspace.selection(profile: service.profile)?.identity?.stored == current.stored)
    }

    @Test func ambiguousHostAliasesNeverChooseAnArbitraryChat() async throws {
        let service = try WorkspaceTestService()
        let destination = service.summaries[1].identity
        let other = SessionIdentity(profile: destination.profile, root: try ExactID("another-root"),
            stored: try ExactID("another-tip"), aliases: [destination.root])
        service.summaries.append(.init(identity: other, title: "Ambiguous", isCanonical: false, persistence: .durable))
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)

        #expect(await !workspace.openNotificationChat(destination, isCurrent: { true }))
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
