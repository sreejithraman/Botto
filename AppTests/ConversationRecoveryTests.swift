import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationRecoveryTests {
    private func fixture() async throws -> (AppStore, WorkspaceTestService, ConnectionConfiguration) {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://recovery.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        await store.open(try #require(store.bots.first))
        return (store, service, configuration)
    }

    @Test(arguments: [true, false], [true, false])
    func recoveryPublicationIsNonactionableOfflineAndAppliesOnlyAfterConnected(publicationFirst: Bool, ordinary: Bool) async throws {
        let (store, service, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats
        var before = try #require(workspace.screen(profile: service.profile))
        var beforeCards = workspace.cards(profile: service.profile)
        if ordinary {
            await workspace.refreshDirectory(before.owner)
            let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
            await workspace.select(try #require(workspace.captureSelection(other, owner: before.owner)))
            before = try #require(workspace.screen(profile: service.profile))
            beforeCards = workspace.cards(profile: service.profile)
            workspace.preferOpening(try #require(beforeCards.first { $0.isMain }?.id), owner: before.owner)
        }
        let identity = service.summaries[ordinary ? 1 : 0].identity
        let attachment = ChatAttachment(name: "proof.txt", path: "/proof.txt")
        let oldArtifact = try #require(workspace.captureArtifact(attachment, owner: before.owner))
        workspace.editDraft("kept draft", owner: before.owner)
        let oldSend = try #require(workspace.captureSend(before.owner))
        let oldImport = try #require(workspace.captureImport(before.owner))
        service.onEvent?(.disconnected("Recovering"))
        service.snapshots[identity.root]?.messages = [.init(id: "recovered", role: .assistant, text: "Fresh recovery transcript")]
        service.snapshots[identity.root]?.pendingRequests = [.init(id: "recovery-approval", kind: .approval, title: "Recovered approval")]
        let recovered = try service.publication(identity)
        if publicationFirst {
            service.onEvent?(.conversation(recovered))
            let offline = try #require(workspace.screen(profile: service.profile))
            #expect(!offline.canAct && offline.requests.isEmpty)
            #expect(offline.snapshot?.messages.last?.text == before.snapshot?.messages.last?.text)
            #expect(workspace.captureArtifact(attachment, owner: offline.owner) == nil)
        }
        service.onEvent?(.connected(.init(version: "recovered")))
        if !publicationFirst { service.onEvent?(.conversation(recovered)) }
        let current = try #require(workspace.screen(profile: service.profile))
        #expect(current.selectedChatID == before.selectedChatID && current.canAct)
        #expect(current.snapshot?.messages.last?.text == "Fresh recovery transcript")
        #expect(current.requests.map { $0.request.id } == ["recovery-approval"])
        #expect(workspace.persisted().record(current.selectedChatID)?.transcript?.pendingRequests.isEmpty == true)
        #expect(workspace.draft(current.owner) == "kept draft")
        #expect(workspace.persisted().record(current.selectedChatID)?.seen == nil)
        #expect(!workspace.isCurrent(before.owner) && !workspace.isCurrentArtifact(oldArtifact))
        let freshArtifact = try #require(workspace.captureArtifact(attachment, owner: current.owner))
        #expect(try await workspace.download(freshArtifact).data == Data("artifact".utf8))
        await workspace.send(oldSend)
        await workspace.upload(Data([1]), filename: "old.txt", mimeType: "text/plain", to: oldImport)
        service.onEvent?(.connected(.init(version: "duplicate connected")))
        #expect(workspace.screen(profile: service.profile)?.epoch == current.epoch)
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.uploads.isEmpty)
    }
    enum Retirement: CaseIterable { case selection, selectionRoundTrip, review, connection, recovery, background }

    @Test(arguments: Retirement.allCases)
    func pendingRecoveryCannotSurvivePresentationOrConnectionRetirement(_ retirement: Retirement) async throws {
        let (store, service, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats, callback = try #require(service.onEvent)
        let before = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(before.owner)
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        let identity = service.summaries[0].identity
        callback(.disconnected("First recovery"))
        let pending = try service.publication(identity)
        callback(.conversation(pending))
        switch retirement {
        case .selection, .selectionRoundTrip:
            var offline = try #require(workspace.screen(profile: service.profile))
            await workspace.select(try #require(workspace.captureSelection(other, owner: offline.owner)))
            if retirement == .selectionRoundTrip {
                offline = try #require(workspace.screen(profile: service.profile))
                await workspace.select(try #require(workspace.captureSelection(before.selectedChatID, owner: offline.owner)))
            }
        case .review: store.showsConnection = true
        case .connection: workspace.retireConnection()
        case .recovery: callback(.disconnected("Second recovery"))
        case .background: await store.setActive(false)
        }
        // A late copy of the first recovery frame must not requeue after retirement.
        callback(.conversation(pending))
        callback(.connected(.init(version: "First recovery complete")))
        callback(.conversation(pending)) // The same stale frame may also arrive after connected.
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(!after.canAct && after.requests.isEmpty)
        #expect(workspace.captureArtifact(.init(name: "old", path: "/old"), owner: after.owner) == nil)
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.uploads.isEmpty)
        store.showsConnection = false
        if retirement == .background {
            #expect(store.link == .connecting)
            #expect(await store.connect(configuration))
        } else if retirement == .recovery {
            callback(.conversation(try service.publication(identity)))
        } else { await store.open(try #require(store.bots.first)) }
        #expect(store.chats.screen(profile: service.profile)?.canAct == true)
    }

    @Test func oldConnectionCallbackCannotBufferOrReplaceNewWorkspaceRecovery() async throws {
        let (store, service, first) = try await fixture()
        let second = ConnectionConfiguration(serverURL: URL(string: "https://replacement.invalid")!)
        defer { LocalHistory.remove(for: first.id); LocalHistory.remove(for: second.id) }
        let oldWorkspace = store.chats, oldCallback = try #require(service.onEvent)
        let identity = service.summaries[0].identity
        oldCallback(.disconnected("Old workspace recovery"))
        let oldPublication = try service.publication(identity)
        oldCallback(.conversation(oldPublication))
        #expect(await store.connect(second))
        await store.open(try #require(store.bots.first))
        let workspace = store.chats, callback = try #require(service.onEvent)
        let before = try #require(workspace.screen(profile: service.profile))
        #expect(workspace !== oldWorkspace && before.canAct)
        callback(.disconnected("Current workspace recovery"))
        oldCallback(.conversation(oldPublication))
        oldCallback(.connected(.init(version: "Retired connection")))
        #expect(store.link == .offline && workspace.screen(profile: service.profile)?.canAct == false)
        let fresh = try service.publication(identity)
        callback(.conversation(fresh))
        #expect(workspace.screen(profile: service.profile)?.canAct == false)
        callback(.connected(.init(version: "Current connection")))
        let current = try #require(workspace.screen(profile: service.profile))
        #expect(current.canAct && current.selectedChatID == before.selectedChatID)
        let epoch = current.epoch
        oldCallback(.conversation(oldPublication))
        #expect(workspace.screen(profile: service.profile)?.epoch == epoch)
        #expect(!oldWorkspace.isCurrent(current.owner))
    }

    @Test(arguments: ["profile", "root", "snapshot", "retired-access"])
    func recoveryNeverUsesWrongIdentityOrPreviousGrant(_ mismatch: String) async throws {
        let (store, service, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats, callback = try #require(service.onEvent)
        let expected = service.summaries[0].identity
        let previous = try service.publication(expected)
        callback(.conversation(previous))
        callback(.disconnected("Recovering"))
        let fresh = try service.publication(expected)
        let identity = SessionIdentity(profile: mismatch == "profile" ? try ExactID("foreign") : expected.profile,
            root: mismatch == "root" ? try ExactID("foreign-root") : expected.root, stored: expected.stored, aliases: expected.aliases)
        var snapshot = fresh.snapshot
        if mismatch == "snapshot" { snapshot.profileID = "foreign" }
        let invalid = mismatch == "retired-access" ? previous : OpenedConversation(identity: identity, snapshot: snapshot, access: fresh.access)
        callback(.conversation(invalid))
        callback(.connected(.init(version: "Recovered")))
        #expect(workspace.screen(profile: service.profile)?.canAct == false)
        callback(.conversation(fresh))
        #expect(workspace.screen(profile: service.profile)?.canAct == true)
        #expect(workspace.screen(profile: service.profile)?.owner.chat == workspace.persisted().preference(service.profile)?.main)
    }

    @Test func recoveryDoesNotAutomaticallyReuploadRetiredStagedCapabilities() async throws {
        let (store, service, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats
        let before = try #require(workspace.screen(profile: service.profile))
        await workspace.upload(Data([1, 2]), filename: "kept.txt", mimeType: "text/plain", to: try #require(workspace.captureImport(before.owner)))
        let identity = service.summaries[0].identity
        service.onEvent?(.disconnected("Recovering"))
        service.onEvent?(.conversation(try service.publication(identity)))
        service.onEvent?(.connected(.init(version: "Recovered")))
        let current = try #require(workspace.screen(profile: service.profile))
        #expect(current.canAct && current.needsReattachment)
        #expect(current.attachments.map(\.name) == ["kept.txt"] && service.uploads.count == 1)
        #expect(workspace.captureSend(current.owner) == nil)
        #expect(service.sends.isEmpty)
    }

    @Test func newerPendingPublicationSupersedesEarlierFrameWithoutGrantRevival() async throws {
        let (store, service, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats, callback = try #require(service.onEvent)
        let identity = service.summaries[0].identity
        callback(.disconnected("Recovering"))
        let first = try service.publication(identity)
        callback(.conversation(first))
        service.snapshots[identity.root]?.messages = [.init(id: "latest", role: .assistant, text: "Latest recovery frame")]
        let latest = try service.publication(identity)
        callback(.conversation(latest))
        callback(.conversation(first))
        #expect(workspace.screen(profile: service.profile)?.canAct == false)
        callback(.connected(.init(version: "Recovered")))
        let current = try #require(workspace.screen(profile: service.profile))
        #expect(current.canAct && current.snapshot?.messages.last?.text == "Latest recovery frame")
        callback(.conversation(first))
        #expect(workspace.screen(profile: service.profile)?.epoch == current.epoch)
        #expect(workspace.persisted().record(current.selectedChatID)?.seen == nil)
    }

    @Test func reviewAlreadyOpenDoesNotAdmitRecoveryPublicationOrItsLateCopy() async throws {
        let (store, service, configuration) = try await fixture()
        defer { LocalHistory.remove(for: configuration.id) }
        let workspace = store.chats, callback = try #require(service.onEvent)
        let identity = service.summaries[0].identity
        store.showsConnection = true
        callback(.disconnected("Recovering behind review"))
        let rejected = try service.publication(identity)
        callback(.conversation(rejected))
        callback(.connected(.init(version: "Recovered")))
        store.showsConnection = false
        callback(.conversation(rejected))
        #expect(workspace.screen(profile: service.profile)?.canAct == false)
        await store.open(try #require(store.bots.first))
        #expect(workspace.screen(profile: service.profile)?.canAct == true)
    }

}
