import Foundation
import Observation
import CryptoKit
import BottoCore

private enum ArtifactCaptureFailure: Error, LocalizedError {
    case notRetained
    var errorDescription: String? { "The refreshed file couldn’t be saved on this device. Try again." }
}

private final class OriginalReadCancellation: @unchecked Sendable {
    // A response can reach the actor before its queued cancellation cleanup.
    private let lock = NSLock()
    private var cancelled = false
    private let onCancel: @Sendable () -> Void
    init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
    func cancel() { lock.withLock { cancelled = true }; onCancel() }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

struct LibraryChat: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let workspace: UUID
        let profile: ExactID
        let root: ExactID
    }
    let id: ID
    let identity: SessionIdentity
    let botID: String
    let botName: String
    let title: String
    let messages: [ChatMessage]
    var updatedAt: Date?
    let discoveredArtifacts: [DiscoveredArtifact]
    let sourceRevisions: [Data: Data]
    let searchableText: [Data: [String]]
    let unavailableMessageIDs: Set<Data>
    let removedMessageIDs: Set<Data>
    let retiredStoredIDs: Set<Data>
    let directoryAbsent: Bool

    init(workspace: UUID, identity: SessionIdentity, botName: String, title: String,
         messages: [ChatMessage], updatedAt: Date?, discoveredArtifacts: [DiscoveredArtifact], sourceRevisions: [Data: Data],
         searchableText: [Data: [String]] = [:], unavailableMessageIDs: Set<Data> = [], removedMessageIDs: Set<Data> = [],
         retiredStoredIDs: Set<Data> = [], directoryAbsent: Bool = false) {
        id = ID(workspace: workspace, profile: identity.profile, root: identity.root)
        self.identity = identity; botID = identity.profile.text; self.botName = botName
        self.title = title; self.messages = messages; self.updatedAt = updatedAt
        self.discoveredArtifacts = discoveredArtifacts
        self.sourceRevisions = sourceRevisions
        self.searchableText = searchableText
        self.unavailableMessageIDs = unavailableMessageIDs
        self.removedMessageIDs = removedMessageIDs
        self.retiredStoredIDs = retiredStoredIDs
        self.directoryAbsent = directoryAbsent
    }

    func updatingMetadata(identity: SessionIdentity, botName: String, title: String, updatedAt: Date?) -> Self {
        Self(workspace: id.workspace, identity: identity, botName: botName, title: title,
            messages: messages, updatedAt: updatedAt, discoveredArtifacts: discoveredArtifacts,
            sourceRevisions: sourceRevisions, searchableText: searchableText,
            unavailableMessageIDs: unavailableMessageIDs, removedMessageIDs: removedMessageIDs,
            retiredStoredIDs: retiredStoredIDs, directoryAbsent: directoryAbsent)
    }

    nonisolated static func searchIndex(_ messages: [ChatMessage]) -> [Data: [String]] {
        var result: [Data: [String]] = [:], seen = Set<Data>(), ambiguous = Set<Data>()
        for message in messages {
            let id = Data(message.id.utf8)
            if !seen.insert(id).inserted { ambiguous.insert(id) }
            else { result[id] = NativeMessageText.segments(for: message) }
        }
        for id in ambiguous { result[id] = nil }
        return result
    }
}

struct LibraryArtifact: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let chat: LibraryChat.ID
        let artifact: DiscoveredArtifact.ID
    }
    let chat: LibraryChat
    let artifact: DiscoveredArtifact
    var id: ID { ID(chat: chat.id, artifact: artifact.id) }
}

/// A mounted workspace's read-only index. It never opens a chat or acknowledges
/// its messages; the live conversation and its mutation grants remain separate.
@MainActor @Observable final class WorkspaceLibrary {
    struct Limits {
        let messageCount: Int
        let textBytes: Int
        let chatCount: Int
        init(messageCount: Int = 25_000, textBytes: Int = 32 * 1024 * 1024, chatCount: Int = 1_000) {
            self.messageCount = max(0, messageCount)
            self.textBytes = max(0, textBytes)
            self.chatCount = max(0, chatCount)
        }
    }
    private enum Coverage: Equatable, Sendable { case complete, partial }
    enum TranscriptEvidence: Sendable {
        case read(startedAt: ContinuousClock.Instant, observedSource: SessionIdentity?)
        case incremental(previous: Conversation?)
    }
    private enum Reconciliation: Equatable { case replace, merge, seed, restore, olderPage, accepted, observedSource, absent }
    private enum ProjectionOwner { case caller, background }
    private struct Candidate: Sendable {
        let id: LibraryChat.ID
        let source: SessionIdentity
        let botName: String
        let title: String
        let updatedAt: Date?
        let messages: [ChatMessage]
        let coverage: Coverage
        let unavailableMessageIDs: Set<Data>
        let removedMessageIDs: Set<Data>
        let retiredStoredIDs: Set<Data>
        let directoryAbsent: Bool
    }
    struct IndexingMetrics {
        var acceptedSnapshots = 0
        var batches = 0
        var parsedMessages = 0
        var processingDuration: Duration = .zero
        var galleryConsumersRegistered = 0
        var retainedAcceptanceFences = 0
        var pendingMetadataIdentities = 0
        var forcedRefreshesJoined = 0
    }
    @ObservationIgnored private(set) var indexingMetrics = IndexingMetrics()
    struct Projection: Sendable {
        let artifacts: [DiscoveredArtifact]
        let revisions: [Data: Data]
        var searchableText: [Data: [String]] = [:]
    }
    private struct Admission: Sendable {
        let candidates: [Candidate]
        let limited: Bool
    }
    private struct ProjectionState {
        let version: UUID
        var published: UUID?
        let tail: WorkingTail?
    }
    private var projectionStates: [LibraryChat.ID: ProjectionState] = [:]
    private struct ProjectionWaiter {
        let item: LibraryArtifact
        let continuation: CheckedContinuation<Void, any Error>
    }
    @ObservationIgnored private var projectionWaiters: [UUID: ProjectionWaiter] = [:]
    private struct AcceptanceFence {
        struct Stamp: Equatable {
            let generation: UUID
            let sequence: UInt64
        }
        private var generation = UUID()
        private var sequence: UInt64 = 0
        private var discardedThrough: UInt64 = 0
        private var versions: [LibraryChat.ID: UInt64] = [:]
        let capacity: Int
        init(capacity: Int) { self.capacity = capacity }
        var stamp: Stamp { Stamp(generation: generation, sequence: sequence) }
        var count: Int { versions.count }
        func contains(_ id: LibraryChat.ID) -> Bool { versions[id] != nil }
        mutating func record(_ id: LibraryChat.ID) {
            if sequence == .max {
                generation = UUID(); sequence = 0; discardedThrough = 0; versions = [:]
            }
            sequence += 1; versions[id] = sequence
            while versions.count > capacity, let oldest = versions.min(by: { $0.value < $1.value }) {
                versions[oldest.key] = nil; discardedThrough = max(discardedThrough, oldest.value)
            }
        }
        func permits(_ id: LibraryChat.ID, since stamp: Stamp) -> Bool {
            guard stamp.generation == generation else { return false }
            if let version = versions[id] { return version <= stamp.sequence }
            // A discarded change cannot become indistinguishable from an ID
            // that never changed. Only unknown IDs need this overflow fence.
            return discardedThrough <= stamp.sequence
        }
    }
    private var acceptanceFence: AcceptanceFence
    private let initialRestorationStamp: AcceptanceFence.Stamp
    private var captureRevisions: [Data: UUID] = [:]
    private(set) var thumbnailAvailabilityRevision = UUID()
    private(set) var revalidationRevision = UUID()
    @ObservationIgnored private var lastRevalidation: (at: ContinuousClock.Instant, revision: UUID)?
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    typealias ProjectionWorker = @Sendable ([ChatMessage], ChatMessage?) async -> Projection
    @ObservationIgnored private let projector: ProjectionWorker
    private let identity = UUID()
    private let mountedAt = ContinuousClock.now
    private struct SourceObservation {
        let stored: ExactID
        let sourceAt: ContinuousClock.Instant
        let contentAt: ContinuousClock.Instant?
    }
    private var observations: [LibraryChat.ID: SourceObservation] = [:]
    private var initialReadRows: [LibraryChat.ID: Set<Data>] = [:]
    private var initialSourceProofs: [LibraryChat.ID: ExactID] = [:]
    @ObservationIgnored private let cache: ArtifactCacheSession?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    private var inFlightUpsert: LibraryChat.ID?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var seedTask: Task<Void, Never>?
    private var pendingSeed: (book: ConversationBook, bots: [BotProfile], accepted: AcceptanceFence.Stamp, roster: UUID, request: UUID)?
    private var seedVersion = UUID()
    private var localWorkCount = 0
    private var restored = false
    private var restorationFailed = false
    private var unverifiedPersistenceChanges = false
    private var guardAdmissionFailure = UUID()
    private var metadataRecovery = ArtifactMetadataRecovery()
    private var restorationHints = Set<LibraryChat.ID>()
    private var persistedIDs: Set<LibraryChat.ID> = []
    private var summaries: [LibraryChat.ID: SessionSummary] = [:]
    private var heads: [LibraryChat.ID: Data] = [:]
    private var freshnessUnverified = false
    private var dirtyChats: Set<LibraryChat.ID> = []
    private var dirtyVersions: [LibraryChat.ID: UUID] = [:]
    private var unreconciledSeedIDs = Set<LibraryChat.ID>()
    private struct WorkingTail: Equatable {
        let stored: ExactID
        let messageID: Data
    }
    private var unsettledTail: [LibraryChat.ID: WorkingTail] = [:]

    private func workingTail(in source: SessionIdentity) -> Data? {
        guard let tail = unsettledTail[key(for: source)], tail.stored == source.stored else { return nil }
        return tail.messageID
    }
    private var botNames: [ExactID: String] = [:]
    private var rosterReadFloors: [ExactID: ContinuousClock.Instant]?
    private var rosterBots: [BotProfile] = []
    private var rosterRevision = UUID()
    enum RosterEvidence { case cached, observed }

    private func rosterPermits(_ profile: ExactID) -> Bool {
        rosterReadFloors == nil || rosterReadFloors?[profile] != nil
    }
    private struct OriginalConsumer {
        let validate: @MainActor () throws -> Void
        let projection: LibraryChat.ID?
        let download: @MainActor () async throws -> DownloadedArtifact

        @MainActor func isCurrent() -> Bool {
            do { try validate(); return true } catch { return false }
        }
    }
    private struct OriginalFlight {
        let id: UUID
        let task: Task<DownloadedArtifact, Error>
        let admission: ArtifactCaptureAdmission
        var consumers: [UUID: OriginalConsumer]
    }
    @ObservationIgnored private var flights: [ArtifactOriginalKey: OriginalFlight] = [:]
    @ObservationIgnored private var pendingTranscripts: [LibraryChat.ID: UUID] = [:]
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptDraining = false
    @ObservationIgnored private var originals: [ArtifactOriginalKey: DownloadedArtifact] = [:]
    private let limits: Limits
    @ObservationIgnored private let service: any BotService
    private var records: [LibraryChat.ID: LibraryChat] = [:]
    private var coverage: [LibraryChat.ID: Coverage] = [:]
    private var capacityLimited = false
    private enum ScanNotice {
        case failure(String), incomplete
        var message: String {
            switch self {
            case .failure(let message): message
            case .incomplete: "Showing available history. Older results may be missing."
            }
        }
    }
    private var scanNotice: ScanNotice?
    private var statusBeforeScan: (warning: String?, action: StatusAction?)?
    private var isScanning = false
    var isLoading: Bool { isScanning || localWorkCount > 0 }
    private(set) var isRetired = false
    private var online = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanIdentity = UUID()
    @ObservationIgnored private var requiresForcedPass = false
    @ObservationIgnored private var scanningForced = false

    init(service: any BotService, limits: Limits = .init(), cache: ArtifactCacheSession? = nil,
         now: @escaping () -> ContinuousClock.Instant = { .now },
         projector: @escaping ProjectionWorker = { messages, tail in await WorkspaceLibrary.project(messages, streamingMessage: tail) }) {
        self.service = service; self.limits = limits; self.projector = projector
        let (fenceCapacity, overflow) = max(1, limits.chatCount).multipliedReportingOverflow(by: 2)
        let fence = AcceptanceFence(capacity: overflow ? Int.max : fenceCapacity)
        acceptanceFence = fence; initialRestorationStamp = fence.stamp
        self.now = now
        self.cache = cache ?? ArtifactCache(root: nil).session(scope: .init(configurationID: UUID(),
            serverURL: Data(), installationID: nil, username: Data(), provider: nil))
    }

    func restore() async {
        if let seedTask { await seedTask.value }
        await restoreSavedIndex()
    }

    private func restoreSavedIndex() async {
        guard !isRetired, !restored || restorationFailed else { return }
        if let restoreTask { await restoreTask.value; return }
        localWorkCount += 1
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                restored = true
                if !restorationFailed { initialReadRows = [:]; initialSourceProofs = [:] }
                localWorkCount -= 1; schedulePersistence()
            }
            guard let cache else { return }
            let roster = rosterRevision, guardFailure = guardAdmissionFailure
            do {
                if restorationFailed { try await cache.retryStorage() }
                try await readMetadataRecovery()
                withdrawUntrustedRestoration()
                if metadataRecovery.all || !metadataRecovery.invalidated.isEmpty {
                    for hint in try await cache.metadataRecoveryHints() {
                        let id = key(for: hint.identity), stamp = acceptanceFence.stamp
                        await installRestorationHint(hint, admittedBy: {
                            !self.isRetired && self.rosterRevision == roster && self.rosterPermits(hint.identity.profile)
                                && self.acceptanceFence.permits(id, since: stamp)
                        })
                    }
                }
                let loaded = try await cache.loadChats()
                guard !isRetired, rosterRevision == roster else { restorationFailed = true; return }
                @MainActor func canRestore(_ row: CachedArtifactChat) -> Bool {
                    guard !isRetired, self.rosterRevision == roster, self.rosterPermits(row.identity.profile) else { return false }
                    let id = key(for: row.identity)
                    guard let current = records[id] else {
                        return !self.unverifiedPersistenceChanges
                            || self.acceptanceFence.permits(id, since: self.initialRestorationStamp)
                    }
                    if row.directoryAbsent == true {
                        return initialSourceProofs[id] != current.identity.stored
                    }
                    if current.directoryAbsent { return false }
                    guard current.identity.stored != row.identity.stored else { return true }
                    return initialSourceProofs[id] != current.identity.stored
                        && row.retiredStoredIDs?.contains(current.identity.stored.bytes) == true
                }
                for row in loaded {
                    guard rosterRevision == roster else { restorationFailed = true; return }
                    let id = key(for: row.identity)
                    persistedIDs.insert(id)
                    if !rosterPermits(row.identity.profile) || (records[id] == nil && unverifiedPersistenceChanges
                        && !acceptanceFence.permits(id, since: initialRestorationStamp)) {
                        recordAcceptance(id)
                        withdraw([id])
                        scanNotice = .failure("Saved artifacts need a fresh history check. Pull to refresh to try again.")
                        continue
                    }
                    guard canRestore(row) else { continue }
                    // A checked saved row replaces the row-free hint left by a
                    // failed read. Keep its actual negative row evidence.
                    restorationHints.remove(id)
                    if let seeded = records[id], seeded.identity.stored != row.identity.stored {
                        initialReadRows[id] = nil; initialSourceProofs[id] = nil
                    }
                    if observations[id] == nil || observations[id]?.stored != row.identity.stored {
                        observe(row.identity, content: false, at: mountedAt)
                    }
                    await installAsync(source: row.identity, botName: row.botName, title: row.title, messages: row.messages,
                        updatedAt: row.updatedAt, reconciliation: .restore,
                        incomingCoverage: row.coverage == .complete ? .complete : .partial,
                        unavailableMessageIDs: row.unavailableMessageIDs ?? [],
                        removedMessageIDs: row.removedMessageIDs ?? [],
                        retiredStoredIDs: row.retiredStoredIDs ?? [],
                        directoryAbsent: row.directoryAbsent == true,
                        persistedRead: row, admittedBy: { canRestore(row) })
                }
                unreconciledSeedIDs = []
                restorationFailed = metadataRecovery.all || guardAdmissionFailure != guardFailure
                if !restorationFailed { unverifiedPersistenceChanges = false }
            } catch {
                if !isRetired {
                    restorationFailed = true
                    // A failed index read cannot certify an inert book seed.
                    metadataRecovery.all = true
                    withdrawUntrustedRestoration()
                    scanNotice = .failure("Saved artifacts couldn’t be loaded. Showing available content.")
                }
            }
        }
        restoreTask = task
        await task.value
        restoreTask = nil
    }

    private func cachedChat(_ id: LibraryChat.ID) -> CachedArtifactChat? {
        guard let chat = records[id], !restorationHints.contains(id) else { return nil }
        let tail = workingTail(in: chat.identity)
        return CachedArtifactChat(identity: chat.identity, botName: chat.botName, title: chat.title,
            messages: chat.messages.filter { Data($0.id.utf8) != tail }, updatedAt: chat.updatedAt,
            coverage: coverage[id] == .complete && tail == nil ? .complete : .partial,
            summary: summaries[id], headFingerprint: heads[id],
            unavailableMessageIDs: chat.unavailableMessageIDs.isEmpty ? nil : chat.unavailableMessageIDs,
            removedMessageIDs: chat.removedMessageIDs.isEmpty ? nil : chat.removedMessageIDs,
            retiredStoredIDs: chat.retiredStoredIDs.isEmpty ? nil : chat.retiredStoredIDs,
            directoryAbsent: chat.directoryAbsent ? true : nil)
    }

    private func readMetadataRecovery() async throws {
        guard let cache else { return }
        do {
            metadataRecovery = try await cache.metadataRecovery()
            if metadataRecovery.all || !metadataRecovery.invalidated.isEmpty {
                scanNotice = .failure("Saved artifacts need a fresh history check. Pull to refresh to try again.")
            }
        } catch {
            metadataRecovery = ArtifactMetadataRecovery(all: true)
            throw error
        }
    }

    private func withdrawUntrustedRestoration() {
        let unsafe = Set(records.values.filter {
            metadataRecovery.contains($0.identity) && initialSourceProofs[$0.id] != $0.identity.stored
        }.map(\.id))
        guard let target = unsafe.first else { return }
        restorationHints.formUnion(unsafe)
        for id in unsafe { unsettledTail[id] = nil; observations[id] = nil }
        let safe = records.values.map {
            Candidate(id: $0.id, source: $0.identity, botName: $0.botName, title: $0.title, updatedAt: $0.updatedAt,
                messages: unsafe.contains($0.id) ? [] : $0.messages,
                coverage: unsafe.contains($0.id) ? .partial : coverage[$0.id] ?? .partial,
                unavailableMessageIDs: $0.unavailableMessageIDs,
                removedMessageIDs: $0.removedMessageIDs,
                retiredStoredIDs: $0.retiredStoredIDs, directoryAbsent: $0.directoryAbsent)
        }
        commitCanonical(Admission(candidates: safe, limited: false), target: target)
        dirtyChats.subtract(unsafe)
    }

    private func installRestorationHint(_ hint: ArtifactMetadataHint, admittedBy: @MainActor () -> Bool) async {
        let id = key(for: hint.identity)
        guard rosterPermits(hint.identity.profile), admittedBy() else { return }
        if let current = records[id] {
            guard restorationHints.contains(id), current.identity.stored == hint.identity.stored else { return }
        }
        restorationHints.insert(id)
        _ = await installAsync(source: hint.identity, botName: hint.botName, title: hint.title, messages: [], updatedAt: hint.updatedAt,
            reconciliation: .seed, incomingCoverage: .partial, unavailableMessageIDs: hint.unavailableMessageIDs,
            removedMessageIDs: hint.removedMessageIDs, retiredStoredIDs: hint.retiredStoredIDs, admittedBy: admittedBy)
        if restorationHints.contains(id), admittedBy() { dirtyChats.remove(id) }
    }

    private func sameCachedChat(_ a: CachedArtifactChat, _ b: CachedArtifactChat, includingCertificate: Bool = true) -> Bool {
        a.identity == b.identity && Data(a.botName.utf8) == Data(b.botName.utf8) && Data(a.title.utf8) == Data(b.title.utf8)
            && sameMessages(a.messages, b.messages) && a.updatedAt == b.updatedAt && a.coverage == b.coverage
            && (!includingCertificate || (a.summary == b.summary && a.headFingerprint == b.headFingerprint))
            && (a.unavailableMessageIDs ?? []) == (b.unavailableMessageIDs ?? [])
            && (a.removedMessageIDs ?? []) == (b.removedMessageIDs ?? [])
            && (a.retiredStoredIDs ?? []) == (b.retiredStoredIDs ?? [])
            && (a.directoryAbsent == true) == (b.directoryAbsent == true)
    }

    private func persist() async {
        schedulePersistence()
        await persistenceTask?.value
    }

    private func recordAcceptance(_ id: LibraryChat.ID) {
        acceptanceFence.record(id)
        indexingMetrics.retainedAcceptanceFences = acceptanceFence.count
    }

    private func markDirty(_ id: LibraryChat.ID) {
        dirtyChats.insert(id); dirtyVersions[id] = UUID()
    }

    private func pendingMetadata() -> Set<LibraryChat.ID> {
        var savedOrWriting = persistedIDs
        if let inFlightUpsert { savedOrWriting.insert(inFlightUpsert) }
        return savedOrWriting.filter { records[$0] == nil }.union(dirtyChats.filter {
            records[$0] != nil && !restorationHints.contains($0) && !unreconciledSeedIDs.contains($0)
        })
    }

    private func schedulePersistence() {
        guard let cache, !isRetired else { return }
        // Never-saved evictions need no recovery guard. Keep saved and in-flight
        // owners even when the journal is unavailable.
        dirtyChats = dirtyChats.filter { records[$0] != nil }
        let pending = pendingMetadata().filter { restored || acceptanceFence.contains($0) }
        dirtyVersions = dirtyVersions.filter { pending.contains($0.key) }
        for id in pending where dirtyVersions[id] == nil { dirtyVersions[id] = UUID() }
        indexingMetrics.pendingMetadataIdentities = dirtyVersions.count
        // This bounded atomic ledger write is independent of SQL and precedes
        // the existing writer guard, including changes arriving while SQL waits.
        do {
            try cache.invalidateMetadata(pending.map { (profile: $0.profile, root: $0.root, revision: dirtyVersions[$0]!) })
        } catch {
            guardAdmissionFailure = UUID()
            if !restored || restorationFailed { unverifiedPersistenceChanges = true }
            scanNotice = .failure("Artifacts are available, but changes couldn’t be saved on this device.")
            return
        }
        guard restored, persistenceTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { persistenceTask = nil }
            do {
                while !isRetired {
                    if let id = persistedIDs.first(where: { records[$0] == nil }) {
                        try await cache.deleteChat(profile: id.profile, root: id.root)
                        persistedIDs.remove(id)
                        if records[id] == nil { dirtyVersions[id] = nil }
                        continue
                    }
                    dirtyChats = dirtyChats.filter { records[$0] != nil && !restorationHints.contains($0) && !unreconciledSeedIDs.contains($0) }
                    guard let id = dirtyChats.first, let row = cachedChat(id), let revision = dirtyVersions[id] else { return }
                    inFlightUpsert = id
                    defer { inFlightUpsert = nil }
                    try await cache.upsert(row, revision: revision)
                    persistedIDs.insert(id)
                    if dirtyVersions[id] == revision, let current = cachedChat(id), sameCachedChat(current, row) {
                        metadataRecovery.invalidated.remove(ArtifactMetadataRecovery.key(row.identity))
                        dirtyChats.remove(id); dirtyVersions[id] = nil
                    }
                }
            } catch {
                if !isRetired { scanNotice = .failure("Artifacts are available, but changes couldn’t be saved on this device.") }
            }
        }
        persistenceTask = task
    }

    func observeBots(_ bots: [BotProfile], evidence: RosterEvidence = .observed) {
        let names = Dictionary(bots.compactMap { bot in (try? ExactID(bot.id)).map { ($0, bot.name) } }, uniquingKeysWith: { first, _ in first })
        if evidence == .observed {
            let previous = rosterReadFloors
            if Set(previous?.keys.map { $0 } ?? Array(botNames.keys)) != Set(names.keys) { rosterRevision = UUID() }
            rosterBots = bots
            rosterReadFloors = names.mapValues { _ in mountedAt }
            for profile in names.keys {
                rosterReadFloors?[profile] = previous?[profile] ?? (previous == nil ? mountedAt : .now)
            }
            // Whole-profile absence withdraws even working chats before another
            // directory/history await can reuse their old observations.
            withdraw(Set(records.keys.filter { names[$0.profile] == nil }))
            observations = observations.filter { names[$0.key.profile] != nil }
        }
        if names != botNames { botNames = names; invalidateRevalidation() }
    }

    func invalidateRevalidation() {
        guard !isRetired else { return }
        revalidationRevision = UUID()
    }

    func accept(identity source: SessionIdentity, snapshot: Conversation, title: String, evidence: TranscriptEvidence) {
        guard !isRetired else { return }
        if let rosterReadFloors {
            guard let floor = rosterReadFloors[source.profile] else { return }
            switch evidence {
            case .read(let startedAt, _): guard startedAt >= floor else { return }
            case .incremental:
                guard floor == mountedAt || observations[key(for: source)] != nil else { return }
            }
        }
        let id = key(for: source), observation = observations[id]
        let expected = observation?.stored ?? records[id]?.identity.stored
        let provesSource: Bool
        switch evidence {
        case .read(let startedAt, let observedSource):
            provesSource = observedSource.map {
                $0.profile == source.profile && $0.root == source.root && $0.stored == source.stored
            } == true
            let floor = observation?.contentAt ?? mountedAt
            guard startedAt >= floor,
                  (records[id]?.directoryAbsent != true && !restorationHints.contains(id)) || provesSource,
                  expected == nil || expected == source.stored || (
                    startedAt >= (observation?.sourceAt ?? mountedAt) && provesSource) else { return }
        case .incremental:
            provesSource = false
            guard records[id]?.directoryAbsent != true, !restorationHints.contains(id), expected == nil || expected == source.stored else { return }
        }
        restorationHints.remove(id); unreconciledSeedIDs.remove(id)
        indexingMetrics.acceptedSnapshots += 1
        recordAcceptance(id)
        let previous = records[id]?.identity.stored == source.stored ? records[id] : nil
        let known = Dictionary((previous?.messages ?? []).map { (Data($0.id.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        let knownUnavailable = (snapshot.unavailableMessageIDs ?? []).union(duplicateMessageIDs(snapshot.messages))
        let messages: [ChatMessage]
        let unavailable: Set<Data>
        let protectsRestore: Bool
        switch evidence {
        case .read:
            messages = snapshot.messages; unavailable = knownUnavailable; protectsRestore = true
        case .incremental(let baseline):
            let sameSource = baseline.map {
                Data($0.storedID.utf8) == source.stored.bytes && Data($0.profileID.utf8) == source.profile.bytes
            } == true
            let prior = sameSource ? baseline?.messages ?? [] : []
            protectsRestore = sameSource && initialSourceProofs[id] == source.stored
            let priorUnsafe = (sameSource ? baseline?.unavailableMessageIDs ?? [] : []).union(duplicateMessageIDs(prior))
            let priorRows = Dictionary(prior.map { (Data($0.id.utf8), $0) }, uniquingKeysWith: { first, _ in first })
            unavailable = knownUnavailable.subtracting(priorUnsafe)
            messages = snapshot.messages.filter { message in
                let key = Data(message.id.utf8)
                guard previous?.unavailableMessageIDs.contains(key) != true,
                      previous?.removedMessageIDs.contains(key) != true else { return false }
                if let row = priorRows[key] {
                    return !priorUnsafe.contains(key) && known[key].map { TranscriptContentRevision.sameMessage($0, row) } == true
                }
                return sameSource || (previous == nil && observations[id] == nil)
            }
        }
        let tail = snapshot.isWorking && snapshot.messages.last?.role == .assistant
            ? snapshot.messages.last.map { WorkingTail(stored: source.stored, messageID: Data($0.id.utf8)) } : nil
        if unsettledTail[id] != tail { unsettledTail[id] = tail; markDirty(id) }
        let admission = prepareAdmission(source: source, botName: botNames[source.profile] ?? source.profile.text, title: title,
            messages: messages, updatedAt: newest(previous?.updatedAt, messages.last?.timestamp),
            reconciliation: .accepted, incomingCoverage: .partial, unavailableMessageIDs: unavailable, removedMessageIDs: [], retiredStoredIDs: [])
        commitCanonical(admission, target: id, projectionOwner: .caller)
        if (!restored || restorationFailed), provesSource, records[id]?.identity.stored == source.stored { initialSourceProofs[id] = source.stored }
        if records[id]?.identity.stored == source.stored {
            if case .read = evidence { observe(source, content: true) }
            else if !sameMessages(previous?.messages ?? [], records[id]?.messages ?? [])
                || previous?.unavailableMessageIDs != records[id]?.unavailableMessageIDs {
                observe(source, content: true)
            }
        }
        if (!restored || restorationFailed), protectsRestore, !messages.isEmpty {
            initialReadRows[id] = (initialReadRows[id] ?? []).union(messages.map { Data($0.id.utf8) }).subtracting(unavailable)
                .intersection(Set(records[id]?.messages.map { Data($0.id.utf8) } ?? []))
        }
        pendingTranscripts[id] = projectionStates[id]?.version
        scheduleTranscripts(delayed: snapshot.isWorking)
    }

    private func scheduleTranscripts(delayed: Bool) {
        if !delayed, !transcriptDraining { transcriptTask?.cancel(); transcriptTask = nil }
        guard transcriptTask == nil else { return }
        transcriptTask = Task { [weak self] in
            if delayed { try? await Task.sleep(for: .milliseconds(750)) }
            guard !Task.isCancelled, let self else { return }
            await drainTranscripts()
        }
    }

    private func drainTranscripts() async {
        transcriptDraining = true
        defer { transcriptTask = nil; transcriptDraining = false }
        await restore()
        while !pendingTranscripts.isEmpty, !isRetired, !Task.isCancelled {
            let pending = pendingTranscripts
            pendingTranscripts = [:]
            let started = ContinuousClock.now
            indexingMetrics.batches += 1
            for (id, version) in pending {
                guard projectionStates[id]?.version == version, !projectionIsCurrent(id) else { continue }
                if await enrichCurrent(id, while: { !self.isRetired && !Task.isCancelled && self.projectionStates[id]?.version == version }) {
                    indexingMetrics.parsedMessages += records[id]?.messages.count ?? 0
                }
            }
            indexingMetrics.processingDuration += started.duration(to: .now)
            await persist()
        }
    }

    var warning: String? {
        guard !isRetired else { return nil }
        if !online { return "You’re offline. Showing previously loaded chats and artifacts." }
        if isScanning { return statusBeforeScan?.warning }
        if let scanNotice { return scanNotice.message }
        if freshnessUnverified { return "Showing saved history. Older messages haven’t been checked for changes. Pull to refresh to check all history." }
        if capacityLimited || coverage.values.contains(where: { $0 == .partial }) {
            return "Showing available history. Older results may be missing."
        }
        return nil
    }
    enum StatusAction { case retry, checkOlderHistory }
    var statusAction: StatusAction? {
        guard !isRetired, online else { return nil }
        if isScanning { return statusBeforeScan?.action }
        if let scanNotice {
            switch scanNotice {
            case .failure: return .retry
            case .incomplete: return nil
            }
        }
        return freshnessUnverified ? .checkOlderHistory : nil
    }
    var chats: [LibraryChat] {
        records.values.filter { rosterPermits($0.identity.profile) && !$0.directoryAbsent && !restorationHints.contains($0.id) && !unreconciledSeedIDs.contains($0.id) }.sorted {
            if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            let name = $0.botName.localizedStandardCompare($1.botName)
            if name != .orderedSame { return name == .orderedAscending }
            let title = $0.title.localizedStandardCompare($1.title)
            if title != .orderedSame { return title == .orderedAscending }
            if $0.identity.profile != $1.identity.profile {
                return $0.identity.profile.bytes.lexicographicallyPrecedes($1.identity.profile.bytes)
            }
            return $0.identity.root.bytes.lexicographicallyPrecedes($1.identity.root.bytes)
        }
    }
    var artifacts: [LibraryArtifact] {
        chats.flatMap { chat in chat.discoveredArtifacts.map { LibraryArtifact(chat: chat, artifact: $0) } }
            .sorted {
                let a = $0.artifact.timestamp ?? $0.chat.updatedAt ?? .distantPast
                let b = $1.artifact.timestamp ?? $1.chat.updatedAt ?? .distantPast
                if a != b { return a > b }
                let name = $0.artifact.title.localizedStandardCompare($1.artifact.title)
                if name != .orderedSame { return name == .orderedAscending }
                if $0.chat.identity.profile != $1.chat.identity.profile {
                    return $0.chat.identity.profile.bytes.lexicographicallyPrecedes($1.chat.identity.profile.bytes)
                }
                return $0.chat.identity.root.bytes.lexicographicallyPrecedes($1.chat.identity.root.bytes)
            }
    }

    func seed(book: ConversationBook, bots: [BotProfile]) {
        guard !isRetired else { return }
        seedVersion = UUID()
        pendingSeed = (book, bots, acceptanceFence.stamp, rosterRevision, seedVersion)
        guard seedTask == nil else { return }
        localWorkCount += 1
        seedTask = Task { [weak self] in
            guard let self else { return }
            defer { seedTask = nil; localWorkCount -= 1 }
            while let seed = pendingSeed, !isRetired, !Task.isCancelled {
                pendingSeed = nil
                do { try await readMetadataRecovery() }
                catch { scanNotice = .failure("Saved artifacts couldn’t be verified. Refresh to check history.") }
                let names = Dictionary(seed.bots.compactMap { bot in (try? ExactID(bot.id)).map { ($0, bot.name) } },
                    uniquingKeysWith: { first, _ in first })
                for record in seed.book.records where !record.isUnverified {
                    guard seedVersion == seed.request, rosterRevision == seed.roster else { break }
                    guard let source = record.binding.identity, let name = names[source.profile], let transcript = record.transcript,
                          Data(transcript.profileID.utf8) == source.profile.bytes,
                          Data(transcript.storedID.utf8) == source.stored.bytes else { continue }
                    let id = key(for: source)
                    guard rosterPermits(source.profile) else { continue }
                    guard acceptanceFence.permits(id, since: seed.accepted), records[id]?.directoryAbsent != true,
                          records[id] == nil || records[id]?.identity.stored == source.stored else { continue }
                    if metadataRecovery.contains(source) {
                        if !restored, records[id] == nil {
                            let hint = ArtifactMetadataHint(identity: source, botName: name, title: record.title, updatedAt: record.updatedAt,
                                unavailableMessageIDs: (transcript.unavailableMessageIDs ?? []).union(transcript.messages.map { Data($0.id.utf8) }),
                                removedMessageIDs: [], retiredStoredIDs: [])
                            await installRestorationHint(hint, admittedBy: { !self.isRetired && !Task.isCancelled && self.seedVersion == seed.request
                                && self.acceptanceFence.permits(id, since: seed.accepted) })
                        }
                        continue
                    }
                    if !restored { unreconciledSeedIDs.insert(id) }
                    if transcript.isWorking, let tail = transcript.messages.last, tail.role == .assistant {
                        unsettledTail[id] = WorkingTail(stored: source.stored, messageID: Data(tail.id.utf8)); markDirty(id)
                    }
                    await installAsync(source: records[id]?.identity ?? source, botName: name, title: record.title,
                        messages: transcript.messages, updatedAt: newest(record.updatedAt, transcript.messages.last?.timestamp),
                        reconciliation: .seed, incomingCoverage: .partial,
                        unavailableMessageIDs: transcript.unavailableMessageIDs ?? [],
                        removedMessageIDs: [],
                        retiredStoredIDs: [],
                        admittedBy: { !self.isRetired && !Task.isCancelled && self.seedVersion == seed.request
                            && self.rosterRevision == seed.roster && self.rosterPermits(source.profile)
                            && self.records[id]?.directoryAbsent != true
                            && self.acceptanceFence.permits(id, since: seed.accepted)
                            && (self.records[id] == nil || self.records[id]?.identity.stored == source.stored) })
                }
                await restoreSavedIndex()
            }
        }
    }

    func setOnline(_ value: Bool) {
        guard !isRetired, online != value else { return }
        online = value
        invalidateRevalidation()
        thumbnailAvailabilityRevision = UUID()
        if !value { cancelOperations() }
    }
    func retire() {
        guard !isRetired else { return }
        isRetired = true; online = false
        cache?.retire(); restoreTask?.cancel(); seedTask?.cancel(); pendingSeed = nil
        persistenceTask?.cancel(); transcriptTask?.cancel(); pendingTranscripts = [:]; originals = [:]
        cancelOperations()
        acceptanceFence = AcceptanceFence(capacity: acceptanceFence.capacity); indexingMetrics.retainedAcceptanceFences = 0
        records = [:]; coverage = [:]; scanNotice = nil; observations = [:]; initialReadRows = [:]; initialSourceProofs = [:]; projectionStates = [:]; restorationHints = []; unreconciledSeedIDs = []; dirtyVersions = [:]
        reconcileProjectionWaiters()
    }
    private func cancelOperations() {
        generation = UUID()
        scanTask?.cancel(); scanTask = nil; isScanning = false; statusBeforeScan = nil
        requiresForcedPass = false; scanningForced = false
        for flight in flights.values { flight.admission.revokeAll(); flight.task.cancel() }; flights = [:]
    }
    func refreshIfNeeded(bots: [BotProfile]) async {
        observeBots(bots)
        await restore()
        while !isRetired, online, !Task.isCancelled {
            if scanTask == nil, let lastRevalidation,
               lastRevalidation.revision == revalidationRevision,
               lastRevalidation.at.duration(to: now()) < .seconds(60) { return }
            // Tab navigation does not own the mounted library's background read.
            let revalidation = Task { await refreshCurrentRoster(force: false) }
            await revalidation.value
        }
    }

    func refresh(bots: [BotProfile], force: Bool = false) async {
        observeBots(bots)
        await refreshCurrentRoster(force: force)
    }

    private func refreshCurrentRoster(force: Bool) async {
        await restore()
        guard !isRetired, online, !Task.isCancelled else { return }
        if let scanTask {
            if force, !scanningForced {
                requiresForcedPass = true
                indexingMetrics.forcedRefreshesJoined += 1
            }
            await scanTask.value
            return
        }
        let owner = generation
        statusBeforeScan = (warning, statusAction)
        isScanning = true
        scanningForced = force
        let request = UUID()
        scanIdentity = request
        let task = Task {
            defer {
                if generation == owner, scanIdentity == request {
                    scanTask = nil; isScanning = false; statusBeforeScan = nil
                    requiresForcedPass = false; scanningForced = false
                }
            }
            var nextForced = force
            while accepts(owner) {
                let roster = rosterRevision, revision = revalidationRevision
                scanningForced = nextForced
                await scan(bots: rosterBots, owner: owner, force: nextForced)
                guard accepts(owner) else { return }
                if rosterRevision == roster, !requiresForcedPass {
                    lastRevalidation = (now(), revision)
                    return
                }
                nextForced = nextForced || requiresForcedPass
                requiresForcedPass = false
            }
        }
        scanTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard generation == owner, scanIdentity == request else { return }
        if task.isCancelled {
            scanNotice = .failure("Loading stopped before all history was indexed. Refresh to load the remaining results.")
        }
    }

    private func key(for source: SessionIdentity) -> LibraryChat.ID {
        .init(workspace: identity, profile: source.profile, root: source.root)
    }
    private func newest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (nil, nil): nil
        case (let date?, nil), (nil, let date?): date
        case (let a?, let b?): max(a, b)
        }
    }

    private func sameMessages(_ a: [ChatMessage], _ b: [ChatMessage]) -> Bool {
        a.elementsEqual(b, by: TranscriptContentRevision.sameMessage)
    }

    private func duplicateMessageIDs(_ messages: [ChatMessage]) -> Set<Data> {
        var seen = Set<Data>(), duplicates = Set<Data>()
        for message in messages {
            let id = Data(message.id.utf8)
            if !seen.insert(id).inserted { duplicates.insert(id) }
        }
        return duplicates
    }

    /// Admit rows before discovery. Both inputs are chronological; merge them
    /// newest-first without allocating a combined, potentially oversized cache.
    private func boundedMessages(_ incoming: [ChatMessage], existing: [ChatMessage],
                                 reconciliation: Reconciliation, count: Int, bytes: Int,
                                 excluding unavailable: Set<Data> = []) -> (messages: [ChatMessage], trimmed: Bool) {
        let prior = reconciliation == .replace ? [] : existing
        let previousByID = Dictionary(prior.map { (Data($0.id.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        let acceptedRevisions: Set<Data> = reconciliation == .accepted
            ? Set(incoming.lazy.map { Data($0.id.utf8) }.filter { previousByID[$0] != nil }) : []
        var incomingIndex = incoming.count - 1, previousIndex = prior.count - 1
        var newestFirst: [ChatMessage] = [], admitted = Set<Data>(), usedBytes = 0, trimmed = false
        while incomingIndex >= 0 || previousIndex >= 0 {
            let fromIncoming = incomingIndex >= 0 && (previousIndex < 0 ||
                (reconciliation != .olderPage &&
                 (incoming[incomingIndex].timestamp ?? .distantPast) >= (prior[previousIndex].timestamp ?? .distantPast)))
            var message: ChatMessage
            if fromIncoming { message = incoming[incomingIndex]; incomingIndex -= 1 }
            else { message = prior[previousIndex]; previousIndex -= 1 }
            let id = Data(message.id.utf8)
            guard !unavailable.contains(id) else { continue }
            if !fromIncoming, acceptedRevisions.contains(id) { continue }
            guard !admitted.contains(id) else { continue }
            if fromIncoming, let old = previousByID[id] {
                if reconciliation != .accepted {
                    message = old
                }
            }
            let cost = message.text.utf8.count
            guard newestFirst.count < count, cost <= bytes - usedBytes else { trimmed = true; continue }
            newestFirst.append(message); admitted.insert(id); usedBytes += cost
        }
        return (Array(newestFirst.reversed()), trimmed)
    }

    private func prepareAdmission(source: SessionIdentity, botName: String, title: String, messages: [ChatMessage],
                                  updatedAt: Date?, reconciliation: Reconciliation, incomingCoverage: Coverage,
                                  unavailableMessageIDs: Set<Data>, removedMessageIDs: Set<Data>, retiredStoredIDs: Set<Data>,
                                  directoryAbsent: Bool = false) -> Admission {
        let key = key(for: source), previous = records[key]
        let sameTip = previous?.identity.stored == source.stored
        var unavailable = sameTip ? previous?.unavailableMessageIDs ?? [] : []
        var removed = sameTip ? previous?.removedMessageIDs ?? [] : []
        var retired = previous?.retiredStoredIDs ?? []
        if let previous, !sameTip, [.accepted, .replace, .observedSource].contains(reconciliation) {
            retired.insert(previous.identity.stored.bytes)
        }
        retired.formUnion(retiredStoredIDs); retired.remove(source.stored.bytes)
        let incomingIDs = Set(messages.map { Data($0.id.utf8) })
        switch reconciliation {
        case .replace:
            unavailable = []
            removed.formUnion((sameTip ? previous?.messages ?? [] : []).map { Data($0.id.utf8) })
            removed.subtract(incomingIDs)
        case .accepted:
            unavailable.subtract(incomingIDs)
            removed.subtract(incomingIDs)
        case .seed, .merge, .olderPage, .observedSource: break
        case .absent: unavailable = []; removed = []
        case .restore:
            if directoryAbsent { unavailable = []; removed = []; break }
            let protected = initialReadRows[key] ?? []
            let saved = Dictionary((sameTip ? previous?.messages ?? [] : []).map { (Data($0.id.utf8), $0) }, uniquingKeysWith: { first, _ in first })
            // Independently persisted copies have no comparable revision order.
            if incomingCoverage == .complete {
                unavailable.formUnion(saved.keys.filter { !protected.contains($0) && !incomingIDs.contains($0) && !removedMessageIDs.contains($0) })
            }
            for message in messages {
                let id = Data(message.id.utf8)
                if !protected.contains(id), let other = saved[id], !TranscriptContentRevision.sameMessage(other, message) { unavailable.insert(id) }
            }
        }
        let protected = reconciliation == .restore ? initialReadRows[key] ?? [] : []
        unavailable.formUnion(unavailableMessageIDs.subtracting(protected))
        unavailable.formUnion(duplicateMessageIDs(messages).subtracting(protected))
        unavailable.formUnion(messages.lazy.filter { !$0.hasStableIdentity(storedID: source.stored.text) }.map { Data($0.id.utf8) })
        removed.formUnion(removedMessageIDs.subtracting(protected))
        let absent = directoryAbsent || reconciliation == .absent
        let existing = sameTip && !absent ? previous?.messages ?? [] : []
        let incoming: [ChatMessage]
        if reconciliation == .seed, sameTip, coverage[key] == .complete {
            let retainedIDs = Set(existing.map { Data($0.id.utf8) })
            unavailable.formUnion(incomingIDs.subtracting(retainedIDs).subtracting(removed))
            incoming = messages.filter { retainedIDs.contains(Data($0.id.utf8)) }
        } else { incoming = absent ? [] : messages }
        let local = boundedMessages(incoming, existing: existing, reconciliation: reconciliation,
            count: limits.messageCount, bytes: limits.textBytes, excluding: unavailable.union(removed))
        let sourceCoverage: Coverage
        let hasLiveTail = !absent && workingTail(in: source) != nil
        if !unavailable.isEmpty { sourceCoverage = .partial }
        else if (reconciliation == .seed || reconciliation == .restore || reconciliation == .accepted), sameTip, coverage[key] == .complete,
           sameMessages(local.messages, previous?.messages ?? []), !local.trimmed, !hasLiveTail {
            sourceCoverage = .complete
        } else {
            sourceCoverage = incomingCoverage == .complete && !local.trimmed && !hasLiveTail
                && ((reconciliation != .seed && reconciliation != .restore) || sameMessages(local.messages, messages)) ? .complete : .partial
        }
        let date = reconciliation == .seed ? newest(updatedAt, sameTip ? previous?.updatedAt : nil) : updatedAt ?? previous?.updatedAt
        var candidates = records.values.filter { $0.id != key }.map {
            Candidate(id: $0.id, source: $0.identity, botName: $0.botName, title: $0.title,
                updatedAt: $0.updatedAt, messages: $0.messages, coverage: coverage[$0.id] ?? .partial,
                unavailableMessageIDs: $0.unavailableMessageIDs, removedMessageIDs: $0.removedMessageIDs,
                retiredStoredIDs: $0.retiredStoredIDs, directoryAbsent: $0.directoryAbsent)
        }
        candidates.append(Candidate(id: key, source: source, botName: botName, title: title,
            updatedAt: date, messages: local.messages, coverage: sourceCoverage, unavailableMessageIDs: unavailable, removedMessageIDs: removed,
            retiredStoredIDs: retired, directoryAbsent: absent))
        candidates.removeAll { !rosterPermits($0.source.profile) }
        candidates.sort { a, b in
            if a.updatedAt != b.updatedAt { return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast) }
            if a.source.profile != b.source.profile { return a.source.profile.bytes.lexicographicallyPrecedes(b.source.profile.bytes) }
            return a.source.root.bytes.lexicographicallyPrecedes(b.source.root.bytes)
        }
        var remainingCount = limits.messageCount, remainingBytes = limits.textBytes
        var limited = local.trimmed || candidates.count > limits.chatCount
        let retained = candidates.prefix(limits.chatCount).compactMap { candidate -> Candidate? in
            let excluded = candidate.unavailableMessageIDs.union(candidate.removedMessageIDs)
            let unavailableBytes = excluded.reduce(0) { $0 + $1.count } + candidate.retiredStoredIDs.reduce(0) { $0 + $1.count }
            let evidenceCount = excluded.count + candidate.retiredStoredIDs.count
            guard evidenceCount <= remainingCount, unavailableBytes <= remainingBytes else {
                limited = true; return nil
            }
            remainingCount -= evidenceCount
            remainingBytes -= unavailableBytes
            let kept = boundedMessages(candidate.messages, existing: [], reconciliation: .replace,
                count: remainingCount, bytes: remainingBytes)
            remainingCount -= kept.messages.count
            remainingBytes -= kept.messages.reduce(0) { $0 + $1.text.utf8.count }
            limited = limited || kept.trimmed
            return Candidate(id: candidate.id, source: candidate.source, botName: candidate.botName, title: candidate.title,
                updatedAt: candidate.updatedAt, messages: kept.messages, coverage: kept.trimmed ? .partial : candidate.coverage,
                unavailableMessageIDs: candidate.unavailableMessageIDs, removedMessageIDs: candidate.removedMessageIDs,
                retiredStoredIDs: candidate.retiredStoredIDs, directoryAbsent: candidate.directoryAbsent)
        }
        return Admission(candidates: retained, limited: limited)
    }

    nonisolated static func project(_ messages: [ChatMessage], streamingMessage: ChatMessage?) async -> Projection {
        await Task.detached(priority: .utility) {
            let artifacts = Self.discover(messages, streamingMessage: streamingMessage)
            let producers = Set(artifacts.map { Data($0.messageID.utf8) })
            let revisions = Dictionary(messages.filter { producers.contains(Data($0.id.utf8)) }.map {
                (Data($0.id.utf8), fingerprintBytes([$0]))
            }, uniquingKeysWith: { first, _ in first })
            return Projection(artifacts: artifacts, revisions: revisions, searchableText: LibraryChat.searchIndex(messages))
        }.value
    }

    private func commit(_ admission: Admission, discoveries: [LibraryChat.ID: Projection]) {
        var next: [LibraryChat.ID: LibraryChat] = [:], nextCoverage: [LibraryChat.ID: Coverage] = [:]
        for candidate in admission.candidates where rosterPermits(candidate.source.profile) {
            let chat = LibraryChat(workspace: identity, identity: candidate.source, botName: candidate.botName,
                title: candidate.title, messages: candidate.messages, updatedAt: candidate.updatedAt,
                discoveredArtifacts: discoveries[candidate.id]?.artifacts ?? [], sourceRevisions: discoveries[candidate.id]?.revisions ?? [:],
                searchableText: discoveries[candidate.id]?.searchableText ?? [:], unavailableMessageIDs: candidate.unavailableMessageIDs,
                removedMessageIDs: candidate.removedMessageIDs, retiredStoredIDs: candidate.retiredStoredIDs,
                directoryAbsent: candidate.directoryAbsent)
            next[candidate.id] = chat
            nextCoverage[candidate.id] = candidate.coverage
            if records[candidate.id] != chat || coverage[candidate.id] != candidate.coverage { markDirty(candidate.id) }
            if records[candidate.id]?.identity != chat.identity
                || !sameMessages(records[candidate.id]?.messages ?? [], chat.messages)
                || coverage[candidate.id] != candidate.coverage {
                summaries[candidate.id] = nil; heads[candidate.id] = nil
            }
        }
        capacityLimited = capacityLimited || admission.limited
        var nextStates: [LibraryChat.ID: ProjectionState] = [:]
        for (id, chat) in next {
            let tail = !chat.directoryAbsent && unsettledTail[id]?.stored == chat.identity.stored ? unsettledTail[id] : nil
            if let old = records[id], let state = projectionStates[id], old.identity == chat.identity,
               sameMessages(old.messages, chat.messages), state.tail == tail {
                nextStates[id] = state
            } else { nextStates[id] = ProjectionState(version: UUID(), tail: tail) }
        }
        // Suspend gallery publication before replacing its canonical evidence.
        // Valid historical readers retain their independent admission.
        for flight in flights.values {
            flight.admission.updateReadiness(flight.consumers.mapValues { consumer in
                guard let id = consumer.projection else { return true }
                guard let state = nextStates[id] else { return false }
                return state.published == state.version
            })
        }
        for id in records.keys where next[id] == nil { markDirty(id); recordAcceptance(id) }
        records = next; coverage = nextCoverage; projectionStates = nextStates
        unreconciledSeedIDs.formIntersection(next.keys)
        restorationHints.formIntersection(next.keys)
        unsettledTail = unsettledTail.filter { next[$0.key]?.directoryAbsent == false && next[$0.key]?.identity.stored == $0.value.stored }
        observations = observations.filter { next[$0.key] != nil }
        initialReadRows = initialReadRows.reduce(into: [:]) { result, entry in
            guard let chat = next[entry.key] else { return }
            result[entry.key] = entry.value.intersection(chat.messages.map { Data($0.id.utf8) })
        }
        initialSourceProofs = initialSourceProofs.filter { next[$0.key]?.identity.stored == $0.value }
        reconcileOriginalConsumers()
        summaries = summaries.filter { next[$0.key] != nil }; heads = heads.filter { next[$0.key] != nil }
    }

    private func withdraw(_ ids: Set<LibraryChat.ID>) {
        guard let target = ids.first else { return }
        let remaining = records.values.filter { !ids.contains($0.id) }.map {
            Candidate(id: $0.id, source: $0.identity, botName: $0.botName, title: $0.title, updatedAt: $0.updatedAt,
                messages: $0.messages, coverage: coverage[$0.id] ?? .partial,
                unavailableMessageIDs: $0.unavailableMessageIDs, removedMessageIDs: $0.removedMessageIDs,
                retiredStoredIDs: $0.retiredStoredIDs, directoryAbsent: $0.directoryAbsent)
        }
        commitCanonical(Admission(candidates: remaining, limited: false), target: target)
    }

    private func commitCanonical(_ admission: Admission, target: LibraryChat.ID,
                                 projectionOwner: ProjectionOwner = .background, persistedRead: CachedArtifactChat? = nil) {
        let savedBefore = cachedChat(target), wasDirty = dirtyChats.contains(target)
        let previousVersions = projectionStates.mapValues(\.version)
        var retained: [LibraryChat.ID: Projection] = [:]
        for candidate in admission.candidates {
            guard let old = records[candidate.id], old.identity.stored == candidate.source.stored else { continue }
            let prior = Dictionary(old.messages.map { (Data($0.id.utf8), $0) }, uniquingKeysWith: { first, _ in first })
            let stable = Set(candidate.messages.compactMap { message -> Data? in
                let id = Data(message.id.utf8)
                guard prior[id].map({ TranscriptContentRevision.sameMessage($0, message) }) == true else { return nil }
                return id
            })
            retained[candidate.id] = Projection(artifacts: old.discoveredArtifacts.filter { stable.contains(Data($0.messageID.utf8)) },
                revisions: old.sourceRevisions.filter { stable.contains($0.key) },
                searchableText: old.searchableText.filter { stable.contains($0.key) })
        }
        commit(admission, discoveries: retained)
        // Reinstalling a checked saved row is a read, not a new metadata edit.
        // Resolve it before persistence can create a speculative guard.
        if !wasDirty, let persistedRead, let current = cachedChat(target),
           sameCachedChat(current, persistedRead, includingCertificate: false) {
            summaries[target] = persistedRead.summary; heads[target] = persistedRead.headFingerprint
            dirtyChats.remove(target); dirtyVersions[target] = nil
        }
        var needsProjection = false
        for (id, state) in projectionStates where (id != target || projectionOwner == .background) && !projectionIsCurrent(id)
            && state.version != previousVersions[id] && records[id]?.directoryAbsent == false && !restorationHints.contains(id) {
            pendingTranscripts[id] = state.version
            needsProjection = true
        }
        if needsProjection { scheduleTranscripts(delayed: false) }
        if !wasDirty, let savedBefore, let savedAfter = cachedChat(target), sameCachedChat(savedBefore, savedAfter) {
            dirtyChats.remove(target)
        }
        schedulePersistence()
    }

    private func enrichCurrent(_ id: LibraryChat.ID, while admittedBy: @MainActor () -> Bool) async -> Bool {
        while admittedBy() {
            guard let chat = records[id] else { return true }
            guard let version = projectionStates[id]?.version else { return true }
            let tail = chat.messages.first { Data($0.id.utf8) == workingTail(in: chat.identity) }
            let projection = await projector(chat.messages, tail)
            guard admittedBy() else { return false }
            guard let current = records[id] else { return true }
            guard projectionStates[id]?.version == version else { continue }
            records[id] = LibraryChat(workspace: identity, identity: current.identity, botName: current.botName,
                title: current.title, messages: current.messages, updatedAt: current.updatedAt,
                discoveredArtifacts: projection.artifacts, sourceRevisions: projection.revisions,
                searchableText: projection.searchableText, unavailableMessageIDs: current.unavailableMessageIDs,
                removedMessageIDs: current.removedMessageIDs, retiredStoredIDs: current.retiredStoredIDs,
                directoryAbsent: current.directoryAbsent)
            projectionStates[id]?.published = version
            schedulePersistence()
            reconcileOriginalConsumers()
            return true
        }
        return false
    }

    private func projectionIsCurrent(_ id: LibraryChat.ID) -> Bool {
        guard let chat = records[id], !chat.directoryAbsent, !restorationHints.contains(id), let state = projectionStates[id] else { return false }
        return state.published == state.version
    }

    private func waitForProjection(of item: LibraryArtifact) async throws {
        while true {
            try Task.checkCancellation()
            guard isCurrent(item) else { throw HermesServiceError.staleConversation }
            if projectionIsCurrent(item.chat.id) { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if !isCurrent(item) || projectionIsCurrent(item.chat.id) { continuation.resume() }
                    else { projectionWaiters[id] = ProjectionWaiter(item: item, continuation: continuation) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.projectionWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func reconcileProjectionWaiters() {
        let ready = projectionWaiters.filter { !isCurrent($0.value.item) || projectionIsCurrent($0.value.item.chat.id) }
        for (id, waiter) in ready {
            projectionWaiters[id] = nil
            waiter.continuation.resume()
        }
    }

    private func quarantine(_ ids: Set<Data>, source: SessionIdentity) {
        let id = key(for: source)
        guard let chat = records[id], chat.identity.stored == source.stored else { return }
        let retained = Set(chat.messages.map { Data($0.id.utf8) }).union(chat.unavailableMessageIDs)
        let unavailable = ids.intersection(retained)
        guard !unavailable.isSubset(of: chat.unavailableMessageIDs) else { return }
        commitCanonical(prepareAdmission(source: source, botName: chat.botName, title: chat.title, messages: [],
            updatedAt: chat.updatedAt, reconciliation: .merge, incomingCoverage: .partial,
            unavailableMessageIDs: unavailable, removedMessageIDs: [], retiredStoredIDs: []), target: id)
    }

    private func quarantineFailure(_ error: any Error, source: SessionIdentity) {
        guard let failure = error as? ConversationHistoryPage.Failure,
              failure.identity.profile == source.profile, failure.identity.root == source.root,
              failure.identity.stored == source.stored else { return }
        quarantine(failure.unavailableMessageIDs, source: source)
    }

    private func pageAmbiguity(_ page: ConversationHistoryPage, source: SessionIdentity) -> Set<Data> {
        let visible = Set(page.messages.map { Data($0.id.utf8) })
        let hidden = (page.sourceIDs ?? visible).subtracting(visible)
        let retained = Set(records[key(for: source)]?.messages.map { Data($0.id.utf8) } ?? [])
        return page.unavailableMessageIDs.union(duplicateMessageIDs(page.messages)).union(hidden.intersection(retained))
    }

    private func observe(_ source: SessionIdentity, content: Bool, at instant: ContinuousClock.Instant = .now) {
        let id = key(for: source), previous = observations[id]
        let sameTip = previous?.stored == source.stored
        observations[id] = SourceObservation(stored: source.stored,
            sourceAt: sameTip ? previous?.sourceAt ?? instant : instant,
            contentAt: content ? instant : (sameTip ? previous?.contentAt : nil))
    }

    @discardableResult private func installAsync(source: SessionIdentity, botName: String, title: String, messages: [ChatMessage],
        updatedAt: Date?, reconciliation: Reconciliation, incomingCoverage: Coverage,
        unavailableMessageIDs: Set<Data>,
        removedMessageIDs: Set<Data>,
        retiredStoredIDs: Set<Data>,
        directoryAbsent: Bool = false,
        persistedRead: CachedArtifactChat? = nil,
        admittedBy: @MainActor () -> Bool, onCommit: @MainActor () -> Void = {}) async -> Bool {
        guard rosterPermits(source.profile), admittedBy() else { return false }
        let target = key(for: source)
        commitCanonical(prepareAdmission(source: source, botName: botName, title: title, messages: messages,
            updatedAt: updatedAt, reconciliation: reconciliation, incomingCoverage: incomingCoverage,
            unavailableMessageIDs: unavailableMessageIDs, removedMessageIDs: removedMessageIDs,
            retiredStoredIDs: retiredStoredIDs, directoryAbsent: directoryAbsent), target: target,
            projectionOwner: .caller, persistedRead: persistedRead)
        let admitted = cachedChat(target)
        // Passive discovery follows the workspace after admission; completion
        // metadata still belongs to the original read and canonical rows.
        _ = await enrichCurrent(target, while: { !self.isRetired && admittedBy() })
        guard admittedBy(), let admitted, let current = cachedChat(target), sameCachedChat(admitted, current) else { return false }
        let beforeCompletion = cachedChat(target), wasDirty = dirtyChats.contains(target)
        onCommit()
        if !wasDirty, let beforeCompletion, let after = cachedChat(target), sameCachedChat(beforeCompletion, after) {
            dirtyChats.remove(target)
        }
        schedulePersistence()
        return true
    }

    private func scan(bots: [BotProfile], owner: UUID, force: Bool) async {
        let roster = rosterRevision
        func currentScan() -> Bool { current(owner) && rosterRevision == roster }
        func acceptsScan() -> Bool { accepts(owner) && rosterRevision == roster }
        defer {
            schedulePersistence()
            if acceptsScan() { thumbnailAvailabilityRevision = UUID() }
        }
        let acceptedAtStart = acceptanceFence.stamp
        func canScan(_ id: LibraryChat.ID) -> Bool {
            rosterRevision == roster && rosterPermits(id.profile) && acceptanceFence.permits(id, since: acceptedAtStart)
        }
        var failures = 0, incomplete = false, readMessages = 0, readBytes = 0
        let maximumReadMessages = 25_000, maximumReadBytes = 32 * 1024 * 1024
        scanNotice = nil; capacityLimited = false; freshnessUnverified = false
        var summaries: [(BotProfile, SessionSummary)] = []
        var completeDirectories: Set<ExactID> = []
        func newestSummaries(_ values: [(BotProfile, SessionSummary)]) -> [(BotProfile, SessionSummary)] {
            values.sorted {
                if $0.1.updatedAt != $1.1.updatedAt { return ($0.1.updatedAt ?? .distantPast) > ($1.1.updatedAt ?? .distantPast) }
                if $0.1.identity.profile != $1.1.identity.profile {
                    return $0.1.identity.profile.bytes.lexicographicallyPrecedes($1.1.identity.profile.bytes)
                }
                return $0.1.identity.root.bytes.lexicographicallyPrecedes($1.1.identity.root.bytes)
            }
        }
        for bot in bots {
            guard acceptsScan() else { return }
            guard let profile = try? ExactID(bot.id) else { failures += 1; continue }
            do {
                let directory = try await service.conversations(profile: profile)
                guard acceptsScan() else { return }
                incomplete = incomplete || !directory.isComplete
                if directory.isComplete { completeDirectories.insert(profile) }
                var observedRetained = Set<LibraryChat.ID>()
                for summary in directory.summaries where summary.identity.profile == profile {
                    let key = key(for: summary.identity)
                    guard canScan(key) else { observedRetained.insert(key); incomplete = true; continue }
                    restorationHints.remove(key); unreconciledSeedIDs.remove(key)
                    if let previous = records[key] {
                        observedRetained.insert(key)
                        if previous.directoryAbsent || previous.identity.stored != summary.identity.stored {
                            observe(summary.identity, content: false)
                            commitCanonical(prepareAdmission(source: summary.identity, botName: bot.name,
                                title: summary.isCanonical ? "Main" : (summary.title.isEmpty ? "New chat" : summary.title),
                                messages: [], updatedAt: summary.updatedAt, reconciliation: .observedSource, incomingCoverage: .partial,
                                unavailableMessageIDs: [], removedMessageIDs: [], retiredStoredIDs: []), target: key)
                        }
                        else if unsettledTail[key] == nil {
                            let updated = previous.updatingMetadata(identity: summary.identity,
                                botName: bot.name, title: summary.isCanonical ? "Main" : (summary.title.isEmpty ? "New chat" : summary.title),
                                updatedAt: newest(summary.updatedAt, previous.messages.last?.timestamp) ?? previous.updatedAt)
                            if updated != previous { markDirty(key); records[key] = updated }
                        }
                    } else {
                        observedRetained.insert(key)
                        observe(summary.identity, content: false)
                        commitCanonical(prepareAdmission(source: summary.identity, botName: bot.name,
                            title: summary.isCanonical ? "Main" : (summary.title.isEmpty ? "New chat" : summary.title),
                            messages: [], updatedAt: summary.updatedAt, reconciliation: .observedSource, incomingCoverage: .partial,
                            unavailableMessageIDs: [], removedMessageIDs: [], retiredStoredIDs: []), target: key)
                    }
                    guard !summaries.contains(where: { self.key(for: $0.1.identity) == key }) else { continue }
                    summaries.append((bot, summary))
                    if summaries.count > limits.chatCount * 2 {
                        summaries = Array(newestSummaries(summaries).prefix(limits.chatCount)); incomplete = true
                    }
                }
                if directory.isComplete {
                    let absent = records.values.filter {
                        $0.identity.profile == profile && !observedRetained.contains($0.id)
                            && canScan($0.id) && unsettledTail[$0.id] == nil && !$0.directoryAbsent
                    }
                    for chat in absent {
                        restorationHints.remove(chat.id); unreconciledSeedIDs.remove(chat.id)
                        observe(chat.identity, content: true)
                        commitCanonical(prepareAdmission(source: chat.identity, botName: chat.botName, title: chat.title,
                            messages: [], updatedAt: Date(), reconciliation: .absent, incomingCoverage: .complete,
                            unavailableMessageIDs: [], removedMessageIDs: [], retiredStoredIDs: []), target: chat.id)
                    }
                }
                reconcileOriginalConsumers()
            } catch is CancellationError {
                if currentScan() { scanNotice = .failure("Loading stopped before all history was indexed. Refresh to load the remaining results.") }
                return
            }
            catch { guard acceptsScan() else { return }; failures += 1 }
        }
        guard acceptsScan() else { return }
        let profiles = Set(bots.compactMap { try? ExactID($0.id) })
        let removed = Set(records.keys.filter { !profiles.contains($0.profile) && canScan($0) })
        withdraw(removed)
        if summaries.count > limits.chatCount { incomplete = true }
        summaries = Array(newestSummaries(summaries).prefix(limits.chatCount))
        chatScan: for (bot, summary) in summaries {
            guard acceptsScan() else { return }
            if readMessages >= maximumReadMessages || readBytes >= maximumReadBytes { incomplete = true; break }
            let chatKey = key(for: summary.identity)
            guard canScan(chatKey) else { incomplete = true; continue }
            let hasLiveTail = workingTail(in: summary.identity) != nil
            let retainedComplete = coverage[chatKey] == .complete && records[chatKey]?.identity.stored == summary.identity.stored
            let previousSummary = self.summaries[chatKey]
            if !force, retainedComplete, unsettledTail[chatKey] == nil, completeDirectories.contains(summary.identity.profile), let previousSummary,
               summary.messageCount.map({ $0 >= 0 }) == true, summary.updatedAt != nil, summary.hasPreview == true,
               sameFingerprint(summary, previousSummary) { continue }
            var probed: ConversationHistoryPage?
            if !force, retainedComplete, summary.messageCount == nil || summary.updatedAt == nil || summary.hasPreview != true {
                do {
                    let page = try await service.conversationHistory(summary.identity, offset: 0)
                    guard acceptsScan() else { return }
                    guard canScan(chatKey) else { incomplete = true; continue chatScan }
                    observe(summary.identity, content: true)
                    quarantine(pageAmbiguity(page, source: summary.identity), source: summary.identity)
                    let fingerprint = await Self.headFingerprint(page)
                    guard acceptsScan(), canScan(chatKey) else { incomplete = true; continue chatScan }
                    if page.sourceIDs != nil, heads[chatKey] == fingerprint, page.isComplete,
                       page.unavailableMessageIDs.isEmpty, page.nextOffset != nil {
                        freshnessUnverified = true; continue
                    }
                    probed = page
                } catch {
                    guard acceptsScan() else { return }
                    if canScan(chatKey) {
                        quarantineFailure(error, source: summary.identity)
                        invalidateHistoryCertificate(chatKey)
                    }
                    failures += 1; continue
                }
            }
            var messages: [ChatMessage] = [], offsets = Set<Int>(), seen: [Data: ChatMessage] = [:], offset = 0
            var seenSourceIDs = Set<Data>()
            var unavailableMessageIDs = Set<Data>()
            var complete = !hasLiveTail, pages = 0, receivedPage = false
            var pageHead: Data?
            let title = summary.isCanonical ? "Main" : (summary.title.isEmpty ? "New chat" : summary.title)
            func publish(_ final: Bool, allowingCancellation: Bool = false) async -> Bool {
                await installAsync(source: summary.identity, botName: bot.name, title: title, messages: messages,
                    updatedAt: newest(summary.updatedAt, messages.last?.timestamp),
                    reconciliation: final && complete ? .replace : .merge,
                    incomingCoverage: final && complete ? .complete : .partial,
                    unavailableMessageIDs: unavailableMessageIDs,
                    removedMessageIDs: [],
                    retiredStoredIDs: [],
                    admittedBy: { currentScan() && canScan(chatKey) && (allowingCancellation || !Task.isCancelled) },
                    onCommit: {
                        self.heads[chatKey] = pageHead
                        self.summaries[chatKey] = final && complete && self.coverage[chatKey] == .complete ? summary : nil
                        self.markDirty(chatKey)
                    })
            }
            do {
                while true {
                    guard offsets.insert(offset).inserted else { throw HermesServiceError.incompatible }
                    let page: ConversationHistoryPage
                    if offset == 0, let first = probed { page = first; probed = nil }
                    else { page = try await service.conversationHistory(summary.identity, offset: offset) }
                    guard currentScan() else { return }; try Task.checkCancellation()
                    guard canScan(chatKey) else { incomplete = true; continue chatScan }
                    observe(summary.identity, content: true)
                    pages += 1; receivedPage = true
                    complete = complete && page.isComplete
                    unavailableMessageIDs.formUnion(page.unavailableMessageIDs)
                    let visibleIDs = Set(page.messages.map { Data($0.id.utf8) })
                    let sourceIDs = page.sourceIDs ?? visibleIDs
                    let hiddenIDs = sourceIDs.subtracting(visibleIDs)
                    unavailableMessageIDs.formUnion((records[chatKey]?.messages ?? []).lazy.map { Data($0.id.utf8) }.filter { hiddenIDs.contains($0) })
                    let overlap = seenSourceIDs.intersection(sourceIDs)
                    if !overlap.isEmpty { complete = false }
                    for id in overlap where seen[id] == nil || !visibleIDs.contains(id) { unavailableMessageIDs.insert(id) }
                    seenSourceIDs.formUnion(sourceIDs)
                    unavailableMessageIDs.formUnion(duplicateMessageIDs(page.messages))
                    let batch = page.messages.filter { message in
                        let id = Data(message.id.utf8)
                        if let earlier = seen[id] {
                            complete = false
                            if !TranscriptContentRevision.sameMessage(earlier, message) { unavailableMessageIDs.insert(id) }
                            return false
                        }
                        seen[id] = message
                        return true
                    }
                    quarantine(unavailableMessageIDs, source: summary.identity)
                    if pages == 1 {
                        let head = await Self.headFingerprint(page)
                        guard canScan(chatKey) else { incomplete = true; continue chatScan }
                        pageHead = head
                    }
                    readMessages += sourceIDs.count
                    readBytes += page.messages.reduce(0) { $0 + $1.text.utf8.count }
                    let buffered = boundedMessages(batch, existing: messages, reconciliation: .olderPage,
                        count: limits.messageCount, bytes: limits.textBytes, excluding: unavailableMessageIDs)
                    messages = buffered.messages
                    complete = complete && !buffered.trimmed
                    if let next = page.nextOffset {
                        guard next > offset, page.messages.isEmpty || !batch.isEmpty else { throw HermesServiceError.incompatible }
                        if pages == 1 {
                            guard await publish(false) else {
                                if Task.isCancelled { _ = await publish(false, allowingCancellation: true); return }
                                incomplete = true; continue chatScan
                            }
                        }
                        if readMessages >= maximumReadMessages || readBytes >= maximumReadBytes || pages >= 1_000 || buffered.trimmed {
                            complete = false; break
                        }
                        offset = next
                    } else { break }
                }
                guard currentScan() else { return }; try Task.checkCancellation()
                guard await publish(true) else {
                    if Task.isCancelled { _ = await publish(false, allowingCancellation: true); return }
                    incomplete = true; continue chatScan
                }
                incomplete = incomplete || !complete
            } catch is CancellationError {
                if currentScan() {
                    if receivedPage { _ = await publish(false, allowingCancellation: true) }
                    if canScan(chatKey) { invalidateHistoryCertificate(chatKey) }
                    scanNotice = .failure("Loading stopped before all history was indexed. Refresh to load the remaining results.")
                }
                return
            }
            catch {
                guard currentScan() else { return }
                if canScan(chatKey) { quarantineFailure(error, source: summary.identity) }
                if receivedPage { _ = await publish(false, allowingCancellation: Task.isCancelled) }
                if canScan(chatKey) { invalidateHistoryCertificate(chatKey) }
                failures += 1
            }
        }
        guard acceptsScan() else { return }
        await persist()
        if failures > 0 { scanNotice = .failure("Some chats couldn’t be loaded. Showing available results; refresh to try again.") }
        else if incomplete { scanNotice = .incomplete }
    }

    private func invalidateHistoryCertificate(_ id: LibraryChat.ID) {
        guard records[id] != nil else { return }
        summaries[id] = nil; heads[id] = nil; coverage[id] = .partial
        markDirty(id); schedulePersistence()
    }

    private func current(_ owner: UUID) -> Bool { !isRetired && online && generation == owner }
    private func accepts(_ owner: UUID) -> Bool { current(owner) && !Task.isCancelled }

    func isCurrent(_ chat: LibraryChat) -> Bool {
        !isRetired && rosterPermits(chat.identity.profile) && !restorationHints.contains(chat.id) && !unreconciledSeedIDs.contains(chat.id) && records[chat.id]?.directoryAbsent == false && records[chat.id]?.identity == chat.identity
    }
    func isCurrent(_ item: LibraryArtifact) -> Bool {
        guard isCurrent(item.chat), let chat = records[item.chat.id] else { return false }
        guard chat.discoveredArtifacts.contains(where: { $0.id == item.artifact.id && $0 == item.artifact }),
              let current = chat.messages.first(where: { Data($0.id.utf8) == Data(item.artifact.messageID.utf8) }),
              let captured = item.chat.messages.first(where: { Data($0.id.utf8) == Data(item.artifact.messageID.utf8) }) else { return false }
        return sameMessages([current], [captured])
    }

    private nonisolated static func discover(_ messages: [ChatMessage], streamingMessage: ChatMessage?) -> [DiscoveredArtifact] {
        let artifacts = ArtifactDiscovery.artifacts(in: messages)
        guard let streamingMessage else { return artifacts }
        let settled = ReplyContent(message: streamingMessage, isStreaming: true).blocks
        return artifacts.filter { artifact in
            guard Data(artifact.messageID.utf8) == Data(streamingMessage.id.utf8),
                  case .inline(let block) = artifact.payload else { return true }
            return settled.contains { $0.id == block.id && $0.isComplete && Data($0.source.utf8) == Data(block.source.utf8) }
        }
    }

    private func sameFingerprint(_ a: SessionSummary, _ b: SessionSummary) -> Bool {
        a.identity.stored == b.identity.stored && a.messageCount == b.messageCount
            && a.updatedAt == b.updatedAt && a.hasPreview == true && b.hasPreview == true
            && Data(a.preview.utf8) == Data(b.preview.utf8)
    }

    private nonisolated static func fingerprintBytes(_ messages: [ChatMessage]) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: (try? encoder.encode(messages)) ?? Data()))
    }

    private nonisolated static func fingerprint(_ messages: [ChatMessage]) async -> Data {
        await Task.detached(priority: .utility) { fingerprintBytes(messages) }.value
    }

    private nonisolated static func headFingerprint(_ page: ConversationHistoryPage) async -> Data {
        nonisolated struct Evidence: Encodable, Sendable {
            let messages: [ChatMessage]
            let sourceIDs: [Data]?
            let unavailableIDs: [Data]
            let nextOffset: Int?
            let complete: Bool
        }
        return await Task.detached(priority: .utility) {
            let evidence = Evidence(messages: page.messages,
                sourceIDs: page.sourceIDs.map { $0.sorted { $0.lexicographicallyPrecedes($1) } },
                unavailableIDs: page.unavailableMessageIDs.sorted { $0.lexicographicallyPrecedes($1) },
                nextOffset: page.nextOffset, complete: page.isComplete)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return Data(SHA256.hash(data: (try? encoder.encode(evidence)) ?? Data()))
        }.value
    }

    static func originalKey(identity: SessionIdentity, attachment: ChatAttachment, messages: [ChatMessage],
                            producingMessage: ChatMessage? = nil) async -> ArtifactOriginalKey? {
        let matches = await Task.detached(priority: .utility) {
            (producingMessage.map { [$0] } ?? messages).filter { message in
                ArtifactDiscovery.artifacts(in: [message]).contains {
                    $0.attachment.map { Data($0.path.utf8) == Data(attachment.path.utf8) } == true
                }
            }
        }.value
        guard matches.count == 1, let message = matches.first else { return nil }
        guard message.hasStableIdentity(storedID: identity.stored.text) else { return nil }
        return ArtifactOriginalKey(identity: identity, messageID: Data(message.id.utf8), path: Data(attachment.path.utf8),
            sourceRevision: await fingerprint([message]))
    }

    func original(for key: ArtifactOriginalKey, force: Bool = false,
                  validateNetwork: @escaping @MainActor () throws -> Void = {},
                  projection: LibraryChat.ID? = nil,
                  download: @escaping @MainActor () async throws -> DownloadedArtifact) async throws -> DownloadedArtifact {
        try Task.checkCancellation()
        guard Self.hasStableIdentity(key.messageID, source: key.identity) else { throw HermesServiceError.staleConversation }
        guard !isRetired else { throw HermesServiceError.staleConversation }
        if !force {
            if let value = originals[key] { return value }
            if let value = try? await cache?.original(for: key) {
                try Task.checkCancellation()
                guard !isRetired else { throw HermesServiceError.staleConversation }
                originals = [key: value.artifact]
                return value.artifact
            }
        }
        guard online else { throw HermesServiceError.disconnected }
        try validateNetwork()
        let owner = generation
        if force {
            while let previous = flights[key] {
                _ = try? await previous.task.value
                try Task.checkCancellation()
                guard accepts(owner) else { throw HermesServiceError.staleConversation }
                try validateNetwork()
            }
        }
        let waiter = UUID(), flightID: UUID
        let admission = flights[key]?.admission ?? ArtifactCaptureAdmission()
        admission.register(waiter, ready: projection.map(projectionIsCurrent) ?? true)
        let cancellation = OriginalReadCancellation(onCancel: { admission.revoke(waiter) })
        let validateWaiter: @MainActor () throws -> Void = {
            try cancellation.check()
            try validateNetwork()
        }
        let consumer = OriginalConsumer(validate: validateWaiter, projection: projection, download: download)
        let task: Task<DownloadedArtifact, Error>
        if var existing = flights[key] {
            flightID = existing.id; task = existing.task
            existing.consumers[waiter] = consumer
            flights[key] = existing
        } else {
            flightID = UUID()
            task = Task { [weak self] in
                defer {
                    admission.revokeAll()
                    if let self, flights[key]?.id == flightID { flights[key] = nil }
                }
                var loader = (id: waiter, consumer: consumer), attempted = Set<UUID>()
                while true {
                    try Task.checkCancellation()
                    attempted.insert(loader.id)
                    let result: DownloadedArtifact
                    do { result = try await loader.consumer.download() }
                    catch {
                        guard let self, accepts(owner), let flight = flights[key], flight.id == flightID,
                              !loader.consumer.isCurrent(),
                              let next = flight.consumers.first(where: { !attempted.contains($0.key) && $0.value.isCurrent() }) else {
                            throw error
                        }
                        loader = (id: next.key, consumer: next.value)
                        continue
                    }
                    guard let self, accepts(owner), let flight = flights[key], flight.id == flightID,
                          flight.consumers.values.contains(where: { $0.isCurrent() }) else { throw HermesServiceError.staleConversation }
                    do {
                        let retained = try await cache?.retainOriginal(result, for: key, admission: admission)
                        if force, retained == nil { throw ArtifactCaptureFailure.notRetained }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if force { throw ArtifactCaptureFailure.notRetained }
                        scanNotice = .failure("The file is available, but its offline capture couldn’t be saved. Try again.")
                    }
                    try await admission.waitUntilReady()
                    guard accepts(owner), let current = flights[key], current.id == flightID,
                          current.consumers.values.contains(where: { $0.isCurrent() }) else { throw HermesServiceError.staleConversation }
                    originals = [key: result]
                    thumbnailAvailabilityRevision = UUID()
                    return result
                }
            }
            flights[key] = OriginalFlight(id: flightID, task: task, admission: admission, consumers: [waiter: consumer])
        }
        if projection != nil { indexingMetrics.galleryConsumersRegistered += 1 }
        return try await withTaskCancellationHandler {
            defer { releaseOriginalWaiter(waiter, key: key, flightID: flightID) }
            let result = try await task.value
            try Task.checkCancellation()
            guard accepts(owner) else { throw HermesServiceError.staleConversation }
            try validateWaiter()
            if force {
                let id = Data(SHA256.hash(data: key.persistenceKey))
                captureRevisions[id] = UUID()
                if captureRevisions.count > max(1, limits.messageCount), let other = captureRevisions.keys.first(where: { $0 != id }) {
                    captureRevisions[other] = nil
                }
            }
            return result
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.releaseOriginalWaiter(waiter, key: key, flightID: flightID) }
        }
    }

    private func releaseOriginalWaiter(_ waiter: UUID, key: ArtifactOriginalKey, flightID: UUID) {
        guard var flight = flights[key], flight.id == flightID else { return }
        flight.admission.revoke(waiter)
        flight.consumers[waiter] = nil
        if flight.consumers.isEmpty {
            flights[key] = nil
            flight.task.cancel()
        } else { flights[key] = flight }
    }

    func reconcileOriginalConsumers() {
        defer { reconcileProjectionWaiters() }
        var retired: [ArtifactOriginalKey] = []
        for (key, flight) in flights {
            var valid = false
            for (id, consumer) in flight.consumers {
                if consumer.isCurrent() {
                    valid = true
                    flight.admission.setReady(consumer.projection.map(projectionIsCurrent) ?? true, for: id)
                }
                else { flight.admission.revoke(id) }
            }
            if !valid { retired.append(key) }
        }
        for key in retired {
            guard let flight = flights.removeValue(forKey: key) else { continue }
            flight.admission.revokeAll(); flight.task.cancel()
        }
    }

    func thumbnail(for item: LibraryArtifact, decoderVersion: Int = 1,
                   render: @escaping @MainActor (Data) async -> Data?) async -> Data? {
        guard isCurrent(item), !Task.isCancelled else { return nil }
        if let original = originalKey(for: item), originals[original] == nil,
           let digest = try? await cache?.originalDigest(for: original),
           let saved = try? await cache?.thumbnail(for: .init(originalDigest: digest, maximumPixels: 400, decoderVersion: decoderVersion)),
           isCurrent(item), !Task.isCancelled { return saved }
        guard let artifact = try? await capturedArtifact(item), isCurrent(item), !Task.isCancelled else { return nil }
        let digest = await Task.detached(priority: .utility) { Data(SHA256.hash(data: artifact.data)) }.value
        let key = ArtifactThumbnailKey(originalDigest: digest, maximumPixels: 400, decoderVersion: decoderVersion)
        if let saved = try? await cache?.thumbnail(for: key), isCurrent(item) { return saved }
        let rendered = await render(artifact.data)
        guard isCurrent(item), !Task.isCancelled, let rendered else { return nil }
        try? await cache?.retainThumbnail(rendered, for: key)
        return isCurrent(item) ? rendered : nil
    }

    func download(_ item: LibraryArtifact, force: Bool = false) async throws -> DownloadedArtifact {
        let result = try await capturedArtifact(item, force: force)
        thumbnailAvailabilityRevision = UUID()
        return result
    }

    private func originalKey(for item: LibraryArtifact) -> ArtifactOriginalKey? {
        guard Self.hasStableIdentity(Data(item.artifact.messageID.utf8), source: item.chat.identity),
              let attachment = item.artifact.attachment,
              let revision = item.chat.sourceRevisions[Data(item.artifact.messageID.utf8)] else { return nil }
        return ArtifactOriginalKey(identity: item.chat.identity, messageID: Data(item.artifact.messageID.utf8),
            path: Data(attachment.path.utf8), sourceRevision: revision)
    }

    nonisolated private static func hasStableIdentity(_ id: Data, source: SessionIdentity) -> Bool {
        ChatMessage.isStableID(id, storedID: source.stored.text)
    }

    func captureRevision(for item: LibraryArtifact) -> UUID? {
        guard let key = originalKey(for: item) else { return nil }
        return captureRevisions[Data(SHA256.hash(data: key.persistenceKey))]
    }

    private func capturedArtifact(_ item: LibraryArtifact, force: Bool = false) async throws -> DownloadedArtifact {
        try Task.checkCancellation()
        guard isCurrent(item) else { throw HermesServiceError.staleConversation }
        switch item.artifact.payload {
        case .inline(let block):
            let format = block.previewFormat
            let suffix = format == .html ? "html" : format == .svg ? "svg" : "mmd"
            let mime = format == .html ? "text/html" : format == .svg ? "image/svg+xml" : "text/plain"
            return DownloadedArtifact(data: Data(block.source.utf8), filename: "\(item.artifact.title).\(suffix)", mimeType: mime)
        case .file(let attachment):
            guard let key = originalKey(for: item), isCurrent(item) else {
                throw HermesServiceError.staleConversation
            }
            let result = try await original(for: key, force: force, validateNetwork: { [weak self] in
                guard self?.isCurrent(item) == true else { throw HermesServiceError.staleConversation }
            }, projection: item.chat.id) { [service] in
                try await service.downloadArtifact(attachment, in: item.chat.identity)
            }
            try await waitForProjection(of: item)
            guard isCurrent(item) else { throw HermesServiceError.staleConversation }
            return result
        }
    }
}
