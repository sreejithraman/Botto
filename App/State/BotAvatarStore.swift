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
    @ObservationIgnored private let decodeProbe = BotAvatarDecodeProbe.current
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
            let probe = decodeProbe
            let request = BotAvatarDecodeProbe.Request(id: attempt, generation: owner, profileID: id, revision: bot.lookRevision)
            flights[id]?.recordCancellation = { probe?.record(.cancelRequested(request)) }
            #endif
            flights[id]?.task = Task { [weak self] in
                let decoded: Decoded?
                do {
                    let asset = try await service.avatarAsset(for: bot)
                    guard !Task.isCancelled else { return }
                    let photo = bot.appearance?.imageKind == "photo"
                    #if DEBUG
                    probe?.record(.requested(request))
                    #endif
                    decoded = await Task.detached(priority: .utility) {
                        #if DEBUG
                        await probe?.beforeStart?(request)
                        probe?.record(.started(request, taskCancelled: Task.isCancelled))
                        let decode: @Sendable () -> Decoded? = { asset.flatMap { Self.decode($0, photo: photo) } }
                        let result: Decoded?
                        if let decoder = probe?.decode { result = decoder(request, decode) }
                        else { result = decode() }
                        probe?.record(.finished(request, producedImage: result?.image != nil))
                        #else
                        let result = asset.flatMap { Self.decode($0, photo: photo) }
                        #endif
                        return result
                    }.value
                } catch {
                    // Optional/unsupported image RPCs never affect the connection or roster.
                    decoded = nil
                }
                #if DEBUG
                probe?.record(.publication(request, .init(taskCancelled: Task.isCancelled,
                    storeAlive: self != nil, generationCurrent: self?.generation == owner,
                    requestCurrent: self?.flights[id]?.id == attempt,
                    keyCurrent: self?.wanted[id].map(Key.init) == key)))
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
        flights.removeValue(forKey: id)
        if revalidateAfterFlight.remove(id) != nil { queued.append(id) }
        startQueuedReads()
    }

    enum Decoded: Sendable {
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
/// Scoped to a test's store construction; absent from distribution builds.
nonisolated struct BotAvatarDecodeProbe: Sendable {
    @TaskLocal static var current: Self?

    struct Request: Equatable, Sendable {
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
        var accepted: Bool { !taskCancelled && storeAlive && generationCurrent && requestCurrent && keyCurrent }
    }

    enum Event: Sendable {
        case requested(Request)
        case started(Request, taskCancelled: Bool)
        case finished(Request, producedImage: Bool)
        case cancelRequested(Request)
        case publication(Request, PublicationAuthority)

        var request: Request {
            switch self {
            case .requested(let request), .started(let request, _), .finished(let request, _),
                 .cancelRequested(let request), .publication(let request, _): request
            }
        }
    }

    var beforeStart: (@Sendable (Request) async -> Void)?
    // Tests can wrap the real synchronous decoder with controlled occupied work.
    var decode: (@Sendable (Request, @Sendable () -> BotAvatarStore.Decoded?) -> BotAvatarStore.Decoded?)?
    let record: @Sendable (Event) -> Void
}
#endif
