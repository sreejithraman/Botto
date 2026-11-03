import SwiftUI
import BottoCore

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
        case .working: "Thoughtful motion follows the reference avatar engine."
        case .tools: "Open, watchful eyes and a little wrench at work."
        case .failed: "Puff up in surprise, shake it off, then hold the error cue."
        case .waiting: "Thoughtful motion and a question cue."
        case .replying: "Lean into the chat with a light conversational rhythm."
        case .finished: "One jump, a tucked somersault and a soft landing back to idle."
        case .unavailable: "Eyes gently closed with a little zzz while activity is unavailable."
        case .offline: "Eyes gently closed with a no-signal cue while Botto is offline."
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
    let still: Bool
    var minimumCueTop: Double? = nil
    @State private var model = BotAvatarRenderModel()

    var body: some View {
        let geometry = profile.appearance?.geometry ?? BotAvatarCatalog.geometry(for: profile.face.shape)
        let drawing = model.drawing(for: geometry)
        let reaction = BotCharacterFrame.resolve(elapsed: still ? .infinity : max(0, model.date.timeIntervalSince(presentation.enteredAt)),
                                                 activity: presentation.activity, still: still)
        Group {
            if let (asset, frame) = drawing {
                BotAvatarCanvas(asset: asset, frame: frame, color: profile.face.color,
                                eyes: BotAvatarActivityStyle.eyes(profile: profile, activity: presentation.activity))
                    .overlay {
                        BotAvatarActivityCue(shape: profile.face.shape, size: size, activity: presentation.activity,
                            frame: reaction, minimumCueTop: minimumCueTop,
                            placement: BotAvatarContourPlacement(asset: asset, frame: frame))
                    }
                    .scaleEffect(x: reaction.scaleX * reaction.tuck, y: reaction.scaleY * reaction.tuck)
                    .rotationEffect(.degrees(reaction.roll + reaction.turn))
                    .offset(x: size * reaction.shiftX, y: size * reaction.lift)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: presentation, initial: true) { _, updated in model.updatePresentation(updated) }
        .task(id: BotAvatarPlayback(profile: profile, presentation: presentation, still: still)) {
            await model.run(profile: profile, initialPresentation: presentation, still: still)
        }
        .task(id: NativeClock(presentation: presentation, still: still)) {
            await model.runClock(presentation: presentation, still: still)
        }
        .onDisappear { model.retire() }
    }

    private struct NativeClock: Equatable {
        let presentation: BotAvatarPresentation
        let still: Bool
    }
}

struct BotAvatarPlayback: Equatable {
    let profileID: String
    let geometry: BotAvatarGeometry
    let fallback: BotAvatarShape
    let expression: String?
    let staticPresentation: BotAvatarPresentation?
    let still: Bool

    init(profile: BotProfile, presentation: BotAvatarPresentation, still: Bool) {
        profileID = profile.id
        geometry = profile.appearance?.geometry ?? BotAvatarCatalog.geometry(for: profile.face.shape)
        fallback = profile.face.shape
        expression = profile.appearance?.expression
        staticPresentation = still ? presentation : nil
        self.still = still
    }
}

struct BotAvatarActivityCue: View {
    let shape: BotAvatarShape
    let size: CGFloat
    let activity: BotMotionActivity
    var frame = BotCharacterFrame()
    var minimumCueTop: Double? = nil
    var placement: BotAvatarContourPlacement? = nil

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
        let point = contourAnchor(corner)
        let extraClearance = (cueSize - size) * 0.36
        let topExtent = cueSize * (activity == .unavailable ? 0.33 : 0.23)
        let y = minimumCueTop.map { max(size * point.y, size * $0 + topExtent) } ?? size * point.y
        return CGPoint(x: size * point.x + corner.horizontalDirection * extraClearance, y: y)
    }

    private func contourAnchor(_ corner: BotActivityCueCorner) -> CGPoint {
        (placement ?? BotAvatarContourPlacement(shape: shape)).anchor(for: corner)
    }

    private func tool(angle: Double) -> some View {
        let anchor = contourAnchor(.bottomRight)
        let growth = cueSize - size
        let ordinaryY = size * anchor.y + cueSize * 0.015
        let y = ordinaryY
        return Image(systemName: "wrench.fill")
            .font(.system(size: cueSize * 0.28, weight: .semibold))
            .foregroundStyle(Color(white: 0.34))
            .shadow(color: BottoTheme.paper, radius: 0, x: 0, y: 1)
            .frame(width: cueSize * 0.32, height: cueSize * 0.32)
            .rotationEffect(.degrees(-20 + angle))
            // Keep the head attached when the glyph grows on small avatars.
            .offset(x: size * anchor.x - cueSize * 0.11 + growth * 0.18,
                    y: y)
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

enum BotActivityCueCorner {
    case topLeft, topRight, bottomLeft, bottomRight

    var horizontalDirection: CGFloat {
        switch self {
        case .topLeft, .bottomLeft: -1
        case .topRight, .bottomRight: 1
        }
    }

    var isTop: Bool {
        switch self {
        case .topLeft, .topRight: true
        case .bottomLeft, .bottomRight: false
        }
    }
}

/// Contour intersections come from the exact projected slices, including custom silhouettes.
struct BotAvatarContourPlacement {
    private let paths: [(Path, Bool)]
    private let center: CGPoint
    @MainActor init(shape: BotAvatarShape) {
        if let asset = BotAvatarRenderCache.shared.asset(for: BotAvatarCatalog.geometry(for: shape)) {
            self.init(asset: asset, frame: asset.source.restingFrame)
        } else {
            self.init(paths: [])
        }
    }
    init(asset: BotAvatarNativeAsset, frame: BotAvatarRenderFrame) {
        self.init(paths: asset.bodyPaths(in: frame))
    }
    private init(paths: [(Path, Bool)]) {
        self.paths = paths
        let bounds = paths.reduce(CGRect.null) { $0.union($1.0.boundingRect) }
        center = bounds.isNull ? CGPoint(x: 50, y: 50) : CGPoint(x: bounds.midX, y: bounds.midY)
    }
    func anchor(for corner: BotActivityCueCorner) -> CGPoint {
        let dx = corner.horizontalDirection
        let dy: CGFloat = corner.isTop ? -1 : 1
        var boundary = center
        // Search from outside inward so handles and disconnected details remain attached.
        for step in stride(from: 110, through: 0, by: -1) {
            let candidate = CGPoint(x: center.x + dx * CGFloat(step) / 2,
                                    y: center.y + dy * CGFloat(step) / 2)
            if paths.contains(where: { $0.0.contains(candidate, eoFill: $0.1) }) {
                boundary = candidate
                break
            }
        }
        let clearance: CGFloat = corner.isTop ? 10 : 0
        return CGPoint(x: (boundary.x - 50 + dx * clearance) / 100,
                       y: (boundary.y - 50 + dy * clearance) / 100)
    }
}

struct BotCharacterFrame {
    var roll = 0.0
    var scaleX = 1.0
    var scaleY = 1.0
    var lift = 0.0
    var toolAngle = 0.0
    var idea = 0.4
    var sleepPhase = 0.17
    var celebration = 0.0
    var turn = 0.0
    var tuck = 1.0
    var shiftX = 0.0

    static func resolve(elapsed: Double, activity: BotMotionActivity, still: Bool = false) -> Self {
        guard !still else { return Self() }
        var frame = Self()
        switch activity {
        case .failed:
            frame = sample(elapsed, [
                (0, Self()),
                (0.14, Self(scaleX: 1.11, scaleY: 1.09, lift: -0.012)),
                (0.22, Self(roll: -5, scaleX: 1.075, scaleY: 1.065, lift: -0.01, shiftX: -0.035)),
                (0.30, Self(roll: 4, scaleX: 1.06, scaleY: 1.06, shiftX: 0.035)),
                (0.38, Self(roll: -3, scaleX: 1.045, scaleY: 1.045, shiftX: -0.027)),
                (0.46, Self(roll: 2, scaleX: 1.03, scaleY: 1.03, shiftX: 0.02)),
                (0.56, Self(roll: -1, shiftX: -0.012)),
                (0.75, Self(scaleX: 1.015, scaleY: 0.985)), (1.1, Self())
            ])
        case .finished where elapsed < 1.85:
                frame = sample(elapsed, [
                    (0, Self()), (0.16, Self(roll: -6, scaleX: 1.075, scaleY: 0.925, lift: 0.025)),
                    (0.34, Self(roll: -5, scaleX: 0.98, scaleY: 1.02, lift: -0.06, celebration: 0.3, tuck: 0.92)),
                    (0.47, Self(lift: -0.115, celebration: 0.8, tuck: 0.76)),
                    (1.02, Self(lift: -0.115, celebration: 1, turn: 360, tuck: 0.76)),
                    (1.16, Self(lift: -0.045, celebration: 0.8, turn: 360, tuck: 0.92)),
                    (1.32, Self(scaleX: 1.06, scaleY: 0.94, lift: 0.025, celebration: 0.6, turn: 360)),
                    (1.5, Self(scaleX: 0.99, scaleY: 1.01, lift: -0.013, celebration: 0.3, turn: 360)),
                    (1.85, Self(turn: 360))
                ])
        case .tools: frame.toolAngle = 18 * sin(elapsed * 2 * .pi / 1.9)
        case .thinking: frame.idea = 0.5 + 0.5 * sin(elapsed * 2 * .pi / 3.4)
        case .unavailable: frame.sleepPhase = elapsed.truncatingRemainder(dividingBy: 3.6) / 3.6
        default: break
        }
        return frame
    }
    private static func sample(_ time: Double, _ keys: [(Double, Self)]) -> Self {
        guard let first = keys.first, let last = keys.last else { return Self() }
        if time <= first.0 { return first.1 }
        for index in 1..<keys.count {
            let (end, b) = keys[index], (start, a) = keys[index - 1]
            if time <= end {
                let t = (time - start) / (end - start)
                let p = t * t * (3 - 2 * t)
                func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
                return Self(roll: mix(a.roll,b.roll), scaleX: mix(a.scaleX,b.scaleX), scaleY: mix(a.scaleY,b.scaleY),
                            lift: mix(a.lift,b.lift), celebration: mix(a.celebration,b.celebration),
                            turn: mix(a.turn,b.turn), tuck: mix(a.tuck,b.tuck), shiftX: mix(a.shiftX,b.shiftX))
            }
        }
        return last.1
    }
}
