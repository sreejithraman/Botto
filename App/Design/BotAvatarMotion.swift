import SwiftUI
import BottoCore

enum BotMotionStyle: String, CaseIterable, Identifiable {
    case original = "Original", attentive = "Attentive", soft = "Soft", playful = "Playful"
    var id: Self { self }
}

enum BotMotionActivity: String, CaseIterable, Identifiable {
    case idle = "Idle", thinking = "Thinking", working = "Working"
    case tools = "Using tool", failed = "Error"
    case waiting = "Needs you", replying = "Replying", finished = "Finished"
    case unavailable = "Unavailable", offline = "Offline"
    var id: Self { self }
    var isWorkingPhase: Bool { [.thinking, .working, .tools, .replying].contains(self) }
    var isSleeping: Bool { self == .unavailable || self == .offline }
    var detail: String {
        switch self {
        case .idle: "Quiet breathing, blinks and occasional eye movements."
        case .thinking: "Look up, consider and refocus, with a little lightbulb."
        case .working: "Hops, rocking, stretches, scoots and wiggles on one shared work rhythm."
        case .tools: "Open, watchful eyes and a little wrench at work."
        case .failed: "Puff up in surprise, shake it off, then hold the error cue."
        case .waiting: "A curious head tilt, thoughtful eye movements and a question cue."
        case .replying: "Lean into the chat with a light conversational rhythm."
        case .finished: "One jump, a tucked somersault and a soft landing back to idle."
        case .unavailable: "Eyes gently closed with a little zzz while activity is unavailable."
        case .offline: "Eyes gently closed with a soft breathing squish and a no-signal cue while Botto is offline."
        }
    }

    static func observed(_ status: BotStatus?) -> Self {
        switch status {
        case .idle: .idle
        case .working: .working
        case .waiting: .waiting
        case nil: .unavailable
        }
    }
}

struct BotAvatarMotion: View {
    let profile: BotProfile
    let size: CGFloat
    let presentation: BotAvatarPresentation
    var style: BotMotionStyle = .playful
    let still: Bool
    /// Normalized canvas coordinates, centered at zero; nil keeps the ordinary cue placement.
    var minimumCueTop: Double? = nil
    @State private var interruptedFrame: BotCharacterFrame?
    @State private var interruptedAt = Date.distantPast

    private struct Playback: Equatable {
        let presentation: BotAvatarPresentation
        let style: BotMotionStyle
    }
    private var playback: Playback { .init(presentation: presentation, style: style) }

    var body: some View {
        Group {
            if still {
                mark(.resting(activity: presentation.activity))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    mark(visible(at: context.date, playback: playback))
                }
            }
        }
        .onChange(of: playback) { old, new in
            let now = Date.now
            var current = visible(at: now, playback: old)
            let next = frame(at: now, playback: new)
            // Normalize at interruption only; authored turns retain their full rotation.
            current.turn = next.turn + (current.turn - next.turn).remainder(dividingBy: 360)
            interruptedFrame = current
            interruptedAt = now
        }
    }

    private func frame(at date: Date, playback: Playback) -> BotCharacterFrame {
        let value = playback.presentation
        return BotCharacterFrame.resolve(at: date, elapsed: max(0, date.timeIntervalSince(value.enteredAt)),
            workElapsed: max(0, date.timeIntervalSince(value.workStartedAt ?? value.enteredAt)),
            profileID: profile.id, style: playback.style, activity: value.activity)
    }

    private func visible(at date: Date, playback: Playback) -> BotCharacterFrame {
        let target = frame(at: date, playback: playback)
        return interruptedFrame.map {
            BotCharacterFrame.blend(from: $0, to: target, progress: date.timeIntervalSince(interruptedAt) / 0.24)
        } ?? target
    }

    private func mark(_ frame: BotCharacterFrame) -> some View {
        let amount = size < 40 ? 0.55 : 1.0
        return BotAvatarMark(profile: profile, size: size,
                             pose: BotFacePose(gazeX: frame.x * amount, gazeY: frame.y * amount,
                                               roll: frame.roll * amount + frame.turn, lid: frame.lid),
                             animatedEyes: frame.eyes(for: profile))
            .scaleEffect(x: (1 + (frame.scaleX - 1) * amount) * frame.tuck,
                         y: (1 + (frame.scaleY - 1) * amount) * frame.tuck)
            .overlay {
                ZStack {
                    BotAvatarActivityCue(shape: profile.face.shape, size: size,
                        activity: presentation.activity, frame: frame, minimumCueTop: minimumCueTop)
                        .id(presentation.activity)
                        .transition(.opacity)
                }
                .animation(still ? nil : .easeInOut(duration: 0.18), value: presentation.activity)
                .accessibilityHidden(true)
            }
            .offset(x: size * frame.shiftX * amount, y: size * frame.lift * amount)
    }
}

struct BotAvatarActivityCue: View {
    let shape: BotAvatarShape
    let size: CGFloat
    let activity: BotMotionActivity
    var frame = BotCharacterFrame()
    var minimumCueTop: Double? = nil

    var body: some View {
        Group {
            if activity == .tools {
                tool(angle: frame.toolAngle * (size < 40 ? 0.55 : 1))
            } else {
                activityMarker(frame)
            }
        }
        .accessibilityHidden(true)
    }

    private var cueSize: CGFloat { max(48, size) }

    private func cueAnchor(_ corner: BotActivityCueCorner) -> CGPoint {
        let point = BotMotionActivityCuePlacement(shape: shape).anchor(for: corner)
        let extraClearance = (cueSize - size) * 0.36
        let topExtent = cueSize * (activity == .unavailable ? 0.33 : 0.23)
        let y = minimumCueTop.map { max(size * point.y, size * $0 + topExtent) } ?? size * point.y
        return CGPoint(x: size * point.x + corner.horizontalDirection * extraClearance, y: y)
    }

    private func tool(angle: Double) -> some View {
        let anchor = BotMotionActivityCuePlacement(shape: shape).anchor(for: .bottomRight)
        let growth = cueSize - size
        let smallSizeClearance: CGSize = switch shape {
        case .pill: .init(width: 0.18, height: 0.10)
        case .cloud: .init(width: 0.18, height: 0.09)
        case .drop: .init(width: 0.25, height: 0.09)
        case .hexagon: .init(width: 0.30, height: 0)
        default: .init(width: 0.18, height: 0)
        }
        return Image(systemName: "wrench.fill")
            .font(.system(size: cueSize * 0.28, weight: .semibold))
            .foregroundStyle(Color(white: 0.34))
            .shadow(color: BottoTheme.paper, radius: 0, x: 0, y: 1)
            .frame(width: cueSize * 0.32, height: cueSize * 0.32)
            .rotationEffect(.degrees(-20 + angle))
            // Keep the head attached when the glyph grows on small avatars.
            .offset(x: size * anchor.x - cueSize * 0.11 + growth * smallSizeClearance.width,
                    y: size * anchor.y + cueSize * 0.015 + growth * smallSizeClearance.height)
    }

    @ViewBuilder private func activityMarker(_ frame: BotCharacterFrame) -> some View {
        switch activity {
        case .offline:
            let anchor = cueAnchor(.topRight)
            Image(systemName: "wifi.slash")
                .resizable().scaledToFit()
                .font(.system(size: cueSize * 0.28, weight: .semibold))
                .frame(width: cueSize * 0.32, height: cueSize * 0.28)
                .foregroundStyle(BottoTheme.ink)
                .shadow(color: BottoTheme.paper, radius: 0, x: 0, y: 1)
                .offset(x: anchor.x, y: anchor.y)
        case .failed:
            let anchor = cueAnchor(.topRight)
            BotActivityCueBubble(symbol: "exclamationmark", size: cueSize)
                .offset(x: anchor.x, y: anchor.y)
        case .thinking:
            let anchor = cueAnchor(.topLeft)
            ZStack {
                Circle().fill(Color.yellow.opacity(0.08 + frame.idea * 0.18))
                    .frame(width: cueSize * 0.38, height: cueSize * 0.38)
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(Color(red: 1, green: 0.86, blue: 0.22))
                    .overlay {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(Color(red: 0.70, green: 0.53, blue: 0.10))
                    }
                    .font(.system(size: cueSize * 0.27, weight: .semibold))
            }
            .rotationEffect(.degrees(-8 + 12 * frame.idea))
            .scaleEffect(0.92 + 0.12 * frame.idea)
            .offset(x: anchor.x, y: anchor.y - size * 0.01 * frame.idea)
        case .waiting:
            let anchor = cueAnchor(.topRight)
            BotActivityCueBubble(symbol: "questionmark", size: cueSize)
                .rotationEffect(.degrees(frame.roll * 0.35))
                .offset(x: anchor.x, y: anchor.y)
        case .finished:
            let anchor = cueAnchor(.bottomLeft)
            Image(systemName: "sparkles")
                .font(.system(size: cueSize * 0.28, weight: .semibold))
                .foregroundStyle(Color.yellow)
                .opacity(frame.celebration)
                .scaleEffect(0.8 + 0.2 * frame.celebration)
                .offset(x: anchor.x, y: anchor.y)
        case .unavailable:
            let anchor = cueAnchor(.topRight)
            ZStack {
                ForEach(0..<3) { index in
                    let progress = (frame.sleepPhase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                    let opacity = min(1, progress / 0.12) * min(1, (1 - progress) / 0.38)
                    Text("z").font(.system(size: max(9, size * (0.095 + 0.045 * progress)), weight: .bold, design: .rounded))
                        .foregroundStyle(BottoTheme.ink)
                        .opacity(opacity)
                        .offset(x: size * (-0.10 + 0.18 * progress),
                                y: size * (0.14 - 0.39 * progress))
                }
            }
            .offset(x: anchor.x, y: max(anchor.y, -size * 0.35))
        default:
            EmptyView()
        }
    }
}

private struct BotActivityCueBubble: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        let diameter = size * 0.30
        ZStack(alignment: .topLeading) {
            BotActivityCueBubbleShape()
                .fill(BottoTheme.attention)
                .overlay {
                    BotActivityCueBubbleShape()
                        .stroke(BottoTheme.paper, lineWidth: max(1.5, size * 0.018))
                }
            Image(systemName: symbol)
                .resizable().scaledToFit()
                .font(.system(size: size * 0.18, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: max(9, size * 0.16), height: max(10, size * 0.18))
                .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: size * 0.34)
    }
}

private struct BotActivityCueBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(150), endAngle: .degrees(468), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + rect.width / 15, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private enum BotActivityCueCorner {
    case topLeft, topRight, bottomLeft, bottomRight

    var horizontalDirection: CGFloat {
        switch self {
        case .topLeft, .bottomLeft: -1
        case .topRight, .bottomRight: 1
        }
    }
}

/// Centers in mark coordinates. Each contour gets its own four attachment points;
/// expressions and gaze never pull a cue toward the middle of the face.
private struct BotMotionActivityCuePlacement {
    let shape: BotAvatarShape

    func anchor(for corner: BotActivityCueCorner) -> CGPoint {
        let points: (topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint)
        switch shape {
        case .circle:
            points = (.init(x: -0.34, y: -0.34), .init(x: 0.41, y: -0.47),
                      .init(x: -0.34, y: 0.34), .init(x: 0.34, y: 0.34))
        case .blob:
            points = (.init(x: -0.33, y: -0.34), .init(x: 0.43, y: -0.47),
                      .init(x: -0.34, y: 0.34), .init(x: 0.35, y: 0.36))
        case .squircle:
            points = (.init(x: -0.38, y: -0.36), .init(x: 0.44, y: -0.47),
                      .init(x: -0.38, y: 0.36), .init(x: 0.38, y: 0.36))
        case .pill:
            points = (.init(x: -0.40, y: -0.22), .init(x: 0.44, y: -0.47),
                      .init(x: -0.40, y: 0.22), .init(x: 0.47, y: 0.25))
        case .triangle:
            points = (.init(x: -0.22, y: -0.26), .init(x: 0.24, y: -0.30),
                      .init(x: -0.40, y: 0.38), .init(x: 0.40, y: 0.38))
        case .hexagon:
            points = (.init(x: -0.37, y: -0.29), .init(x: 0.44, y: -0.47),
                      .init(x: -0.37, y: 0.29), .init(x: 0.37, y: 0.29))
        case .cloud:
            points = (.init(x: -0.20, y: -0.35), .init(x: 0.43, y: -0.36),
                      .init(x: -0.35, y: 0.31), .init(x: 0.49, y: 0.31))
        case .drop:
            points = (.init(x: -0.32, y: -0.35), .init(x: 0.33, y: -0.37),
                      .init(x: -0.34, y: 0.32), .init(x: 0.38, y: 0.32))
        case .sun:
            points = (.init(x: -0.33, y: -0.33), .init(x: 0.36, y: -0.37),
                      .init(x: -0.33, y: 0.33), .init(x: 0.33, y: 0.33))
        case .nub:
            points = (.init(x: -0.34, y: -0.36), .init(x: 0.44, y: -0.40),
                      .init(x: -0.32, y: 0.35), .init(x: 0.33, y: 0.35))
        }
        return switch corner {
        case .topLeft: points.topLeft
        case .topRight: points.topRight
        case .bottomLeft: points.bottomLeft
        case .bottomRight: points.bottomRight
        }
    }
}

/// Authored poses with holds; all times are local, so a repeat can start immediately.
struct BotCharacterFrame {
    var x = 0.0
    var y = 0.0
    var roll = 0.0
    var lid = 1.0
    var scaleX = 1.0
    var scaleY = 1.0
    var lift = 0.0
    var focus = 0.0
    var surprise = 0.0
    var closed = 0.0
    var toolAngle = 0.0
    var idea = 0.4
    var sleepPhase = 0.0
    var celebration = 0.0
    var turn = 0.0
    var tuck = 1.0
    var shiftX = 0.0

    static func resting(activity: BotMotionActivity) -> Self {
        switch activity {
        case .tools: Self()
        case .working, .thinking: Self()
        case .failed: Self(surprise: 0.85)
        case .unavailable, .offline: Self(closed: 1, sleepPhase: 0.17)
        default: Self()
        }
    }

    func eyes(for profile: BotProfile) -> BotAvatarExpression.Geometry {
        typealias Geometry = BotAvatarExpression.Geometry
        func blend(_ a: Geometry, _ b: Geometry, _ progress: Double) -> Geometry {
            func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * progress }
            func eye(_ x: BotAvatarExpression.Eye, _ y: BotAvatarExpression.Eye) -> BotAvatarExpression.Eye {
                .init(width: mix(x.width, y.width), height: mix(x.height, y.height), tilt: mix(x.tilt, y.tilt))
            }
            return Geometry(left: eye(a.left, b.left), right: eye(a.right, b.right), split: mix(a.split, b.split))
        }
        let saved = BotAvatarExpression.resolve(profile.appearance?.expression).geometry
        let narrow = Geometry(left: .init(width: 0.28, height: 0.075, tilt: 18),
                              right: .init(width: 0.28, height: 0.075, tilt: 18), split: 16)
        let focused = blend(saved, narrow, focus)
        let surprised = blend(focused, BotAvatarExpression.surprised.geometry, surprise)
        let shut = Geometry(left: .init(width: 0.30, height: 0.028, tilt: 18),
                            right: .init(width: 0.30, height: 0.028, tilt: 18), split: 16)
        return blend(surprised, shut, closed)
    }

    static func blend(from a: Self, to b: Self, progress: Double) -> Self {
        let progress = min(1, max(0, progress))
        let eased = progress * progress * (3 - 2 * progress)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * eased }
        return Self(x: mix(a.x, b.x), y: mix(a.y, b.y), roll: mix(a.roll, b.roll),
                    lid: mix(a.lid, b.lid), scaleX: mix(a.scaleX, b.scaleX),
                    scaleY: mix(a.scaleY, b.scaleY), lift: mix(a.lift, b.lift),
                    focus: mix(a.focus, b.focus), surprise: mix(a.surprise, b.surprise),
                    closed: mix(a.closed, b.closed), toolAngle: mix(a.toolAngle, b.toolAngle),
                    idea: mix(a.idea, b.idea), sleepPhase: mix(a.sleepPhase, b.sleepPhase),
                    celebration: mix(a.celebration, b.celebration),
                    turn: mix(a.turn, b.turn), tuck: mix(a.tuck, b.tuck), shiftX: mix(a.shiftX, b.shiftX))
    }

    static func resolve(at date: Date, elapsed: Double, workElapsed: Double, profileID: String,
                        style: BotMotionStyle, activity: BotMotionActivity) -> Self {
        let rhythm = BotBlinkSchedule(seed: profileID)
        let phase = date.timeIntervalSinceReferenceDate + rhythm.phase
        var frame: Self
        switch activity {
        case .idle:
            frame = quietIdle(elapsed: elapsed, rhythm: rhythm)
        case .thinking, .working, .tools, .replying:
            let t = (workElapsed + rhythm.phase * 0.4).truncatingRemainder(dividingBy: 22.8)
            frame = workingBody(t, variation: Int(rhythm.period * 1000) % 6)
            switch activity {
            case .thinking:
                frame.x += -0.018 + 0.008 * sin(workElapsed * 2 * .pi / 6.5)
                frame.y -= 0.022
                frame.idea = 0.5 + 0.5 * sin(workElapsed * 2 * .pi / 3.4)
                frame.focus = 0.25 + 0.35 * (1 - frame.idea)
            case .tools:
                frame.x += 0.012; frame.y += 0.01
                frame.toolAngle = 18 * sin(t * 2 * .pi / 1.9)
                frame.focus = 0.1 + 0.15 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.9))
            case .replying:
                frame.x += 0.015; frame.y -= 0.006
                frame.surprise = 0.12 + 0.1 * sin(workElapsed * 2 * .pi / 2.8)
            default:
                frame.x -= 0.012; frame.focus = 0.35
            }
            frame.x = min(0.04, max(-0.04, frame.x))
            frame.y = min(0.04, max(-0.04, frame.y))
        case .failed:
            frame = sample(elapsed, [
                (0, Self()),
                (0.14, Self(scaleX: 1.11, scaleY: 1.09, lift: -0.012, surprise: 1)),
                (0.22, Self(roll: -5, scaleX: 1.075, scaleY: 1.065, lift: -0.01, surprise: 1, shiftX: -0.035)),
                (0.30, Self(roll: 4, scaleX: 1.06, scaleY: 1.06, surprise: 1, shiftX: 0.035)),
                (0.38, Self(roll: -3, scaleX: 1.045, scaleY: 1.045, surprise: 1, shiftX: -0.027)),
                (0.46, Self(roll: 2, scaleX: 1.03, scaleY: 1.03, surprise: 1, shiftX: 0.02)),
                (0.56, Self(roll: -1, surprise: 0.9, shiftX: -0.012)),
                (0.75, Self(scaleX: 1.015, scaleY: 0.985, surprise: 0.85)), (1.1, Self(surprise: 0.85))
            ])
        case .waiting:
            let t = (elapsed + rhythm.phase * 0.3).truncatingRemainder(dividingBy: 8.4)
            frame = sample(t, [
                (0, Self()), (0.18, Self(x: -0.022, y: -0.022)),
                (0.5, Self(x: -0.022, y: -0.022, roll: 7, scaleX: 0.99, scaleY: 1.01, focus: 0.1)),
                (1.8, Self(x: -0.022, y: -0.022, roll: 7, focus: 0.1)),
                (2.4, Self(x: 0.01, y: -0.005, roll: 3)),
                (3.1, Self(x: 0.018, y: -0.018, roll: -4, focus: 0.25)),
                (4.5, Self(x: 0.018, y: -0.018, roll: -4, focus: 0.25)),
                (5.2, Self(x: -0.01, y: -0.006, roll: 1)), (7.5, Self(roll: 1)), (8.4, Self())
            ])
            frame.surprise = 0.12
        case .finished:
            if elapsed < 1.85 {
                frame = sample(elapsed, [
                    (0, Self()), (0.16, Self(roll: -6, scaleX: 1.075, scaleY: 0.925, lift: 0.025)),
                    (0.34, Self(roll: -5, scaleX: 0.98, scaleY: 1.02, lift: -0.06, celebration: 0.3, tuck: 0.92)),
                    (0.47, Self(lift: -0.115, celebration: 0.8, tuck: 0.76)),
                    (1.02, Self(lift: -0.115, celebration: 1, turn: 360, tuck: 0.76)),
                    (1.16, Self(lift: -0.045, celebration: 0.8, turn: 360, tuck: 0.92)),
                    (1.32, Self(scaleX: 1.06, scaleY: 0.94, lift: 0.025, celebration: 0.6, turn: 360)),
                    (1.5, Self(lid: 0.65, scaleX: 0.99, scaleY: 1.01, lift: -0.013, celebration: 0.3, turn: 360)),
                    (1.85, Self(turn: 360))
                ])
            } else {
                frame = quietIdle(elapsed: elapsed - 1.85, rhythm: rhythm)
                // Keep the unwrapped final angle while a late style-change blend finishes.
                frame.turn = 360
            }
        case .unavailable, .offline:
            frame = Self(closed: 1, sleepPhase: elapsed.truncatingRemainder(dividingBy: 3.6) / 3.6)
        }
        let breath = sin(phase * 2 * .pi / (3.8 + (rhythm.period - 3) * 0.5))
        let presence = activity.isSleeping ? 2.2 : activity.isWorkingPhase ? 0.5 : 0.25
        frame.scaleX *= 1 - 0.009 * breath * presence
        frame.scaleY *= 1 + 0.012 * breath * presence
        frame.lift -= 0.004 * breath * presence
        if activity.isWorkingPhase { frame.roll += 0.35 * sin(phase * 2 * .pi / 6.7) }
        let energy = style == .playful ? 1.35 : style == .attentive ? 0.7 : 1.0
        frame.roll *= energy
        if style == .attentive {
            frame.scaleX = 1; frame.scaleY = 1; frame.lift *= 0.6
        } else {
            frame.scaleX = 1 + (frame.scaleX - 1) * energy
            frame.scaleY = 1 + (frame.scaleY - 1) * energy
            frame.lift *= energy
        }
        if !activity.isSleeping {
            let blinkTime = phase.truncatingRemainder(dividingBy: rhythm.period + 1.7)
            frame.lid *= sample(blinkTime, [
                (0, Self()), (0.07, Self(lid: 0.06)), (0.12, Self(lid: 0.06)), (0.23, Self())
            ]).lid
        }
        return frame
    }

    private static func quietIdle(elapsed: Double, rhythm: BotBlinkSchedule) -> Self {
        let t = (elapsed + rhythm.phase * 0.4).truncatingRemainder(dividingBy: 12)
        return sample(t, [
            (0, Self()), (3, Self()), (3.3, Self(x: 0.02, y: -0.006)),
            (5, Self(x: 0.02, y: -0.006)), (5.4, Self(x: -0.015, y: -0.01)),
            (7.4, Self(x: -0.015, y: -0.01)), (7.8, Self()), (12, Self())
        ])
    }

    private static func workingBody(_ time: Double, variation: Int) -> Self {
        let phrase = (Int(time / 3.8) + variation) % 6
        let t = time.truncatingRemainder(dividingBy: 3.8)
        switch phrase {
        case 1:
            return sample(t, [
                (0, Self()), (0.3, Self(roll: -5, scaleX: 1.025, scaleY: 0.975, lift: 0.008)),
                (0.75, Self(roll: 5, scaleX: 0.985, scaleY: 1.015, lift: -0.025)),
                (1.1, Self(roll: -4, lift: -0.01)),
                (1.55, Self(roll: 4, scaleX: 1.02, scaleY: 0.98, lift: 0.01)),
                (2.1, Self(roll: -2, scaleX: 0.99, scaleY: 1.01, lift: -0.018)),
                (2.6, Self()), (3.1, Self(scaleX: 0.96, scaleY: 1.04, lift: -0.012)), (3.8, Self())
            ])
        case 2:
            return sample(t, [
                (0, Self()), (0.25, Self(roll: 2, scaleX: 1.045, scaleY: 0.955, lift: 0.02)),
                (0.47, Self(roll: -3, scaleX: 0.99, scaleY: 1.01, lift: -0.04)),
                (0.74, Self(scaleX: 1.035, scaleY: 0.965, lift: 0.02)),
                (0.94, Self(roll: 4, lift: -0.065)),
                (1.27, Self(roll: -2, scaleX: 1.045, scaleY: 0.955, lift: 0.015)), (1.6, Self()),
                (2.2, Self(roll: 3, scaleX: 0.975, scaleY: 1.025, lift: -0.01)),
                (2.9, Self(roll: -2, lift: -0.012)), (3.5, Self()), (3.8, Self())
            ])
        case 3:
            return sample(t, [
                (0, Self()), (0.35, Self(x: -0.015, roll: -5, scaleX: 0.98, scaleY: 1.02, lift: -0.02, shiftX: -0.025)),
                (0.85, Self(x: -0.015, roll: -5, shiftX: -0.025)),
                (1.3, Self(x: 0.015, roll: 4, lift: -0.035, shiftX: 0.03)),
                (1.7, Self(scaleX: 1.03, scaleY: 0.97, lift: 0.012, shiftX: 0.025)),
                (2.3, Self(x: -0.012, roll: -3, shiftX: -0.02)), (3, Self()), (3.8, Self())
            ])
        case 4:
            return sample(t, [
                (0, Self()), (0.4, Self(y: 0.01, scaleX: 1.055, scaleY: 0.945, lift: 0.02, tuck: 0.95)),
                (0.8, Self(y: -0.012, scaleX: 0.95, scaleY: 1.05, lift: -0.035)),
                (1.3, Self(roll: 3, scaleX: 0.98, scaleY: 1.02, lift: -0.045)),
                (1.7, Self(roll: -2, scaleX: 1.04, scaleY: 0.96, lift: 0.015)),
                (2.1, Self()), (2.7, Self(y: -0.008, scaleX: 0.975, scaleY: 1.025)), (3.8, Self())
            ])
        case 5:
            return sample(t, [
                (0, Self()), (0.25, Self(roll: -5, shiftX: -0.018)),
                (0.55, Self(roll: 5, lift: -0.02, shiftX: 0.018)),
                (0.8, Self(roll: -4, scaleX: 1.025, scaleY: 0.975, shiftX: -0.014)),
                (1.1, Self(roll: 4, lift: -0.025, shiftX: 0.014)),
                (1.5, Self(roll: -2)), (2, Self()),
                (2.5, Self(x: 0.012, roll: 3, lift: -0.012)), (3, Self(x: -0.012, roll: -2)), (3.8, Self())
            ])
        default:
            return sample(t, [
            (0, Self()), (0.18, Self(roll: -2, scaleX: 1.055, scaleY: 0.945, lift: 0.022)),
            (0.36, Self(roll: 3, scaleX: 0.98, scaleY: 1.02, lift: -0.06)),
            (0.58, Self(roll: 4, lift: -0.07)),
            (0.88, Self(roll: -2, scaleX: 1.045, scaleY: 0.955, lift: 0.012)),
            (1.12, Self(roll: 1, scaleX: 0.99, scaleY: 1.01, lift: -0.015)), (1.5, Self()),
            (2.2, Self(roll: 1, scaleX: 1.03, scaleY: 0.97, lift: 0.012)),
            (2.42, Self(roll: -2, lift: -0.035)),
            (2.68, Self(scaleX: 1.025, scaleY: 0.975, lift: 0.008)), (3, Self()), (3.8, Self())
            ])
        }
    }

    private static func sample(_ time: Double, _ keys: [(Double, Self)]) -> Self {
        guard let first = keys.first, let last = keys.last else { return Self() }
        if time <= first.0 { return first.1 }
        for index in 1..<keys.count {
            let (end, b) = keys[index]
            let (start, a) = keys[index - 1]
            if time <= end {
                return blend(from: a, to: b, progress: (time - start) / (end - start))
            }
        }
        return last.1
    }
}
