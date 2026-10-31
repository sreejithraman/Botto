import Foundation
import Testing
import UIKit
import BottoCore
@testable import Botto

@MainActor struct AppStoreAvatarTests {
    @Test(arguments: [false, true])
    func foregroundRecoveryStaysNeutralUntilTheConnectionResult(fails: Bool) async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://foreground-avatar.example")!)
        defer { LocalHistory.remove(for: connection.id) }
        let bot = BotProfile(id: "milo", name: "Milo")
        let service = StoreTestService()
        service.profiles = [bot]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: connection).persistence)
        await store.start()
        await store.testEdit("Keep my draft", for: bot.id)

        for _ in 0..<3 {
            let retiredCallback = try #require(service.onEvent)
            await store.setActive(false)
            retiredCallback(.disconnected("Retired socket"))
            for scope in [BotAvatarScope.profile, .selectedChat] {
                #expect(store.avatarPresentation(for: bot, scope: scope).activity == .idle)
                #expect(store.avatarPresentation(for: bot, scope: scope).accessibilityStatus == nil)
            }
            #expect(!store.isConnected)
            #expect(store.draft(for: bot.id) == "Keep my draft")

            let barrier = StoreTestBarrier()
            service.connectBarrier = barrier
            service.connectError = fails ? HermesServiceError.disconnected : nil
            let foreground = Task { await store.setActive(true) }
            await barrier.waitUntilEntered()
            let attempts = service.connectCount
            await store.setActive(true)
            #expect(service.connectCount == attempts)
            for scope in [BotAvatarScope.profile, .selectedChat] {
                #expect(store.avatarPresentation(for: bot, scope: scope).activity == .idle)
                #expect(store.avatarPresentation(for: bot, scope: scope).accessibilityStatus == nil)
            }
            #expect(!store.isConnected)
            barrier.release()
            await foreground.value
            service.connectBarrier = nil
            #expect(store.isConnected == !fails)
            #expect(store.draft(for: bot.id) == "Keep my draft")
            for scope in [BotAvatarScope.profile, .selectedChat] {
                #expect((store.avatarPresentation(for: bot, scope: scope).activity == .offline) == fails)
                #expect(store.avatarPresentation(for: bot, scope: scope).accessibilityStatus == (fails ? "Offline" : nil))
            }
        }
    }

    @Test(arguments: [false, true])
    func savedSetupDoesNotShowOfflineBeforeTheStartupConnectionResult(fails: Bool) async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://startup-avatar.example")!)
        defer { LocalHistory.remove(for: connection.id) }
        let bot = BotProfile(id: "milo", name: "Milo", status: .working)
        var history = LocalHistory()
        history.bots = [bot]
        try history.fixtureDraft("Saved draft", profile: bot.id)
        try history.save(for: connection.id)
        let service = StoreTestService()
        service.profiles = [bot]
        if fails { service.connectError = HermesServiceError.disconnected }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: connection).persistence)

        #expect(store.link == .connecting)
        for scope in [BotAvatarScope.profile, .selectedChat] {
            let initial = store.avatarPresentation(for: bot, scope: scope)
            #expect(initial.activity == .idle)
            #expect(initial.accessibilityStatus == nil)
        }
        #expect(!store.isConnected)
        #expect(store.draft(for: bot.id) == "Saved draft")

        await store.start()
        #expect(store.link == (fails ? .offline : .online))
        #expect(store.draft(for: bot.id) == "Saved draft")
        for scope in [BotAvatarScope.profile, .selectedChat] {
            let result = store.avatarPresentation(for: bot, scope: scope)
            #expect((result.activity == .offline) == fails)
            #expect(result.accessibilityStatus == (fails ? "Offline" : nil))
        }
    }

    @Test func chatSenderAvatarUsesAnExactLocalProfileBeforeDisplayName() throws {
        let message = ChatMessage(id: "sender", role: .user, text: "Message from 🤖 Gustavo (@hermes): Hello", displayKind: "internal_notification")
        let sender = try #require(message.botSender)
        let exact = BotProfile(id: "hermes", name: "Renamed Gustavo", appearance: .init(shape: .sun, color: "#8b5cf6"))
        let sameName = BotProfile(id: "other", name: "Gustavo")
        #expect(ChatSenderAvatar.profile(for: sender, among: [sameName, exact]) == exact)
        #expect(ChatSenderAvatar.profile(for: sender, among: [sameName]) == sameName)
    }

    @Test func chatSenderAvatarDoesNotBorrowAmbiguousOrRemoteIdentity() throws {
        let local = try #require(ChatMessage(id: "local", role: .user,
            text: "Message from 🤖 Gustavo (@hermes): Hello", displayKind: "internal_notification").botSender)
        let one = BotProfile(id: "one", name: "Gustavo"), two = BotProfile(id: "two", name: "Gustavo")
        #expect(ChatSenderAvatar.profile(for: local, among: [one, two]) == nil)
        #expect(ChatSenderAvatar.profile(for: local, among: [.init(id: "hermes", name: "One"), .init(id: "hermes", name: "Two")]) == nil)
        let remote = try #require(ChatMessage(id: "remote", role: .user,
            text: "Message from 🤖 Gustavo (@home/hermes): Hello", displayKind: "internal_notification").botSender)
        #expect(ChatSenderAvatar.profile(for: remote, among: [one, .init(id: "home/hermes", name: "Gustavo")]) == nil)
        let qualified = try #require(ChatMessage(id: "qualified", role: .user,
            text: "Message from 🤖 Gustavo (@hermes@home): Hello", displayKind: "internal_notification").botSender)
        #expect(ChatSenderAvatar.profile(for: qualified, among: [one, .init(id: "hermes", name: "Gustavo")]) == nil)
        #expect(ChatSenderAvatar.profile(for: local, among: [.init(id: "unknown", name: "Different")]) == nil)
    }

    @Test func chatSenderAvatarKeepsWireDistinctNamesSeparate() throws {
        let sender = try #require(ChatMessage(id: "accented", role: .user,
            text: "Message from 🤖 é (@sender): Hello", displayKind: "internal_notification").botSender)
        let canonical = BotProfile(id: "one", name: "é"), decomposed = BotProfile(id: "two", name: "e\u{301}")
        #expect(ChatSenderAvatar.profile(for: sender, among: [canonical, decomposed]) == canonical)
        #expect(ChatSenderAvatar.profile(for: sender, among: [decomposed]) == nil)
    }

    @Test func disconnectSleepsWithOfflineCueAndRecoveryClearsItForEveryAvatarScope() async throws {
        let service = StoreTestService()
        service.profiles = [.init(id: "milo", name: "Milo")]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://offline-avatar.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let bot = try #require(store.bots.first)
        for _ in 0..<2 {
            service.onEvent?(.disconnected("Lost connection"))
            for scope in [BotAvatarScope.profile, .selectedChat] {
                let presentation = store.avatarPresentation(for: bot, scope: scope)
                #expect(presentation.activity == .offline)
                #expect(presentation.accessibilityStatus == "Offline")
                #expect(presentation.workStartedAt == nil)
                #expect(presentation.reactionID == nil)
            }
            service.onEvent?(.connected(ServerInfo(version: "test")))
            for scope in [BotAvatarScope.profile, .selectedChat] {
                #expect(store.avatarPresentation(for: bot, scope: scope).activity == .idle)
                #expect(store.avatarPresentation(for: bot, scope: scope).accessibilityStatus == nil)
            }
        }
    }

    @Test func profileSavePreservesAvatarAndReportsPartialCombinedSaveWithoutReplay() async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://profile-edit.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        try await store.saveProfile(.init(name: "New visible name", description: "A useful introduction"), avatar: nil, to: destination)
        #expect(service.profileSaves == 1 && service.saves == 0)
        #expect(store.bots[0].id == destination.profile.id && store.bots[0].hasAvatar == true)
        #expect(store.bots[0].name == "New visible name" && store.bots[0].description == "A useful introduction")
        let current = try #require(store.avatarDestination(for: store.bots[0]))
        service.saveError = .uncertainAvatar
        await #expect(throws: HermesServiceError.partialProfile) {
            try await store.saveProfile(.init(name: "Saved before the avatar failed"), avatar: .automatic, to: current)
        }
        #expect(service.profileSaves == 2 && service.saves == 1)
        service.saveError = nil
        let reloaded = try await store.reloadAvatar(current)
        #expect(reloaded.profile.name == "Saved before the avatar failed")
        #expect(service.profileSaves == 2 && service.saves == 1)
    }

    @Test func cachedAvatarCanOpenOfflineAndSaveOnlyAfterDeliberateOnlineAttempt() async throws {
        let service = AvatarService(); service.holdImages = false
        let storage = AvatarStorage()
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://cached-avatars.example")!)
        storage.value = connection
        var cached = LocalHistory(); cached.bots = service.profiles
        try cached.save(for: connection.id)
        let store = AppStore(service: service, persistence: storage.persistence)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(!store.isConnected)
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        await #expect(throws: HermesServiceError.disconnected) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 0)
        #expect(await store.connect(connection))
        #expect(service.saves == 0)
        try await store.saveAvatar(.face(.init(shape: .drop, color: "#22c55e")), to: destination)
        #expect(service.saves == 1)
        #expect(store.bots[0].face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
    }

    @Test(arguments: ["background", "transport", "reconnect"])
    func sameAccountRecoveryKeepsAvatarDraftValidWithoutRetry(recovery: String) async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://recovery-avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        if recovery == "transport" {
            service.onEvent?(.disconnected("Lost connection"))
            #expect(destination.isCurrent(in: store))
            service.onEvent?(.connected(ServerInfo(version: "test")))
        } else {
            if recovery == "background" { await store.setActive(false) }
            #expect(destination.isCurrent(in: store))
            #expect(await store.connect(connection))
        }
        #expect(destination.isCurrent(in: store))
        #expect(service.saves == 0)
        try await store.saveAvatar(.automatic, to: destination)
        #expect(service.saves == 1)
    }

    @Test(arguments: ["password", "token", "installation"])
    func sameAccountCredentialUpdatesKeepLocalAvatarDraft(change: String) async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        var connection = ConnectionConfiguration(serverURL: URL(string: "https://credentials-avatars.example")!, username: "alice",
                                                  nativeCredential: NativeCredential(refreshToken: "before", provider: "native"))
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        switch change {
        case "password": connection.password = "replacement"
        case "token": connection.nativeCredential?.refreshToken = "after"
        default: connection.installID = "discovered-installation"
        }
        if change == "token" { service.onEvent?(.configuration(connection)) }
        else { #expect(await store.connect(connection)) }
        #expect(destination.isCurrent(in: store))
        #expect(service.saves == 0)
        try await store.saveAvatar(.automatic, to: destination)
        #expect(service.saves == 1)
    }

    @Test func uncertainSaveIsNotRetriedByRecoveryOrReload() async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://uncertain-avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        service.saveError = .uncertainAvatar
        await #expect(throws: HermesServiceError.uncertainAvatar) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 1)
        service.saveError = nil
        #expect(await store.connect(connection))
        let reloaded = try await store.reloadAvatar(destination)
        #expect(service.saves == 1)
        try await store.saveAvatar(.automatic, to: reloaded)
        #expect(service.saves == 2)
    }

    @Test(arguments: ["appearance", "image"])
    func authoritativeAvatarConflictRequiresReloadBeforeDeliberateSave(change: String) async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://conflict-avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        if change == "appearance" { service.profiles[0].appearance = BotAppearance(shape: .hexagon, color: "#ec4899") }
        else { service.profiles[0].hasAvatar = false }
        let fresh = service.profiles
        await store.refresh()
        await #expect(throws: HermesServiceError.avatarConflict) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 1 && service.mutations == 0)
        #expect(service.profiles == fresh)
        let reloaded = try await store.reloadAvatar(destination)
        try await store.saveAvatar(.automatic, to: reloaded)
        #expect(service.saves == 2 && service.mutations == 1)
    }

    @Test func unrelatedRosterFailureCannotBlockSaveAndPublicationFailureDoesNotRetry() async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://roster-failure-avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        let visible = store.bots
        service.failRoster = true
        await #expect(throws: HermesServiceError.avatarRefresh) {
            try await store.saveAvatar(.face(.init(shape: .drop, color: "#22c55e")), to: destination)
        }
        #expect(service.saves == 1 && service.mutations == 1)
        #expect(service.profiles[0].face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
        #expect(service.profiles[0].hasAvatar == false)
        #expect(store.bots == visible)
        service.failRoster = false
        #expect(await store.connect(connection))
        _ = try await store.reloadAvatar(destination)
        #expect(service.saves == 1 && service.mutations == 1)
        #expect(store.bots[0].face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
    }

    @Test func duplicateAvatarSaveCannotWriteWhileFirstSaveAwaitsRosterPublication() async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://duplicate-avatars.example")!)
        defer { store.forgetConnection(); service.releaseRosters(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        service.holdRoster = true
        let save = Task { try await store.saveAvatar(.face(.init(shape: .drop, color: "#22c55e")), to: destination) }
        try await avatarEventually { !service.pendingRosters.isEmpty }
        await #expect(throws: HermesServiceError.avatarConflict) {
            try await store.saveAvatar(.automatic, to: destination)
        }
        #expect(service.saves == 1 && service.mutations == 1)
        service.holdRoster = false; service.releaseRosters()
        try await save.value
        #expect(store.bots[0].face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
        #expect(service.saves == 1 && service.mutations == 1)
    }

    @Test func authoritativeTargetReadFailureCannotMutateAndRecoveryDoesNotRetry() async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://target-read-avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        let original = service.profiles
        service.targetReadError = .timeout
        await #expect(throws: HermesServiceError.timeout) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 1 && service.mutations == 0)
        #expect(service.profiles == original)
        service.targetReadError = nil
        #expect(await store.connect(connection))
        let reloaded = try await store.reloadAvatar(destination)
        #expect(service.saves == 1 && service.mutations == 0)
        try await store.saveAvatar(.automatic, to: reloaded)
        #expect(service.saves == 2 && service.mutations == 1)
        #expect(service.profiles[0].hasAvatar == false)
    }

    @Test(arguments: [false, true]) func interruptedServiceTargetReadCannotWriteAfterReconnect(reconnect: Bool) async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://interrupted-avatars.example")!)
        defer { store.forgetConnection(); service.pendingTargetRead?.resume(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        let original = service.profiles
        service.holdTargetRead = true
        let save = Task { try await store.saveAvatar(.automatic, to: destination) }
        try await avatarEventually { service.pendingTargetRead != nil }
        await store.setActive(false)
        service.holdTargetRead = false
        if reconnect { #expect(await store.connect(connection)) }
        service.pendingTargetRead?.resume(); service.pendingTargetRead = nil
        await #expect(throws: HermesServiceError.disconnected) { try await save.value }
        #expect(service.saves == 1 && service.mutations == 0)
        #expect(service.profiles == original)
        #expect(destination.isCurrent(in: store))
        if !reconnect { #expect(await store.connect(connection)) }
        try await store.saveAvatar(.automatic, to: destination)
        #expect(service.saves == 2 && service.mutations == 1)
    }

    @Test(arguments: ["forget", "workspace", "account", "provider", "origin", "installation", "demo"])
    func avatarDraftRejectsRevokedWorkspaceOrAccount(change: String) async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        var connection = ConnectionConfiguration(serverURL: URL(string: "https://owned-avatars.example")!, username: "alice", installID: "first")
        let original = connection
        let originalID = connection.id
        defer { store.forgetConnection(); LocalHistory.remove(for: originalID); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        switch change {
        case "forget": store.forgetConnection()
        case "demo": await store.enterDemo()
        default:
            switch change {
            case "workspace": connection.id = UUID()
            case "account": connection.username = "bob"
            case "provider": connection.nativeCredential = NativeCredential(refreshToken: "test", provider: "other")
            case "origin": connection.serverURL = URL(string: "https://other-avatars.example")!
            default: connection.installID = "second"
            }
            #expect(await store.connect(connection))
        }
        #expect(!destination.isCurrent(in: store))
        await #expect(throws: HermesServiceError.disconnected) { try await store.saveAvatar(.automatic, to: destination) }
        await #expect(throws: HermesServiceError.disconnected) { _ = try await store.reloadAvatar(destination) }
        #expect(service.saves == 0)
        #expect(await store.connect(original))
        #expect(!destination.isCurrent(in: store))
        await #expect(throws: HermesServiceError.disconnected) { try await store.saveAvatar(.automatic, to: destination) }
        await #expect(throws: HermesServiceError.disconnected) { _ = try await store.reloadAvatar(destination) }
        #expect(service.saves == 0)
        let reopened = try #require(store.avatarDestination(for: store.bots[0]))
        try await store.saveAvatar(.automatic, to: reopened)
        #expect(service.saves == 1)
    }

    @Test(arguments: ["account", "provider", "installation"])
    func configurationEventPermanentlyRevokesOldAvatarDraft(change: String) async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let original = ConnectionConfiguration(serverURL: URL(string: "https://event-avatars.example")!, username: "alice")
        defer { store.forgetConnection(); LocalHistory.remove(for: original.id) }
        #expect(await store.connect(original))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        var changed = original
        switch change {
        case "account": changed.username = "bob"
        case "provider": changed.nativeCredential = NativeCredential(refreshToken: "test", provider: "other")
        default:
            changed.installID = "discovered"
            service.onEvent?(.configuration(changed))
            #expect(destination.isCurrent(in: store))
            changed.installID = "replacement"
        }
        service.onEvent?(.configuration(changed))
        #expect(!destination.isCurrent(in: store))
        service.onEvent?(.configuration(original))
        #expect(!destination.isCurrent(in: store))
        await #expect(throws: HermesServiceError.disconnected) { try await store.saveAvatar(.automatic, to: destination) }
        await #expect(throws: HermesServiceError.disconnected) { _ = try await store.reloadAvatar(destination) }
        #expect(service.saves == 0)
        let reopened = try #require(store.avatarDestination(for: store.bots[0]))
        try await store.saveAvatar(.automatic, to: reopened)
        #expect(service.saves == 1)
    }

    @Test func failedWorkspaceReplacementKeepsOriginalAvatarDraft() async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let original = ConnectionConfiguration(serverURL: URL(string: "https://failed-replacement-avatars.example")!, username: "alice")
        var replacement = original; replacement.username = "bob"
        defer { store.forgetConnection(); LocalHistory.remove(for: original.id) }
        #expect(await store.connect(original))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        service.connectError = .timeout
        #expect(!(await store.connect(replacement)))
        #expect(destination.isCurrent(in: store))
        #expect(service.saves == 0)
        service.connectError = nil
        #expect(await store.connect(original))
        try await store.saveAvatar(.automatic, to: destination)
        #expect(service.saves == 1)
    }

    @Test func explicitSavePublishesSharedLookAndRetiredEditorCannotWrite() async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        try await store.saveAvatar(.face(.init(shape: .drop, color: "#22c55e")), to: destination)
        #expect(store.bots[0].face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
        #expect(store.bots[0].hasAvatar == false)
        #expect(store.avatar(for: store.bots[0]) == nil)
        #expect(service.saves == 1 && store.notice == nil)
        await store.setActive(false)
        await #expect(throws: HermesServiceError.disconnected) {
            try await store.saveAvatar(.automatic, to: destination)
        }
        #expect(service.saves == 1)
    }

    @Test(arguments: ["cancel", "background", "transport", "reconnect", "demo", "replacement"])
    func retiredSaveCannotPublishIntoCurrentWorkspace(retirement: String) async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let first = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        let second = ConnectionConfiguration(serverURL: URL(string: "https://replacement.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: first.id); LocalHistory.remove(for: second.id) }
        #expect(await store.connect(first))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        service.holdSave = true
        let save = Task { try await store.saveAvatar(.face(.init(shape: .hexagon, color: "#ec4899")), to: destination) }
        try await avatarEventually { service.pendingSave != nil }
        switch retirement {
        case "cancel": save.cancel()
        case "background": await store.setActive(false)
        case "transport":
            service.onEvent?(.disconnected("Lost connection"))
            service.onEvent?(.connected(ServerInfo(version: "test")))
            await store.refresh()
        case "reconnect": #expect(await store.connect(first))
        case "demo":
            await store.enterDemo()
            let profiles = Set(try store.bots.map { try ExactID($0.id) })
            await store.chats.refreshInboxPreviews(profiles: profiles)
        default:
            service.profiles = [BotProfile(id: "shared", name: "Replacement")]
            #expect(await store.connect(second))
        }
        let visible = store.bots
        service.pendingSave?.resume(); service.pendingSave = nil
        await #expect(throws: HermesServiceError.disconnected) { try await save.value }
        #expect(store.bots == visible)
        #expect(service.saves == 1 && store.notice == nil)
    }

    @Test func slowAvatarDoesNotBlockRosterOrCreationAndOldHostCannotPublish() async throws {
        let service = AvatarService()
        let storage = AvatarStorage()
        let store = AppStore(service: service, persistence: storage.persistence)
        let first = ConnectionConfiguration(serverURL: URL(string: "https://first.example")!)
        let second = ConnectionConfiguration(serverURL: URL(string: "https://second.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: first.id); LocalHistory.remove(for: second.id) }
        #expect(await store.connect(first))
        #expect(store.bots.map(\.id) == ["shared"])
        try await avatarEventually { service.pending.count == 1 }
        #expect(!store.isRefreshing)
        let created = await store.create(.init(name: "New", avatar: .face(.init(shape: .drop, color: "#22c55e"))))
        #expect(created?.id == "new")
        #expect(store.bots.contains { $0.id == "new" })
        service.profiles = [BotProfile(id: "shared", name: "Other host", hasAvatar: false)]
        #expect(await store.connect(second))
        service.releaseImages()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.avatar(for: store.bots[0]) == nil)
        #expect(store.bots[0].name == "Other host")
        #expect(store.notice == nil)
    }

    @Test func revisionCacheRemovalAndImageFailuresStayLocal() async throws {
        let diagnostic = NativeTestDiagnostics(method: #function)
        defer { diagnostic.finish() }
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        func diagnostics() -> String {
            let bot = store.bots.first
            return """
            capturedAt=\(Date.now.timeIntervalSince1970)
            reads=\(service.reads)
            loading=\(bot.map { store.isLoadingAvatar(for: $0) } ?? false)
            image=\(bot.flatMap { store.avatar(for: $0) } != nil)
            revision=\(String(describing: bot?.lookRevision))
            failImages=\(service.failImages)
            pending=\(service.pending.count)
            """
        }
        #expect(await store.connect(connection))
        try await avatarEventually("Initial avatar decoded", diagnostics: diagnostics) { store.avatar(for: store.bots[0]) != nil }
        #expect(service.reads == 1)
        #expect(store.avatar(for: store.bots[0])?.size == CGSize(width: 192, height: 192))
        await store.refresh()
        try await Task.sleep(for: .milliseconds(30))
        #expect(service.reads == 1)
        service.profiles[0].lookRevision = 2
        service.failImages = true
        await store.refresh()
        try await avatarEventually("Changed revision requested", diagnostics: diagnostics) { service.reads == 2 }
        #expect(store.avatar(for: store.bots[0]) == nil)
        #expect(store.notice == nil && store.isConnected)
        service.failImages = false; service.profiles[0].lookRevision = nil
        await store.refresh()
        try await avatarEventually("Unknown revision avatar decoded", diagnostics: diagnostics) { store.avatar(for: store.bots[0]) != nil }
        let reads = service.reads
        await store.refresh()
        try await avatarEventually("Unknown revision requested again", diagnostics: diagnostics) { service.reads > reads }
        service.profiles[0].hasAvatar = false
        await store.refresh()
        #expect(store.avatar(for: store.bots[0]) == nil)
    }

    @Test(arguments: ["image/png", "image/jpeg", "image/webp"])
    func hermesPetAndImageAssetsKeepAspectAndTransparency(mime: String) async throws {
        let diagnostic = NativeTestDiagnostics(method: #function, argument: mime)
        defer { diagnostic.finish() }
        let pet = mime != "image/jpeg"
        let size = pet ? CGSize(width: 96, height: 104) : CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = !pet
        let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(pet ? CGRect(x: 24, y: 20, width: 48, height: 64) : CGRect(origin: .zero, size: size))
        }
        let bytes: Data
        switch mime {
        case "image/png": bytes = try #require(source.pngData())
        case "image/jpeg": bytes = try #require(source.jpegData(compressionQuality: 0.9))
        default:
            // Lossless 96x104 RGBA fixture with the same red rectangle and transparent border.
            bytes = try #require(Data(base64Encoded: "UklGRi4AAABXRUJQVlA4TCEAAAAvX8AZEA8Q8x/zHwy1bdsw/v/pluxtiuj/BGDibD/fsAEA"))
        }
        let service = AvatarService(); service.holdImages = false
        service.suppliedAsset = BotAvatarAsset(data: bytes, mimeType: mime)
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        try await avatarEventually { !store.isLoadingAvatar(for: store.bots[0]) }
        let image = try #require(store.avatar(for: store.bots[0]))
        #expect(abs(image.size.width / image.size.height - size.width / size.height) < 0.001)
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        #expect(pixels[3] == (pet ? 0 : 255))
        #expect(pixels[((height / 2) * width + width / 2) * 4 + 3] == 255)
    }

    @Test(arguments: [false, true]) func desktopFaceCopyFallsBackButPhotoRemains(photo: Bool) async throws {
        let service = AvatarService(); service.holdImages = false; service.imageSize = 160
        service.profiles[0].appearance = BotAppearance(imageKind: photo ? "photo" : "shape")
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        try await avatarEventually { service.reads == 1 && !store.isLoadingAvatar(for: store.bots[0]) }
        #expect((store.avatar(for: store.bots[0]) != nil) == photo)
    }

    @Test(arguments: [false, true]) func explicitRefreshRevalidatesChangedImageWithUnchangedLook(editor: Bool) async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); service.releaseImages(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        try await avatarEventually { store.avatar(for: store.bots[0]) != nil }
        let before = try #require(store.avatar(for: store.bots[0])?.pngData())
        let profile = store.bots[0]
        service.imageColor = .blue
        for _ in 0..<3 { await store.refresh() }
        #expect(service.reads == 1)
        if editor {
            let destination = try #require(store.avatarDestination(for: profile))
            _ = try await store.reloadAvatar(destination)
        } else { await store.refresh(revalidateAvatars: true) }
        try await avatarEventually { service.reads == 2 && !store.isLoadingAvatar(for: store.bots[0]) }
        #expect(store.bots[0] == profile)
        #expect(try #require(store.avatar(for: store.bots[0])?.pngData()) != before)
        #expect(service.saves == 0 && store.notice == nil)
    }

    @Test func cachedImageExpiresWithoutFetchingOnEveryRoster() async throws {
        let service = AvatarService(); service.holdImages = false
        var now = Date(timeIntervalSince1970: 1_000)
        let store = AppStore(service: service, persistence: AvatarStorage().persistence, avatarNow: { now })
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        try await avatarEventually { store.avatar(for: store.bots[0]) != nil }
        let before = try #require(store.avatar(for: store.bots[0])?.pngData())
        service.imageColor = .blue
        for seconds in [10.0, 20, 40, 59] {
            now = Date(timeIntervalSince1970: 1_000 + seconds)
            await store.refresh()
        }
        #expect(service.reads == 1)
        now = Date(timeIntervalSince1970: 1_061)
        await store.refresh()
        try await avatarEventually { service.reads == 2 && !store.isLoadingAvatar(for: store.bots[0]) }
        #expect(try #require(store.avatar(for: store.bots[0])?.pngData()) != before)
    }

    @Test func repeatedRostersKeepSlowImageInFlightAndAllowLaterImagesToFinish() async throws {
        let service = AvatarService(); service.holdImages = false; service.heldIDs = ["shared"]
        var other = service.profiles[0]; other.id = "later"; other.name = "Later"
        service.profiles.append(other)
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); service.releaseImages(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        try await avatarEventually { service.pending.count == 1 }
        for _ in 0..<4 { await store.refresh() }
        let slow = try #require(store.bots.first { $0.id == "shared" })
        let later = try #require(store.bots.first { $0.id == "later" })
        try await avatarEventually { store.avatar(for: later) != nil }
        #expect(service.readsByID["shared"] == 1 && service.readsByID["later"] == 1)
        #expect(store.isLoadingAvatar(for: slow) && !store.isRefreshing)
        service.releaseImages()
        try await avatarEventually { store.avatar(for: slow) != nil && !store.isLoadingAvatar(for: slow) }
        #expect(store.notice == nil)
    }

    @Test func explicitRefreshDuringSlowReadQueuesOneFreshReadWithoutRestartingIt() async throws {
        let service = AvatarService()
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); service.releaseImages(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        try await avatarEventually { service.pending.count == 1 }
        service.imageColor = .blue
        await store.refresh(revalidateAvatars: true)
        await store.refresh(revalidateAvatars: true)
        #expect(service.reads == 1)
        service.holdImages = false; service.releaseImages()
        try await avatarEventually { service.reads == 2 && !store.isLoadingAvatar(for: store.bots[0]) }
        let refreshed = try #require(store.avatar(for: store.bots[0])?.pngData())
        // A second explicit read of the same blue bytes must produce the same thumbnail.
        await store.refresh(revalidateAvatars: true)
        try await avatarEventually { service.reads == 3 && !store.isLoadingAvatar(for: store.bots[0]) }
        #expect(store.avatar(for: store.bots[0])?.pngData() == refreshed)
    }

    @Test func changedKeysRetireOnlyTheirReadAndLateCompletionCannotClearReplacementLoading() async throws {
        let service = AvatarService()
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); service.releaseImages(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        try await avatarEventually { service.pending.count == 1 }
        service.profiles[0].lookRevision = 2; service.imageColor = .blue
        await store.refresh()
        try await avatarEventually { service.pending.count == 2 }
        service.releaseFirstImage()
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.avatar(for: store.bots[0]) == nil && store.isLoadingAvatar(for: store.bots[0]))
        service.releaseImages()
        try await avatarEventually { store.avatar(for: store.bots[0]) != nil && !store.isLoadingAvatar(for: store.bots[0]) }
        #expect(service.reads == 2)
    }

    @Test func avatarReadsUseBoundedConcurrencyAndRetiredQueuedProfilesCannotFetch() async throws {
        let service = AvatarService()
        service.profiles = (0..<8).map { BotProfile(id: "bot-\($0)", name: "Bot \($0)", hasAvatar: true, lookRevision: 1) }
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); service.releaseImages(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        try await avatarEventually { service.pending.count == 3 }
        for _ in 0..<3 { await store.refresh() }
        #expect(service.reads == 3)
        service.profiles.removeAll { $0.id == "bot-0" || $0.id == "bot-7" }
        await store.refresh()
        try await avatarEventually { service.reads == 4 }
        service.holdImages = false; service.releaseImages()
        try await avatarEventually { store.bots.allSatisfy { store.avatar(for: $0) != nil && !store.isLoadingAvatar(for: $0) } }
        #expect(service.readsByID["bot-7"] == nil)
        #expect(service.readsByID["bot-0"] == 1)
    }

    @Test(arguments: [false, true]) func failedReloadDoesNotClaimUnacknowledgedSave(acknowledged: Bool) async throws {
        let service = AvatarService(); service.holdImages = false
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        if acknowledged {
            service.failRosterAfterSave = true
            await #expect(throws: HermesServiceError.avatarRefresh) { try await store.saveAvatar(.automatic, to: destination) }
        } else {
            service.saveError = .avatarConflict
            await #expect(throws: HermesServiceError.avatarConflict) { try await store.saveAvatar(.automatic, to: destination) }
            service.failRoster = true
            await #expect(throws: HermesServiceError.avatarReload) { _ = try await store.reloadAvatar(destination) }
            #expect(!HermesServiceError.avatarReload.localizedDescription.contains("was saved"))
        }
        #expect(service.saves == 1)
    }
}

@MainActor private func avatarEventually(_ message: String = "Avatar condition became true",
                                        diagnostics: () -> String = { "" },
                                        sourceLocation: SourceLocation = #_sourceLocation,
                                        _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let passed = condition()
    if !passed {
        Attachment.record("\(message)\n\(diagnostics())", named: "avatar-readiness-failure.txt")
    }
    try #require(passed, Comment(rawValue: message), sourceLocation: sourceLocation)
}

@MainActor private final class AvatarStorage {
    var value: ConnectionConfiguration?
    var persistence: ConnectionPersistence {
        ConnectionPersistence(load: { self.value }, save: { self.value = $0 }, remove: { self.value = nil })
    }
}

@MainActor private final class AvatarService: BotService {
    let authority = TestConversationAuthority()

    func conversations(profile: ExactID) async throws -> ConversationDirectory { authority.directory(profile) }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw HermesServiceError.rejected(-32601) }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact { throw HermesServiceError.rejected(-32601) }

    var onEvent: ((BotServiceEvent) -> Void)?
    var profiles = [BotProfile(id: "shared", name: "Shared", appearance: BotAppearance(imageKind: "photo"), hasAvatar: true, lookRevision: 1)]
    var holdImages = true, failImages = false
    var holdRoster = false
    var failRoster = false
    var failRosterAfterSave = false
    var connectError: HermesServiceError?
    var profileSaves = 0
    var saveError: HermesServiceError?
    var targetReadError: HermesServiceError?
    var holdTargetRead = false
    var pendingTargetRead: CheckedContinuation<Void, Never>?
    private var connectionGeneration = 0
    var heldIDs = Set<String>()
    var imageColor = UIColor.red
    var suppliedAsset: BotAvatarAsset?
    var imageSize = 300
    var reads = 0
    var readsByID: [String: Int] = [:]
    var saves = 0
    var mutations = 0
    var holdSave = false
    var pendingSave: CheckedContinuation<Void, Never>?
    var pending: [CheckedContinuation<Void, Never>] = []
    var pendingRosters: [CheckedContinuation<Void, Never>] = []
    func releaseRosters() { let held = pendingRosters; pendingRosters = []; for item in held { item.resume() } }
    func releaseImages() { let held = pending; pending = []; for item in held { item.resume() } }
    func releaseFirstImage() { if !pending.isEmpty { pending.removeFirst().resume() } }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        if let connectError { throw connectError }
        return ServerInfo(version: "test")
    }
    func disconnect() { connectionGeneration += 1 }
    func bots() async throws -> [BotProfile] {
        let result = profiles
        if holdRoster { await withCheckedContinuation { pendingRosters.append($0) } }
        if failRoster { throw HermesServiceError.timeout }
        return result
    }
    func avatarAsset(for bot: BotProfile) async throws -> BotAvatarAsset? {
        reads += 1; readsByID[bot.id, default: 0] += 1
        let size = imageSize, color = imageColor
        if holdImages || heldIDs.contains(bot.id) { await withCheckedContinuation { pending.append($0) } }
        if failImages { throw HermesServiceError.rejected(-32601) }
        if let suppliedAsset { return suppliedAsset }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let image = renderer.image { context in color.setFill(); context.fill(CGRect(x: 0, y: 0, width: size, height: size)) }
        return BotAvatarAsset(data: image.pngData()!, mimeType: "image/png")
    }
    func updateProfile(_ edit: BotProfileEdit, for bot: BotProfile) async throws -> BotProfile {
        let index = profiles.firstIndex { $0.id.utf8.elementsEqual(bot.id.utf8) }!
        profileSaves += 1
        if let name = edit.name { profiles[index].name = name }
        if let description = edit.description { profiles[index].description = description }
        return profiles[index]
    }
    func setAvatar(_ choice: BotAvatarChoice, for bot: BotProfile) async throws -> BotProfile {
        saves += 1
        // Mirror the real service's fresh target read and prewrite connection fence.
        let owner = connectionGeneration
        if holdTargetRead { await withCheckedContinuation { pendingTargetRead = $0 } }
        guard owner == connectionGeneration, !Task.isCancelled else { throw HermesServiceError.disconnected }
        if let targetReadError { throw targetReadError }
        let matches = profiles.indices.filter { profiles[$0].id == bot.id }
        guard matches.count == 1, let index = matches.first else { throw HermesServiceError.profileUnavailable }
        let fresh = profiles[index]
        guard (fresh.hasAvatar == true) == (bot.hasAvatar == true),
              (fresh.appearance ?? BotAppearance()) == (bot.appearance ?? BotAppearance()) else {
            throw HermesServiceError.avatarConflict
        }
        if let saveError { throw saveError }
        mutations += 1
        profiles[index].appearance = choice.applying(to: fresh.appearance ?? BotAppearance())
        profiles[index].hasAvatar = false
        profiles[index].lookRevision = (fresh.lookRevision ?? 0) + 1
        if failRosterAfterSave { failRoster = true }
        let saved = profiles[index]
        if holdSave { await withCheckedContinuation { pendingSave = $0 } }
        return saved
    }
    func createBot(_ draft: BotDraft) async throws -> BotProfile {
        let bot = BotProfile(id: "new", name: draft.name, appearance: draft.avatar.appearance)
        profiles.append(bot); return bot
    }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let bot = BotProfile(id: authority.profile(target), name: "Fixture")
        return try authority.opened(Conversation(id: bot.id, storedID: bot.id, profileID: bot.id))
    }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment { throw HermesServiceError.invalidAttachment }
}
