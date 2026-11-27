import Foundation
import Testing
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
            service.connectError = fails ? ConversationServiceError.disconnected : nil
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
        if fails { service.connectError = ConversationServiceError.disconnected }
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

    @Test func cachedAvatarCanOpenOfflineAndSaveOnlyAfterDeliberateOnlineAttempt() async throws {
        let service = AvatarService()
        let storage = AvatarStorage()
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://cached-avatars.example")!)
        storage.value = connection
        var cached = LocalHistory(); cached.bots = service.profiles
        try cached.save(for: connection.id)
        let store = AppStore(service: service, persistence: storage.persistence)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(!store.isConnected)
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        await #expect(throws: ConversationServiceError.disconnected) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 0)
        #expect(await store.connect(connection))
        #expect(service.saves == 0)
        try await store.saveAvatar(.face(.init(shape: .drop, color: "#22c55e")), to: destination)
        #expect(service.saves == 1)
        #expect(store.bots[0].face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
    }

    @Test(arguments: ["background", "transport", "reconnect"])
    func sameAccountRecoveryKeepsAvatarDraftValidWithoutRetry(recovery: String) async throws {
        let service = AvatarService()
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
        let service = AvatarService()
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
        let service = AvatarService()
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://uncertain-avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        service.saveError = T3RPCError.timeout
        await #expect(throws: T3RPCError.timeout) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 1)
        service.saveError = nil
        #expect(await store.connect(connection))
        await store.refresh()
        let reloaded = try #require(store.avatarDestination(for: store.bots[0]))
        #expect(service.saves == 1)
        try await store.saveAvatar(.automatic, to: reloaded)
        #expect(service.saves == 2)
    }

    @Test func authoritativeAvatarConflictRequiresReloadBeforeDeliberateSave() async throws {
        let service = AvatarService()
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://conflict-avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        service.profiles[0].appearance = BotAppearance(shape: .hexagon, color: "#ec4899")
        let fresh = service.profiles
        await store.refresh()
        await #expect(throws: ConversationServiceError.avatarConflict) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 1 && service.mutations == 0)
        #expect(service.profiles == fresh)
        await store.refresh()
        let reloaded = try #require(store.avatarDestination(for: store.bots[0]))
        try await store.saveAvatar(.automatic, to: reloaded)
        #expect(service.saves == 2 && service.mutations == 1)
    }

    @Test func unrelatedRosterFailureCannotBlockSaveAndPublicationFailureDoesNotRetry() async throws {
        let service = AvatarService()
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://roster-failure-avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        let visible = store.bots
        service.failRoster = true
        await #expect(throws: ConversationServiceError.avatarRefresh) {
            try await store.saveAvatar(.face(.init(shape: .drop, color: "#22c55e")), to: destination)
        }
        #expect(service.saves == 1 && service.mutations == 1)
        #expect(service.profiles[0].face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
        #expect(store.bots == visible)
        service.failRoster = false
        #expect(await store.connect(connection))
        await store.refresh()
        #expect(service.saves == 1 && service.mutations == 1)
        #expect(store.bots[0].face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
    }

    @Test func duplicateAvatarSaveCannotWriteWhileFirstSaveAwaitsRosterPublication() async throws {
        let service = AvatarService()
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://duplicate-avatars.example")!)
        defer { store.forgetConnection(); service.releaseRosters(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        service.holdRoster = true
        let save = Task { try await store.saveAvatar(.face(.init(shape: .drop, color: "#22c55e")), to: destination) }
        try await avatarEventually { !service.pendingRosters.isEmpty }
        await #expect(throws: ConversationServiceError.avatarConflict) {
            try await store.saveAvatar(.automatic, to: destination)
        }
        #expect(service.saves == 1 && service.mutations == 1)
        service.holdRoster = false; service.releaseRosters()
        try await save.value
        #expect(store.bots[0].face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
        #expect(service.saves == 1 && service.mutations == 1)
    }

    @Test func authoritativeTargetReadFailureCannotMutateAndRecoveryDoesNotRetry() async throws {
        let service = AvatarService()
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://target-read-avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        let original = service.profiles
        service.targetReadError = T3RPCError.timeout
        await #expect(throws: T3RPCError.timeout) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 1 && service.mutations == 0)
        #expect(service.profiles == original)
        service.targetReadError = nil
        #expect(await store.connect(connection))
        await store.refresh()
        let reloaded = try #require(store.avatarDestination(for: store.bots[0]))
        #expect(service.saves == 1 && service.mutations == 0)
        try await store.saveAvatar(.automatic, to: reloaded)
        #expect(service.saves == 2 && service.mutations == 1)
    }

    @Test(arguments: [false, true]) func interruptedServiceTargetReadCannotWriteAfterReconnect(reconnect: Bool) async throws {
        let service = AvatarService()
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
        await #expect(throws: ConversationServiceError.disconnected) { try await save.value }
        #expect(service.saves == 1 && service.mutations == 0)
        #expect(service.profiles == original)
        #expect(destination.isCurrent(in: store))
        if !reconnect { #expect(await store.connect(connection)) }
        try await store.saveAvatar(.automatic, to: destination)
        #expect(service.saves == 2 && service.mutations == 1)
    }

    @Test(arguments: ["forget", "workspace", "account", "provider", "origin", "installation", "demo"])
    func avatarDraftRejectsRevokedWorkspaceOrAccount(change: String) async throws {
        let service = AvatarService()
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
        await #expect(throws: ConversationServiceError.disconnected) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 0)
        #expect(await store.connect(original))
        #expect(!destination.isCurrent(in: store))
        await #expect(throws: ConversationServiceError.disconnected) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 0)
        let reopened = try #require(store.avatarDestination(for: store.bots[0]))
        try await store.saveAvatar(.automatic, to: reopened)
        #expect(service.saves == 1)
    }

    @Test(arguments: ["account", "provider", "installation"])
    func configurationEventPermanentlyRevokesOldAvatarDraft(change: String) async throws {
        let service = AvatarService()
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
        await #expect(throws: ConversationServiceError.disconnected) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 0)
        let reopened = try #require(store.avatarDestination(for: store.bots[0]))
        try await store.saveAvatar(.automatic, to: reopened)
        #expect(service.saves == 1)
    }

    @Test func failedWorkspaceReplacementKeepsOriginalAvatarDraft() async throws {
        let service = AvatarService()
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let original = ConnectionConfiguration(serverURL: URL(string: "https://failed-replacement-avatars.example")!, username: "alice")
        var replacement = original; replacement.username = "bob"
        defer { store.forgetConnection(); LocalHistory.remove(for: original.id) }
        #expect(await store.connect(original))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        service.connectError = T3RPCError.timeout
        #expect(!(await store.connect(replacement)))
        #expect(destination.isCurrent(in: store))
        #expect(service.saves == 0)
        service.connectError = nil
        #expect(await store.connect(original))
        try await store.saveAvatar(.automatic, to: destination)
        #expect(service.saves == 1)
    }

    @Test func explicitSavePublishesSharedLookAndRetiredEditorCannotWrite() async throws {
        let service = AvatarService()
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        try await store.saveAvatar(.face(.init(shape: .drop, color: "#22c55e")), to: destination)
        #expect(store.bots[0].face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
        #expect(service.saves == 1 && store.notice == nil)
        let character = try #require(store.avatarDestination(for: store.bots[0]))
        try await store.saveAvatar(.geometry(DemoBotService.sampleCharacter, color: .value("#22c55e")), to: character)
        #expect(store.bots[0].appearance?.rawShape == DemoBotService.sampleCharacter.recipe)
        #expect(store.bots[0].appearance?.geometry == DemoBotService.sampleCharacter)
        #expect(store.bots[0].appearance?.color == "hsl(120 68% 58%)")
        #expect(service.profiles[0].appearance == store.bots[0].appearance && service.saves == 2)
        await store.setActive(false)
        await #expect(throws: ConversationServiceError.disconnected) {
            try await store.saveAvatar(.automatic, to: character)
        }
        #expect(service.saves == 2)
    }

    @Test(arguments: ["cancel", "background", "transport", "reconnect", "demo", "replacement"])
    func retiredSaveCannotPublishIntoCurrentWorkspace(retirement: String) async throws {
        let service = AvatarService()
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
            await store.chats.refreshInboxHistory(profiles: profiles)
        default:
            service.profiles = [BotProfile(id: "shared", name: "Replacement")]
            #expect(await store.connect(second))
        }
        let visible = store.bots
        service.pendingSave?.resume(); service.pendingSave = nil
        await #expect(throws: ConversationServiceError.disconnected) { try await save.value }
        #expect(store.bots == visible)
        #expect(service.saves == 1 && store.notice == nil)
    }

    @Test func failedRosterAfterAnAcknowledgedSaveReportsTheSave() async throws {
        let service = AvatarService()
        let store = AppStore(service: service, persistence: AvatarStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://avatars.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        let destination = try #require(store.avatarDestination(for: store.bots[0]))
        service.failRosterAfterSave = true
        await #expect(throws: ConversationServiceError.avatarRefresh) { try await store.saveAvatar(.automatic, to: destination) }
        #expect(service.saves == 1)
    }
}

@MainActor private func avatarEventually(_ message: String = "Avatar condition became true",
                                        timeout: Duration = readinessLimit,
                                        diagnostics: () -> String = { "" },
                                        sourceLocation: SourceLocation = #_sourceLocation,
                                        _ condition: () -> Bool) async throws {
    let started = ContinuousClock.now, deadline = started + timeout
    var polls = 0, maximumGap = Duration.zero
    var previousPoll = ContinuousClock.now
    while !condition(), ContinuousClock.now < deadline {
        polls += 1
        try await Task.sleep(for: .milliseconds(5))
        let resumed = ContinuousClock.now
        maximumGap = max(maximumGap, previousPoll.duration(to: resumed)); previousPoll = resumed
    }
    let passed = condition()
    if !passed || started.duration(to: .now) > slowReadiness {
        maximumGap = max(maximumGap, previousPoll.duration(to: .now))
        Attachment.record("\(message)\npolls=\(polls) maximumPollGap=\(maximumGap)\n\(diagnostics())",
                          named: passed ? "readiness-wait.txt" : "avatar-readiness-failure.txt")
    }
    try #require(passed, Comment(rawValue: message), sourceLocation: sourceLocation)
}

@MainActor private final class AvatarStorage {
    var value: ConnectionConfiguration?
    var persistence: ConnectionPersistence {
        ConnectionPersistence(load: { self.value }, save: { self.value = $0 }, remove: { self.value = nil })
    }
}

@MainActor private final class AvatarService: ConversationTestService {
    let authority = TestConversationAuthority()

    func conversations(profile: ExactID) async throws -> ConversationDirectory { authority.directory(profile) }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact { throw T3ServiceError.unsupported }

    var onEvent: ((BotServiceEvent) -> Void)?
    var profiles = [BotProfile(id: "shared", name: "Shared", appearance: BotAppearance(), hasAvatar: false, lookRevision: 1)]
    var holdRoster = false
    var failRoster = false
    var failRosterAfterSave = false
    var connectError: (any Error)?
    var saveError: (any Error)?
    var targetReadError: (any Error)?
    var holdTargetRead = false
    var pendingTargetRead: CheckedContinuation<Void, Never>?
    private var connectionGeneration = 0
    var saves = 0
    var mutations = 0
    var holdSave = false
    var pendingSave: CheckedContinuation<Void, Never>?
    var pendingRosters: [CheckedContinuation<Void, Never>] = []
    func releaseRosters() { let held = pendingRosters; pendingRosters = []; for item in held { item.resume() } }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        if let connectError { throw connectError }
        return ServerInfo(version: "test")
    }
    func disconnect() { connectionGeneration += 1 }
    func bots() async throws -> [BotProfile] {
        let result = profiles
        if holdRoster { await withCheckedContinuation { pendingRosters.append($0) } }
        if failRoster { throw T3RPCError.timeout }
        return result
    }
    func updateProfile(_ edit: BotProfileEdit, for bot: BotProfile) async throws -> BotProfile {
        let index = profiles.firstIndex { $0.id.utf8.elementsEqual(bot.id.utf8) }!
        if let name = edit.name { profiles[index].name = name }
        if let description = edit.description { profiles[index].description = description }
        return profiles[index]
    }
    func setAvatar(_ choice: BotAvatarChoice, for bot: BotProfile) async throws -> BotProfile {
        saves += 1
        // Mirror the real service's fresh target read and prewrite connection fence.
        let owner = connectionGeneration
        if holdTargetRead { await withCheckedContinuation { pendingTargetRead = $0 } }
        guard owner == connectionGeneration, !Task.isCancelled else { throw ConversationServiceError.disconnected }
        if let targetReadError { throw targetReadError }
        let matches = profiles.indices.filter { profiles[$0].id == bot.id }
        guard matches.count == 1, let index = matches.first else { throw ConversationServiceError.profileUnavailable }
        let fresh = profiles[index]
        guard (fresh.appearance ?? BotAppearance()) == (bot.appearance ?? BotAppearance()) else {
            throw ConversationServiceError.avatarConflict
        }
        if let saveError { throw saveError }
        mutations += 1
        profiles[index].appearance = choice.applying(to: fresh.appearance ?? BotAppearance())
        profiles[index].lookRevision = (fresh.lookRevision ?? 0) + 1
        if failRosterAfterSave { failRoster = true }
        let saved = profiles[index]
        if holdSave { await withCheckedContinuation { pendingSave = $0 } }
        return saved
    }
    func markVisited(through mark: VisitMark, access: ConversationAccess) async throws {}
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let bot = BotProfile(id: authority.profile(target), name: "Fixture")
        return try authority.opened(Conversation(id: bot.id, storedID: bot.id, profileID: bot.id))
    }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment { throw ConversationServiceError.invalidAttachment }
}
