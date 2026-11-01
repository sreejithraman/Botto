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
        #if DEBUG
        var recordCancellation: (@Sendable () -> Void)?
        #endif
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
    @ObservationIgnored private let decodeObservation = BotAvatarDecodeObservation.capture()
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
            flight.recordCancellation?()
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
            flight.recordCancellation?()
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
            let observation = decodeObservation
            let request = BotAvatarDecodeObservation.Request(id: attempt, generation: owner, profileID: id, revision: bot.lookRevision)
            observation?.record(.admitted(request))
            flights[id]?.recordCancellation = { observation?.record(.cancelRequested(request)) }
            let recordPublication: @MainActor @Sendable () -> Void = { [weak self] in
                observation?.record(.publicationChecked(request, .init(taskCancelled: Task.isCancelled,
                    storeAlive: self != nil, generationCurrent: self?.generation == owner,
                    requestCurrent: self?.flights[id]?.id == attempt,
                    keyCurrent: self?.wanted[id].map(Key.init) == key)))
            }
            #endif
            flights[id]?.task = Task { [weak self] in
                let decoded: Decoded?
                do {
                    #if DEBUG
                    observation?.record(.serviceStarted(request))
                    #endif
                    let asset = try await service.avatarAsset(for: bot)
                    #if DEBUG
                    observation?.record(.assetReturned(request, present: asset != nil))
                    if Task.isCancelled { recordPublication() }
                    #endif
                    guard !Task.isCancelled else { return }
                    let photo = bot.appearance?.imageKind == "photo"
                    #if DEBUG
                    observation?.record(.requested(request))
                    let worker = Task.detached(priority: BotAvatarDecodeObservation.workerPriority) {
                        observation?.record(.started(request))
                        let result = asset.flatMap { Self.decode($0, photo: photo) }
                        observation?.record(.finished(request, producedImage: result?.image != nil))
                        return result
                    }
                    observation?.record(.awaiting(request))
                    decoded = await worker.value
                    #else
                    decoded = await Task.detached(priority: .utility) { asset.flatMap { Self.decode($0, photo: photo) } }.value
                    #endif
                } catch {
                    #if DEBUG
                    observation?.record(.serviceFailed(request))
                    #endif
                    // Optional/unsupported image RPCs never affect the connection or roster.
                    decoded = nil
                }
                #if DEBUG
                recordPublication()
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
        decodeObservation?.record(.published(.init(id: attempt, generation: owner, profileID: id, revision: key.revision),
            imagePresent: image != nil))
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
/// Read-only, scoped to test store construction, and absent from Release builds.
nonisolated struct BotAvatarDecodeObservation: Sendable {
    @TaskLocal static var current: Self?
    private static let variant = environment("BOTTO_AVATAR_DECODE_PRIORITY").flatMap(Variant.init(rawValue:))
    private static let journal = variant.map { variant in
        let arm = environment("BOTTO_AVATAR_PRIORITY_ARM") ?? "unlabelled"
        return Journal(variant: variant, arm: ["A1", "B1", "B2", "A2"].contains(arm) ? arm : "unlabelled")
    }
    static var workerPriority: TaskPriority { variant == .userInitiated ? .userInitiated : .utility }

    private enum Variant: String, Sendable { case utility, userInitiated }

    private static func environment(_ name: String) -> String? {
        let values = ProcessInfo.processInfo.environment
        return values[name] ?? values["TEST_RUNNER_" + name]
    }

    static func capture() -> Self? {
        let scoped = current
        guard let journal else { return scoped }
        return .init(record: { event in scoped?.record(event); journal.record(event) })
    }

    static func processSnapshot(excluding local: Set<UUID> = []) -> String? {
        journal?.snapshot(excluding: local)
    }

    struct Request: Sendable {
        let id: UUID
        let generation: UUID
        let profileID: String
        let revision: Int?
    }

    struct PublicationAuthority: Sendable {
        let taskCancelled: Bool
        let storeAlive: Bool
        let generationCurrent: Bool
        let requestCurrent: Bool
        let keyCurrent: Bool
    }

    enum Event: Sendable {
        case admitted(Request)
        case serviceStarted(Request)
        case assetReturned(Request, present: Bool)
        case serviceFailed(Request)
        case requested(Request)
        case awaiting(Request)
        case started(Request)
        case finished(Request, producedImage: Bool)
        case cancelRequested(Request)
        case publicationChecked(Request, PublicationAuthority)
        case published(Request, imagePresent: Bool)

        var request: Request {
            switch self {
            case .admitted(let request), .serviceStarted(let request), .assetReturned(let request, _), .serviceFailed(let request),
                 .requested(let request), .awaiting(let request), .started(let request), .finished(let request, _),
                 .cancelRequested(let request), .publicationChecked(let request, _), .published(let request, _): request
            }
        }
    }

    let record: @Sendable (Event) -> Void

    private final class Journal: @unchecked Sendable {
        private struct Entry {
            let elapsed: Duration
            let event: Event
            var base: UInt8?
            var effective: UInt8?
            let mainThread: Bool
        }

        private let lock = NSLock()
        private let origin = ContinuousClock.now
        private let variant: Variant
        private let arm: String
        private var entries: [Entry] = []
        private var tracked = Set<UUID>()
        private var queued = Set<UUID>(), running = Set<UUID>(), retired = Set<UUID>()
        private var dropped = 0

        init(variant: Variant, arm: String) { self.variant = variant; self.arm = arm }

        func record(_ event: Event) {
            let entry = Entry(elapsed: origin.duration(to: .now), event: event,
                base: nil, effective: nil, mainThread: Thread.isMainThread)
            let index: Int? = lock.withLock {
                let id = event.request.id
                if !tracked.contains(id) {
                    guard tracked.count < 10_000 else { dropped += 1; return nil }
                    tracked.insert(id)
                }
                switch event {
                case .requested: queued.insert(id)
                case .started: queued.remove(id); running.insert(id)
                case .finished: running.remove(id)
                case .cancelRequested: retired.insert(id)
                default: break
                }
                guard entries.count < 10_000 else { dropped += 1; return nil }
                entries.append(entry)
                return entries.count - 1
            }
            // Entry/phase accounting precedes priority queries so a pending
            // query cannot look like a worker that never entered its body.
            if let index {
                let base = Task.basePriority?.rawValue, effective = Task.currentPriority.rawValue
                lock.withLock { entries[index].base = base; entries[index].effective = effective }
            }
        }

        func snapshot(excluding local: Set<UUID>) -> String {
            let (captured, queued, running, retired, dropped) = lock.withLock { (entries, self.queued, self.running, self.retired, self.dropped) }
            let header = "priorityArm=\(arm) variant=\(variant.rawValue) pid=\(ProcessInfo.processInfo.processIdentifier) events=\(captured.count) dropped=\(dropped) allQueued=\(queued.count) allRunning=\(running.count) priorQueued=\(queued.subtracting(local).count) priorRunning=\(running.subtracting(local).count) retiredQueued=\(queued.intersection(retired).count) retiredRunning=\(running.intersection(retired).count)"
            let lines = captured.map { entry in
                "processElapsed=\(entry.elapsed) basePriority=\(entry.base.map(String.init) ?? "none") effectivePriority=\(entry.effective.map(String.init) ?? "pending") mainThread=\(entry.mainThread) \(entry.event)"
            }
            return ([header] + lines).joined(separator: "\n")
        }
    }
}
#endif
