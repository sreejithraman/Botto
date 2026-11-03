import Foundation
import Observation
import BottoCore

@MainActor @Observable final class BotAvatarRenderModel {
    private(set) var asset: BotAvatarNativeAsset?
    private(set) var date = Date.now
    private(set) var frame: BotAvatarRenderFrame?
    private(set) var representedGeometry: String?
    private var fallbackForGeometry: String?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var currentPresentation: BotAvatarPresentation?
    @ObservationIgnored private let prepareAsset: @MainActor (BotAvatarGeometry) async throws -> BotAvatarNativeAsset
    @ObservationIgnored private let renderFrame: @MainActor (BotAvatarGeometry, BotAvatarFrameOptions) async throws -> BotAvatarRenderFrame
    @ObservationIgnored private let releaseInstance: @MainActor (String) async -> Void

    init() {
        prepareAsset = { try await BotAvatarRenderCache.shared.prepare($0) }
        renderFrame = { try await BotAvatarEngine.shared.frame($0, options: $1) }
        releaseInstance = { await BotAvatarEngine.shared.release(instanceID: $0) }
    }

    init(prepareAsset: @escaping @MainActor (BotAvatarGeometry) async throws -> BotAvatarNativeAsset = { try await BotAvatarRenderCache.shared.prepare($0) },
         renderFrame: @escaping @MainActor (BotAvatarGeometry, BotAvatarFrameOptions) async throws -> BotAvatarRenderFrame,
         releaseInstance: @escaping @MainActor (String) async -> Void = { await BotAvatarEngine.shared.release(instanceID: $0) }) {
        self.prepareAsset = prepareAsset
        self.renderFrame = renderFrame
        self.releaseInstance = releaseInstance
    }

    func drawing(for geometry: BotAvatarGeometry) -> (asset: BotAvatarNativeAsset, frame: BotAvatarRenderFrame)? {
        if representedGeometry == geometry.json || fallbackForGeometry == geometry.json, let asset, let frame { return (asset, frame) }
        guard let ready = BotAvatarRenderCache.shared.asset(for: geometry) else { return nil }
        return (ready, ready.source.restingFrame)
    }

    func updatePresentation(_ presentation: BotAvatarPresentation) {
        currentPresentation = presentation
    }

    func run(profile: BotProfile, initialPresentation: BotAvatarPresentation, still: Bool) async {
        guard !Task.isCancelled else { return }
        if still || currentPresentation == nil { currentPresentation = initialPresentation }
        let owner = UUID()
        revision = owner
        let requested = profile.appearance?.geometry ?? BotAvatarCatalog.geometry(for: profile.face.shape)
        let fallback = BotAvatarCatalog.geometry(for: profile.face.shape)
        let idle = BotAvatarActivityStyle.options(profile: profile,
            presentation: currentPresentation ?? initialPresentation, at: .now, still: true).motion == .idle
        if still, idle, let ready = BotAvatarRenderCache.shared.asset(for: requested) {
            asset = ready
            frame = ready.source.restingFrame
            representedGeometry = requested.json
            fallbackForGeometry = nil
            return
        }
        let definition: BotAvatarGeometry
        let prepared: BotAvatarNativeAsset
        do { (definition, prepared) = try await prepare(requested, fallback: fallback, owner: owner) }
        catch { return }
        guard !Task.isCancelled, revision == owner else { return }
        display(prepared, geometry: definition, requested: requested)
        for attempt in 0...2 {
            guard !Task.isCancelled, revision == owner else { return }
            let instanceID = UUID().uuidString
            do {
                try await animate(definition, profile: profile, initialPresentation: initialPresentation,
                                  still: still, owner: owner, instanceID: instanceID)
                await releaseInstance(instanceID)
                return
            } catch {
                await releaseInstance(instanceID)
                guard !still, !Task.isCancelled, revision == owner, !(error is CancellationError), attempt < 2 else { return }
                // Keep the last complete frame while a transient worker failure recovers.
                do { try await Task.sleep(for: .milliseconds(250 * (attempt + 1))) }
                catch { return }
            }
        }
    }

    private func prepare(_ requested: BotAvatarGeometry, fallback: BotAvatarGeometry,
                         owner: UUID) async throws -> (BotAvatarGeometry, BotAvatarNativeAsset) {
        var definition = requested
        var failures = 0
        while true {
            guard !Task.isCancelled, revision == owner else { throw CancellationError() }
            do { return (definition, try await prepareAsset(definition)) }
            catch {
                guard !Task.isCancelled, revision == owner, !(error is CancellationError) else { throw CancellationError() }
                showFallback(for: requested, fallback: fallback)
                if case .invalidDefinition = error as? BotAvatarEngineError {
                    guard definition != fallback else { throw error }
                    definition = fallback
                    continue
                }
                guard failures < 2 else { throw error }
                failures += 1
                try await Task.sleep(for: .milliseconds(250 * failures))
            }
        }
    }

    private func showFallback(for requested: BotAvatarGeometry, fallback: BotAvatarGeometry) {
        if representedGeometry == requested.json, asset != nil, frame != nil { return }
        guard let safe = BotAvatarRenderCache.shared.asset(for: fallback) else { return }
        display(safe, geometry: fallback, requested: requested)
    }

    private func display(_ prepared: BotAvatarNativeAsset, geometry: BotAvatarGeometry, requested: BotAvatarGeometry) {
        if representedGeometry != geometry.json || asset?.source.key != prepared.source.key {
            frame = prepared.source.restingFrame
        }
        asset = prepared
        representedGeometry = geometry.json
        fallbackForGeometry = geometry == requested ? nil : requested.json
    }

    private func animate(_ definition: BotAvatarGeometry, profile: BotProfile,
                         initialPresentation: BotAvatarPresentation, still: Bool,
                         owner: UUID, instanceID: String) async throws {
        repeat {
            guard !Task.isCancelled, revision == owner else { return }
            let options = BotAvatarActivityStyle.options(profile: profile,
                presentation: currentPresentation ?? initialPresentation, at: .now,
                still: still, instanceID: still ? nil : instanceID)
            let next = try await renderFrame(definition, options)
            guard !Task.isCancelled, revision == owner else { return }
            frame = next
            if still { return }
            try await Task.sleep(for: .milliseconds(33))
        } while !Task.isCancelled
    }

    // Native cues and verified reactions keep their clock while geometry prepares.
    func runClock(presentation: BotAvatarPresentation, still: Bool) async {
        let duration: Double
        switch presentation.activity {
        case .finished: duration = 1.85
        case .failed: duration = 1.1
        case .thinking, .tools, .unavailable: duration = .infinity
        default: duration = 0
        }
        repeat {
            guard !Task.isCancelled else { return }
            date = .now
            guard !still, date.timeIntervalSince(presentation.enteredAt) < duration else { return }
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
        } while !Task.isCancelled
    }

    func retire() {
        revision = UUID()
    }
}

enum BotAvatarActivityStyle {
    static func options(profile: BotProfile, presentation: BotAvatarPresentation, at date: Date,
                        still: Bool, instanceID: String? = nil) -> BotAvatarFrameOptions {
        let elapsed = max(0, date.timeIntervalSince(presentation.enteredAt))
        let motion: BotAvatarFrameOptions.Motion
        switch presentation.activity {
        case .thinking, .working, .tools, .replying, .waiting: motion = .thinking
        case .finished where elapsed < 1.85: motion = .happy
        default: motion = BotAvatarExpression.resolve(profile.appearance?.expression).motion
        }
        let time = still ? 0 : date.timeIntervalSinceReferenceDate + phase(for: profile.id)
        return .init(time: time, motion: motion, reducedMotion: still,
                     instanceID: instanceID, now: date.timeIntervalSinceReferenceDate * 1000)
    }

    static func eyes(profile: BotProfile, activity: BotMotionActivity) -> BotAvatarEyeTreatment {
        if activity.isSleeping || profile.appearance?.expression == "sleepy" { return .sleeping }
        return activity == .failed ? .surprised : .normal
    }

    static func phase(for profileID: String) -> Double {
        let hash = profileID.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return Double(hash % 60_000) / 1000
    }
}
