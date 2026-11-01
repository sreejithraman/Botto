import Foundation
import Testing
@testable import Botto

@MainActor struct HapticsTests {
    @MainActor final class Output {
        var played: [HapticPlayback] = []
        var cancellations = 0
        var now: TimeInterval = 10
        var active = true
        var hardware: HapticOutput {
            .init(play: { self.played.append($0) }, cancel: { self.cancellations += 1 })
        }
    }

    private func preferences() -> UserDefaults {
        UserDefaults(suiteName: "haptics-tests-\(UUID())")!
    }

    @Test func offAndInactivePlaybackAreDiscardedWithoutReplay() {
        let output = Output()
        let haptics = BottoHaptics(defaults: preferences(), output: output.hardware,
                                  now: { output.now }, isActive: { output.active })
        haptics.mode = .off
        haptics.play(.celebration)
        haptics.mode = .playful
        output.active = false
        haptics.play(.attention)
        output.active = true
        #expect(output.played.isEmpty)
        haptics.play(.accepted)
        #expect(output.played == [.impact(.light, intensity: 0.65)])
    }

    @Test func replyFinishedStaysSmallWhileCelebrationUsesTheSelectedStyle() {
        let output = Output()
        let haptics = BottoHaptics(defaults: preferences(), output: output.hardware,
                                  now: { output.now }, isActive: { output.active })
        haptics.play(.replyFinished)
        haptics.play(.celebration)
        haptics.mode = .subtle
        haptics.play(.replyFinished)
        haptics.play(.celebration)
        #expect(output.played == [
            .impact(.soft, intensity: 0.45), .celebration,
            .impact(.soft, intensity: 0.45), .notification(.success)
        ])
    }

    @Test func streamingIsOptInThrottledAndDoesNotReplayWhenEnabled() {
        let output = Output()
        let haptics = BottoHaptics(defaults: preferences(), output: output.hardware,
                                  now: { output.now }, isActive: { output.active })
        haptics.play(.streaming)
        #expect(output.played.isEmpty)
        haptics.streamingEnabled = true
        #expect(output.played.isEmpty)
        haptics.play(.streaming)
        output.now += 0.31
        haptics.play(.streaming)
        output.now += 0.02
        haptics.play(.streaming)
        #expect(output.played == [
            .impact(.soft, intensity: 0.2), .impact(.soft, intensity: 0.2)
        ])
        haptics.mode = .off
        output.now += 1
        haptics.play(.streaming)
        #expect(output.played.count == 2)
    }

    @Test func errorInterruptsAFlourishAndDiscardsCoincidentLowerPriorityFeedback() {
        let output = Output()
        let haptics = BottoHaptics(defaults: preferences(), output: output.hardware,
                                  now: { output.now }, isActive: { output.active })
        haptics.play(.celebration)
        let cancellations = output.cancellations
        haptics.play(.error)
        haptics.play(.replyFinished)
        haptics.play(.streaming)
        #expect(output.cancellations > cancellations)
        #expect(output.played == [.celebration, .notification(.error)])
        output.now += 0.3
        haptics.play(.replyFinished)
        #expect(output.played.last == .impact(.soft, intensity: 0.45))
    }

    @Test func preferencesPersistWithoutReplayingPreviousFeedback() {
        let output = Output(), defaults = preferences()
        let first = BottoHaptics(defaults: defaults, output: output.hardware,
                                now: { output.now }, isActive: { output.active })
        #expect(first.mode == .playful && !first.streamingEnabled)
        first.mode = .subtle
        first.streamingEnabled = true
        let reopened = BottoHaptics(defaults: defaults, output: output.hardware,
                                   now: { output.now }, isActive: { output.active })
        #expect(reopened.mode == .subtle && reopened.streamingEnabled)
        #expect(output.played.isEmpty)
    }
}

@MainActor struct HapticPatternOutputTests {
    enum LifecycleEvent: CaseIterable, Sendable { case stopped, reset }
    enum StartupStage: CaseIterable, Sendable { case handlersInstalled, engineStarted, playerCreated }

    @MainActor final class Player {
        var starts = 0
        var stops = 0
        var stopFailure = false
        var hardware: HapticPatternPlayer {
            .init(start: { self.starts += 1 }, stop: {
                self.stops += 1
                if self.stopFailure { throw CancellationError() }
            })
        }
    }

    @MainActor final class Engine {
        var stopped: HapticLifecycleHandler?
        var reset: HapticLifecycleHandler?
        var starts = 0
        var onStart: (@MainActor () -> Void)?
        var onMakePlayer: (@MainActor () -> Void)?
        var onInstallHandlers: (@MainActor (@escaping HapticLifecycleHandler,
                                          @escaping HapticLifecycleHandler) -> Void)?
        var players: [Player] = []
        var hardware: HapticPatternEngine {
            .init(start: { self.starts += 1; self.onStart?() }, makePlayer: { _ in
                let player = Player()
                self.players.append(player)
                self.onMakePlayer?()
                return player.hardware
            }, setLifecycleHandlers: {
                self.stopped = $0; self.reset = $1
                self.onInstallHandlers?($0, $1)
            })
        }
    }

    @MainActor final class Hardware {
        var engines: [Engine] = []
        var queued: [HapticRetirement] = []
        var configureEngine: (@MainActor (Engine) -> Void)?
        func makeEngine() -> HapticPatternEngine {
            let engine = Engine()
            configureEngine?(engine)
            engines.append(engine)
            return engine.hardware
        }
        func queue(_ event: LifecycleEvent) throws {
            let engine = try #require(engines.last)
            let callback = try #require(event == .stopped ? engine.stopped : engine.reset)
            queued.append(callback())
        }
        func drain() {
            let callbacks = queued
            queued.removeAll()
            for callback in callbacks { callback() }
        }
    }

    @Test(arguments: LifecycleEvent.allCases)
    func oldQueuedRetirementCannotLoseTheRestartedPlayersCancellation(_ event: LifecycleEvent) throws {
        let hardware = Hardware()
        let output = HapticPatternOutput(makeEngine: hardware.makeEngine)
        try output.play(.knock)
        try hardware.queue(event)
        try output.play(.celebration)
        #expect(hardware.engines.count == 2)
        let restarted = try #require(hardware.engines.last?.players.last)
        hardware.drain()
        #expect(restarted.stops == 0)
        output.cancel()
        #expect(restarted.starts == 1)
        #expect(restarted.stops == 1)
    }

    @Test(arguments: LifecycleEvent.allCases)
    func currentRetirementRequiresANewEngineForLaterPlayback(_ event: LifecycleEvent) throws {
        let hardware = Hardware()
        let output = HapticPatternOutput(makeEngine: hardware.makeEngine)
        try output.play(.knock)
        try hardware.queue(event)
        hardware.drain()
        try output.play(.celebration)
        output.cancel()
        #expect(hardware.engines.count == 2)
        #expect(hardware.engines.last?.players.last?.stops == 1)
    }

    @Test(arguments: LifecycleEvent.allCases)
    func delayedOldNotificationCannotRetireReplacement(_ event: LifecycleEvent) throws {
        let hardware = Hardware()
        let output = HapticPatternOutput(makeEngine: hardware.makeEngine)
        try output.play(.knock)
        let engine = try #require(hardware.engines.last)
        var delayed = try #require(event == .stopped ? engine.stopped : engine.reset)
        engine.onInstallHandlers = { stopped, reset in
            delayed = event == .stopped ? stopped : reset
        }
        try output.play(.celebration)
        let replacement = try #require(hardware.engines.last?.players.last)
        hardware.queued.append(delayed())
        hardware.drain()
        #expect(replacement.stops == 0)
        output.cancel()
        #expect(replacement.stops == 1)
    }

    @Test(arguments: LifecycleEvent.allCases)
    func currentRetirementReleasesInvalidatedPlayback(_ event: LifecycleEvent) throws {
        let hardware = Hardware()
        let output = HapticPatternOutput(makeEngine: hardware.makeEngine)
        try output.play(.knock)
        hardware.engines.last?.players.last?.stopFailure = event == .reset
        try hardware.queue(event)
        weak var engine = hardware.engines.last
        weak var player = hardware.engines.last?.players.last
        hardware.engines.removeAll()
        hardware.drain()
        #expect(engine == nil)
        #expect(player == nil)
        output.cancel()
    }

    @Test(arguments: LifecycleEvent.allCases, StartupStage.allCases)
    func currentLifecycleAbortsInterruptedStartup(_ event: LifecycleEvent, _ stage: StartupStage) throws {
        let hardware = Hardware()
        hardware.configureEngine = { [weak hardware] engine in
            let notify: @MainActor () -> Void = { [weak hardware, weak engine] in
                if let callback = event == .stopped ? engine?.stopped : engine?.reset {
                    hardware?.queued.append(callback())
                }
            }
            switch stage {
            case .handlersInstalled:
                engine.onInstallHandlers = { stopped, reset in
                    hardware?.queued.append((event == .stopped ? stopped : reset)())
                }
            case .engineStarted: engine.onStart = notify
            case .playerCreated: engine.onMakePlayer = notify
            }
        }
        let output = HapticPatternOutput(makeEngine: hardware.makeEngine)
        #expect(throws: CancellationError.self) { try output.play(.knock) }
        let engine = try #require(hardware.engines.last)
        #expect(engine.starts == (stage == .handlersInstalled ? 0 : 1))
        #expect(engine.players.count == (stage == .playerCreated ? 1 : 0))
        #expect(engine.players.allSatisfy { $0.starts == 0 })
        #expect(hardware.queued.count == 1)
        hardware.drain()
        output.cancel()
    }

    @Test(arguments: LifecycleEvent.allCases)
    func offMainOldNotificationCannotRetireReplacement(_ event: LifecycleEvent) async throws {
        let hardware = Hardware()
        let output = HapticPatternOutput(makeEngine: hardware.makeEngine)
        try output.play(.knock)
        let engine = try #require(hardware.engines.last)
        let notification = try #require(event == .stopped ? engine.stopped : engine.reset)
        let retire = await Task.detached { notification() }.value
        try output.play(.celebration)
        let replacement = try #require(hardware.engines.last?.players.last)
        retire()
        #expect(replacement.stops == 0)
        output.cancel()
        #expect(replacement.stops == 1)
    }

    @Test(arguments: LifecycleEvent.allCases)
    func currentRetirementCancelsBeforeReleasingThePlayer(_ event: LifecycleEvent) throws {
        let hardware = Hardware()
        let output = HapticPatternOutput(makeEngine: hardware.makeEngine)
        try output.play(.knock)
        let player = try #require(hardware.engines.last?.players.last)
        player.stopFailure = event == .reset
        try hardware.queue(event)
        hardware.drain()
        #expect(player.stops == 1)
        output.cancel()
        #expect(player.stops == 1)
    }

    @Test(arguments: LifecycleEvent.allCases)
    func oldEngineNotificationCannotInterruptNewPlayerCreation(_ event: LifecycleEvent) throws {
        let hardware = Hardware()
        let output = HapticPatternOutput(makeEngine: hardware.makeEngine)
        try output.play(.knock)
        let engine = try #require(hardware.engines.last)
        let oldNotification = try #require(event == .stopped ? engine.stopped : engine.reset)
        try hardware.queue(event)
        hardware.drain()
        hardware.configureEngine = { [weak hardware] engine in
            engine.onMakePlayer = { [weak hardware] in
                hardware?.queued.append(oldNotification())
            }
        }
        try output.play(.celebration)
        let replacement = try #require(hardware.engines.last?.players.last)
        #expect(hardware.engines.count == 2)
        #expect(hardware.queued.count == 1)
        #expect(replacement.starts == 1)
        hardware.drain()
        output.cancel()
        #expect(replacement.stops == 1)
    }
}
