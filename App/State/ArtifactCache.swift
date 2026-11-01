import Foundation
import BottoCore
import SQLite3
import CryptoKit

nonisolated private func artifactCacheFields(_ fields: [Data]) -> Data {
    var result = Data()
    for field in fields {
        var length = UInt64(field.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(field)
    }
    return result
}

nonisolated struct ArtifactMetadataRecovery: Sendable {
    var invalidated = Set<Data>()
    var all = false
    static func key(_ identity: SessionIdentity) -> Data {
        Data(SHA256.hash(data: artifactCacheFields([identity.profile.bytes, identity.root.bytes])))
    }
    func contains(_ identity: SessionIdentity) -> Bool { all || invalidated.contains(Self.key(identity)) }
}

nonisolated struct ArtifactMetadataHint: Sendable {
    let identity: SessionIdentity
    let botName: String
    let title: String
    let updatedAt: Date?
    let unavailableMessageIDs: Set<Data>
    let removedMessageIDs: Set<Data>
    let retiredStoredIDs: Set<Data>
}

nonisolated final class ArtifactCaptureAdmission: @unchecked Sendable {
    enum PublicationError: Error { case pending }
    private let lock = NSLock()
    private var consumers: [UUID: Bool] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private func update(_ mutation: (inout [UUID: Bool]) -> Void) {
        let ready: ([CheckedContinuation<Void, any Error>], Bool)? = lock.withLock {
            mutation(&consumers)
            guard consumers.isEmpty || consumers.values.contains(true) else { return nil }
            let pending = Array(waiters.values); waiters = [:]
            return (pending, !consumers.isEmpty)
        }
        if let (pending, admitted) = ready {
            for waiter in pending {
                if admitted { waiter.resume() } else { waiter.resume(throwing: CancellationError()) }
            }
        }
    }
    func register(_ id: UUID, ready: Bool = true) { update { $0[id] = ready } }
    func setReady(_ ready: Bool, for id: UUID) { update { if $0[id] != nil { $0[id] = ready } } }
    func updateReadiness(_ values: [UUID: Bool]) {
        update { consumers in
            for (id, ready) in values where consumers[id] != nil { consumers[id] = ready }
        }
    }
    func revoke(_ id: UUID) { update { $0[id] = nil } }
    func revokeAll() { update { $0 = [:] } }
    func waitUntilReady() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Bool? = lock.withLock {
                    if Task.isCancelled || consumers.isEmpty { return false }
                    if consumers.values.contains(true) { return true }
                    waiters[id] = continuation; return nil
                }
                if let ready {
                    if ready { continuation.resume() } else { continuation.resume(throwing: CancellationError()) }
                }
            }
        } onCancel: {
            let pending = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            pending?.resume(throwing: CancellationError())
        }
    }
    func claimPublication() throws {
        try lock.withLock {
            guard !consumers.isEmpty else { throw CancellationError() }
            guard consumers.values.contains(true) else { throw PublicationError.pending }
        }
    }
}

nonisolated fileprivate final class ArtifactCacheLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func retire() { lock.withLock { active = false } }
}

nonisolated struct ArtifactCacheScope: Hashable, Codable, Sendable {
    let configurationID: UUID
    let serverURL: Data
    let installationID: Data?
    let username: Data
    let provider: Data?
}
nonisolated enum ArtifactCacheCoverage: String, Codable, Sendable { case complete, partial }
nonisolated struct CachedArtifactChat: Codable, Sendable {
    let identity: SessionIdentity
    let botName: String
    let title: String
    let messages: [ChatMessage]
    let updatedAt: Date?
    let coverage: ArtifactCacheCoverage
    let summary: SessionSummary?
    let headFingerprint: Data?
    var unavailableMessageIDs: Set<Data>? = nil
    var removedMessageIDs: Set<Data>? = nil
    var retiredStoredIDs: Set<Data>? = nil
    var directoryAbsent: Bool? = nil
    var excludedMessageIDs: Set<Data> { (unavailableMessageIDs ?? []).union(removedMessageIDs ?? []) }
    var retainedEvidenceCount: Int { excludedMessageIDs.count + (retiredStoredIDs?.count ?? 0) }
    var retainedEvidenceBytes: Int { excludedMessageIDs.reduce(0) { $0 + $1.count } + (retiredStoredIDs?.reduce(0) { $0 + $1.count } ?? 0) }
}
nonisolated struct ArtifactOriginalKey: Hashable, Codable, Sendable {
    let identity: SessionIdentity
    let messageID: Data
    let path: Data
    let sourceRevision: Data

    // Alias discovery does not create a new captured occurrence.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.persistenceKey == rhs.persistenceKey
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(persistenceKey)
    }
    var persistenceKey: Data {
        artifactCacheFields([identity.profile.bytes, identity.root.bytes, identity.stored.bytes, messageID, path, sourceRevision])
    }
}
nonisolated struct CachedArtifactOriginal: Sendable {
    let artifact: DownloadedArtifact
    let digest: Data
}
nonisolated struct ArtifactThumbnailKey: Hashable, Codable, Sendable {
    let originalDigest: Data
    let maximumPixels: Int
    let decoderVersion: Int
}

// The recovery file has a separate lock from SQLite. Scoped guards can be
// recorded while SQL is busy, and an older write can clear only its own guard.
nonisolated fileprivate final class ArtifactMetadataJournal: @unchecked Sendable {
    fileprivate struct MetadataKey: Hashable, Sendable {
        let configuration: UUID
        let namespace: Data
        let chat: Data
    }
    fileprivate struct MetadataInvalidation: Codable, Hashable, Sendable {
        let configuration: UUID
        let namespace: Data
        let chat: Data
        var key: MetadataKey { MetadataKey(configuration: configuration, namespace: namespace, chat: chat) }
    }
    fileprivate struct MetadataLedger: Codable, Sendable {
        var version = 1
        var all = false
        var entries = Set<MetadataInvalidation>()
        var blockedConfigurations = Set<UUID>()
    }
    struct Checkpoint: Sendable {
        fileprivate let ledger: MetadataLedger?
        fileprivate let revisions: [MetadataKey: UUID]
        fileprivate let quarantines: [UUID: UUID]
        fileprivate let allVersion: UUID
    }
    struct Eviction: Sendable {
        fileprivate let configuration: UUID
        fileprivate let namespace: Data
        fileprivate let chat: Data
        fileprivate let revision: UUID
    }
    private let metadataLedgerName = "metadata-recovery.plist"
    private let root: URL
    private let limits: ArtifactCache.Limits
    private let lock = NSLock()
    private var closed = false
    private var revisions: [MetadataKey: UUID] = [:]
    private var quarantines: [UUID: UUID] = [:]
    private var allVersion = UUID()
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()
    init(root: URL, limits: ArtifactCache.Limits) {
        self.root = root; self.limits = limits; encoder.outputFormat = .binary
    }
    func checkpoint() -> Checkpoint {
        lock.withLock {
            let saved = try? metadataLedger()
            return Checkpoint(ledger: saved?.writable == true ? saved?.value : nil,
                revisions: revisions, quarantines: quarantines, allVersion: allVersion)
        }
    }
    func close() { lock.withLock { closed = true } }
    private func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private func namespace(_ scope: ArtifactCacheScope) -> Data {
        artifactCacheFields([Data(scope.configurationID.uuidString.utf8), scope.serverURL,
            scope.installationID.map { Data([1]) + $0 } ?? Data([0]), scope.username,
            scope.provider.map { Data([1]) + $0 } ?? Data([0])])
    }
    private func chatKey(_ profile: ExactID, _ root: ExactID) -> Data {
        artifactCacheFields([profile.bytes, root.bytes])
    }
    private var recoveryBudget: Int { max(256, min(256 * 1_024, limits.metadataBytes / 4)) }
    private var recoveryCountLimit: Int {
        // A retained roster can replace a disjoint saved roster in one pass.
        let (count, overflow) = max(0, limits.chatCount).multipliedReportingOverflow(by: 2)
        return overflow ? Int.max : count
    }
    private func metadataLedger() throws -> (value: MetadataLedger, writable: Bool) {
        let url = root.appendingPathComponent(metadataLedgerName)
        guard FileManager.default.fileExists(atPath: url.path) else { return (MetadataLedger(), true) }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= recoveryBudget,
              let value = try? decoder.decode(MetadataLedger.self, from: Data(contentsOf: url)), value.version == 1,
              value.entries.count + value.blockedConfigurations.count <= recoveryCountLimit,
              value.entries.allSatisfy({ $0.namespace.count == 32 && $0.chat.count == 32 }) else {
            return (MetadataLedger(all: true), false)
        }
        return (value, true)
    }
    private func saveMetadataLedger(_ value: MetadataLedger) throws {
        let url = root.appendingPathComponent(metadataLedgerName)
        if value.entries.isEmpty, value.blockedConfigurations.isEmpty, !value.all {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        }
    }
    private func invalidation(scope: ArtifactCacheScope, profile: ExactID, root: ExactID) -> MetadataInvalidation {
        MetadataInvalidation(configuration: scope.configurationID, namespace: hash(namespace(scope)),
            chat: hash(chatKey(profile, root)))
    }
    private func record(_ entries: [MetadataInvalidation], allowingQuarantine: Bool = true) throws {
        guard !entries.isEmpty else { return }
        var ledger = try metadataLedger()
        guard ledger.writable else { throw ArtifactCacheError.unavailable }
        if ledger.value.all { allVersion = UUID(); throw ArtifactCacheError.unavailable }
        let blocked = Set(entries.map(\.configuration)).intersection(ledger.value.blockedConfigurations)
        if !blocked.isEmpty {
            for configuration in blocked { quarantines[configuration] = UUID() }
            throw ArtifactCacheError.unavailable
        }
        let before = ledger.value.entries
        let blockedBefore = ledger.value.blockedConfigurations
        let allBefore = ledger.value.all
        var indexed = Dictionary(ledger.value.entries.map { ($0.key, $0) }, uniquingKeysWith: { _, newer in newer })
        for entry in entries { indexed[entry.key] = entry }
        ledger.value.entries = Set(indexed.values)
        guard ledger.value.entries != before else { return }
        let encodedSize = try encoder.encode(ledger.value).count
        if ledger.value.entries.count + ledger.value.blockedConfigurations.count > recoveryCountLimit || encodedSize > recoveryBudget {
            guard allowingQuarantine else { throw ArtifactCacheError.quota }
            ledger.value.blockedConfigurations.formUnion(ledger.value.entries.map(\.configuration))
            ledger.value.entries = []
            let compactedSize = try encoder.encode(ledger.value).count
            if ledger.value.blockedConfigurations.count > recoveryCountLimit || compactedSize > recoveryBudget {
                ledger.value = MetadataLedger(all: true)
            }
        }
        try saveMetadataLedger(ledger.value)
        let retained = Set(ledger.value.entries.map(\.key))
        revisions = revisions.filter { retained.contains($0.key) }
        for configuration in ledger.value.blockedConfigurations.subtracting(blockedBefore) { quarantines[configuration] = UUID() }
        quarantines = quarantines.filter { ledger.value.blockedConfigurations.contains($0.key) }
        if ledger.value.all && !allBefore { allVersion = UUID() }
        guard !ledger.value.all, entries.allSatisfy({ !ledger.value.blockedConfigurations.contains($0.configuration) }) else {
            throw ArtifactCacheError.quota
        }
    }
    func invalidate(_ chats: [(profile: ExactID, root: ExactID, revision: UUID)], scope: ArtifactCacheScope,
                    state: ArtifactCacheLeaseState) throws {
        try lock.withLock {
            guard !closed, state.isActive else { throw ArtifactCacheError.retired }
            let entries = chats.map { invalidation(scope: scope, profile: $0.profile, root: $0.root) }
            try record(entries)
            // Repeated dirty versions share the durable identity guard. Their
            // clearing tokens remain runtime-only and need no extra file write.
            for (entry, chat) in zip(entries, chats) { revisions[entry.key] = chat.revision }
        }
    }
    func begin(scope: ArtifactCacheScope, profile: ExactID, root: ExactID, revision: UUID) throws {
        try lock.withLock {
            guard !closed else { throw ArtifactCacheError.unavailable }
            let entry = invalidation(scope: scope, profile: profile, root: root)
            // An older queued SQL write cannot replace a newer runtime guard.
            let ledger = try metadataLedger()
            if ledger.value.entries.contains(entry) {
                if revisions[entry.key] == nil { revisions[entry.key] = revision }
                return
            }
            try record([entry]); revisions[entry.key] = revision
        }
    }
    func evict(configuration: UUID, namespace: Data, key: Data, provisional: Bool) throws -> Eviction? {
        try lock.withLock {
            guard !closed else { throw ArtifactCacheError.unavailable }
            let entry = MetadataInvalidation(configuration: configuration, namespace: hash(namespace), chat: hash(key))
            guard !(try metadataLedger().value.entries.contains(entry)) else { return nil }
            // A speculative deletion can reject quota before changing SQL; it
            // must not quarantine a configuration that rollback will preserve.
            try record([entry], allowingQuarantine: !provisional)
            let revision = UUID(); revisions[entry.key] = revision
            return Eviction(configuration: entry.configuration, namespace: entry.namespace, chat: entry.chat, revision: revision)
        }
    }
    func rollback(_ evictions: [Eviction]) throws {
        guard !evictions.isEmpty else { return }
        try lock.withLock {
            var ledger = try metadataLedger()
            guard ledger.writable else { throw ArtifactCacheError.unavailable }
            var cleared = Set<MetadataKey>()
            for eviction in evictions {
                let entry = MetadataInvalidation(configuration: eviction.configuration, namespace: eviction.namespace, chat: eviction.chat)
                guard revisions[entry.key] == eviction.revision else { continue }
                if ledger.value.entries.remove(entry) != nil { cleared.insert(entry.key) }
            }
            guard !cleared.isEmpty else { return }
            try saveMetadataLedger(ledger.value)
            for key in cleared { revisions[key] = nil }
        }
    }
    func finish(scope: ArtifactCacheScope, profile: ExactID, root: ExactID, revision: UUID) throws {
        try lock.withLock {
            var ledger = try metadataLedger()
            guard ledger.writable, !ledger.value.all, !ledger.value.blockedConfigurations.contains(scope.configurationID) else {
                throw ArtifactCacheError.unavailable
            }
            let entry = invalidation(scope: scope, profile: profile, root: root)
            guard revisions[entry.key] == revision, ledger.value.entries.remove(entry) != nil else { return }
            try saveMetadataLedger(ledger.value); revisions[entry.key] = nil
        }
    }
    func withFileMaintenance(_ operation: () throws -> Void) rethrows {
        try lock.withLock(operation)
    }
    func recovery(scope: ArtifactCacheScope) throws -> ArtifactMetadataRecovery {
        try lock.withLock {
            guard !closed else { throw ArtifactCacheError.unavailable }
            let ledger = try metadataLedger().value
            let scopeKey = hash(namespace(scope))
            return ArtifactMetadataRecovery(invalidated: Set(ledger.entries.filter {
                $0.configuration == scope.configurationID && $0.namespace == scopeKey
            }.map(\.chat)), all: ledger.all || ledger.blockedConfigurations.contains(scope.configurationID))
        }
    }
    private func cleanMetadata(removing configurations: (UUID) -> Bool, clearAll: Bool, checkpoint: Checkpoint) throws {
        var ledger = try metadataLedger()
        guard ledger.writable, let prior = checkpoint.ledger else { throw ArtifactCacheError.unavailable }
        ledger.value.entries = ledger.value.entries.filter {
            !configurations($0.configuration) || !prior.entries.contains($0)
                || revisions[$0.key] != checkpoint.revisions[$0.key]
        }
        ledger.value.blockedConfigurations = ledger.value.blockedConfigurations.filter {
            !configurations($0) || !prior.blockedConfigurations.contains($0)
                || quarantines[$0] != checkpoint.quarantines[$0]
        }
        if clearAll && prior.all && allVersion == checkpoint.allVersion { ledger.value.all = false }
        try saveMetadataLedger(ledger.value)
        let retained = Set(ledger.value.entries.map(\.key))
        revisions = revisions.filter { retained.contains($0.key) }
        quarantines = quarantines.filter { ledger.value.blockedConfigurations.contains($0.key) }
    }
    func prune(_ reachable: Set<UUID>, checkpoint: Checkpoint) throws {
        try lock.withLock {
            try cleanMetadata(removing: { !reachable.contains($0) }, clearAll: reachable.isEmpty, checkpoint: checkpoint)
        }
    }
    func discard(_ configurationID: UUID, checkpoint: Checkpoint) throws {
        try lock.withLock {
            try cleanMetadata(removing: { $0 == configurationID }, clearAll: false, checkpoint: checkpoint)
        }
    }

}

@MainActor fileprivate final class ArtifactCacheMaintenance {
    private let operation: @MainActor () async throws -> Void
    private var attempt = UUID()
    private var task: Task<Void, Error>
    init(operation: @escaping @MainActor () async throws -> Void) {
        self.operation = operation
        task = Task { try await operation() }
    }
    func wait() async throws { try await task.value }
    func retry() async throws {
        let previous = attempt
        do { try await task.value; return } catch {}
        if attempt == previous {
            attempt = UUID()
            task = Task { try await operation() }
        }
        try await task.value
    }
}

@MainActor final class ArtifactCache {
    struct Limits: Sendable {
        var originalBytes = 256 * 1024 * 1024
        var thumbnailBytes = 32 * 1024 * 1024
        var singleOriginalBytes = 25 * 1024 * 1024
        var metadataBytes = 40 * 1024 * 1024
        var chatCount = 1_000
        var messageCount = 25_000
        var textBytes = 32 * 1024 * 1024
    }
    static let shared = ArtifactCache(root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BottoArtifacts", isDirectory: true))
    private let backend: ArtifactCacheBackend
    private let journal: ArtifactMetadataJournal
    private var maintenance: ArtifactCacheMaintenance?
    private struct WeakSession { weak var value: ArtifactCacheSession?; let configurationID: UUID }
    private var sessions: [WeakSession] = []
    init(root: URL?, limits: Limits = .init(), beforeCaptureCommit: (@Sendable () -> Void)? = nil,
         beforeMetadataWrite: (@Sendable () -> Void)? = nil) {
        let resolvedRoot = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("BottoArtifactEphemeral-\(UUID().uuidString)")
        journal = ArtifactMetadataJournal(root: resolvedRoot, limits: limits)
        backend = ArtifactCacheBackend(root: resolvedRoot, ephemeral: root == nil, limits: limits, journal: journal,
            beforeCaptureCommit: beforeCaptureCommit, beforeMetadataWrite: beforeMetadataWrite)
    }
    func session(scope: ArtifactCacheScope) -> ArtifactCacheSession {
        let session = ArtifactCacheSession(backend: backend, journal: journal, scope: scope, barrier: maintenance)
        sessions.removeAll { $0.value == nil }
        sessions.append(WeakSession(value: session, configurationID: scope.configurationID))
        return session
    }
    func discard(configurationID: UUID) {
        for item in sessions where item.configurationID == configurationID { item.value?.retire() }
        let previous = maintenance, backend = backend, checkpoint = journal.checkpoint()
        maintenance = ArtifactCacheMaintenance {
            _ = try? await previous?.wait()
            try await backend.discard(configurationID, checkpoint: checkpoint)
        }
    }
    func prune(reachableConfigurationIDs: Set<UUID>) {
        for item in sessions where !reachableConfigurationIDs.contains(item.configurationID) { item.value?.retire() }
        let previous = maintenance, backend = backend, checkpoint = journal.checkpoint()
        maintenance = ArtifactCacheMaintenance {
            _ = try? await previous?.wait()
            try await backend.prune(reachableConfigurationIDs, checkpoint: checkpoint)
        }
    }
    func drainMaintenance() async throws { try await maintenance?.wait() }
    func close() async {
        for item in sessions { item.value?.retire() }
        _ = try? await maintenance?.wait()
        await backend.close()
    }
}
@MainActor final class ArtifactCacheSession {
    private(set) var isRetired = false
    private let backend: ArtifactCacheBackend
    private let journal: ArtifactMetadataJournal
    private let lease = UUID()
    private let leaseState = ArtifactCacheLeaseState()
    private var acquisition: Task<Void, Error>
    private var acquisitionAttempt = UUID()
    private let metadataScope: ArtifactCacheScope
    private let maintenance: ArtifactCacheMaintenance?
    fileprivate init(backend: ArtifactCacheBackend, journal: ArtifactMetadataJournal, scope: ArtifactCacheScope, barrier: ArtifactCacheMaintenance?) {
        self.backend = backend; self.journal = journal
        metadataScope = scope; maintenance = barrier
        let lease = lease, state = leaseState
        acquisition = Task {
            try await barrier?.wait()
            try await backend.acquire(lease, scope: scope, state: state)
        }
    }
    deinit {
        leaseState.retire()
        let backend = backend, lease = lease, acquisition = acquisition
        Task { _ = try? await acquisition.value; await backend.revoke(lease) }
    }
    func retire() {
        guard !isRetired else { return }
        isRetired = true
        leaseState.retire()
        let backend = backend, lease = lease, acquisition = acquisition
        Task { _ = try? await acquisition.value; await backend.revoke(lease) }
    }
    private func ready() async throws {
        guard !isRetired else { throw ArtifactCacheError.retired }
        try await acquisition.value
        try Task.checkCancellation()
        guard !isRetired else { throw ArtifactCacheError.retired }
    }
    func retryStorage() async throws {
        try Task.checkCancellation()
        guard !isRetired else { throw ArtifactCacheError.retired }
        let previous = acquisitionAttempt
        do { try await ready(); return } catch {}
        try Task.checkCancellation()
        guard !isRetired else { throw ArtifactCacheError.retired }
        if acquisitionAttempt == previous {
            acquisitionAttempt = UUID()
            let maintenance = maintenance, backend = backend, lease = lease, scope = metadataScope, state = leaseState
            acquisition = Task {
                try await maintenance?.retry()
                try await backend.acquire(lease, scope: scope, state: state)
            }
        }
        try await ready()
    }
    private func accepted<T>(_ value: T) throws -> T {
        guard !isRetired else { throw ArtifactCacheError.retired }
        return value
    }
    func loadChats() async throws -> [CachedArtifactChat] {
        try await ready()
        return try accepted(try await backend.loadChats(lease))
    }
    func metadataRecovery() async throws -> ArtifactMetadataRecovery {
        guard !isRetired else { throw ArtifactCacheError.retired }
        return try accepted(try journal.recovery(scope: metadataScope))
    }
    func metadataRecoveryHints() async throws -> [ArtifactMetadataHint] {
        try await ready()
        return try accepted(try await backend.metadataRecoveryHints(lease))
    }
    func upsert(_ record: CachedArtifactChat) async throws {
        let revision = UUID()
        try invalidateMetadata([(record.identity.profile, record.identity.root, revision)])
        try await upsert(record, revision: revision)
    }
    func upsert(_ record: CachedArtifactChat, revision: UUID) async throws {
        try await ready()
        try await backend.upsert(record, lease: lease, revision: revision)
        try accepted(())
    }
    func invalidateMetadata(_ chats: [(profile: ExactID, root: ExactID)]) throws {
        try invalidateMetadata(chats.map { ($0.profile, $0.root, UUID()) })
    }
    func invalidateMetadata(_ chats: [(profile: ExactID, root: ExactID, revision: UUID)]) throws {
        guard !isRetired else { throw ArtifactCacheError.retired }
        // Guards only withhold metadata. SQL reads/writes still await cleanup;
        // queued cleanup preserves guards recorded by a new active lease.
        try journal.invalidate(chats, scope: metadataScope, state: leaseState)
    }
    func deleteChat(profile: ExactID, root: ExactID) async throws {
        try await ready()
        try await backend.deleteChat(profile: profile, root: root, lease: lease)
        try accepted(())
    }
    func original(for key: ArtifactOriginalKey) async throws -> CachedArtifactOriginal? {
        try await ready()
        return try accepted(try await backend.original(for: key, lease: lease))
    }
    func originalDigest(for key: ArtifactOriginalKey) async throws -> Data? {
        try await ready()
        return try accepted(try await backend.originalDigest(for: key, lease: lease))
    }
    @discardableResult func retainOriginal(_ artifact: DownloadedArtifact, for key: ArtifactOriginalKey,
                                         admission: ArtifactCaptureAdmission? = nil) async throws -> Data? {
        while true {
            try await admission?.waitUntilReady()
            try await ready()
            do { return try accepted(try await backend.retainOriginal(artifact, for: key, lease: lease, admission: admission)) }
            catch ArtifactCaptureAdmission.PublicationError.pending { continue }
        }
    }
    func thumbnail(for key: ArtifactThumbnailKey) async throws -> Data? {
        try await ready()
        return try accepted(try await backend.thumbnail(for: key, lease: lease))
    }
    func retainThumbnail(_ data: Data, for key: ArtifactThumbnailKey) async throws {
        try await ready()
        try await backend.retainThumbnail(data, for: key, lease: lease)
        try accepted(())
    }
}
private enum ArtifactCacheError: Error { case unavailable, retired, unsupportedSchema, quota }

fileprivate actor ArtifactCacheBackend {
    private let root: URL
    private let ephemeral: Bool
    private let limits: ArtifactCache.Limits
    private let journal: ArtifactMetadataJournal
    private let beforeMetadataWrite: (@Sendable () -> Void)?
    private var database: SQLiteConnection?
    private var closed = false
    private var leases: [UUID: (scope: ArtifactCacheScope, state: ArtifactCacheLeaseState)] = [:]
    private let beforeCaptureCommit: (@Sendable () -> Void)?
    private var denied = Set<UUID>()
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(root: URL, ephemeral: Bool, limits: ArtifactCache.Limits, journal: ArtifactMetadataJournal,
         beforeCaptureCommit: (@Sendable () -> Void)?, beforeMetadataWrite: (@Sendable () -> Void)?) {
        self.ephemeral = ephemeral; self.root = root; self.limits = limits; self.journal = journal
        self.beforeMetadataWrite = beforeMetadataWrite
        self.beforeCaptureCommit = beforeCaptureCommit
        encoder.outputFormat = .binary
    }
    deinit {
        database = nil
        if ephemeral { try? FileManager.default.removeItem(at: root) }
    }
    func close() {
        closed = true; journal.close()
        leases = [:]
        database = nil
    }
    func acquire(_ id: UUID, scope: ArtifactCacheScope, state: ArtifactCacheLeaseState) throws {
        guard state.isActive else { throw ArtifactCacheError.retired }
        guard !denied.contains(scope.configurationID) else { throw ArtifactCacheError.unavailable }
        try open()
        leases[id] = (scope, state)
    }
    func revoke(_ id: UUID) { leases[id] = nil }
    private func scope(_ id: UUID) throws -> ArtifactCacheScope {
        guard let value = leases[id], value.state.isActive, !denied.contains(value.scope.configurationID) else { throw ArtifactCacheError.retired }
        return value.scope
    }
    private func open() throws {
        guard !closed else { throw ArtifactCacheError.unavailable }
        if database != nil { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let connection = try SQLiteConnection(path: root.appendingPathComponent("index.sqlite").path)
        let version = try connection.rows("PRAGMA user_version").first?.first?.integer ?? 0
        guard version == 0 || version == 1 else { throw ArtifactCacheError.unsupportedSchema }
        if version == 0 {
            // An unrecognized existing database is preserved, never reset.
            guard try connection.rows("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else { throw ArtifactCacheError.unsupportedSchema }
            try connection.execute("CREATE TABLE entries(scope BLOB NOT NULL, configuration BLOB NOT NULL, kind INTEGER NOT NULL, key BLOB NOT NULL, payload BLOB NOT NULL, blob TEXT, size INTEGER NOT NULL, accessed REAL NOT NULL, PRIMARY KEY(scope,kind,key)); PRAGMA user_version=1")
        }
        database = connection
        do { try cleanup() }
        catch { database = nil; throw error }
    }
    private func pack(_ fields: [Data]) -> Data {
        artifactCacheFields(fields)
    }
    private func namespace(_ scope: ArtifactCacheScope) -> Data {
        pack([Data(scope.configurationID.uuidString.utf8), scope.serverURL,
              scope.installationID.map { Data([1]) + $0 } ?? Data([0]), scope.username,
              scope.provider.map { Data([1]) + $0 } ?? Data([0])])
    }
    private func chatKey(_ profile: ExactID, _ root: ExactID) -> Data { pack([profile.bytes, root.bytes]) }
    private func originalKey(_ key: ArtifactOriginalKey) -> Data {
        key.persistenceKey
    }
    private func thumbnailKey(_ key: ArtifactThumbnailKey) -> Data {
        pack([key.originalDigest, Data(String(key.maximumPixels).utf8), Data(String(key.decoderVersion).utf8)])
    }
    private var recoveryBudget: Int { max(256, min(256 * 1_024, limits.metadataBytes / 4)) }
    private var metadataCapacity: Int { max(0, limits.metadataBytes - recoveryBudget) }
    func metadataRecovery(scope: ArtifactCacheScope) throws -> ArtifactMetadataRecovery {
        guard !closed, !denied.contains(scope.configurationID) else { throw ArtifactCacheError.unavailable }
        return try journal.recovery(scope: scope)
    }
    private func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private func filename(scope: ArtifactCacheScope, digest: Data, kind: Int) -> String {
        "\(kind)-" + hash(namespace(scope)).map { String(format: "%02x", $0) }.joined() + "-" + digest.map { String(format: "%02x", $0) }.joined()
    }
    private func row(scope: ArtifactCacheScope, kind: Int, key: Data) throws -> [SQLiteValue]? {
        guard let database else { throw ArtifactCacheError.unavailable }
        let bindings: [SQLiteValue] = [.data(namespace(scope)), .integer(kind), .data(key)]
        let row = try database.rows("SELECT payload,blob,size FROM entries WHERE scope=? AND kind=? AND key=?", bindings).first
        if row != nil { try database.execute("UPDATE entries SET accessed=? WHERE scope=? AND kind=? AND key=?", [.real(Date().timeIntervalSince1970)] + bindings) }
        return row
    }
    private func put(scope: ArtifactCacheScope, kind: Int, key: Data, payload: Data, blob: String? = nil, size: Int) throws {
        try insert(scope: scope, kind: kind, key: key, payload: payload, blob: blob, size: size)
        try enforceLimits()
    }
    private func insert(scope: ArtifactCacheScope, kind: Int, key: Data, payload: Data, blob: String? = nil, size: Int) throws {
        guard let database else { throw ArtifactCacheError.unavailable }
        try database.execute("INSERT OR REPLACE INTO entries VALUES(?,?,?,?,?,?,?,?)", [.data(namespace(scope)), .data(Data(scope.configurationID.uuidString.utf8)), .integer(kind), .data(key), .data(payload), blob.map(SQLiteValue.text) ?? .null, .integer(size), .real(Date().timeIntervalSince1970)])
    }
    func loadChats(_ lease: UUID) throws -> [CachedArtifactChat] {
        let scope = try scope(lease)
        let recovery = try metadataRecovery(scope: scope)
        guard !recovery.all else { return [] }
        return try savedChats(scope: scope).filter { !recovery.contains($0.identity) }
    }
    private func savedChats(scope: ArtifactCacheScope) throws -> [CachedArtifactChat] {
        guard let database else { throw ArtifactCacheError.unavailable }
        return try database.rows("SELECT payload FROM entries WHERE scope=? AND kind=0 ORDER BY accessed DESC", [.data(namespace(scope))]).compactMap { row in
            guard let data = row.first?.data, let record = try? decoder.decode(CachedArtifactChat.self, from: data) else { return nil }
            return record
        }
    }
    func metadataRecoveryHints(_ lease: UUID) throws -> [ArtifactMetadataHint] {
        let scope = try scope(lease), recovery = try metadataRecovery(scope: scope)
        return try savedChats(scope: scope).filter { recovery.contains($0.identity) }.map {
            ArtifactMetadataHint(identity: $0.identity, botName: $0.botName, title: $0.title, updatedAt: $0.updatedAt,
                unavailableMessageIDs: ($0.unavailableMessageIDs ?? []).union($0.messages.map { Data($0.id.utf8) }),
                removedMessageIDs: $0.removedMessageIDs ?? [], retiredStoredIDs: $0.retiredStoredIDs ?? [])
        }
    }
    func upsert(_ record: CachedArtifactChat, lease: UUID, revision: UUID) throws {
        let scope = try scope(lease)
        try journal.begin(scope: scope, profile: record.identity.profile, root: record.identity.root, revision: revision)
        beforeMetadataWrite?()
        try Task.checkCancellation(); _ = try self.scope(lease)
        let payload = try encoder.encode(record)
        guard record.messages.count + record.retainedEvidenceCount <= limits.messageCount,
              record.messages.reduce(0, { $0 + $1.text.utf8.count }) + record.retainedEvidenceBytes <= limits.textBytes,
              payload.count <= metadataCapacity else {
            try database?.execute("DELETE FROM entries WHERE scope=? AND kind=0 AND key=?", [.data(namespace(scope)), .data(chatKey(record.identity.profile, record.identity.root))])
            throw ArtifactCacheError.quota
        }
        try put(scope: scope, kind: 0, key: chatKey(record.identity.profile, record.identity.root), payload: payload, size: payload.count)
        guard try row(scope: scope, kind: 0, key: chatKey(record.identity.profile, record.identity.root))?.first?.data == payload else {
            throw ArtifactCacheError.quota
        }
        try Task.checkCancellation(); _ = try self.scope(lease)
        try journal.finish(scope: scope, profile: record.identity.profile, root: record.identity.root, revision: revision)
    }
    func deleteChat(profile: ExactID, root: ExactID, lease: UUID) throws {
        let scope = try scope(lease)
        try journal.begin(scope: scope, profile: profile, root: root, revision: UUID())
        try database?.execute("DELETE FROM entries WHERE scope=? AND kind=0 AND key=?", [.data(namespace(scope)), .data(chatKey(profile, root))])
    }
    nonisolated private struct OriginalMetadata: Codable {
        let filename: String
        let mimeType: String
        let digest: Data
    }
    func original(for key: ArtifactOriginalKey, lease: UUID) throws -> CachedArtifactOriginal? {
        let scope = try scope(lease)
        guard let row = try row(scope: scope, kind: 1, key: originalKey(key)), let payload = row[0].data,
              let metadata = try? decoder.decode(OriginalMetadata.self, from: payload), let name = row[1].text,
              let data = readBlob(name, maximumBytes: limits.singleOriginalBytes), hash(data) == metadata.digest else { return nil }
        return CachedArtifactOriginal(artifact: DownloadedArtifact(data: data, filename: metadata.filename, mimeType: metadata.mimeType), digest: metadata.digest)
    }
    func originalDigest(for key: ArtifactOriginalKey, lease: UUID) throws -> Data? {
        let scope = try scope(lease)
        return try row(scope: scope, kind: 3, key: originalKey(key))?.first?.data
    }
    func retainOriginal(_ artifact: DownloadedArtifact, for key: ArtifactOriginalKey, lease: UUID,
                        admission: ArtifactCaptureAdmission? = nil) throws -> Data? {
        let scope = try scope(lease)
        guard let database else { throw ArtifactCacheError.unavailable }
        defer { try? cleanup() }
        let digest = hash(artifact.data)
        guard artifact.data.count <= limits.singleOriginalBytes, artifact.data.count <= limits.originalBytes else { return nil }
        let name = filename(scope: scope, digest: digest, kind: 1)
        try writeBlob(artifact.data, name: name)
        let payload = try encoder.encode(OriginalMetadata(filename: artifact.filename, mimeType: artifact.mimeType, digest: digest))
        try database.execute("BEGIN IMMEDIATE")
        var evictions: [ArtifactMetadataJournal.Eviction] = []
        do {
            try insert(scope: scope, kind: 1, key: originalKey(key), payload: payload, blob: name, size: artifact.data.count)
            try insert(scope: scope, kind: 3, key: originalKey(key), payload: digest, size: digest.count)
            try enforceLimits(reclaimStorage: false, onEviction: { evictions.append($0) })
            guard try row(scope: scope, kind: 1, key: originalKey(key))?.first?.data == payload,
                  try row(scope: scope, kind: 3, key: originalKey(key))?.first?.data == digest else { throw ArtifactCacheError.quota }
            beforeCaptureCommit?()
            try Task.checkCancellation()
            // Claim publication immediately before COMMIT; later presentation
            // retirement cannot undo bytes admitted while a consumer was valid.
            try admission?.claimPublication()
            _ = try self.scope(lease)
            try database.execute("COMMIT")
        } catch {
            do {
                try database.execute("ROLLBACK")
                try journal.rollback(evictions)
            } catch {
                // An uncertain SQL outcome or failed guard write stays closed.
            }
            throw error
        }
        return digest
    }
    func thumbnail(for key: ArtifactThumbnailKey, lease: UUID) throws -> Data? {
        let scope = try scope(lease)
        guard let row = try row(scope: scope, kind: 2, key: thumbnailKey(key)), let name = row[1].text,
              let expected = row[0].data, let data = readBlob(name, maximumBytes: limits.thumbnailBytes), hash(data) == expected else { return nil }
        return data
    }
    func retainThumbnail(_ data: Data, for key: ArtifactThumbnailKey, lease: UUID) throws {
        let scope = try scope(lease)
        guard key.maximumPixels > 0, data.count <= limits.thumbnailBytes else { return }
        defer { try? cleanup() }
        let digest = hash(data), name = filename(scope: scope, digest: digest, kind: 2)
        try writeBlob(data, name: name)
        try put(scope: scope, kind: 2, key: thumbnailKey(key), payload: digest, blob: name, size: data.count)
    }
    private func readBlob(_ name: String, maximumBytes: Int) -> Data? {
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let url = root.appendingPathComponent(name)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else { return nil }
        return try? Data(contentsOf: url)
    }
    private func writeBlob(_ data: Data, name: String) throws {
        let url = root.appendingPathComponent(name)
        // Atomic replacement completes before the transactional mapping becomes visible.
        try data.write(to: url, options: .atomic)
    }
    func discard(_ configurationID: UUID, checkpoint: ArtifactMetadataJournal.Checkpoint) throws {
        denied.insert(configurationID)
        leases = leases.filter { $0.value.scope.configurationID != configurationID }
        try open()
        try database?.execute("DELETE FROM entries WHERE configuration=?", [.data(Data(configurationID.uuidString.utf8))])
        try cleanup()
        try database?.execute("VACUUM")
        try journal.discard(configurationID, checkpoint: checkpoint)
        denied.remove(configurationID)
    }
    func prune(_ reachable: Set<UUID>, checkpoint: ArtifactMetadataJournal.Checkpoint) throws {
        try open()
        let ids = try database?.rows("SELECT DISTINCT configuration FROM entries") ?? []
        for row in ids {
            if let data = row[0].data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)), !reachable.contains(id) { try discard(id, checkpoint: checkpoint) }
        }
        try journal.prune(reachable, checkpoint: checkpoint)
    }
    private func cleanup() throws {
        guard let database else { return }
        let names = Set(try database.rows("SELECT DISTINCT blob FROM entries WHERE blob IS NOT NULL").compactMap { $0[0].text })
        // Cleanup must not remove the journal's in-progress atomic write file.
        try journal.withFileMaintenance {
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                let name = url.lastPathComponent
                if name == "metadata-recovery.plist" { continue }
                if name == "index.sqlite" || name == "index.sqlite-journal" || name == "index.sqlite-wal" || name == "index.sqlite-shm" { continue }
                if !names.contains(name) { try FileManager.default.removeItem(at: url) }
            }
        }
    }
    private func databaseBytes() throws -> Int {
        try ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "index.sqlite-journal"].reduce(0) { total, name in
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return total }
            return total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }
    private func evict(_ row: [SQLiteValue], onEviction: ((ArtifactMetadataJournal.Eviction) -> Void)? = nil) throws {
        guard let database, let id = row.first?.integer else { throw ArtifactCacheError.unavailable }
        if row[1].integer == 0 {
            guard let configuration = row[2].data.flatMap({ UUID(uuidString: String(decoding: $0, as: UTF8.self)) }),
                  let namespace = row[3].data, let key = row[4].data else { throw ArtifactCacheError.unavailable }
            if let eviction = try journal.evict(configuration: configuration, namespace: namespace, key: key, provisional: onEviction != nil) {
                onEviction?(eviction)
            }
        }
        try database.execute("DELETE FROM entries WHERE rowid=?", [.integer(id)])
    }
    private func evictOldest(kind: Int? = nil, onEviction: ((ArtifactMetadataJournal.Eviction) -> Void)? = nil) throws {
        guard let database else { throw ArtifactCacheError.unavailable }
        let rows = try database.rows("SELECT rowid,kind,configuration,scope,key FROM entries" +
            (kind == nil ? "" : " WHERE kind=?") + " ORDER BY accessed ASC LIMIT 1", kind.map { [.integer($0)] } ?? [])
        guard let row = rows.first else { throw ArtifactCacheError.quota }
        try evict(row, onEviction: onEviction)
    }
    private func enforceLimits(reclaimStorage: Bool = true, onEviction: ((ArtifactMetadataJournal.Eviction) -> Void)? = nil) throws {
        guard let database else { return }
        var removed = false
        for (kind, budget) in [(0, metadataCapacity), (1, limits.originalBytes), (2, limits.thumbnailBytes)] {
            while true {
                let sizes = try database.rows(kind == 0 ? "SELECT COALESCE(SUM(length(payload)),0),COUNT(*) FROM entries WHERE kind=0" : "SELECT COALESCE(SUM(size),0),COUNT(*) FROM (SELECT blob,MAX(size) AS size FROM entries WHERE kind=\(kind) GROUP BY blob)")
                let size = sizes.first?[0].integer ?? 0, count = sizes.first?[1].integer ?? 0
                if size <= max(0, budget) && (kind != 0 || count <= max(0, limits.chatCount)) { break }
                try evictOldest(kind: kind, onEviction: onEviction)
                removed = true
            }
        }
        // Include mapping keys, scope bytes and response metadata in admission.
        while (try database.rows("SELECT COALESCE(SUM(length(payload)+length(key)+length(scope)+length(configuration)+128),0) FROM entries").first?[0].integer ?? 0) > metadataCapacity {
            guard !(try database.rows("SELECT rowid FROM entries LIMIT 1")).isEmpty else { throw ArtifactCacheError.quota }
            try evictOldest(onEviction: onEviction)
            removed = true
        }
        var messages = 0, textBytes = 0
        for row in try database.rows("SELECT rowid,payload,configuration,scope,key FROM entries WHERE kind=0 ORDER BY accessed DESC") {
            guard let payload = row[1].data, let record = try? decoder.decode(CachedArtifactChat.self, from: payload) else { continue }
            messages += record.messages.count + record.retainedEvidenceCount
            textBytes += record.messages.reduce(0) { $0 + $1.text.utf8.count } + record.retainedEvidenceBytes
            if messages > limits.messageCount || textBytes > limits.textBytes {
                try evict([row[0], .integer(0), row[2], row[3], row[4]], onEviction: onEviction)
                removed = true
            }
        }
        if !reclaimStorage {
            let pages = try database.rows("PRAGMA page_count").first?.first?.integer ?? 0
            let pageBytes = try database.rows("PRAGMA page_size").first?.first?.integer ?? 0
            guard pageBytes > 0, pages <= max(0, max(64 * 1024, limits.metadataBytes) - recoveryBudget) / pageBytes else { throw ArtifactCacheError.quota }
            return
        }
        try cleanup()
        if removed { try database.execute("VACUUM") }
        // SQLite pages and indexes also consume the metadata allowance. Small
        // injected budgets retain the minimum schema pages (64 KiB).
        let physicalBudget = max(0, max(64 * 1024, limits.metadataBytes) - recoveryBudget)
        while try databaseBytes() > physicalBudget {
            guard !(try database.rows("SELECT rowid FROM entries LIMIT 1")).isEmpty else { break }
            try evictOldest(onEviction: onEviction)
            try cleanup()
            try database.execute("VACUUM")
        }
    }
}

nonisolated private enum SQLiteValue {
    case data(Data), text(String), integer(Int), real(Double), null
    var data: Data? { if case .data(let value) = self { value } else { nil } }
    var text: String? { if case .text(let value) = self { value } else { nil } }
    var integer: Int? { if case .integer(let value) = self { value } else { nil } }
}
/// The actor exclusively owns the connection; this wrapper closes it at teardown.
nonisolated private final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer
    init(path: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw ArtifactCacheError.unavailable
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 1_000)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        if bindings.isEmpty {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw ArtifactCacheError.unavailable }
        } else { _ = try rows(sql, bindings) }
    }
    func rows(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ArtifactCacheError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case .data(let data): result = data.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : data.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient) }
            case .text(let text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .integer(let value): result = sqlite3_bind_int64(statement, index, Int64(value))
            case .real(let value): result = sqlite3_bind_double(statement, index, value)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw ArtifactCacheError.unavailable }
        }
        var output: [[SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw ArtifactCacheError.unavailable }
            var row: [SQLiteValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    row.append(.data(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, index)!, count: count)))
                case SQLITE_INTEGER: row.append(.integer(Int(sqlite3_column_int64(statement, index))))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, index))))
                default: row.append(.null)
                }
            }
            output.append(row)
        }
    }
}
