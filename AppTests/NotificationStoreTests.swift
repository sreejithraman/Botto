import CryptoKit
import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor private final class NotificationVaultFixture {
    var saved = PushSavedState()
    var failsSave = false
    var persistence: PushPersistence {
        .init(load: { self.saved }, save: {
            if self.failsSave { throw PushError.unavailableStorage }
            self.saved = $0
        })
    }
}

@MainActor struct NotificationStoreTests {
    @Test(arguments: ["directory", "open"], [false, true])
    func closingATabSupersedesAnOlderNotification(boundary: String, closeTab: Bool) async throws {
        let (store, service, connection, vault) = try fixture()
        let configuration = try #require(connection.saved)
        defer { LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(try #require(store.bots.first))
        let workspace = store.chats
        let main = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(main.owner)
        let other = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        let target = service.summaries[1].identity
        let revision = store.notificationNavigationRevision
        let gate = WorkspaceGate()
        if boundary == "directory" { service.directoryGate = gate }
        else { service.openGate = gate }
        let envelope = try notification(target, pairing: #require(vault.saved.pairings.first))
        let tap = Task { await store.openPushNotification(envelope) }
        await gate.entered()
        if closeTab {
            let current = try #require(workspace.screen(profile: service.profile))
            let close = try #require(workspace.captureClose(other, owner: current.owner))
            _ = try #require(workspace.close(close))
        }
        let opensAtClose = service.opens.count
        service.directoryGate = nil; service.openGate = nil; gate.release()
        await tap.value
        if closeTab {
            #expect(workspace.closedChats(profile: service.profile).map(\.id) == [other])
            #expect(workspace.screen(profile: service.profile)?.owner.chat == main.owner.chat)
            #expect(store.notificationNavigationRevision == revision)
            #expect(service.opens.count == opensAtClose)
        } else {
            #expect(workspace.screen(profile: service.profile)?.owner.chat == other)
            #expect(workspace.closedChats(profile: service.profile).isEmpty)
            #expect(store.notificationNavigationRevision != revision)
        }
        await store.refresh()
        if closeTab {
            #expect(workspace.closedChats(profile: service.profile).map(\.id) == [other])
            #expect(workspace.screen(profile: service.profile)?.owner.chat == main.owner.chat)
            #expect(service.opens.count == opensAtClose)
        } else { #expect(workspace.screen(profile: service.profile)?.owner.chat == other) }
        #expect(service.sends.isEmpty && service.creates.isEmpty && service.responses.isEmpty)
    }

    private func fixture(authorization: PushAuthorization? = nil, pendingEnrollment: Bool = false,
                         now: @escaping () -> Date = Date.init) throws -> (AppStore, WorkspaceTestService, MemoryConnectionStorage, NotificationVaultFixture) {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://notifications.invalid")!,
            username: "owner", installID: "fixture-install")
        let connection = MemoryConnectionStorage(saved: configuration)
        let vault = NotificationVaultFixture()
        vault.saved.pairings = [.init(host: try #require(PushHostBinding(configuration, profileID: service.profile.text)),
            installationID: String(repeating: "a", count: 64), deviceID: String(repeating: "b", count: 32),
            generation: pendingEnrollment ? 0 : 1, key: Data(repeating: 7, count: 32), preferences: .init(),
            pendingEnrollment: pendingEnrollment ? .init(deviceID: String(repeating: "b", count: 32),
                token: String(repeating: "1", count: 64), bundleID: "com.example.botto", environment: .sandbox,
                previewKey: Data(repeating: 7, count: 32), preferences: .init()) : nil,
            remoteConfirmed: !pendingEnrollment, lastEnrollment: nil)]
        service.pushStatusResult = .init(pluginVersion: "fixture", supported: true,
            installationID: String(repeating: "a", count: 64),
            devices: [.init(deviceID: String(repeating: "b", count: 32), generation: 1, active: true, state: .active)])
        let push = PushCoordinator(persistence: vault.persistence,
            authorization: authorization ?? .init(requestPermission: { false }, deviceToken: { throw PushError.tokenUnavailable }), now: now)
        return (AppStore(service: service, persistence: connection.persistence, push: push), service, connection, vault)
    }

    private func notification(_ destination: SessionIdentity, pairing: PushPairing, expiresAt: Int? = nil) throws -> PushEnvelope {
        let installation = try #require(pairing.installationID)
        let event = String(repeating: "c", count: 64)
        let aad = "botto-push:v1\n\(installation)\n\(pairing.deviceID)\n1\n\(event)"
        let preview = PushPreview(title: "Milo", body: "A meaningful reply", destination: .init(identity: destination))
        let box = try AES.GCM.seal(JSONEncoder().encode(preview), using: SymmetricKey(data: pairing.key),
            authenticating: Data(aad.utf8))
        return .init(installationID: installation, deviceID: pairing.deviceID, generation: 1,
            eventID: event, kind: .reply, expiresAt: expiresAt ?? Int(Date().timeIntervalSince1970) + 300,
            sealed: try #require(box.combined).base64EncodedString())
    }

    @Test func notificationTapReconnectsWithoutLosingItsDestinationToChatRestoration() async throws {
        let (store, service, connection, vault) = try fixture()
        let configuration = try #require(connection.saved)
        defer { LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(try #require(store.bots.first))
        let original = try #require(store.chats.screen(profile: service.profile))
        store.chats.editDraft("Keep my current draft", owner: original.owner)
        service.onEvent?(.disconnected("Temporary outage"))
        let target = service.summaries[1].identity
        let before = store.notificationNavigationRevision

        await store.openPushNotification(try notification(target, pairing: #require(vault.saved.pairings.first)))

        #expect(store.isConnected)
        #expect(store.chats.selection(profile: service.profile)?.identity?.root == target.root)
        #expect(store.notificationNavigationRevision != before)
        #expect(store.chats.persisted().record(original.owner.chat)?.draft.text == "Keep my current draft")
        #expect(service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test func coldStartTapReconnectsAndOpensTheVerifiedChatWithoutSending() async throws {
        let (store, service, connection, vault) = try fixture()
        defer { if let id = connection.saved?.id { LocalHistory.remove(for: id) } }
        let target = service.summaries[1].identity
        let before = store.notificationNavigationRevision

        await store.openPushNotification(try notification(target, pairing: #require(vault.saved.pairings.first)))

        #expect(store.isConnected)
        #expect(store.selectedBotID == service.profile.text)
        #expect(store.chats.selection(profile: service.profile)?.identity?.root == target.root)
        #expect(store.notificationNavigationRevision != before)
        #expect(service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test func tapWhileTheFirstRosterLoadsRetainsItsVerifiedDestination() async throws {
        let (store, service, connection, vault) = try fixture()
        defer { if let id = connection.saved?.id { LocalHistory.remove(for: id) } }
        let gate = WorkspaceGate()
        service.rosterGate = gate
        let configuration = try #require(connection.saved)
        let connecting = Task { await store.connect(configuration) }
        await gate.entered()
        #expect(store.isConnected && store.bots.isEmpty)
        let target = service.summaries[1].identity
        let envelope = try notification(target, pairing: #require(vault.saved.pairings.first))
        let tap = Task { await store.openPushNotification(envelope) }
        await Task.yield()
        #expect(service.opens.isEmpty)
        service.rosterGate = nil
        gate.release()
        #expect(await connecting.value)
        await tap.value
        #expect(store.selectedBotID == service.profile.text)
        #expect(store.chats.selection(profile: service.profile)?.identity?.root == target.root)
        #expect(service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test func aValidTapSurvivesAnOutageBeyondDeliveryExpiry() async throws {
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let (store, service, connection, vault) = try fixture(now: { clock })
        defer { if let id = connection.saved?.id { LocalHistory.remove(for: id) } }
        let configuration = try #require(connection.saved)
        let target = service.summaries[1].identity
        let envelope = try notification(target, pairing: #require(vault.saved.pairings.first),
            expiresAt: Int(clock.timeIntervalSince1970) + 300)
        service.connectError = HermesServiceError.disconnected
        await store.openPushNotification(envelope)
        #expect(!store.isConnected && service.opens.isEmpty)
        clock.addTimeInterval(301)
        service.connectError = nil
        #expect(await store.connect(configuration))
        for _ in 0..<1_000 where store.chats.selection(profile: service.profile)?.identity?.root != target.root { await Task.yield() }
        #expect(store.selectedBotID == service.profile.text)
        #expect(store.chats.selection(profile: service.profile)?.identity?.root == target.root)
        #expect(service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test(arguments: ["expired", "removed", "replacement"])
    func recoveringATapCannotRestoreExpiredOrRetiredNavigation(control: String) async throws {
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let (store, service, connection, vault) = try fixture(now: { clock })
        let configuration = try #require(connection.saved)
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.invalid")!,
            username: "other-owner", installID: "other-install")
        defer { LocalHistory.remove(for: configuration.id); LocalHistory.remove(for: replacement.id) }
        let envelope = try notification(service.summaries[1].identity, pairing: #require(vault.saved.pairings.first),
            expiresAt: Int(clock.timeIntervalSince1970) + (control == "expired" ? 0 : 300))
        service.connectError = HermesServiceError.disconnected
        await store.openPushNotification(envelope)
        if control == "removed" { #expect(await store.push.prepareToForget()) }
        clock.addTimeInterval(301)
        service.connectError = nil
        if control == "replacement" { #expect(await store.connect(replacement)) }
        #expect(await store.connect(configuration))
        for _ in 0..<1_000 { await Task.yield() }
        #expect(store.selectedBotID == nil)
        #expect(service.opens.isEmpty && service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test(arguments: ["roster", "directory"], ["refresh", "socket"])
    func ordinaryRecoveryResumesTheAuthenticatedTapBeyondDeliveryExpiry(failedRead: String, recovery: String) async throws {
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let (store, service, connection, vault) = try fixture(now: { clock })
        let configuration = try #require(connection.saved)
        defer { LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        let target = service.summaries[1].identity
        let envelope = try notification(target, pairing: #require(vault.saved.pairings.first),
            expiresAt: Int(clock.timeIntervalSince1970) + 300)
        if failedRead == "roster" { service.rosterError = HermesServiceError.disconnected }
        else { service.directoryError = HermesServiceError.disconnected }
        await store.openPushNotification(envelope)
        #expect(service.opens.isEmpty)
        let failedReads = service.rosterCalls
        for _ in 0..<100 { await Task.yield() }
        #expect(service.rosterCalls == failedReads)
        clock.addTimeInterval(301)
        service.rosterError = nil; service.directoryError = nil
        if recovery == "socket" {
            let gate = WorkspaceGate()
            service.rosterGate = gate
            service.onEvent?(.disconnected("Temporary outage"))
            service.onEvent?(.connected(.init(version: "recovered")))
            await gate.entered()
            service.rosterGate = nil; gate.release()
        } else { await store.refresh() }
        for _ in 0..<1_000 where store.chats.selection(profile: service.profile)?.identity?.root != target.root { await Task.yield() }
        #expect(store.chats.selection(profile: service.profile)?.identity?.root == target.root)
        #expect(service.opens.count == 1)
        #expect(service.connectionAttempts == 1)
        #expect(store.notice == nil)
        #expect(service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test(arguments: ["recovered", "removed", "manual", "background"])
    func recoveryPublicationDuringAnOldOpenRespectsTheCurrentNavigationOwner(control: String) async throws {
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let (store, service, connection, vault) = try fixture(now: { clock })
        let configuration = try #require(connection.saved)
        defer { LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        let target = service.summaries[1].identity
        let envelope = try notification(target, pairing: #require(vault.saved.pairings.first),
            expiresAt: Int(clock.timeIntervalSince1970) + 300)
        let gate = WorkspaceGate()
        service.openGate = gate
        let tap = Task { await store.openPushNotification(envelope) }
        await gate.entered()
        service.onEvent?(.disconnected("Temporary outage"))
        service.onEvent?(.connected(.init(version: "recovered")))
        await store.refresh()
        clock.addTimeInterval(301)
        service.openGate = nil
        if control == "removed" { #expect(await store.push.prepareToForget()) }
        if control == "manual" {
            let screen = try #require(store.chats.screen(profile: service.profile))
            let main = try #require(store.chats.cards(profile: service.profile).first { $0.isMain }?.id)
            await store.chats.select(try #require(store.chats.captureSelection(main, owner: screen.owner)))
        }
        if control == "background" { await store.setActive(false) }
        gate.release()
        await tap.value
        for _ in 0..<1_000 { await Task.yield() }
        if control == "recovered" || control == "manual" {
            let expected = control == "manual" ? service.summaries[0].identity.root : target.root
            let selection = try #require(store.chats.selection(profile: service.profile))
            #expect(selection.identity?.root == expected && !selection.isUnverified)
            #expect(service.opens.count == 2)
        } else { #expect(service.opens.count == 1) }
        #expect(service.connectionAttempts == 1)
        #expect(service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test func notificationFromAnotherPairingCannotSelectAChat() async throws {
        let (store, service, connection, vault) = try fixture()
        defer { if let id = connection.saved?.id { LocalHistory.remove(for: id) } }
        var envelope = try notification(service.summaries[1].identity, pairing: #require(vault.saved.pairings.first))
        envelope.installationID = String(repeating: "d", count: 64)

        await store.openPushNotification(envelope)

        #expect(store.selectedBotID == nil)
        #expect(service.opens.isEmpty && service.sends.isEmpty && service.responses.isEmpty)
        #expect(store.notice?.contains("verified chat destination") == true)
    }

    @Test(arguments: ["current", "disabled", "remote"])
    func pairingRetirementDuringTheDirectoryReadCannotCommitNavigation(authority: String) async throws {
        let (store, service, connection, vault) = try fixture()
        let configuration = try #require(connection.saved)
        defer { LocalHistory.remove(for: configuration.id) }
        let pairing = try #require(vault.saved.pairings.first)
        service.pushStatusResult = .init(pluginVersion: "fixture", supported: true,
            installationID: pairing.installationID, relayURL: URL(string: "https://relay.invalid"),
            devices: [.init(deviceID: pairing.deviceID, generation: 1, active: true, state: .active)])
        #expect(await store.connect(configuration))
        await store.open(try #require(store.bots.first))
        let original = try #require(store.chats.selection(profile: service.profile))
        let preference = store.history.book.preference(service.profile)?.lastSelected
        let revision = store.notificationNavigationRevision
        let target = service.summaries[1].identity
        let envelope = try notification(target, pairing: pairing)
        let gate = WorkspaceGate()
        service.directoryGate = gate
        let tap = Task { await store.openPushNotification(envelope) }
        await gate.entered()
        #expect(!store.isRefreshing)
        if authority == "disabled" { await store.push.disable() }
        if authority == "remote" {
            service.pushStatusResult?.devices = [.init(deviceID: pairing.deviceID, generation: 2, active: false, state: .removed)]
            await store.push.refresh()
        }
        #expect(store.isConnected && service.opens.count == 1)
        service.directoryGate = nil; gate.release()
        await tap.value
        if authority == "current" {
            #expect(service.opens.count == 2)
            #expect(store.chats.selection(profile: service.profile)?.identity?.root == target.root)
            #expect(store.notificationNavigationRevision != revision)
        } else {
            #expect(service.opens.count == 1)
            #expect(store.chats.selection(profile: service.profile)?.identity == original.identity)
            #expect(store.history.book.preference(service.profile)?.lastSelected == preference)
            #expect(store.notificationNavigationRevision == revision)
        }
        #expect(service.connectionAttempts == 1)
        #expect(service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test(arguments: ["directory", "open"], ["current", "disabled", "remote", "manual", "failure", "alias", "unrelated"].flatMap { authority in
        ["connected", "reconnect"].map { (authority, $0) }
    })
    func rejectedCrossProfileNotificationsPreserveTheDisplayedBot(boundary: String, control: (String, String)) async throws {
        let (authority, entry) = control
        let (store, service, connection, vault) = try fixture()
        let configuration = try #require(connection.saved)
        defer { LocalHistory.remove(for: configuration.id) }
        let otherProfile = try ExactID("scout")
        let target = SessionIdentity(profile: otherProfile, root: try ExactID("scout-main"), stored: try ExactID("scout-tip"), aliases: [])
        service.rosterProfiles = [.init(id: service.profile.text, name: "Milo"), .init(id: otherProfile.text, name: "Scout")]
        service.summaries.append(.init(identity: target, title: "Scout chat", isCanonical: true, persistence: .durable))
        service.snapshots[target.root] = .init(id: target.root.text, storedID: target.stored.text, profileID: otherProfile.text,
            messages: [.init(id: "scout-reply", role: .assistant, text: "Scout reply")])
        var pairing = try #require(vault.saved.pairings.first)
        pairing.host = try #require(PushHostBinding(configuration, profileID: otherProfile.text))
        pairing.deviceID = String(repeating: "d", count: 32)
        vault.saved.pairings.append(pairing)
        store.push.retryStorage()
        service.pushStatusResult = .init(pluginVersion: "fixture", supported: true, installationID: pairing.installationID,
            devices: vault.saved.pairings.map { .init(deviceID: $0.deviceID, generation: 1, active: true, state: .active) })
        #expect(await store.connect(configuration))
        let originalBot = try #require(store.bots.first { $0.id == service.profile.text })
        await store.open(originalBot)
        await store.push.selectProfile(otherProfile.text)
        let original = try #require(store.chats.selection(profile: service.profile))
        let preference = store.history.book.preference(service.profile)?.lastSelected
        let revision = store.notificationNavigationRevision
        store.chats.editDraft("Keep Milo's draft", owner: original.owner)
        let oldPublication = try #require(service.completedOpens.last)
        let destinationPreference = store.history.book.preference(otherProfile)?.lastSelected
        var acceptedTarget = target
        if authority == "alias" || authority == "unrelated" {
            acceptedTarget = .init(profile: otherProfile, root: try ExactID("scout-new-root"), stored: try ExactID("scout-new-tip"),
                aliases: authority == "alias" ? [target.root] : [])
            let replacement = acceptedTarget
            service.snapshots[replacement.root] = .init(id: replacement.root.text, storedID: replacement.stored.text,
                profileID: otherProfile.text, messages: [.init(id: "new-root-reply", role: .assistant, text: "New canonical reply")])
            service.openResult = { opened in
                guard opened.identity.profile == otherProfile else { return opened }
                return try service.publication(replacement, readEvidence: .init(summaryObservedBeforeRead: .init(identity: replacement,
                    title: "Scout chat", isCanonical: true, persistence: .durable)))
            }
        }
        let envelope = try notification(target, pairing: pairing)
        if entry == "reconnect" {
            service.onEvent?(.disconnected("Temporary outage"))
            service.connectError = HermesServiceError.disconnected
            await store.openPushNotification(envelope)
            service.connectError = nil
        }
        let gate = WorkspaceGate()
        service.directoryGatedProfile = otherProfile; service.openGatedProfile = otherProfile
        if boundary == "directory" { service.directoryGate = gate } else { service.openGate = gate }
        let tap = Task {
            if entry == "reconnect" { #expect(await store.connect(configuration)) }
            else { await store.openPushNotification(envelope) }
        }
        await gate.entered()
        if authority == "disabled" { await store.push.disable() }
        if authority == "remote" {
            service.pushStatusResult?.devices = [.init(deviceID: pairing.deviceID, generation: 2, active: false, state: .removed)]
            await store.push.refresh()
        }
        service.directoryGate = nil; service.openGate = nil
        if authority == "manual" { await store.open(originalBot) }
        if authority == "failure" {
            if boundary == "open" { service.openError = HermesServiceError.rejected(409) }
            else { service.directoryError = HermesServiceError.rejected(409) }
        }
        gate.release(); await tap.value
        if authority == "current" || authority == "alias" {
            #expect(store.selectedBotID == otherProfile.text)
            #expect(store.chats.selection(profile: otherProfile)?.identity?.root == acceptedTarget.root)
            #expect(store.chats.selection(profile: otherProfile)?.identity?.stored == acceptedTarget.stored)
            #expect(store.chats.screen(profile: otherProfile)?.canAct == true)
            #expect(store.chats.screen(profile: otherProfile)?.canEditDraft == true)
            #expect(store.notice == nil)
            #expect(store.notificationNavigationRevision != revision)
        } else {
            #expect(service.opens.filter { $0.profile == otherProfile }.count == (boundary == "open" || authority == "unrelated" ? 1 : 0))
            #expect(store.selectedBotID == originalBot.id)
            #expect(store.chats.selection(profile: service.profile)?.identity == original.identity)
            #expect(store.history.book.preference(service.profile)?.lastSelected == preference)
            #expect(store.notificationNavigationRevision == revision)
            if authority == "failure" {
                let restored = try #require(store.chats.screen(profile: service.profile))
                #expect(restored.canEditDraft)
                #expect(store.chats.draft(restored.owner) == "Keep Milo's draft")
                store.chats.editDraft("Still editable", owner: restored.owner)
                #expect(store.chats.draft(restored.owner) == "Still editable")
                #expect(store.history.book.preference(otherProfile)?.lastSelected == destinationPreference)
                if entry == "connected" && boundary == "open" {
                    #expect(!restored.canAct)
                    service.onEvent?(.conversation(oldPublication))
                    #expect(store.chats.isCurrent(restored.owner))
                    #expect(store.chats.screen(profile: service.profile)?.canAct == false)
                }
                service.openError = nil; service.directoryError = nil
            }
            if boundary == "open" || authority == "unrelated", let late = service.completedOpens.last(where: { $0.identity.profile == otherProfile }) {
                service.onEvent?(.conversation(late))
                #expect(store.selectedBotID == originalBot.id)
                #expect(store.chats.screen(profile: otherProfile)?.canAct != true)
            }
            if authority == "failure" {
                await store.refresh()
                for _ in 0..<1_000 where store.selectedBotID != otherProfile.text { await Task.yield() }
                #expect(store.selectedBotID == otherProfile.text)
                #expect(store.chats.screen(profile: otherProfile)?.canAct == true)
            }
            if authority != "manual" && authority != "failure" {
                service.openResult = nil
                await store.open(try #require(store.bots.first { $0.id == otherProfile.text }))
                #expect(store.selectedBotID == otherProfile.text)
                #expect(store.chats.screen(profile: otherProfile)?.canAct == true)
            }
        }
        #expect(service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test(arguments: ["cold", "other-profile"], ["current", "removed", "failure"])
    func notificationRoutingWaitsForItsOwnAuthoritativePairing(entry: String, authority: String) async throws {
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let (store, service, connection, vault) = try fixture(now: { clock })
        let configuration = try #require(connection.saved)
        defer { LocalHistory.remove(for: configuration.id) }
        let other = try ExactID("scout")
        let second = SessionIdentity(profile: other, root: try ExactID("scout-main"), stored: try ExactID("scout-tip"), aliases: [])
        service.rosterProfiles = [.init(id: service.profile.text, name: "Milo"), .init(id: other.text, name: "Scout")]
        service.summaries.append(.init(identity: second, title: "Scout chat", isCanonical: true, persistence: .durable))
        service.snapshots[second.root] = .init(id: second.root.text, storedID: second.stored.text, profileID: other.text)
        var secondPairing = try #require(vault.saved.pairings.first)
        secondPairing.host = try #require(PushHostBinding(configuration, profileID: other.text))
        secondPairing.deviceID = String(repeating: "d", count: 32)
        vault.saved.pairings.append(secondPairing); store.push.retryStorage()
        for pairing in vault.saved.pairings {
            service.pushStatuses[pairing.host.profileID] = .init(pluginVersion: "fixture", supported: true,
                installationID: pairing.installationID, devices: [.init(deviceID: pairing.deviceID, generation: 1, active: true, state: .active)])
        }
        if entry == "other-profile" {
            #expect(await store.connect(configuration))
            await store.open(try #require(store.bots.first { $0.id == service.profile.text }))
        }
        let pairing = try #require(vault.saved.pairings.first { $0.host.profileID == (entry == "cold" ? service.profile.text : other.text) })
        let target = entry == "cold" ? service.summaries[1].identity : second
        let selected = store.selectedBotID, opens = service.opens.count, revision = store.notificationNavigationRevision
        if authority == "removed" {
            service.pushStatuses[pairing.host.profileID]?.devices = [.init(deviceID: pairing.deviceID, generation: 2, active: false, state: .removed)]
        }
        let gate = WorkspaceGate()
        service.pushStatusGate = gate; service.pushStatusGatedProfileID = pairing.host.profileID
        service.pushStatusCalls = []
        if authority == "failure" { service.pushStatusError = HermesServiceError.disconnected }
        let envelope = try notification(target, pairing: pairing, expiresAt: Int(clock.timeIntervalSince1970) + 300)
        let tap = Task { await store.openPushNotification(envelope) }
        for _ in 0..<1_000 { await Task.yield() }
        #expect(service.pushStatusCalls.contains(pairing.host.profileID))
        #expect(service.opens.count == opens && store.selectedBotID == selected)
        service.pushStatusGate = nil; gate.release(); await tap.value
        if authority == "removed" || authority == "failure" {
            #expect(service.opens.count == opens && store.selectedBotID == selected)
            #expect(store.notificationNavigationRevision == revision)
        }
        if authority == "failure" {
            clock.addTimeInterval(301); service.pushStatusError = nil
            await store.refresh()
            for _ in 0..<1_000 where store.chats.selection(profile: target.profile)?.identity?.root != target.root { await Task.yield() }
        }
        if authority != "removed" {
            #expect(store.selectedBotID == target.profile.text)
            #expect(store.chats.selection(profile: target.profile)?.identity?.root == target.root)
            #expect(service.opens.count == opens + 1)
            #expect(store.chats.screen(profile: target.profile)?.canAct == true)
        } else {
            #expect(vault.saved.pairings.first { $0.deviceID == pairing.deviceID }?.retirement?.reason == .removed)
            await store.open(try #require(store.bots.first { $0.id == target.profile.text }))
            #expect(store.chats.screen(profile: target.profile)?.canAct == true)
        }
        if entry == "other-profile" { #expect(store.push.selectedProfileID == service.profile.text) }
        #expect(service.connectionAttempts == 1 && service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test func forgettingAnUnpairedHostDoesNotCarryAnOptionalPluginWarningToWelcome() async throws {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://without-push.invalid")!,
            username: "owner", installID: "fixture-install")
        let connection = MemoryConnectionStorage(saved: configuration)
        let vault = NotificationVaultFixture()
        let push = PushCoordinator(persistence: vault.persistence,
            authorization: .init(requestPermission: { false }, deviceToken: { throw PushError.tokenUnavailable }))
        let store = AppStore(service: service, persistence: connection.persistence, push: push)
        defer { LocalHistory.remove(for: configuration.id) }
        service.pushStatusError = HermesServiceError.rejected(404)
        await push.refresh()
        #expect(push.notice?.contains("Install the Botto push plugin") == true)

        await store.forgetConnectionWithPush()

        #expect(store.configuration == nil && connection.saved == nil)
        #expect(store.notice == nil)
        #expect(vault.saved.pairings.isEmpty && vault.saved.removals.isEmpty)
        #expect(service.pushEnrollments.isEmpty)
    }

    @Test func unreadablePushStorageAfterProfileSelectionExplainsWhyForgetFailed() async throws {
        let (_, service, connection, _) = try fixture()
        let before = try #require(connection.saved)
        let push = PushCoordinator(persistence: .init(
            load: { throw PushError.unavailableStorage },
            save: { _ in throw PushError.unavailableStorage }))
        let store = AppStore(service: service, persistence: connection.persistence, push: push)
        push.configureProfiles([.init(id: "first", name: "First"), .init(id: "second", name: "Second")])
        push.bind(service: service, configuration: before, isDemo: false, profileID: "first")
        await push.selectProfile("second")
        #expect(push.storageUnavailable && push.notice == nil)

        await store.forgetConnectionWithPush()

        #expect(store.configuration == before && connection.saved == before)
        #expect(store.notice?.isEmpty == false)
    }

    @Test func failedSecurePreviewRemovalPreservesTheSavedHost() async throws {
        let (store, _, connection, vault) = try fixture()
        let before = connection.saved
        vault.failsSave = true

        await store.forgetConnectionWithPush()

        #expect(store.configuration == before && connection.saved == before)
        #expect(vault.saved.pairings.count == 1)
        #expect(store.notice != nil)
    }

    @Test(arguments: ["current", "disabled", "remote"])
    func pairingRetirementDuringAnOpenRejectsLateSnapshotsAndGrants(authority: String) async throws {
        let (store, service, connection, vault) = try fixture()
        let configuration = try #require(connection.saved)
        defer { LocalHistory.remove(for: configuration.id) }
        let pairing = try #require(vault.saved.pairings.first)
        service.pushStatusResult = .init(pluginVersion: "fixture", supported: true,
            installationID: pairing.installationID, relayURL: URL(string: "https://relay.invalid"),
            devices: [.init(deviceID: pairing.deviceID, generation: 1, active: true, state: .active)])
        #expect(await store.connect(configuration))
        await store.open(try #require(store.bots.first))
        let original = try #require(store.chats.selection(profile: service.profile))
        let preference = store.history.book.preference(service.profile)?.lastSelected
        let revision = store.notificationNavigationRevision
        let target = service.summaries[1].identity
        let envelope = try notification(target, pairing: pairing)
        let gate = WorkspaceGate()
        service.openGate = gate
        let tap = Task { await store.openPushNotification(envelope) }
        await gate.entered()
        if authority == "disabled" { await store.push.disable() }
        if authority == "remote" {
            service.pushStatusResult?.devices = [.init(deviceID: pairing.deviceID, generation: 2, active: false, state: .removed)]
            await store.push.refresh()
        }
        #expect(store.isConnected && service.opens.count == 2)
        service.openGate = nil; gate.release()
        await tap.value
        if authority == "current" {
            #expect(store.chats.selection(profile: service.profile)?.snapshot?.id == target.root.text)
            #expect(store.notificationNavigationRevision != revision)
        } else {
            #expect(store.chats.selection(profile: service.profile)?.identity == original.identity)
            #expect(store.chats.selection(profile: service.profile)?.snapshot?.id == original.snapshot?.id)
            #expect(store.history.book.preference(service.profile)?.lastSelected == preference)
            #expect(store.notificationNavigationRevision == revision)
        }
        let late = try #require(service.completedOpens.last)
        service.onEvent?(.conversation(late))
        if authority != "current" {
            let selection = try #require(store.chats.selection(profile: service.profile))
            #expect(selection.identity == original.identity)
            #expect(store.history.book.records.first { $0.binding.identity?.root == target.root }?.transcript == nil)
            #expect(store.chats.screen(profile: service.profile)?.canAct == false)
            #expect(store.notificationNavigationRevision == revision)
            await store.open(try #require(store.bots.first))
            let main = try #require(store.chats.screen(profile: service.profile))
            let other = try #require(store.chats.cards(profile: service.profile).first { !$0.isMain }?.id)
            await store.chats.select(try #require(store.chats.captureSelection(other, owner: main.owner)))
            let fresh = try #require(store.chats.screen(profile: service.profile))
            #expect(store.chats.screen(profile: service.profile)?.canAct == true)
            #expect(store.chats.selection(profile: service.profile)?.identity?.root == target.root)
            #expect(!store.push.isEnabled)
            service.onEvent?(.conversation(late))
            #expect(store.chats.isCurrent(fresh.owner))
        }
        #expect(service.opens.count == (authority == "current" ? 2 : 4) && service.connectionAttempts == 1)
        #expect(service.sends.isEmpty && service.responses.isEmpty && service.creates.isEmpty)
    }

    @Test func openingSettingsDoesNotLoseTheKnownNotificationTestDestination() async throws {
        let (store, service, connection, _) = try fixture()
        defer { if let id = connection.saved?.id { LocalHistory.remove(for: id) } }
        #expect(await store.connect(try #require(connection.saved)))
        await store.open(try #require(store.bots.first))
        let screen = try #require(store.chats.screen(profile: service.profile))
        store.chats.setTranscriptVisible(false, owner: screen.owner)

        #expect(store.push.selectedProfileID == service.profile.text)
        #expect(store.notificationTestDestination?.rootID == service.summaries[0].identity.root.text)
    }

    @Test func pendingForgetCannotRemoveAReplacementConnectionOrItsDraft() async throws {
        let (store, service, connection, _) = try fixture()
        let oldID = try #require(connection.saved?.id)
        let gate = WorkspaceGate()
        service.pushRemovalGate = gate
        let forgetting = Task { await store.forgetConnectionWithPush() }
        await gate.entered()
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.invalid")!, username: "owner")
        defer { LocalHistory.remove(for: oldID); LocalHistory.remove(for: replacement.id) }
        #expect(await store.connect(replacement))
        await store.open(try #require(store.bots.first))
        let screen = try #require(store.chats.screen(profile: service.profile))
        store.chats.editDraft("Keep this draft", owner: screen.owner)
        let workspace = store.chats
        gate.release()
        await forgetting.value

        #expect(store.configuration?.id == replacement.id && connection.saved?.id == replacement.id)
        #expect(store.chats === workspace && store.isConnected)
        #expect(store.draft(for: service.profile.text) == "Keep this draft")
    }

    @Test func enteringDemoDuringForgetPreservesTheSavedHost() async throws {
        let (store, service, connection, _) = try fixture()
        let saved = try #require(connection.saved)
        defer { LocalHistory.remove(for: saved.id) }
        let gate = WorkspaceGate()
        service.pushRemovalGate = gate
        let forgetting = Task { await store.forgetConnectionWithPush() }
        await gate.entered()
        await store.enterDemo()
        let workspace = store.chats
        gate.release()
        await forgetting.value

        #expect(store.isDemo && store.chats === workspace)
        #expect(connection.saved == saved)
    }

    @Test(arguments: [false, true]) func replacingTheHostRetiresPendingEnrollmentBeforeItsRosterReturns(holdsOldTokenAwait: Bool) async throws {
        let tokenGate = WorkspaceGate()
        let authorization = PushAuthorization(requestPermission: { true }, deviceToken: {
            if holdsOldTokenAwait { await tokenGate.wait() }
            return String(repeating: "2", count: 64)
        })
        let (store, service, connection, vault) = try fixture(authorization: authorization, pendingEnrollment: true)
        let oldID = try #require(connection.saved?.id)
        let original = try #require(vault.saved.pairings.first)
        service.pushStatusResult = .init(pluginVersion: "fixture", supported: true,
            installationID: String(repeating: "d", count: 64), relayURL: URL(string: "https://relay.invalid"))
        let oldResume = holdsOldTokenAwait ? Task { await store.push.resume() } : nil
        if holdsOldTokenAwait { await tokenGate.entered() }
        let rosterGate = WorkspaceGate()
        service.rosterGate = rosterGate
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.invalid")!,
            username: "replacement-owner", installID: "replacement-install")
        defer { LocalHistory.remove(for: oldID); LocalHistory.remove(for: replacement.id) }
        let replacing = Task { await store.connect(replacement) }
        await rosterGate.entered()
        tokenGate.release()
        await oldResume?.value
        await store.push.didRegister(token: String(repeating: "3", count: 64))

        #expect(service.connectedConfiguration?.id == replacement.id)
        #expect(service.pushEnrollments.isEmpty)
        #expect(vault.saved.pairings.first == original)
        rosterGate.release()
        #expect(await replacing.value)
    }

    @Test func unreadableSavedSetupCanRetireReadablePairingsAndForgetCredentials() async throws {
        let (_, service, connection, vault) = try fixture()
        let savedID = try #require(connection.saved?.id)
        defer { LocalHistory.remove(for: savedID) }
        var malformedCredentialExists = true
        let persistence = ConnectionPersistence(load: {
            if malformedCredentialExists { throw HermesServiceError.invalidResponse }
            return nil
        }, save: { _ in throw HermesServiceError.invalidResponse }, remove: { malformedCredentialExists = false })
        let push = PushCoordinator(persistence: vault.persistence,
            authorization: .init(requestPermission: { false }, deviceToken: { throw PushError.tokenUnavailable }))
        let store = AppStore(service: service, persistence: persistence, push: push)

        await store.forgetConnectionWithPush()

        #expect(!malformedCredentialExists && store.configuration == nil && !store.savedSetupLoadFailed)
        #expect(vault.saved.pairings.isEmpty && vault.saved.removals.count == 1)
        #expect(store.notice != nil)
    }

    @Test func forgettingUnreadableSetupPurgesCapturesWithoutKnowingItsConfigurationID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try WorkspaceTestService(), source = try #require(service.summaries.first?.identity)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let key = ArtifactOriginalKey(identity: source, messageID: Data("private".utf8), path: Data("/private.txt".utf8), sourceRevision: Data("revision".utf8))
        let cache = ArtifactCache(root: root), saved = cache.session(scope: scope)
        try await saved.upsert(.init(identity: source, botName: "Bot", title: "Private",
            messages: [.init(id: "private", role: .assistant, text: "MEDIA:/private.txt")], updatedAt: nil,
            coverage: .complete, summary: nil, headFingerprint: nil))
        try await saved.retainOriginal(.init(data: Data("private capture".utf8), filename: "private.txt", mimeType: "text/plain"), for: key)
        var unreadable = true
        let store = AppStore(service: service, persistence: .init(load: {
            if unreadable { throw HermesServiceError.invalidResponse }
            return nil
        }, save: { _ in }, remove: { unreadable = false }), artifactCache: cache)
        #expect(store.savedSetupLoadFailed && store.configuration == nil)
        #expect(try await saved.original(for: key)?.artifact.data == Data("private capture".utf8))
        store.forgetConnection()
        try await cache.drainMaintenance()
        await cache.close()
        let reopenedCache = ArtifactCache(root: root), reopened = reopenedCache.session(scope: scope)
        #expect(!unreadable && !store.savedSetupLoadFailed)
        #expect(try await reopened.loadChats().isEmpty)
        #expect(try await reopened.original(for: key) == nil)
        await reopenedCache.close()
    }
}
