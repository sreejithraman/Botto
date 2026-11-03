import Foundation
import Testing
import BottoCore
@testable import Botto

struct BotFaceMotionTests {
    @Test func completionTurnsOnceAndReturnsToRest() {
        let airborne = BotCharacterFrame.resolve(elapsed: 0.7, activity: .finished)
        #expect(airborne.turn > 45 && airborne.turn < 360)
        for elapsed in [1.85, 2, 10, 100] {
            let frame = BotCharacterFrame.resolve(elapsed: elapsed, activity: .finished)
            #expect(frame.turn == 0 && frame.lift == 0 && frame.tuck == 1)
        }
    }
    @Test func failureShakesOnceAndReducedMotionSuppressesReactions() {
        #expect(BotCharacterFrame.resolve(elapsed: 0.22, activity: .failed).shiftX < 0)
        #expect(BotCharacterFrame.resolve(elapsed: 0.3, activity: .failed).shiftX > 0)
        #expect(BotCharacterFrame.resolve(elapsed: 5, activity: .failed).shiftX == 0)
        for activity in BotMotionActivity.allCases {
            let frame = BotCharacterFrame.resolve(elapsed: 0.7, activity: activity, still: true)
            #expect(frame.turn == 0 && frame.lift == 0 && frame.scaleY == 1)
        }
    }
    @Test func canonicalEngineOwnsOrdinaryMotion() {
        for activity in [BotMotionActivity.idle, .working, .waiting, .replying, .offline] {
            let frame = BotCharacterFrame.resolve(elapsed: 0.7, activity: activity)
            #expect(frame.turn == 0 && frame.roll == 0 && frame.lift == 0 && frame.scaleY == 1)
        }
        #expect(BotAvatarActivityStyle.phase(for: "milo") == BotAvatarActivityStyle.phase(for: "milo"))
        #expect(BotAvatarActivityStyle.phase(for: "milo") != BotAvatarActivityStyle.phase(for: "scout"))
    }
    @Test func compatibleExpressionsKeepAllStoredNames() {
        #expect(BotAvatarExpression.allCases.count == 16)
        #expect(BotAvatarExpression.happy.motion == .happy)
        #expect(BotAvatarExpression.curious.motion == .thinking)
        #expect(BotAvatarExpression.resolve("unknown") == .neutral)
        #expect(BotFaceMotion.idle.honoring(reduceMotion: true) == .still)
    }
}
