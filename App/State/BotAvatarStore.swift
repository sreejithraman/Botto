// Asset policy adapted from Hermex BotAvatarStore.swift. MIT; see LICENSES/Hermex.txt.
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers
import BottoCore

/// One workspace's bounded thumbnails. Roster publication never awaits this store.
@MainActor @Observable final class BotAvatarStore {
    private struct Key: Equatable {
        let revision: Int?
        let appearance: BotAppearance?
        init(_ bot: BotProfile) { revision = bot.lookRevision; appearance = bot.appearance }
    }
    private struct Entry {
        let key: Key
        let checkedAt: Date
        // Nil covers Desktop face copies, absent/invalid images and failed reads.
        let image: UIImage?
    }
    private struct Flight {
        let id: UUID
        let key: Key
        var task: Task<Void, Never>?
    }
    private var entries: [String: Entry] = [:]
    private var loading = Set<String>()
    private var connectionID: UUID?
    @ObservationIgnored private var flights: [String: Flight] = [:]
    @ObservationIgnored private var wanted: [String: BotProfile] = [:]
    @ObservationIgnored private var queued: [String] = []
    @ObservationIgnored private var revalidateAfterFlight = Set<String>()
    @ObservationIgnored private var service: (any BotService)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let now: () -> Date
    #if DEBUG
    @ObservationIgnored private let diagnosticTestOwner = AvatarDecodeLedger.testOwner
    @ObservationIgnored private let beforeDecode = AvatarDecodeLedger.beforeDecode
    #endif

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func image(for bot: BotProfile) -> UIImage? {
        guard bot.hasAvatar == true, let entry = entries[bot.id], entry.key == Key(bot) else { return nil }
        return entry.image
    }

    func isLoading(_ bot: BotProfile) -> Bool {
        bot.hasAvatar == true && loading.contains(bot.id) && wanted[bot.id].map(Key.init) == Key(bot)
    }

    func cancel() {
        generation = UUID()
        let retired = flights.values
        flights = [:]; queued = []; wanted = [:]; revalidateAfterFlight = []
        service = nil; loading = []
        for flight in retired {
            #if DEBUG
            AvatarDecodeLedger.shared.retire(flight.id)
            #endif
            flight.task?.cancel()
        }
    }
    func reset() { cancel(); connectionID = nil; entries = [:] }

    func refresh(_ profiles: [BotProfile], connectionID: UUID, using service: any BotService,
                 revalidate: Set<String> = []) {
        if self.connectionID != connectionID { reset() }
        self.connectionID = connectionID; self.service = service
        wanted = Dictionary(profiles.filter { $0.hasAvatar == true }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entries = entries.filter { id, entry in wanted[id].map(Key.init) == entry.key }
        for (id, flight) in flights where wanted[id].map(Key.init) != flight.key {
            flights.removeValue(forKey: id); revalidateAfterFlight.remove(id)
            #if DEBUG
            AvatarDecodeLedger.shared.retire(flight.id)
            #endif
            flight.task?.cancel()
        }
        queued.removeAll { wanted[$0] == nil }
        let instant = now()
        for bot in profiles where wanted[bot.id] != nil {
            if flights[bot.id] != nil {
                // An explicit refresh needs a read started after that request. Coalesce
                // it behind the current read rather than repeatedly cancelling progress.
                if revalidate.contains(bot.id) { revalidateAfterFlight.insert(bot.id) }
                continue
            }
            guard !queued.contains(bot.id) else { continue }
            if !revalidate.contains(bot.id), bot.lookRevision != nil, let entry = entries[bot.id] {
                let age = instant.timeIntervalSince(entry.checkedAt)
                // Asset bytes can change without a look revision. Polling revalidates
                // at most once per minute per stable key, including failed image reads.
                if age >= 0, age < 60 { continue }
            }
            queued.append(bot.id)
        }
        startQueuedReads()
    }

    private func startQueuedReads() {
        guard let service else { return }
        while flights.count < 3, !queued.isEmpty {
            let id = queued.removeFirst()
            guard let bot = wanted[id] else { continue }
            let attempt = UUID(), owner = generation, key = Key(bot)
            flights[id] = Flight(id: attempt, key: key)
            #if DEBUG
            AvatarDecodeLedger.shared.admit(attempt, generation: owner, testOwner: diagnosticTestOwner)
            #endif
            flights[id]?.task = Task { [weak self] in
                #if DEBUG
                defer { AvatarDecodeLedger.shared.end(attempt) }
                #endif
                let decoded: Decoded?
                do {
                    let asset = try await service.avatarAsset(for: bot)
                    guard !Task.isCancelled else { return }
                    let photo = bot.appearance?.imageKind == "photo"
                    #if DEBUG
                    AvatarDecodeLedger.shared.mark(.queued, attempt)
                    let beforeDecode = self?.beforeDecode
                    #endif
                    let worker = Task.detached(priority: .utility) { () -> Decoded? in
                        #if DEBUG
                        await beforeDecode?()
                        AvatarDecodeLedger.shared.mark(.body, attempt, cancelled: Task.isCancelled)
                        #endif
                        guard !Task.isCancelled else { return nil }
                        let result = asset.flatMap { asset in
                            #if DEBUG
                            AvatarDecodeLedger.shared.mark(.sync, attempt)
                            #endif
                            return Self.decode(asset, photo: photo)
                        }
                        #if DEBUG
                        AvatarDecodeLedger.shared.mark(.finish, attempt, imageProduced: result?.image != nil)
                        #endif
                        return result
                    }
                    decoded = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                } catch {
                    // Optional/unsupported image RPCs never affect the connection or roster.
                    decoded = nil
                }
                #if DEBUG
                AvatarDecodeLedger.shared.checkAuthority(attempt, .init(taskCancelled: Task.isCancelled,
                    storeAlive: self != nil, generationCurrent: self?.generation == owner,
                    requestCurrent: self?.flights[id]?.id == attempt,
                    keyCurrent: self?.wanted[id].map(Key.init) == key))
                #endif
                guard !Task.isCancelled else { return }
                self?.complete(id, attempt: attempt, owner: owner, key: key, image: decoded?.image)
            }
        }
        loading = Set(queued).union(flights.keys)
    }

    private func complete(_ id: String, attempt: UUID, owner: UUID, key: Key, image: UIImage?) {
        guard generation == owner, flights[id]?.id == attempt, wanted[id].map(Key.init) == key else { return }
        entries[id] = Entry(key: key, checkedAt: now(), image: image)
        #if DEBUG
        AvatarDecodeLedger.shared.mark(.published, attempt)
        #endif
        flights.removeValue(forKey: id)
        if revalidateAfterFlight.remove(id) != nil { queued.append(id) }
        startQueuedReads()
    }

    private enum Decoded: Sendable {
        case image(UIImage), faceCopy
        var image: UIImage? { if case .image(let image) = self { image } else { nil } }
    }

    private nonisolated static func decode(_ asset: BotAvatarAsset, photo: Bool) -> Decoded? {
        guard asset.data.count <= 2_000_000,
              let source = CGImageSourceCreateWithData(asset.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              let expected = ["image/png": UTType.png.identifier, "image/jpeg": UTType.jpeg.identifier,
                              "image/webp": UTType.webP.identifier][asset.mimeType], type == expected,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
              width <= 32_768, height <= 32_768, Int64(width) * Int64(height) <= 100_000_000 else { return nil }
        if !photo, type == UTType.png.identifier, width == 160, height == 160 { return .faceCopy }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 192,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return .image(UIImage(cgImage: image))
    }
}

#if DEBUG
/// Debug decode tracing; a finished decode stays active until its parent checks publication.
nonisolated final class AvatarDecodeLedger: @unchecked Sendable {
    @TaskLocal static var testOwner: String?
    @TaskLocal static var beforeDecode: (@Sendable () async -> Void)?
    static let shared = AvatarDecodeLedger()
    static let activeLimit = 256, recentLimit = 64, ownerScalarLimit = 256

    enum Stage: String, Encodable, Sendable {
        case admitted = "awaitingService", queued, body, sync
        case finish = "finishedAwaitingPublication", authority, published
    }
    struct Authority: Encodable, Sendable {
        let taskCancelled, storeAlive, generationCurrent, requestCurrent, keyCurrent: Bool
    }
    private struct Record: Encodable, Sendable {
        let request: UUID, generation: UUID
        let testOwner: String
        let ownerAvailable, ownerTruncated: Bool
        let admittedAt: TimeInterval
        var stage = Stage.admitted
        var queuedAt, bodyAt, syncAt, finishedAt, authorityAt, publishedAt, retiredAt, endedAt: TimeInterval?
        var workerCancelledAtEntry, imageProduced: Bool?
        var authority: Authority?
    }
    private struct Snapshot: Encodable {
        let capturedAt: TimeInterval
        let activeLimit, recentLimit, ownerScalarLimit: Int
        let droppedRequests, droppedEvents, evictedRecent: Int
        let active, recent: [Record]
    }

    private let lock = NSLock()
    private let origin = ProcessInfo.processInfo.systemUptime
    private var active: [UUID: Record] = [:]
    private var recent: [Record] = []
    private var droppedRequests = 0, droppedEvents = 0, evictedRecent = 0

    func admit(_ id: UUID, generation: UUID, testOwner: String?) {
        let label = testOwner.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(Self.ownerScalarLimit))) } ?? "unknown"
        let record = Record(request: id, generation: generation, testOwner: label,
            ownerAvailable: testOwner != nil, ownerTruncated: (testOwner?.unicodeScalars.count ?? 0) > Self.ownerScalarLimit,
            admittedAt: ProcessInfo.processInfo.systemUptime - origin)
        lock.withLock {
            guard active.count < Self.activeLimit else { droppedRequests += 1; return }
            active[id] = record
        }
    }

    func mark(_ stage: Stage, _ id: UUID, cancelled: Bool? = nil, imageProduced: Bool? = nil) {
        update(id) { record, time in
            record.stage = stage
            switch stage {
            case .admitted: break
            case .queued: record.queuedAt = time
            case .body: record.bodyAt = time; record.workerCancelledAtEntry = cancelled
            case .sync: record.syncAt = time
            case .finish: record.finishedAt = time; record.imageProduced = imageProduced
            case .authority: record.authorityAt = time
            case .published: record.publishedAt = time
            }
        }
    }

    func retire(_ id: UUID) {
        update(id) { record, time in record.retiredAt = time }
    }

    func checkAuthority(_ id: UUID, _ authority: Authority) {
        update(id) { record, time in
            record.stage = .authority; record.authorityAt = time; record.authority = authority
        }
    }

    func end(_ id: UUID) {
        lock.withLock {
            guard var record = active.removeValue(forKey: id) else { droppedEvents += 1; return }
            record.endedAt = ProcessInfo.processInfo.systemUptime - origin
            if recent.count == Self.recentLimit { recent.removeFirst(); evictedRecent += 1 }
            recent.append(record)
        }
    }

    private func update(_ id: UUID, _ change: (inout Record, TimeInterval) -> Void) {
        let time = ProcessInfo.processInfo.systemUptime - origin
        lock.withLock {
            guard var record = active[id] else { droppedEvents += 1; return }
            change(&record, time)
            active[id] = record
        }
    }

    func failureSnapshot() -> String {
        let snapshot = lock.withLock {
            Snapshot(capturedAt: ProcessInfo.processInfo.systemUptime - origin,
                activeLimit: Self.activeLimit, recentLimit: Self.recentLimit, ownerScalarLimit: Self.ownerScalarLimit,
                droppedRequests: droppedRequests, droppedEvents: droppedEvents, evictedRecent: evictedRecent,
                active: active.values.sorted { $0.admittedAt < $1.admittedAt }, recent: recent)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot), let text = String(data: data, encoding: .utf8) else {
            return "Avatar decode metadata could not be encoded"
        }
        return text
    }
}
#endif
