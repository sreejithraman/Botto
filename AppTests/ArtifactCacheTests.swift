import CryptoKit
import Foundation
import Testing
import SQLite3
import BottoCore
@testable import Botto

@MainActor struct ArtifactCacheTests {
    /// A capture paused before COMMIT publishes only if one of its consumers is still registered when it resumes.
    @Test(arguments: [false, true])
    func aPausedCaptureCommitsOnlyWhileAConsumerRemains(survivingPeer: Bool) async throws {
        try await withCacheRoot { root, own in
            let gate = CaptureCommitGate()
            defer { gate.release() }
            let (_, scope, key) = try fixture()
            let cache = own(ArtifactCache(root: root, beforeCaptureCommit: { gate.pause() }))
            let session = cache.session(scope: scope), admission = ArtifactCaptureAdmission()
            let consumer = UUID(), peer = UUID()
            admission.register(consumer)
            if survivingPeer { admission.register(peer) }
            gate.arm()
            let saving = Task { try await session.retainOriginal(bytes, for: key, admission: admission) }
            defer { saving.cancel(); admission.revokeAll() }
            await waitWhile { !gate.isEntered }
            try #require(gate.isEntered)
            admission.revoke(consumer); gate.release()
            if survivingPeer {
                #expect(try await saving.value != nil)
            } else {
                await #expect(throws: CancellationError.self) { _ = try await saving.value }
            }
            #expect(try await session.original(for: key)?.artifact.data == (survivingPeer ? bytes.data : nil),
                "A rolled-back capture must also release the cache actor")
            await cache.close()
            let reopened = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await reopened.original(for: key)?.artifact.data == (survivingPeer ? bytes.data : nil))
        }
    }

    /// Pages and indexes count against the index allowance as well as row bytes. A cache at that limit evicts
    /// its oldest captures and compacts, instead of refusing every later capture.
    @Test func capturesPastThePageBudgetEvictTheOldestAndKeepSucceeding() async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.indexBytes = 40_000
            let (_, scope, _) = try fixture()
            let session = own(ArtifactCache(root: root, limits: limits)).session(scope: scope)
            let identity = SessionIdentity(profile: try ExactID("bot"), root: try ExactID("chat"), stored: try ExactID("chat"), aliases: [])
            func key(_ index: Int) -> ArtifactOriginalKey {
                .init(identity: identity, messageID: Data("message-\(index)".utf8),
                    path: Data(("/outputs/" + String(repeating: "long-folder/", count: 20) + "report-\(index).txt").utf8),
                    sourceRevision: Data(SHA256.hash(data: Data("\(index)".utf8))))
            }
            let count = 300
            for index in 0..<count {
                let artifact = DownloadedArtifact(data: Data("report \(index)".utf8), filename: "report-\(index).txt", mimeType: "text/plain")
                #expect(try await session.retainOriginal(artifact, for: key(index)) != nil, "Capture \(index) was refused")
            }
            #expect(try await session.original(for: key(count - 1))?.artifact.data == Data("report \(count - 1)".utf8))
            #expect(try await session.original(for: key(0)) == nil, "The oldest capture makes room")
            let database = root.appendingPathComponent("index.sqlite")
            let size = try #require(try database.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(size <= 64 * 1024)
        }
    }

    private func pageBytesInUse(_ root: URL) throws -> Int {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        func value(_ pragma: String) -> Int {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, pragma, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int64(statement, 0))
        }
        return (value("PRAGMA page_count") - value("PRAGMA freelist_count")) * value("PRAGMA page_size")
    }
    private func pressureKey(_ name: String, pathBytes: Int = 1_500) throws -> ArtifactOriginalKey {
        let id = try ExactID("chat")
        return .init(identity: SessionIdentity(profile: try ExactID("bot"), root: id, stored: id, aliases: [id]),
            messageID: Data(name.utf8), path: Data(("/" + String(repeating: "p", count: pathBytes)).utf8), sourceRevision: Data(name.utf8))
    }
    private func pressureScope() -> ArtifactCacheScope {
        .init(configurationID: UUID(), serverURL: Data("https://other.example".utf8), installationID: nil, username: Data(), provider: nil)
    }

    /// A capture too large for the page budget on its own is refused without evicting anything, in any scope.
    @Test func aCaptureThatCannotFitIsRefusedAndKeepsEveryOtherCapture() async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.indexBytes = 40_000
            let (_, scope, key) = try fixture()
            let other = pressureScope()
            let cache = own(ArtifactCache(root: root, limits: limits))
            let session = cache.session(scope: scope), otherSession = cache.session(scope: other)
            try await session.retainOriginal(bytes, for: key)
            try await otherSession.retainOriginal(bytes, for: key)
            let rows = try entries(in: root).map { [$0.kind] + [$0.scope, $0.key, $0.payload].map(\.count) }, blobs = try files(in: root)
            // Its rows fit the row allowance, but with their primary-key index copy they need more pages than the budget.
            let large = try pressureKey("large", pathBytes: 17_000)
            await #expect(throws: ArtifactCacheError.quota) { _ = try await session.retainOriginal(bytes, for: large) }
            #expect(try entries(in: root).map { [$0.kind] + [$0.scope, $0.key, $0.payload].map(\.count) } == rows)
            #expect(try files(in: root) == blobs)
            await cache.close()
            let reopened = own(ArtifactCache(root: root, limits: limits))
            #expect(try await reopened.session(scope: scope).original(for: key)?.artifact.data == bytes.data)
            #expect(try await reopened.session(scope: other).original(for: key)?.artifact.data == bytes.data)
        }
    }

    /// A replacement that needs evictions to fit, then is revoked or retired before COMMIT, takes its evictions
    /// back with it: the key keeps its previous original and digest, and no other row is gone.
    /// The committed case shows the same replacement really evicts, and never its own key.
    @Test(arguments: ["revoked", "retired", "committed"])
    func aWithdrawnReplacementUnderPagePressureKeepsThePreviousCaptureAndEvictsNothing(withdrawal: String) async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.indexBytes = 40_000
            let gate = CaptureCommitGate()
            defer { gate.release() }
            let (_, scope, _) = try fixture()
            let cache = own(ArtifactCache(root: root, limits: limits, beforeCaptureCommit: { gate.pause() }))
            let session = cache.session(scope: scope)
            // The replaced key is the least recently used, the first candidate for eviction.
            let key = try pressureKey("replaced")
            let previousDigest = try #require(try await session.retainOriginal(bytes, for: key))
            var fillers = 0
            while try pageBytesInUse(root) < 44 * 1024 {
                let filler = DownloadedArtifact(data: Data("filler \(fillers)".utf8), filename: "filler.txt", mimeType: "text/plain")
                try await session.retainOriginal(filler, for: try pressureKey("filler-\(fillers)"))
                fillers += 1
            }
            let rows = try entries(in: root)
            try #require(rows.count == 2 * (fillers + 1), "Filling must not evict")
            let blobs = try files(in: root)
            let admission = ArtifactCaptureAdmission(), consumer = UUID()
            admission.register(consumer)
            gate.arm()
            // Long metadata needs about six more pages than the budget leaves.
            let replacement = DownloadedArtifact(data: Data("replacement".utf8), filename: String(repeating: "f", count: 24_000), mimeType: "text/plain")
            let replacing = Task { try await session.retainOriginal(replacement, for: key, admission: admission) }
            defer { replacing.cancel(); admission.revokeAll() }
            await waitWhile { !gate.isEntered }
            try #require(gate.isEntered)
            if withdrawal == "revoked" { admission.revoke(consumer) } else if withdrawal == "retired" { session.retire() }
            gate.release()
            if withdrawal == "committed" {
                #expect(try await replacing.value != nil)
                let after = try entries(in: root)
                #expect(after.count < rows.count, "The replacement needed evictions to fit")
                #expect(after.filter { $0.key == Self.captureKey(key) }.count == 2)
                #expect(try await session.original(for: key)?.artifact.data == replacement.data)
                #expect(try pageBytesInUse(root) <= 64 * 1024)
                return
            }
            await #expect(throws: (any Error).self) { _ = try await replacing.value }
            let after = try entries(in: root)
            #expect(after.count == rows.count, "A withdrawn capture evicts nothing")
            #expect(after.map(\.key) == rows.map(\.key) && after.map(\.payload) == rows.map(\.payload))
            #expect(try files(in: root) == blobs)
            await cache.close()
            let reopened = own(ArtifactCache(root: root, limits: limits)).session(scope: scope)
            #expect(try await reopened.original(for: key)?.artifact.data == bytes.data)
            #expect(try await reopened.originalDigest(for: key) == previousDigest)
        }
    }

    /// Startup pruning also opens and upgrades the cache. A lock at launch must not leave the cache unavailable
    /// for the rest of the run: the next workspace mount retries it once.
    @Test func aStartupPruneThatFailsIsRetriedByALaterMount() async throws {
        try await withCacheRoot { root, own in
            let (seed, scope, key) = try fixture(root: root)
            _ = own(seed)
            try await seed.session(scope: scope).retainOriginal(bytes, for: key)
            await seed.close()
            var handle: OpaquePointer?
            try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            try #require(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
            let cache = own(ArtifactCache(root: root))
            cache.prune(reachableConfigurationIDs: [scope.configurationID])
            await #expect(throws: (any Error).self) { try await cache.drainMaintenance() }
            await #expect(throws: (any Error).self) { _ = try await cache.session(scope: scope).original(for: key) }
            #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            #expect(try await cache.session(scope: scope).original(for: key)?.artifact.data == bytes.data)
        }
    }

    @Test(arguments: [false, true])
    func rejectedCaptureAdmissionKeepsThePreviousBytesAndDigestAcrossReopen(evictionFails: Bool) async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.indexBytes = 4_000
            let (cache, scope, key) = try fixture(root: root, limits: limits)
            _ = own(cache)
            let session = cache.session(scope: scope)
            let previousDigest = try #require(try await session.retainOriginal(bytes, for: key))
            // An older capture of another key, so the oversized replacement has something to evict.
            let other = ArtifactOriginalKey(identity: key.identity, messageID: key.messageID, path: Data("/other".utf8), sourceRevision: key.sourceRevision)
            let otherDigest = try #require(try await session.retainOriginal(.init(data: Data("other".utf8), filename: "other.txt", mimeType: "text/plain"), for: other))
            var handle: OpaquePointer?
            #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            if evictionFails {
                #expect(sqlite3_exec(handle, "CREATE TRIGGER reject_eviction BEFORE DELETE ON entries WHEN OLD.kind=1 BEGIN SELECT RAISE(ABORT,'injected eviction failure'); END", nil, nil, nil) == SQLITE_OK)
            }
            // Evicting the other key fails mid-transaction, or succeeds and the replacement still doesn't fit.
            let refusal: ArtifactCacheError = evictionFails ? .unavailable : .quota
            await #expect(throws: refusal) {
                _ = try await session.retainOriginal(.init(data: Data("replacement".utf8),
                    filename: String(repeating: "metadata", count: 1_000), mimeType: "text/plain"), for: key)
            }
            if evictionFails { #expect(sqlite3_exec(handle, "DROP TRIGGER reject_eviction", nil, nil, nil) == SQLITE_OK) }
            await cache.close()
            let reopened = own(ArtifactCache(root: root, limits: limits)).session(scope: scope)
            #expect(try await reopened.original(for: key)?.artifact.data == Data("report".utf8))
            #expect(try await reopened.originalDigest(for: key) == previousDigest)
            #expect(try await reopened.original(for: other)?.artifact.data == Data("other".utf8))
            #expect(try await reopened.originalDigest(for: other) == otherDigest)
        }
    }

    @Test func failedDigestReplacementRollsBackTheOriginalAndSurvivesReopen() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root)
            _ = own(cache)
            let session = cache.session(scope: scope)
            let digest = try #require(try await session.retainOriginal(bytes, for: key))
            var handle: OpaquePointer?
            #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            #expect(sqlite3_exec(handle, "CREATE TRIGGER reject_digest BEFORE INSERT ON entries WHEN NEW.kind=3 BEGIN SELECT RAISE(ABORT,'injected digest failure'); END", nil, nil, nil) == SQLITE_OK)
            await #expect(throws: (any Error).self) {
                _ = try await session.retainOriginal(.init(data: Data("replacement".utf8), filename: "report.txt", mimeType: "text/plain"), for: key)
            }
            #expect(sqlite3_exec(handle, "DROP TRIGGER reject_digest", nil, nil, nil) == SQLITE_OK)
            await cache.close()
            let reopened = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await reopened.original(for: key)?.artifact.data == Data("report".utf8))
            #expect(try await reopened.originalDigest(for: key) == digest)
        }
    }

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
            let retrying = own(ArtifactCache(root: root)).session(scope: scope)
            do {
                _ = try await retrying.original(for: key)
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

    @Test(arguments: ["tagged", "absent", "empty"])
    func persistedScopeAndCaptureBytesKeepTheirEstablishedFormat(shape: String) async throws {
        let format = persistedFormat(shape)
        let root = try ExactID("cafe\u{301}"), identity = SessionIdentity(profile: try ExactID("bót"), root: root, stored: root, aliases: [])
        let key = ArtifactOriginalKey(identity: identity, messageID: Data("message".utf8), path: Data("/report".utf8), sourceRevision: Data("r1".utf8))
        let original = "1-" + format.digest + "-845e91831319e89c4d656bdb80c278ac09a7230d61e5dfd2e1b1fbb436ac8917"
        try await withCacheRoot { directory, own in
            let cache = own(ArtifactCache(root: directory)), session = cache.session(scope: format.scope)
            try await session.retainOriginal(bytes, for: key)
            let rows = try entries(in: directory)
            #expect(rows.map(\.kind) == [1, 3])
            #expect(rows.allSatisfy { $0.scope == format.namespace })
            #expect(rows.allSatisfy { $0.configuration == Data("12345678-ABCD-4EF0-8123-456789ABCDEF".utf8) })
            #expect(rows.allSatisfy { $0.key == Self.captureKey(key) })
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(original).path))
        }
    }

    // Version 1 also held the retired Library index. Opening it purges that index once.

    nonisolated private static let chatText = "a private message only the old Library index kept"
    private struct LegacyCache {
        let scope: ArtifactCacheScope, key: ArtifactOriginalKey
        let original: String, thumbnail: String
    }
    /// Writes the version 1 layout an older build left on a device, without the app's encoder: a chat copy (kind 0),
    /// a captured original and its digest (kinds 1 and 3), a thumbnail (kind 2), their files and the recovery ledger.
    private func writeLegacyCache(at root: URL) throws -> LegacyCache {
        let format = persistedFormat("absent"), id = try ExactID("chat")
        let key = ArtifactOriginalKey(identity: SessionIdentity(profile: try ExactID("bot"), root: id, stored: id, aliases: [id]),
            messageID: Data("message".utf8), path: Data("/report".utf8), sourceRevision: Data("r1".utf8))
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        let data = Data("report".utf8), digest = Data(SHA256.hash(data: data))
        let original = "1-\(format.digest)-\(hex(digest))", thumbnail = "2-\(format.digest)-\(String(repeating: "ab", count: 32))"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(original))
        try Data("thumbnail pixels".utf8).write(to: root.appendingPathComponent(thumbnail))
        try Data("old ledger".utf8).write(to: root.appendingPathComponent("metadata-recovery.plist"))
        struct Metadata: Encodable { let filename: String, mimeType: String, digest: Data }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let metadata = try encoder.encode(Metadata(filename: "report.txt", mimeType: "text/plain", digest: digest))
        let chat = try PropertyListSerialization.data(fromPropertyList: ["title": "Main", "messages": [["text": Self.chatText]]],
            format: .binary, options: 0)
        let namespace = "X'\(hex(format.namespace))'", configuration = "X'\(hex(Data("12345678-ABCD-4EF0-8123-456789ABCDEF".utf8)))'"
        let captured = "X'\(hex(Self.captureKey(key)))'"
        let sql = """
            CREATE TABLE entries(scope BLOB NOT NULL, configuration BLOB NOT NULL, kind INTEGER NOT NULL, key BLOB NOT NULL, payload BLOB NOT NULL, blob TEXT, size INTEGER NOT NULL, accessed REAL NOT NULL, PRIMARY KEY(scope,kind,key));
            INSERT INTO entries VALUES(\(namespace), \(configuration), 0, X'0001', X'\(hex(chat))', NULL, \(chat.count), 1000);
            INSERT INTO entries VALUES(\(namespace), \(configuration), 1, \(captured), X'\(hex(metadata))', '\(original)', \(data.count), 1001);
            INSERT INTO entries VALUES(\(namespace), \(configuration), 2, X'0002', X'\(hex(Data(SHA256.hash(data: Data("thumbnail pixels".utf8)))))', '\(thumbnail)', 16, 1002);
            INSERT INTO entries VALUES(\(namespace), \(configuration), 3, \(captured), X'\(hex(digest))', NULL, 32, 1003);
            PRAGMA user_version=1;
            """
        var handle: OpaquePointer?
        try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        return .init(scope: format.scope, key: key, original: original, thumbnail: thumbnail)
    }
    private func files(in root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    }

    @Test func openingAnOldCachePurgesChatCopiesAndThumbnailsAndKeepsOriginalsOffline() async throws {
        try await withCacheRoot { root, own in
            let legacy = try writeLegacyCache(at: root)
            let database = root.appendingPathComponent("index.sqlite")
            #expect(try Data(contentsOf: database).range(of: Data(Self.chatText.utf8)) != nil)
            // Startup pruning opens the cache without writing any surviving row.
            let startup = own(ArtifactCache(root: root))
            startup.prune(reachableConfigurationIDs: [legacy.scope.configurationID])
            try await startup.drainMaintenance(); await startup.close()
            #expect(try Data(contentsOf: database).range(of: Data(Self.chatText.utf8)) == nil,
                "Deleted chat text must not remain in the database file")
            #expect(try userVersion(in: root) == 2)
            #expect(try entries(in: root).map(\.kind) == [1, 3])
            let names = try files(in: root)
            #expect(names.contains(legacy.original))
            #expect(!names.contains(legacy.thumbnail) && !names.contains("metadata-recovery.plist"))
            let reopened = try #require(try await own(ArtifactCache(root: root)).session(scope: legacy.scope).original(for: legacy.key))
            #expect(reopened.artifact.data == Data("report".utf8) && reopened.artifact.filename == "report.txt")
        }
    }

    @Test func thePurgeRunsOnceAndLeavesLaterOpensUnchanged() async throws {
        try await withCacheRoot { root, own in
            let legacy = try writeLegacyCache(at: root)
            let first = own(ArtifactCache(root: root))
            first.prune(reachableConfigurationIDs: [legacy.scope.configurationID])
            try await first.drainMaintenance(); await first.close()
            #expect(try userVersion(in: root) == 2)
            let purged = try entries(in: root)
            #expect(purged.map(\.kind) == [1, 3])
            let second = own(ArtifactCache(root: root))
            second.prune(reachableConfigurationIDs: [legacy.scope.configurationID])
            try await second.drainMaintenance(); await second.close()
            let after = try entries(in: root)
            #expect(after.map(\.payload) == purged.map(\.payload) && after.map(\.accessed) == purged.map(\.accessed))
            #expect(try userVersion(in: root) == 2)
            #expect(try await own(ArtifactCache(root: root)).session(scope: legacy.scope).original(for: legacy.key)?.artifact.data == Data("report".utf8))
        }
    }

    @Test func anInterruptedPurgeFinishesRemovingFilesOnTheNextOpen() async throws {
        try await withCacheRoot { root, own in
            let legacy = try writeLegacyCache(at: root)
            // The rows were removed and the version committed, but the app stopped before removing files.
            var handle: OpaquePointer?
            try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
            #expect(sqlite3_exec(handle, "BEGIN; DELETE FROM entries WHERE kind IN (0,2); PRAGMA user_version=2; COMMIT", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(handle)
            #expect(try files(in: root).contains(legacy.thumbnail))
            let session = own(ArtifactCache(root: root)).session(scope: legacy.scope)
            #expect(try await session.original(for: legacy.key)?.artifact.data == Data("report".utf8))
            let names = try files(in: root)
            #expect(names.contains(legacy.original))
            #expect(!names.contains(legacy.thumbnail) && !names.contains("metadata-recovery.plist"))
        }
    }

    @Test func aFailedPurgeKeepsTheOldCacheWholeUntilTheNextOpen() async throws {
        try await withCacheRoot { root, own in
            let legacy = try writeLegacyCache(at: root)
            var handle: OpaquePointer?
            try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            #expect(sqlite3_exec(handle, "CREATE TRIGGER reject_purge BEFORE DELETE ON entries WHEN OLD.kind=2 BEGIN SELECT RAISE(ABORT,'injected purge failure'); END", nil, nil, nil) == SQLITE_OK)
            let failing = own(ArtifactCache(root: root))
            await #expect(throws: (any Error).self) { _ = try await failing.session(scope: legacy.scope).original(for: legacy.key) }
            #expect(try userVersion(in: root) == 1)
            #expect(try entries(in: root).map(\.kind) == [0, 1, 2, 3])
            #expect(try files(in: root).isSuperset(of: [legacy.original, legacy.thumbnail, "metadata-recovery.plist"]))
            #expect(sqlite3_exec(handle, "DROP TRIGGER reject_purge", nil, nil, nil) == SQLITE_OK)
            await failing.close()
            #expect(try await own(ArtifactCache(root: root)).session(scope: legacy.scope).original(for: legacy.key)?.artifact.data == Data("report".utf8))
            #expect(try entries(in: root).map(\.kind) == [1, 3])
        }
    }

    @Test func aFreshInstallCreatesTheCurrentSchema() async throws {
        try await withCacheRoot { root, own in
            let (_, scope, key) = try fixture()
            let session = own(ArtifactCache(root: root)).session(scope: scope)
            try await session.retainOriginal(bytes, for: key)
            #expect(try userVersion(in: root) == 2)
            #expect(try await session.original(for: key)?.artifact.data == Data("report".utf8))
        }
    }

    @Test func aCorruptDatabaseStaysUntouchedAndUnavailable() async throws {
        try await withCacheRoot { root, own in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("index.sqlite"), garbage = Data(repeating: 0x5A, count: 4_096)
            try garbage.write(to: url)
            let (_, scope, key) = try fixture()
            let cache = own(ArtifactCache(root: root))
            await #expect(throws: (any Error).self) { _ = try await cache.session(scope: scope).original(for: key) }
            #expect(try Data(contentsOf: url) == garbage)
        }
    }

    // Derived without the app's encoder. A change strands every saved capture.
    private func persistedFormat(_ shape: String) -> (scope: ArtifactCacheScope, namespace: Data, digest: String) {
        let configuration = UUID(uuidString: "12345678-ABCD-4EF0-8123-456789ABCDEF")!
        switch shape {
        case "tagged":
            return (ArtifactCacheScope(configurationID: configuration, serverURL: Data("https://é.example".utf8), installationID: Data("install".utf8), username: Data([0xFF, 0x00]) + Data("user".utf8), provider: Data("native".utf8)),
                    hex("""
                        0000000000000024 31323334353637382d414243442d344546302d383132332d343536373839414243444546
                        0000000000000012 68747470733a2f2fc3a92e6578616d706c65
                        0000000000000008 01696e7374616c6c
                        0000000000000006 ff0075736572
                        0000000000000007 016e6174697665
                        """),
                    "26db3b5c3ab9765bebc814f437f047e317681c97565e9f12abf60aed9d9be2d7")
        case "absent":
            return (ArtifactCacheScope(configurationID: configuration, serverURL: Data("https://cache.example".utf8), installationID: nil, username: Data(), provider: nil),
                    hex("""
                        0000000000000024 31323334353637382d414243442d344546302d383132332d343536373839414243444546
                        0000000000000015 68747470733a2f2f63616368652e6578616d706c65
                        0000000000000001 00
                        0000000000000000
                        0000000000000001 00
                        """),
                    "8f9661b7a6d54f64c6541a56fafe07b325d458177a1680b04c365ebdfaa12fc0")
        default:
            return (ArtifactCacheScope(configurationID: configuration, serverURL: Data("https://cache.example".utf8), installationID: Data(), username: Data(), provider: Data()),
                    hex("""
                        0000000000000024 31323334353637382d414243442d344546302d383132332d343536373839414243444546
                        0000000000000015 68747470733a2f2f63616368652e6578616d706c65
                        0000000000000001 01
                        0000000000000000
                        0000000000000001 01
                        """),
                    "be983f58d153729d1890cd7abdd8707e462bdd657fa9b25456d6f8959821089c")
        }
    }
    private func hex(_ text: String) -> Data {
        let digits = text.compactMap(\.hexDigitValue)
        return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(digits[$0] << 4 | digits[$0 + 1]) })
    }
    /// Length-prefixed fields, as saved capture keys have always been written.
    private static func captureKey(_ key: ArtifactOriginalKey) -> Data {
        var result = Data()
        for field in [key.identity.profile.bytes, key.identity.root.bytes, key.identity.stored.bytes, key.messageID, key.path, key.sourceRevision] {
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(field)
        }
        return result
    }
    private func entries(in root: URL) throws -> [(kind: Int, scope: Data, configuration: Data, key: Data, payload: Data, accessed: Double)] {
        var handle: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        try #require(sqlite3_prepare_v2(handle, "SELECT kind,scope,configuration,key,payload,accessed FROM entries ORDER BY kind,key", -1, &statement, nil) == SQLITE_OK)
        func blob(_ column: Int32) -> Data { Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column))) }
        var rows: [(kind: Int, scope: Data, configuration: Data, key: Data, payload: Data, accessed: Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((Int(sqlite3_column_int64(statement, 0)), blob(1), blob(2), blob(3), blob(4), sqlite3_column_double(statement, 5)))
        }
        return rows
    }
    private func userVersion(in root: URL) throws -> Int {
        var handle: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        try #require(sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
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
