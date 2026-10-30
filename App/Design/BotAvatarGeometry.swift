// Adapted from Hermex; eye geometry from Bloub. MIT; see LICENSES/Hermex.txt and LICENSES/Bloub.txt.
import SwiftUI
import BottoCore

struct BotAvatarLayout {
    let size: CGFloat
    let bodyBounds: CGRect

    init(shape: BotAvatarShape, size: CGFloat, imageSize: CGSize? = nil) {
        self.size = size
        if let imageSize, imageSize.width > 0, imageSize.height > 0 {
            let scale = min(size / imageSize.width, size / imageSize.height)
            let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            bodyBounds = CGRect(x: (size - fitted.width) / 2, y: (size - fitted.height) / 2,
                                width: fitted.width, height: fitted.height)
        } else {
            bodyBounds = BotAvatarBody(shape: shape)
                .path(in: CGRect(x: 0, y: 0, width: size, height: size)).cgPath.boundingBoxOfPath
        }
    }

    var fittedHeight: CGFloat { bodyBounds.height }
    var fittedVerticalOffset: CGFloat { size / 2 - bodyBounds.midY }
}

enum BotAvatarExpression: String, CaseIterable, Identifiable, Sendable {
    case neutral, attentive, surprised, excited, happy, laughing, angry, sad
    case scared, wary, confused, curious, proud, shy, bored, sleepy
    var id: String { rawValue }

    struct Eye: Equatable { let width: Double; let height: Double; let tilt: Double }
    struct Geometry: Equatable { let left: Eye; let right: Eye; let split: Double }

    /// An unknown or missing stored value reads as neutral rather than failing the row.
    static func resolve(_ raw: String?) -> BotAvatarExpression { raw.flatMap(BotAvatarExpression.init(rawValue:)) ?? .neutral }

    var geometry: Geometry {
        func pair(_ w: Double, _ h: Double, _ tilt: Double = 0, split: Double) -> Geometry {
            Geometry(left: Eye(width: w, height: h, tilt: tilt), right: Eye(width: w, height: h, tilt: -tilt), split: split)
        }
        switch self {
        case .neutral: return pair(0.186, 0.412, split: 15.46)
        case .attentive: return pair(0.21, 0.44, split: 16)
        case .surprised: return pair(0.45, 0.47, split: 19)
        case .excited: return pair(0.4, 0.56, -10, split: 19.5)
        case .happy: return pair(0.27, 0.17, 14, split: 17)
        case .laughing: return pair(0.34, 0.13, 20, split: 18)
        case .angry: return pair(0.34, 0.15, 30, split: 17)
        case .sad: return pair(0.22, 0.4, -28, split: 16)
        case .scared: return pair(0.4, 0.6, split: 20.5)
        case .wary: return Geometry(left: Eye(width: 0.21, height: 0.4, tilt: 0), right: Eye(width: 0.22, height: 0.15, tilt: 0), split: 16)
        case .confused: return Geometry(left: Eye(width: 0.2, height: 0.44, tilt: -18), right: Eye(width: 0.28, height: 0.17, tilt: 14), split: 16.5)
        case .curious: return Geometry(left: Eye(width: 0.24, height: 0.46, tilt: -8), right: Eye(width: 0.2, height: 0.38, tilt: -8), split: 16.5)
        case .proud: return pair(0.3, 0.15, 18, split: 17)
        case .shy: return pair(0.17, 0.3, split: 14)
        case .bored: return pair(0.3, 0.12, split: 16)
        case .sleepy: return pair(0.2, 0.42 * 0.42, split: 16)
        }
    }

}

/// Face anchors in mark coordinates, with room for the full rotated capsules
/// throughout the working gaze. Body contours and shared expressions stay exact.
struct BotAvatarFacePlacement {
    var x = 0.12
    var y = -0.08
    var scale = 1.0

    init(shape: BotAvatarShape, geometry: BotAvatarExpression.Geometry) {
        switch shape {
        case .triangle:
            // Below the midpoint, the triangle has room for even the widest pair.
            x = 0.025
            y = 0.14
            scale = 0.75
        case .cloud:
            x = 0.08
            y = 0.04
        case .drop:
            x = 0.06
            y = 0
        case .pill:
            // Only the tall expressions approach the pill's curved upper edge.
            if max(geometry.left.height, geometry.right.height) > 0.44 { y = -0.04 }
        case .sun:
            x = 0.04
            y = 0
            scale = 0.8
        case .nub:
            x = 0.08
            y = -0.04
            scale = 0.9
        case .circle, .blob, .squircle, .hexagon:
            break
        }
    }
}

struct BotAvatarBody: Shape {
    let shape: BotAvatarShape

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
        switch shape {
        case .sun:
            var path = Path(ellipseIn: CGRect(x: rect.minX + rect.width * 0.17,
                                              y: rect.minY + rect.height * 0.17,
                                              width: rect.width * 0.66, height: rect.height * 0.66))
            for index in 0..<8 {
                let angle = Double(index) * .pi / 4
                let center = CGPoint(x: rect.midX + rect.width * 0.32 * cos(angle),
                                     y: rect.midY + rect.height * 0.32 * sin(angle))
                path.addEllipse(in: CGRect(x: center.x - rect.width * 0.10,
                                          y: center.y - rect.height * 0.10,
                                          width: rect.width * 0.20, height: rect.height * 0.20))
            }
            return path
        case .nub:
            var path = Path(ellipseIn: CGRect(x: rect.minX + rect.width * 0.12,
                                              y: rect.minY + rect.height * 0.16,
                                              width: rect.width * 0.76, height: rect.height * 0.76))
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.05,
                                       width: rect.width * 0.32, height: rect.height * 0.32))
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.68, y: rect.minY + rect.height * 0.17,
                                       width: rect.width * 0.25, height: rect.height * 0.25))
            return path
        case .circle:
            return Path(ellipseIn: inset)
        case .squircle:
            return Path(roundedRect: inset, cornerRadius: rect.width * 0.28)
        case .pill:
            let pill = CGRect(x: inset.minX, y: rect.midY - rect.height * 0.27,
                              width: inset.width, height: rect.height * 0.54)
            return Path(roundedRect: pill, cornerRadius: pill.height / 2)
        case .triangle:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: inset.minY))
            path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
            path.closeSubpath()
            return path
        case .hexagon:
            var path = Path()
            let points = [
                CGPoint(x: rect.midX, y: inset.minY), CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.3),
                CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.7), CGPoint(x: rect.midX, y: inset.maxY),
                CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.7), CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.3)
            ]
            path.move(to: points[0]); for point in points.dropFirst() { path.addLine(to: point) }; path.closeSubpath()
            return path
        case .cloud:
            var path = Path()
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.38,
                                       width: rect.width * 0.48, height: rect.height * 0.48))
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.12,
                                       width: rect.width * 0.5, height: rect.height * 0.64))
            path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.55, y: rect.minY + rect.height * 0.35,
                                       width: rect.width * 0.38, height: rect.height * 0.45))
            return path
        case .drop:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: inset.minY))
            path.addCurve(to: CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.62),
                          control1: CGPoint(x: rect.midX + rect.width * 0.22, y: rect.minY + rect.height * 0.2),
                          control2: CGPoint(x: inset.maxX, y: rect.minY + rect.height * 0.42))
            path.addCurve(to: CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.62),
                          control1: CGPoint(x: inset.maxX, y: inset.maxY), control2: CGPoint(x: inset.minX, y: inset.maxY))
            path.addCurve(to: CGPoint(x: rect.midX, y: inset.minY),
                          control1: CGPoint(x: inset.minX, y: rect.minY + rect.height * 0.42),
                          control2: CGPoint(x: rect.midX - rect.width * 0.22, y: rect.minY + rect.height * 0.2))
            return path
        case .blob:
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.17))
            path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.2),
                          control1: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY),
                          control2: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.02))
            path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.86),
                          control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.4),
                          control2: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.72))
            path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.78),
                          control1: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.maxY),
                          control2: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY))
            path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.17),
                          control1: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.6),
                          control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.3))
            return path
        }
    }
}
