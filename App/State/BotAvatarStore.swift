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
        for flight in retired { flight.task?.cancel() }
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
            flights[id]?.task = Task { [weak self] in
                let decoded: Decoded?
                do {
                    let asset = try await service.avatarAsset(for: bot)
                    Self.trace("asset-returned", attempt: attempt)
                    guard !Task.isCancelled else { Self.trace("read-cancelled", attempt: attempt); return }
                    let photo = bot.appearance?.imageKind == "photo"
                    Self.trace("decode-enqueued", attempt: attempt)
                    decoded = await Task.detached(priority: .utility) {
                        Self.trace("decode-started", attempt: attempt)
                        let result = asset.flatMap { Self.decode($0, photo: photo, attempt: attempt) }
                        Self.trace("decode-finished", attempt: attempt)
                        return result
                    }.value
                    Self.trace("decode-awaited", attempt: attempt)
                } catch {
                    // Optional/unsupported image RPCs never affect the connection or roster.
                    decoded = nil
                }
                guard !Task.isCancelled else { Self.trace("publication-cancelled", attempt: attempt); return }
                self?.complete(id, attempt: attempt, owner: owner, key: key, image: decoded?.image)
            }
        }
        loading = Set(queued).union(flights.keys)
    }

    private func complete(_ id: String, attempt: UUID, owner: UUID, key: Key, image: UIImage?) {
        guard generation == owner, flights[id]?.id == attempt, wanted[id].map(Key.init) == key else {
            Self.trace("publication-rejected", attempt: attempt); return
        }
        Self.trace("publication-accepted", attempt: attempt)
        entries[id] = Entry(key: key, checkedAt: now(), image: image)
        flights.removeValue(forKey: id)
        if revalidateAfterFlight.remove(id) != nil { queued.append(id) }
        startQueuedReads()
    }

    private enum Decoded: Sendable {
        case image(UIImage), faceCopy
        var image: UIImage? { if case .image(let image) = self { image } else { nil } }
    }

    private nonisolated static func decode(_ asset: BotAvatarAsset, photo: Bool, attempt: UUID) -> Decoded? {
        guard asset.data.count <= 2_000_000 else { return nil }
        trace("source-started", attempt: attempt)
        guard let source = CGImageSourceCreateWithData(asset.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              let expected = ["image/png": UTType.png.identifier, "image/jpeg": UTType.jpeg.identifier,
                              "image/webp": UTType.webP.identifier][asset.mimeType], type == expected else { return nil }
        trace("source-created", attempt: attempt)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
              width <= 32_768, height <= 32_768, Int64(width) * Int64(height) <= 100_000_000 else { return nil }
        trace("properties-read", attempt: attempt)
        if !photo, type == UTType.png.identifier, width == 160, height == 160 { return .faceCopy }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 192,
            kCGImageSourceShouldCacheImmediately: true]
        trace("thumbnail-started", attempt: attempt)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        trace("thumbnail-created", attempt: attempt)
        let result = Decoded.image(UIImage(cgImage: image))
        trace("image-created", attempt: attempt)
        return result
    }

    private nonisolated static func trace(_ stage: String, attempt: UUID) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return }
        NSLog("[BottoAvatarDecode] attempt=%@ stage=%@ priority=%u cancelled=%d main=%d",
              attempt.uuidString, stage, Task.currentPriority.rawValue,
              Task.isCancelled ? 1 : 0, Thread.isMainThread ? 1 : 0)
        #endif
    }
}
