import Foundation
import Observation
import CryptoKit
import BottoCore

private final class OriginalReadCancellation: @unchecked Sendable {
    // A response can reach the actor before its queued cancellation cleanup.
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
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

    init(workspace: UUID, identity: SessionIdentity, botName: String, title: String,
         messages: [ChatMessage], updatedAt: Date?, discoveredArtifacts: [DiscoveredArtifact], sourceRevisions: [Data: Data],
         searchableText: [Data: [String]]? = nil, unavailableMessageIDs: Set<Data> = []) {
        id = ID(workspace: workspace, profile: identity.profile, root: identity.root)
        self.identity = identity; botID = identity.profile.text; self.botName = botName
        self.title = title; self.messages = messages; self.updatedAt = updatedAt
        self.discoveredArtifacts = discoveredArtifacts
        self.sourceRevisions = sourceRevisions
        self.searchableText = searchableText ?? Self.searchIndex(messages)
        self.unavailableMessageIDs = unavailableMessageIDs
    }

    func updatingMetadata(identity: SessionIdentity, botName: String, title: String, updatedAt: Date?) -> Self {
        Self(workspace: id.workspace, identity: identity, botName: botName, title: title,
            messages: messages, updatedAt: updatedAt, discoveredArtifacts: discoveredArtifacts,
            sourceRevisions: sourceRevisions, searchableText: searchableText,
            unavailableMessageIDs: unavailableMessageIDs)
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
    private enum Reconciliation: Equatable { case replace, merge, seed, restore, olderPage, accepted }
    private struct Candidate: Sendable {
        let id: LibraryChat.ID
        let source: SessionIdentity
        let botName: String
        let title: String
        let updatedAt: Date?
        let messages: [ChatMessage]
        let coverage: Coverage
        let unavailableMessageIDs: Set<Data>
    }
    struct IndexingMetrics {
        var acceptedSnapshots = 0
        var batches = 0
        var parsedMessages = 0
        var processingDuration: Duration = .zero
    }
    @ObservationIgnored private(set) var indexingMetrics = IndexingMetrics()
    struct Projection: Sendable {
        let artifacts: [DiscoveredArtifact]
        let revisions: [Data: Data]
        var searchableText: [Data: [String]]? = nil
    }
    private struct Admission: Sendable {
        let candidates: [Candidate]
        let limited: Bool
    }
    private var indexRevision = UUID()
    private var acceptedVersions: [LibraryChat.ID: UUID] = [:]
    private(set) var captureRevision = UUID()
    typealias ProjectionWorker = @Sendable ([ChatMessage], ChatMessage?) async -> Projection
    @ObservationIgnored private let projector: ProjectionWorker
    private let identity = UUID()
    @ObservationIgnored private let cache: ArtifactCacheSession?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var seedTask: Task<Void, Never>?
    private var pendingSeed: (book: ConversationBook, bots: [BotProfile], accepted: [LibraryChat.ID: UUID], request: UUID)?
    private var seedVersion = UUID()
    private var localWorkCount = 0
    private var restored = false
    private var persistedIDs: Set<LibraryChat.ID> = []
    private var summaries: [LibraryChat.ID: SessionSummary] = [:]
    private var heads: [LibraryChat.ID: Data] = [:]
    private var freshnessUnverified = false
    private var dirtyChats: Set<LibraryChat.ID> = []
    private var unsettledTail: [LibraryChat.ID: Data] = [:]
    private var botNames: [ExactID: String] = [:]
    private struct OriginalConsumer {
        let validate: @MainActor () throws -> Void
        let download: @MainActor () async throws -> DownloadedArtifact

        @MainActor func isCurrent() -> Bool {
            do { try validate(); return true } catch { return false }
        }
    }
    private struct OriginalFlight {
        let id: UUID
        let task: Task<DownloadedArtifact, Error>
        var consumers: [UUID: OriginalConsumer]
    }
    @ObservationIgnored private var flights: [ArtifactOriginalKey: OriginalFlight] = [:]
    @ObservationIgnored private var pendingTranscripts: [LibraryChat.ID: (SessionIdentity, Conversation, String, String, UUID)] = [:]
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptDraining = false
    @ObservationIgnored private var originals: [ArtifactOriginalKey: DownloadedArtifact] = [:]
    private let limits: Limits
    @ObservationIgnored private let service: any BotService
    private var records: [LibraryChat.ID: LibraryChat] = [:]
    private var coverage: [LibraryChat.ID: Coverage] = [:]
    private var capacityLimited = false
    private var scanNotice: String?
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
         projector: @escaping ProjectionWorker = { messages, tail in await WorkspaceLibrary.project(messages, streamingMessage: tail) }) {
        self.service = service; self.limits = limits; self.projector = projector
        self.cache = cache ?? ArtifactCache(root: nil).session(scope: .init(configurationID: UUID(),
            serverURL: Data(), installationID: nil, username: Data(), provider: nil))
    }

    func restore() async {
        if let seedTask { await seedTask.value }
        guard !isRetired, !restored else { return }
        if let restoreTask { await restoreTask.value; return }
        localWorkCount += 1
        let task = Task { [weak self] in
            guard let self else { return }
            defer { restored = true; localWorkCount -= 1; schedulePersistence() }
            guard let cache else { return }
            do {
                let loaded = try await cache.loadChats()
                guard !isRetired else { return }
                for row in loaded {
                    let id = key(for: row.identity)
                    persistedIDs.insert(id)
                    if let seeded = records[id], seeded.identity.stored != row.identity.stored { continue }
                    await installAsync(source: row.identity, botName: row.botName, title: row.title, messages: row.messages,
                        updatedAt: row.updatedAt, reconciliation: .restore,
                        incomingCoverage: row.coverage == .complete ? .complete : .partial,
                        unavailableMessageIDs: row.unavailableMessageIDs ?? [],
                        admittedBy: { !self.isRetired && (self.records[id] == nil || self.records[id]?.identity.stored == row.identity.stored) },
                        onCommit: {
                            guard let chat = self.records[id], chat.unavailableMessageIDs.isEmpty,
                                  self.sameMessages(chat.messages, row.messages),
                                  self.unsettledTail[id] == nil,
                                  (self.coverage[id] == .complete) == (row.coverage == .complete) else { return }
                            self.summaries[id] = row.summary; self.heads[id] = row.headFingerprint
                            if let admitted = self.cachedChat(id), self.sameCachedChat(admitted, row) { self.dirtyChats.remove(id) }
                        })
                }
            } catch { if !isRetired { scanNotice = "Saved artifacts couldn’t be loaded. Showing available content." } }
        }
        restoreTask = task
        await task.value
        restoreTask = nil
    }

    private func cachedChat(_ id: LibraryChat.ID) -> CachedArtifactChat? {
        guard let chat = records[id] else { return nil }
        let tail = unsettledTail[id]
        return CachedArtifactChat(identity: chat.identity, botName: chat.botName, title: chat.title,
            messages: chat.messages.filter { Data($0.id.utf8) != tail }, updatedAt: chat.updatedAt,
            coverage: coverage[id] == .complete && tail == nil ? .complete : .partial,
            summary: summaries[id], headFingerprint: heads[id],
            unavailableMessageIDs: chat.unavailableMessageIDs.isEmpty ? nil : chat.unavailableMessageIDs)
    }

    private func sameCachedChat(_ a: CachedArtifactChat, _ b: CachedArtifactChat) -> Bool {
        a.identity == b.identity && Data(a.botName.utf8) == Data(b.botName.utf8) && Data(a.title.utf8) == Data(b.title.utf8)
            && sameMessages(a.messages, b.messages) && a.updatedAt == b.updatedAt && a.coverage == b.coverage
            && a.summary == b.summary && a.headFingerprint == b.headFingerprint
            && (a.unavailableMessageIDs ?? []) == (b.unavailableMessageIDs ?? [])
    }

    private func persist() async {
        schedulePersistence()
        await persistenceTask?.value
    }

    private func schedulePersistence() {
        guard restored, let cache, !isRetired, persistenceTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { persistenceTask = nil }
            do {
                while !isRetired {
                    if let id = persistedIDs.first(where: { records[$0] == nil }) {
                        try await cache.deleteChat(profile: id.profile, root: id.root)
                        persistedIDs.remove(id)
                        continue
                    }
                    dirtyChats = dirtyChats.filter { records[$0] != nil }
                    guard let id = dirtyChats.first, let row = cachedChat(id) else { return }
                    try await cache.upsert(row)
                    persistedIDs.insert(id)
                    if let current = cachedChat(id), sameCachedChat(current, row) { dirtyChats.remove(id) }
                }
            } catch {
                if !isRetired { scanNotice = "Artifacts are available, but changes couldn’t be saved on this device." }
            }
        }
        persistenceTask = task
    }

    func observeBots(_ bots: [BotProfile]) {
        botNames = Dictionary(bots.compactMap { bot in (try? ExactID(bot.id)).map { ($0, bot.name) } }, uniquingKeysWith: { first, _ in first })
    }

    func accept(identity source: SessionIdentity, snapshot: Conversation, title: String) {
        guard !isRetired else { return }
        indexingMetrics.acceptedSnapshots += 1
        let id = key(for: source), version = UUID()
        acceptedVersions[id] = version
        let tail = snapshot.isWorking && snapshot.messages.last?.role == .assistant ? snapshot.messages.last.map { Data($0.id.utf8) } : nil
        if unsettledTail[id] != tail { unsettledTail[id] = tail; dirtyChats.insert(id) }
        pendingTranscripts[id] = (source, snapshot, botNames[source.profile] ?? source.profile.text, title, version)
        if !snapshot.isWorking, !transcriptDraining { transcriptTask?.cancel(); transcriptTask = nil }
        guard transcriptTask == nil else { return }
        let delayed = snapshot.isWorking
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
            for (id, (source, snapshot, botName, title, version)) in pending {
                guard acceptedVersions[id] == version else { continue }
                let previous = records[id]
                let installed = await installAsync(source: source, botName: botName, title: title,
                    messages: snapshot.messages, updatedAt: newest(previous?.updatedAt, snapshot.messages.last?.timestamp),
                    reconciliation: .accepted, incomingCoverage: .partial,
                    admittedBy: { !self.isRetired && !Task.isCancelled && self.acceptedVersions[id] == version })
                guard installed else { continue }
                indexingMetrics.parsedMessages += records[id]?.messages.count ?? 0
            }
            indexingMetrics.processingDuration += started.duration(to: .now)
            await persist()
        }
    }

    var warning: String? {
        guard !isRetired else { return nil }
        if !online { return "You’re offline. Showing previously loaded chats and artifacts." }
        guard !isLoading else { return nil }
        if let scanNotice { return scanNotice }
        if freshnessUnverified { return "Showing saved history. Older messages haven’t been checked for changes. Pull to refresh to check all history." }
        if capacityLimited || coverage.values.contains(where: { $0 == .partial }) {
            return "Showing available history. Older results may be missing."
        }
        return nil
    }
    var chats: [LibraryChat] {
        records.values.sorted {
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
        pendingSeed = (book, bots, acceptedVersions, seedVersion)
        guard seedTask == nil else { return }
        localWorkCount += 1
        seedTask = Task { [weak self] in
            guard let self else { return }
            defer { seedTask = nil; localWorkCount -= 1 }
            while let seed = pendingSeed, !isRetired, !Task.isCancelled {
                pendingSeed = nil
                let names = Dictionary(seed.bots.compactMap { bot in (try? ExactID(bot.id)).map { ($0, bot.name) } },
                    uniquingKeysWith: { first, _ in first })
                for record in seed.book.records where !record.isUnverified {
                    guard seedVersion == seed.request else { break }
                    guard let source = record.binding.identity, let name = names[source.profile], let transcript = record.transcript,
                          Data(transcript.profileID.utf8) == source.profile.bytes,
                          Data(transcript.storedID.utf8) == source.stored.bytes else { continue }
                    let id = key(for: source)
                    guard acceptedVersions[id] == seed.accepted[id], records[id] == nil || records[id]?.identity.stored == source.stored else { continue }
                    if transcript.isWorking, let tail = transcript.messages.last, tail.role == .assistant {
                        unsettledTail[id] = Data(tail.id.utf8); dirtyChats.insert(id)
                    }
                    await installAsync(source: records[id]?.identity ?? source, botName: name, title: record.title,
                        messages: transcript.messages, updatedAt: newest(record.updatedAt, transcript.messages.last?.timestamp),
                        reconciliation: .seed, incomingCoverage: .partial,
                        admittedBy: { !self.isRetired && !Task.isCancelled && self.seedVersion == seed.request
                            && self.acceptedVersions[id] == seed.accepted[id]
                            && (self.records[id] == nil || self.records[id]?.identity.stored == source.stored) })
                }
            }
        }
    }

    func setOnline(_ value: Bool) {
        guard !isRetired, online != value else { return }
        online = value
        if !value { cancelOperations() }
    }
    func retire() {
        guard !isRetired else { return }
        isRetired = true; online = false
        cache?.retire(); restoreTask?.cancel(); seedTask?.cancel(); pendingSeed = nil
        persistenceTask?.cancel(); transcriptTask?.cancel(); pendingTranscripts = [:]; originals = [:]
        cancelOperations()
        records = [:]; coverage = [:]; scanNotice = nil
    }
    private func cancelOperations() {
        generation = UUID()
        scanTask?.cancel(); scanTask = nil; isScanning = false
        requiresForcedPass = false; scanningForced = false
        for flight in flights.values { flight.task.cancel() }; flights = [:]
    }
    func refresh(bots: [BotProfile], force: Bool = false) async {
        await restore()
        guard !isRetired, online, !Task.isCancelled else { return }
        if let scanTask {
            if force, !scanningForced { requiresForcedPass = true }
            await scanTask.value
            return
        }
        let owner = generation
        isScanning = true
        scanningForced = force
        let request = UUID()
        scanIdentity = request
        let task = Task {
            defer {
                if generation == owner, scanIdentity == request {
                    scanTask = nil; isScanning = false
                    requiresForcedPass = false; scanningForced = false
                }
            }
            await scan(bots: bots, owner: owner, force: force)
            if accepts(owner), requiresForcedPass {
                requiresForcedPass = false; scanningForced = true
                await scan(bots: bots, owner: owner, force: true)
            }
        }
        scanTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard generation == owner, scanIdentity == request else { return }
        if task.isCancelled {
            scanNotice = "Loading stopped before all history was indexed. Refresh to load the remaining results."
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
                if reconciliation == .seed || reconciliation == .restore {
                    message = old
                } else if reconciliation != .accepted,
                          old.text.utf8.count > message.text.utf8.count && old.text.utf8.starts(with: message.text.utf8) {
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
                                  unavailableMessageIDs: Set<Data>) -> Admission {
        let key = key(for: source), previous = records[key]
        let sameTip = previous?.identity.stored == source.stored
        var unavailable = sameTip ? previous?.unavailableMessageIDs ?? [] : []
        switch reconciliation {
        case .replace: unavailable = []
        case .accepted, .merge, .olderPage:
            unavailable.subtract(messages.map { Data($0.id.utf8) })
        case .seed: break
        case .restore:
            unavailable.formUnion(unavailableMessageIDs)
            let saved = Dictionary((sameTip ? previous?.messages ?? [] : []).map { (Data($0.id.utf8), $0) }, uniquingKeysWith: { first, _ in first })
            // Independently persisted copies have no comparable revision order.
            for message in messages {
                let id = Data(message.id.utf8)
                if let other = saved[id], !TranscriptContentRevision.sameMessage(other, message) { unavailable.insert(id) }
            }
        }
        let existing = sameTip ? previous?.messages ?? [] : []
        let local = boundedMessages(messages, existing: existing, reconciliation: reconciliation,
            count: limits.messageCount, bytes: limits.textBytes, excluding: unavailable)
        let sourceCoverage: Coverage
        if !unavailable.isEmpty { sourceCoverage = .partial }
        else if (reconciliation == .seed || reconciliation == .restore || reconciliation == .accepted), sameTip, coverage[key] == .complete,
           sameMessages(local.messages, previous?.messages ?? []), !local.trimmed, unsettledTail[key] == nil {
            sourceCoverage = .complete
        } else {
            sourceCoverage = incomingCoverage == .complete && !local.trimmed && unsettledTail[key] == nil
                && ((reconciliation != .seed && reconciliation != .restore) || sameMessages(local.messages, messages)) ? .complete : .partial
        }
        let date = reconciliation == .seed ? newest(updatedAt, sameTip ? previous?.updatedAt : nil) : updatedAt ?? previous?.updatedAt
        var candidates = records.values.filter { $0.id != key }.map {
            Candidate(id: $0.id, source: $0.identity, botName: $0.botName, title: $0.title,
                updatedAt: $0.updatedAt, messages: $0.messages, coverage: coverage[$0.id] ?? .partial,
                unavailableMessageIDs: $0.unavailableMessageIDs)
        }
        candidates.append(Candidate(id: key, source: source, botName: botName, title: title,
            updatedAt: date, messages: local.messages, coverage: sourceCoverage, unavailableMessageIDs: unavailable))
        candidates.sort { a, b in
            if a.updatedAt != b.updatedAt { return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast) }
            if a.source.profile != b.source.profile { return a.source.profile.bytes.lexicographicallyPrecedes(b.source.profile.bytes) }
            return a.source.root.bytes.lexicographicallyPrecedes(b.source.root.bytes)
        }
        var remainingCount = limits.messageCount, remainingBytes = limits.textBytes
        var limited = local.trimmed || candidates.count > limits.chatCount
        let retained = candidates.prefix(limits.chatCount).compactMap { candidate -> Candidate? in
            let unavailableBytes = candidate.unavailableMessageIDs.reduce(0) { $0 + $1.count }
            guard candidate.unavailableMessageIDs.count <= remainingCount, unavailableBytes <= remainingBytes else {
                limited = true; return nil
            }
            remainingCount -= candidate.unavailableMessageIDs.count
            remainingBytes -= unavailableBytes
            let kept = boundedMessages(candidate.messages, existing: [], reconciliation: .replace,
                count: remainingCount, bytes: remainingBytes)
            remainingCount -= kept.messages.count
            remainingBytes -= kept.messages.reduce(0) { $0 + $1.text.utf8.count }
            limited = limited || kept.trimmed
            return Candidate(id: candidate.id, source: candidate.source, botName: candidate.botName, title: candidate.title,
                updatedAt: candidate.updatedAt, messages: kept.messages, coverage: kept.trimmed ? .partial : candidate.coverage,
                unavailableMessageIDs: candidate.unavailableMessageIDs)
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

    private func discoverAdmission(_ admission: Admission, target: LibraryChat.ID,
        previous: [LibraryChat.ID: LibraryChat], tails: [LibraryChat.ID: Data]) async -> [LibraryChat.ID: Projection] {
        var result: [LibraryChat.ID: Projection] = [:]
        for candidate in admission.candidates {
            if candidate.id != target, let old = previous[candidate.id], old.identity == candidate.source,
               candidate.messages.elementsEqual(old.messages, by: TranscriptContentRevision.sameMessage) {
                result[candidate.id] = Projection(artifacts: old.discoveredArtifacts, revisions: old.sourceRevisions, searchableText: old.searchableText)
            } else {
                let tail = candidate.messages.first { Data($0.id.utf8) == tails[candidate.id] }
                result[candidate.id] = await projector(candidate.messages, tail)
            }
        }
        return result
    }

    private func commit(_ admission: Admission, discoveries: [LibraryChat.ID: Projection]) {
        var next: [LibraryChat.ID: LibraryChat] = [:], nextCoverage: [LibraryChat.ID: Coverage] = [:]
        for candidate in admission.candidates {
            let chat = LibraryChat(workspace: identity, identity: candidate.source, botName: candidate.botName,
                title: candidate.title, messages: candidate.messages, updatedAt: candidate.updatedAt,
                discoveredArtifacts: discoveries[candidate.id]?.artifacts ?? [], sourceRevisions: discoveries[candidate.id]?.revisions ?? [:],
                searchableText: discoveries[candidate.id]?.searchableText, unavailableMessageIDs: candidate.unavailableMessageIDs)
            next[candidate.id] = chat
            nextCoverage[candidate.id] = candidate.coverage
            if records[candidate.id] != chat || coverage[candidate.id] != candidate.coverage { dirtyChats.insert(candidate.id) }
            if records[candidate.id]?.identity != chat.identity
                || !sameMessages(records[candidate.id]?.messages ?? [], chat.messages)
                || coverage[candidate.id] != candidate.coverage {
                summaries[candidate.id] = nil; heads[candidate.id] = nil
            }
        }
        capacityLimited = capacityLimited || admission.limited
        records = next; coverage = nextCoverage; indexRevision = UUID()
        summaries = summaries.filter { next[$0.key] != nil }; heads = heads.filter { next[$0.key] != nil }
    }

    @discardableResult private func installAsync(source: SessionIdentity, botName: String, title: String, messages: [ChatMessage],
        updatedAt: Date?, reconciliation: Reconciliation, incomingCoverage: Coverage,
        unavailableMessageIDs: Set<Data> = [],
        admittedBy: @MainActor () -> Bool, onCommit: @MainActor () -> Void = {}) async -> Bool {
        while admittedBy() {
            let revision = indexRevision, previous = records, tails = unsettledTail, target = key(for: source)
            let admission = prepareAdmission(source: source, botName: botName, title: title, messages: messages,
                updatedAt: updatedAt, reconciliation: reconciliation, incomingCoverage: incomingCoverage,
                unavailableMessageIDs: unavailableMessageIDs)
            let discoveries = await discoverAdmission(admission, target: target, previous: previous, tails: tails)
            guard admittedBy() else { return false }
            guard indexRevision == revision else { continue }
            commit(admission, discoveries: discoveries)
            if reconciliation == .accepted { acceptedVersions[target] = UUID() }
            onCommit()
            schedulePersistence()
            return true
        }
        return false
    }

    private func scan(bots: [BotProfile], owner: UUID, force: Bool) async {
        defer { schedulePersistence() }
        let acceptedAtStart = acceptedVersions
        func canScan(_ id: LibraryChat.ID) -> Bool {
            acceptedVersions[id] == acceptedAtStart[id]
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
            guard accepts(owner) else { return }
            guard let profile = try? ExactID(bot.id) else { failures += 1; continue }
            do {
                let directory = try await service.conversations(profile: profile)
                guard accepts(owner) else { return }
                incomplete = incomplete || !directory.isComplete
                if directory.isComplete { completeDirectories.insert(profile) }
                var observedRetained = Set<LibraryChat.ID>()
                for summary in directory.summaries where summary.identity.profile == profile {
                    let key = key(for: summary.identity)
                    guard canScan(key) else { observedRetained.insert(key); incomplete = true; continue }
                    if unsettledTail[key] != nil { observedRetained.insert(key) }
                    else if let previous = records[key] {
                        observedRetained.insert(key)
                        if previous.identity.stored != summary.identity.stored { records[key] = nil; coverage[key] = nil; self.summaries[key] = nil; heads[key] = nil; indexRevision = UUID() }
                        else {
                            let updated = previous.updatingMetadata(identity: summary.identity,
                                botName: bot.name, title: summary.isCanonical ? "Main" : (summary.title.isEmpty ? "New chat" : summary.title),
                                updatedAt: newest(summary.updatedAt, previous.messages.last?.timestamp))
                            if updated != previous { dirtyChats.insert(key); records[key] = updated; indexRevision = UUID() }
                        }
                    }
                    guard !summaries.contains(where: { self.key(for: $0.1.identity) == key }) else { continue }
                    summaries.append((bot, summary))
                    if summaries.count > limits.chatCount * 2 {
                        summaries = Array(newestSummaries(summaries).prefix(limits.chatCount)); incomplete = true
                    }
                }
                if directory.isComplete {
                    records = records.filter { $0.key.profile != profile || observedRetained.contains($0.key) || !canScan($0.key) || unsettledTail[$0.key] != nil }; indexRevision = UUID()
                    coverage = coverage.filter { records[$0.key] != nil }
                }
            } catch is CancellationError {
                if current(owner) { scanNotice = "Loading stopped before all history was indexed. Refresh to load the remaining results." }
                return
            }
            catch { guard accepts(owner) else { return }; failures += 1 }
        }
        guard accepts(owner) else { return }
        let profiles = Set(bots.compactMap { try? ExactID($0.id) })
        records = records.filter { profiles.contains($0.key.profile) || !canScan($0.key) || unsettledTail[$0.key] != nil }; indexRevision = UUID()
        coverage = coverage.filter { records[$0.key] != nil }
        if summaries.count > limits.chatCount { incomplete = true }
        summaries = Array(newestSummaries(summaries).prefix(limits.chatCount))
        chatScan: for (bot, summary) in summaries {
            guard accepts(owner) else { return }
            if readMessages >= maximumReadMessages || readBytes >= maximumReadBytes { incomplete = true; break }
            let chatKey = key(for: summary.identity)
            guard canScan(chatKey) else { incomplete = true; continue }
            let hasLiveTail = unsettledTail[chatKey] != nil
            if hasLiveTail, records[chatKey]?.identity.stored != summary.identity.stored { incomplete = true; continue }
            let retainedComplete = coverage[chatKey] == .complete && records[chatKey]?.identity.stored == summary.identity.stored
            let previousSummary = self.summaries[chatKey]
            if !force, retainedComplete, unsettledTail[chatKey] == nil, completeDirectories.contains(summary.identity.profile), let previousSummary,
               summary.messageCount.map({ $0 >= 0 }) == true, summary.updatedAt != nil,
               sameFingerprint(summary, previousSummary) { continue }
            var probed: ConversationHistoryPage?
            if !force, retainedComplete, summary.messageCount == nil || summary.updatedAt == nil {
                do {
                    let page = try await service.conversationHistory(summary.identity, offset: 0)
                    guard accepts(owner) else { return }
                    let fingerprint = await Self.fingerprint(page.messages)
                    guard accepts(owner), canScan(chatKey) else { incomplete = true; continue chatScan }
                    if heads[chatKey] == fingerprint, page.isComplete {
                        freshnessUnverified = true; continue
                    }
                    probed = page
                } catch { guard accepts(owner) else { return }; failures += 1; continue }
            }
            var messages: [ChatMessage] = [], offsets = Set<Int>(), seen = Set<Data>(), offset = 0
            var complete = !hasLiveTail, pages = 0, receivedPage = false
            var pageHead: Data?
            let title = summary.isCanonical ? "Main" : (summary.title.isEmpty ? "New chat" : summary.title)
            func publish(_ final: Bool, allowingCancellation: Bool = false) async -> Bool {
                await installAsync(source: summary.identity, botName: bot.name, title: title, messages: messages,
                    updatedAt: newest(summary.updatedAt, messages.last?.timestamp),
                    reconciliation: hasLiveTail ? .seed : (final && complete ? .replace : .merge),
                    incomingCoverage: final && complete ? .complete : .partial,
                    admittedBy: { self.current(owner) && canScan(chatKey) && (allowingCancellation || !Task.isCancelled) },
                    onCommit: {
                        self.heads[chatKey] = pageHead
                        self.summaries[chatKey] = final && complete && self.coverage[chatKey] == .complete ? summary : nil
                        self.dirtyChats.insert(chatKey)
                    })
            }
            do {
                while true {
                    guard offsets.insert(offset).inserted else { throw HermesServiceError.incompatible }
                    let page: ConversationHistoryPage
                    if offset == 0, let first = probed { page = first; probed = nil }
                    else { page = try await service.conversationHistory(summary.identity, offset: offset) }
                    guard current(owner) else { return }; try Task.checkCancellation()
                    pages += 1; receivedPage = true
                    if pages == 1 {
                        let head = await Self.fingerprint(page.messages)
                        guard canScan(chatKey) else { incomplete = true; continue chatScan }
                        pageHead = head
                    }
                    complete = complete && page.isComplete
                    let batch = page.messages.filter { seen.insert(Data($0.id.utf8)).inserted }
                    readMessages += page.messages.count
                    readBytes += page.messages.reduce(0) { $0 + $1.text.utf8.count }
                    let buffered = boundedMessages(batch, existing: messages, reconciliation: .olderPage,
                        count: limits.messageCount, bytes: limits.textBytes)
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
                guard current(owner) else { return }; try Task.checkCancellation()
                guard await publish(true) else {
                    if Task.isCancelled { _ = await publish(false, allowingCancellation: true); return }
                    incomplete = true; continue chatScan
                }
                incomplete = incomplete || !complete
            } catch is CancellationError {
                if current(owner) {
                    if receivedPage { _ = await publish(false, allowingCancellation: true) }
                    scanNotice = "Loading stopped before all history was indexed. Refresh to load the remaining results."
                }
                return
            }
            catch {
                guard current(owner) else { return }
                if receivedPage { _ = await publish(false, allowingCancellation: Task.isCancelled) }
                failures += 1
            }
        }
        guard accepts(owner) else { return }
        await persist()
        if failures > 0 { scanNotice = "Some chats couldn’t be loaded. Showing available results; refresh to try again." }
        else if incomplete { scanNotice = "Showing available history. Older results may be missing." }
    }

    private func current(_ owner: UUID) -> Bool { !isRetired && online && generation == owner }
    private func accepts(_ owner: UUID) -> Bool { current(owner) && !Task.isCancelled }

    func isCurrent(_ chat: LibraryChat) -> Bool {
        !isRetired && records[chat.id]?.identity == chat.identity
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
            && a.updatedAt == b.updatedAt && Data(a.preview.utf8) == Data(b.preview.utf8)
    }

    private nonisolated static func fingerprintBytes(_ messages: [ChatMessage]) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: (try? encoder.encode(messages)) ?? Data()))
    }

    private nonisolated static func fingerprint(_ messages: [ChatMessage]) async -> Data {
        await Task.detached(priority: .utility) { fingerprintBytes(messages) }.value
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
        return ArtifactOriginalKey(identity: identity, messageID: Data(message.id.utf8), path: Data(attachment.path.utf8),
            sourceRevision: await fingerprint([message]))
    }

    func original(for key: ArtifactOriginalKey, force: Bool = false,
                  validateNetwork: @escaping @MainActor () throws -> Void = {},
                  download: @escaping @MainActor () async throws -> DownloadedArtifact) async throws -> DownloadedArtifact {
        try Task.checkCancellation()
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
        let waiter = UUID(), flightID: UUID
        let cancellation = OriginalReadCancellation()
        let validateWaiter: @MainActor () throws -> Void = {
            try cancellation.check()
            try validateNetwork()
        }
        let consumer = OriginalConsumer(validate: validateWaiter, download: download)
        let task: Task<DownloadedArtifact, Error>
        if var existing = flights[key] {
            flightID = existing.id; task = existing.task
            existing.consumers[waiter] = consumer
            flights[key] = existing
        } else {
            flightID = UUID()
            task = Task { [weak self] in
                defer {
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
                    originals = [key: result]
                    _ = try? await cache?.retainOriginal(result, for: key)
                    guard accepts(owner) else { throw HermesServiceError.staleConversation }
                    return result
                }
            }
            flights[key] = OriginalFlight(id: flightID, task: task, consumers: [waiter: consumer])
        }
        return try await withTaskCancellationHandler {
            defer { releaseOriginalWaiter(waiter, key: key, flightID: flightID) }
            let result = try await task.value
            try Task.checkCancellation()
            guard accepts(owner) else { throw HermesServiceError.staleConversation }
            try validateWaiter()
            if force { captureRevision = UUID() }
            return result
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.releaseOriginalWaiter(waiter, key: key, flightID: flightID) }
        }
    }

    private func releaseOriginalWaiter(_ waiter: UUID, key: ArtifactOriginalKey, flightID: UUID) {
        guard var flight = flights[key], flight.id == flightID else { return }
        flight.consumers[waiter] = nil
        if flight.consumers.isEmpty {
            flights[key] = nil
            flight.task.cancel()
        } else { flights[key] = flight }
    }

    func thumbnail(for item: LibraryArtifact, render: @escaping @Sendable (Data) -> Data?) async -> Data? {
        guard let artifact = try? await download(item), isCurrent(item) else { return nil }
        let digest = await Task.detached(priority: .utility) { Data(SHA256.hash(data: artifact.data)) }.value
        let key = ArtifactThumbnailKey(originalDigest: digest, maximumPixels: 400, decoderVersion: 1)
        if let saved = try? await cache?.thumbnail(for: key), isCurrent(item) { return saved }
        let rendered = await Task.detached(priority: .utility) { render(artifact.data) }.value
        guard isCurrent(item), !Task.isCancelled, let rendered else { return nil }
        try? await cache?.retainThumbnail(rendered, for: key)
        return isCurrent(item) ? rendered : nil
    }

    func download(_ item: LibraryArtifact, force: Bool = false) async throws -> DownloadedArtifact {
        try Task.checkCancellation()
        guard isCurrent(item) else { throw HermesServiceError.staleConversation }
        switch item.artifact.payload {
        case .inline(let block):
            let format = block.previewFormat
            let suffix = format == .html ? "html" : format == .svg ? "svg" : "mmd"
            let mime = format == .html ? "text/html" : format == .svg ? "image/svg+xml" : "text/plain"
            return DownloadedArtifact(data: Data(block.source.utf8), filename: "\(item.artifact.title).\(suffix)", mimeType: mime)
        case .file(let attachment):
            guard let revision = item.chat.sourceRevisions[Data(item.artifact.messageID.utf8)], isCurrent(item) else {
                throw HermesServiceError.staleConversation
            }
            let key = ArtifactOriginalKey(identity: item.chat.identity, messageID: Data(item.artifact.messageID.utf8),
                path: Data(attachment.path.utf8), sourceRevision: revision)
            let result = try await original(for: key, force: force, validateNetwork: { [weak self] in
                guard self?.isCurrent(item) == true else { throw HermesServiceError.staleConversation }
            }) { [service] in
                try await service.downloadArtifact(attachment, in: item.chat.identity)
            }
            guard isCurrent(item) else { throw HermesServiceError.staleConversation }
            return result
        }
    }
}
