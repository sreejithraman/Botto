import Foundation
import SwiftUI
import Testing
@testable import Botto

struct BotFaceMotionTests {
    @Test(arguments: [BotMotionActivity.unavailable, .offline])
    func sleepingGentlySquishesWithoutOpeningItsEyes(activity: BotMotionActivity) {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let frames = stride(from: 0.0, through: 8.0, by: 0.125).map { elapsed in
            BotCharacterFrame.resolve(at: start.addingTimeInterval(elapsed), elapsed: elapsed,
                workElapsed: 0, profileID: "sleeping-milo", style: .playful, activity: activity)
        }
        let heights = frames.map(\.scaleY)
        #expect((heights.max() ?? 0) - (heights.min() ?? 0) > 0.06)
        for frame in frames {
            #expect((0.96...1.04).contains(frame.scaleY))
            #expect((0.96...1.04).contains(frame.scaleX))
            #expect((frame.scaleX - 1) * (frame.scaleY - 1) <= 0)
            #expect(frame.closed == 1 && frame.lid == 1)
        }
        let still = BotCharacterFrame.resting(activity: activity)
        #expect(still.scaleX == 1 && still.scaleY == 1 && still.closed == 1)
    }

    #if DEBUG
    @MainActor @Test func completionReactionStaysUprightWhenStyleChangeCrossesLanding() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let airborne = BotCharacterFrame.resolve(at: date, elapsed: 0.7, workElapsed: 0,
                                                 profileID: "motion-milo", style: .soft, activity: .finished)
        #expect(abs(airborne.turn.remainder(dividingBy: 360)) > 45)

        let captured = BotCharacterFrame.resolve(at: date, elapsed: 1.7, workElapsed: 0,
                                                profileID: "motion-milo", style: .soft, activity: .finished)
        for elapsed in [1.849, 1.85, 1.9, 1.939, 1.94, 2.1] {
            let target = BotCharacterFrame.resolve(at: date.addingTimeInterval(elapsed - 1.7),
                                                   elapsed: elapsed, workElapsed: 0,
                                                   profileID: "motion-milo", style: .playful, activity: .finished)
            let visible = BotCharacterFrame.blend(from: captured, to: target, progress: (elapsed - 1.7) / 0.24)
            #expect(abs(visible.turn.remainder(dividingBy: 360)) < 0.0001,
                    "Changing style near landing must not create another visible rotation at \(elapsed)s")
        }
    }
    #endif

    @Test func idleOnlySchedulesBlinkEdgesAndReopensWhenStartingMidBlink() throws {
        let schedule = BotBlinkSchedule(seed: "inbox-triage")
        #expect((3...5).contains(schedule.period))
        #expect(schedule != BotBlinkSchedule(seed: "research"))
        let start = Date(timeIntervalSinceReferenceDate: schedule.phase + schedule.period * 10 + 0.09)
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(5))
        #expect(schedule.isShut(at: entries[0]))
        #expect(!schedule.isShut(at: entries[1]))
        #expect(abs(entries[1].timeIntervalSince(start) - 0.09) < 0.0001)
        #expect(schedule.isShut(at: entries[2]))
        #expect(abs(entries[3].timeIntervalSince(entries[2]) - 0.18) < 0.0001)
        #expect(entries[4].timeIntervalSince(entries[3]) >= 2.82)
    }

    @Test func workingSettlesAfterThirtySecondsAndHonorsReducedMotion() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let schedule = BotWorkingSchedule(start: start, blink: BotBlinkSchedule(seed: "inbox-triage"))
        let entries = Array(schedule.entries(from: start.addingTimeInterval(29), mode: .normal).prefix(22))
        #expect(entries.filter { $0 < start.addingTimeInterval(30) }.count == 15)
        #expect(entries[16].timeIntervalSince(entries[15]) > 0.18)
        #expect(schedule.pose(at: start.addingTimeInterval(31)).roll == 0)
        #expect(schedule.pose(at: start.addingTimeInterval(31)).gazeX == -0.0275)
        #expect(BotFaceMotion.working(since: start).honoring(reduceMotion: true) == .still)
        #expect(BotFaceMotion.idle.honoring(reduceMotion: true) == .still)
    }
}
