import Foundation
import Testing
import SQLite3
import BottoCore
@testable import Botto

@MainActor struct ArtifactCacheTests {
    @Test func downloadedOriginalSurvivesAnIndependentCacheReopen() async throws {
        try await withCacheRoot { root, own in
            let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data("https://cache.example".utf8),
                installationID: Data("installation".utf8), username: Data(), provider: Data("native".utf8))
            let id = try ExactID("chat")
            let identity = SessionIdentity(profile: try ExactID("bot"), root: id, stored: id, aliases: [id])
            let key = ArtifactOriginalKey(identity: identity, messageID: Data("message".utf8), path: Data("/report.txt".utf8), sourceRevision: Data("revision".utf8))
            let first = own(ArtifactCache(root: root)).session(scope: scope)
            try await first.retainOriginal(.init(data: Data("retained report".utf8), filename: "report.txt", mimeType: "text/plain"), for: key)
            first.retire()
            let reopened = own(ArtifactCache(root: root)).session(scope: scope)
            let result = try #require(try await reopened.original(for: key))
            #expect(result.artifact.data == Data("retained report".utf8))
            #expect(result.artifact.filename == "report.txt")
        }
    }
    private func fixture(root: URL? = nil, limits: ArtifactCache.Limits = .init(), configurationID: UUID = UUID(), origin: String = "https://cache.example") throws -> (ArtifactCache, ArtifactCacheScope, ArtifactOriginalKey) {
        let scope = ArtifactCacheScope(configurationID: configurationID, serverURL: Data(origin.utf8), installationID: Data("install".utf8), username: Data(), provider: Data("native".utf8))
        let id = try ExactID("chat")
        return (ArtifactCache(root: root, limits: limits), scope,
                ArtifactOriginalKey(identity: SessionIdentity(profile: try ExactID("bot"), root: id, stored: id, aliases: [id]), messageID: Data("message".utf8), path: Data("/report".utf8), sourceRevision: Data("r1".utf8)))
    }
    private var bytes: DownloadedArtifact { .init(data: Data("report".utf8), filename: "report.txt", mimeType: "text/plain") }

    @Test func byteDistinctScopesAndProducingRevisionsNeverShareCapturedOriginals() async throws {
        let (cache, scope, key) = try fixture()
        let first = cache.session(scope: scope)
        try await first.retainOriginal(bytes, for: key)
        let otherID = ArtifactCacheScope(configurationID: UUID(), serverURL: scope.serverURL, installationID: scope.installationID, username: scope.username, provider: scope.provider)
        #expect(try await cache.session(scope: otherID).original(for: key) == nil)
        let changed = ArtifactOriginalKey(identity: key.identity, messageID: key.messageID, path: key.path, sourceRevision: Data("r2".utf8))
        #expect(try await first.original(for: changed) == nil)
        #expect(try await first.original(for: key)?.artifact.data == Data("report".utf8))
        let unicodeA = ArtifactCacheScope(configurationID: scope.configurationID, serverURL: Data("https://é.example".utf8), installationID: scope.installationID, username: scope.username, provider: scope.provider)
        let unicodeB = ArtifactCacheScope(configurationID: scope.configurationID, serverURL: Data("https://e\u{301}.example".utf8), installationID: scope.installationID, username: scope.username, provider: scope.provider)
        try await cache.session(scope: unicodeA).retainOriginal(bytes, for: key)
        #expect(try await cache.session(scope: unicodeB).original(for: key) == nil)
    }
    @Test func purgeFencesOldSessionAndOrdersImmediateConfigurationReuseBeforeColdReopen() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root)
            _ = own(cache)
            let old = cache.session(scope: scope)
            try await old.retainOriginal(bytes, for: key)
            let queuedWrite = Task { try await old.retainOriginal(bytes, for: key) }
            cache.discard(configurationID: scope.configurationID)
            do { _ = try await queuedWrite.value; Issue.record("A queued retired write was admitted") } catch {}
            #expect(old.isRetired)
            let replacement = cache.session(scope: scope)
            #expect(try await replacement.original(for: key) == nil)
            do {
                try await old.retainOriginal(bytes, for: key)
                Issue.record("A retired session admitted bytes")
            } catch {}
            try await cache.drainMaintenance()
            #expect(try await own(ArtifactCache(root: root)).session(scope: scope).original(for: key) == nil)
            try await replacement.retainOriginal(bytes, for: key)
            #expect(try await replacement.original(for: key)?.artifact.data == Data("report".utf8))
        }
    }
    @Test func originalEvictionAndMissingBlobAreCacheMisses() async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits()
            limits.originalBytes = 6
            let (cache, scope, key) = try fixture(root: root, limits: limits)
            _ = own(cache)
            let session = cache.session(scope: scope)
            try await session.retainOriginal(bytes, for: key)
            let changed = ArtifactOriginalKey(identity: key.identity, messageID: key.messageID, path: key.path, sourceRevision: Data("r2".utf8))
            try await session.retainOriginal(.init(data: Data("second".utf8), filename: "second", mimeType: "text/plain"), for: changed)
            #expect(try await session.original(for: key) == nil)
            #expect(try await session.original(for: changed)?.artifact.data == Data("second".utf8))
            for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("1-") {
                try FileManager.default.removeItem(at: file)
            }
            #expect(try await session.original(for: changed) == nil)
            #expect(try await session.retainOriginal(.init(data: Data(repeating: 0, count: 7), filename: "large", mimeType: "text/plain"), for: key) == nil)
        }
    }
    @Test func metadataAndThumbnailsSurviveReopenWithCoverageIntact() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root)
            _ = own(cache)
            let session = cache.session(scope: scope)
            let message = ChatMessage(id: "output", role: .assistant, text: "Saved file: /report.txt")
            let record = CachedArtifactChat(identity: key.identity, botName: "Bot", title: "Report", messages: [message], updatedAt: nil, coverage: .partial, summary: nil, headFingerprint: Data("head".utf8))
            try await session.upsert(record)
            let digest = try #require(try await session.retainOriginal(bytes, for: key))
            let thumbnail = ArtifactThumbnailKey(originalDigest: digest, maximumPixels: 400, decoderVersion: 1)
            try await session.retainThumbnail(Data("thumbnail".utf8), for: thumbnail)
            let reopened = own(ArtifactCache(root: root)).session(scope: scope)
            let chats = try await reopened.loadChats()
            #expect(chats.count == 1)
            #expect(chats.first?.title == "Report")
            #expect(chats.first?.coverage == .partial)
            #expect(chats.first?.messages.first?.text == "Saved file: /report.txt")
            #expect(try await reopened.thumbnail(for: thumbnail) == Data("thumbnail".utf8))
            #expect(try await reopened.thumbnail(for: .init(originalDigest: digest, maximumPixels: 401, decoderVersion: 1)) == nil)
            try await reopened.deleteChat(profile: key.identity.profile, root: key.identity.root)
            #expect(try await reopened.loadChats().isEmpty)
        }
    }
    @Test func startupPruneRemovesOnlyUnreachableConfigurations() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root)
            _ = own(cache)
            try await cache.session(scope: scope).retainOriginal(bytes, for: key)
            let other = ArtifactCacheScope(configurationID: UUID(), serverURL: scope.serverURL, installationID: scope.installationID, username: scope.username, provider: scope.provider)
            try await cache.session(scope: other).retainOriginal(bytes, for: key)
            cache.prune(reachableConfigurationIDs: [other.configurationID])
            try await cache.drainMaintenance()
            #expect(try await own(ArtifactCache(root: root)).session(scope: scope).original(for: key) == nil)
            #expect(try await own(ArtifactCache(root: root)).session(scope: other).original(for: key)?.artifact.data == Data("report".utf8))
        }
    }


    @Test func unknownDatabaseVersionRemainsUntouchedAndUnavailable() async throws {
        try await withCacheRoot { root, own in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("index.sqlite")
            var handle: OpaquePointer?
            #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
            #expect(sqlite3_exec(handle, "CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES('preserve'); PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(handle)
            let before = try Data(contentsOf: url)
            let (cache, scope, key) = try fixture(root: root)
            _ = own(cache)
            do {
                _ = try await cache.session(scope: scope).original(for: key)
                Issue.record("Unknown schema must be unavailable")
            } catch {}
            #expect(try Data(contentsOf: url) == before)
        }
    }
    @Test func lockedDatabaseFailsWithoutReplacingItsRetainedContent() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root)
            _ = own(cache)
            try await cache.session(scope: scope).retainOriginal(bytes, for: key)
            var handle: OpaquePointer?
            #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            #expect(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
            do {
                _ = try await own(ArtifactCache(root: root)).session(scope: scope).original(for: key)
                Issue.record("An exclusively locked store should report unavailable")
            } catch {}
            #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            #expect(try await own(ArtifactCache(root: root)).session(scope: scope).original(for: key)?.artifact.data == Data("report".utf8))
        }
    }
    @Test func corruptOriginalBytesAreNeverServed() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root)
            _ = own(cache)
            let session = cache.session(scope: scope)
            try await session.retainOriginal(bytes, for: key)
            let file = try #require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("1-") })
            try Data("damage".utf8).write(to: file)
            #expect(try await session.original(for: key) == nil)
            try await session.retainOriginal(bytes, for: key)
            #expect(try await session.original(for: key)?.artifact.data == Data("report".utf8))
        }
    }

    @Test func failedPurgeFencesReuseUntilExplicitMaintenanceRetry() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root)
            _ = own(cache)
            let old = cache.session(scope: scope)
            try await old.retainOriginal(bytes, for: key)
            var handle: OpaquePointer?
            #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            #expect(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
            cache.discard(configurationID: scope.configurationID)
            #expect(old.isRetired)
            do { try await cache.drainMaintenance(); Issue.record("Locked purge reported success") } catch {}
            #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            do {
                _ = try await cache.session(scope: scope).original(for: key)
                Issue.record("A failed purge permitted namespace reuse")
            } catch {}
            cache.discard(configurationID: scope.configurationID)
            try await cache.drainMaintenance()
            #expect(try await cache.session(scope: scope).original(for: key) == nil)
            #expect(try await own(ArtifactCache(root: root)).session(scope: scope).original(for: key) == nil)
        }
    }
    @Test(arguments: ["messages", "text", "chats", "metadata"])
    func globalChatAdmissionEvictsOlderRowsAcrossConfigurationScopes(_ budget: String) async throws {
        var limits = ArtifactCache.Limits()
        switch budget {
        case "messages": limits.messageCount = 3
        case "text": limits.textBytes = 9
        case "chats": limits.chatCount = 1
        default: limits.metadataBytes = 4_000
        }
        let (cache, scope, key) = try fixture(limits: limits)
        let other = ArtifactCacheScope(configurationID: UUID(), serverURL: scope.serverURL, installationID: scope.installationID, username: scope.username, provider: scope.provider)
        let messages = [ChatMessage(id: "1", role: .assistant, text: "four"), ChatMessage(id: "2", role: .assistant, text: "four")]
        let title = budget == "metadata" ? String(repeating: "t", count: 2_000) : "Report"
        let record = CachedArtifactChat(identity: key.identity, botName: "Bot", title: title, messages: messages, updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil)
        let first = cache.session(scope: scope), second = cache.session(scope: other)
        try await first.upsert(record)
        #expect(try await first.loadChats().count == 1)
        try await second.upsert(record)
        #expect(try await first.loadChats().isEmpty)
        let retained = try await second.loadChats()
        #expect(retained.count == 1)
        #expect(retained.first?.messages.map(\.text) == ["four", "four"])
    }
    @Test func unavailableRootPreservesExistingFileAndReportsFailure() async throws {
        try await withCacheRoot { root, own in
            let sentinel = Data("existing protected content".utf8)
            try sentinel.write(to: root)
            let (cache, scope, key) = try fixture(root: root)
            _ = own(cache)
            do {
                try await cache.session(scope: scope).retainOriginal(bytes, for: key)
                Issue.record("A regular file cannot be used as a cache directory")
            } catch {}
            #expect(try Data(contentsOf: root) == sentinel)
        }
    }

    @Test func orderlyCloseRetiresSessionsAndPreventsDelayedReopening() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root)
            _ = own(cache)
            let session = cache.session(scope: scope)
            try await session.retainOriginal(bytes, for: key)
            let delayedWrite = Task { try await session.retainOriginal(bytes, for: key) }
            await cache.close()
            #expect(session.isRetired)
            do { _ = try await delayedWrite.value; Issue.record("A retired session admitted a delayed write") } catch {}
            do {
                _ = try await cache.session(scope: scope).original(for: key)
                Issue.record("A closed cache reopened its database")
            } catch {}
            let reopened = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await reopened.original(for: key)?.artifact.data == Data("report".utf8))
        }
    }

    private func withCacheRoot(_ operation: @MainActor (URL, @MainActor (ArtifactCache) -> ArtifactCache) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var owned: [ArtifactCache] = []
        do {
            try await operation(root, { cache in owned.append(cache); return cache })
        } catch {
            for cache in owned { await cache.close() }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        for cache in owned { await cache.close() }
        try FileManager.default.removeItem(at: root)
    }
}
