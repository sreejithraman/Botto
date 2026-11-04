import Foundation
import Testing
import SQLite3
import BottoCore
@testable import Botto

@MainActor struct ArtifactCacheTests {
    @Test func pendingRosterRestrictionsSurviveReentryAndPreserveOtherChats() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root); _ = own(cache)
            let session = cache.session(scope: scope)
            let sibling = SessionIdentity(profile: key.identity.profile, root: try ExactID("sibling"), stored: try ExactID("sibling"), aliases: [])
            let peer = SessionIdentity(profile: try ExactID("peer"), root: try ExactID("main"), stored: try ExactID("main"), aliases: [])
            for identity in [key.identity, sibling, peer] {
                try await session.upsert(.init(identity: identity, botName: "Bot", title: "Old", messages: [],
                    updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            }
            try await session.retainOriginal(bytes, for: key)
            try session.restrictMetadata(to: [peer.profile])
            try session.restrictMetadata(to: [peer.profile, key.identity.profile])
            await cache.close()
            let cold = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await cold.loadChats().map(\.identity) == [peer])
            #expect(try await cold.original(for: key)?.artifact.data == bytes.data)
            try await cold.upsert(.init(identity: key.identity, botName: "Bot", title: "Fresh", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            let rows = try await cold.loadChats()
            #expect(rows.count == 2 && rows.contains { $0.identity == peer })
            #expect(rows.first { $0.identity == key.identity }?.title == "Fresh")
            #expect(try await cold.metadataRecovery().contains(sibling))
            #expect(try await cold.metadataRecovery().withholdsBookSeed(key.identity))
            #expect(try await !cold.metadataRecovery().contains(key.identity))
            try cold.restrictMetadata(to: [peer.profile, key.identity.profile, try ExactID("another")])
            #expect(try await cold.loadChats().first { $0.identity == key.identity }?.title == "Fresh")
            try cold.restrictMetadata(to: [peer.profile])
            try cold.restrictMetadata(to: [peer.profile, key.identity.profile])
            #expect(try await cold.loadChats().map(\.identity) == [peer])
        }
    }

    @Test func aDelayedOldRevisionCannotReplaceANewerCheckedSave() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root); _ = own(cache)
            let session = cache.session(scope: scope), oldRevision = UUID()
            let old = CachedArtifactChat(identity: key.identity, botName: "Bot", title: "Old", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil)
            try session.invalidateMetadata([(key.identity.profile, key.identity.root, oldRevision)])
            try session.restrictMetadata(to: [])
            try await session.upsert(.init(identity: key.identity, botName: "Bot", title: "Fresh", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            await #expect(throws: (any Error).self) { try await session.upsert(old, revision: oldRevision) }
            #expect(try await session.loadChats().first?.title == "Fresh")
            await cache.close()
            #expect(try await own(ArtifactCache(root: root)).session(scope: scope).loadChats().first?.title == "Fresh")
        }
    }

    @Test func aPausedMetadataWriterCannotClearARosterWithdrawal() async throws {
        try await withCacheRoot { root, own in
            let gate = CaptureCommitGate(); defer { gate.release() }
            let (_, scope, key) = try fixture()
            let cache = own(ArtifactCache(root: root, beforeMetadataWrite: { gate.pause() })), session = cache.session(scope: scope)
            let old = CachedArtifactChat(identity: key.identity, botName: "Bot", title: "Old", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil)
            gate.arm()
            let writing = Task { try await session.upsert(old) }; defer { writing.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
            try #require(gate.isEntered)
            try session.restrictMetadata(to: [])
            gate.release(); try await writing.value
            #expect(try await session.loadChats().isEmpty)
            #expect(try await session.metadataRecovery().contains(key.identity))
            await cache.close()
            let cold = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await cold.loadChats().isEmpty)
            try await cold.upsert(.init(identity: key.identity, botName: "Bot", title: "Fresh", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            #expect(try await cold.loadChats().first?.title == "Fresh")
        }
    }

    @Test func aWriterAwaitingSQLiteAcquisitionCannotClearARosterWithdrawal() async throws {
        try await withCacheRoot { root, own in
            let (warm, scope, key) = try fixture(root: root); _ = own(warm)
            let row = CachedArtifactChat(identity: key.identity, botName: "Bot", title: "Old", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil)
            try await warm.session(scope: scope).upsert(row); await warm.close()
            var handle: OpaquePointer?
            try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
            defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
            try #require(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
            let cache = own(ArtifactCache(root: root)), session = cache.session(scope: scope)
            let writing = Task { try await session.upsert(row) }; defer { writing.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            var registered = false
            while !registered, ContinuousClock.now < deadline {
                registered = try await session.metadataRecovery().contains(key.identity)
                await Task.yield()
            }
            try #require(registered)
            try session.restrictMetadata(to: [])
            try #require(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            _ = await writing.result
            await cache.close()
            let cold = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await cold.loadChats().isEmpty)
            #expect(try await cold.metadataRecovery().contains(key.identity))
        }
    }

    @Test(arguments: ["discard", "prune"], [false, true])
    func queuedCleanupPreservesANewLeaseRosterRestriction(cleanup: String, blocked: Bool) async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.metadataBytes = 4_000
            let (cache, scope, key) = try fixture(root: root, limits: limits); _ = own(cache)
            let old = cache.session(scope: scope)
            if blocked {
                let oversized = try Set((0..<100).map { try ExactID("profile-\($0)") })
                #expect(throws: (any Error).self) { try old.restrictMetadata(to: oversized) }
            } else { try old.restrictMetadata(to: []) }
            if cleanup == "discard" { cache.discard(configurationID: scope.configurationID) }
            else { cache.prune(reachableConfigurationIDs: []) }
            #expect(throws: (any Error).self) { try old.restrictMetadata(to: []) }
            let current = cache.session(scope: scope)
            if blocked { #expect(throws: (any Error).self) { try current.restrictMetadata(to: [key.identity.profile]) } }
            else { try current.restrictMetadata(to: [key.identity.profile]) }
            try await cache.drainMaintenance()
            #expect(try await current.metadataRecovery().contains(key.identity))
            await cache.close()
            let cold = own(ArtifactCache(root: root)).session(scope: scope)
            #expect(try await cold.metadataRecovery().contains(key.identity))
            #expect(try await cold.loadChats().isEmpty)
            #expect(try await cold.metadataRecovery().contains(key.identity))
        }
    }

    @Test func rosterRestrictionsUseEveryScopeComponent() async throws {
        let (cache, scope, key) = try fixture()
        let session = cache.session(scope: scope)
        try session.restrictMetadata(to: [])
        let variants = [
            ArtifactCacheScope(configurationID: UUID(), serverURL: scope.serverURL, installationID: scope.installationID, username: scope.username, provider: scope.provider),
            ArtifactCacheScope(configurationID: scope.configurationID, serverURL: Data("https://other.example".utf8), installationID: scope.installationID, username: scope.username, provider: scope.provider),
            ArtifactCacheScope(configurationID: scope.configurationID, serverURL: scope.serverURL, installationID: nil, username: scope.username, provider: scope.provider),
            ArtifactCacheScope(configurationID: scope.configurationID, serverURL: scope.serverURL, installationID: scope.installationID, username: Data("user".utf8), provider: scope.provider),
            ArtifactCacheScope(configurationID: scope.configurationID, serverURL: scope.serverURL, installationID: scope.installationID, username: scope.username, provider: nil)
        ]
        for variant in variants { #expect(try await !cache.session(scope: variant).metadataRecovery().contains(key.identity)) }
        #expect(try await session.metadataRecovery().contains(key.identity))
        await cache.close()
    }

    @Test(arguments: [false, true])
    func aOneChatBudgetCanRetainAndReplaceItsOneChat(excludedProfile: Bool) async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.chatCount = 1
            let (cache, scope, key) = try fixture(root: root, limits: limits); _ = own(cache)
            let session = cache.session(scope: scope)
            try session.restrictMetadata(to: excludedProfile ? [] : [key.identity.profile])
            for title in ["First", "Replacement"] {
                try await session.upsert(.init(identity: key.identity, botName: "Bot", title: title, messages: [],
                    updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
                #expect(try await session.loadChats().first?.title == title)
            }
            await cache.close()
            let cold = own(ArtifactCache(root: root, limits: limits)).session(scope: scope)
            #expect(try await cold.loadChats().first?.title == "Replacement")
        }
    }

    @Test(arguments: ["namespace", "configuration", "all"])
    func recoveryOverflowUsesTheNarrowestDurableMarkerThatFits(fallback: String) async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.chatCount = 1; limits.metadataBytes = 40_000
            let (cache, scope, key) = try fixture(root: root, limits: limits); _ = own(cache)
            let session = cache.session(scope: scope)
            try await session.retainOriginal(bytes, for: key)
            let peerScope = ArtifactCacheScope(configurationID: UUID(), serverURL: scope.serverURL,
                installationID: scope.installationID, username: scope.username, provider: scope.provider)
            let peer = cache.session(scope: peerScope)
            try await peer.upsert(.init(identity: key.identity, botName: "Peer", title: "Peer", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            if fallback != "namespace" {
                for index in 0..<2 {
                    let guardScope = ArtifactCacheScope(configurationID: fallback == "configuration" ? scope.configurationID : UUID(),
                        serverURL: scope.serverURL, installationID: scope.installationID,
                        username: Data("guard-\(index)".utf8), provider: scope.provider)
                    try cache.session(scope: guardScope).restrictMetadata(to: [])
                }
            }
            let observed = try Set((0..<400).map { try ExactID("observed-\($0)") })
            #expect(throws: (any Error).self) { try session.restrictMetadata(to: observed) }
            #expect(try await session.metadataRecovery().all)
            #expect(try await session.original(for: key)?.artifact.data == bytes.data)
            #expect(try Data(contentsOf: root.appendingPathComponent("metadata-recovery.plist")).count <= 10_000)
            await cache.close()
            let coldCache = own(ArtifactCache(root: root, limits: limits)), cold = coldCache.session(scope: scope)
            #expect(try await cold.metadataRecovery().all)
            #expect(try await cold.original(for: key)?.artifact.data == bytes.data)
            let coldPeer = coldCache.session(scope: peerScope)
            #expect(try await coldPeer.metadataRecovery().all == (fallback == "all"))
            #expect(try await coldPeer.loadChats().first?.title == (fallback == "all" ? nil : "Peer"))
            let sameConfiguration = ArtifactCacheScope(configurationID: scope.configurationID, serverURL: scope.serverURL,
                installationID: scope.installationID, username: Data("another-account".utf8), provider: scope.provider)
            #expect(try await coldCache.session(scope: sameConfiguration).metadataRecovery().all == (fallback != "namespace"))
        }
    }

    @Test func oversizedRosterCannotQuarantinePeersOrReplaceTheExistingRestriction() async throws {
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.metadataBytes = 4_000
            let (cache, scope, key) = try fixture(root: root, limits: limits); _ = own(cache)
            let session = cache.session(scope: scope)
            try await session.upsert(.init(identity: key.identity, botName: "Bot", title: "Peer", messages: [],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
            try session.restrictMetadata(to: [key.identity.profile])
            let ledger = root.appendingPathComponent("metadata-recovery.plist")
            let oversized = try Set((0..<100).map { try ExactID("profile-\($0)") })
            let otherScope = ArtifactCacheScope(configurationID: scope.configurationID, serverURL: scope.serverURL,
                installationID: scope.installationID, username: Data("other".utf8), provider: scope.provider)
            let other = cache.session(scope: otherScope)
            #expect(throws: (any Error).self) { try other.restrictMetadata(to: oversized) }
            #expect(try Data(contentsOf: ledger).count <= 1_000)
            #expect(try await other.metadataRecovery().all)
            #expect(try await !session.metadataRecovery().all)
            #expect(try await session.loadChats().map(\.identity) == [key.identity])
        }
    }

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

    @Test(arguments: [false, true])
    func captureRollbackPreservesCheckedSavedChatAdmission(newCanonicalGuard: Bool) async throws {
        try await withCacheRoot { root, own in
            let (_, scope, key) = try fixture()
            let sibling = SessionIdentity(profile: key.identity.profile, root: try ExactID("second"), stored: try ExactID("second"), aliases: [])
            let warm = own(ArtifactCache(root: root)), warmSession = warm.session(scope: scope)
            try warmSession.restrictMetadata(to: [])
            for source in [key.identity, sibling] {
                try await warmSession.upsert(.init(identity: source, botName: "Bot", title: source.root.text,
                    messages: [.init(id: "saved", role: .assistant, text: "Saved")], updatedAt: nil,
                    coverage: .complete, summary: nil, headFingerprint: nil))
            }
            try await warmSession.retainOriginal(bytes, for: key); await warm.close()
            var limits = ArtifactCache.Limits(); limits.chatCount = 2; limits.messageCount = 1
            let gate = CaptureCommitGate(); defer { gate.release() }
            let cache = own(ArtifactCache(root: root, limits: limits, beforeCaptureCommit: { gate.pause() })), session = cache.session(scope: scope)
            try #require(try await session.loadChats().count == 2)
            let next = ArtifactOriginalKey(identity: sibling, messageID: Data("new".utf8), path: Data("/new".utf8), sourceRevision: Data("r2".utf8))
            let admission = ArtifactCaptureAdmission(), consumer = UUID(); admission.register(consumer)
            gate.arm()
            let saving = Task { try await session.retainOriginal(bytes, for: next, admission: admission) }
            defer { saving.cancel(); admission.revokeAll() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
            try #require(gate.isEntered)
            #expect(try await session.metadataRecovery().contains(key.identity))
            if newCanonicalGuard { try session.invalidateMetadata([(key.identity.profile, key.identity.root)]) }
            admission.revokeAll(); gate.release()
            await #expect(throws: (any Error).self) { _ = try await saving.value }
            #expect(try await session.loadChats().contains { $0.identity == key.identity } == !newCanonicalGuard)
            #expect(try await session.metadataRecovery().withholdsBookSeed(key.identity))
            #expect(try await session.original(for: key)?.artifact.data == bytes.data)
            await cache.close()
            let cold = own(ArtifactCache(root: root, limits: limits)).session(scope: scope)
            #expect(try await cold.loadChats().contains { $0.identity == key.identity } == !newCanonicalGuard)
            #expect(try await cold.original(for: key)?.artifact.data == bytes.data)
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
            #expect(hints.first?.unavailableMessageIDs.isEmpty == true)
            #expect(hints.first?.unverifiedMessageIDs == [Data("old".utf8)])
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
            let retrying = own(ArtifactCache(root: root)).session(scope: scope)
            do {
                _ = try await retrying.original(for: key)
                Issue.record("An exclusively locked store should report unavailable")
            } catch {}
            #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
            try await retrying.retryStorage()
            #expect(try await retrying.original(for: key)?.artifact.data == Data("report".utf8))
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

    @Test(arguments: ["unverified-only", "disjoint", "overlap"])
    func metadataCodecKeepsDisputesDistinctAndDowngradesConservatively(shape: String) throws {
        struct OldReader: Decodable { let unavailableMessageIDs: Set<Data>? }
        let source = SessionIdentity(profile: try ExactID("bot"), root: try ExactID("chat"), stored: try ExactID("chat"), aliases: [])
        let uncertain = Data("uncertain".utf8)
        let disputed: Set<Data>? = shape == "unverified-only" ? nil : [shape == "overlap" ? uncertain : Data("disputed".utf8)]
        let unverified: Set<Data> = [uncertain]
        let blocked = (disputed ?? []).union(unverified)
        let record = CachedArtifactChat(identity: source, botName: "Bot", title: "Main", messages: [],
            updatedAt: nil, coverage: .partial, summary: nil, headFingerprint: nil,
            unavailableMessageIDs: disputed, unverifiedMessageIDs: unverified)
        let encoded = try JSONEncoder().encode(record)
        let restored = try JSONDecoder().decode(CachedArtifactChat.self, from: encoded)
        #expect(restored.unavailableMessageIDs == disputed)
        #expect(restored.unverifiedMessageIDs == unverified)
        #expect(restored.excludedMessageIDs == blocked)
        #expect(restored.retainedEvidenceCount == blocked.count)
        #expect(restored.retainedEvidenceBytes == blocked.reduce(0) { $0 + $1.count })
        let old = try JSONDecoder().decode(OldReader.self, from: encoded)
        #expect(old.unavailableMessageIDs == blocked)
        var downgraded = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        downgraded.removeValue(forKey: "disputedMessageIDs")
        downgraded.removeValue(forKey: "unverifiedMessageIDs")
        let afterDowngrade = try JSONDecoder().decode(CachedArtifactChat.self,
            from: JSONSerialization.data(withJSONObject: downgraded))
        #expect(afterDowngrade.excludedMessageIDs == blocked)
        #expect(afterDowngrade.unavailableMessageIDs == blocked)
        #expect(afterDowngrade.unverifiedMessageIDs == nil)
    }

    @Test func legacyMetadataCodecKeepsUnavailableIDsAsActualDisputes() throws {
        let source = SessionIdentity(profile: try ExactID("bot"), root: try ExactID("chat"), stored: try ExactID("chat"), aliases: [])
        let disputed = Data("disputed".utf8), removed = Data("removed".utf8)
        let record = CachedArtifactChat(identity: source, botName: "Bot", title: "Main", messages: [],
            updatedAt: nil, coverage: .partial, summary: nil, headFingerprint: nil,
            unavailableMessageIDs: [disputed], removedMessageIDs: [removed])
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        legacy.removeValue(forKey: "disputedMessageIDs")
        legacy.removeValue(forKey: "unverifiedMessageIDs")
        let restored = try JSONDecoder().decode(CachedArtifactChat.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.unavailableMessageIDs == [disputed])
        #expect(restored.unverifiedMessageIDs == nil)
        #expect(restored.excludedMessageIDs == [disputed, removed])
    }

    @Test func recoveryHintsKeepActualDisputesSeparateFromAllUnverifiedRows() async throws {
        try await withCacheRoot { root, own in
            let (cache, scope, key) = try fixture(root: root); _ = own(cache)
            let session = cache.session(scope: scope)
            let disputed = Data("disputed".utf8), uncertain = Data("not-in-retained-messages".utf8)
            let record = CachedArtifactChat(identity: key.identity, botName: "Bot", title: "Main",
                messages: [.init(id: "saved-old-row", role: .assistant, text: "Saved reply")],
                updatedAt: nil, coverage: .partial, summary: nil, headFingerprint: nil,
                unavailableMessageIDs: [disputed], unverifiedMessageIDs: [uncertain])
            try await session.upsert(record)
            try session.invalidateMetadata([(key.identity.profile, key.identity.root)])
            let hints = try await session.metadataRecoveryHints()
            let hint = try #require(hints.first)
            #expect(hint.unavailableMessageIDs == [disputed])
            #expect(hint.unverifiedMessageIDs == [Data("saved-old-row".utf8), uncertain])
        }
    }

    @Test(arguments: ["tagged", "absent", "empty"])
    func persistedScopeChatAndGuardBytesKeepTheirEstablishedFormat(shape: String) async throws {
        let format = persistedFormat(shape)
        let root = try ExactID("cafe\u{301}"), identity = SessionIdentity(profile: try ExactID("bót"), root: root, stored: root, aliases: [])
        let chat = hex("""
            0000000000000004 62c3b374
            0000000000000006 63616665cc81
            """)
        let chatDigest = hex("30216996d68e57e6c533ad6ba80e445c8b8eec59edf4663e6e854b5cc52470c2")
        let original = "1-" + format.digest + "-845e91831319e89c4d656bdb80c278ac09a7230d61e5dfd2e1b1fbb436ac8917"
        #expect(ArtifactMetadataRecovery.key(identity) == chatDigest)
        try await withCacheRoot { directory, own in
            var limits = ArtifactCache.Limits(); limits.chatCount = 1
            let cache = own(ArtifactCache(root: directory, limits: limits)), session = cache.session(scope: format.scope)
            try await session.upsert(savedChat(identity))
            let key = ArtifactOriginalKey(identity: identity, messageID: Data("message".utf8), path: Data("/report".utf8), sourceRevision: Data("r1".utf8))
            try await session.retainOriginal(bytes, for: key)
            let rows = try savedChatRows(in: directory)
            #expect(rows.map(\.scope) == [format.namespace])
            #expect(rows.map(\.configuration) == [Data("12345678-ABCD-4EF0-8123-456789ABCDEF".utf8)])
            #expect(rows.map(\.key) == [chat])
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(original).path))

            let peer = ArtifactCacheScope(configurationID: UUID(), serverURL: format.scope.serverURL, installationID: format.scope.installationID, username: format.scope.username, provider: format.scope.provider)
            try await cache.session(scope: peer).upsert(savedChat(identity))
            let entries = try #require(try recoveryLedger(in: directory)["entries"] as? [[String: Any]])
            #expect(entries.count == 1)
            #expect(entries.first?["configuration"] as? String == "12345678-ABCD-4EF0-8123-456789ABCDEF")
            #expect(entries.first?["namespace"] as? Data == hex(format.digest))
            #expect(entries.first?["chat"] as? Data == chatDigest)
            try session.restrictMetadata(to: [identity.profile])
            let namespaces = try #require(try recoveryLedger(in: directory)["namespaces"] as? [[String: Any]])
            #expect(namespaces.map { $0["namespace"] as? Data } == [hex(format.digest)])
            await cache.close()
            #expect(try await own(ArtifactCache(root: directory)).session(scope: format.scope).metadataRecovery().invalidated == [chatDigest])
        }
    }

    @Test(arguments: ["configuration", "server", "installation", "absent installation", "empty installation", "username", "provider", "absent provider", "empty provider", "unicode", "field boundary"], [false, true])
    func scopeComponentsKeepEvictionAndRosterGuardsPrivateAcrossReopen(component: String, swapped: Bool) async throws {
        let scopes = scopesDiffering(in: component), (evicted, survivor) = swapped ? (scopes.1, scopes.0) : (scopes.0, scopes.1)
        let (_, _, key) = try fixture(), identity = key.identity
        try await withCacheRoot { root, own in
            var limits = ArtifactCache.Limits(); limits.chatCount = 1
            let writer = own(ArtifactCache(root: root, limits: limits))
            try await writer.session(scope: evicted).upsert(savedChat(identity))
            try await writer.session(scope: survivor).upsert(savedChat(identity))
            await writer.close()

            let reopened = own(ArtifactCache(root: root))
            #expect(try await reopened.session(scope: evicted).loadChats().isEmpty)
            #expect(try await reopened.session(scope: survivor).loadChats().map(\.identity) == [identity])
            #expect(try await reopened.session(scope: evicted).metadataRecovery().contains(identity))
            #expect(try await !reopened.session(scope: survivor).metadataRecovery().contains(identity))
            try await reopened.session(scope: survivor).upsert(savedChat(identity))
            try reopened.session(scope: survivor).restrictMetadata(to: [])
            await reopened.close()

            let cold = own(ArtifactCache(root: root))
            let evictedRecovery = try await cold.session(scope: evicted).metadataRecovery()
            let survivorRecovery = try await cold.session(scope: survivor).metadataRecovery()
            #expect(evictedRecovery.invalidated == [ArtifactMetadataRecovery.key(identity)])
            #expect(evictedRecovery.allowedProfiles == nil)
            #expect(survivorRecovery.invalidated.isEmpty)
            #expect(survivorRecovery.allowedProfiles == [])
        }
    }

    private func scopesDiffering(in component: String) -> (ArtifactCacheScope, ArtifactCacheScope) {
        let configuration = UUID()
        func scope(configuration otherConfiguration: UUID? = nil, server: String = "https://cache.example", installation: Data? = Data("install".utf8),
                   username: String = "user", provider: Data? = Data("native".utf8)) -> ArtifactCacheScope {
            ArtifactCacheScope(configurationID: otherConfiguration ?? configuration, serverURL: Data(server.utf8), installationID: installation, username: Data(username.utf8), provider: provider)
        }
        switch component {
        case "configuration": return (scope(), scope(configuration: UUID()))
        case "server": return (scope(), scope(server: "https://other.example"))
        case "installation": return (scope(), scope(installation: Data("other".utf8)))
        case "absent installation": return (scope(installation: nil), scope(installation: Data([0])))
        case "empty installation": return (scope(installation: nil), scope(installation: Data()))
        case "username": return (scope(), scope(username: "other"))
        case "provider": return (scope(), scope(provider: Data("other".utf8)))
        case "absent provider": return (scope(provider: nil), scope(provider: Data([0])))
        case "empty provider": return (scope(provider: nil), scope(provider: Data()))
        case "unicode": return (scope(server: "https://é.example"), scope(server: "https://e\u{301}.example"))
        default: return (scope(installation: Data("installuser".utf8), username: ""), scope())
        }
    }

    // Derived without the app's encoder. A change strands every saved cache row and recovery guard.
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
    private func savedChat(_ identity: SessionIdentity) -> CachedArtifactChat {
        CachedArtifactChat(identity: identity, botName: "Bot", title: "Main", messages: [], updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil)
    }
    private func savedChatRows(in root: URL) throws -> [(scope: Data, configuration: Data, key: Data)] {
        var handle: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        try #require(sqlite3_prepare_v2(handle, "SELECT scope,configuration,key FROM entries WHERE kind=0", -1, &statement, nil) == SQLITE_OK)
        func blob(_ column: Int32) -> Data { Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column))) }
        var rows: [(scope: Data, configuration: Data, key: Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append((blob(0), blob(1), blob(2))) }
        return rows
    }
    private func recoveryLedger(in root: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("metadata-recovery.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
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
