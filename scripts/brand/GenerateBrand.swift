// Uses avatar geometry adapted from Hermex and Bloub. MIT; see LICENSES/.
import AppKit
import SwiftUI
import BottoCore

@main
struct GenerateBrand {
    struct Fill {
        let path: CGPath
        let hex: String
        var opacity: CGFloat = 1
    }

    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let side = 1024
        let background = try surfaceColor(root: root)
        var fills = [Fill(path: CGPath(rect: CGRect(x: 0, y: 0, width: side, height: side), transform: nil), hex: background)]
        for avatar in BottoBrand.iconAvatars {
            let frame = avatar.iconFrame
            let transform = CGAffineTransform(scaleX: 4, y: 4)
                .translatedBy(x: frame.midX, y: frame.midY)
                .rotated(by: avatar.iconRoll * .pi / 180)
                .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
                .scaledBy(x: frame.width / 100, y: frame.height / 100)
            fills.append(Fill(path: transformed(BotAvatarBody(shape: avatar.shape)
                .path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).cgPath, by: transform), hex: avatar.face.color))

            let geometry = BotAvatarExpression.neutral.geometry
            let placement = BotAvatarFacePlacement(shape: avatar.shape, geometry: geometry)
            let faceTransform = transform
                .translatedBy(x: 50 + placement.x * 100, y: 50 + placement.y * 100)
                .scaledBy(x: placement.scale, y: placement.scale)
            let eyes = [geometry.left, geometry.right]
            let widths = eyes.map { 7.5 * $0.width / 0.186 }
            let gap = 10 * geometry.split / 15.46
            for (index, eye) in eyes.enumerated() {
                let width = widths[index]
                let height = 22 * eye.height / 0.412
                let center = index == 0 ? -(gap + widths[1]) / 2 : (gap + widths[0]) / 2
                let eyeTransform = faceTransform.translatedBy(x: center, y: 0)
                    .rotated(by: (-18 + eye.tilt) * .pi / 180)
                let capsule = Capsule().path(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
                fills.append(Fill(path: transformed(capsule.cgPath, by: eyeTransform), hex: "#000000", opacity: 0.85))
            }
        }

        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        var paths: [String] = []
        for fill in fills {
            let hex = UInt32(fill.hex.dropFirst(), radix: 16)!
            context.setFillColor(CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                                        green: CGFloat((hex >> 8) & 255) / 255,
                                        blue: CGFloat(hex & 255) / 255, alpha: fill.opacity))
            context.addPath(fill.path)
            context.fillPath()
            paths.append("  <path d=\"\(svgPath(fill.path))\" fill=\"\(fill.hex)\" fill-opacity=\"\(number(fill.opacity))\"/>")
        }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
          <!-- Generated from Botto's avatar geometry. Hermex and Bloub MIT notices: LICENSES/. -->
        \(paths.joined(separator: "\n"))
        </svg>

        """
        let assets = root.appendingPathComponent("App/Resources/Assets.xcassets")
        try svg.write(to: assets.appendingPathComponent("BottoMark.imageset/BottoMark.svg"), atomically: true, encoding: .utf8)
        let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(to: assets.appendingPathComponent("AppIcon.appiconset/AppIcon.png"), options: .atomic)
        print("Generated BottoMark.svg and opaque 1024×1024 AppIcon.png from the shared brand trio")
    }

    static func surfaceColor(root: URL) throws -> String {
        struct Asset: Decodable {
            struct Entry: Decodable {
                struct Appearance: Decodable { let appearance: String; let value: String }
                struct Color: Decodable { let components: [String: String] }
                let appearances: [Appearance]?
                let color: Color
            }
            let colors: [Entry]
        }
        let url = root.appendingPathComponent("App/Resources/Assets.xcassets/BottoSurface.colorset/Contents.json")
        let asset = try JSONDecoder().decode(Asset.self, from: Data(contentsOf: url))
        let entry = asset.colors.first { entry in
            let appearances = entry.appearances ?? []
            return appearances.count == 1 && appearances[0].appearance == "luminosity" && appearances[0].value == "dark"
        }!
        return "#" + ["red", "green", "blue"].map {
            String(format: "%02x", Int((Double(entry.color.components[$0]!)! * 255).rounded()))
        }.joined()
    }

    static func transformed(_ path: CGPath, by transform: CGAffineTransform) -> CGPath {
        var transform = transform
        return path.copy(using: &transform)!
    }

    static func number(_ value: CGFloat) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    static func svgPath(_ path: CGPath) -> String {
        var segments: [String] = []
        func point(_ p: CGPoint) -> String { "\(number(p.x)) \(number(p.y))" }
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            switch e.type {
            case .moveToPoint: segments.append("M\(point(e.points[0]))")
            case .addLineToPoint: segments.append("L\(point(e.points[0]))")
            case .addQuadCurveToPoint: segments.append("Q\(point(e.points[0])) \(point(e.points[1]))")
            case .addCurveToPoint: segments.append("C\(point(e.points[0])) \(point(e.points[1])) \(point(e.points[2]))")
            case .closeSubpath: segments.append("Z")
            @unknown default: fatalError("Unsupported avatar path segment")
            }
        }
        return segments.joined(separator: " ")
    }
}
