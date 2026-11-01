import Foundation
import Synchronization
import Observation
import UIKit
@preconcurrency import CoreHaptics
import OSLog

enum HapticMode: String, CaseIterable, Identifiable, Sendable {
    case off, subtle, playful
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum HapticEvent: String, CaseIterable, Identifiable, Sendable {
    case selection, avatarSelection, accepted, surface, attention
    case replyFinished, celebration, stopped, warning, error, streaming
    var id: Self { self }
    var title: String {
        switch self {
        case .selection: "Selection"
        case .avatarSelection: "Avatar shape"
        case .accepted: "Action accepted"
        case .surface: "Sheet opening"
        case .attention: "Needs you"
        case .replyFinished: "Reply finished"
        case .celebration: "Celebration"
        case .stopped: "Work stopped"
        case .warning: "Needs care"
        case .error: "Action failed"
        case .streaming: "Streaming tick"
        }
    }
    var detail: String {
        switch self {
        case .selection: "A tiny step when a choice changes."
        case .avatarSelection: "A soft plip while choosing a face."
        case .accepted: "A light acknowledgment after an action is accepted."
        case .surface: "A quiet cushion as a surface comes forward."
        case .attention: "A gentle knock when a bot needs an answer."
        case .replyFinished: "A small upbeat cue when the bot finishes its turn."
        case .celebration: "A short ta-da for a new bot or completed setup."
        case .stopped: "A damped pulse when work actually stops."
        case .warning: "A familiar warning for a result that needs care."
        case .error: "A familiar error alongside recovery guidance."
        case .streaming: "An optional sparse tick as answer text arrives."
        }
    }
}

enum HapticImpact: Equatable, Sendable { case light, soft, medium }
enum HapticNotification: Equatable, Sendable { case success, warning, error }

/// Commands at the device-output boundary, independent of app state and views.
enum HapticPlayback: Equatable, Sendable {
    case selection
    case impact(HapticImpact, intensity: Double)
    case notification(HapticNotification)
    case knock, celebration
}

struct HapticOutput {
    let play: @MainActor (HapticPlayback) -> Void
    let cancel: @MainActor () -> Void
}

@MainActor @Observable final class BottoHaptics: NSObject {
    static let shared = BottoHaptics(observeLifecycle: true)
    private static let modeKey = "botto.haptics.mode"
    private static let streamingKey = "botto.haptics.streaming"

    var mode: HapticMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            cancel()
        }
    }
    var streamingEnabled: Bool {
        didSet {
            guard streamingEnabled != oldValue else { return }
            defaults.set(streamingEnabled, forKey: Self.streamingKey)
            cancel()
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let output: HapticOutput
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let isActive: () -> Bool
    @ObservationIgnored private var lastStreaming: TimeInterval?
    @ObservationIgnored private var protectedUntil: TimeInterval = 0
    @ObservationIgnored private var decorativeUntil: TimeInterval = 0

    init(defaults: UserDefaults = .standard, output: HapticOutput? = nil,
         now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         observeLifecycle: Bool = false) {
        self.defaults = defaults
        self.mode = HapticMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .playful
        self.streamingEnabled = defaults.bool(forKey: Self.streamingKey)
        self.now = now; self.isActive = isActive
        if let output {
            self.output = output
        } else {
            let device = SystemHapticOutput()
            self.output = .init(play: { device.play($0) }, cancel: { device.cancel() })
        }
        super.init()
        if observeLifecycle {
            NotificationCenter.default.addObserver(self, selector: #selector(becameInactive),
                name: UIApplication.willResignActiveNotification, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func play(_ event: HapticEvent) {
        guard mode != .off, isActive() else { cancel(); return }
        let time = now()
        let important = event == .warning || event == .error
        guard important || time >= protectedUntil else { return }
        if event == .streaming {
            guard streamingEnabled, time >= decorativeUntil,
                  lastStreaming.map({ time - $0 >= 0.32 }) ?? true else { return }
            lastStreaming = time
        } else {
            if (event == .attention || event == .replyFinished), time < decorativeUntil { return }
            output.cancel()
            decorativeUntil = 0
        }
        if important { protectedUntil = time + 0.25 }
        let playback = playback(for: event)
        if playback == .knock || playback == .celebration { decorativeUntil = time + 0.18 }
        output.play(playback)
    }

    func cancel() {
        output.cancel()
        lastStreaming = nil; protectedUntil = 0; decorativeUntil = 0
    }

    @objc private func becameInactive() { cancel() }

    private func playback(for event: HapticEvent) -> HapticPlayback {
        switch event {
        case .selection: .selection
        case .avatarSelection:
            mode == .playful ? .impact(.soft, intensity: 0.45) : .selection
        case .accepted: .impact(.light, intensity: 0.65)
        case .surface: .impact(.soft, intensity: mode == .playful ? 0.55 : 0.35)
        case .attention:
            mode == .playful ? .knock : .impact(.soft, intensity: 0.5)
        case .replyFinished: .impact(.soft, intensity: 0.45)
        case .celebration:
            mode == .playful ? .celebration : .notification(.success)
        case .stopped: .impact(.medium, intensity: 0.65)
        case .warning: .notification(.warning)
        case .error: .notification(.error)
        case .streaming: .impact(.soft, intensity: 0.2)
        }
    }
}

@MainActor private final class SystemHapticOutput {
    private let selection = UISelectionFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()
    private let patterns = HapticPatternOutput(makeEngine: HapticPatternEngine.coreHaptics)
    private let supportsPatterns = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private let logger = Logger(subsystem: "com.sree.botto", category: "Haptics")

    func play(_ playback: HapticPlayback) {
        switch playback {
        case .selection: selection.selectionChanged()
        case let .impact(style, intensity):
            let generator: UIImpactFeedbackGenerator = switch style {
            case .light: light
            case .soft: soft
            case .medium: medium
            }
            generator.impactOccurred(intensity: CGFloat(intensity))
        case .notification(let value):
            let type: UINotificationFeedbackGenerator.FeedbackType = switch value {
            case .success: .success
            case .warning: .warning
            case .error: .error
            }
            notification.notificationOccurred(type)
        case .knock, .celebration:
            guard supportsPatterns else { fallback(for: playback); return }
            do {
                try patterns.play(playback == .knock ? .knock : .celebration)
            } catch {
                logger.error("Custom haptic playback failed: \(String(describing: error), privacy: .public)")
                fallback(for: playback)
            }
        }
    }

    func cancel() { patterns.cancel() }

    private func fallback(for playback: HapticPlayback) {
        if playback == .celebration { notification.notificationOccurred(.success) }
        else { soft.impactOccurred(intensity: 0.5) }
    }
}

enum HapticPattern: Sendable { case knock, celebration }

typealias HapticRetirement = @MainActor @Sendable () -> Void
typealias HapticLifecycleHandler = @Sendable () -> HapticRetirement

@MainActor struct HapticPatternPlayer {
    let start: @MainActor () throws -> Void
    let stop: @MainActor () throws -> Void
}

@MainActor struct HapticPatternEngine {
    let start: @MainActor () throws -> Void
    let makePlayer: @MainActor (HapticPattern) throws -> HapticPatternPlayer
    let setLifecycleHandlers: @MainActor (@escaping HapticLifecycleHandler,
                                        @escaping HapticLifecycleHandler) -> Void

    static func coreHaptics() throws -> Self {
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        return Self(start: { try engine.start() }, makePlayer: { pattern in
            let accents: [(TimeInterval, Float)] = pattern == .knock
                ? [(0, 0.32), (0.16, 0.32)]
                : [(0, 0.22), (0.065, 0.35), (0.15, 0.5)]
            let events = accents.map { time, intensity in
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    .init(parameterID: .hapticIntensity, value: intensity),
                    .init(parameterID: .hapticSharpness, value: 0.3)
                ], relativeTime: time)
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            return HapticPatternPlayer(start: { try player.start(atTime: CHHapticTimeImmediate) },
                                       stop: { try player.stop(atTime: CHHapticTimeImmediate) })
        }, setLifecycleHandlers: { stopped, reset in
            // Mark interruptions on the SDK callback queue before deferring retirement.
            engine.stoppedHandler = { _ in
                let retire = stopped()
                Task { @MainActor in retire() }
            }
            engine.resetHandler = {
                let retire = reset()
                Task { @MainActor in retire() }
            }
        })
    }
}

@MainActor final class HapticPatternOutput {
    private nonisolated final class PlaybackLifetime: Sendable {
        private let interrupted = Mutex(false)

        func interrupt() { interrupted.withLock { $0 = true } }

        func checkForInterruption() throws {
            if interrupted.withLock({ $0 }) { throw CancellationError() }
        }
    }

    private let makeEngine: @MainActor () throws -> HapticPatternEngine
    private var activePlayback: (lifetime: PlaybackLifetime, engine: HapticPatternEngine,
                                 player: HapticPatternPlayer?)?

    init(makeEngine: @escaping @MainActor () throws -> HapticPatternEngine) {
        self.makeEngine = makeEngine
    }

    func play(_ pattern: HapticPattern) throws {
        cancel()
        do {
            // Use a fresh engine so delayed notifications stay with their original playback.
            let engine = try makeEngine()
            let lifetime = PlaybackLifetime()
            activePlayback = (lifetime, engine, nil)
            let handler: HapticLifecycleHandler = { [weak self, lifetime] in
                lifetime.interrupt()
                return { @MainActor [weak self, lifetime] in self?.retire(lifetime) }
            }
            engine.setLifecycleHandlers(handler, handler)
            try lifetime.checkForInterruption()
            try engine.start()
            try lifetime.checkForInterruption()
            let player = try engine.makePlayer(pattern)
            activePlayback?.player = player
            try lifetime.checkForInterruption()
            try player.start()
        } catch {
            cancel()
            throw error
        }
    }

    func cancel() {
        guard let playback = activePlayback else { return }
        activePlayback = nil
        playback.lifetime.interrupt()
        withExtendedLifetime(playback.engine) {
            try? playback.player?.stop()
        }
    }

    private func retire(_ lifetime: PlaybackLifetime) {
        guard activePlayback?.lifetime === lifetime else { return }
        cancel()
    }
}
