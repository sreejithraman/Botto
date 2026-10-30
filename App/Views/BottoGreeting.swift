import SwiftUI
import BottoCore

struct BottoGreeting: View {
    enum Style { case welcome, settings }

    let style: Style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = GreetingPlayback()

    private var isWelcome: Bool { style == .welcome }

    var body: some View {
        Button {
            playback.play(animated: !reduceMotion && scenePhase == .active)
        } label: {
            VStack(spacing: isWelcome ? 24 : 12) {
                bots
                name.font(.system(isWelcome ? .largeTitle : .title2, design: .rounded, weight: .bold))
                if !isWelcome {
                    Text(BottoBrand.tagline)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Botto")
        .accessibilityValue(playback.showsJapanese ? "ボット" : "Botto")
        .accessibilityHint(playback.showsJapanese ? "Show the English name" : "Show the Japanese name and celebrate")
        .accessibilityIdentifier("botto-greeting")
        .onChange(of: reduceMotion) { _, _ in playback.settle() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.settle() }
        }
    }

    private var name: some View {
        Text(playback.showsJapanese ? "ボット" : "Botto")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bots: some View {
        HStack(alignment: .bottom, spacing: isWelcome ? 17 : 12) {
            ForEach(Array(BottoBrand.onboardingAvatars.enumerated()), id: \.element.id) { index, avatar in
                FestivalDancer(avatar: avatar, size: avatar.onboardingSize * (isWelcome ? 1.1 : 0.7),
                               index: index, playback: playback,
                               still: reduceMotion || scenePhase != .active)
            }
        }
        .frame(height: isWelcome ? 132 : 72, alignment: .bottom)
        .clipped()
    }
}

private struct GreetingPlayback {
    private(set) var showsJapanese = false
    private(set) var trigger = 0
    private(set) var animates = false

    mutating func play(animated: Bool) {
        showsJapanese.toggle()
        animates = animated
        trigger += 1
    }

    mutating func settle() {
        animates = false
        trigger += 1
    }
}

private struct FestivalMotion {
    var turn = 0.0
    var costume = 0.0
    var lift = 0.0
    var stretch = 0.0
    var tilt = 0.0
    var sparkles = 0.0
}

private struct FestivalDancer: View {
    let avatar: BottoBrand.Avatar
    let size: CGFloat
    let index: Int
    let playback: GreetingPlayback
    let still: Bool

    var body: some View {
        KeyframeAnimator(initialValue: FestivalMotion(), trigger: playback.trigger) { motion in
            FestivalAvatar(avatar: avatar, size: size,
                           motion: still ? FestivalMotion(costume: playback.showsJapanese ? 1 : 0) : motion)
        } keyframes: { current in
            let delay = 0.02 + Double(index) * 0.07
            let back = floor((current.turn + 180) / 360) * 360 + 180
            let nextTurn = back + 180
            let halfTurn = 0.26
            let returnTime = delay + halfTurn + 0.06 + 0.26
            let direction = index.isMultiple(of: 2) ? 1.0 : -1.0
            KeyframeTrack(\.turn) {
                if playback.animates && !still {
                    LinearKeyframe(current.turn, duration: delay)
                    CubicKeyframe(back, duration: halfTurn)
                    LinearKeyframe(back, duration: 0.06)
                    CubicKeyframe(nextTurn, duration: 0.26)
                } else { MoveKeyframe(0) }
            }
            KeyframeTrack(\.costume) {
                if playback.animates && !still {
                    LinearKeyframe(current.costume, duration: delay + halfTurn + 0.03)
                    MoveKeyframe(playback.showsJapanese ? 1 : 0)
                } else { MoveKeyframe(playback.showsJapanese ? 1 : 0) }
            }
            KeyframeTrack(\.lift) {
                if playback.animates && !still && playback.showsJapanese {
                    CubicKeyframe(0, duration: delay + 0.12)
                    LinearKeyframe(0, duration: returnTime - delay - 0.12 + 0.07)
                    CubicKeyframe(0.22, duration: 0.14)
                    CubicKeyframe(0, duration: 0.20)
                } else { MoveKeyframe(0) }
            }
            KeyframeTrack(\.stretch) {
                if playback.animates && !still && playback.showsJapanese {
                    CubicKeyframe(0, duration: returnTime)
                    CubicKeyframe(-1, duration: 0.07)
                    CubicKeyframe(0.8, duration: 0.14)
                    CubicKeyframe(-0.65, duration: 0.20)
                    CubicKeyframe(0, duration: 0.16)
                } else { MoveKeyframe(0) }
            }
            KeyframeTrack(\.tilt) {
                if playback.animates && !still && playback.showsJapanese {
                    CubicKeyframe(0, duration: returnTime + 0.07)
                    CubicKeyframe(direction * 8, duration: 0.14)
                    CubicKeyframe(-direction * 3, duration: 0.20)
                    CubicKeyframe(0, duration: 0.16)
                } else { MoveKeyframe(0) }
            }
            KeyframeTrack(\.sparkles) {
                MoveKeyframe(0)
                if playback.animates && !still && playback.showsJapanese {
                    LinearKeyframe(0, duration: returnTime + 0.07)
                    LinearKeyframe(1, duration: 0.50)
                } else { MoveKeyframe(0) }
            }
        }
    }
}

private struct FestivalAvatar: View {
    let avatar: BottoBrand.Avatar
    let size: CGFloat
    let motion: FestivalMotion

    private var facingFront: Bool { cos(motion.turn * .pi / 180) >= 0 }

    var body: some View {
        ZStack {
            BotAvatarMark(profile: avatar.profile, size: size)
                .overlay {
                    if motion.costume >= 0.5 {
                        FestivalAttire(shape: avatar.shape, facingFront: true)
                    }
                }
                .rotation3DEffect(.degrees(motion.turn), axis: (x: 0, y: 1, z: 0), perspective: 0.25)
                .opacity(facingFront ? 1 : 0)
            BotAvatarBody(shape: avatar.shape).fill(Color.botBody(avatar.face.color))
                .overlay {
                    if motion.costume >= 0.5 {
                        FestivalAttire(shape: avatar.shape, facingFront: false)
                    }
                }
                .rotation3DEffect(.degrees(motion.turn - 180), axis: (x: 0, y: 1, z: 0), perspective: 0.25)
                .opacity(facingFront ? 0 : 1)
        }
        .frame(width: size, height: size)
        .scaleEffect(x: 1 - motion.stretch * 0.06, y: 1 + motion.stretch * 0.06, anchor: .bottom)
        .rotationEffect(.degrees(avatar.onboardingRoll + motion.tilt))
        .offset(y: -motion.lift * size)
        .overlay {
            FestivalSparkles(progress: motion.sparkles, color: Color.botBody(avatar.face.color))
        }
        .accessibilityHidden(true)
    }
}

private struct FestivalSparkles: View {
    let progress: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 100, y: size.height / 100)
            let spread = progress * 5
            for (x, y, radius) in [(9.0, 26.0, 3.5), (28, 6, 2.5), (78, 9, 3), (94, 33, 2.5)] {
                let center = CGPoint(x: x + (x < 50 ? -spread : spread), y: y - spread)
                let star = Path { path in
                    path.move(to: CGPoint(x: center.x, y: center.y - radius))
                    path.addLine(to: CGPoint(x: center.x + radius * 0.35, y: center.y - radius * 0.35))
                    path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                    path.addLine(to: CGPoint(x: center.x + radius * 0.35, y: center.y + radius * 0.35))
                    path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                    path.addLine(to: CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.35))
                    path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
                    path.addLine(to: CGPoint(x: center.x - radius * 0.35, y: center.y - radius * 0.35))
                    path.closeSubpath()
                }
                context.fill(star, with: .color(x < 50 ? BottoTheme.action : color))
            }
        }
        .opacity(sin(min(1, max(0, progress)) * .pi))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FestivalAttire: View {
    let shape: BotAvatarShape
    let facingFront: Bool

    private nonisolated static let indigo =
        Color.botBody(BotAvatarColors.presets.first { $0.id == "indigo" }!.hex)

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 100, y: size.height / 100)
            var clothing = context
            clothing.clip(to: BotAvatarBody(shape: shape).path(in: CGRect(x: 0, y: 0, width: 100, height: 100)))

            let artwork = shape == .drop ? Artwork.drop : Artwork.round
            let coat = facingFront ? artwork.coat : artwork.back
            clothing.fill(coat, with: .color(Self.indigo))
            var fabric = clothing
            fabric.clip(to: coat)
            fabric.stroke(Artwork.crestRings, with: .color(.white), lineWidth: 1.4)
            fabric.fill(Artwork.crestDots, with: .color(.white))
            fabric.fill(artwork.hem, with: .color(Self.indigo))
            var hem = fabric
            hem.clip(to: artwork.hem)
            hem.fill(Artwork.checks, with: .color(.white))
            if facingFront {
                clothing.stroke(artwork.lapels, with: .color(BottoTheme.surface),
                                style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            }

            for strand in artwork.headband {
                clothing.stroke(strand.full, with: .color(BottoTheme.surface.opacity(0.4)),
                                style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                clothing.stroke(strand.full, with: .color(strand.color),
                                style: StrokeStyle(lineWidth: 3.7, lineCap: .round))
            }
            for strand in artwork.headband {
                clothing.stroke(strand.crossings, with: .color(BottoTheme.surface.opacity(0.23)),
                                style: StrokeStyle(lineWidth: 4.3, lineCap: .round))
                clothing.stroke(strand.crossings, with: .color(strand.color),
                                style: StrokeStyle(lineWidth: 3.7, lineCap: .round))
                clothing.stroke(strand.crossings.offsetBy(dx: 0, dy: -0.65),
                                with: .color(.white.opacity(0.28)),
                                style: StrokeStyle(lineWidth: 0.55, lineCap: .round))
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private struct Artwork {
        static let round = Artwork(isDrop: false)
        static let drop = Artwork(isDrop: true)

        let coat: Path
        let back: Path
        let lapels: Path
        let hem: Path
        let headband: [Strand]

        static let crestRings = Path { path in
            for y in stride(from: 10, through: 90, by: 20) {
                for x in stride(from: 11, through: 99, by: 22) {
                    path.addEllipse(in: CGRect(x: Double(x) - 4.7, y: Double(y) - 4.7,
                                               width: 9.4, height: 9.4))
                }
            }
        }

        static let crestDots = Path { path in
            for y in stride(from: 10, through: 90, by: 20) {
                for x in stride(from: 11, through: 99, by: 22) {
                    for offset in [CGPoint(x: 0, y: -1.8), CGPoint(x: -1.6, y: 1.2),
                                   CGPoint(x: 1.6, y: 1.2)] {
                        path.addEllipse(in: CGRect(x: Double(x) + offset.x - 1,
                                                   y: Double(y) + offset.y - 1, width: 2, height: 2))
                    }
                }
            }
        }

        static let checks = Path { path in
            for row in 0..<15 {
                for column in 0..<15 where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: column * 7, y: row * 7, width: 7, height: 7))
                }
            }
        }

        init(isDrop: Bool) {
            let top: CGFloat = isDrop ? 64 : 58
            back = Path(CGRect(x: 8, y: top, width: 84, height: 100 - top))
            coat = Path { path in
                path.move(to: CGPoint(x: 8, y: top))
                path.addLine(to: CGPoint(x: 34, y: top))
                path.addLine(to: CGPoint(x: 42, y: top + 9))
                path.addLine(to: CGPoint(x: 42, y: 100))
                path.addLine(to: CGPoint(x: 8, y: 100))
                path.closeSubpath()
                path.move(to: CGPoint(x: 92, y: top))
                path.addLine(to: CGPoint(x: 66, y: top))
                path.addLine(to: CGPoint(x: 58, y: top + 9))
                path.addLine(to: CGPoint(x: 58, y: 100))
                path.addLine(to: CGPoint(x: 92, y: 100))
                path.closeSubpath()
            }
            lapels = Path { path in
                path.move(to: CGPoint(x: 34, y: top))
                path.addLine(to: CGPoint(x: 42, y: top + 9))
                path.addLine(to: CGPoint(x: 42, y: 100))
                path.move(to: CGPoint(x: 66, y: top))
                path.addLine(to: CGPoint(x: 58, y: top + 9))
                path.addLine(to: CGPoint(x: 58, y: 100))
            }
            let hemY: CGFloat = isDrop ? 76 : 80
            hem = Path(CGRect(x: 0, y: hemY, width: 100, height: 100 - hemY))
            headband = [Strand(index: 0, bandY: isDrop ? 25 : 20, color: .white),
                        Strand(index: 1, bandY: isDrop ? 25 : 20, color: FestivalAttire.indigo)]
        }
    }

    private struct Strand {
        let color: Color
        let full: Path
        let crossings: Path

        init(index: Int, bandY: CGFloat, color: Color) {
            self.color = color
            full = Path { path in
                for segment in 0..<11 {
                    Self.addSegment(to: &path, segment: segment, strand: index, bandY: bandY)
                }
            }
            crossings = Path { path in
                for segment in 0..<11 where segment % 2 == index {
                    Self.addSegment(to: &path, segment: segment, strand: index, bandY: bandY,
                                    start: 0.19, end: 0.81)
                }
            }
        }

        private static func addSegment(to path: inout Path, segment: Int, strand: Int,
                                       bandY: CGFloat, start: CGFloat = 0, end: CGFloat = 1) {
            func point(_ t: CGFloat) -> (position: CGPoint, slope: CGFloat) {
                let x = 1 + CGFloat(segment) * 9 + t * 9
                let sign: CGFloat = (segment.isMultiple(of: 2) ? -1 : 1) * (strand == 0 ? 1 : -1)
                let arch = (x - 50) / 42
                let ease = 3 * t * t - 2 * t * t * t
                let y = bandY + 3 + 2.7 * arch * arch + sign * 1.65 * (1 - 2 * ease)
                let slope = 5.4 * (x - 50) / (42 * 42) + sign * 1.65 * (-12 * t + 12 * t * t) / 9
                return (CGPoint(x: x, y: y), slope)
            }
            let a = point(start)
            let b = point(end)
            let dx = (b.position.x - a.position.x) / 3
            path.move(to: a.position)
            path.addCurve(to: b.position,
                          control1: CGPoint(x: a.position.x + dx, y: a.position.y + a.slope * dx),
                          control2: CGPoint(x: b.position.x - dx, y: b.position.y - b.slope * dx))
        }
    }
}
