import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A derived resting pose for clients that cannot render a shape recipe.
nonisolated enum BotAvatarStaticPreview {
    static func render(_ asset: BotAvatarDrawingAsset, color: String) throws -> BotAvatarAsset {
        let size = 512
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw BotAvatarEngineError.invalidFrame }
        let hex = BotAvatarColors.presentation(color) ?? "#8b5cf6"
        let encoded = UInt64(hex.dropFirst(), radix: 16)!
        let rgb = hex.count == 9 ? encoded >> 8 : encoded
        let alpha = hex.count == 9 ? CGFloat(encoded & 255) / 255 : 1
        let r = CGFloat((rgb >> 16) & 255) / 255, g = CGFloat((rgb >> 8) & 255) / 255, b = CGFloat(rgb & 255) / 255
        let body = CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        let dark = (0.2126 * r + 0.7152 * g + 0.0722 * b) * alpha + (250.0 / 255) * (1 - alpha) < 110.0 / 255
        let lightEyes = BotAvatarColors.preset(for: color) == nil && dark
        let ink = CGColor(gray: lightEyes ? 1 : 0, alpha: lightEyes ? 0.9 : 0.85)
        let frame = asset.restingFrame
        let bounds = asset.restingBounds
        let width = bounds.maxX - bounds.minX, height = bounds.maxY - bounds.minY
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw BotAvatarEngineError.invalidFrame }
        // Leave margin for small rounded crops without changing the character's proportions.
        let scale = Double(size) * 0.88 / max(width, height)
        context.translateBy(x: 0, y: CGFloat(size)); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: (Double(size) - width * scale) / 2, y: (Double(size) - height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.concatenate(frame.root.cgTransform)
        let paths = asset.paths.mapValues(\.cgPath)

        func slice(_ identifier: String) {
            guard let path = paths[identifier], let source = asset.paths[identifier] else { return }
            context.addPath(path)
            context.drawPath(using: source.evenOdd ? .eoFill : .fill)
        }
        func eye(_ mark: BotAvatarRenderFrame.EyeMark) {
            context.setFillColor(ink); context.setStrokeColor(ink)
            switch mark {
            case .pill(let x, let y, let width, let height, let radius):
                context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
                    cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            case .arc(let x0, let y0, let cx, let cy, let x1, let y1, let strokeWidth):
                context.move(to: CGPoint(x: x0, y: y0))
                context.addQuadCurve(to: CGPoint(x: x1, y: y1), control: CGPoint(x: cx, y: cy))
                context.setLineWidth(strokeWidth); context.setLineCap(.round); context.strokePath()
            }
        }
        if alpha < 1 {
            context.saveGState(); context.setAlpha(alpha); context.beginTransparencyLayer(auxiliaryInfo: nil)
            for shape in frame.shapes {
                guard case .slice(_, let path, let matrix) = shape else { continue }
                context.saveGState(); context.concatenate(matrix.cgTransform); context.setFillColor(body)
                slice(path); context.restoreGState()
            }
            context.endTransparencyLayer(); context.restoreGState()
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for shape in frame.shapes {
            context.saveGState()
            switch shape {
            case .slice(_, let path, let matrix):
                context.concatenate(matrix.cgTransform)
                context.setFillColor(body)
                if alpha < 1 { context.setBlendMode(.clear) }
                slice(path)
            case .eye(_, let matrix, let mark):
                context.concatenate(matrix.cgTransform); eye(mark)
            }
            context.restoreGState()
        }
        context.endTransparencyLayer()
        guard let image = context.makeImage() else { throw BotAvatarEngineError.invalidFrame }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw BotAvatarEngineError.invalidFrame
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 2_000_000 else { throw BotAvatarEngineError.invalidFrame }
        return BotAvatarAsset(data: data as Data, mimeType: "image/png")
    }
}

extension BotAvatarAffine {
    nonisolated fileprivate var cgTransform: CGAffineTransform { .init(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

extension BotAvatarAsset {
    public var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Byte identity, rather than image size, distinguishes our preview from a later uploaded photo.
    public func isStaticPreview(for appearance: BotAppearance?) -> Bool {
        appearance?.imageKind != "photo" && appearance?.bottoPreviewSHA256 == sha256
    }
}
