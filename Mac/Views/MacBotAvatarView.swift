import BottoCore
import SwiftUI

/// What the bot is doing right now, as its drawn face shows it.
enum MacAvatarActivity: Equatable {
    case idle, thinking, working, tools, replying, waiting
    /// The local engine is off: eyes closed, a slow breath, no work cues.
    case sleeping

    init(status: BotStatus, phase: ConversationWorkPhase? = nil, needsResponse: Bool = false) {
        if needsResponse || status == .waiting {
            self = .waiting
            return
        }
        switch phase {
        case .thinking: self = .thinking
        case .tools: self = .tools
        case .replying: self = .replying
        case .working: self = .working
        case nil: self = status == .working ? .working : .idle
        }
    }

    var label: String? {
        switch self {
        case .idle: nil
        case .thinking: "Thinking…"
        case .working: "Working…"
        case .tools: "Using tools…"
        case .replying: "Replying…"
        case .waiting: "Needs you"
        case .sleeping: "Asleep"
        }
    }

    /// The quiet line under a space's name, in place of status pills.
    var cue: String? {
        switch self {
        case .idle: nil
        case .thinking: "thinking…"
        case .working: "working…"
        case .tools: "using tools…"
        case .replying: "replying…"
        case .waiting: "waiting on you"
        case .sleeping: "asleep"
        }
    }

    var isBusy: Bool { self != .idle && self != .waiting && self != .sleeping }
}

struct MacBotAvatarView: View {
    let profileID: String
    let appearance: BotAppearance?
    var activity: MacAvatarActivity = .idle
    /// Small repeated avatars (transcript rows) stay still to keep the eye on the live one.
    var animated = true
    @State private var prepared: BotAvatarDrawingAsset?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    private var geometry: BotAvatarGeometry {
        appearance?.geometry ?? BotAvatarCatalog.geometry(for: (appearance ?? BotAppearance()).face(for: profileID).shape)
    }

    private var still: Bool { !animated || reduceMotion || controlActiveState == .inactive }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { timeline in
            let motion = MacAvatarMotion(time: still ? 0 : timeline.date.timeIntervalSinceReferenceDate,
                                         activity: activity, profileID: profileID)
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                ZStack {
                    if activity.isBusy {
                        Circle()
                            .fill(MacTheme.action.opacity(0.10 + 0.10 * motion.pulse))
                            .scaleEffect(0.86 + 0.16 * motion.pulse)
                            .blur(radius: side * 0.06)
                    }
                    face(blink: activity == .sleeping ? 0.9 : motion.blink)
                        .scaleEffect(x: 1 + motion.squash * 0.5, y: 1 - motion.squash, anchor: .bottom)
                        .rotationEffect(.degrees(motion.tilt))
                        .offset(y: -side * motion.lift)
                    cue(side: side, motion: motion)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .task(id: geometry.json) {
            let geometry = geometry
            guard BotAvatarEngine.bundledAsset(for: geometry) == nil else { return }
            if let drawing = try? await BotAvatarEngine.shared.prepare(geometry), !Task.isCancelled {
                prepared = drawing
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cue(side: CGFloat, motion: MacAvatarMotion) -> some View {
        let bubble = max(12, side * 0.32)
        switch activity {
        case .waiting:
            Image(systemName: "questionmark")
                .font(.system(size: bubble * 0.55, weight: .heavy, design: .rounded))
                .foregroundStyle(MacTheme.onAction)
                .frame(width: bubble, height: bubble)
                .background(MacTheme.action, in: .circle)
                .overlay { Circle().stroke(MacTheme.paper, lineWidth: max(1.5, side * 0.025)) }
                .rotationEffect(.degrees(8 * sin(motion.phase * 1.6)))
                .offset(x: side * 0.36, y: -side * 0.36)
        case .tools:
            Image(systemName: "wrench.adjustable.fill")
                .font(.system(size: bubble * 0.62, weight: .semibold))
                .foregroundStyle(MacTheme.action)
                .shadow(color: MacTheme.paper, radius: 0, x: 0, y: 1)
                .rotationEffect(.degrees(-20 + 22 * sin(motion.phase * 3.3)), anchor: .bottomLeading)
                .offset(x: side * 0.38, y: -side * 0.3)
        case .thinking:
            Image(systemName: "lightbulb.fill")
                .font(.system(size: bubble * 0.6, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.82, blue: 0.24))
                .shadow(color: .orange.opacity(0.25 + 0.35 * motion.pulse), radius: side * 0.06)
                .scaleEffect(0.9 + 0.14 * motion.pulse)
                .offset(x: -side * 0.36, y: -side * 0.36)
        case .working, .replying:
            HStack(spacing: max(1.5, side * 0.035)) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(MacTheme.action)
                        .frame(width: max(3, side * 0.07), height: max(3, side * 0.07))
                        .opacity(0.35 + 0.65 * max(0, sin(motion.phase * 4 - Double(index) * 0.9)))
                }
            }
            .padding(.horizontal, max(3, side * 0.06))
            .padding(.vertical, max(2, side * 0.045))
            .background(MacTheme.paper, in: .capsule)
            .overlay { Capsule().stroke(MacTheme.action.opacity(0.35), lineWidth: 1) }
            .offset(x: side * 0.34, y: -side * 0.36)
        case .sleeping:
            Text("z")
                .font(.system(size: bubble * 0.6, weight: .heavy, design: .rounded))
                .foregroundStyle(.secondary)
                .opacity(0.45 + 0.4 * motion.pulse)
                .offset(x: side * 0.36, y: -side * (0.32 + 0.04 * motion.pulse))
        case .idle:
            EmptyView()
        }
    }

    private func face(blink: Double) -> some View {
        let face = (appearance ?? BotAppearance()).face(for: profileID)
        let fallback = BotAvatarCatalog.geometry(for: face.shape)
        let geometry = appearance?.geometry ?? fallback
        let asset = BotAvatarEngine.bundledAsset(for: geometry) ??
            (prepared?.geometry == geometry ? prepared : nil) ?? BotAvatarEngine.bundledAsset(for: fallback)
        return Canvas { context, size in
            guard let asset else { return }
            let hex = BotAvatarColors.presentation(face.color) ?? "#8b5cf6"
            let rgb = UInt32(hex.dropFirst().prefix(6), radix: 16) ?? 0x8b5cf6
            let red = Double(rgb >> 16) / 255
            let green = Double((rgb >> 8) & 255) / 255
            let blue = Double(rgb & 255) / 255
            let alpha = hex.count == 9 ? Double(UInt8(hex.suffix(2), radix: 16) ?? 255) / 255 : 1
            let fill = Color(red: red, green: green, blue: blue)
            let luminance = (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha + 0.98 * (1 - alpha)
            let lightEyes = BotAvatarColors.preset(for: face.color) == nil && luminance < 0.43
            let ink = GraphicsContext.Shading.color(lightEyes ? .white.opacity(0.9) : .black.opacity(0.85))

            let bounds = asset.restingBounds
            let width = bounds.maxX - bounds.minX
            let height = bounds.maxY - bounds.minY
            guard width > 0, height > 0 else { return }
            let scale = min(size.width, size.height) * 0.88 / max(width, height)
            var drawing = context
            drawing.translateBy(x: (size.width - width * scale) / 2, y: (size.height - height * scale) / 2)
            drawing.scaleBy(x: scale, y: scale)
            drawing.translateBy(x: -bounds.minX, y: -bounds.minY)
            drawing.concatenate(asset.restingFrame.root.transform)

            if alpha < 1 {
                var bodyLayer = drawing
                bodyLayer.opacity = alpha
                bodyLayer.drawLayer { layer in
                    for shape in asset.restingFrame.shapes {
                        guard case let .slice(_, id, matrix) = shape, let vector = asset.paths[id] else { continue }
                        var painter = layer
                        painter.concatenate(matrix.transform)
                        painter.fill(Path(vector.cgPath), with: .color(fill), style: FillStyle(eoFill: vector.evenOdd))
                    }
                }
            }
            drawing.drawLayer { layer in
                for shape in asset.restingFrame.shapes {
                    var painter = layer
                    switch shape {
                    case let .slice(_, id, matrix):
                        guard let vector = asset.paths[id] else { continue }
                        painter.concatenate(matrix.transform)
                        if alpha < 1 { painter.blendMode = .destinationOut }
                        painter.fill(Path(vector.cgPath), with: .color(fill), style: FillStyle(eoFill: vector.evenOdd))
                    case let .eye(_, matrix, mark):
                        painter.concatenate(matrix.transform)
                        switch mark {
                        case let .pill(x, y, width, height, radius):
                            let closed = max(0.12, 1 - blink)
                            let rect = CGRect(x: x, y: y + height * (1 - closed) / 2, width: width, height: height * closed)
                            painter.fill(Path(roundedRect: rect, cornerRadius: min(radius, rect.height / 2)), with: ink)
                        case let .arc(x0, y0, cx, cy, x1, y1, strokeWidth):
                            var path = Path()
                            path.move(to: CGPoint(x: x0, y: y0))
                            path.addQuadCurve(to: CGPoint(x: x1, y: y1), control: CGPoint(x: cx, y: cy))
                            painter.stroke(path, with: ink, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                        }
                    }
                }
            }
        }
    }
}

/// Small procedural motion: breathing and blinks at rest, a lively bob while working.
struct MacAvatarMotion {
    var phase = 0.0
    var lift = 0.0
    var squash = 0.0
    var tilt = 0.0
    var blink = 0.0
    var pulse = 0.0

    init(time: Double, activity: MacAvatarActivity, profileID: String) {
        guard time > 0 else { return }
        // Offset each bot so several faces never blink in unison.
        let seed = Double(profileID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 }) / 997
        phase = time + seed * 10
        pulse = 0.5 + 0.5 * sin(phase * 2.4)
        let cycle = (phase / 4.3).truncatingRemainder(dividingBy: 1)
        blink = cycle < 0.035 ? sin(cycle / 0.035 * .pi) : 0
        switch activity {
        case .idle:
            squash = 0.012 * sin(phase * 1.5)
        case .sleeping:
            pulse = 0.5 + 0.5 * sin(phase * 0.8)
            squash = 0.02 * sin(phase * 0.8)
            blink = 0
        case .waiting:
            squash = 0.01 * sin(phase * 1.5)
            tilt = 5 * sin(phase * 0.9)
        case .thinking:
            lift = 0.015 + 0.015 * sin(phase * 1.3)
            tilt = -4 + 2 * sin(phase * 0.8)
        case .working, .tools:
            let hop = abs(sin(phase * 3.1))
            lift = 0.045 * hop
            squash = 0.035 * max(0, 0.25 - hop)
        case .replying:
            lift = 0.02 * abs(sin(phase * 4.2))
            tilt = 2.5 * sin(phase * 2.1)
        }
    }
}

private extension BotAvatarAffine {
    var transform: CGAffineTransform { .init(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}
