import Foundation
import Testing
import SQLite3
import BottoCore
@testable import Botto

@MainActor struct ArtifactCacheTests {
    @Test(arguments: ["discard", "prune"], [false, true])
    func queuedCleanupPreservesNewLeaseGuardsAndRetiresOldWriters(cleanup: String, existingGuard: Bool) async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root); _ = own(cache)
            let old = cache.session(scope: scope)
            try await old.upsert(.init(identity: key.identity, botName: "Bot", title: "Main", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            try await old.retainOriginal(bytes, for: key)
            if existingGuard { try old.invalidateMetadata([(key.identity.profile, key.identity.root)]) }
            if cleanup == "discard" { cache.discard(configurationID: scope.configurationID) }
            else { cache.prune(reachableConfigurationIDs: []) }
            #expect(throws: (any Error).self) { try old.invalidateMetadata([(key.identity.profile, key.identity.root)]) }
            let current = cache.session(scope: scope)
            try current.invalidateMetadata([(key.identity.profile, key.identity.root)])
            #expect(try await current.metadataRecovery().contains(key.identity))
            try await cache.drainMaintenance()
            #expect(try await current.metadataRecovery().contains(key.identity))
            #expect(try await current.loadChats().isEmpty)
            #expect(try await current.original(for: key) == nil)
            await cache.close()
            let cold = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await cold.metadataRecovery().contains(key.identity))
            #expect(try await cold.original(for: key) == nil)
        }
    }

    @Test(arguments: ["none", "existing", "newer"], [false, true])
    func captureRollbackPreservesOnlyPreviouslyRequiredMetadataGuards(guardKind: String, pending: Bool) async throws {
        try await withCacheRoot { root, own in
            let (_, scope, key) = try fixture()
            let second = SessionIdentity(profile: key.identity.profile, root: try ExactID("second"), stored: try ExactID("second"), aliases: [])
            let warm = own(ArtifactCache(root: root)), warmSession = warm.session(scope: scope)
            for source in [key.identity, second] {
                try await warmSession.upsert(.init(identity: source, botName: "Bot", title: source.root.text,
                    messages: [.init(id: "saved", role: .assistant, text: "Saved needle")], updatedAt: nil,
                    coverage: .complete, summary: nil, headFingerprint: nil))
            }
            try await warmSession.retainOriginal(bytes, for: key); await warm.close()
            // A smaller retained roster forces kind0 eviction during capture
            // while leaving ample byte/page capacity to reach the commit gate.
            var limits = ArtifactCache.Limits(); limits.chatCount = 1
            let gate = CaptureCommitGate(); defer { gate.release() }
            let cache = own(ArtifactCache(root: root, limits: limits, beforeCaptureCommit: { gate.pause() }))
            let session = cache.session(scope: scope)
            try #require(try await session.loadChats().count == 2)
            if guardKind == "existing" { try session.invalidateMetadata([(key.identity.profile, key.identity.root)]) }
            let next = ArtifactOriginalKey(identity: second, messageID: Data("new".utf8), path: Data("/new.txt".utf8), sourceRevision: Data("revision".utf8))
            let admission = ArtifactCaptureAdmission(), consumer = UUID(); admission.register(consumer)
            gate.arm()
            let saving = Task { try await session.retainOriginal(bytes, for: next, admission: admission) }
            defer { saving.cancel(); admission.revokeAll() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
            try #require(gate.isEntered)
            #expect(try await session.metadataRecovery().contains(key.identity), "The SQL transaction must really have staged A's eviction.")
            if guardKind == "newer" { try session.invalidateMetadata([(key.identity.profile, key.identity.root)]) }
            if pending { admission.setReady(false, for: consumer) } else { admission.revokeAll() }
            gate.release()
            if pending {
                #expect(try await session.original(for: next) == nil)
                #expect(try await session.metadataRecovery().contains(key.identity) == (guardKind != "none"))
                saving.cancel(); admission.revokeAll()
            }
            await #expect(throws: (any Error).self) { _ = try await saving.value }
            #expect(try await session.metadataRecovery().contains(key.identity) == (guardKind != "none"))
            await cache.close()
            let cold = own(ArtifactCache(root: root)).session(scope: scope)
            let rows = try await cold.loadChats()
            #expect(rows.contains { $0.identity == key.identity } == (guardKind == "none"))
            #expect(rows.contains { $0.identity == second })
            #expect(try await cold.original(for: key)?.artifact.data == bytes.data)
            #expect(try await cold.original(for: next) == nil)
        }
    }

    @Test func speculativeEvictionQuotaFailureCannotQuarantineRestoredMetadata() async throws {
        try await withCacheRoot { root, own in
            let (_, scope, key) = try fixture()
            let warm = own(ArtifactCache(root: root)), warmSession = warm.session(scope: scope)
            try await warmSession.upsert(.init(identity: key.identity, botName: "Bot", title: "Main", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            await warm.close()
            var limits = ArtifactCache.Limits(); limits.chatCount = 0
            let cache = own(ArtifactCache(root: root, limits: limits)), session = cache.session(scope: scope)
            try #require(try await session.loadChats().count == 1)
            await #expect(throws: (any Error).self) { _ = try await session.retainOriginal(bytes, for: key) }
            #expect(try await !session.metadataRecovery().all)
            #expect(try await session.metadataRecovery().invalidated.isEmpty)
            await cache.close()
            let cold = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await cold.loadChats().map(\.identity) == [key.identity])
            #expect(try await cold.original(for: key) == nil)
        }
    }

    @Test func anOlderSuccessfulSQLWriteCannotClearANewerGuard() async throws {
        try await withCacheRoot { root, own in
            let gate = CaptureCommitGate(); defer { gate.release() }
            let (_, scope, key) = try fixture()
            let cache = own(ArtifactCache(root: root, beforeMetadataWrite: { gate.pause() })), session = cache.session(scope: scope)
            let old = CachedArtifactChat(identity: key.identity, botName: "Bot", title: "Main",
                messages: [.init(id: "old", role: .assistant, text: "MEDIA:/old.txt")], updatedAt: nil,
                coverage: .complete, summary: nil, headFingerprint: nil)
            gate.arm()
            let saving = Task { try await session.upsert(old) }; defer { saving.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
            try #require(gate.isEntered)
            let guardURL = root.appendingPathComponent("metadata-recovery.plist")
            let durableGuard = try Data(contentsOf: guardURL)
            try session.invalidateMetadata([(key.identity.profile, key.identity.root, UUID())])
            #expect(try Data(contentsOf: guardURL) == durableGuard, "A new dirty token reuses the same durable identity guard.")
            #expect(try await session.metadataRecovery().contains(key.identity))
            gate.release(); try await saving.value
            #expect(try await session.metadataRecovery().contains(key.identity))
            await cache.close()
            let reopened = own(ArtifactCache(root: root))
            #expect(try await reopened.session(scope: scope).loadChats().isEmpty)
            #expect(try await reopened.session(scope: scope).metadataRecovery().contains(key.identity))
        }
    }

    @Test func replacingADisjointFullRosterFitsTheRecoveryCountBound() async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.chatCount = 1
            let (_, scope, key) = try fixture()
            let cache = own(ArtifactCache(root: root, limits: limits)), session = cache.session(scope: scope)
            let next = SessionIdentity(profile: key.identity.profile, root: try ExactID("next"), stored: try ExactID("next"), aliases: [])
            try await session.upsert(.init(identity: key.identity, botName: "Bot", title: "Old", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            try session.invalidateMetadata([(key.identity.profile, key.identity.root), (next.profile, next.root)])
            let recovery = try await session.metadataRecovery()
            #expect(!recovery.all && recovery.invalidated.count == 2)
            try await session.deleteChat(profile: key.identity.profile, root: key.identity.root)
            try await session.upsert(.init(identity: next, botName: "Bot", title: "Next", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            #expect(try await session.loadChats().map(\.identity) == [next])
            #expect(try await session.metadataRecovery().contains(key.identity))
            #expect(try await !session.metadataRecovery().contains(next))
        }
    }

    @Test func recoveryOverflowIsBoundedAndConfirmedDiscardAllowsANewConnection() async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.chatCount = 1
            let (unused, scope, key) = try fixture(); _ = own(unused)
            let cache = own(ArtifactCache(root: root, limits: limits)), session = cache.session(scope: scope)
            try await session.retainOriginal(bytes, for: key)
            #expect(throws: (any Error).self) {
                try session.invalidateMetadata([(key.identity.profile, key.identity.root),
                    (key.identity.profile, try ExactID("another")), (key.identity.profile, try ExactID("third"))])
            }
            #expect(try await session.metadataRecovery().all)
            let ledgerBytes = try #require(try root.appendingPathComponent("metadata-recovery.plist").resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(ledgerBytes <= 256 * 1_024)
            #expect(try await session.original(for: key)?.artifact.data == bytes.data)
            cache.discard(configurationID: scope.configurationID); try await cache.drainMaintenance()
            let freshScope = ArtifactCacheScope(configurationID: UUID(), serverURL: scope.serverURL,
                installationID: nil, username: Data(), provider: nil)
            let fresh = cache.session(scope: freshScope)
            #expect(try await !fresh.metadataRecovery().all)
            try await fresh.upsert(.init(identity: key.identity, botName: "Bot", title: "Fresh", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            #expect(try await fresh.loadChats().count == 1)
        }
    }

    @Test func failedMetadataWritesRemainScopedAndUntrustedAcrossIndependentReopen() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root); _ = own(cache)
            let session = cache.session(scope: scope)
            let other = SessionIdentity(profile: key.identity.profile, root: try ExactID("other"), stored: try ExactID("other"), aliases: [])
            let old = CachedArtifactChat(identity: key.identity, botName: "Bot", title: "Main",
                messages: [.init(id: "old", role: .assistant, text: "MEDIA:/old.txt")], updatedAt: nil,
                coverage: .complete, summary: nil, headFingerprint: Data("old head".utf8))
            let kept = CachedArtifactChat(identity: other, botName: "Bot", title: "Other", messages: [], updatedAt: nil,
                coverage: .complete, summary: nil, headFingerprint: nil)
            try await session.upsert(old); try await session.upsert(kept)
            let otherScope = ArtifactCacheScope(configurationID: scope.configurationID, serverURL: scope.serverURL,
                installationID: scope.installationID, username: Data("other account".utf8), provider: scope.provider)
            try await cache.session(scope: otherScope).upsert(old)
            try await session.retainOriginal(bytes, for: key)
            var handle: OpaquePointer?
            #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
            defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
            #expect(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
            let revised = CachedArtifactChat(identity: key.identity, botName: "Bot", title: "Main", messages: [],
                updatedAt: nil, coverage: .partial, summary: nil, headFingerprint: nil, removedMessageIDs: [Data("old".utf8)])
            await #expect(throws: (any Error).self) { try await session.upsert(revised) }
            let recovery = try await session.metadataRecovery()
            #expect(recovery.contains(key.identity) && !recovery.contains(other))
            let hints = try await session.metadataRecoveryHints()
            #expect(hints.first?.identity == key.identity)
            #expect(hints.first?.unavailableMessageIDs == [Data("old".utf8)])
            #expect(try await !cache.session(scope: otherScope).metadataRecovery().contains(key.identity))
            await cache.close()
            #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            let reopenedCache = own(ArtifactCache(root: root)), reopened = reopenedCache.session(scope: scope)
            #expect(try await reopened.loadChats().map(\.identity) == [other])
            #expect(try await reopenedCache.session(scope: otherScope).loadChats().map(\.identity) == [key.identity])
            #expect(try await reopened.original(for: key)?.artifact.data == bytes.data)
            try await reopened.upsert(revised)
            #expect(try await !reopened.metadataRecovery().contains(key.identity))
            #expect(try await reopened.loadChats().first { $0.identity == key.identity }?.headFingerprint == nil)
        }
    }

    @Test func anUnreadableRecoveryLedgerPreservesBytesAndBlocksOldMetadata() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root); _ = own(cache)
            let session = cache.session(scope: scope)
            let row = CachedArtifactChat(identity: key.identity, botName: "Bot", title: "Main", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil)
            try await session.upsert(row); try await session.retainOriginal(bytes, for: key)
            let ledger = root.appendingPathComponent("metadata-recovery.plist"), damaged = Data("unknown recovery bytes".utf8)
            try damaged.write(to: ledger)
            #expect(try await session.metadataRecovery().all)
            #expect(try await session.loadChats().isEmpty)
            await #expect(throws: (any Error).self) { try await session.upsert(row) }
            #expect(try Data(contentsOf: ledger) == damaged)
            #expect(try await session.original(for: key)?.artifact.data == bytes.data)
        }
    }

    @Test(arguments: [false, true])
    func pendingPublicationReleasesTheBackendAndEitherResumesOrCancelsAcrossReopen(cancel: Bool) async throws {
        try await withCacheRoot { root, own in
            let gate = CaptureCommitGate()
            defer { gate.release() }
            let (_, scope, key) = try fixture()
            let cache = own(ArtifactCache(root: root, beforeCaptureCommit: { gate.pause() }))
            let session = cache.session(scope: scope), admission = ArtifactCaptureAdmission(), consumer = UUID()
            admission.register(consumer)
            gate.arm()
            let saving = Task { try await session.retainOriginal(bytes, for: key, admission: admission) }
            defer { saving.cancel(); admission.revokeAll() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
            try #require(gate.isEntered)
            admission.setReady(false, for: consumer); gate.release()
            #expect(try await session.original(for: key) == nil, "Pending publication must rollback and release the cache actor.")
            if cancel {
                saving.cancel()
                await #expect(throws: (any Error).self) { _ = try await saving.value }
            } else {
                admission.setReady(true, for: consumer)
                #expect(try await saving.value != nil)
            }
            await cache.close()
            let reopened = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await reopened.original(for: key)?.artifact.data == (cancel ? nil : bytes.data))
        }
    }

    @Test func retiringTheLeaseBeforeCommitRestoresThePreviousCaptureOnReopen() async throws {
        try await withCacheRoot { root, own in
            let gate = CaptureCommitGate()
            defer { gate.release() }
            let (_, scope, key) = try fixture()
            let cache = own(ArtifactCache(root: root, beforeCaptureCommit: { gate.pause() }))
            let session = cache.session(scope: scope)
            let digest = try #require(try await session.retainOriginal(bytes, for: key))
            gate.arm()
            let replacing = Task { try await session.retainOriginal(.init(data: Data("replacement".utf8), filename: "report.txt", mimeType: "text/plain"), for: key) }
            defer { replacing.cancel(); gate.release() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
            try #require(gate.isEntered)
            session.retire()
            gate.release()
            await #expect(throws: (any Error).self) { _ = try await replacing.value }
            await cache.close()
            let reopened = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await reopened.original(for: key)?.artifact.data == Data("report".utf8))
            #expect(try await reopened.originalDigest(for: key) == digest)
        }
    }

    @Test(arguments: [false, true])
    func rejectedCaptureAdmissionKeepsThePreviousBytesAndDigestAcrossReopen(evictionFails: Bool) async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.metadataBytes = 4_000
            let (cache, scope, key) = try fixture(root: root, limits: limits)
            _ = own(cache)
            let session = cache.session(scope: scope)
            let previousDigest = try #require(try await session.retainOriginal(bytes, for: key))
            var handle: OpaquePointer?
            #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            if evictionFails {
                #expect(sqlite3_exec(handle, "CREATE TRIGGER reject_eviction BEFORE DELETE ON entries WHEN OLD.kind=1 BEGIN SELECT RAISE(ABORT,'injected eviction failure'); END", nil, nil, nil) == SQLITE_OK)
            }
            await #expect(throws: (any Error).self) {
                _ = try await session.retainOriginal(.init(data: Data("replacement".utf8),
                    filename: String(repeating: "metadata", count: 1_000), mimeType: "text/plain"), for: key)
            }
            if evictionFails { #expect(sqlite3_exec(handle, "DROP TRIGGER reject_eviction", nil, nil, nil) == SQLITE_OK) }
            await cache.close()
            let reopened = own(ArtifactCache(root: root, limits: limits)).session(scope: scope)
            #expect(try await reopened.original(for: key)?.artifact.data == Data("report".utf8))
            #expect(try await reopened.originalDigest(for: key) == previousDigest)
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

    @Test func replacementRejectedByRowOverheadReportsQuotaAfterRemovingTheOldRow() async throws {
        try await withCacheRoot { root, own in
            let chat = try ExactID("chat")
            let source = SessionIdentity(profile: try ExactID("bot"), root: chat, stored: chat, aliases: [chat])
            let revised = CachedArtifactChat(identity: source, botName: "Bot", title: String(repeating: "t", count: 1_000),
                messages: [.init(id: "report", role: .assistant, text: "Report ready")], updatedAt: nil,
                coverage: .complete, summary: nil, headFingerprint: nil)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            var limits = ArtifactCache.Limits(); limits.metadataBytes = try encoder.encode(revised).count + 64
            let (cache, scope, _) = try fixture(root: root, limits: limits)
            _ = own(cache)
            let session = cache.session(scope: scope)
            try await session.upsert(.init(identity: source, botName: "Bot", title: "Old",
                messages: [.init(id: "report", role: .assistant, text: "MEDIA:/deleted.txt")], updatedAt: nil,
                coverage: .complete, summary: nil, headFingerprint: nil))
            #expect(try await session.loadChats().count == 1)
            await #expect(throws: (any Error).self) { try await session.upsert(revised) }
            await cache.close()
            let reopened = own(ArtifactCache(root: root, limits: limits)).session(scope: scope)
            #expect(try await reopened.loadChats().isEmpty)
        }
    }

    @Test func rejectedReplacementCannotRestoreADeletedOutputOnReopen() async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits()
            limits.metadataBytes = 4_000
            let (cache, scope, key) = try fixture(root: root, limits: limits)
            _ = own(cache)
            let session = cache.session(scope: scope)
            try await session.upsert(.init(identity: key.identity, botName: "Bot", title: "Report",
                messages: [.init(id: "report", role: .assistant, text: "MEDIA:/deleted.txt")],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            #expect(try await session.loadChats().count == 1)
            await #expect(throws: (any Error).self) {
                try await session.upsert(.init(identity: key.identity, botName: "Bot",
                    title: String(repeating: "metadata", count: 1_000),
                    messages: [.init(id: "report", role: .assistant, text: "Report ready")],
                    updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            }
            await cache.close()
            let reopened = own(ArtifactCache(root: root, limits: limits)).session(scope: scope)
            #expect(try await reopened.loadChats().isEmpty)
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
