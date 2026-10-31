import Testing
import Foundation
import BottoCore
@testable import Botto

@MainActor struct AppStoreTests {
    @Test(arguments: ["current", "background", "workspace"])
    func creationRefreshRejectsRetiredWorkspace(retirement: String) async throws {
        let original = ConnectionConfiguration(serverURL: URL(string: "https://original.example")!)
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.example")!)
        defer { LocalHistory.remove(for: original.id); LocalHistory.remove(for: replacement.id) }
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(original))
        let bot = BotProfile(id: "created", name: "Orbit")
        service.createdBot = bot; service.profiles = [bot]
        let barrier = StoreTestBarrier()
        service.botsBarrier = barrier
        let creation = Task { await store.create(.init(name: "Orbit")) }
        await barrier.waitUntilEntered()
        service.botsBarrier = nil
        if retirement == "background" { await store.setActive(false) }
        if retirement == "workspace" { service.profiles = []; #expect(await store.connect(replacement)) }
        barrier.release()
        let result = await creation.value
        #expect(result?.id == (retirement == "current" ? bot.id : nil))
        #expect(service.createCount == 1)
        #expect(store.selectedBotID == nil)
        if retirement == "background" { #expect(store.link == .connecting) }
        if retirement == "workspace" { #expect(store.configuration?.id == replacement.id) }
    }

    @Test func reauthenticationWritesCacheBeforeCredentialsAndForgetRemovesBothCacheIDs() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, username: "alice",
                                          password: "old", installID: "test-install")
        let candidate = ConnectionConfiguration(serverURL: old.serverURL, username: "alice", password: "new")
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        var cached = LocalHistory()
        try cached.fixtureDraft("Previously saved", profile: "milo")
        try cached.save(for: old.id)
        let storage = MemoryConnectionStorage(saved: old)
        let store = AppStore(service: StoreTestService(), persistence: storage.persistence)
        await store.testEdit("Latest unsaved thought", for: "milo")
        storage.beforeSave = { saved in
            if saved.id == candidate.id {
                #expect((try? LocalHistory.load(for: candidate.id).fixtureRecord("milo")?.draft.text) == "Latest unsaved thought")
            }
        }

        #expect(await store.connect(candidate))
        #expect(try LocalHistory.load(for: old.id).book.records.allSatisfy({ $0.draft.text.isEmpty }))
        let restarted = AppStore(service: StoreTestService(), persistence: storage.persistence)
        #expect(restarted.draft(for: "milo") == "Latest unsaved thought")
        restarted.forgetConnection()
        #expect(storage.saved == nil)
        #expect(try LocalHistory.load(for: old.id).book.records.allSatisfy({ $0.draft.text.isEmpty }))
        #expect(try LocalHistory.load(for: candidate.id).book.records.allSatisfy({ $0.draft.text.isEmpty }))
    }

    @Test func failedCachePreparationLeavesTheSavedConnectionAndHistoryIntact() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, username: "alice",
                                          password: "old", installID: "test-install")
        let candidate = ConnectionConfiguration(serverURL: old.serverURL, username: "alice", password: "new")
        let cacheURL = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            .appendingPathComponent("Botto/\(candidate.id.uuidString).json")
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheURL); LocalHistory.remove(for: old.id) }
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
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let service = StoreTestService()
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
        let old = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, username: "alice",
                                          password: "old", installID: "test-install")
        let candidate = ConnectionConfiguration(serverURL: old.serverURL, username: "alice", password: "new")
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        var cached = LocalHistory(); try cached.fixtureDraft("Existing candidate history", profile: "milo")
        try cached.save(for: candidate.id)
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
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let service = StoreTestService()
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
        else { service.uploadError = HermesServiceError.invalidAttachment }
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
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let service = StoreTestService()
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

    enum Reauthentication: CaseIterable {
        case password, accessHeaders, native, passwordToNativeBasic, nativeBasicToPassword
    }

    @Test(arguments: Reauthentication.allCases)
    func freshSignInPreservesVerifiedAccountHistoryAcrossRestart(_ method: Reauthentication) async throws {
        var old = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!,
                                          username: "alice", password: "old-password", installID: "test-install")
        if method == .accessHeaders {
            old.connectionHeaders = ["CF-Access-Client-Id": "old-client", "CF-Access-Client-Secret": "old-secret"]
        }
        if method == .native || method == .nativeBasicToPassword {
            old.password = ""
            old.nativeCredential = .init(refreshToken: "old-token", provider: method == .native ? "oidc" : "basic")
        }
        var candidate = ConnectionConfiguration(serverURL: URL(string: "https://HERMES.example:443/")!,
                                                username: "alice", password: "new-password")
        if method == .accessHeaders {
            candidate.password = old.password
            candidate.connectionHeaders = ["CF-Access-Client-Id": "new-client", "CF-Access-Client-Secret": "new-secret"]
        } else if method == .native || method == .passwordToNativeBasic {
            candidate.password = ""
            candidate.installID = "test-install"
            candidate.nativeCredential = .init(refreshToken: "fresh-token", provider: method == .native ? "oidc" : "basic")
        }
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        let bot = BotProfile(id: "milo", name: "Milo")
        let serverPinned = BotProfile(id: "scout", name: "Scout", isPinned: true)
        service.profiles = [bot, serverPinned]
        service.chat.messages = [.init(id: "reply", role: .assistant, text: "Readable history")]
        service.chat.pendingRequests = [.init(id: "approval", kind: .approval, title: "Run command?")]
        service.chat.isWorking = true
        let store = AppStore(service: service, persistence: storage.persistence)
        #expect(await store.connect(old))
        await store.open(bot)
        let destination = try #require(store.testImport(bot.id))
        await store.testUpload(Data("file".utf8), filename: "notes.txt", mimeType: "text/plain", intent: destination)
        #expect(!store.attachments(for: bot.id).isEmpty)
        await store.testEdit("Unsaved thought", for: bot.id)
        store.togglePin(bot)
        store.togglePin(serverPinned)
        let seen = try store.history.fixtureRecord(bot.id)?.seen?.observedAt

        #expect(await store.connect(candidate))
        #expect(service.connectedConfigurations.last == candidate)
        #expect(store.configuration?.id == candidate.id)
        #expect(storage.saved?.id == candidate.id)
        #expect(storage.saved?.password == candidate.password)
        #expect(storage.saved?.nativeCredential == candidate.nativeCredential)
        #expect(storage.saved?.connectionHeaders == candidate.connectionHeaders)
        #expect(store.draft(for: bot.id) == "Unsaved thought")
        #expect(store.isPinned(bot))
        #expect(!store.isPinned(serverPinned))
        #expect(try store.history.fixtureRecord(bot.id)?.seen?.observedAt == seen)
        #expect(store.conversation(for: bot.id)?.messages.first?.text == "Readable history")
        #expect(store.conversation(for: bot.id)?.pendingRequests.isEmpty == true)
        #expect(store.conversation(for: bot.id)?.isWorking == false)
        #expect(store.attachments(for: bot.id).isEmpty)
        #expect(store.selectedBotID == nil)

        // No explicit flush: the replacement must commit its cache with the new credential.
        let restarted = AppStore(service: StoreTestService(), persistence: storage.persistence)
        #expect(restarted.draft(for: bot.id) == "Unsaved thought")
        #expect(restarted.isPinned(bot))
        #expect(!restarted.isPinned(serverPinned))
        #expect(try restarted.history.fixtureRecord(bot.id)?.seen?.observedAt == seen)
        #expect(restarted.conversation(for: bot.id)?.messages.first?.text == "Readable history")
        #expect(restarted.conversation(for: bot.id)?.pendingRequests.isEmpty == true)
        #expect(restarted.attachments(for: bot.id).isEmpty)
    }

    enum IdentityMismatch: CaseIterable {
        case origin, port, scheme, installation, account, provider
        case missingOldInstall, emptyOldInstall, missingConfirmedInstall, emptyConfirmedInstall
        case missingOldAccount, missingNewAccount, missingBothAccounts, blankAccounts, emptyProvider
    }

    @Test(arguments: IdentityMismatch.allCases)
    func freshSignInNeverMigratesHistoryWithoutTheSameVerifiedIdentity(_ mismatch: IdentityMismatch) async throws {
        var old = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, username: "alice",
                                          installID: "test-install", nativeCredential: .init(refreshToken: "old-token", provider: "oidc"))
        var candidate = ConnectionConfiguration(serverURL: old.serverURL, username: "alice",
                                                nativeCredential: .init(refreshToken: "new-token", provider: "oidc"))
        let service = StoreTestService()
        switch mismatch {
        case .origin: candidate.serverURL = URL(string: "https://other.example")!
        case .port: candidate.serverURL = URL(string: "https://hermes.example:8443")!
        case .scheme:
            old.serverURL = URL(string: "https://localhost")!
            candidate.serverURL = URL(string: "http://localhost")!
        case .installation: service.info.installID = "different-install"
        case .account: candidate.username = "bob"
        case .provider: candidate.nativeCredential?.provider = "other-oidc"
        case .missingOldInstall: old.installID = nil
        case .emptyOldInstall: old.installID = ""
        case .missingConfirmedInstall:
            candidate.installID = old.installID
            service.info.installID = nil
        case .emptyConfirmedInstall: service.info.installID = ""
        case .missingOldAccount: old.username = ""
        case .missingNewAccount: candidate.username = ""
        case .missingBothAccounts: old.username = ""; candidate.username = ""
        case .blankAccounts: old.username = " "; candidate.username = " "
        case .emptyProvider: old.nativeCredential?.provider = ""; candidate.nativeCredential?.provider = ""
        }
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        var cached = LocalHistory()
        let bot = BotProfile(id: "milo", name: "Milo")
        cached.bots = [bot]
        try cached.fixtureDraft("Private old thought", profile: bot.id)
        cached.pinned = [try ExactID(bot.id)]
        try cached.fixtureConversation(.init(id: "old-runtime", storedID: "old-stored", profileID: bot.id,
                                             messages: [.init(id: "old-reply", role: .assistant, text: "Private old history")]), profile: bot.id)
        try cached.save(for: old.id)
        let storage = MemoryConnectionStorage(saved: old)
        let store = AppStore(service: service, persistence: storage.persistence)

        #expect(await store.connect(candidate))
        #expect(store.configuration?.id == candidate.id)
        #expect(store.draft(for: bot.id).isEmpty)
        #expect(!store.isPinned(bot))
        #expect(store.conversation(for: bot.id) == nil)
        let restarted = AppStore(service: StoreTestService(), persistence: storage.persistence)
        #expect(restarted.draft(for: bot.id).isEmpty)
        #expect(restarted.conversation(for: bot.id) == nil)
        #expect(try LocalHistory.load(for: old.id).book.records.allSatisfy({ $0.draft.text.isEmpty }))
    }

    @Test(arguments: [true, false])
    func failedSameAccountReplacementDoesNotMigrateOrCommitHistory(authenticationFails: Bool) async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, username: "alice",
                                          password: "old-password", installID: "test-install")
        let candidate = ConnectionConfiguration(serverURL: old.serverURL, username: "alice", password: "new-password")
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence)
        await store.testEdit("Keep until replacement succeeds", for: "milo")
        store.flush()
        service.connectError = authenticationFails ? HermesServiceError.authentication : nil
        storage.failSave = !authenticationFails

        #expect(!(await store.connect(candidate)))
        #expect(store.configuration == old)
        #expect(storage.saved == old)
        #expect(store.draft(for: "milo") == "Keep until replacement succeeds")
        #expect(try LocalHistory.load(for: candidate.id).book.records.allSatisfy({ $0.draft.text.isEmpty }))
        #expect(AppStore(service: StoreTestService(), persistence: storage.persistence).draft(for: "milo") == "Keep until replacement succeeds")

        service.connectError = nil; storage.failSave = false
        #expect(await store.connect(candidate))
        #expect(store.draft(for: "milo") == "Keep until replacement succeeds")
        #expect(try LocalHistory.load(for: candidate.id).fixtureRecord("milo")?.draft.text == "Keep until replacement succeeds")
    }

    @Test func retiredNativeRotationCannotOverrideFreshSignInOrItsNextReconnect() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, username: "alice",
                                          installID: "test-install", nativeCredential: .init(refreshToken: "old-token", provider: "basic"))
        let candidate = ConnectionConfiguration(serverURL: old.serverURL, username: "alice", installID: old.installID,
                                                nativeCredential: .init(refreshToken: "fresh-token", provider: "basic"))
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence)
        #expect(await store.connect(old))
        let oldCallback = service.onEvent
        await store.testEdit("Preserve through rotation", for: "milo")
        var retiredRotation = old
        retiredRotation.nativeCredential?.refreshToken = "retired-rotated-token"
        var freshRotation = candidate
        freshRotation.nativeCredential?.refreshToken = "fresh-rotated-token"
        service.duringConnect = { _ in
            oldCallback?(.configuration(retiredRotation))
            #expect(storage.saved == retiredRotation)
            service.onEvent?(.configuration(freshRotation))
        }

        #expect(await store.connect(candidate))
        #expect(storage.saved == freshRotation)
        #expect(store.configuration == freshRotation)
        #expect(store.draft(for: "milo") == "Preserve through rotation")
        retiredRotation.nativeCredential?.refreshToken = "later-retired-token"
        oldCallback?(.configuration(retiredRotation))
        #expect(storage.saved == freshRotation)
        #expect(store.configuration == freshRotation)
        service.duringConnect = nil
        #expect(await store.connect(candidate))
        #expect(service.connectedConfigurations.last == freshRotation)
        #expect(storage.saved == freshRotation)
    }

    @Test func pendingProviderReadCannotUploadToReplacementWithIdenticalChatIDs() async throws {
        let original = ConnectionConfiguration(serverURL: URL(string: "https://original.example")!)
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.example")!)
        defer { LocalHistory.remove(for: original.id); LocalHistory.remove(for: replacement.id) }
        let service = StoreTestService()
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
        let service = StoreTestService()
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
        let service = StoreTestService()
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
        let service = StoreTestService()
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
        let service = StoreTestService()
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
        service.connectError = HermesServiceError.authentication
        let store = AppStore(service: service, persistence: storage.persistence)
        let result = await store.connect(.init(serverURL: URL(string: "https://wrong.example")!, password: "test-only"))
        #expect(!result)
        #expect(store.configuration == nil)
        #expect(store.link == .unconfigured)
        #expect(storage.saved == nil)
    }

    @Test func failedReplacementPreservesTheSavedConnectionAndDraft() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://original.example")!)
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        service.connectError = HermesServiceError.authentication
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
        service.connectError = HermesServiceError.timeout
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

    @Test func reconnectSavesRotatedRefreshCredentialBeforeContinuing() async throws {
        var old = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!)
        old.nativeCredential = NativeCredential(refreshToken: "old-test-token", provider: "basic")
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        service.duringConnect = { configuration in
            var updated = configuration
            updated.nativeCredential = NativeCredential(refreshToken: "rotated-test-token", provider: "basic")
            service.onEvent?(.configuration(updated))
            #expect(storage.saved?.nativeCredential?.refreshToken == "rotated-test-token")
        }
        let store = AppStore(service: service, persistence: storage.persistence)
        #expect(await store.connect(old))
        #expect(store.configuration?.nativeCredential?.refreshToken == "rotated-test-token")
        LocalHistory.remove(for: old.id)
    }

    @Test func refreshRotationStillSavesAfterBackgroundRetiresTheScreen() async throws {
        var old = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!)
        old.nativeCredential = .init(refreshToken: "old-test-token", provider: "basic")
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence)
        #expect(await store.connect(old))
        let lateEvent = service.onEvent
        await store.setActive(false)
        var updated = old
        updated.nativeCredential = .init(refreshToken: "late-rotated-test-token", provider: "basic")
        lateEvent?(.configuration(updated))
        #expect(storage.saved?.nativeCredential?.refreshToken == "late-rotated-test-token")
        #expect(store.link == .connecting)
        LocalHistory.remove(for: old.id)
    }

    @Test(arguments: [true, false])
    func backgroundRotationWaitsForSecureStorageBeforeForegroundReconnect(failLoad: Bool) async throws {
        var old = ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, installID: "test-install")
        old.nativeCredential = .init(refreshToken: "consumed-test-token", provider: "basic")
        defer { LocalHistory.remove(for: old.id) }
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence)
        await store.start()
        await store.testEdit("Keep this cache identity", for: "milo")
        let lateEvent = service.onEvent
        await store.setActive(false)
        storage.failLoad = failLoad
        storage.failSave = !failLoad
        var rotated = old
        rotated.nativeCredential = .init(refreshToken: "rotated-while-locked", provider: "basic")
        lateEvent?(.configuration(rotated))

        #expect(store.configuration == rotated)
        #expect(storage.saved == old)
        await store.setActive(true)
        #expect(store.link == .offline)
        #expect(service.connectedConfigurations == [old])
        #expect(!(await store.connect(old)))
        #expect(service.connectedConfigurations == [old])

        storage.failLoad = false; storage.failSave = false
        service.duringConnect = { supplied in
            #expect(supplied == rotated)
            #expect(storage.saved == rotated)
        }
        await store.setActive(true)
        #expect(store.link == .online)
        #expect(service.connectedConfigurations == [old, rotated])
        #expect(storage.saved == rotated)
        #expect(store.draft(for: "milo") == "Keep this cache identity")
        store.flush()
        #expect(try LocalHistory.load(for: old.id).fixtureRecord("milo")?.draft.text == "Keep this cache identity")
    }

    @Test(arguments: [true, false])
    func failedInitialNativeCommitRetainsRotatedTokenWithoutReplacingOldWorkspace(failLoad: Bool) async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://original.example")!)
        var candidate = ConnectionConfiguration(serverURL: URL(string: "https://native.example")!)
        candidate.nativeCredential = .init(refreshToken: "browser-issued-token", provider: "basic")
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence)
        await store.testEdit("Old workspace draft", for: "milo")
        service.duringConnect = { supplied in
            var rotated = supplied
            rotated.nativeCredential = .init(refreshToken: "rotated-browser-token", provider: "basic")
            storage.failLoad = failLoad; storage.failSave = !failLoad
            service.onEvent?(.configuration(rotated))
        }

        #expect(!(await store.connect(candidate)))
        #expect(store.configuration == old)
        #expect(storage.saved == old)
        #expect(store.draft(for: "milo") == "Old workspace draft")
        storage.failLoad = false; storage.failSave = false
        service.duringConnect = { supplied in
            #expect(supplied.nativeCredential?.refreshToken == "rotated-browser-token")
            #expect(storage.saved == old)
        }
        #expect(await store.connect(candidate))
        #expect(store.configuration?.id == candidate.id)
        #expect(storage.saved?.nativeCredential?.refreshToken == "rotated-browser-token")
        #expect(store.draft(for: "milo").isEmpty)
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
        let real = ConnectionConfiguration(serverURL: URL(string: "https://my-hermes.example")!)
        defer { LocalHistory.remove(for: real.id) }
        let storage = MemoryConnectionStorage()
        let service = StoreTestService()
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
        #expect(store.bots.contains { $0.id == "canvas" && $0.isPinned })
        let milo = try #require(store.bots.first { $0.id == "milo" })
        await store.open(milo)
        let request = try #require(store.conversation(for: "milo")?.pendingRequests.first)
        let workspace = store.chats
        let row = try #require(workspace.screen(profile: try ExactID("milo"))?.requests.first { $0.request == request })
        await workspace.answer(row.intent, response: .choice("once"))
        #expect(store.conversation(for: "milo")?.pendingRequests.isEmpty == true)
        #expect(store.conversation(for: "milo")?.messages.last?.text.contains("nothing is sent") == true)
    }

    @Test func draftsArePerBotAndSurviveNavigation() async throws {
        let store = AppStore(persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        await store.enterDemo()
        await store.testEdit("Keep this thought", for: "milo")
        let scout = try #require(store.bots.first { $0.id == "scout" })
        await store.open(scout)
        await store.testEdit("A second thought", for: "scout")
        #expect(store.draft(for: "milo") == "Keep this thought")
        #expect(store.draft(for: "scout") == "A second thought")
    }

    @Test func localPinOverrideCanUnpinAServerPinnedBot() async throws {
        let store = AppStore(persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        await store.enterDemo()
        let bot = try #require(store.bots.first { $0.id == "milo" })
        #expect(store.isPinned(bot))
        store.togglePin(bot)
        #expect(!store.isPinned(bot))
        store.togglePin(bot)
        #expect(store.isPinned(bot))
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

    @Test func connectingFromDemoUsesTheRealServiceAndSavesTheRealHost() async throws {
        let storage = MemoryConnectionStorage()
        let service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence)
        await store.enterDemo()
        let real = ConnectionConfiguration(serverURL: URL(string: "https://my-hermes.example")!)
        #expect(await store.connect(real))
        #expect(!store.isDemo)
        #expect(service.connectCount == 1)
        #expect(storage.saved?.id == real.id)
        LocalHistory.remove(for: real.id)
    }
}
