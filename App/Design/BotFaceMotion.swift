// Adapted from Hermex BotFaceMotion.swift. MIT; see LICENSES/Hermex.txt.
import SwiftUI

enum BotFaceMotion: Equatable, Sendable {
    case still, idle
    case working(since: Date)

    func honoring(reduceMotion: Bool) -> BotFaceMotion { reduceMotion ? .still : self }
}

/// One frame of a face: gaze offset as a fraction of the mark size, head roll in
/// degrees and the lid factor applied to eye height (1 open, 0.06 shut).
struct BotFacePose: Equatable, Sendable {
    var gazeX = 0.0
    var gazeY = 0.0
    var roll = 0.0
    var lid = 1.0
    static let rest = BotFacePose()
    static let blink = BotFacePose(lid: 0.06)

    /// Desktop's `work` pose (`avatar.tsx` facePose), scaled from head degrees onto the mark.
    static func working(at t: Double) -> BotFacePose {
        let turn = -11 + sin(t * 0.48) * 8
        let tilt = sin(t * 0.42) * 8 + sin(t * 1.1) * 1.6
        let roll = sin(t * 0.75) * 4.2
        let blink = t.truncatingRemainder(dividingBy: 1.45) > 1.26
        return BotFacePose(gazeX: turn * 0.0025, gazeY: -tilt * 0.0025, roll: roll, lid: blink ? 0.06 : 1)
    }

    static let settledWorking = BotFacePose(gazeX: -11 * 0.0025)
}

/// Only blink edges trigger redraws; the profile ID seeds an independent rhythm
/// for each bot.
struct BotBlinkSchedule: TimelineSchedule, Equatable {
    static let shutDuration = 0.18
    let period: Double
    let phase: Double

    init(seed: String) {
        let hash = seed.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        period = 3 + Double(hash % 2001) / 1000
        phase = Double((hash >> 20) % 5000) / 1000
    }

    func isShut(at date: Date) -> Bool {
        let offset = (date.timeIntervalSinceReferenceDate - phase).truncatingRemainder(dividingBy: period)
        let position = offset < 0 ? offset + period : offset
        // The open entry lands exactly at shutDuration; keep float error from reading it as shut.
        return position + 0.0001 < Self.shutDuration
    }

    func entries(from start: Date, mode: Mode) -> AnySequence<Date> {
        let period = period, shut = Self.shutDuration
        let base = start.timeIntervalSinceReferenceDate
        let firstShut = phase + (floor((base - phase) / period) + 1) * period
        // Starting inside a blink still needs that blink's open edge, or the eyes
        // would stay shut until the next cycle.
        let pendingOpen: Date? = isShut(at: start) ? Date(timeIntervalSinceReferenceDate: firstShut - period + shut) : nil
        return AnySequence { () -> AnyIterator<Date> in
            var index = -1
            let edges = [start] + (pendingOpen.map { [$0] } ?? [])
            return AnyIterator {
                index += 1
                if index < edges.count { return edges[index] }
                let step = index - edges.count
                let blink = firstShut + Double(step / 2) * period
                return Date(timeIntervalSinceReferenceDate: step.isMultiple(of: 2) ? blink : blink + shut)
            }
        }
    }
}

/// Sways for one beat from `start`, then schedules only blink edges to avoid
/// continuous repainting during long turns.
struct BotWorkingSchedule: TimelineSchedule, Equatable {
    static let beat = 30.0
    static let frameInterval = 1.0 / 15
    let start: Date
    let blink: BotBlinkSchedule

    private var end: Date { start.addingTimeInterval(Self.beat) }

    func pose(at date: Date) -> BotFacePose {
        if date < end { return .working(at: date.timeIntervalSinceReferenceDate) }
        var pose = BotFacePose.settledWorking
        if blink.isShut(at: date) { pose.lid = BotFacePose.blink.lid }
        return pose
    }

    func entries(from date: Date, mode: Mode) -> AnySequence<Date> {
        let end = end
        guard date < end else { return blink.entries(from: date, mode: mode) }
        let first = max(date, start), blink = blink
        return AnySequence { () -> AnyIterator<Date> in
            var frame = 0
            // The blink schedule's first entry is `end` itself, which paints the settled pose.
            let settled = blink.entries(from: end, mode: mode).makeIterator()
            return AnyIterator {
                let next = first.addingTimeInterval(Double(frame) * Self.frameInterval)
                guard next < end else { return settled.next() }
                frame += 1
                return next
            }
        }
    }
}
