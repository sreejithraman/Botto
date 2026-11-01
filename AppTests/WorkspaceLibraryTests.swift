import Foundation
import Testing
import SwiftUI
import UIKit
import Observation
import SQLite3
import BottoCore
@testable import Botto

@MainActor struct WorkspaceLibraryTests {
    private func savedBook(_ service: LibraryTestService) -> ConversationBook {
        var book = ConversationBook()
        for source in [service.first, service.second] {
            let id = book.merge(.init(identity: source, title: source.root.text, isCanonical: source == service.first, persistence: .durable))
            book.cache(.init(id: source.root.text, storedID: source.stored.text, profileID: source.profile.text,
                messages: service.messages[source] ?? []), for: id)
        }
        return book
    }

    @Test func initialLegacyPublicationDoesNotAuthorizeAWithdrawnRosterReentry() async throws {
        let service = LibraryTestService(), library = WorkspaceLibrary(service: service)
        defer { library.retire() }
        await library.restore(); library.observeBots(service.profiles, evidence: .observed)
        let snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: service.messages[service.first]!)
        library.accept(identity: service.first, snapshot: snapshot, title: "Legacy", evidence: .incremental(previous: nil))
        #expect(library.chats.first?.messages == snapshot.messages)
        let staleStart = ContinuousClock.now
        library.setOnline(true); await library.refresh(evidence: .observed, bots: [])
        #expect(library.chats.isEmpty)
        library.observeBots(service.profiles, evidence: .observed)
        library.accept(identity: service.first, snapshot: snapshot, title: "Old event", evidence: .incremental(previous: snapshot))
        library.accept(identity: service.first, snapshot: snapshot, title: "Old read", evidence: .read(startedAt: staleStart, observedSource: service.first))
        #expect(library.chats.isEmpty)
        library.accept(identity: service.first, snapshot: snapshot, title: "Fresh", evidence: .read(startedAt: .now, observedSource: service.first))
        #expect(library.chats.first?.messages == snapshot.messages)
    }

    @Test(arguments: [false, true])
    func observedRosterWithdrawsWorkingBotsBeforeAnOldScanReturns(seedOldBook: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(secondBot: true), gate = StoreTestBarrier()
        defer { gate.release() }
        let settled = ChatMessage(id: "side-file", role: .assistant, text: "Withdrawn needle\nMEDIA:/removed.txt")
        service.messages[service.second] = [settled]
        let book = savedBook(service)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let removed = try #require(library.artifacts.first { $0.chat.identity == service.second })
        _ = try await library.download(removed)
        _ = try await library.download(try #require(library.artifacts.first { $0.chat.identity == service.first }))
        let working = Conversation(id: "side", storedID: "side", profileID: "other",
            messages: [settled, .init(id: "working-tail", role: .assistant, text: "Still working")], isWorking: true)
        library.accept(identity: service.second, snapshot: working, title: "Other",
            evidence: .read(startedAt: .now, observedSource: service.second))
        #expect(library.isCurrent(removed))
        service.directoryBarriers[service.first.profile] = gate
        let reading = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        defer { reading.cancel() }
        try #require(await gate.waitUntilEntered(timeout: .seconds(5)))
        library.observeBots([service.profiles[0]], evidence: .observed)
        #expect(!library.isCurrent(removed))
        #expect(!library.chats.contains { $0.identity == service.second })
        #expect(LibrarySearchResults(query: "Withdrawn needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(try await session.metadataRecovery().contains(service.second))
        let reads = service.historyOffsets.count
        let joined = library.indexingMetrics.forcedRefreshesJoined
        let forced = Task { await library.refresh(evidence: .observed, bots: [service.profiles[0]], force: true) }
        defer { forced.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while library.indexingMetrics.forcedRefreshesJoined == joined, ContinuousClock.now < deadline { await Task.yield() }
        try #require(library.indexingMetrics.forcedRefreshesJoined > joined)
        service.directoryBarriers = [:]
        gate.release(); await reading.value; await forced.value
        #expect(service.historyOffsets.count > reads, "The joined forced refresh still checks the remaining profile")
        #expect(!library.chats.contains { $0.identity == service.second })
        library.accept(identity: service.second,
            snapshot: .init(id: "side", storedID: "side", profileID: "other", messages: [settled]),
            title: "Late idle", evidence: .incremental(previous: working))
        #expect(!library.isCurrent(removed))
        library.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root), cold = WorkspaceLibrary(service: service, cache: coldCache.session(scope: scope))
        if seedOldBook { cold.seed(book: book, bots: service.profiles) }
        await cold.restore()
        #expect(!cold.chats.contains { $0.identity == service.second })
        let unaffected = try #require(cold.artifacts.first { $0.chat.identity == service.first })
        let downloads = service.downloadCount
        #expect(try await cold.download(unaffected).data == Data("main".utf8))
        #expect(service.downloadCount == downloads)
        cold.retire(); await coldCache.close()
    }

    @Test func quickRosterReentryDoesNotReuseItsOldObservation() async throws {
        let service = LibraryTestService(), library = WorkspaceLibrary(service: service)
        defer { library.retire() }
        await library.restore(); library.observeBots(service.profiles, evidence: .observed)
        let snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: service.messages[service.first]!)
        library.accept(identity: service.first, snapshot: snapshot, title: "Current", evidence: .read(startedAt: .now, observedSource: service.first))
        let started = ContinuousClock.now
        library.observeBots([], evidence: .observed); library.observeBots(service.profiles, evidence: .observed)
        var late = snapshot; late.messages.append(.init(id: "late", role: .assistant, text: "MEDIA:/stale.txt"))
        library.accept(identity: service.first, snapshot: late, title: "Old event", evidence: .incremental(previous: snapshot))
        library.accept(identity: service.first, snapshot: late, title: "Old read", evidence: .read(startedAt: started, observedSource: service.first))
        #expect(library.chats.isEmpty)
        library.accept(identity: service.first, snapshot: snapshot, title: "Fresh", evidence: .read(startedAt: .now, observedSource: service.first))
        #expect(library.chats.first?.messages == snapshot.messages)
    }

    @Test(arguments: ["missing", "unreadable", "partial"])
    func offlineTabEntryDoesNotPromoteCachedLabelsToRosterEvidence(historyState: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://offline-library.example")!)
        defer { try? FileManager.default.removeItem(at: root); LocalHistory.remove(for: configuration.id) }
        let service = LibraryTestService(secondBot: true)
        service.messages[service.second] = [.init(id: "side-file", role: .assistant, text: "Offline saved needle\nMEDIA:/saved.txt")]
        let book = savedBook(service), vault = MemoryConnectionStorage(saved: configuration)
        let scope = ArtifactCacheScope(configurationID: configuration.id,
            serverURL: Data(configuration.serverURL.absoluteString.utf8), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = WorkspaceLibrary(service: service, cache: warmCache.session(scope: scope))
        warm.setOnline(true); await warm.refresh(evidence: .observed, bots: service.profiles)
        for item in warm.artifacts { _ = try await warm.download(item) }
        warm.retire(); await warmCache.close()
        let historyURL = try LocalHistory.file(for: configuration.id)
        if historyState == "unreadable" { try Data("Unreadable saved history".utf8).write(to: historyURL) }
        if historyState == "partial" {
            var history = LocalHistory(); history.bots = [service.profiles[0]]
            try history.save(for: configuration.id)
        }
        let reads = service.historyOffsets.count, directories = service.directoryCount
        let downloads = service.downloadCount, rosters = service.botReadCount
        let cache = ArtifactCache(root: root), store = AppStore(service: service, persistence: vault.persistence, artifactCache: cache)
        #expect(!store.isConnected && store.cacheLoadFailed == (historyState == "unreadable"))
        await store.refreshLibraryIfNeeded(); await store.refreshLibrary(force: true)
        #expect(store.library.chats.contains { $0.identity == service.first })
        let saved = try #require(store.library.artifacts.first { $0.chat.identity == service.second })
        #expect(!LibrarySearchResults(query: "Offline saved needle", bots: [], chats: store.library.chats, artifacts: []).messages.isEmpty)
        #expect(try await store.library.download(saved).data == Data("side".utf8))
        #expect(service.historyOffsets.count == reads && service.directoryCount == directories
            && service.downloadCount == downloads && service.botReadCount == rosters)
        if historyState == "unreadable" { #expect(try Data(contentsOf: historyURL) == Data("Unreadable saved history".utf8)) }
        store.library.retire(); await cache.close()

        let coldCache = ArtifactCache(root: root), cold = AppStore(service: service, persistence: vault.persistence, artifactCache: coldCache)
        await cold.refreshLibraryIfNeeded()
        let retained = try #require(cold.library.artifacts.first { $0.chat.identity == service.second })
        #expect(try await cold.library.download(retained).data == Data("side".utf8))
        #expect(service.downloadCount == downloads && service.botReadCount == rosters)
        // Only an actual service roster response withdraws the saved bot.
        service.rosterProfiles = [service.profiles[0]]
        try #require(await cold.connect(configuration)); await cold.refreshLibrary(force: true)
        #expect(service.botReadCount > rosters && !cold.library.chats.contains { $0.identity == service.second })
        #expect(try await coldCache.session(scope: scope).metadataRecovery().contains(service.second))
        cold.library.retire(); await coldCache.close()
        let finalCache = ArtifactCache(root: root), final = WorkspaceLibrary(service: service, cache: finalCache.session(scope: scope))
        final.seed(book: book, bots: service.profiles); await final.restore()
        #expect(!final.chats.contains { $0.identity == service.second })
        let peer = try #require(final.artifacts.first { $0.chat.identity == service.first })
        let finalDownloads = service.downloadCount
        #expect(try await final.download(peer).data == Data("main".utf8))
        #expect(service.downloadCount == finalDownloads)
        final.retire(); await finalCache.close()
    }

    @Test(arguments: [false, true])
    func malformedLaterPageRevokesAnEarlierProducerAndItsPendingCapture(oversized: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), gate = CaptureCommitGate()
        defer { gate.release() }
        let old = ChatMessage(id: "main:row:7", role: .assistant, text: "Conflicted page needle\nMEDIA:/disputed.txt")
        service.messages[service.first] = [old]
        let book = savedBook(service)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root, beforeCaptureCommit: { gate.pause() }), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first { $0.chat.identity == service.first })
        _ = try await library.download(item)
        _ = try await library.download(try #require(library.artifacts.first { $0.chat.identity == service.second }))
        gate.arm(); service.fileBytes = Data("Uncommitted replacement".utf8)
        let capturing = Task { try await library.download(item, force: true) }
        defer { capturing.cancel() }
        var deadline = ContinuousClock.now + .seconds(5)
        while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.isEntered)
        let first = (1...100).map { $0 == 7 ? old : ChatMessage(id: "main:row:\($0)", role: .assistant, text: "First page \($0)") }
        service.historyPages[service.first] = [0: .init(messages: first, nextOffset: 100, isComplete: true,
            sourceIDs: Set(first.map { Data($0.id.utf8) }))]
        service.historyFailureOffsets[service.first] = 100
        service.historyFailures[service.first] = ConversationHistoryPage.Failure(identity: service.first,
            unavailableMessageIDs: [], sourceIDs: oversized ? [Data("main:row:200".utf8)] : [Data(old.id.utf8)],
            exceedsRowLimit: oversized)
        let reading = Task { await library.refresh(evidence: .observed, bots: service.profiles, force: true) }
        defer { reading.cancel() }
        deadline = .now + .seconds(5)
        while library.isCurrent(item), ContinuousClock.now < deadline { await Task.yield() }
        try #require(!library.isCurrent(item))
        #expect(service.historyOffsets.contains(100))
        #expect(LibrarySearchResults(query: "Conflicted page needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await capturing.value }
        await reading.value
        library.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root), coldSession = coldCache.session(scope: scope)
        let cold = WorkspaceLibrary(service: service, cache: coldSession)
        cold.seed(book: book, bots: service.profiles); await cold.restore()
        #expect(!cold.artifacts.contains { $0.artifact.messageID == old.id })
        #expect(LibrarySearchResults(query: "Conflicted page needle", bots: [], chats: cold.chats, artifacts: []).messages.isEmpty)
        let attachment = try #require(item.artifact.attachment)
        let key = try #require(await WorkspaceLibrary.originalKey(identity: service.first,
            attachment: attachment, messages: [old]))
        #expect(try await coldSession.original(for: key)?.artifact.data == Data("main".utf8))
        let peer = try #require(cold.artifacts.first { $0.chat.identity == service.second })
        let downloads = service.downloadCount
        #expect(try await cold.download(peer).data == Data("side".utf8))
        #expect(service.downloadCount == downloads)
        service.historyFailures = [:]; service.historyPages = [:]; service.historyFailureOffsets = [:]
        cold.setOnline(true); await cold.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(cold.artifacts.contains { $0.artifact.messageID == old.id })
        cold.retire(); await coldCache.close()
    }

    @Test(arguments: ["equal", "empty", "failed"])
    func reconnectKeepsRestoredArtifactsUntilTheFirstRosterIsObserved(response: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://first-roster.example")!)
        defer { try? FileManager.default.removeItem(at: root); LocalHistory.remove(for: configuration.id) }
        let service = LibraryTestService(secondBot: true), gate = StoreTestBarrier()
        defer { gate.release() }
        service.messages[service.second] = [.init(id: "side-file", role: .assistant, text: "First roster needle\nMEDIA:/saved.txt")]
        let book = savedBook(service), vault = MemoryConnectionStorage(saved: configuration)
        let scope = ArtifactCacheScope(configurationID: configuration.id,
            serverURL: Data(configuration.serverURL.absoluteString.utf8), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = WorkspaceLibrary(service: service, cache: warmCache.session(scope: scope))
        warm.setOnline(true); await warm.refresh(evidence: .observed, bots: service.profiles)
        for item in warm.artifacts { _ = try await warm.download(item) }
        warm.retire(); await warmCache.close()
        try LocalHistory(bots: service.profiles, book: book).save(for: configuration.id)
        let cache = ArtifactCache(root: root), store = AppStore(service: service, persistence: vault.persistence, artifactCache: cache)
        defer { store.library.retire() }
        await store.refreshLibraryIfNeeded()
        try #require(store.library.artifacts.contains { $0.chat.identity == service.second })
        service.botsBarrier = gate
        service.rosterProfiles = response == "empty" ? [] : service.profiles
        service.botsError = response == "failed" ? HermesServiceError.disconnected : nil
        let connecting = Task { await store.connect(configuration) }
        defer { connecting.cancel() }
        try #require(await gate.waitUntilEntered(timeout: .seconds(5)))
        try #require(store.isConnected)
        let beforeObservation = store.library.revalidationRevision
        let directories = service.directoryCount, reads = service.historyOffsets.count, downloads = service.downloadCount
        await store.refreshLibraryIfNeeded(); await store.refreshLibrary(force: true)
        let pending = try #require(store.library.artifacts.first { $0.chat.identity == service.second })
        #expect(!LibrarySearchResults(query: "First roster needle", bots: [], chats: store.library.chats, artifacts: []).messages.isEmpty)
        #expect(try await store.library.download(pending).data == Data("side".utf8))
        #expect(service.directoryCount == directories && service.historyOffsets.count == reads && service.downloadCount == downloads)
        // Read through a second cache while the first network roster is still held.
        let probeCache = ArtifactCache(root: root), probeSession = probeCache.session(scope: scope)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await probeSession.loadChats()).contains(where: { $0.identity == service.second }), ContinuousClock.now < deadline {
            await Task.yield()
        }
        let probe = WorkspaceLibrary(service: service, cache: probeSession)
        await probe.restore()
        let independent = try #require(probe.artifacts.first { $0.chat.identity == service.second })
        #expect(try await probe.download(independent).data == Data("side".utf8))
        #expect(service.downloadCount == downloads)
        probe.retire(); await probeCache.close()
        gate.release(); try #require(await connecting.value)
        service.botsBarrier = nil
        if response == "failed" {
            await store.refreshLibraryIfNeeded()
            #expect(store.library.revalidationRevision == beforeObservation)
            #expect(store.library.artifacts.contains { $0.chat.identity == service.second })
            #expect(service.directoryCount == directories && service.historyOffsets.count == reads)
            service.botsError = nil
            await store.refresh()
        }
        #expect(store.library.revalidationRevision != beforeObservation,
            "The first observed roster invalidates tab freshness even when cached labels are identical")
        let observedDirectories = service.directoryCount
        await store.refreshLibraryIfNeeded()
        if response == "empty" {
            #expect(store.library.chats.isEmpty)
            #expect(service.directoryCount == observedDirectories)
        } else {
            #expect(service.directoryCount == observedDirectories + service.profiles.count)
            #expect(store.library.artifacts.contains { $0.chat.identity == service.second })
        }
        // An observed absence remains authoritative after the initial read.
        service.rosterProfiles = [service.profiles[0]]
        await store.refresh(); await store.refreshLibrary(force: true)
        #expect(!store.library.chats.contains { $0.identity == service.second })
        #expect(try await cache.session(scope: scope).metadataRecovery().contains(service.second))
        store.library.retire(); await cache.close()
        let finalCache = ArtifactCache(root: root), final = WorkspaceLibrary(service: service, cache: finalCache.session(scope: scope))
        final.seed(book: book, bots: service.profiles); await final.restore()
        #expect(!final.chats.contains { $0.identity == service.second })
        let peer = try #require(final.artifacts.first { $0.chat.identity == service.first })
        let finalDownloads = service.downloadCount
        #expect(try await final.download(peer).data == Data("main".utf8))
        #expect(service.downloadCount == finalDownloads)
        final.retire(); await finalCache.close()
    }

    @Test(arguments: [false, true])
    func malformedHistoryFailureWithdrawsItsDisputedCaptureBeforeCommit(force: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), gate = CaptureCommitGate()
        defer { gate.release() }
        let old = ChatMessage(id: "main-file", role: .assistant, text: "Disputed needle\nMEDIA:/disputed.txt")
        service.messages[service.first] = [old]
        let book = savedBook(service)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root, beforeCaptureCommit: { gate.pause() }), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first { $0.chat.identity == service.first })
        _ = try await library.download(try #require(library.artifacts.first { $0.chat.identity == service.second }))
        gate.arm()
        let capturing = Task { try await library.download(item) }
        defer { capturing.cancel() }
        var deadline = ContinuousClock.now + .seconds(5)
        while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.isEntered)
        service.historyFailures[service.first] = ConversationHistoryPage.Failure(identity: service.first,
            unavailableMessageIDs: [Data(old.id.utf8)])
        let reading = Task { await library.refresh(evidence: .observed, bots: service.profiles, force: force) }
        defer { reading.cancel() }
        deadline = .now + .seconds(5)
        while library.isCurrent(item), ContinuousClock.now < deadline { await Task.yield() }
        try #require(!library.isCurrent(item))
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await capturing.value }
        await reading.value
        library.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root), coldSession = coldCache.session(scope: scope)
        let cold = WorkspaceLibrary(service: service, cache: coldSession)
        cold.seed(book: book, bots: service.profiles); await cold.restore()
        #expect(!cold.artifacts.contains { $0.artifact.messageID == old.id })
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: cold.chats, artifacts: []).messages.isEmpty)
        let key = try #require(await WorkspaceLibrary.originalKey(identity: service.first,
            attachment: ChatAttachment(name: "disputed.txt", path: "/disputed.txt"), messages: [old]))
        #expect(try await coldSession.original(for: key) == nil)
        let peer = try #require(cold.artifacts.first { $0.chat.identity == service.second })
        let downloads = service.downloadCount
        #expect(try await cold.download(peer).data == Data("side".utf8))
        #expect(service.downloadCount == downloads)
        service.historyFailures = [:]
        cold.setOnline(true); await cold.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(cold.artifacts.contains { $0.artifact.messageID == old.id })
        cold.retire(); await coldCache.close()
    }

    @Test func recoveredStorageCannotRestoreAnEvictedFreshProducer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService()
        let old = ChatMessage(id: "main-file", role: .assistant, text: "Retired needle\nMEDIA:/old.txt", timestamp: Date(timeIntervalSince1970: 10_000))
        service.messages[service.first] = [old]
        service.messages[service.second] = [.init(id: "side-file", role: .assistant, text: "MEDIA:/peer.txt", timestamp: Date(timeIntervalSince1970: 5_000))]
        let book = savedBook(service)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = WorkspaceLibrary(service: service, cache: warmCache.session(scope: scope))
        warm.setOnline(true); await warm.refresh(evidence: .observed, bots: service.profiles)
        _ = try await warm.download(try #require(warm.artifacts.first { $0.chat.identity == service.second }))
        warm.retire(); await warmCache.close()
        var handle: OpaquePointer?
        try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        let ledger = root.appendingPathComponent("metadata-recovery.plist"), unknown = Data("temporarily unreadable recovery".utf8)
        try unknown.write(to: ledger)
        let cache = ArtifactCache(root: root)
        cache.prune(reachableConfigurationIDs: [scope.configurationID])
        let session = cache.session(scope: scope), library = WorkspaceLibrary(service: service, limits: .init(chatCount: 1), cache: session)
        await library.restore()
        library.accept(identity: service.first, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [.init(id: old.id, role: .assistant, text: "Producer no longer references any file")]),
            title: "Fresh", evidence: .read(startedAt: .now, observedSource: service.first))
        let newer = SessionIdentity(profile: service.first.profile, root: try ExactID("newer"), stored: try ExactID("newer"), aliases: [])
        library.accept(identity: newer, snapshot: .init(id: "newer", storedID: "newer", profileID: "helper",
            messages: [.init(id: "new", role: .assistant, text: "Newer content", timestamp: Date(timeIntervalSince1970: 20))]),
            title: "Newer", evidence: .read(startedAt: .now, observedSource: newer))
        #expect(!library.chats.contains { $0.identity == service.first })
        #expect(try Data(contentsOf: ledger) == unknown)
        try #require(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        try FileManager.default.removeItem(at: ledger)
        await library.restore()
        #expect(!library.artifacts.contains { $0.artifact.messageID == old.id })
        #expect(LibrarySearchResults(query: "Retired needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(try await session.metadataRecovery().contains(service.first))
        let peer = try #require(library.artifacts.first { $0.chat.identity == service.second })
        let downloads = service.downloadCount
        #expect(try await library.download(peer).data == Data("side".utf8))
        #expect(service.downloadCount == downloads)
        library.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root), cold = WorkspaceLibrary(service: service, cache: coldCache.session(scope: scope))
        cold.seed(book: book, bots: service.profiles); await cold.restore()
        #expect(!cold.artifacts.contains { $0.artifact.messageID == old.id })
        cold.retire(); await coldCache.close()
    }

    @Test(arguments: [false, true])
    func sameMountRecoveryGuardsAnAbsentBotBeforeAnotherDirectoryRead(seedOldBook: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(secondBot: true), gate = StoreTestBarrier()
        defer { gate.release() }
        service.messages[service.second] = [.init(id: "side-file", role: .assistant, text: "Removed recovery needle\nMEDIA:/removed.txt")]
        let book = savedBook(service)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = WorkspaceLibrary(service: service, cache: warmCache.session(scope: scope))
        warm.setOnline(true); await warm.refresh(evidence: .observed, bots: service.profiles)
        _ = try await warm.download(try #require(warm.artifacts.first { $0.chat.identity == service.first }))
        warm.retire(); await warmCache.close()
        var handle: OpaquePointer?
        try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        if seedOldBook { library.seed(book: book, bots: service.profiles) }
        await library.restore()
        library.observeBots([service.profiles[0]], evidence: .observed)
        try #require(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        service.directoryBarriers[service.first.profile] = gate
        library.setOnline(true)
        let refreshing = Task { await library.refresh(evidence: .observed, bots: [service.profiles[0]], force: true) }
        defer { refreshing.cancel() }
        try #require(await gate.waitUntilEntered(timeout: .seconds(5)))
        #expect(!library.chats.contains { $0.identity == service.second })
        #expect(LibrarySearchResults(query: "Removed recovery needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(try await session.metadataRecovery().contains(service.second))
        library.retire(); gate.release(); await refreshing.value; await cache.close()
        service.directoryBarriers = [:]
        let coldCache = ArtifactCache(root: root), cold = WorkspaceLibrary(service: service, cache: coldCache.session(scope: scope))
        cold.seed(book: book, bots: service.profiles); await cold.restore()
        #expect(!cold.chats.contains { $0.identity == service.second })
        let peer = try #require(cold.artifacts.first { $0.chat.identity == service.first })
        let downloads = service.downloadCount
        #expect(try await cold.download(peer).data == Data("main".utf8))
        #expect(service.downloadCount == downloads)
        cold.setOnline(true); await cold.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(cold.artifacts.contains { $0.chat.identity == service.second })
        cold.retire(); await coldCache.close()
    }

    @Test func aLateRealOpeningCannotReintroduceAWithdrawnBot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(secondBot: true), cache = ArtifactCache(root: root), gate = StoreTestBarrier()
        defer { gate.release() }
        service.messages[service.second] = [.init(id: "withdrawn-file", role: .assistant, text: "Withdrawn bot needle\nMEDIA:/withdrawn.txt")]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://late-roster-read.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try #require(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let staleStart = ContinuousClock.now
        service.gatedSource = service.second; service.openingBarrier = gate
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        service.rosterProfiles = [service.profiles[0]]
        await store.refresh(); await store.refreshLibrary(force: true)
        gate.release()
        #expect(!(await opening.value))
        #expect(store.selectedBotID == service.first.profile.text)
        let stale = Conversation(id: service.second.root.text, storedID: service.second.stored.text,
            profileID: service.second.profile.text, messages: service.messages[service.second]!)
        store.library.accept(identity: service.second, snapshot: stale, title: "Removed", evidence: .read(startedAt: staleStart, observedSource: service.second))
        #expect(!store.library.chats.contains { $0.identity == service.second })
        #expect(!store.library.artifacts.contains { $0.chat.identity == service.second })
        #expect(LibrarySearchResults(query: "Withdrawn bot needle", bots: [], chats: store.library.chats, artifacts: []).messages.isEmpty)
        let scope = ArtifactCacheScope(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(), provider: nil)
        #expect(try await cache.session(scope: scope).metadataRecovery().contains(service.second))
        let coldCache = ArtifactCache(root: root), cold = WorkspaceLibrary(service: service, cache: coldCache.session(scope: scope))
        cold.seed(book: store.history.book, bots: service.profiles); await cold.restore()
        #expect(!cold.chats.contains { $0.identity == service.second })
        #expect(LibrarySearchResults(query: "Withdrawn bot needle", bots: [], chats: cold.chats, artifacts: []).messages.isEmpty)
        cold.retire(); await coldCache.close()
        service.rosterProfiles = service.profiles; service.openingBarrier = nil
        await store.refresh()
        store.library.accept(identity: service.second, snapshot: stale, title: "Still stale", evidence: .read(startedAt: staleStart, observedSource: service.second))
        #expect(!store.library.chats.contains { $0.identity == service.second })
        await store.open(service.profiles[1]); await store.refreshLibrary(force: true)
        #expect(store.selectedBotID == service.second.profile.text)
        #expect(store.library.artifacts.contains { $0.chat.identity == service.second })
        store.library.retire(); await cache.close()
    }

    @Test func aMountedLibraryRetriesStartupStorageAfterTheLockClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), book = savedBook(service)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = WorkspaceLibrary(service: service, cache: warmCache.session(scope: scope))
        warm.setOnline(true); await warm.refresh(evidence: .observed, bots: service.profiles)
        _ = try await warm.download(try #require(warm.artifacts.first { $0.chat.identity == service.second }))
        warm.retire(); await warmCache.close()
        var handle: OpaquePointer?
        try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        let cache = ArtifactCache(root: root)
        cache.prune(reachableConfigurationIDs: [scope.configurationID])
        let session = cache.session(scope: scope), library = WorkspaceLibrary(service: service, cache: session)
        library.seed(book: book, bots: service.profiles); await library.restore()
        #expect(library.chats.isEmpty)
        let current = ChatMessage(id: "main-file", role: .assistant, text: "Current safe needle")
        library.accept(identity: service.first,
            snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [current]),
            title: "Current", evidence: .read(startedAt: .now, observedSource: service.first))
        try #require(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        // These deliberate entries retry the same mount and share reconciliation.
        async let first: Void = library.restore()
        async let second: Void = library.restore()
        _ = await (first, second)
        #expect(library.chats.first { $0.identity == service.first }?.messages == [current])
        let retained = try #require(library.artifacts.first { $0.chat.identity == service.second })
        let downloads = service.downloadCount
        #expect(try await library.download(retained).data == Data("side".utf8))
        #expect(service.downloadCount == downloads)
        library.setOnline(true); service.fileBytes = Data("Explicit reload after recovery".utf8)
        #expect(try await library.download(retained, force: true).data == service.fileBytes)
        #expect(service.downloadCount == downloads + 1)
        library.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root), coldSession = coldCache.session(scope: scope)
        let cold = WorkspaceLibrary(service: service, cache: coldSession)
        await cold.restore()
        #expect(cold.artifacts.contains { $0.chat.identity == service.second }, "A checked saved row remains visible after another cold reopen")
        let attachment = try #require(retained.artifact.attachment)
        let key = try #require(await WorkspaceLibrary.originalKey(identity: retained.chat.identity,
            attachment: attachment, messages: retained.chat.messages))
        #expect(try await coldSession.original(for: key)?.artifact.data == service.fileBytes)
        cold.retire()
        await coldCache.close()
    }

    @Test func unavailableRecoveryStateKeepsDirtyBookkeepingBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), book = savedBook(service)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, limits: .init(chatCount: 2), cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let ledger = root.appendingPathComponent("metadata-recovery.plist"), unknown = Data("future recovery bytes".utf8)
        try unknown.write(to: ledger)
        for index in 0..<64 {
            let source = SessionIdentity(profile: service.first.profile, root: try ExactID("new-\(index)"), stored: try ExactID("new-\(index)"), aliases: [])
            library.accept(identity: source, snapshot: .init(id: source.root.text, storedID: source.stored.text,
                profileID: source.profile.text, messages: [.init(id: "new", role: .assistant, text: "Current", timestamp: Date(timeIntervalSince1970: Double(index + 1)))]),
                title: "New", evidence: .read(startedAt: .now, observedSource: source))
            #expect(library.chats.count <= 2 && library.indexingMetrics.pendingMetadataIdentities <= 4)
        }
        #expect(try Data(contentsOf: ledger) == unknown)
        // Restore a readable ledger, then require guards before any SQL writer.
        try FileManager.default.removeItem(at: ledger)
        let current = try #require(library.chats.first)
        library.accept(identity: current.identity, snapshot: .init(id: current.identity.root.text,
            storedID: current.identity.stored.text, profileID: current.identity.profile.text, messages: current.messages),
            title: "Retry", evidence: .read(startedAt: .now, observedSource: current.identity))
        #expect(try await session.metadataRecovery().contains(service.first))
        #expect(try await session.metadataRecovery().contains(service.second))
        library.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root), cold = WorkspaceLibrary(service: service, cache: coldCache.session(scope: scope))
        cold.seed(book: book, bots: service.profiles); await cold.restore()
        #expect(!cold.chats.contains { $0.identity == service.first || $0.identity == service.second })
        cold.retire(); await coldCache.close()
    }

    @Test(arguments: [false, true])
    func firstMetadataWriterCannotClearItsEvictionOnRetirement(seedOldBook: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), book = savedBook(service), gate = CaptureCommitGate()
        defer { gate.release() }
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root, beforeMetadataWrite: { gate.pause() }), session = cache.session(scope: scope)
        let limits = WorkspaceLibrary.Limits(chatCount: 1)
        let library = WorkspaceLibrary(service: service, limits: limits, cache: session)
        await library.restore(); gate.arm()
        library.accept(identity: service.first,
            snapshot: .init(id: "main", storedID: "main", profileID: "helper",
                messages: [.init(id: "main-file", role: .assistant, text: "MEDIA:/old.txt", timestamp: Date(timeIntervalSince1970: 10))]),
            title: "Main", evidence: .read(startedAt: .now, observedSource: service.first))
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.isEntered)
        library.accept(identity: service.second,
            snapshot: .init(id: "side", storedID: "side", profileID: "helper",
                messages: [.init(id: "side-file", role: .assistant, text: "MEDIA:/new.txt", timestamp: Date(timeIntervalSince1970: 20))]),
            title: "Side", evidence: .read(startedAt: .now, observedSource: service.second))
        #expect(!library.chats.contains { $0.identity == service.first })
        #expect(try await session.metadataRecovery().contains(service.first))
        library.retire(); gate.release(); await cache.close()
        let coldCache = ArtifactCache(root: root), coldSession = coldCache.session(scope: scope)
        #expect(try await coldSession.metadataRecovery().contains(service.first))
        let cold = WorkspaceLibrary(service: service, cache: coldSession)
        if seedOldBook { cold.seed(book: book, bots: service.profiles) }
        await cold.restore()
        #expect(!cold.chats.contains { $0.identity == service.first })
        #expect(!cold.artifacts.contains { $0.chat.identity == service.first })
        cold.retire(); await coldCache.close()
    }

    @Test(arguments: [false, true])
    func rosterWithdrawalIsDurableBeforeAnotherBotsHistoryReturns(seedOldBook: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(secondBot: true)
        service.messages[service.second] = [.init(id: "side-file", role: .assistant, text: "Removed bot needle\nMEDIA:/removed.txt")]
        let book = savedBook(service), history = StoreTestBarrier(); defer { history.release() }
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        _ = try await library.download(try #require(library.artifacts.first { $0.chat.identity == service.first }))
        service.historyBarrier = history
        let refreshing = Task { await library.refresh(evidence: .observed, bots: [service.profiles[0]], force: true) }
        defer { refreshing.cancel() }
        await history.waitUntilEntered()
        #expect(!library.chats.contains { $0.identity == service.second })
        #expect(try await session.metadataRecovery().contains(service.second))
        library.retire(); history.release(); await refreshing.value; await cache.close()
        let coldCache = ArtifactCache(root: root), cold = WorkspaceLibrary(service: service, cache: coldCache.session(scope: scope))
        if seedOldBook { cold.seed(book: book, bots: service.profiles) }
        await cold.restore()
        #expect(!cold.chats.contains { $0.identity == service.second })
        #expect(LibrarySearchResults(query: "Removed bot needle", bots: [], chats: cold.chats, artifacts: cold.artifacts).messages.isEmpty)
        let unaffected = try #require(cold.artifacts.first { $0.chat.identity == service.first })
        let downloads = service.downloadCount
        #expect(try await cold.download(unaffected).data == Data("main".utf8))
        #expect(service.downloadCount == downloads)
        cold.retire(); await coldCache.close()
    }

    @Test(arguments: [false, true], [false, true])
    func productionStartupPruneCannotBlockAReachableWithdrawalGuard(seedOldBook: Bool, waitForFailure: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), book = savedBook(service)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://startup-prune.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let scope = ArtifactCacheScope(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = WorkspaceLibrary(service: service, cache: warmCache.session(scope: scope))
        warm.setOnline(true); await warm.refresh(evidence: .observed, bots: service.profiles)
        _ = try await warm.download(try #require(warm.artifacts.first { $0.chat.identity == service.second }))
        warm.retire(); await warmCache.close()
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        let blockedCache = ArtifactCache(root: root), vault = MemoryConnectionStorage(saved: configuration)
        let store = AppStore(service: service, persistence: vault.persistence, artifactCache: blockedCache)
        if waitForFailure {
            await #expect(throws: (any Error).self) { try await blockedCache.drainMaintenance() }
        }
        store.library.accept(identity: service.first,
            snapshot: .init(id: "main", storedID: "main", profileID: "helper",
                messages: [.init(id: "main-file", role: .assistant, text: "Current producer no longer references a file.")]),
            title: "Main", evidence: .read(startedAt: .now, observedSource: service.first))
        #expect(!store.library.artifacts.contains { $0.chat.identity == service.first })
        #expect(try await blockedCache.session(scope: scope).metadataRecovery().contains(service.first))
        store.library.retire(); await blockedCache.close()
        #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        let coldCache = ArtifactCache(root: root), cold = WorkspaceLibrary(service: service, cache: coldCache.session(scope: scope))
        if seedOldBook { cold.seed(book: book, bots: service.profiles) }
        await cold.restore()
        #expect(!cold.chats.contains { $0.identity == service.first })
        let unaffected = try #require(cold.artifacts.first { $0.chat.identity == service.second })
        let downloads = service.downloadCount
        #expect(try await cold.download(unaffected).data == Data("side".utf8))
        #expect(service.downloadCount == downloads)
        cold.retire(); await coldCache.close()
    }

    @Test(arguments: ["scan", "seed"])
    func acceptanceFencesStayBoundedAndRejectDiscardedChanges(operation: String) async throws {
        let service = LibraryTestService(), gate = StoreTestBarrier(); defer { gate.release() }
        let book = savedBook(service)
        let target = operation == "seed" ? try #require(book.records.last?.binding.identity) : service.first
        let firstMessage = try #require(book.records.first?.transcript?.messages.first?.id)
        let limits = WorkspaceLibrary.Limits(chatCount: 1)
        let library = WorkspaceLibrary(service: service, limits: limits, projector: { messages, tail in
            if operation == "seed", messages.contains(where: { $0.id == firstMessage && $0.text.contains("report.txt") }) { await gate.wait() }
            return await WorkspaceLibrary.project(messages, streamingMessage: tail)
        })
        defer { library.retire() }
        await library.restore()
        let reading: Task<Void, Never>
        if operation == "seed" {
            library.seed(book: book, bots: service.profiles)
            reading = Task { await library.restore() }
        } else {
            service.historyBarrier = gate; library.setOnline(true)
            reading = Task { await library.refresh(evidence: .observed, bots: service.profiles, force: true) }
        }
        defer { reading.cancel() }
        await gate.waitUntilEntered()
        let targetMessage = target == service.first ? "main-file" : "side-file"
        library.accept(identity: target,
            snapshot: .init(id: target.root.text, storedID: target.stored.text, profileID: target.profile.text,
                messages: [.init(id: targetMessage, role: .assistant, text: "Fresh safe needle\nMEDIA:/current.txt", timestamp: Date(timeIntervalSince1970: 1_000))]),
            title: "Fresh", evidence: .read(startedAt: .now, observedSource: target))
        for index in 0..<20 {
            let source = SessionIdentity(profile: target.profile, root: try ExactID("noise-\(index)"), stored: try ExactID("noise-\(index)"), aliases: [])
            library.accept(identity: source,
                snapshot: .init(id: source.root.text, storedID: source.stored.text, profileID: source.profile.text,
                    messages: [.init(id: "row", role: .assistant, text: "Old noise", timestamp: Date(timeIntervalSince1970: -1_000))]),
                title: "Noise", evidence: .read(startedAt: .now, observedSource: source))
            #expect(library.indexingMetrics.retainedAcceptanceFences <= 2)
        }
        gate.release(); await reading.value
        let current = try #require(library.chats.first { $0.identity == target })
        #expect(current.title == "Fresh")
        #expect(current.messages.contains { $0.id == targetMessage && $0.text.contains("Fresh safe needle") })
        #expect(library.chats.count <= 1 && library.indexingMetrics.retainedAcceptanceFences <= 2)
    }

    @Test func repeatedUpdatesToOneChatDoNotFenceAnUnrelatedHistoryRead() async throws {
        let service = LibraryTestService(secondBot: true), gate = StoreTestBarrier(); defer { gate.release() }
        service.historyBarriers[service.second] = gate
        let limits = WorkspaceLibrary.Limits(chatCount: 2)
        let library = WorkspaceLibrary(service: service, limits: limits)
        defer { library.retire() }
        library.setOnline(true)
        let reading = Task { await library.refresh(evidence: .observed, bots: service.profiles, force: true) }
        defer { reading.cancel() }
        await gate.waitUntilEntered()
        for index in 0..<40 {
            library.accept(identity: service.first,
                snapshot: .init(id: "main", storedID: "main", profileID: "helper",
                    messages: [.init(id: "main-file", role: .assistant, text: "Fresh \(index)", timestamp: Date(timeIntervalSince1970: 1_000))]),
                title: "Fresh", evidence: .read(startedAt: .now, observedSource: service.first))
            #expect(library.indexingMetrics.retainedAcceptanceFences <= 4)
        }
        gate.release(); await reading.value
        #expect(library.artifacts.contains { $0.chat.identity == service.second })
        #expect(service.historyOffsets.count == 2)
    }

    @Test(arguments: [false, true])
    func retiredCaptureRollbackKeepsAnUnrelatedOfflineGalleryAndSearchUsable(seedOldBook: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService()
        service.messages[service.first] = [.init(id: "main-file", role: .assistant, text: "Saved needle\nMEDIA:/report.txt")]
        let book = savedBook(service)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = WorkspaceLibrary(service: service, cache: warmCache.session(scope: scope))
        warm.setOnline(true); await warm.refresh(evidence: .observed, bots: service.profiles)
        _ = try await warm.download(try #require(warm.artifacts.first { $0.chat.identity == service.first }))
        warm.retire(); await warmCache.close()
        var limits = ArtifactCache.Limits(); limits.chatCount = 1
        let gate = CaptureCommitGate(); defer { gate.release() }
        let cache = ArtifactCache(root: root, limits: limits, beforeCaptureCommit: { gate.pause() }), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        await library.restore(); library.setOnline(true)
        let next = try #require(library.artifacts.first { $0.chat.identity == service.second })
        gate.arm()
        let saving = Task { try await library.download(next) }; defer { saving.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.isEntered)
        #expect(try await session.metadataRecovery().contains(service.first))
        library.retire(); gate.release()
        await #expect(throws: (any Error).self) { _ = try await saving.value }
        await cache.close()
        let coldCache = ArtifactCache(root: root), cold = WorkspaceLibrary(service: service, cache: coldCache.session(scope: scope))
        if seedOldBook { cold.seed(book: book, bots: service.profiles) }
        await cold.restore()
        let retained = try #require(cold.artifacts.first { $0.chat.identity == service.first })
        #expect(!LibrarySearchResults(query: "Saved needle", bots: [], chats: cold.chats, artifacts: cold.artifacts).messages.isEmpty)
        let downloads = service.downloadCount
        #expect(try await cold.download(retained).data == Data("main".utf8))
        #expect(service.downloadCount == downloads)
        cold.retire(); await coldCache.close()
    }

    @Test(arguments: [false, true])
    func aSecondDirtyChatIsGuardedWhileTheFirstSQLWriteIsBlocked(seedOldBook: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CaptureCommitGate(); defer { gate.release() }
        let service = LibraryTestService(), book = savedBook(service)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root, beforeMetadataWrite: { gate.pause() }), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first { $0.chat.identity == service.second })
        _ = try await library.download(item)
        let key = ArtifactOriginalKey(identity: service.second, messageID: Data(item.artifact.messageID.utf8),
            path: Data(try #require(item.artifact.attachment).path.utf8),
            sourceRevision: try #require(item.chat.sourceRevisions[Data(item.artifact.messageID.utf8)]))
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        gate.arm()
        library.accept(identity: service.first,
            snapshot: .init(id: "main", storedID: "main", profileID: "helper",
                messages: [.init(id: "main-file", role: .assistant, text: "Main producer was revised without a file.")]), title: "Main",
            evidence: .read(startedAt: .now, observedSource: service.first))
        #expect(!library.artifacts.contains { $0.chat.identity == service.first })
        var deadline = ContinuousClock.now + .seconds(5)
        while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.isEntered)
        library.accept(identity: service.second,
            snapshot: .init(id: "side", storedID: "side", profileID: "helper",
                messages: [.init(id: "side-file", role: .assistant, text: "Side producer was revised without a file.")]), title: "Side",
            evidence: .read(startedAt: .now, observedSource: service.second))
        #expect(!library.artifacts.contains { $0.chat.identity == service.second })
        // This succeeds before the SQL owner is released, not after its timeout.
        let recovery = try await session.metadataRecovery()
        #expect(recovery.contains(service.first) && recovery.contains(service.second))
        #expect(!library.isCurrent(item))
        gate.release()
        deadline = .now + .seconds(5)
        while library.statusAction != .retry, ContinuousClock.now < deadline { await Task.yield() }
        try #require(library.statusAction == .retry)
        library.retire(); await cache.close()
        #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        let coldCache = ArtifactCache(root: root), coldSession = coldCache.session(scope: scope)
        let cold = WorkspaceLibrary(service: service, cache: coldSession)
        if seedOldBook { cold.seed(book: book, bots: service.profiles) }
        await cold.restore()
        #expect(cold.artifacts.isEmpty && cold.chats.isEmpty)
        #expect(try await coldSession.original(for: key)?.artifact.data == Data("side".utf8))
        cold.retire(); await coldCache.close()
    }

    @Test(arguments: [false, true])
    func withdrawalIsGuardedWhenSQLiteWasLockedBeforeSessionAcquisition(seedOldBook: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), book = savedBook(service)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = WorkspaceLibrary(service: service, cache: warmCache.session(scope: scope))
        warm.setOnline(true); await warm.refresh(evidence: .observed, bots: service.profiles)
        warm.retire(); await warmCache.close()
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        let blockedCache = ArtifactCache(root: root), blockedSession = blockedCache.session(scope: scope)
        let blocked = WorkspaceLibrary(service: service, cache: blockedSession)
        await blocked.restore()
        blocked.accept(identity: service.first,
            snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: []), title: "Main",
            evidence: .read(startedAt: .now, observedSource: service.first))
        #expect(try await blockedSession.metadataRecovery().contains(service.first))
        blocked.retire(); await blockedCache.close()
        #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        let coldCache = ArtifactCache(root: root), cold = WorkspaceLibrary(service: service, cache: coldCache.session(scope: scope))
        if seedOldBook { cold.seed(book: book, bots: service.profiles) }
        await cold.restore()
        #expect(!cold.chats.contains { $0.identity == service.first })
        #expect(cold.artifacts.contains { $0.chat.identity == service.second })
        cold.retire(); await coldCache.close()
    }

    @Test(.timeLimit(.minutes(1))) func coldSeedCannotExposeAProducerBeforeSavedRemovalEvidenceIsLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), book = savedBook(service)
        let first = try #require(book.records.first?.binding.identity)
        let later = try #require(book.records.last?.binding.identity)
        try #require(first != later)
        let firstMessage = try #require(book.records.first?.transcript?.messages.first?.id)
        let laterMessage = try #require(service.messages[later]?.first?.id)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = WorkspaceLibrary(service: service, cache: warmCache.session(scope: scope))
        warm.setOnline(true); await warm.refresh(evidence: .observed, bots: service.profiles)
        let old = try #require(warm.artifacts.first { $0.chat.identity == first })
        _ = try await warm.download(old)
        service.messages[first] = []; await warm.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(!warm.artifacts.contains { $0.chat.identity == first })
        warm.retire(); await warmCache.close()
        let firstProjection = StoreTestBarrier(), projection = StoreTestBarrier(), pause = NextLibraryProjectionPause()
        defer { firstProjection.release(); projection.release() }
        await pause.arm()
        let coldCache = ArtifactCache(root: root)
        let cold = WorkspaceLibrary(service: service, cache: coldCache.session(scope: scope), projector: { messages, tail in
            if messages.contains(where: { $0.id == firstMessage }) { await firstProjection.wait() }
            if messages.contains(where: { $0.id == laterMessage }), await pause.take() { await projection.wait() }
            return await WorkspaceLibrary.project(messages, streamingMessage: tail)
        })
        cold.seed(book: book, bots: service.profiles)
        let restoring = Task { await cold.restore() }; defer { restoring.cancel() }
        await firstProjection.waitUntilEntered(); firstProjection.release()
        await projection.waitUntilEntered()
        #expect(!cold.chats.contains { $0.identity == first })
        #expect(!cold.artifacts.contains { $0.chat.identity == first })
        projection.release(); await restoring.value
        #expect(!cold.artifacts.contains { $0.chat.identity == first })
        #expect(cold.artifacts.contains { $0.chat.identity == later })
        cold.retire(); await coldCache.close()
    }

    @Test func successfulIndexEvictionCannotReviveAnOlderBookProducer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), book = savedBook(service)
        service.omitSecond = true
        var limits = ArtifactCache.Limits(); limits.chatCount = 1
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root, limits: limits), session = cache.session(scope: scope)
        let warm = WorkspaceLibrary(service: service, cache: session)
        warm.setOnline(true); await warm.refresh(evidence: .observed, bots: service.profiles)
        let old = try #require(warm.artifacts.first { $0.chat.identity == service.first })
        _ = try await warm.download(old)
        let key = ArtifactOriginalKey(identity: service.first, messageID: Data(old.artifact.messageID.utf8),
            path: Data(try #require(old.artifact.attachment).path.utf8),
            sourceRevision: try #require(old.chat.sourceRevisions[Data(old.artifact.messageID.utf8)]))
        service.messages[service.first] = []; await warm.refresh(evidence: .observed, bots: service.profiles, force: true)
        try await session.upsert(.init(identity: service.second, botName: "Helper", title: "Side", messages: service.messages[service.second] ?? [],
            updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
        #expect(try await session.loadChats().map(\.identity) == [service.second])
        #expect(try await session.metadataRecovery().contains(service.first))
        warm.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root, limits: limits), coldSession = coldCache.session(scope: scope)
        let cold = WorkspaceLibrary(service: service, cache: coldSession)
        cold.seed(book: book, bots: service.profiles); await cold.restore()
        #expect(!cold.chats.contains { $0.identity == service.first })
        #expect(!cold.artifacts.contains { $0.chat.identity == service.first })
        #expect(cold.artifacts.contains { $0.chat.identity == service.second })
        #expect(try await coldSession.original(for: key)?.artifact.data == Data("main".utf8))
        cold.retire(); await coldCache.close()
    }

    @Test(arguments: [false, true])
    func historicalCompletionCannotReleaseAGalleryWaiterBeforeItsProjection(failingSave: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), network = StoreTestBarrier(), projection = StoreTestBarrier()
        let pause = NextLibraryProjectionPause()
        defer { network.release(); projection.release() }
        let old = ChatMessage(id: "old", role: .assistant, text: "MEDIA:/same.html", timestamp: Date(timeIntervalSince1970: 10))
        let newer = ChatMessage(id: "new", role: .assistant, text: "MEDIA:/same.html", timestamp: Date(timeIntervalSince1970: 20))
        service.messages[service.first] = [old]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session, projector: { messages, tail in
            if messages.contains(where: { $0.id == newer.id }), await pause.take() { await projection.wait() }
            return await WorkspaceLibrary.project(messages, streamingMessage: tail)
        })
        defer { library.retire() }
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let opened = try await service.openChat(.stored(service.first))
        let item = try #require(library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        let key = ArtifactOriginalKey(identity: service.first, messageID: Data(old.id.utf8), path: Data(attachment.path.utf8),
            sourceRevision: try #require(item.chat.sourceRevisions[Data(old.id.utf8)]))
        service.downloadBarrier = network
        var galleryFinished = false, historicalFinished = false, joined = false
        let gallery = Task { defer { galleryFinished = true }; return try await library.download(item) }
        defer { gallery.cancel() }
        await network.waitUntilEntered()
        let historical = Task {
            let result = try await library.original(for: key, validateNetwork: {
                guard try service.source(for: opened.access) == service.first else { throw HermesServiceError.staleConversation }
                joined = true
            }) { try await service.downloadArtifact(attachment, in: service.first) }
            historicalFinished = true; return result
        }
        defer { historical.cancel() }
        var deadline = ContinuousClock.now + .seconds(5)
        while !joined, ContinuousClock.now < deadline { await Task.yield() }
        try #require(joined)
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        if failingSave {
            #expect(sqlite3_exec(handle, "CREATE TRIGGER fail_capture BEFORE INSERT ON entries WHEN NEW.kind=1 BEGIN SELECT RAISE(ABORT,'injected capture failure'); END", nil, nil, nil) == SQLITE_OK)
        }
        await pause.arm()
        library.accept(identity: service.first,
            snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [old, newer], isWorking: true),
            title: "Main", evidence: .incremental(previous: opened.snapshot))
        await projection.waitUntilEntered()
        service.downloadBarrier = nil; network.release()
        deadline = .now + .seconds(5)
        while !historicalFinished, ContinuousClock.now < deadline { await Task.yield() }
        try #require(historicalFinished)
        #expect(!galleryFinished, "Historical access must not complete a gallery reader whose provenance is pending.")
        #expect(try await historical.value.data == Data("main".utf8))
        projection.release()
        await #expect(throws: (any Error).self) { _ = try await gallery.value }
        library.retire(); await cache.close()
        let reopened = ArtifactCache(root: root)
        #expect(try await reopened.session(scope: scope).original(for: key)?.artifact.data == (failingSave ? nil : Data("main".utf8)))
        await reopened.close()
    }

    @Test(arguments: ["removal", "certificate", "tip"], [false, true])
    func failedMetadataPersistenceCannotRestoreWithdrawnRowsOrCertificates(change: String, seedOldBook: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(); service.versionedSummaries = true
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let old = try #require(library.artifacts.first { $0.chat.identity == service.first })
        let unaffected = try #require(library.artifacts.first { $0.chat.identity == service.second })
        _ = try await library.download(old); _ = try await library.download(unaffected)
        var book = ConversationBook()
        for source in [service.first, service.second] {
            let id = book.merge(.init(identity: source, title: source.root.text, isCanonical: source == service.first, persistence: .durable))
            book.cache(.init(id: source.root.text, storedID: source.stored.text, profileID: source.profile.text,
                messages: service.messages[source] ?? []), for: id)
        }
        if change == "removal" { service.messages[service.first] = [] }
        else if change == "certificate" { service.failingHistorySource = service.first }
        else {
            let successor = SessionIdentity(profile: service.first.profile, root: service.first.root,
                stored: try ExactID("successor"), aliases: [service.first.stored])
            service.replacementFirst = successor
            service.messages[successor] = [.init(id: "next", role: .assistant, text: "MEDIA:/next.txt")]
        }
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.statusAction == .retry)
        let recovery = try await session.metadataRecovery()
        #expect(recovery.contains(service.first) && !recovery.contains(service.second))
        library.retire(); await cache.close()
        #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        let reopenedCache = ArtifactCache(root: root), reopenedSession = reopenedCache.session(scope: scope)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedSession)
        if seedOldBook { reopened.seed(book: book, bots: service.profiles) }
        await reopened.restore()
        #expect(!reopened.chats.contains { $0.identity.root == service.first.root })
        let retained = try #require(reopened.artifacts.first { $0.chat.identity == service.second })
        let downloads = service.downloadCount
        #expect(try await reopened.download(retained).data == Data("side".utf8))
        #expect(service.downloadCount == downloads)
        reopened.setOnline(true)
        #expect(reopened.statusAction == .retry)
        service.failingHistorySource = nil
        let reads = service.historyOffsets.count
        await reopened.refreshIfNeeded(evidence: .observed, bots: service.profiles)
        #expect(service.historyOffsets.count > reads)
        #expect(try await !reopenedSession.metadataRecovery().contains(service.first))
        if change == "removal" { #expect(!reopened.artifacts.contains { $0.chat.identity == service.first }) }
        else if change == "certificate" { #expect(reopened.artifacts.contains { $0.chat.identity == service.first }) }
        else { #expect(reopened.artifacts.contains { $0.artifact.title == "next.txt" }) }
        reopened.retire(); await reopenedCache.close()
        if change == "tip" {
            let finalCache = ArtifactCache(root: root), final = WorkspaceLibrary(service: service, cache: finalCache.session(scope: scope))
            final.seed(book: book, bots: service.profiles); await final.restore()
            #expect(final.artifacts.contains { $0.artifact.title == "next.txt" })
            #expect(!final.artifacts.contains { $0.chat.identity == service.first })
            final.retire(); await finalCache.close()
        }
    }

    @Test func directoryAbsenceSurvivesImmediateTabReseedingAndIndependentReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService()
        service.messages[service.second] = [.init(id: "ghost", role: .assistant, text: "Ghost needle\nMEDIA:/ghost.txt")]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://directory-absence.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let scope = ArtifactCacheScope(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        try #require(await store.connect(configuration)); await store.refreshLibrary()
        let old = try #require(store.library.artifacts.first { $0.chat.identity == service.second })
        try #require(await store.openLibraryChat(old.chat))
        _ = try await store.library.download(old)
        let savedBook = store.history.book
        service.omitSecond = true
        await store.refreshLibrary(force: true)
        #expect(!store.library.chats.contains { $0.identity.root == service.second.root })
        let directories = service.directoryCount, reads = service.historyOffsets.count
        for _ in 0..<2 { await store.refreshLibraryIfNeeded() }
        #expect(service.directoryCount == directories && service.historyOffsets.count == reads)
        #expect(!store.library.artifacts.contains { $0.artifact.title == "ghost.txt" })
        #expect(LibrarySearchResults(query: "Ghost needle", bots: [], chats: store.library.chats, artifacts: []).messages.isEmpty)
        let saved = try await cache.session(scope: scope).loadChats()
        #expect(saved.first { $0.identity.root == service.second.root }?.directoryAbsent == true)
        store.library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        reopened.seed(book: savedBook, bots: service.profiles); await reopened.restore()
        #expect(!reopened.chats.contains { $0.identity.root == service.second.root })
        #expect(!reopened.artifacts.contains { $0.artifact.title == "ghost.txt" })
        service.omitSecond = false; reopened.setOnline(true)
        await reopened.refresh(evidence: .observed, bots: service.profiles)
        #expect(reopened.artifacts.contains { $0.artifact.title == "ghost.txt" })
        reopened.retire(); await reopenedCache.close()
    }

    @Test func failedForcedHistoryCannotReuseItsOldCertificateOnNormalOrColdRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(); service.versionedSummaries = true
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        service.failHistory = true
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.statusAction == .retry)
        let reads = service.historyOffsets.count
        library.invalidateRevalidation(); await library.refreshIfNeeded(evidence: .observed, bots: service.profiles)
        #expect(service.historyOffsets.count > reads && library.statusAction == .retry)
        let saved = try await session.loadChats()
        #expect(!saved.isEmpty && saved.allSatisfy { $0.coverage == .partial && $0.summary == nil && $0.headFingerprint == nil })
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore(); reopened.setOnline(true)
        let coldReads = service.historyOffsets.count
        await reopened.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyOffsets.count > coldReads && reopened.statusAction == .retry)
        service.failHistory = false
        let retryReads = service.historyOffsets.count
        await reopened.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyOffsets.count > retryReads && reopened.warning == nil)
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: ["legacy", "retired", "fresh"])
    func cachedSuccessorRetirementOutranksOnlyAnInertOlderBook(proof: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService()
        let successor = SessionIdentity(profile: service.first.profile, root: service.first.root,
            stored: try ExactID("successor"), aliases: [service.first.stored])
        let old = ChatMessage(id: "old-file", role: .assistant, text: "MEDIA:/old.txt")
        let tail = ChatMessage(id: "working", role: .assistant, text: "Still working")
        let new = ChatMessage(id: "new-file", role: .assistant, text: "MEDIA:/new.txt")
        let snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [old, tail], isWorking: true)
        var book = ConversationBook()
        let id = book.merge(.init(identity: service.first, title: "Main", isCanonical: true, persistence: .durable))
        book.cache(snapshot, for: id)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        try await session.upsert(.init(identity: successor, botName: "Helper", title: "Main", messages: [new], updatedAt: nil,
            coverage: .complete, summary: nil, headFingerprint: nil,
            retiredStoredIDs: proof == "legacy" ? nil : [service.first.stored.bytes]))
        let library = WorkspaceLibrary(service: service, cache: session)
        library.seed(book: book, bots: service.profiles)
        if proof == "fresh" {
            let deadline = ContinuousClock.now + .seconds(5)
            while library.chats.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
            try #require(!library.chats.isEmpty)
            library.accept(identity: service.first, snapshot: snapshot, title: "Main",
                evidence: .read(startedAt: .now, observedSource: service.first))
        }
        await library.restore()
        let expected = proof == "retired" ? successor : service.first
        if proof == "fresh" {
            let deadline = ContinuousClock.now + .seconds(5)
            while !library.artifacts.contains(where: { $0.artifact.title == "old.txt" }), ContinuousClock.now < deadline { await Task.yield() }
            try #require(library.artifacts.contains { $0.artifact.title == "old.txt" })
        }
        #expect(library.chats.first?.identity.stored == expected.stored)
        #expect(library.artifacts.map(\.artifact.title) == [proof == "retired" ? "new.txt" : "old.txt"])
        if proof == "retired" {
            let saved = try #require(try await session.loadChats().first)
            #expect(saved.identity.stored == successor.stored && saved.coverage == .complete)
            #expect(saved.retiredStoredIDs == [service.first.stored.bytes])
            library.retire(); await cache.close()
            let reopenedCache = ArtifactCache(root: root)
            let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
            reopened.seed(book: book, bots: service.profiles); await reopened.restore()
            #expect(reopened.artifacts.map(\.artifact.title) == ["new.txt"])
            reopened.retire(); await reopenedCache.close()
        } else { library.retire(); await cache.close() }
        #expect(service.historyOffsets.isEmpty && service.downloadCount == 0)
    }

    @Test func aDirectorySuccessorRetiresAWorkingTipBeforeHistoryOrCaptureCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), capture = CaptureCommitGate(), history = StoreTestBarrier()
        defer { capture.release(); history.release() }
        let old = ChatMessage(id: "old-file", role: .assistant, text: "Old needle\nMEDIA:/old.txt")
        service.messages[service.first] = [old]
        let cache = ArtifactCache(root: root, beforeCaptureCommit: { capture.pause() })
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let session = cache.session(scope: scope), library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let original = try #require(library.artifacts.first { $0.chat.identity == service.first })
        let key = ArtifactOriginalKey(identity: service.first, messageID: Data(old.id.utf8), path: Data("/old.txt".utf8),
            sourceRevision: try #require(original.chat.sourceRevisions[Data(old.id.utf8)]))
        library.accept(identity: service.first,
            snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [old,
                .init(id: "working", role: .assistant, text: "Still working")], isWorking: true),
            title: "Main", evidence: .read(startedAt: .now, observedSource: service.first))
        capture.arm()
        let download = Task { try await library.download(original) }
        defer { download.cancel() }
        var deadline = ContinuousClock.now + .seconds(5)
        while !capture.isEntered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(capture.isEntered)
        let successor = SessionIdentity(profile: service.first.profile, root: service.first.root,
            stored: try ExactID("successor"), aliases: [service.first.stored])
        service.replacementFirst = successor
        service.messages[successor] = [.init(id: "new-file", role: .assistant, text: "MEDIA:/new.txt")]
        service.historyBarrier = history
        let reads = service.historyOffsets.count
        let refresh = Task { await library.refresh(evidence: .observed, bots: service.profiles, force: true) }
        defer { refresh.cancel() }
        deadline = .now + .seconds(5)
        while service.historyOffsets.count == reads, ContinuousClock.now < deadline { await Task.yield() }
        try #require(service.historyOffsets.count > reads)
        #expect(library.chats.first { $0.identity.root == service.first.root }?.identity.stored == successor.stored)
        #expect(!library.isCurrent(original))
        #expect(LibrarySearchResults(query: "Old needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        capture.release()
        await #expect(throws: (any Error).self) { _ = try await download.value }
        service.historyBarrier = nil; history.release(); await refresh.value
        #expect(library.artifacts.contains { $0.artifact.title == "new.txt" })
        deadline = .now + .seconds(5)
        var persisted = false
        while !persisted, ContinuousClock.now < deadline {
            persisted = try await session.loadChats().contains { $0.identity.stored == successor.stored && $0.coverage == .complete }
            if !persisted { await Task.yield() }
        }
        try #require(persisted)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root), reopenedSession = reopenedCache.session(scope: scope)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedSession)
        await reopened.restore()
        #expect(reopened.artifacts.contains { $0.artifact.title == "new.txt" })
        #expect(!reopened.artifacts.contains { $0.artifact.title == "old.txt" })
        #expect(try await reopenedSession.original(for: key) == nil)
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: [false, true])
    func oldTipPublicationsCannotReplaceAnObservedSuccessorAcrossReopen(empty: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://tip-observation.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let cache = ArtifactCache(root: root)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        try #require(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let oldReadStartedAt = ContinuousClock.now, oldAccess = try #require(service.lastAccess)
        let next = SessionIdentity(profile: service.first.profile, root: service.first.root,
            stored: try ExactID("next-tip"), aliases: service.first.aliases)
        service.replacementFirst = next
        service.messages[next] = [.init(id: "next-report", role: .assistant, text: "MEDIA:/next.txt")]
        let history = StoreTestBarrier(), reads = service.historyOffsets.count
        defer { history.release() }
        service.historyBarrier = history
        let refresh = Task { await store.refreshLibrary(force: true) }
        defer { refresh.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while service.historyOffsets.count == reads, ContinuousClock.now < deadline { await Task.yield() }
        try #require(service.historyOffsets.count > reads)
        let stale = Conversation(id: "main", storedID: "main", profileID: "helper",
            messages: empty ? [] : [.init(id: "old-event", role: .assistant, text: "MEDIA:/old-tip.txt")])
        service.onEvent?(.conversation(.init(identity: service.first, snapshot: stale, access: oldAccess)))
        #expect(store.library.chats.first { $0.identity.root == next.root }?.identity.stored == next.stored)
        service.historyBarrier = nil; history.release(); await refresh.value
        let successor = try #require(store.library.artifacts.first { $0.chat.identity == next })
        _ = try await store.library.download(successor)
        service.onEvent?(.conversation(.init(identity: service.first, snapshot: stale, access: oldAccess)))
        service.onEvent?(.conversation(.init(identity: service.first, snapshot: stale, access: oldAccess,
            historyReadStartedAt: oldReadStartedAt, observedSource: service.first)))
        service.onEvent?(.conversation(.init(identity: service.first, snapshot: stale, access: oldAccess,
            historyReadStartedAt: .now)))
        #expect(store.library.isCurrent(successor))
        #expect(store.library.chats.first { $0.identity.root == next.root }?.identity.stored == next.stored)
        #expect(!store.library.artifacts.contains { $0.artifact.title == "old-tip.txt" })
        let oldBook = store.history.book
        #expect(await store.openLibraryChat(successor.chat))
        #expect(store.library.chats.first { $0.identity.root == next.root }?.identity.stored == next.stored)
        store.library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let scope = ArtifactCacheScope(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(), provider: nil)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        reopened.seed(book: oldBook, bots: service.profiles); await reopened.restore()
        #expect(reopened.chats.first { $0.identity.root == next.root }?.identity.stored == next.stored)
        let offline = try #require(reopened.artifacts.first { $0.artifact.title == "next.txt" })
        #expect(try await reopened.download(offline).data == Data("main".utf8))
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: [false, true], ["before", "after"])
    func derivedPathReplacementRevokesAPrecommitGalleryConsumerUnlessAHistoricalPeerSurvives(peer: Bool, discovery: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), gate = CaptureCommitGate(), network = StoreTestBarrier()
        defer { gate.release(); network.release() }
        let old = ChatMessage(id: "old", role: .assistant, text: "MEDIA:/same.html", timestamp: Date(timeIntervalSince1970: 10))
        let newer = ChatMessage(id: "new", role: .assistant, text: "MEDIA:/same.html", timestamp: Date(timeIntervalSince1970: 20))
        service.messages[service.first] = [old]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://derived-provenance.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let scope = ArtifactCacheScope(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root, beforeCaptureCommit: { gate.pause() })
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        try #require(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let library = store.library
        let item = try #require(library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: old))
        defer { store.finishArtifact(destination) }
        let key = ArtifactOriginalKey(identity: service.first, messageID: Data(old.id.utf8), path: Data(attachment.path.utf8),
            sourceRevision: try #require(item.chat.sourceRevisions[Data(old.id.utf8)]))
        gate.arm(); service.downloadBarrier = network
        let gallery = Task { try await library.download(item) }
        defer { gallery.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while service.downloadCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        try #require(service.downloadCount == 1)
        var joined = false
        let historical: Task<DownloadedArtifact, Error>? = peer ? Task {
            try await library.original(for: key, validateNetwork: {
                guard store.isCurrentArtifactDestination(destination) else { throw HermesServiceError.staleConversation }
                joined = true
            }) {
                try await service.downloadArtifact(attachment, in: service.first)
            }
        } : nil
        defer { historical?.cancel() }
        var until = ContinuousClock.now + .seconds(5)
        while peer && !joined, ContinuousClock.now < until { await Task.yield() }
        try #require(!peer || joined)
        service.downloadBarrier = nil; network.release()
        until = .now + .seconds(5)
        while !gate.isEntered, ContinuousClock.now < until { await Task.yield() }
        try #require(gate.isEntered)
        service.onEvent?(.conversation(.init(identity: service.first,
            snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [old, newer], isWorking: true),
            access: try #require(service.lastAccess))))
        if discovery == "after" {
            until = .now + .seconds(5)
            while !library.artifacts.contains(where: { $0.artifact.messageID == newer.id }), ContinuousClock.now < until { await Task.yield() }
            try #require(library.artifacts.contains { $0.artifact.messageID == newer.id })
            #expect(!library.isCurrent(item))
        } else { #expect(!library.artifacts.contains { $0.artifact.messageID == newer.id }) }
        #expect(store.isCurrentArtifactDestination(destination))
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await gallery.value }
        if let historical { #expect(try await historical.value.data == Data("main".utf8)) }
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root), reopened = reopenedCache.session(scope: scope)
        #expect(try await reopened.original(for: key)?.artifact.data == (peer ? Data("main".utf8) : nil))
        await reopenedCache.close()
    }

    @Test(arguments: ["removed", "suffix", "ambiguous"])
    func inheritedIncrementalRowsCannotUndoNewerLibraryEvidence(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService()
        let old = ChatMessage(id: "report", role: .assistant, text: "Stale needle\nMEDIA:/retired.html", timestamp: Date(timeIntervalSince1970: 20))
        let kept = ChatMessage(id: "kept", role: .assistant, text: "MEDIA:/kept.txt", timestamp: Date(timeIntervalSince1970: 10))
        service.messages[service.first] = [kept, old]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://publication-evidence.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let cache = ArtifactCache(root: root)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        try #require(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.artifact.messageID == old.id })
        let retained = try #require(store.library.artifacts.first { $0.artifact.messageID == kept.id })
        _ = try await store.library.download(item); _ = try await store.library.download(retained)
        let staleReadStartedAt = ContinuousClock.now
        switch change {
        case "removed": service.messages[service.first] = [kept]
        case "suffix": service.messages[service.first] = [kept, .init(id: old.id, role: .assistant, text: "Revised report", timestamp: old.timestamp)]
        default: service.messages[service.first] = [kept, old, .init(id: old.id, role: .assistant, text: "Conflicting occurrence")]
        }
        await store.refreshLibrary(force: true)
        let parsed = store.library.indexingMetrics.parsedMessages
        let stale = Conversation(id: "main", storedID: "main", profileID: "helper",
            messages: [kept, old, .init(id: "event", role: .assistant, text: "New incremental text")])
        service.onEvent?(.conversation(.init(identity: service.first, snapshot: stale, access: try #require(service.lastAccess))))
        #expect(!store.library.isCurrent(item))
        #expect(LibrarySearchResults(query: "Stale needle", bots: [], chats: store.library.chats, artifacts: []).messages.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while store.library.indexingMetrics.parsedMessages <= parsed, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!store.library.artifacts.contains { $0.artifact.messageID == old.id })
        let savedBook = store.history.book
        let scope = ArtifactCacheScope(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(), provider: nil)
        let checkpoint = cache.session(scope: scope)
        var durable = false
        let saveDeadline = ContinuousClock.now + .seconds(5)
        while !durable, ContinuousClock.now < saveDeadline {
            let rows = try await checkpoint.loadChats()
            durable = try await !checkpoint.metadataRecovery().contains(service.first)
                && rows.contains { $0.identity == service.first && $0.messages.contains { $0.id == kept.id } }
            if !durable { await Task.yield() }
        }
        try #require(durable, "The ordinary cold-reuse control needs a completed metadata checkpoint; interrupted writes are covered separately")
        store.library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        reopened.seed(book: savedBook, bots: service.profiles); await reopened.restore()
        #expect(!reopened.artifacts.contains { $0.artifact.messageID == old.id })
        #expect(LibrarySearchResults(query: "Stale needle", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        let offline = try #require(reopened.artifacts.first { $0.artifact.messageID == kept.id })
        #expect(try await reopened.download(offline).data == Data("main".utf8))
        reopened.accept(identity: service.first, snapshot: stale, title: "Main", evidence: .read(startedAt: staleReadStartedAt, observedSource: service.first))
        #expect(!reopened.artifacts.contains { $0.artifact.messageID == old.id })
        reopened.accept(identity: service.first, snapshot: stale, title: "Main", evidence: .read(startedAt: .now, observedSource: service.first))
        let recoveryDeadline = ContinuousClock.now + .seconds(5)
        while !reopened.artifacts.contains(where: { $0.artifact.messageID == old.id }), ContinuousClock.now < recoveryDeadline { await Task.yield() }
        #expect(reopened.artifacts.contains { $0.artifact.messageID == old.id })
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: ["ambiguous", "edited", "tip"])
    func acceptedSafetyRevokesAGalleryCaptureBeforeDeferredProjection(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), gate = CaptureCommitGate()
        defer { gate.release() }
        let old = ChatMessage(id: "report", role: .assistant, text: "Old needle\nMEDIA:/report.html", timestamp: Date(timeIntervalSince1970: 20))
        let kept = ChatMessage(id: "kept", role: .assistant, text: "MEDIA:/kept.txt", timestamp: Date(timeIntervalSince1970: 10))
        service.messages[service.first] = [kept, old]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root, beforeCaptureCommit: { gate.pause() }), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first { $0.artifact.messageID == old.id })
        let unaffected = try #require(library.artifacts.first { $0.artifact.messageID == kept.id })
        let key = ArtifactOriginalKey(identity: service.first, messageID: Data(old.id.utf8), path: Data("/report.html".utf8),
            sourceRevision: try #require(item.chat.sourceRevisions[Data(old.id.utf8)]))
        gate.arm()
        let download = Task { try await library.download(item) }
        defer { download.cancel(); gate.release() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.isEntered)
        let peer = change == "tip" ? nil : Task { try await library.download(unaffected, force: true) }
        defer { peer?.cancel() }
        let source = change == "tip" ? SessionIdentity(profile: service.first.profile, root: service.first.root,
            stored: try ExactID("new-tip"), aliases: service.first.aliases) : service.first
        var snapshot = Conversation(id: "main", storedID: source.stored.text, profileID: "helper", messages: [kept,
            change == "edited" ? .init(id: old.id, role: .assistant, text: "Revised report", timestamp: old.timestamp) : old], isWorking: true)
        if change == "ambiguous" { snapshot.unavailableMessageIDs = [Data(old.id.utf8)] }
        library.accept(identity: source, snapshot: snapshot, title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        #expect(!library.isCurrent(item))
        #expect(library.isCurrent(unaffected) == (change != "tip"))
        #expect(LibrarySearchResults(query: "Old needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await download.value }
        if let peer { #expect(try await peer.value.data == Data("main".utf8)) }
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root), reopened = reopenedCache.session(scope: scope)
        #expect(try await reopened.original(for: key) == nil)
        await reopenedCache.close()
    }

    @Test(arguments: [false, true], ["close", "cancel", "connection"])
    func captureCommitRequiresASurvivingConsumer(validPeer: Bool, retirement: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CaptureCommitGate(), network = StoreTestBarrier()
        defer { gate.release(); network.release() }
        let cache = ArtifactCache(root: root, beforeCaptureCommit: { gate.pause() })
        let service = LibraryTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://capture-admission.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        try #require(await store.connect(configuration)); await store.refreshLibrary(); await store.open(service.profiles[0])
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        let producer = try #require(item.chat.messages.first { $0.id == item.artifact.messageID })
        let destination = try #require(store.artifactDestination(for: attachment, botID: service.first.profile.text, producingMessage: producer))
        defer { store.finishArtifact(destination) }
        let key = try #require(await WorkspaceLibrary.originalKey(identity: item.chat.identity, attachment: attachment,
            messages: item.chat.messages, producingMessage: producer))
        service.downloadBarrier = network; gate.arm()
        let presentation = WorkspacePresentation()
        let first: Task<DownloadedArtifact, Error>?
        let reader: ArtifactPreviewSession?
        if retirement == "close" {
            presentation.openArtifact(destination, store: store)
            let opened: ArtifactPreviewSession = try #require(presentation.artifact)
            reader = opened; first = nil
        } else {
            reader = nil; first = Task { try await store.downloadArtifact(destination) }
        }
        defer { first?.cancel(); if let reader { presentation.closeArtifact(id: reader.id) } }
        await network.waitUntilEntered()
        let registrations = store.library.indexingMetrics.galleryConsumersRegistered
        let peer: Task<DownloadedArtifact, Error>? = validPeer ? Task { try await store.library.download(item) } : nil
        defer { peer?.cancel() }
        var deadline = ContinuousClock.now + .seconds(5)
        while validPeer && store.library.indexingMetrics.galleryConsumersRegistered == registrations,
              ContinuousClock.now < deadline { await Task.yield() }
        try #require(!validPeer || store.library.indexingMetrics.galleryConsumersRegistered > registrations)
        network.release()
        deadline = .now + .seconds(5)
        while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.isEntered)
        if let reader {
            presentation.closeArtifact(id: reader.id)
            #expect(presentation.artifact == nil && !reader.isCurrent && reader.file == nil)
        } else if retirement == "connection" { store.showsConnection = true }
        else { first?.cancel() }
        gate.release()
        if let first { await #expect(throws: (any Error).self) { _ = try await first.value } }
        if let peer { #expect(try await peer.value.data == Data("main".utf8)) }
        #expect(service.downloadCount == 1)
        let liveScope = ArtifactCacheScope(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(), provider: nil)
        // This queued SQL read observes the held transaction after it settles.
        #expect(try await cache.session(scope: liveScope).original(for: key)?.artifact.data == (validPeer ? Data("main".utf8) : nil))
        if let reader { #expect(!reader.isCurrent && reader.file == nil) }
        store.library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let scope = ArtifactCacheScope(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(), provider: nil)
        let reopened = reopenedCache.session(scope: scope)
        #expect(try await reopened.original(for: key)?.artifact.data == (validPeer ? Data("main".utf8) : nil))
        await reopenedCache.close()
    }

    @Observable final class SearchLeadingGrowth {
        var height: CGFloat = 40
    }

    @Test func aChatLedOriginalCanHandOffToAValidGalleryReaderAfterNavigation() async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let library = store.library
        let item = try #require(library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        let message = try #require(item.chat.messages.first { $0.id == item.artifact.messageID })
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        defer { store.finishArtifact(destination) }
        let key = ArtifactOriginalKey(identity: item.chat.identity, messageID: Data(message.id.utf8),
            path: Data(attachment.path.utf8), sourceRevision: try #require(item.chat.sourceRevisions[Data(message.id.utf8)]))
        let barrier = StoreTestBarrier(); service.downloadBarrier = barrier
        let inChat = Task { try await store.downloadArtifact(destination) }
        await barrier.waitUntilEntered()
        var joined = false
        let peer = Task {
            try await library.original(for: key, validateNetwork: {
                guard library.isCurrent(item) else { throw HermesServiceError.staleConversation }
                joined = true
            }, download: { try await service.downloadArtifact(attachment, in: item.chat.identity) })
        }
        let gallery = Task { try await library.download(item) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !joined, ContinuousClock.now < deadline { await Task.yield() }
        try #require(joined)
        await store.open(service.profiles[1])
        #expect(!store.isCurrentArtifactDestination(destination))
        #expect(library.isCurrent(item))
        service.downloadBarrier = nil; barrier.release()
        await #expect(throws: (any Error).self) { _ = try await inChat.value }
        #expect(try await peer.value.data == Data("main".utf8))
        #expect(try await gallery.value.data == Data("main".utf8))
        #expect(store.selectedBotID == service.second.profile.text)
        #expect(store.chats.screen(profile: service.second.profile)?.canAct == true)
        #expect(service.downloadCount == 2, "Only the retired first transport should require a replacement read")
        #expect(try await library.download(item).data == Data("main".utf8))
        #expect(service.downloadCount == 2)
    }

    @Test(arguments: [false, true])
    func aShorterAcceptedRevisionRemovesItsDeletedOutputAndSearchText(timestampChanges: Bool) async throws {
        let service = LibraryTestService()
        let message = ChatMessage(id: "main:row:7", role: .assistant, text: "Report ready\nMEDIA:/report.txt", timestamp: Date(timeIntervalSince1970: 100))
        service.messages[service.first] = [message]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let library = store.library, item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let reader = LibraryArtifactPreviewSession(item: item, library: library)
        defer { reader.finish() }
        reader.retry()
        var deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(reader.file != nil)
        let parsed = library.indexingMetrics.parsedMessages
        library.accept(identity: service.first, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [.init(id: message.id, role: .assistant, text: "Report ready", timestamp: timestampChanges ? nil : message.timestamp)]), title: "Main", evidence: .read(startedAt: .now, observedSource: service.first))
        deadline = ContinuousClock.now + .seconds(5)
        while library.indexingMetrics.parsedMessages == parsed, ContinuousClock.now < deadline { await Task.yield() }
        try #require(library.indexingMetrics.parsedMessages > parsed)
        let current = try #require(library.chats.first { $0.identity == service.first })
        #expect(current.messages.first?.text == "Report ready")
        #expect(library.artifacts.allSatisfy { $0.chat.identity != service.first })
        #expect(!library.isCurrent(item) && !reader.isCurrent && reader.file == nil)
        let results = LibrarySearchResults(query: "report.txt", bots: [], chats: [current], artifacts: library.artifacts)
        #expect(results.messages.isEmpty && results.artifacts.allSatisfy { $0.chat.identity != service.first })
        #expect(library.artifacts.contains { $0.chat.identity == service.second }, "An edit must preserve another chat’s outputs")
    }

    @Test(arguments: [false, true])
    func offlineRefreshCannotReseedAnOutputRemovedByACompleteRead(deletesWholeMessage: Bool) async throws {
        let service = LibraryTestService()
        let old = ChatMessage(id: "report", role: .assistant, text: "Report ready with deleted appendix\nMEDIA:/deleted.txt")
        service.messages[service.first] = [old]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: store.library.chats, artifacts: []).messages.count == 1)
        #expect(try await store.library.download(item).data == Data("main".utf8))
        service.messages[service.first] = deletesWholeMessage ? [] : [.init(id: old.id, role: .assistant, text: "Report ready")]
        await store.refreshLibrary(force: true)
        #expect(!store.library.isCurrent(item))
        service.onEvent?(.disconnected("Offline reseed fixture"))
        let reads = service.historyOffsets.count
        await store.refreshLibrary()
        let current = try #require(store.library.chats.first { $0.identity == service.first })
        #expect(current.messages.first?.text == (deletesWholeMessage ? nil : "Report ready"))
        #expect(store.library.artifacts.allSatisfy { $0.chat.identity != service.first })
        #expect(!store.library.isCurrent(item))
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: [current], artifacts: []).messages.isEmpty)
        #expect(service.historyOffsets.count == reads)
    }

    @Test(arguments: [false, true])
    func conflictingSavedRevisionsCannotRestoreADeletedOutputOffline(cacheHasOldSuffix: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService()
        service.versionedSummaries = true
        let old = ChatMessage(id: "report", role: .assistant, text: "Report ready with deleted appendix\nMEDIA:/deleted.txt", timestamp: Date(timeIntervalSince1970: 100))
        let edited = ChatMessage(id: old.id, role: .assistant, text: "Report ready", timestamp: old.timestamp)
        let retained = ChatMessage(id: "other", role: .assistant, text: "MEDIA:/retained.txt", timestamp: Date(timeIntervalSince1970: 200))
        service.messages[service.first] = [old, retained]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let original = WorkspaceLibrary(service: service, cache: session)
        original.setOnline(true); await original.refresh(evidence: .observed, bots: service.profiles)
        let deleted = try #require(original.artifacts.first { $0.artifact.title == "deleted.txt" })
        let kept = try #require(original.artifacts.first { $0.artifact.title == "retained.txt" })
        let oldKey = ArtifactOriginalKey(identity: service.first, messageID: Data(old.id.utf8), path: Data("/deleted.txt".utf8),
            sourceRevision: try #require(deleted.chat.sourceRevisions[Data(old.id.utf8)]))
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: original.chats, artifacts: []).messages.count == 1)
        #expect(try await original.download(deleted).data == Data("main".utf8))
        #expect(try await original.download(kept).data == Data("main".utf8))
        original.retire()
        let fixture = cache.session(scope: scope)
        let summary = SessionSummary(identity: service.first, title: "Main", isCanonical: true, persistence: .durable,
            updatedAt: Date(timeIntervalSince1970: 1_000), messageCount: 2)
        try await fixture.upsert(.init(identity: service.first, botName: "Helper", title: "Main",
            messages: [cacheHasOldSuffix ? old : edited, retained], updatedAt: summary.updatedAt,
            coverage: .complete, summary: summary, headFingerprint: nil))
        var book = ConversationBook()
        let id = book.merge(summary)
        book.cache(.init(id: "main", storedID: "main", profileID: "helper",
            messages: [cacheHasOldSuffix ? edited : old, retained]), for: id)
        let library = WorkspaceLibrary(service: service, cache: fixture)
        library.seed(book: book, bots: service.profiles); await library.restore()
        let reads = service.historyOffsets.count, downloads = service.downloadCount
        #expect(try await fixture.original(for: oldKey)?.artifact.data == Data("main".utf8))
        #expect(!library.artifacts.contains { $0.artifact.title == "deleted.txt" })
        #expect(library.artifacts.contains { $0.artifact.title == "retained.txt" })
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: library.chats, artifacts: library.artifacts).messages.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while try await fixture.loadChats().first(where: { $0.identity == service.first })?.messages.contains(where: { $0.id == old.id }) == true,
              ContinuousClock.now < deadline { await Task.yield() }
        try #require(try await fixture.loadChats().first { $0.identity == service.first }?.messages.contains { $0.id == old.id } == false)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        reopened.seed(book: book, bots: service.profiles); await reopened.restore()
        #expect(!reopened.artifacts.contains { $0.artifact.title == "deleted.txt" })
        #expect(reopened.artifacts.contains { $0.artifact.title == "retained.txt" })
        let offline = try #require(reopened.artifacts.first { $0.artifact.title == "retained.txt" })
        #expect(try await reopened.download(offline).data == Data("main".utf8))
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        #expect(service.historyOffsets.count == reads && service.downloadCount == downloads)
        service.failHistory = true
        reopened.setOnline(true); await reopened.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyOffsets.count > reads, "The current directory cannot resolve a disputed message")
        reopened.setOnline(false)
        reopened.seed(book: book, bots: service.profiles)
        await reopened.refresh(evidence: .observed, bots: service.profiles)
        #expect(reopened.chats.first { $0.identity == service.first }?.messages.allSatisfy { $0.id != old.id } == true)
        #expect(!reopened.artifacts.contains { $0.artifact.title == "deleted.txt" })
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        reopened.retire(); await reopenedCache.close()
        let recoveredCache = ArtifactCache(root: root)
        let recovered = WorkspaceLibrary(service: service, cache: recoveredCache.session(scope: scope))
        recovered.seed(book: book, bots: service.profiles); await recovered.restore()
        #expect(recovered.chats.first { $0.identity == service.first }?.messages.allSatisfy { $0.id != old.id } == true)
        #expect(!recovered.artifacts.contains { $0.artifact.title == "deleted.txt" })
        let retainedAfterFailure = try #require(recovered.artifacts.first { $0.artifact.title == "retained.txt" })
        let downloadsBeforeRecovery = service.downloadCount
        #expect(try await recovered.download(retainedAfterFailure).data == Data("main".utf8))
        #expect(service.downloadCount == downloadsBeforeRecovery)
        service.failHistory = false
        service.messages[service.first] = [edited, retained]
        let readsBeforeRecovery = service.historyOffsets.count
        recovered.setOnline(true); await recovered.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyOffsets.count > readsBeforeRecovery, "Conflicting local copies cannot certify a complete current index")
        #expect(recovered.chats.first { $0.identity == service.first }?.messages.first?.text == "Report ready")
        #expect(!recovered.artifacts.contains { $0.artifact.title == "deleted.txt" })
        recovered.retire(); await recoveredCache.close()
    }

    @Test(arguments: ["user", "assistant", "code"])
    func exactSearchFocusRevealsTheActualGlyphInsideAnOlderTallMessage(kind: String) async throws {
        let service = LibraryTestService()
        let query = "Native needle checkpoint"
        let prefix = (0..<75).map { "Ordinary native line \($0)" }.joined(separator: "\n")
        let body = kind == "code" ? "```swift\n" + prefix + "\n" + String(repeating: " ", count: 140) + query + "\n```" : String(repeating: "The older project discussion continues with practical details. ", count: 90) + query
        let target = ChatMessage(id: "main:row:1000", role: kind == "user" ? .user : .assistant, text: body)
        service.messages[service.first] = (0..<18).map {
            ChatMessage(id: "main:row:\(10_000 + $0)", role: .assistant, text: "Earlier reply \($0)")
        } + [target] + (0..<220).map {
            ChatMessage(id: "main:row:\($0)", role: .assistant, text: "Later reply \($0)")
        }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.refreshLibrary()
        let chat = try #require(store.library.chats.first { $0.identity == service.first })
        guard case .opened(let focus) = await store.openSearchMessage(.init(chat: chat, message: target, query: query)) else {
            Issue.record("Expected exact older message focus"); return
        }
        let snapshot = try #require(store.chats.selection(profile: service.first.profile)?.snapshot)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let controller = NativeTranscriptController(), window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { controller.retire(); window.isHidden = true; previous?.makeKeyAndVisible() }
        let context = NativeTranscriptContext(workspace: ObjectIdentifier(store.chats), profile: focus.identity.profile.bytes,
            chat: focus.owner.chat, owner: focus.owner, generation: UUID(), reviewingConnection: false)
        let growth = SearchLeadingGrowth()
        var rows = snapshot.messages.map { message in
            NativeTranscriptRow(id: .message(Data(message.id.utf8)), value: .message(message, working: false)) { _, _ in
                AnyView(VStack(spacing: 0) {
                    if message.id == target.id { Color.clear.frame(height: growth.height) }
                    MessageView(message: message).padding(.horizontal, 12)
                })
            }
        }
        rows.append(.init(id: .terminal, value: .auxiliary("terminal")) { _, _ in AnyView(Color.clear.frame(height: 1)) })
        var revealed = false
        controller.apply(context, snapshot: snapshot, rows: rows, active: true, currentTaskSnapshot: { snapshot },
            searchFocus: focus, reportSearchFocus: { id, result in
                if id == focus.id, case .revealed = result { revealed = true }
            })
        controller.view.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(12)
        while !revealed, ContinuousClock.now < deadline { await Task.yield() }
        try #require(revealed, "The native glyph range must be visible before Search acknowledges success")
        let cell = try #require(controller.collection.cellForItem(at: IndexPath(item: 18, section: 0)) as? NativeTranscriptCell)
        let hit = try #require(cell.exposure?.firstSearchMarker(id: focus.id))
        let rect = hit.marker.convert(hit.marker.bounds, to: window)
        let visible = rect.intersection(controller.collection.convert(controller.collection.bounds, to: window))
        #expect(!visible.isNull && visible.height > 0 && visible.width > 0)
        #expect(hit.marker.convert(hit.marker.bounds, to: cell).minY > 1000)
        #expect(controller.collection.cellForItem(at: IndexPath(item: snapshot.messages.count, section: 0)) == nil)
        #expect(!controller.followsLatest)
        let originalHeight = cell.bounds.height
        growth.height = 400
        let growthDeadline = ContinuousClock.now + .seconds(8)
        while (cell.bounds.height < originalHeight + 300 || abs(hit.marker.convert(hit.marker.bounds, to: window).minY - rect.minY) > 1),
              ContinuousClock.now < growthDeadline { await Task.yield() }
        #expect(cell.bounds.height > originalHeight + 300, "The preceding native block must actually grow")
        #expect(abs(hit.marker.convert(hit.marker.bounds, to: window).minY - rect.minY) < 1,
            "A delayed rich-block measurement must preserve the revealed glyph landmark")
        let latest = try #require(controller.view.subviews.compactMap { $0 as? UIButton }.first)
        #expect(!latest.isHidden)
        latest.sendActions(for: .touchUpInside)
        #expect(controller.followsLatest)
        print("BOTTO_SEARCH_NATIVE_GLYPH kind=\(kind) rect=\(rect)")
        let replacement = SearchMessageFocus(workspace: focus.workspace, owner: focus.owner,
            identity: focus.identity, message: focus.message, query: focus.query)
        var edited = snapshot
        edited.messages[18] = .init(id: target.id, role: target.role, text: "The occurrence changed during positioning")
        var unavailable = false
        controller.apply(context, snapshot: edited, rows: rows, active: true, currentTaskSnapshot: { edited },
            searchFocus: replacement, reportSearchFocus: { id, result in
                if id == replacement.id, case .unavailable = result { unavailable = true }
            })
        let editDeadline = ContinuousClock.now + .seconds(5)
        while !unavailable, ContinuousClock.now < editDeadline { await Task.yield() }
        #expect(unavailable, "A stale render receipt cannot acknowledge a changed same-ID message")
    }

    @Test(arguments: ["unchanged", "edited", "missing", "removed-query", "duplicate", "hidden"])
    func messageSearchValidatesTheOccurrenceBeforeChangingSelection(change: String) async throws {
        let service = LibraryTestService(secondBot: true)
        let expected = ChatMessage(id: "main:row:1000", role: .assistant, text: "Saved **Needle** summary")
        service.messages[service.first] = [expected] + (0..<240).map {
            ChatMessage(id: "main:row:\($0)", role: .assistant, text: "Later reply \($0)")
        }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[1]); await store.refreshLibrary()
        let prior = try #require(store.chats.screen(profile: service.second.profile))
        store.chats.editDraft("Keep this draft", owner: prior.owner)
        let chat = try #require(store.library.chats.first { $0.identity == service.first })
        switch change {
        case "edited": service.messages[service.first]?[0] = .init(id: expected.id, role: .assistant, text: "Current Needle summary")
        case "missing": service.messages[service.first]?.removeFirst()
        case "removed-query": service.messages[service.first]?[0] = .init(id: expected.id, role: .assistant, text: "A replacement summary")
        case "duplicate": service.messages[service.first]?.append(expected)
        case "hidden": service.messages[service.first]?[0] = .init(id: expected.id, role: .assistant, text: expected.text, isSilent: true)
        default: break
        }
        let result = await store.openSearchMessage(.init(chat: chat, message: expected, query: "needle"))
        if change == "unchanged" || change == "edited" {
            guard case .opened(let focus) = result else { Issue.record("Expected exact older occurrence"); return }
            #expect(focus.identity == service.first)
            #expect(focus.message.id == expected.id)
            #expect(focus.message.text == (change == "edited" ? "Current Needle summary" : expected.text))
            #expect(focus.matches(workspace: store.chats))
            #expect(store.selectedBotID == service.first.profile.text)
            #expect(store.chats.screen(profile: service.first.profile)?.canAct == true)
        } else {
            guard case .unavailable = result else { Issue.record("A missing or ambiguous match must fail honestly"); return }
            #expect(store.selectedBotID == service.second.profile.text)
            #expect(store.chats.selection(profile: service.second.profile)?.identity == service.second)
            #expect(store.chats.screen(profile: service.second.profile)?.canAct == true)
        }
        #expect(store.chats.persisted().record(prior.owner.chat)?.draft.text == "Keep this draft")
    }

    @Test(arguments: [false, true])
    func cancelledOriginalReadCannotAdmitLateBytesButKeepsAValidPeer(validPeer: Bool) async throws {
        let service = LibraryTestService(), cache = ArtifactCache(root: nil)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        let library = store.library
        let key = ArtifactOriginalKey(identity: service.first, messageID: Data("row".utf8),
            path: Data("/late.txt".utf8), sourceRevision: Data("revision".utf8))
        let gate = StoreTestBarrier()
        var downloads = 0, transportCancelled = false
        let older = Task {
            try await library.original(for: key, download: {
                downloads += 1
                await gate.wait()
                transportCancelled = Task.isCancelled
                return DownloadedArtifact(data: Data("late".utf8), filename: "late.txt", mimeType: "text/plain")
            })
        }
        await gate.waitUntilEntered()
        var joined = false
        let peer: Task<DownloadedArtifact, Error>? = validPeer ? Task {
            try await library.original(for: key, validateNetwork: { joined = true }, download: {
                Issue.record("A valid peer must share the existing flight")
                throw HermesServiceError.disconnected
            })
        } : nil
        if validPeer {
            let deadline = ContinuousClock.now + .seconds(5)
            while !joined, ContinuousClock.now < deadline { await Task.yield() }
            try #require(joined)
        }
        older.cancel()
        // Release immediately: cancellation admission must fence even a response
        // that races the MainActor's scheduled waiter cleanup.
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await older.value }
        if let peer { #expect(try await peer.value.data == Data("late".utf8)) }
        #expect(downloads == 1)
        let subsequent = try await library.original(for: key, download: {
            downloads += 1
            return DownloadedArtifact(data: Data("fresh".utf8), filename: "late.txt", mimeType: "text/plain")
        })
        #expect(subsequent.data == Data((validPeer ? "late" : "fresh").utf8))
        #expect(downloads == (validPeer ? 1 : 2))
        if validPeer { #expect(!transportCancelled) }
    }

    @Test func cancelledMessageOpeningCannotOverrideANewerSearchMatch() async throws {
        let service = LibraryTestService(secondBot: true)
        let message = ChatMessage(id: "side:row:10", role: .assistant, text: "Exact Needle reply")
        service.messages[service.second] = [message]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let prior = try #require(store.chats.screen(profile: service.first.profile))
        store.chats.editDraft("Keep the original draft", owner: prior.owner)
        let chat = try #require(store.library.chats.first { $0.identity == service.second })
        let target = SearchMessageTarget(chat: chat, message: message, query: "needle")
        let attachment = StoreTestBarrier(); service.gatedSource = service.second; service.openingBarrier = attachment
        let older = Task { await store.openSearchMessage(target) }
        await attachment.waitUntilEntered(); older.cancel(); service.openingBarrier = nil
        let directory = StoreTestBarrier(); service.directoryBarrier = directory
        let newer = Task { await store.openSearchMessage(target) }
        await directory.waitUntilEntered(); attachment.release()
        guard case .superseded = await older.value else { Issue.record("Cancelled opening must retire"); directory.release(); return }
        directory.release()
        guard case .opened(let focus) = await newer.value else { Issue.record("Newer exact lookup must survive old cleanup"); return }
        #expect(focus.identity == service.second && focus.message.id == message.id)
        #expect(focus.matches(workspace: store.chats))
        #expect(store.selectedBotID == service.second.profile.text)
        #expect(store.chats.persisted().record(prior.owner.chat)?.draft.text == "Keep the original draft")
    }

    @Test func messageSearchDoesNotConfuseProjectedContentWithOccurrenceIdentity() async throws {
        let service = LibraryTestService()
        let projected = ChatMessage(id: "main:row:1", role: .assistant, text: "Visible Needle projection")
        service.messages[service.first] = [projected]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.refreshLibrary()
        let chat = try #require(store.library.chats.first { $0.identity == service.first })
        service.messages[service.first] = [.init(id: projected.id, role: .assistant, text: "Raw Needle presentation")]
        guard case .opened(let focus) = await store.openSearchMessage(.init(chat: chat, message: projected, query: "needle")) else {
            Issue.record("The stable occurrence has a supported visible match"); return
        }
        #expect(focus.message.text == "Raw Needle presentation")
        let presentation = WorkspacePresentation()
        presentation.didChooseConversation(focusing: focus)
        presentation.selectedBotChanged(store: store)
        #expect(presentation.searchFocus?.id == focus.id, "Selection observation must preserve an already committed exact-message intent")
        presentation.reportSearchFocus(focus.id, result: .revealed)
        #expect(presentation.searchFocus?.needsReveal == false)
        #expect(!TranscriptContentRevision.sameMessage(focus.message, projected))
        #expect(SearchMessageTarget(chat: chat, message: projected, query: "projection")
            .resolve(identity: service.first, snapshot: store.chats.selection(profile: service.first.profile)?.snapshot) == nil)
        let wrong = SessionIdentity(profile: service.first.profile, root: service.first.root,
                                    stored: try ExactID("successor"), aliases: [])
        #expect(SearchMessageTarget(chat: chat, message: projected, query: "needle")
            .resolve(identity: wrong, snapshot: store.chats.selection(profile: service.first.profile)?.snapshot) == nil)
    }

    @Test func authenticationPinCallbackUsesTheNamespaceReopenedOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), vault = MemoryConnectionStorage()
        service.pinOnConnect = "authenticated-installation"
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        vault.saved = configuration
        let cache = ArtifactCache(root: root)
        let store = AppStore(service: service, persistence: vault.persistence, artifactCache: cache)
        let unpinnedLibrary = store.library
        #expect(await store.connect(configuration))
        #expect(store.configuration?.installID == "authenticated-installation")
        #expect(store.library !== unpinnedLibrary)
        await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        #expect(try await store.library.download(item).data == Data("main".utf8))
        let downloads = service.downloadCount, histories = service.historyOffsets.count
        let reopenedCache = ArtifactCache(root: root)
        let reopened = AppStore(service: service, persistence: vault.persistence, artifactCache: reopenedCache)
        await reopened.library.restore()
        let restored = reopened.library.artifacts.first { $0.chat.identity == service.first }
        #expect(restored != nil)
        if let restored { #expect(try await reopened.library.download(restored).data == Data("main".utf8)) }
        #expect(service.downloadCount == downloads && service.historyOffsets.count == histories)
        reopened.forgetConnection(); try await reopenedCache.drainMaintenance()
        store.forgetConnection(); try await cache.drainMaintenance()
        await cache.close(); await reopenedCache.close()
        LocalHistory.remove(for: configuration.id)
    }

    @Test(arguments: [false, true])
    func retiredGalleryReadsNeedAValidPeerBeforeRetainingBytes(validHistoricalPeer: Bool) async throws {
        let service = LibraryTestService(), cache = ArtifactCache(root: nil)
        let message = try #require(service.messages[service.first]?.first)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0]); await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        let revision = try #require(item.chat.sourceRevisions[Data(message.id.utf8)])
        let key = ArtifactOriginalKey(identity: service.first, messageID: Data(message.id.utf8), path: Data(attachment.path.utf8), sourceRevision: revision)
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        let gate = StoreTestBarrier(); service.downloadBarrier = gate
        let gallery = Task { try await store.library.download(item) }
        await gate.waitUntilEntered()
        var joined = false
        let peer: Task<DownloadedArtifact, Error>? = validHistoricalPeer ? Task {
            try await store.library.original(for: key, validateNetwork: {
                guard store.isCurrentArtifactDestination(destination) else { throw HermesServiceError.staleConversation }
                joined = true
            }, download: { throw HermesServiceError.rejected(-32601) })
        } : nil
        if validHistoricalPeer {
            let deadline = ContinuousClock.now + .seconds(5)
            while !joined, ContinuousClock.now < deadline { await Task.yield() }
            #expect(joined)
        }
        let newer = ChatMessage(id: "newer", role: .assistant, text: "MEDIA:/report.txt")
        store.library.accept(identity: service.first, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [message, newer]), title: "Main", evidence: .read(startedAt: .now, observedSource: service.first))
        let deadline = ContinuousClock.now + .seconds(5)
        while store.library.artifacts.first(where: { $0.chat.identity == service.first })?.artifact.messageID != "newer", ContinuousClock.now < deadline { await Task.yield() }
        service.fileBytes = Data("late mutable bytes".utf8)
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await gallery.value }
        if let peer { #expect(try await peer.value.data == Data("late mutable bytes".utf8)) }
        let session = cache.session(scope: .init(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(configuration.username.utf8), provider: nil))
        let retained = try await session.original(for: key)
        #expect((retained != nil) == validHistoricalPeer)
        service.onEvent?(.disconnected("Gallery retirement fixture"))
        if validHistoricalPeer { #expect(try await store.downloadArtifact(destination).data == Data("late mutable bytes".utf8)) }
        else { await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination) } }
        #expect(service.downloadCount == 1)
        store.finishArtifact(destination)
    }

    @Test func anOfflineMissCanRetryUsingFreshSelectedAccess() async throws {
        let service = LibraryTestService()
        let message = try #require(service.messages[service.first]?.first)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        service.onEvent?(.disconnected("Uncached file fixture"))
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt", mimeType: "text/plain")
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        let presentation = WorkspacePresentation()
        presentation.openArtifact(destination, store: store)
        let reader = try #require(presentation.artifact)
        var deadline = ContinuousClock.now + .seconds(5)
        while reader.errorMessage == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(reader.file == nil && reader.errorMessage != nil && service.downloadCount == 0)
        #expect(await store.connect(configuration))
        reader.retry()
        deadline = .now + .seconds(5)
        while reader.file == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(reader.file?.data == Data("main".utf8))
        #expect(service.downloadCount == 1)
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination, force: true) }
        presentation.closeArtifact(id: reader.id)
    }

    @Test func historicalCardsKeepTheirOwnSamePathCaptureOffline() async throws {
        let service = LibraryTestService()
        let first = ChatMessage(id: "first", role: .assistant, text: "MEDIA:/report.txt")
        let second = ChatMessage(id: "second", role: .assistant, text: "MEDIA:/report.txt")
        service.messages[service.first] = [first, second]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt", mimeType: "text/plain")
        service.fileBytes = Data("first capture".utf8)
        let a = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: first))
        #expect(try await store.downloadArtifact(a).data == Data("first capture".utf8))
        store.finishArtifact(a)
        service.fileBytes = Data("second capture".utf8)
        let b = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: second))
        #expect(try await store.downloadArtifact(b).data == Data("second capture".utf8))
        store.finishArtifact(b)
        service.onEvent?(.disconnected("Historical file fixture"))
        for (message, expected) in [(first, "first capture"), (second, "second capture")] {
            let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
            #expect(try await store.downloadArtifact(destination).data == Data(expected.utf8))
            store.finishArtifact(destination)
        }
        #expect(service.downloadCount == 2)
    }

    @Test func offlineTranscriptGestureOpensItsCapturedFile() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0]); await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        _ = try await store.library.download(item)
        service.onEvent?(.disconnected("Offline gesture fixture"))
        let owner = try #require(store.chats.screen(profile: service.first.profile)?.owner)
        let presentation = WorkspacePresentation()
        let captured = transcriptArtifactAction(store: store, workspace: store.chats,
            botID: "helper", owner: owner, admittedBy: { true },
            onOpen: { presentation.openArtifact($0, store: store) })
        let action = try #require(captured)
        action(attachment)
        let reader = try #require(presentation.artifact)
        let deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(reader.file?.data == Data("main".utf8))
        #expect(service.downloadCount == 1)
        presentation.closeArtifact(id: reader.id)
    }

    @Test func aRosterChangeDuringLocalRestoreCannotCertifyAnOlderRoster() async throws {
        let service = LibraryTestService(secondBot: true), seedGate = StoreTestBarrier(), historyGate = StoreTestBarrier()
        defer { seedGate.release(); historyGate.release() }
        let originalRoster = [service.profiles[0]]
        let library = WorkspaceLibrary(service: service, projector: { messages, tail in
            if messages.contains(where: { $0.id == "seed" }) { await seedGate.wait() }
            return await WorkspaceLibrary.project(messages, streamingMessage: tail)
        })
        defer { library.retire() }
        library.setOnline(true); library.observeBots(originalRoster, evidence: .observed)
        var book = ConversationBook()
        let id = book.merge(.init(identity: service.first, title: "Main", isCanonical: true, persistence: .durable))
        book.cache(.init(id: "main", storedID: "main", profileID: "helper",
            messages: [.init(id: "seed", role: .assistant, text: "MEDIA:/saved.txt")]), for: id)
        library.seed(book: book, bots: originalRoster)
        try #require(await seedGate.waitUntilEntered(timeout: .seconds(5)))
        let joined = library.indexingMetrics.refreshesJoinedRestoration
        let old = Task { await library.refresh(evidence: .observed, bots: originalRoster) }
        defer { old.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while library.indexingMetrics.refreshesJoinedRestoration == joined, ContinuousClock.now < deadline { await Task.yield() }
        try #require(library.indexingMetrics.refreshesJoinedRestoration > joined,
            "The old refresh must join the held restoration before the roster changes")
        library.observeBots(service.profiles, evidence: .observed)
        service.historyBarrier = historyGate
        seedGate.release(); try #require(await historyGate.waitUntilEntered(timeout: .seconds(5)))
        let current = Task { await library.refreshIfNeeded(evidence: .observed, bots: service.profiles) }
        defer { current.cancel() }
        service.historyBarrier = nil; historyGate.release()
        await old.value; await current.value
        #expect(library.chats.contains { $0.identity.profile == service.second.profile },
                "An old roster waiting on local restoration must not certify the new roster's revision.")
        #expect(service.directoryCount == 2, "The first scan after restoration uses the current two-profile roster.")
    }

    @Test func cachedHistoryStatusKeepsItsHeightDuringSeedingAndRevalidation() async throws {
        let service = LibraryTestService()
        service.hiddenFirstPage = true
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence,
                             artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary(); await store.refreshLibrary()
        let library = store.library
        let warning = try #require(library.warning)
        #expect(library.statusAction == .checkOlderHistory)
        func height() -> CGFloat {
            ImageRenderer(content: LibraryStatus(library: library, refresh: {})
                .frame(width: 350)).uiImage?.size.height ?? 0
        }
        let originalHeight = height(), originalCards = library.artifacts.map(\.id)
        #expect(originalHeight > 0)
        library.seed(book: store.chats.persisted(), bots: store.bots)
        #expect(library.warning == warning)
        #expect(library.statusAction == .checkOlderHistory)
        #expect(height() == originalHeight)
        await library.restore()
        library.invalidateRevalidation()
        let gate = StoreTestBarrier(); service.directoryBarrier = gate
        let reopening = Task { await store.refreshLibraryIfNeeded() }
        await gate.waitUntilEntered()
        #expect(library.warning == warning)
        #expect(library.statusAction == .checkOlderHistory)
        #expect(height() == originalHeight)
        #expect(library.artifacts.map(\.id) == originalCards)
        service.directoryBarrier = nil; gate.release(); await reopening.value
        #expect(library.warning == warning)
        #expect(height() == originalHeight)
    }

    @Test func automaticLibraryRevalidationRespectsAgeInvalidationAndReconnect() async throws {
        let service = LibraryTestService()
        var now = ContinuousClock.now
        let library = WorkspaceLibrary(service: service, now: { now })
        defer { library.retire() }
        library.setOnline(true); await library.refreshIfNeeded(evidence: .observed, bots: service.profiles)
        let directories = service.directoryCount
        service.summaryTitle = "Changed remotely"
        now = now.advanced(by: .seconds(59))
        await library.refreshIfNeeded(evidence: .observed, bots: service.profiles)
        #expect(service.directoryCount == directories)
        #expect(library.chats.contains { $0.title == "Research notes" })
        now = now.advanced(by: .seconds(1))
        await library.refreshIfNeeded(evidence: .observed, bots: service.profiles)
        #expect(service.directoryCount == directories + 1)
        #expect(library.chats.contains { $0.title == "Changed remotely" })
        library.invalidateRevalidation()
        await library.refreshIfNeeded(evidence: .observed, bots: service.profiles)
        #expect(service.directoryCount == directories + 2)
        library.setOnline(false); await library.refreshIfNeeded(evidence: .observed, bots: service.profiles)
        #expect(service.directoryCount == directories + 2)
        library.setOnline(true); await library.refreshIfNeeded(evidence: .observed, bots: service.profiles)
        #expect(service.directoryCount == directories + 3)
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(service.directoryCount == directories + 4, "An explicit refresh bypasses the freshness window.")
    }

    @Test func leavingALibraryTabDoesNotCancelItsMountedBackgroundRead() async throws {
        let service = LibraryTestService(), gate = StoreTestBarrier()
        let library = WorkspaceLibrary(service: service)
        defer { library.retire() }
        library.setOnline(true); service.historyBarrier = gate
        let browsing = Task { await library.refreshIfNeeded(evidence: .observed, bots: service.profiles) }
        await gate.waitUntilEntered()
        browsing.cancel(); service.historyBarrier = nil; gate.release()
        await browsing.value
        #expect(library.artifacts.count == 2)
        #expect(library.warning == nil)
        let reads = service.historyOffsets.count, directories = service.directoryCount
        await library.refreshIfNeeded(evidence: .observed, bots: service.profiles)
        #expect(service.historyOffsets.count == reads && service.directoryCount == directories)
    }

    @Test(arguments: [false, true])
    func invalidationDuringALibraryReadRunsACurrentFollowUp(replacingCaller: Bool) async throws {
        let service = LibraryTestService(), gate = StoreTestBarrier()
        let library = WorkspaceLibrary(service: service)
        defer { library.retire() }
        library.setOnline(true); service.historyBarrier = gate
        let browsing = Task { await library.refreshIfNeeded(evidence: .observed, bots: service.profiles) }
        await gate.waitUntilEntered()
        library.invalidateRevalidation()
        var replacement: Task<Void, Never>?
        if replacingCaller {
            browsing.cancel()
            replacement = Task { await library.refreshIfNeeded(evidence: .observed, bots: service.profiles) }
            for _ in 0..<20 { await Task.yield() }
        }
        service.historyBarrier = nil; gate.release(); await browsing.value
        await replacement?.value
        #expect(service.directoryCount == 2)
        let reads = service.historyOffsets.count
        await library.refreshIfNeeded(evidence: .observed, bots: service.profiles)
        #expect(service.directoryCount == 2 && service.historyOffsets.count == reads)
    }

    @Test func weakDirectoryMetadataDoesNotReorderTheCachedArtifactList() async throws {
        let service = LibraryTestService()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ArtifactCache(root: root)
        let session = cache.session(scope: .init(configurationID: UUID(), serverURL: Data(),
            installationID: nil, username: Data(), provider: nil))
        for (source, time) in [(service.first, 100.0), (service.second, 200.0)] {
            try await session.upsert(.init(identity: source, botName: "Helper", title: source.root.text,
                messages: service.messages[source]!, updatedAt: Date(timeIntervalSince1970: time),
                coverage: .complete, summary: nil, headFingerprint: nil))
        }
        let library = WorkspaceLibrary(service: service, cache: session)
        defer { library.retire() }
        await library.restore(); library.setOnline(true)
        let cached = library.artifacts.map(\.id)
        #expect(library.artifacts.first?.chat.identity == service.second)
        let gate = StoreTestBarrier(); service.historyBarrier = gate
        let refresh = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        await gate.waitUntilEntered()
        #expect(library.artifacts.map(\.id) == cached, "Missing directory dates must not erase known dates and reshuffle cards.")
        service.historyBarrier = nil; gate.release(); await refresh.value
        #expect(library.artifacts.map(\.id) == cached)
        await cache.close()
    }

    @Test func repeatedLibraryTabOpeningUsesTheCurrentListWithoutNetworkReads() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence,
                             artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibraryIfNeeded()
        let cached = store.library.artifacts
        let directories = service.directoryCount, histories = service.historyOffsets.count
        for _ in 0..<3 { await store.refreshLibraryIfNeeded() }
        print("BOTTO_LIBRARY_REOPEN directories=\(service.directoryCount - directories) histories=\(service.historyOffsets.count - histories) opens=3")
        #expect(service.directoryCount == directories)
        #expect(service.historyOffsets.count == histories)
        #expect(store.library.artifacts == cached)
    }

    @Test func repeatedBrowsingReusesHistoryAndOriginalFileBytes() async throws {
        let service = LibraryTestService()
        service.versionedSummaries = true
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let firstHistory = service.historyOffsets.count
        let directories = service.directoryCount
        await store.refreshLibrary()
        let repeatedHistory = service.historyOffsets.count - firstHistory
        let repeatedDirectories = service.directoryCount - directories
        let first = try await store.library.download(item)
        let second = try await store.library.download(item)
        #expect(first.data == Data("main".utf8))
        #expect(second.data == first.data)
        print("BOTTO_ARTIFACT_FETCH_COUNTS initial_history=\(firstHistory) repeated_history=\(repeatedHistory) repeated_directories=\(repeatedDirectories) file_opens=2 file_requests=\(service.downloadCount)")
        #expect(repeatedHistory == 0)
        #expect(service.downloadCount == 1)
        store.library.setOnline(false)
        do {
            let cached = try await store.library.download(item)
            #expect(cached.data == first.data)
        } catch {
            Issue.record("A downloaded original must remain readable offline: \(error)")
        }
    }

    @Test func simultaneousReadersShareAnOriginalWithoutSharingCancellation() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        await store.open(service.profiles[0])
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        let destination = try #require(store.artifactDestination(for: attachment, botID: service.first.profile.text))
        defer { store.finishArtifact(destination) }
        let barrier = StoreTestBarrier()
        service.downloadBarrier = barrier
        let first = Task { try await store.library.download(item) }
        await barrier.waitUntilEntered()
        let second = Task { try await store.downloadArtifact(destination) }
        let thumbnail = Task { await store.library.thumbnail(for: item) { _ in Data("thumbnail".utf8) } }
        for _ in 0..<20 { await Task.yield() }
        first.cancel()
        barrier.release()
        _ = try? await first.value
        #expect(try await second.value.data == Data("main".utf8))
        #expect(await thumbnail.value == Data("thumbnail".utf8))
        #expect(service.downloadCount == 1)
    }

    @Test func relaunchRestoresInlineSourceAndCapturedOriginalWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService()
        service.versionedSummaries = true
        service.messages[service.first]?.append(ChatMessage(id: "inline", role: .assistant,
            text: "```html\n<h1>Saved offline</h1>\n```"))
        let vault = MemoryConnectionStorage()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let firstCache = ArtifactCache(root: root), reopenedCache = ArtifactCache(root: root)
        let first = AppStore(service: service, persistence: vault.persistence, artifactCache: firstCache)
        #expect(await first.connect(configuration))
        await first.refreshLibrary()
        let file = try #require(first.library.artifacts.first { $0.chat.identity == service.first && $0.artifact.attachment != nil })
        #expect(try await first.library.download(file).data == Data("main".utf8))
        let histories = service.historyOffsets.count, downloads = service.downloadCount, directories = service.directoryCount
        let reopened = AppStore(service: service, persistence: vault.persistence, artifactCache: reopenedCache)
        await reopened.library.restore()
        let restored = try #require(reopened.library.artifacts.first { $0.chat.identity == service.first && $0.artifact.attachment != nil })
        #expect(try await reopened.library.download(restored).data == Data("main".utf8))
        let inline = try #require(reopened.library.artifacts.first { $0.artifact.block != nil })
        #expect(try await reopened.library.download(inline).data == Data("<h1>Saved offline</h1>\n".utf8))
        #expect(service.historyOffsets.count == histories)
        #expect(service.downloadCount == downloads)
        #expect(service.directoryCount == directories)
        #expect(reopened.chats.screen(profile: service.first.profile)?.canAct != true)
        reopened.forgetConnection()
        await firstCache.close(); await reopenedCache.close()
    }

    @Test func explicitRefreshChecksHistoryAndReloadCapturesChangedBytes() async throws {
        let service = LibraryTestService()
        service.versionedSummaries = true
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        #expect(try await store.library.download(item).data == Data("main".utf8))
        let history = service.historyOffsets.count
        await store.refreshLibrary(force: true)
        #expect(service.historyOffsets.count > history)
        service.fileBytes = Data("updated capture".utf8)
        #expect(try await store.library.download(item).data == Data("main".utf8))
        #expect(try await store.library.download(item, force: true).data == Data("updated capture".utf8))
        store.library.setOnline(false)
        #expect(try await store.library.download(item).data == Data("updated capture".utf8))
        #expect(service.downloadCount == 2)
    }

    @Test func acceptedOpenIndexesOutputsWithoutLibraryHistoryScan() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let deadline = ContinuousClock.now + .seconds(5)
        while store.library.artifacts.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(store.library.artifacts.first?.artifact.title == "report.txt")
        #expect(service.historyOffsets.isEmpty)
    }

    @Test func offlineChatPreviewSharesTheLibraryCaptureAndRejectsAnOldSemanticOwner() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        #expect(try await store.library.download(item).data == Data("main".utf8))
        service.onEvent?(.disconnected("Offline fixture"))
        let destination = try #require(store.artifactDestination(for: attachment, botID: service.first.profile.text))
        #expect(!store.isCurrentArtifactDestination(destination))
        #expect(store.isAuthorizedArtifactPresentation(destination))
        #expect(try await store.downloadArtifact(destination).data == Data("main".utf8))
        let presentation = WorkspacePresentation()
        presentation.openArtifact(destination, store: store)
        let reader = try #require(presentation.artifact)
        let deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(reader.file?.data == Data("main".utf8))
        #expect(reader.isCurrent)
        #expect(service.downloadCount == 1)
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination, force: true) }
        store.selectedBotID = nil
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination) }
        presentation.closeArtifact(id: reader.id)
        store.finishArtifact(destination)
    }

    @Test func failedSecureForgetPreservesCaptureAndSuccessfulForgetPurgesColdReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = MemoryConnectionStorage()
        var removalFails = true
        let persistence = ConnectionPersistence(load: { vault.saved }, save: { vault.saved = $0 }, remove: {
            if removalFails { throw HermesServiceError.disconnected }
            vault.saved = nil
        })
        let cache = ArtifactCache(root: root)
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: persistence, artifactCache: cache)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        let library = store.library
        let item = try #require(library.artifacts.first { $0.chat.identity == service.first })
        #expect(try await library.download(item).data == Data("main".utf8))
        store.forgetConnection()
        #expect(store.configuration?.id == configuration.id)
        #expect(store.library === library)
        #expect(!library.isRetired)
        library.setOnline(false)
        #expect(try await library.download(item).data == Data("main".utf8))
        removalFails = false
        store.forgetConnection()
        try await cache.drainMaintenance()
        vault.saved = configuration
        let reopenedCache = ArtifactCache(root: root)
        let reopened = AppStore(service: service, persistence: vault.persistence, artifactCache: reopenedCache)
        await reopened.library.restore()
        #expect(reopened.library.artifacts.isEmpty)
        #expect(library.isRetired)
        await cache.close(); await reopenedCache.close()
    }

    @Test func streamingSnapshotsCoalescePerChatAndSettleTheirLatestOutput() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        let older = (0..<500).map { ChatMessage(id: "old-\($0)", role: .assistant, text: "Earlier reply \($0)") }
        var hookDuration: Duration = .zero
        for number in 0..<1_000 {
            let source = number.isMultiple(of: 2) ? service.first : service.second
            let snapshot = Conversation(id: source.root.text, storedID: source.stored.text, profileID: source.profile.text,
                messages: older + [ChatMessage(id: "output", role: .assistant, text: "MEDIA:/draft-\(number).txt")], isWorking: true)
            let started = ContinuousClock.now
            library.accept(identity: source, snapshot: snapshot, title: source.root.text, evidence: .read(startedAt: .now, observedSource: source))
            hookDuration += started.duration(to: .now)
        }
        for source in [service.first, service.second] {
            library.accept(identity: source, snapshot: .init(id: source.root.text, storedID: source.stored.text,
                profileID: source.profile.text, messages: older + [ChatMessage(id: "output", role: .assistant,
                    text: "MEDIA:/settled-\(source.root.text).txt")]), title: source.root.text, evidence: .read(startedAt: .now, observedSource: source))
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while library.artifacts.count < 2 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(Set(library.artifacts.map(\.artifact.title)) == ["settled-main.txt", "settled-side.txt"])
        let metrics = library.indexingMetrics
        #expect(metrics.acceptedSnapshots == 1_002)
        #expect(metrics.batches < 10)
        print("BOTTO_ARTIFACT_STREAMING snapshots=\(metrics.acceptedSnapshots) batches=\(metrics.batches) parsed_messages=\(metrics.parsedMessages) hook_total=\(hookDuration) worker_total=\(metrics.processingDuration)")
        library.retire()
    }

    @Test func anUnchangedCompleteSinglePageDoesNotWarnAboutUncheckedOlderHistory() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        defer { library.retire() }
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.warning == nil)
    }

    @Test func weakSummaryUsesOneHeadProbeAndExplicitRefreshFindsAnOlderEdit() async throws {
        let service = LibraryTestService()
        service.hiddenFirstPage = true
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let initial = service.historyOffsets.count
        service.messages[service.first] = [ChatMessage(id: "main-file", role: .assistant, text: "MEDIA:/changed.txt")]
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyOffsets.count - initial == 2)
        #expect(library.artifacts.contains { $0.chat.identity == service.first && $0.artifact.title == "report.txt" })
        #expect(library.warning?.contains("haven’t been checked") == true)
        #expect(library.statusAction == .checkOlderHistory)
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.artifacts.contains { $0.chat.identity == service.first && $0.artifact.title == "changed.txt" })
        #expect(library.warning == nil)
        #expect(library.statusAction == nil)
    }

    @Test func unchangedHistoryUpdatesRenamedChatAndBotWithoutHistoryReads() async throws {
        let service = LibraryTestService()
        service.versionedSummaries = true
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let initial = service.historyOffsets.count
        service.summaryTitle = "Renamed notes"
        await library.refresh(evidence: .observed, bots: [BotProfile(id: "helper", name: "Renamed Helper")])
        #expect(service.historyOffsets.count == initial)
        #expect(library.chats.first { $0.identity == service.second }?.title == "Renamed notes")
        #expect(library.chats.allSatisfy { $0.botName == "Renamed Helper" })
    }

    @Test func explicitRefreshDuringAnOrdinaryScanRunsAForcedFollowUp() async throws {
        let service = LibraryTestService()
        service.versionedSummaries = true
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        let barrier = StoreTestBarrier()
        service.historyBarrier = barrier
        let ordinary = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        await barrier.waitUntilEntered()
        let forced = Task { await library.refresh(evidence: .observed, bots: service.profiles, force: true) }
        for _ in 0..<20 { await Task.yield() }
        service.historyBarrier = nil
        barrier.release()
        await ordinary.value
        await forced.value
        #expect(service.historyOffsets.count == 4)
        #expect(service.directoryCount == 2)
    }

    @Test(arguments: ["success", "failure", "cancel", "failure-recovery", "cancel-recovery"])
    func foregroundRestorationCannotOverrideANewerLibraryLookup(_ outcome: String) async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let workspace = store.chats
        let original = try #require(workspace.screen(profile: service.first.profile))
        let oldAccess = try #require(service.lastAccess)
        workspace.editDraft("kept through foreground lookup", owner: original.owner)
        let choice = workspace.persisted().preference(service.first.profile)?.lastSelected
        let target = try #require(store.library.chats.first { $0.identity == service.second })

        let refreshGate = StoreTestBarrier(), otherRefreshGate = StoreTestBarrier()
        service.directoryBarriers = [service.first.profile: refreshGate, service.second.profile: otherRefreshGate]
        let reconnecting = Task { await store.connect(configuration) }
        await refreshGate.waitUntilEntered()
        await otherRefreshGate.waitUntilEntered()
        otherRefreshGate.release()
        let lookupGate = StoreTestBarrier()
        service.directoryBarriers[service.second.profile] = lookupGate
        let newer = Task { await store.openLibraryChat(target) }
        await lookupGate.waitUntilEntered()
        let opens = service.openCount
        refreshGate.release()
        #expect(await reconnecting.value)
        #expect(service.openCount == opens, "Automatic restoration cannot clear a newer lookup's claim")
        #expect(workspace.persisted().preference(service.first.profile)?.lastSelected == choice)
        #expect(workspace.persisted().record(original.owner.chat)?.draft.text == "kept through foreground lookup")

        let recoveryFails = outcome.hasSuffix("-recovery")
        if recoveryFails { service.failingSource = service.first }
        if outcome.hasPrefix("failure") { service.failDirectory = true }
        if outcome.hasPrefix("cancel") { newer.cancel() }
        lookupGate.release()
        let opened = await newer.value
        #expect(opened == (outcome == "success"))
        let expected = outcome == "success" ? service.second : service.first
        #expect(store.selectedBotID == expected.profile.text)
        #expect(workspace.selection(profile: expected.profile)?.identity?.root == expected.root)
        let current = try #require(workspace.screen(profile: expected.profile))
        #expect(current.canAct == !recoveryFails)
        #expect(current.canEditDraft)
        if recoveryFails {
            #expect(workspace.captureSend(current.owner) == nil)
            #expect(throws: (any Error).self) { try service.source(for: oldAccess) }
        } else {
            #expect(try service.source(for: #require(service.lastAccess)).root == expected.root)
        }
        #expect(workspace.persisted().preference(service.first.profile)?.lastSelected == choice)
        #expect(workspace.persisted().record(original.owner.chat)?.draft.text == "kept through foreground lookup")
        workspace.editDraft("edited after lookup", owner: current.owner)
        #expect(workspace.draft(current.owner) == "edited after lookup")
    }

    @Test(arguments: [false, true])
    func olderCreationCannotOverrideANewerLibraryLookup(dispatched: Bool) async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let workspace = store.chats
        let original = try #require(workspace.screen(profile: service.first.profile))
        let choice = workspace.persisted().preference(service.first.profile)?.lastSelected
        let intent = try #require(workspace.captureCreation(original.owner))
        let creationGate = StoreTestBarrier()
        var creating: Task<Void, Never>?
        if dispatched {
            service.creationBarrier = creationGate
            creating = Task { await workspace.create(intent) }
            await creationGate.waitUntilEntered()
        }
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let directory = StoreTestBarrier()
        service.directoryBarrier = directory
        let newer = Task { await store.openLibraryChat(target) }
        await directory.waitUntilEntered()
        let opens = service.openCount
        if let creating { creationGate.release(); await creating.value }
        else { await workspace.create(intent) }
        #expect(service.creationCount == 1)
        #expect(service.openCount == opens)
        #expect(workspace.screen(profile: service.first.profile)?.owner.chat == original.owner.chat)
        #expect(workspace.persisted().preference(service.first.profile)?.lastSelected == choice)
        let receipt = try #require(service.createdIdentity)
        let retained = try #require(workspace.persisted().records.first {
            $0.binding.identity?.profile == receipt.profile && $0.binding.identity?.root == receipt.root
        })
        #expect(retained.binding.identity?.stored == receipt.stored)
        directory.release()

        #expect(await newer.value)
        #expect(store.selectedBotID == service.second.profile.text)
        #expect(workspace.screen(profile: service.second.profile)?.canAct == true)
    }

    @Test func olderAttentionLookupCannotOverrideANewerLibraryLookup() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let workspace = store.chats
        let original = try #require(workspace.screen(profile: service.first.profile))
        let attentionGate = StoreTestBarrier()
        service.directoryBarrier = attentionGate
        let intent = try #require(workspace.captureOpening(profile: service.first.profile, attention: true))
        let attention = Task { await workspace.open(intent) }
        await attentionGate.waitUntilEntered()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let directory = StoreTestBarrier()
        service.directoryBarrier = directory
        let newer = Task { await store.openLibraryChat(target) }
        await directory.waitUntilEntered()
        service.directoryActivity[service.second] = .known(.waiting, .distantFuture)
        let opens = service.openCount
        attentionGate.release(); await attention.value
        #expect(service.openCount == opens)
        #expect(workspace.screen(profile: service.first.profile)?.owner.chat == original.owner.chat)
        directory.release()

        #expect(await newer.value)
        #expect(workspace.selection(profile: service.second.profile)?.identity == service.second)
        #expect(workspace.screen(profile: service.second.profile)?.canAct == true)
    }

    @Test(arguments: [false, true], [false, true])
    func unsuccessfulAttachmentPreservesTheOriginalEditableChat(cancel: Bool, otherBot: Bool) async throws {
        let service = LibraryTestService(secondBot: otherBot)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let before = try #require(store.chats.screen(profile: service.first.profile))
        let oldAccess = try #require(service.lastAccess)
        store.chats.editDraft("Keep my original draft", owner: before.owner)
        let originalChoice = store.chats.persisted().preference(service.first.profile)?.lastSelected
        let targetChoice = store.chats.persisted().preference(service.second.profile)?.lastSelected
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let gate = StoreTestBarrier()
        service.openingBarrier = gate
        service.gatedSource = service.second
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        if cancel { opening.cancel() }
        else { service.failingSource = service.second }
        gate.release()

        #expect(!(await opening.value))

        let returned = try #require(store.chats.screen(profile: service.first.profile))
        #expect(store.selectedBotID == service.first.profile.text)
        #expect(returned.owner.chat == before.owner.chat)
        #expect(returned.canEditDraft)
        #expect(returned.canAct)
        #expect(store.chats.draft(returned.owner) == "Keep my original draft")
        #expect(store.chats.persisted().preference(service.first.profile)?.lastSelected == originalChoice)
        #expect(store.chats.persisted().preference(service.second.profile)?.lastSelected == targetChoice)
        let restoredAccess = try #require(service.lastAccess)
        #expect(restoredAccess != oldAccess)
        #expect(try service.source(for: restoredAccess) == service.first)
        #expect(throws: (any Error).self) { try service.source(for: oldAccess) }
    }

    @Test func cancelledAttachmentCannotRestoreOverANewerBotChoice() async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let gate = StoreTestBarrier()
        service.openingBarrier = gate; service.gatedSource = service.second
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        opening.cancel()
        service.openingBarrier = nil
        await store.open(service.profiles[1])
        let newerAccess = try #require(service.lastAccess)
        let opens = service.openCount
        gate.release()

        #expect(!(await opening.value))

        #expect(store.selectedBotID == service.second.profile.text)
        #expect(store.chats.screen(profile: service.second.profile)?.canAct == true)
        #expect(service.openCount == opens)
        #expect(service.lastAccess == newerAccess)
        #expect(try service.source(for: newerAccess) == service.second)
    }

    @Test(arguments: [false, true], [false, true])
    func newerLibraryLookupOwnsNavigationWhileCancelledAttachmentDrains(directoryFails: Bool, cancelNewer: Bool) async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let original = try #require(store.chats.screen(profile: service.first.profile))
        store.chats.editDraft("Keep my first chat", owner: original.owner)
        await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let attachment = StoreTestBarrier()
        service.openingBarrier = attachment; service.gatedSource = service.second
        let cancelled = Task { await store.openLibraryChat(target) }
        await attachment.waitUntilEntered()
        cancelled.cancel()
        service.openingBarrier = nil
        let directory = StoreTestBarrier()
        service.directoryBarrier = directory
        let newer = Task { await store.openLibraryChat(target) }
        await directory.waitUntilEntered()
        attachment.release()
        #expect(!(await cancelled.value))
        service.failDirectory = directoryFails
        if cancelNewer { newer.cancel() }
        directory.release()

        #expect(await newer.value == (!directoryFails && !cancelNewer))

        let expected = directoryFails || cancelNewer ? service.first : service.second
        #expect(store.selectedBotID == expected.profile.text)
        #expect(store.chats.screen(profile: expected.profile)?.canAct == true)
        #expect(try service.source(for: #require(service.lastAccess)) == expected)
        #expect(store.chats.persisted().record(original.owner.chat)?.draft.text == "Keep my first chat")
    }

    @Test(arguments: [false, true])
    func queuedNavigationCannotSupersedeANewerLibraryLookup(picker: Bool) async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let workspace = store.chats
        let queued: @MainActor () async -> Void
        if picker {
            let screen = try #require(workspace.screen(profile: service.first.profile))
            let intent = try #require(workspace.captureSelection(screen.owner.chat, owner: screen.owner))
            queued = { await workspace.select(intent) }
        } else {
            let intent = try #require(workspace.captureOpening(profile: service.first.profile))
            queued = { await workspace.open(intent) }
        }
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let directory = StoreTestBarrier()
        service.directoryBarrier = directory
        let newer = Task { await store.openLibraryChat(target) }
        await directory.waitUntilEntered()
        let opens = service.openCount
        await queued()
        #expect(service.openCount == opens)
        directory.release()

        #expect(await newer.value)

        #expect(store.selectedBotID == service.second.profile.text)
        #expect(workspace.screen(profile: service.second.profile)?.canAct == true)
    }

    @Test func retiredLibraryCannotCommitAnOtherwiseSuccessfulAttachment() async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let gate = StoreTestBarrier()
        service.openingBarrier = gate; service.gatedSource = service.second
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        store.library.retire()
        gate.release()

        #expect(!(await opening.value))

        #expect(store.selectedBotID == service.first.profile.text)
        #expect(store.chats.screen(profile: service.first.profile)?.canAct == true)
        #expect(try service.source(for: #require(service.lastAccess)) == service.first)
    }

    @Test func failedRestorationKeepsTheOriginalDraftEditableWithoutRevivingAccess() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let before = try #require(store.chats.screen(profile: service.first.profile))
        let oldAccess = try #require(service.lastAccess)
        store.chats.editDraft("Keep editing locally", owner: before.owner)
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let gate = StoreTestBarrier()
        service.openingBarrier = gate; service.gatedSource = service.second
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        service.failingSource = service.first
        opening.cancel(); gate.release()

        #expect(!(await opening.value))

        let returned = try #require(store.chats.screen(profile: service.first.profile))
        #expect(returned.owner.chat == before.owner.chat)
        #expect(returned.canEditDraft)
        #expect(!returned.canAct)
        #expect(returned.error != nil)
        #expect(store.chats.draft(returned.owner) == "Keep editing locally")
        #expect(throws: (any Error).self) { try service.source(for: oldAccess) }
    }

    @Test func cachedLibraryChatOpensOfflineWithItsDraftAndNoNewAttachment() async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let original = try #require(store.chats.screen(profile: service.first.profile))
        store.chats.editDraft("My saved offline draft", owner: original.owner)
        await store.refreshLibrary()
        let first = try #require(store.library.chats.first { $0.identity == service.first })
        let second = try #require(store.library.chats.first { $0.identity == service.second })
        #expect(await store.openLibraryChat(second))
        service.onEvent?(.disconnected("Offline"))
        let opens = service.openCount

        #expect(await store.openLibraryChat(first))

        let returned = try #require(store.chats.screen(profile: service.first.profile))
        #expect(store.selectedBotID == service.first.profile.text)
        #expect(returned.owner.chat == original.owner.chat)
        #expect(returned.canEditDraft && !returned.canAct)
        #expect(store.chats.draft(returned.owner) == "My saved offline draft")
        #expect(service.openCount == opens)
    }

    @Test func failedDirectoryCannotReportThePreviouslySelectedChatAsOpened() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.first })
        let opens = service.openCount
        service.failDirectory = true

        #expect(!(await store.openLibraryChat(target)))
        #expect(service.openCount == opens)
    }

    @Test func cancelledDirectoryOpenDoesNotSelectItsBot() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let gate = StoreTestBarrier()
        service.directoryBarrier = gate
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        opening.cancel()
        gate.release()
        #expect(!(await opening.value))
        #expect(store.selectedBotID == nil)
    }

    @Test func libraryReaderRetainsOriginalBytesOfflineAndRevokesOnRetirement() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first { $0.chat.identity == service.first })
        let session = LibraryArtifactPreviewSession(item: item, library: library)
        defer { session.finish() }
        session.retry()
        let deadline = ContinuousClock.now + .seconds(5)
        while session.file == nil && ContinuousClock.now < deadline { await Task.yield() }
        let original = try #require(session.file)
        #expect(original.data == Data("main".utf8))
        library.setOnline(false)
        session.beginOutput(.share)
        #expect(session.isCurrent)
        #expect(session.output?.file === original)
        library.retire()
        #expect(!session.isCurrent)
        #expect(session.file == nil)
        #expect(session.output == nil)
        #expect(original.data == Data("main".utf8))
    }

    @Test func searchLoadsOnlyNearbyArtifactCovers() async throws {
        let service = LibraryTestService()
        service.messages[service.first] = (0..<60).map {
            ChatMessage(id: "image-\($0)", role: .assistant, text: "MEDIA:/chart-\($0).png")
        }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: WorkspaceSearchView(store: store, library: store.library,
            query: .constant("chart"), onBot: { _ in }, onChat: { _ in }, onArtifact: { _ in }, onMessage: { _ in }))
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            store.forgetConnection(); LocalHistory.remove(for: configuration.id)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while service.downloadCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(service.downloadCount > 0)
        try await Task.sleep(for: .seconds(1))
        print("BOTTO_SEARCH_COVERS total=60 requested=\(service.downloadCount)")
        #expect(service.downloadCount < 24)
    }

    @Test func searchHighlightsEveryReadableMatchWithoutChangingUnicode() {
        let text = "👩🏽‍💻 Café and CAFE, with café again."
        let highlighted = SearchHighlightedText.attributed(text, query: "cafe")
        #expect(Data(String(highlighted.characters).utf8) == Data(text.utf8))
        let hits = highlighted.runs.filter { $0.backgroundColor != nil }.map {
            String(highlighted[$0.range].characters)
        }
        #expect(hits == ["Café", "CAFE", "café"])
        #expect(SearchHighlightedText.attributed(text, query: "").runs.allSatisfy { $0.backgroundColor == nil })
    }

    @Test func hiddenLinkTargetsDoNotCreateFalseSearchOverflow() async throws {
        let service = LibraryTestService()
        service.messages[service.first] = [ChatMessage(id: "hidden-target", role: .assistant,
            text: "[Read the guide](https://example.test/needle)")] + (0..<50).map {
                ChatMessage(id: "visible-\($0)", role: .assistant, text: "Needle result \($0)")
            }
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let results = LibrarySearchResults(query: "needle", bots: service.profiles,
            chats: library.chats, artifacts: library.artifacts)
        #expect(results.messages.count == 50)
        #expect(!results.hasMoreMessages)
        library.retire()
    }

    @Test func searchSnippetsUseReadableTextAndVisibleMatches() async throws {
        let service = LibraryTestService()
        service.messages[service.first] = [ChatMessage(id: "readable", role: .assistant,
            text: "A **Café** update with [notes](https://example.test/hidden-token).")]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let visible = LibrarySearchResults(query: "cafe", bots: service.profiles,
            chats: library.chats, artifacts: library.artifacts)
        #expect(visible.messages.first?.snippet == "A Café update with notes.")
        let hidden = LibrarySearchResults(query: "hidden-token", bots: service.profiles,
            chats: library.chats, artifacts: library.artifacts)
        #expect(hidden.messages.isEmpty)
        library.retire()
    }

    @Test func searchGroupsVisibleContentAndKeepsSiblingOrigins() async throws {
        let service = LibraryTestService()
        service.messages[service.second] = [
            ChatMessage(id: "hidden", role: .assistant, text: "Needle internal", displayKind: "hidden"),
            ChatMessage(id: "tool", role: .tool, text: "Needle diagnostic"),
            ChatMessage(id: "answer", role: .assistant, text: "Here is the Needle you asked for.\nMEDIA:/Needle.pdf")
        ]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let result = LibrarySearchResults(query: "needle", bots: service.profiles,
            chats: library.chats, artifacts: library.artifacts)
        #expect(result.messages.count == 1)
        #expect(result.messages.first?.message.id == "answer")
        #expect(result.messages.first?.chat.identity == service.second)
        #expect(result.artifacts.first?.artifact.title == "Needle.pdf")
        #expect(result.artifacts.first?.chat.identity == service.second)
        #expect(!result.hasMoreMessages)
        let empty = LibrarySearchResults(query: "missing", bots: service.profiles,
            chats: library.chats, artifacts: library.artifacts)
        #expect(empty.isEmpty)
    }

    @Test func indexingKeepsTheSelectedChatDraftAndUnreadState() async throws {
        let service = LibraryTestService()
        let storage = MemoryConnectionStorage()
        let store = AppStore(service: service, persistence: storage.persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let before = try #require(store.chats.screen(profile: service.first.profile))
        store.chats.editDraft("Keep this draft", owner: before.owner)
        let seen = store.chats.persisted().record(before.owner.chat)?.seen
        let openCount = service.openCount

        await store.refreshLibrary()

        #expect(store.chats.screen(profile: service.first.profile)?.owner == before.owner)
        #expect(store.chats.draft(before.owner) == "Keep this draft")
        #expect(store.chats.persisted().record(before.owner.chat)?.seen?.messageID == seen?.messageID)
        #expect(service.openCount == openCount)
        #expect(store.library.artifacts.count == 2)
        #expect(Set(store.library.artifacts.map(\.id)).count == 2)
    }

    @Test func failedRefreshKeepsLoadedResultsAndReportsIncompleteHistory() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let loaded = library.artifacts.map(\.id)
        service.failHistory = true

        await library.refresh(evidence: .observed, bots: service.profiles)

        #expect(library.artifacts.map(\.id) == loaded)
        #expect(library.warning != nil)
        #expect(!library.isLoading)
        #expect(library.statusAction == .retry)
    }

    @Test func seedingAShorterCachedTranscriptCannotEraseIndexedOutputs() async throws {
        let service = LibraryTestService()
        service.messages[service.first] = [
            ChatMessage(id: "older", role: .assistant, text: "MEDIA:/older.pdf"),
            ChatMessage(id: "latest", role: .assistant, text: "MEDIA:/latest.pdf")
        ]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        var cached = ConversationBook()
        let id = cached.merge(.init(identity: service.first, title: "Main", isCanonical: true, persistence: .durable))
        cached.cache(.init(id: "main", storedID: "main", profileID: "helper",
            messages: [service.messages[service.first]!.last!]), for: id)

        library.seed(book: cached, bots: service.profiles)
        await library.restore()

        #expect(library.chats.first { $0.identity == service.first }?.messages.count == 2)
        #expect(library.artifacts.contains { $0.artifact.attachment?.path == "/older.pdf" })
    }

    @Test func hiddenMessagePagesDoNotStopHistoryIndexing() async throws {
        let service = LibraryTestService()
        service.hiddenFirstPage = true
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)

        await library.refresh(evidence: .observed, bots: service.profiles)

        #expect(library.artifacts.count == 2)
        #expect(service.historyOffsets.contains(100))
        #expect(library.warning == nil)
    }

    @Test func cancelledScanLabelsItsPartialResults() async throws {
        let service = LibraryTestService()
        let gate = StoreTestBarrier()
        service.historyBarrier = gate
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        let reading = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        await gate.waitUntilEntered()
        reading.cancel()
        gate.release()
        await reading.value
        #expect(library.warning != nil)
        #expect(!library.isLoading)
    }

    @Test func observedTipChangesRetireOldFilesBeforeReplacementHistoryArrives() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let original = try #require(library.artifacts.first { $0.chat.identity == service.first })
        service.replacementFirst = SessionIdentity(profile: service.first.profile, root: service.first.root,
            stored: try ExactID("new-tip"), aliases: [service.first.stored])
        let gate = StoreTestBarrier()
        service.historyBarrier = gate
        let refreshing = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        await gate.waitUntilEntered()

        #expect(!library.isCurrent(original))

        service.historyBarrier = nil
        gate.release()
        await refreshing.value
    }

    @Test func retirementRejectsLateHistoryAndDownloadCompletions() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        let history = StoreTestBarrier()
        service.historyBarrier = history
        let reading = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        await history.waitUntilEntered()
        library.retire()
        history.release()
        await reading.value
        #expect(library.isRetired)
        #expect(library.artifacts.isEmpty)

        service.historyBarrier = nil
        let current = WorkspaceLibrary(service: service)
        current.setOnline(true)
        await current.refresh(evidence: .observed, bots: service.profiles)
        let artifact = try #require(current.artifacts.first)
        let download = StoreTestBarrier()
        service.downloadBarrier = download
        let loading = Task { try await current.download(artifact) }
        await download.waitUntilEntered()
        current.retire()
        download.release()
        await #expect(throws: (any Error).self) { _ = try await loading.value }
    }

    @Test func offlineFilesRequireAConnectionButInlineOutputsRemainReadable() async throws {
        let service = LibraryTestService()
        service.messages[service.first] = [
            ChatMessage(id: "file", role: .assistant, text: "MEDIA:/report.txt"),
            ChatMessage(id: "visual", role: .assistant, text: "```html\n<h1>Offline visual</h1>\n```\n")
        ]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let file = try #require(library.artifacts.first { $0.artifact.attachment != nil })
        let inline = try #require(library.artifacts.first { $0.artifact.block != nil })
        library.setOnline(false)
        let calls = service.downloadCount
        await #expect(throws: (any Error).self) { _ = try await library.download(file) }
        #expect(service.downloadCount == calls)
        let bytes = try await library.download(inline)
        #expect(String(data: bytes.data, encoding: .utf8)?.contains("Offline visual") == true)
    }

    @Test func searchDestinationOpensTheExactSiblingChat() async throws {
        let service = LibraryTestService()
        let storage = MemoryConnectionStorage()
        let store = AppStore(service: service, persistence: storage.persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let sibling = try #require(store.library.chats.first { $0.identity == service.second })

        #expect(await store.openLibraryChat(sibling))

        #expect(store.selectedBotID == sibling.botID)
        #expect(store.chats.selection(profile: service.second.profile)?.identity?.root == service.second.root)
        #expect(service.lastOpened?.root == service.second.root)
    }

    @Test func replacingTheMountedWorkspaceRetiresItsLibraryDestinations() async throws {
        let service = LibraryTestService()
        let storage = MemoryConnectionStorage()
        let store = AppStore(service: service, persistence: storage.persistence)
        let original = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://other.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: original.id); LocalHistory.remove(for: replacement.id) }
        #expect(await store.connect(original))
        await store.refreshLibrary()
        let oldLibrary = store.library
        let oldArtifact = try #require(oldLibrary.artifacts.first)

        #expect(await store.connect(replacement))

        #expect(oldLibrary.isRetired)
        #expect(store.library !== oldLibrary)
        #expect(!store.library.isCurrent(oldArtifact))
        #expect(!(await store.openLibraryChat(oldArtifact.chat)))
        let downloads = service.downloadCount
        await #expect(throws: (any Error).self) { _ = try await oldLibrary.download(oldArtifact) }
        #expect(service.downloadCount == downloads)
    }
}

private actor NextLibraryProjectionPause {
    private var armed = false
    func arm() { armed = true }
    func take() -> Bool {
        guard armed else { return false }
        armed = false; return true
    }
}

@MainActor private final class LibraryTestService: BotService {
    var onEvent: ((BotServiceEvent) -> Void)?
    let profiles: [BotProfile]
    var rosterProfiles: [BotProfile]?
    let first = SessionIdentity(profile: try! ExactID("helper"), root: try! ExactID("main"),
        stored: try! ExactID("main"), aliases: [try! ExactID("main")])
    let second: SessionIdentity
    var messages: [SessionIdentity: [ChatMessage]] = [:]
    var failHistory = false
    var failingHistorySource: SessionIdentity?
    var failDirectory = false
    var versionedSummaries = false
    var directoryCount = 0
    var directoryBarrier: StoreTestBarrier?
    var directoryBarriers: [ExactID: StoreTestBarrier] = [:]
    var directoryActivity: [SessionIdentity: ObservedActivity] = [:]
    var creationBarrier: StoreTestBarrier?
    var creationCount = 0
    var createdIdentity: SessionIdentity?
    var openingBarrier: StoreTestBarrier?
    var gatedSource: SessionIdentity?
    var failingSource: SessionIdentity?
    var replacementFirst: SessionIdentity?
    var omitSecond = false
    var hiddenFirstPage = false
    var historyOffsets: [Int] = []
    var historyBarrier: StoreTestBarrier?
    var historyBarriers: [SessionIdentity: StoreTestBarrier] = [:]
    var historyFailures: [SessionIdentity: any Error] = [:]
    var historyFailureOffsets: [SessionIdentity: Int] = [:]
    var historyPages: [SessionIdentity: [Int: ConversationHistoryPage]] = [:]
    var downloadBarrier: StoreTestBarrier?
    var openCount = 0
    var summaryTitle = "Research notes"
    var fileBytes: Data?
    var pinOnConnect: String?
    var downloadCount = 0
    var botReadCount = 0
    var botsBarrier: StoreTestBarrier?
    var botsError: (any Error)?
    var lastOpened: SessionIdentity?
    private(set) var lastAccess: ConversationAccess?
    private var issuer = ConversationIssuer<SessionIdentity>()
    private var selectionGeneration = 0

    init(secondBot: Bool = false) {
        profiles = [BotProfile(id: "helper", name: "Helper")] + (secondBot ? [BotProfile(id: "other", name: "Other")] : [])
        second = SessionIdentity(profile: try! ExactID(secondBot ? "other" : "helper"), root: try! ExactID("side"),
            stored: try! ExactID("side"), aliases: [try! ExactID("side")])
        messages[first] = [ChatMessage(id: "main-file", role: .assistant, text: "MEDIA:/report.txt")]
        messages[second] = [ChatMessage(id: "side-file", role: .assistant, text: "MEDIA:/report.txt")]
    }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        if let pinOnConnect {
            var pinned = configuration; pinned.installID = pinOnConnect
            onEvent?(.configuration(pinned))
        }
        return .init(version: "test", installID: pinOnConnect)
    }
    func disconnect() {}
    func bots() async throws -> [BotProfile] {
        botReadCount += 1
        await botsBarrier?.wait()
        if let botsError { throw botsError }
        return rosterProfiles ?? profiles
    }
    func createBot(_ draft: BotDraft) async throws -> BotProfile { throw HermesServiceError.rejected(-32601) }
    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        directoryCount += 1
        await (directoryBarriers[profile] ?? directoryBarrier)?.wait()
        if failDirectory { throw HermesServiceError.disconnected }
        var summaries: [SessionSummary] = [
            .init(identity: replacementFirst ?? first, title: "Main", isCanonical: true, persistence: .durable),
            .init(identity: second, title: summaryTitle, isCanonical: second.profile != first.profile, persistence: .durable)
        ]
        if omitSecond { summaries.removeAll { $0.identity.root == second.root } }
        if let createdIdentity { summaries.append(.init(identity: createdIdentity, title: "Created", isCanonical: false, persistence: .durable)) }
        let scoped = summaries.filter { $0.identity.profile == profile }.map { summary in
            guard versionedSummaries else { return summary }
            return SessionSummary(identity: summary.identity, title: summary.title, isCanonical: summary.isCanonical,
                persistence: summary.persistence, preview: "", updatedAt: Date(timeIntervalSince1970: 1_000),
                messageCount: messages[summary.identity]?.count)
        }
        return .init(summaries: scoped, activity: directoryActivity, isComplete: true)
    }
    func conversationHistory(_ identity: SessionIdentity, offset: Int) async throws -> ConversationHistoryPage {
        historyOffsets.append(offset)
        await (historyBarriers[identity] ?? historyBarrier)?.wait()
        if let failure = historyFailures[identity], historyFailureOffsets[identity] == nil || historyFailureOffsets[identity] == offset { throw failure }
        if let page = historyPages[identity]?[offset] { return page }
        if failHistory || identity == failingHistorySource { throw HermesServiceError.disconnected }
        if hiddenFirstPage, offset == 0 { return .init(messages: [], nextOffset: 100, isComplete: true, sourceIDs: [Data("hidden-head".utf8)]) }
        let rows = messages[identity] ?? []
        return .init(messages: rows, nextOffset: nil, isComplete: true, sourceIDs: Set(rows.map { Data($0.id.utf8) }))
    }
    func downloadArtifact(_ attachment: ChatAttachment, in identity: SessionIdentity) async throws -> DownloadedArtifact {
        downloadCount += 1
        await downloadBarrier?.wait()
        return .init(data: fileBytes ?? Data(identity.root.text.utf8), filename: attachment.name, mimeType: "text/plain")
    }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession {
        creationCount += 1
        await creationBarrier?.wait()
        let identity = SessionIdentity(profile: profile, root: try ExactID("created"), stored: try ExactID("created"), aliases: [])
        createdIdentity = identity
        messages[identity] = []
        return .init(operationID: operationID,
            summary: .init(identity: identity, title: "Created", isCanonical: false, persistence: .durable))
    }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let readStartedAt = ContinuousClock.now
        openCount += 1
        selectionGeneration += 1
        let owner = selectionGeneration
        issuer.retireAttachment()
        let identity: SessionIdentity
        switch target {
        case .canonical(let profile, _): identity = profile == first.profile ? replacementFirst ?? first : second
        case .stored(let source): identity = source
        }
        if identity == gatedSource { await openingBarrier?.wait() }
        guard selectionGeneration == owner else { throw HermesServiceError.staleConversation }
        if identity == failingSource { throw HermesServiceError.missingChat }
        lastOpened = identity
        let access = try issuer.issue(identity)
        lastAccess = access
        return .init(identity: identity, snapshot: .init(id: identity.root.text, storedID: identity.stored.text,
            profileID: identity.profile.text, messages: messages[identity] ?? []), access: access,
            historyReadStartedAt: readStartedAt, observedSource: identity)
    }
    func source(for access: ConversationAccess) throws -> SessionIdentity { try issuer.resolve(access) }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw HermesServiceError.rejected(-32601) }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw HermesServiceError.rejected(-32601) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw HermesServiceError.rejected(-32601) }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment { throw HermesServiceError.rejected(-32601) }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        let identity = try issuer.resolve(access)
        let result = try await downloadArtifact(attachment, in: identity)
        guard try issuer.resolve(access) == identity else { throw HermesServiceError.staleConversation }
        return result
    }
}
