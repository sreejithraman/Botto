import Testing
import Foundation
import Observation
import BottoCore
@testable import Botto

@MainActor struct AppStoreTests {
    @Test(arguments: ["completed", "backgrounded", "superseded"])
    func interruptedSignInWaitsForItsOwnResult(outcome: String) async throws {
        let original = ConnectionConfiguration(serverURL: URL(string: "https://saved.example")!)
        var candidate = ConnectionConfiguration(serverURL: URL(string: "https://candidate.example")!)
        candidate.nativeCredential = .init(refreshToken: "candidate-token", provider: "basic")
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.example")!)
        defer {
            for configuration in [original, candidate, replacement] { LocalHistory.remove(for: configuration.id) }
        }
        let storage = MemoryConnectionStorage(saved: original), service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence)
        let gate = StoreTestBarrier()
        defer { gate.release() }
        service.connectBarrier = gate
        let request = Task { await store.connect(candidate) }
        defer { request.cancel() }
        try #require(await gate.entersInTime())
        let owner = store.connectionGeneration
        let callback = try #require(service.onEvent)
        callback(.disconnected("Handshake interrupted"))
        callback(.connected(.init(version: "premature-recovery")))
        #expect(store.link == .offline)
        #expect(store.serverInfo == nil)
        #expect(store.configuration == original && storage.saved == original)
        var rotated = candidate
        rotated.nativeCredential = .init(refreshToken: "rotated-candidate-token", provider: "basic")
        callback(.configuration(rotated))
        #expect(storage.saved == original)

        if outcome == "backgrounded" { await store.setActive(false) }
        if outcome == "superseded" {
            service.connectBarrier = nil
            #expect(await store.connect(replacement))
        }
        gate.release()
        let connected = await request.value
        #expect(connected == (outcome == "completed"))
        if outcome == "completed" {
            #expect(store.connectionGeneration == owner)
            #expect(store.link == .online)
            #expect(store.configuration?.nativeCredential == rotated.nativeCredential)
            #expect(storage.saved == store.configuration)
        } else {
            #expect(store.connectionGeneration != owner)
            #expect(store.configuration?.id == (outcome == "backgrounded" ? original.id : replacement.id))
            #expect(storage.saved == store.configuration)
            #expect(store.link == (outcome == "backgrounded" ? .connecting : .online))
        }
    }

    @Test func ordinaryBotEntryCannotReplaceReentrantNavigation() async throws {
        let service = try WorkspaceTestService()
        let scout = try ExactID("scout")
        let scoutIdentity = SessionIdentity(profile: scout, root: try ExactID("scout-root"), stored: try ExactID("scout-tip"), aliases: [])
        service.summaries.append(.init(identity: scoutIdentity, title: "Scout", isCanonical: true, persistence: .durable))
        service.snapshots[scoutIdentity.root] = .init(id: "scout-runtime", storedID: scoutIdentity.stored.text, profileID: scout.text,
            messages: [.init(id: "scout-message", role: .assistant, text: "Scout reply")])
        service.rosterProfiles = [.init(id: service.profile.text, name: "Milo"), .init(id: scout.text, name: "Scout")]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://bot-entry-navigation.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try #require(await store.connect(configuration))
        let workspace = store.chats, probe = CreationObservation()
        withObservationTracking { _ = store.selectedBotID } onChange: {
            MainActor.assumeIsolated {
                guard !probe.fired else { return }
                probe.fired = true; store.selectedBotID = scout.text
                probe.opening = workspace.captureOpening(profile: scout)
            }
        }
        await store.open(try #require(store.bot(withID: service.profile.text)))
        #expect(probe.fired && store.selectedBotID == scout.text)
        #expect(service.opens.isEmpty)
        await workspace.open(try #require(probe.opening))
        #expect(workspace.selection(profile: scout)?.identity?.profile == scout)
        #expect(workspace.selection(profile: scout)?.identity?.root == scoutIdentity.root)
        #expect(workspace.selection(profile: scout)?.identity?.stored == scoutIdentity.stored)
        #expect(service.opens == [scoutIdentity])
        #expect(workspace.screen(profile: scout)?.canAct == true)
    }

    enum LibraryBoundary: CaseIterable { case directory, attachment }
    enum LibraryNewerIntent: CaseIterable { case none, sameValue, nilValue, inboxRoute }

    enum NewerSelection: CaseIterable {
        case inboxSameBot, sameValue, retirement, inboxEquivalentBot, equivalentValue
    }

    @Test(arguments: NewerSelection.allCases)
    func olderSelectionYieldsToNewerIntentEvenWhenItsBytesAreUnchanged(newer: NewerSelection) async throws {
        let service = try WorkspaceTestService()
        let composed = try addSelectionProfile("caf\u{e9}", to: service)
        let decomposed = try addSelectionProfile("cafe\u{301}", to: service)
        let scout = try addSelectionProfile("scout", to: service)
        service.rosterProfiles = [.init(id: service.profile.text, name: "Milo")] +
            [scout, decomposed, composed].map { .init(id: $0.profile.text, name: $0.profile.text) }
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://selection-ordering.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try #require(await store.connect(configuration))
        let initial: SessionIdentity? = switch newer {
        case .inboxSameBot, .sameValue: scout
        case .retirement: nil
        case .inboxEquivalentBot, .equivalentValue: decomposed
        }
        let expected: SessionIdentity? = switch newer {
        case .inboxSameBot, .sameValue: scout
        case .retirement: nil
        case .inboxEquivalentBot, .equivalentValue: composed
        }
        if let initial {
            await store.open(try #require(store.bot(withID: initial.profile.text)))
            try #require(store.chats.screen(profile: initial.profile)?.canAct == true)
        }
        let baseline = service.opens.count, probe = CreationObservation()
        withObservationTracking { _ = store.selectedBotID } onChange: {
            MainActor.assumeIsolated {
                guard !probe.fired else { return }
                probe.fired = true
                switch newer {
                case .inboxSameBot, .inboxEquivalentBot:
                    probe.botOpening = store.prepareBotOpening(store.bot(withID: expected!.profile.text)!)
                case .sameValue, .retirement, .equivalentValue:
                    store.selectedBotID = expected?.profile.text
                }
            }
        }
        await store.open(try #require(store.bot(withID: service.profile.text)))
        #expect(probe.fired)
        #expect(store.selectedBotID.map { Data($0.utf8) } == expected?.profile.bytes, "The newer selection intent must win.")
        #expect(service.opens.count == baseline, "The superseded selection must not start an attachment.")
        #expect(store.chats.screen(profile: service.profile)?.canAct != true)
        if let initial, initial.profile == expected?.profile {
            #expect(store.chats.screen(profile: initial.profile)?.canAct == true, "An unchanged selection keeps its presentation.")
        }
        guard let expected, newer == .inboxSameBot || newer == .inboxEquivalentBot else { return }
        let opening = try #require(probe.botOpening)
        #expect(store.canOpenBot(opening))
        await store.openBot(opening)
        let selection = store.chats.selection(profile: expected.profile)?.identity
        #expect(selection?.profile == expected.profile)
        #expect(selection?.root == expected.root)
        #expect(selection?.stored == expected.stored)
        #expect(store.chats.screen(profile: expected.profile)?.canAct == true)
        #expect(service.opens.dropFirst(baseline).map(\.profile) == [expected.profile])
    }

    @Test(arguments: ["unselected", "same", "equivalent"])
    func ordinaryOpeningSelectsAndAttachesTheExactProfile(_ initial: String) async throws {
        let service = try WorkspaceTestService()
        let composed = try addSelectionProfile("caf\u{e9}", to: service)
        let decomposed = try addSelectionProfile("cafe\u{301}", to: service)
        service.rosterProfiles = [decomposed, composed].map { .init(id: $0.profile.text, name: $0.profile.text) }
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://exact-selection.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try #require(await store.connect(configuration))
        switch initial {
        case "same": await store.open(try #require(store.bot(withID: composed.profile.text)))
        case "equivalent": await store.open(try #require(store.bot(withID: decomposed.profile.text)))
        default: break
        }
        let baseline = service.opens.count
        let bot = try #require(store.bot(withID: composed.profile.text))
        let opening = try #require(store.prepareBotOpening(bot))
        #expect(store.canOpenBot(opening))
        await store.openBot(opening)
        #expect(store.selectedBotID.map { Data($0.utf8) } == composed.profile.bytes)
        let selection = store.chats.selection(profile: composed.profile)?.identity
        #expect(selection?.profile == composed.profile)
        #expect(selection?.root == composed.root)
        #expect(selection?.stored == composed.stored)
        #expect(store.chats.screen(profile: composed.profile)?.canAct == true)
        #expect(service.opens.dropFirst(baseline).map(\.profile) == [composed.profile])
        if initial == "equivalent" { #expect(store.chats.screen(profile: decomposed.profile)?.canAct != true) }
    }

    @Test func failedCachePreparationLeavesTheSavedConnectionAndHistoryIntact() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://mac.example")!, installID: "test-install",
            t3: .init(environmentID: "test-install", accessToken: "old", projectID: "milo",
                      workspaceRoot: "/host/.botto/bots/milo"))
        let candidate = ConnectionConfiguration(serverURL: old.serverURL,
            t3: .init(environmentID: "test-install", accessToken: "new", projectID: "milo",
                      workspaceRoot: "/host/.botto/bots/milo"))
        let cacheURL = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            .appendingPathComponent("Botto/\(candidate.id.uuidString).json")
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheURL); LocalHistory.remove(for: old.id) }
        var offlineRoster = LocalHistory()
        offlineRoster.bots = [.init(id: "milo", name: "Milo")]
        try offlineRoster.save(for: old.id)
        let storage = MemoryConnectionStorage(saved: old)
        let store = AppStore(service: StoreTestService(), persistence: storage.persistence)
        await store.testEdit("Keep this draft", for: "milo")
        store.flush()

        #expect(!(await store.connect(candidate)))
        #expect(storage.saved == old)
        #expect(store.configuration == old)
        #expect(store.draft(for: "milo") == "Keep this draft")
        #expect(try LocalHistory.load(for: old.id).fixtureRecord("milo")?.draft.text == "Keep this draft")
    }

    @Test func unreadableSavedSetupNeverAcceptsFreshCredentials() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://original.example")!)
        let candidate = ConnectionConfiguration(serverURL: URL(string: "https://replacement.example")!)
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        let storage = MemoryConnectionStorage(saved: old)
        storage.failLoad = true
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence)
        #expect(store.configuration == nil)
        #expect(store.connectionError != nil)
        #expect(!(await store.connect(candidate)))
        #expect(storage.saved == old)
        #expect(service.connectCount == 0)
    }

    @Test func attachmentTotalIsCheckedBeforeUploadAndRemovalAndSendFreeCapacity() async throws {
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://mac.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let service = StoreTestService(profiles: [.init(id: "milo", name: "Milo")])
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        let bot = BotProfile(id: "milo", name: "Milo")
        await store.open(bot)
        let data = Data(repeating: 1, count: 20 * 1024 * 1024)
        for name in ["one.txt", "two.txt", "three.txt"] {
            let destination = try #require(store.testImport(bot.id))
            await store.testUpload(data, filename: name, mimeType: "text/plain", intent: destination)
        }
        #expect(service.uploadedConversations.count == 2)
        #expect(store.attachments(for: bot.id).count == 2)
        let first = try #require(store.attachments(for: bot.id).first)
        store.testRemove(first, profile: bot.id)
        await store.testUpload(data, filename: "replacement.txt", mimeType: "text/plain", intent: try #require(store.testImport(bot.id)))
        #expect(service.uploadedConversations.count == 3)
        #expect(store.attachments(for: bot.id).count == 2)
        await store.testSend(bot.id)
        #expect(store.attachments(for: bot.id).isEmpty)
        await store.testUpload(data, filename: "next.txt", mimeType: "text/plain", intent: try #require(store.testImport(bot.id)))
        #expect(service.uploadedConversations.count == 4)
        #expect(store.attachments(for: bot.id).count == 1)
    }

    @Test func retrySavedSetupRestoresTheSavedCacheWithoutConnectingOrOverwriting() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://original.example")!)
        defer { LocalHistory.remove(for: old.id) }
        var cached = LocalHistory(); try cached.fixtureDraft("Saved before locking", profile: "milo")
        try cached.save(for: old.id)
        let storage = MemoryConnectionStorage(saved: old)
        storage.failLoad = true
        var cleanups: [UUID?] = []
        var saves = 0
        storage.beforeSave = { _ in saves += 1 }
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence, cleanupHistory: { cleanups.append($0) })
        await store.start()
        #expect(store.savedSetupLoadFailed)
        #expect(!store.retrySavedSetup())
        #expect(cleanups.isEmpty)
        #expect(try LocalHistory.load(for: old.id).fixtureRecord("milo")?.draft.text == "Saved before locking")

        storage.failLoad = false
        #expect(store.retrySavedSetup())
        #expect(!store.savedSetupLoadFailed)
        #expect(store.connectionError == nil)
        #expect(store.configuration == old)
        #expect(store.draft(for: "milo") == "Saved before locking")
        #expect(store.link == .offline)
        #expect(cleanups == [old.id])
        #expect(service.connectCount == 0)
        #expect(saves == 0)
        #expect(storage.saved == old)
    }

    @Test func failedCredentialCommitRestoresAnExistingCandidateCacheAndNeverPrunes() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://mac.example")!, installID: "test-install",
            t3: .init(environmentID: "test-install", accessToken: "old", projectID: "milo",
                      workspaceRoot: "/host/.botto/bots/milo"))
        let candidate = ConnectionConfiguration(serverURL: old.serverURL,
            t3: .init(environmentID: "test-install", accessToken: "new", projectID: "milo",
                      workspaceRoot: "/host/.botto/bots/milo"))
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        var cached = LocalHistory(); try cached.fixtureDraft("Existing candidate history", profile: "milo")
        try cached.save(for: candidate.id)
        var offlineRoster = LocalHistory()
        offlineRoster.bots = [.init(id: "milo", name: "Milo")]
        try offlineRoster.save(for: old.id)
        let storage = MemoryConnectionStorage(saved: old)
        var cleanups: [UUID?] = []
        let store = AppStore(service: StoreTestService(), persistence: storage.persistence, cleanupHistory: { cleanups.append($0) })
        await store.testEdit("Current history", for: "milo")
        storage.failSave = true
        #expect(!(await store.connect(candidate)))
        #expect(storage.saved == old)
        #expect(store.configuration == old)
        #expect(store.draft(for: "milo") == "Current history")
        #expect(try LocalHistory.load(for: old.id).fixtureRecord("milo")?.draft.text == "Current history")
        #expect(try LocalHistory.load(for: candidate.id).fixtureRecord("milo")?.draft.text == "Existing candidate history")
        #expect(cleanups == [old.id])

        storage.failSave = false; storage.failLoad = true
        #expect(!(await store.connect(candidate)))
        #expect(storage.saved == old)
        #expect(try LocalHistory.load(for: old.id).fixtureRecord("milo")?.draft.text == "Current history")
        #expect(try LocalHistory.load(for: candidate.id).fixtureRecord("milo")?.draft.text == "Existing candidate history")
        #expect(cleanups == [old.id])
    }

    @Test func historyCleanupTouchesOnlyUnreachableRegularUUIDCacheFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keep = UUID(), orphan = UUID()
        let keepURL = directory.appendingPathComponent(keep.uuidString + ".json")
        let orphanURL = directory.appendingPathComponent(orphan.uuidString + ".json")
        let shared = directory.appendingPathComponent("AdmissionIdentities")
        let sharedFile = shared.appendingPathComponent(UUID().uuidString + ".json")
        let other = directory.appendingPathComponent("shared.json")
        let link = directory.appendingPathComponent(UUID().uuidString + ".json")
        let subdirectory = directory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        for url in [sharedFile, other] { try Data("fixture".utf8).write(to: url) }
        try LocalHistory().save(for: keep, directory: directory)
        try LocalHistory().save(for: orphan, directory: directory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)

        try LocalHistory.removeUnreachable(keeping: keep, directory: directory)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        for url in [keepURL, sharedFile, other, link, subdirectory] { #expect(FileManager.default.fileExists(atPath: url.path)) }
        try LocalHistory.removeUnreachable(keeping: nil, directory: directory)
        #expect(!FileManager.default.fileExists(atPath: keepURL.path))
        for url in [sharedFile, other, link, subdirectory] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test(arguments: [true, false])
    func failedOrRetiredUploadReleasesItsReservation(retired: Bool) async throws {
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://mac.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let service = StoreTestService(profiles: [.init(id: "milo", name: "Milo"), .init(id: "scout", name: "Scout")])
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        let bot = BotProfile(id: "milo", name: "Milo")
        await store.open(bot)
        let destination = try #require(store.testImport(bot.id))
        let barrier = StoreTestBarrier(); service.uploadBarrier = barrier
        let data = Data(repeating: 1, count: AttachmentLimits.fileBytes)
        let first = Task { await store.testUpload(data, filename: "retired.txt", mimeType: "text/plain", intent: destination) }
        await barrier.waitUntilEntered()
        await store.testUpload(data, filename: "concurrent.txt", mimeType: "text/plain", intent: destination)
        #expect(service.uploadedConversations.count == 1)
        if retired { await store.open(.init(id: "scout", name: "Scout")); await store.open(bot) }
        else { service.uploadError = ConversationServiceError.invalidAttachment }
        barrier.release(); await first.value
        service.uploadError = nil; service.uploadBarrier = nil
        #expect(store.attachments(for: bot.id).isEmpty)
        #expect(store.uploading.isEmpty)

        for name in ["one.txt", "two.txt", "over-budget.txt"] {
            let destination = try #require(store.testImport(bot.id))
            await store.testUpload(data, filename: name, mimeType: "text/plain", intent: destination)
        }
        #expect(service.uploadedConversations.count == 3)
        #expect(store.attachments(for: bot.id).count == 2)
    }

    @Test(arguments: [true, false])
    func imageReservationsUsePreparedSizesWithAConservativeLegacyFallback(reportsSize: Bool) async throws {
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://mac.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let service = StoreTestService(profiles: [.init(id: "milo", name: "Milo")])
        service.uploadedByteCount = reportsSize ? 5 * 1024 * 1024 : nil
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        let bot = BotProfile(id: "milo", name: "Milo")
        await store.open(bot)
        for name in ["one.png", "two.png", "three.png"] {
            let destination = try #require(store.testImport(bot.id))
            await store.testUpload(Data([1]), filename: name, mimeType: "image/png", intent: destination)
        }
        #expect(service.uploadedConversations.count == (reportsSize ? 3 : 2))
        #expect(store.attachments(for: bot.id).count == (reportsSize ? 3 : 2))
    }

    @Test func pendingProviderReadCannotUploadToReplacementWithIdenticalChatIDs() async throws {
        let original = ConnectionConfiguration(serverURL: URL(string: "https://original.example")!)
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.example")!)
        defer { LocalHistory.remove(for: original.id); LocalHistory.remove(for: replacement.id) }
        let service = StoreTestService(profiles: [.init(id: "milo", name: "Milo")])
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let bot = BotProfile(id: "milo", name: "Milo")
        #expect(await store.connect(original))
        await store.open(bot)
        let destination = try #require(store.testImport(bot.id))
        let provider = StoreTestBarrier()
        let read = Task { @MainActor in
            await provider.wait()
            await store.testUpload(Data("file contents".utf8), filename: "notes.txt", mimeType: "text/plain",
                               intent: destination)
        }
        await provider.waitUntilEntered()

        await store.setActive(false)
        #expect(await store.connect(replacement))
        await store.open(bot)
        #expect(store.conversation(for: bot.id)?.id == "runtime")
        #expect(store.conversation(for: bot.id)?.storedID == "stored")
        provider.release()
        await read.value

        #expect(service.uploadedConversations.isEmpty)
        #expect(store.attachments(for: bot.id).isEmpty)
        #expect(store.uploading.isEmpty)
    }

    @Test func currentAttachmentDestinationUploadsAndStagesTheReturnedFile() async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://current.example")!)
        defer { LocalHistory.remove(for: connection.id) }
        let service = StoreTestService(profiles: [.init(id: "milo", name: "Milo")])
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let bot = BotProfile(id: "milo", name: "Milo")
        #expect(await store.connect(connection))
        await store.open(bot)
        let destination = try #require(store.testImport(bot.id))

        await store.testUpload(Data("file contents".utf8), filename: "notes.txt", mimeType: "text/plain",
                           intent: destination)

        #expect(service.uploadedConversations == [.init(id: "runtime", storedID: "stored", profileID: "milo")])
        #expect(store.attachments(for: bot.id) == [.init(name: "notes.txt", path: "uploads/notes.txt", mimeType: "text/plain")])
        #expect(store.uploading.isEmpty)
    }

    enum DestinationChange: CaseIterable {
        case reconnect, socketRecovery, runtime, stored, otherBot, reopenedChat, cancellation
    }

    @Test(arguments: DestinationChange.allCases)
    func pendingProviderReadRejectsRetiredDestinations(_ change: DestinationChange) async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://current.example")!)
        defer { LocalHistory.remove(for: connection.id) }
        let service = StoreTestService(profiles: [.init(id: "milo", name: "Milo"), .init(id: "scout", name: "Scout")])
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let bot = BotProfile(id: "milo", name: "Milo")
        #expect(await store.connect(connection))
        await store.open(bot)
        let destination = try #require(store.testImport(bot.id))
        let provider = StoreTestBarrier()
        let read = Task { @MainActor in
            await provider.wait()
            await store.testUpload(Data("file contents".utf8), filename: "notes.txt", mimeType: "text/plain",
                               intent: destination)
        }
        await provider.waitUntilEntered()

        switch change {
        case .reconnect:
            #expect(await store.connect(connection))
        case .socketRecovery:
            service.onEvent?(.disconnected("Transient connection loss"))
            service.onEvent?(.connected(.init(version: "recovered", installID: "test-install")))
        case .runtime:
            service.onEvent?(.conversation(try service.authority.opened(.init(id: "new-runtime", storedID: "stored", profileID: bot.id))))
        case .stored:
            service.onEvent?(.conversation(try service.authority.opened(.init(id: "runtime", storedID: "new-stored", profileID: bot.id))))
        case .otherBot:
            await store.open(.init(id: "scout", name: "Scout"))
        case .reopenedChat:
            await store.open(.init(id: "scout", name: "Scout"))
            await store.open(bot)
        case .cancellation:
            read.cancel()
        }
        provider.release()
        await read.value

        #expect(service.uploadedConversations.isEmpty)
        #expect(store.attachments(for: bot.id).isEmpty)
        #expect(store.attachments(for: "scout").isEmpty)
        #expect(store.uploading.isEmpty)
    }

    enum UploadInterruption: CaseIterable {
        case replacement, navigation, chatReplacement, socketRecovery, cancellation
    }

    @Test(arguments: UploadInterruption.allCases)
    func pendingUploadNeverStagesIntoAReplacementDestination(_ interruption: UploadInterruption) async throws {
        let original = ConnectionConfiguration(serverURL: URL(string: "https://original.example")!)
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.example")!)
        defer { LocalHistory.remove(for: original.id); LocalHistory.remove(for: replacement.id) }
        let service = StoreTestService(profiles: [.init(id: "milo", name: "Milo"), .init(id: "scout", name: "Scout")])
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let bot = BotProfile(id: "milo", name: "Milo")
        #expect(await store.connect(original))
        await store.open(bot)
        let destination = try #require(store.testImport(bot.id))
        let uploadBarrier = StoreTestBarrier()
        service.uploadBarrier = uploadBarrier
        let upload = Task { @MainActor in
            await store.testUpload(Data("file contents".utf8), filename: "notes.txt", mimeType: "text/plain",
                               intent: destination)
        }
        await uploadBarrier.waitUntilEntered()

        switch interruption {
        case .replacement:
            #expect(await store.connect(replacement))
            await store.open(bot)
        case .navigation:
            await store.open(.init(id: "scout", name: "Scout"))
        case .chatReplacement:
            service.onEvent?(.conversation(try service.authority.opened(.init(id: "new-runtime", storedID: "new-stored", profileID: bot.id))))
        case .socketRecovery:
            service.onEvent?(.disconnected("Transient connection loss"))
            service.onEvent?(.connected(.init(version: "recovered", installID: "test-install")))
        case .cancellation:
            upload.cancel()
        }
        uploadBarrier.release()
        await upload.value

        #expect(service.uploadedConversations == [.init(id: "runtime", storedID: "stored", profileID: "milo")])
        #expect(store.attachments(for: bot.id).isEmpty)
        #expect(store.attachments(for: "scout").isEmpty)
        #expect(store.uploading.isEmpty)
    }

    @Test func retiredUploadCannotClearARecoveredConnectionsCurrentUpload() async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://current.example")!)
        defer { LocalHistory.remove(for: connection.id) }
        let service = StoreTestService(profiles: [.init(id: "milo", name: "Milo")])
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let bot = BotProfile(id: "milo", name: "Milo")
        #expect(await store.connect(connection))
        await store.open(bot)
        let originalDestination = try #require(store.testImport(bot.id))
        let originalBarrier = StoreTestBarrier()
        service.uploadBarrier = originalBarrier
        let original = Task { @MainActor in
            await store.testUpload(Data("old".utf8), filename: "old.txt", mimeType: "text/plain",
                               intent: originalDestination)
        }
        await originalBarrier.waitUntilEntered()
        service.onEvent?(.disconnected("Transient connection loss"))
        service.onEvent?(.connected(.init(version: "recovered", installID: "test-install")))
        await store.open(bot) // Recovery retires access; deliberately reattach before acquiring again.
        let recoveredDestination = try #require(store.testImport(bot.id))
        let recoveredBarrier = StoreTestBarrier()
        service.uploadBarrier = recoveredBarrier
        let recovered = Task { @MainActor in
            await store.testUpload(Data("new".utf8), filename: "new.txt", mimeType: "text/plain",
                               intent: recoveredDestination)
        }
        await recoveredBarrier.waitUntilEntered()

        originalBarrier.release()
        await original.value
        #expect(store.uploading.contains(bot.id))
        #expect(store.attachments(for: bot.id).isEmpty)
        recoveredBarrier.release()
        await recovered.value
        #expect(store.uploading.isEmpty)
        #expect(service.uploadedConversations.count == 2)
        #expect(store.attachments(for: bot.id) == [.init(name: "new.txt", path: "uploads/new.txt", mimeType: "text/plain")])
    }

    @Test func failedFirstSignInDoesNotEnterTheInboxOrSaveCredentials() async throws {
        let storage = MemoryConnectionStorage()
        let service = StoreTestService()
        service.connectError = ConversationServiceError.authentication
        let store = AppStore(service: service, persistence: storage.persistence)
        let result = await store.connect(.init(serverURL: URL(string: "https://wrong.example")!, password: "test-only"))
        #expect(!result)
        #expect(store.configuration == nil)
        #expect(store.link == .unconfigured)
        #expect(storage.saved == nil)
    }

    @Test func failedReplacementPreservesTheSavedConnectionAndDraft() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://original.example")!)
        var offlineRoster = LocalHistory()
        offlineRoster.bots = [.init(id: "milo", name: "Milo")]
        try offlineRoster.save(for: old.id)
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        service.connectError = ConversationServiceError.authentication
        let store = AppStore(service: service, persistence: storage.persistence)
        await store.testEdit("A thought for the original host", for: "milo")
        let result = await store.connect(.init(serverURL: URL(string: "https://replacement.example")!))
        #expect(!result)
        #expect(store.configuration == old)
        #expect(storage.saved == old)
        #expect(store.draft(for: "milo") == "A thought for the original host")
        store.flush()
        LocalHistory.remove(for: old.id)
    }

    @Test func failedCandidateCancelsRecoveryAndRejectsAlreadyQueuedEvents() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://original.example")!)
        let candidate = ConnectionConfiguration(serverURL: URL(string: "https://candidate.example")!)
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        var cached = LocalHistory()
        cached.bots = [.init(id: "original", name: "Original bot")]
        try cached.fixtureDraft("Keep the old workspace", profile: "original")
        try cached.save(for: old.id)
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        service.connectError = ConversationServiceError.timeout
        var queuedCallback: ((BotServiceEvent) -> Void)?
        service.duringConnect = { _ in
            queuedCallback = service.onEvent
            service.scheduleRecovery()
        }
        let store = AppStore(service: service, persistence: storage.persistence)

        #expect(!(await store.connect(candidate)))
        let queuedEvent = try #require(queuedCallback)
        await service.finishRecovery()
        #expect(!service.recovered)
        #expect(store.link == .offline)
        queuedEvent(.connected(.init(version: "candidate", installID: "candidate-install")))
        queuedEvent(.conversation(try service.authority.opened(.init(id: "candidate-chat", storedID: "candidate-stored", profileID: "candidate"))))
        #expect(store.link == .offline)
        #expect(store.serverInfo == nil)
        #expect(store.configuration == old)
        #expect(storage.saved == old)
        #expect(store.bots.map(\.id) == ["original"])
        #expect(store.conversation(for: "candidate") == nil)
        #expect(store.draft(for: "original") == "Keep the old workspace")
        store.flush()
        #expect(try LocalHistory.load(for: old.id).bots.map(\.id) == ["original"])
        #expect(try LocalHistory.load(for: candidate.id).bots.isEmpty)
    }

    @Test func offlineHistoryNeverRestoresActionableRequestsOrLiveStatus() throws {
        let connectionID = UUID()
        defer { LocalHistory.remove(for: connectionID) }
        var history = LocalHistory()
        history.bots = [.init(id: "milo", name: "Milo", status: .waiting)]
        try history.fixtureConversation(.init(id: "runtime", storedID: "stored", profileID: "milo",
            messages: [.init(id: "reply", role: .assistant, text: "Keep this readable")],
            pendingRequests: [.init(id: "approval", kind: .approval, title: "Run command?")], isWorking: true), profile: "milo")
        try history.save(for: connectionID)
        let restored = try LocalHistory.load(for: connectionID)
        #expect(try restored.fixtureRecord("milo")?.transcript?.messages.first?.text == "Keep this readable")
        #expect(try restored.fixtureRecord("milo")?.transcript?.pendingRequests.isEmpty == true)
        #expect(try restored.fixtureRecord("milo")?.transcript?.isWorking == false)
        #expect(restored.bots.first?.status == .idle)
    }

    @Test func demoPreservesConnectedSetupAndJustEditedDraft() async throws {
        let real = ConnectionConfiguration(serverURL: URL(string: "https://my-mac.example")!)
        defer { LocalHistory.remove(for: real.id) }
        let storage = MemoryConnectionStorage()
        let service = StoreTestService(profiles: [.init(id: "milo", name: "Milo")])
        let store = AppStore(service: service, persistence: storage.persistence)
        #expect(await store.connect(real))
        await store.testEdit("  Keep my latest draft  ", for: "milo")

        await store.enterDemo()
        #expect(store.isDemo)
        #expect(store.isConnected)
        #expect(storage.saved?.id == real.id)
        #expect(try LocalHistory.load(for: real.id).fixtureRecord("milo")?.draft.text == "  Keep my latest draft  ")

        store.leaveDemo()
        #expect(!store.isDemo)
        #expect(store.configuration?.id == real.id)
        #expect(store.draft(for: "milo") == "  Keep my latest draft  ")
        #expect(await store.connect(try #require(store.configuration)))
        #expect(service.connectCount == 2)
        #expect(store.draft(for: "milo") == "  Keep my latest draft  ")
    }

    @Test func demoDoesNotPerformRealWork() async throws {
        let store = AppStore(persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        await store.enterDemo()
        #expect(store.isDemo)
        #expect(store.isConnected)
        #expect(store.t3Channels.contains { $0.id == "canvas" && $0.isPinned })
        let main = try #require(store.t3Channels.first { $0.isMain })
        #expect(await store.openT3Channel(main))
        let request = try #require(store.conversation(for: "milo")?.pendingRequests.first)
        let workspace = store.chats
        let row = try #require(workspace.screen(profile: try ExactID("milo"))?.requests.first { $0.request == request })
        await workspace.answer(row.intent, response: .choice("once"))
        #expect(store.conversation(for: "milo")?.pendingRequests.isEmpty == true)
        #expect(store.conversation(for: "milo")?.messages.last?.text.contains("nothing is sent") == true)
    }

    @Test func demoDraftsArePerSpaceAndSurviveNavigation() async throws {
        let store = AppStore(persistence: MemoryConnectionStorage().persistence)
        await store.enterDemo()
        let main = try #require(store.t3Channels.first { $0.isMain })
        let sibling = try #require(store.t3Channels.first { $0.id == "scout" })
        #expect(sibling.isUnread)
        let profile = try ExactID("milo")
        #expect(await store.openT3Channel(main))
        let mainOwner = try #require(store.chats.screen(profile: profile)?.owner)
        store.chats.editDraft("Keep this thought", owner: mainOwner)
        #expect(await store.openT3Channel(sibling))
        #expect(store.t3Channels.first { $0.id == sibling.id }?.isUnread == false)
        #expect(store.t3Channels.first { $0.id == "canvas" }?.isUnread == true)
        let siblingOwner = try #require(store.chats.screen(profile: profile)?.owner)
        store.chats.editDraft("A second thought", owner: siblingOwner)
        #expect(await store.openT3Channel(main))
        #expect(store.chats.screen(profile: profile).map { store.chats.draft($0.owner) } == "Keep this thought")
        #expect(await store.openT3Channel(sibling))
        #expect(store.chats.screen(profile: profile).map { store.chats.draft($0.owner) } == "A second thought")
    }

    @Test func demoReturnsFromBackgroundWithoutTryingARealHost() async throws {
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        await store.start()
        await store.enterDemo()
        await store.setActive(false)
        await store.setActive(true)
        #expect(store.isDemo)
        #expect(store.isConnected)
        #expect(service.connectCount == 0)
    }

    @Test func aHeldConnectionAttemptClosesOnlyTheSheetItBelongsTo() async throws {
        let service = try WorkspaceTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://connection-choice.invalid")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let gate = WorkspaceGate()
        service.rosterGate = gate
        store.showsConnection = true
        let attempt = Task { await store.connect(configuration) }
        await gate.entered()

        store.showsConnection = false
        store.showsConnection = true
        service.rosterGate = nil
        gate.release()

        #expect(await attempt.value)
        #expect(store.showsConnection, "The older attempt cannot close the reopened sheet.")
        #expect(await store.connect(configuration))
        #expect(!store.showsConnection, "An attempt started from the sheet still closes it.")
    }

    @Test func connectingFromDemoUsesTheRealServiceAndSavesTheRealHost() async throws {
        let storage = MemoryConnectionStorage()
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence)
        await store.enterDemo()
        let real = ConnectionConfiguration(serverURL: URL(string: "https://my-mac.example")!)
        #expect(await store.connect(real))
        #expect(!store.isDemo)
        #expect(service.connectCount == 1)
        #expect(storage.saved?.id == real.id)
        LocalHistory.remove(for: real.id)
    }
}

@MainActor private final class CreationObservation {
    var fired = false
    var creates = 0
    var opening: OpeningIntent?
    var botOpening: AppStore.BotOpening?
}

@MainActor private func addSelectionProfile(_ text: String, to service: WorkspaceTestService) throws -> SessionIdentity {
    let identity = SessionIdentity(profile: try ExactID(text), root: try ExactID(text + "-root"),
                                   stored: try ExactID(text + "-tip"), aliases: [])
    service.summaries.append(.init(identity: identity, title: text, isCanonical: true, persistence: .durable))
    service.snapshots[identity.root] = .init(id: text + "-runtime", storedID: identity.stored.text, profileID: text,
        messages: [.init(id: text + "-message", role: .assistant, text: text + " reply")])
    return identity
}
