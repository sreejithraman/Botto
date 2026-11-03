import SwiftUI
import Observation
import BottoCore

extension BotAvatarAffine {
    var native: CGAffineTransform { .init(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

extension BotAvatarVectorPath {
    var native: Path { Path(cgPath) }
}

nonisolated struct BotAvatarNativeAsset: Sendable {
    let source: BotAvatarDrawingAsset
    let paths: [String: Path]
    let restingBounds: CGRect

    init(_ asset: BotAvatarDrawingAsset) {
        source = asset
        paths = asset.paths.mapValues(\.native)
        let bounds = asset.restingBounds
        restingBounds = CGRect(x: bounds.minX, y: bounds.minY,
                               width: bounds.maxX - bounds.minX, height: bounds.maxY - bounds.minY)
    }

    func bodyPaths(in frame: BotAvatarRenderFrame) -> [(path: Path, evenOdd: Bool)] {
        frame.shapes.compactMap { shape in
            guard case .slice(_, let identifier, let matrix) = shape,
                  let path = paths[identifier], let source = source.paths[identifier] else { return nil }
            return (path.applying(matrix.native).applying(frame.root.native), source.evenOdd)
        }
    }

    func bodyPath(in frame: BotAvatarRenderFrame) -> Path {
        var path = Path()
        for item in bodyPaths(in: frame) { path.addPath(item.path) }
        return path
    }
}

@MainActor @Observable final class BotAvatarRenderCache {
    static let shared = BotAvatarRenderCache()
    private var assets: [String: BotAvatarNativeAsset] = [:]
    @ObservationIgnored private var bundled: [String: BotAvatarNativeAsset] = [:]
    @ObservationIgnored private var order: [String] = []

    func asset(for geometry: BotAvatarGeometry) -> BotAvatarNativeAsset? {
        if let asset = assets[geometry.json] { return asset }
        if let asset = bundled[geometry.json] { return asset }
        guard let baked = BotAvatarEngine.bundledAsset(for: geometry) else { return nil }
        let asset = BotAvatarNativeAsset(baked)
        bundled[geometry.json] = asset
        return asset
    }

    @discardableResult func insert(_ source: BotAvatarDrawingAsset, for requested: BotAvatarGeometry? = nil, compiled: BotAvatarNativeAsset? = nil) -> BotAvatarNativeAsset {
        let key = requested?.json ?? source.geometry.json
        if let asset = assets[key] { return asset }
        let asset = compiled ?? BotAvatarNativeAsset(source)
        assets[key] = asset
        order.append(key)
        if order.count > 64 { assets.removeValue(forKey: order.removeFirst()) }
        return asset
    }

    func prepare(_ geometry: BotAvatarGeometry) async throws -> BotAvatarNativeAsset {
        if let cached = assets[geometry.json] { return cached }
        let source = try await BotAvatarEngine.shared.prepare(geometry)
        let compiled = await Task.detached(priority: .userInitiated) { BotAvatarNativeAsset(source) }.value
        return insert(source, for: geometry, compiled: compiled)
    }
}

enum BotAvatarEyeTreatment: Equatable { case normal, sleeping, surprised }

struct BotAvatarCanvas: View {
    let asset: BotAvatarNativeAsset
    let frame: BotAvatarRenderFrame
    let color: String
    var eyes: BotAvatarEyeTreatment = .normal
    var drawsEyes = true

    private var bodyHex: String { BotAvatarColors.presentation(color) ?? "#8b5cf6" }
    private var bodyAlpha: Double {
        bodyHex.count == 9 ? Double(UInt8(bodyHex.suffix(2), radix: 16) ?? 255) / 255 : 1
    }

    var body: some View {
        if bodyAlpha < 1 {
            ZStack {
                Color.clear
                if bodyAlpha > 0 {
                    Canvas { context, size in
                        context.scaleBy(x: size.width / 100, y: size.height / 100)
                        context.concatenate(frame.root.native)
                        for shape in frame.shapes {
                            guard case .slice(_, let identifier, let matrix) = shape,
                                  let path = asset.paths[identifier], let source = asset.source.paths[identifier] else { continue }
                            var painter = context
                            painter.concatenate(matrix.native)
                            painter.fill(path, with: .color(Color(botHex: String(bodyHex.prefix(7))) ?? .purple),
                                         style: FillStyle(eoFill: source.evenOdd))
                        }
                    }
                    .compositingGroup()
                    .opacity(bodyAlpha)
                }
                if drawsEyes {
                    Canvas { context, size in
                        context.scaleBy(x: size.width / 100, y: size.height / 100)
                        context.concatenate(frame.root.native)
                        context.drawLayer { layer in
                            for shape in frame.shapes {
                                var painter = layer
                                switch shape {
                                case .slice(_, let identifier, let matrix):
                                    guard let path = asset.paths[identifier], let source = asset.source.paths[identifier] else { continue }
                                    painter.concatenate(matrix.native)
                                    painter.blendMode = .destinationOut
                                    painter.fill(path, with: .color(.black), style: FillStyle(eoFill: source.evenOdd))
                                case .eye(_, let matrix, let mark):
                                    painter.concatenate(matrix.native)
                                    paint(mark, in: &painter)
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityHidden(true)
        } else {
            opaqueCanvas
        }
    }

    private var opaqueCanvas: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 100, y: size.height / 100)
            context.concatenate(frame.root.native)
            for shape in frame.shapes {
                var painter = context
                switch shape {
                case .slice(_, let identifier, let matrix):
                    guard let path = asset.paths[identifier], let source = asset.source.paths[identifier] else { continue }
                    painter.concatenate(matrix.native)
                    painter.fill(path, with: .color(Color.botBody(color)), style: FillStyle(eoFill: source.evenOdd))
                case .eye(_, let matrix, let mark):
                    guard drawsEyes else { continue }
                    painter.concatenate(matrix.native)
                    paint(mark, in: &painter)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func paint(_ mark: BotAvatarRenderFrame.EyeMark, in context: inout GraphicsContext) {
        let ink = GraphicsContext.Shading.color(Color.botEyes(on: color))
        switch mark {
        case .pill(let x, let y, let width, let height, let radius):
            let shownHeight = eyes == .sleeping ? max(0.8, width * 0.22) : height
            let shownWidth = eyes == .surprised ? width * 1.12 : width
            let rect = CGRect(x: x - (shownWidth - width) / 2,
                              y: y + (height - shownHeight) / 2,
                              width: shownWidth, height: shownHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: min(radius, shownHeight / 2)), with: ink)
        case .arc(let x0, let y0, let cx, let cy, let x1, let y1, let strokeWidth):
            var path = Path()
            if eyes == .sleeping {
                path.move(to: CGPoint(x: x0, y: (y0 + y1) / 2))
                path.addLine(to: CGPoint(x: x1, y: (y0 + y1) / 2))
            } else {
                path.move(to: CGPoint(x: x0, y: y0))
                path.addQuadCurve(to: CGPoint(x: x1, y: y1), control: CGPoint(x: cx, y: cy))
            }
            context.stroke(path, with: ink, style: StrokeStyle(lineWidth: eyes == .sleeping ? 1 : strokeWidth, lineCap: .round))
        }
    }
}
