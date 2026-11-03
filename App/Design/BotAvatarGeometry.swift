import SwiftUI
import BottoCore

@MainActor struct BotAvatarLayout {
    let size: CGFloat
    let bodyBounds: CGRect

    init(shape: BotAvatarShape, size: CGFloat, imageSize: CGSize? = nil, geometry: BotAvatarGeometry? = nil) {
        self.size = size
        if let imageSize, imageSize.width > 0, imageSize.height > 0 {
            let scale = min(size / imageSize.width, size / imageSize.height)
            let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            bodyBounds = CGRect(x: (size - fitted.width) / 2, y: (size - fitted.height) / 2,
                                width: fitted.width, height: fitted.height)
        } else {
            let fallback = BotAvatarCatalog.geometry(for: shape)
            let asset = BotAvatarRenderCache.shared.asset(for: geometry ?? fallback)
                ?? BotAvatarRenderCache.shared.asset(for: fallback)
            bodyBounds = (asset?.restingBounds ?? CGRect(x: 8, y: 8, width: 84, height: 84))
                .applying(CGAffineTransform(scaleX: size / 100, y: size / 100))
        }
    }
    var fittedHeight: CGFloat { bodyBounds.height }
    var fittedVerticalOffset: CGFloat { size / 2 - bodyBounds.midY }
}

enum BotAvatarExpression: String, CaseIterable, Identifiable, Sendable {
    case neutral, attentive, surprised, excited, happy, laughing, angry, sad
    case scared, wary, confused, curious, proud, shy, bored, sleepy
    var id: String { rawValue }
    static func resolve(_ raw: String?) -> Self { raw.flatMap(Self.init(rawValue:)) ?? .neutral }

    /// Stored expressions remain editable; the reference engine owns their three compatible moods.
    var motion: BotAvatarFrameOptions.Motion {
        switch self {
        case .excited, .happy, .laughing, .proud: .happy
        case .attentive, .wary, .confused, .curious: .thinking
        default: .idle
        }
    }
}

/// Static masks use the same projected resting slices as the live native painter.
struct BotAvatarBody: Shape {
    private let canonicalPath: Path
    @MainActor init(shape: BotAvatarShape, geometry: BotAvatarGeometry? = nil) {
        let fallback = BotAvatarCatalog.geometry(for: shape)
        let asset = BotAvatarRenderCache.shared.asset(for: geometry ?? fallback)
            ?? BotAvatarRenderCache.shared.asset(for: fallback)
        canonicalPath = asset.map { $0.bodyPath(in: $0.source.restingFrame) } ?? Path()
    }
    func path(in rect: CGRect) -> Path {
        canonicalPath.applying(CGAffineTransform(a: rect.width / 100, b: 0, c: 0,
                                                d: rect.height / 100, tx: rect.minX, ty: rect.minY))
    }
}
