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
