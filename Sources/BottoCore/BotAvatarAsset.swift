import CryptoKit
import Foundation

/// Avatar image bytes and their media type. No URL fetching or UIKit in BottoCore.
nonisolated public struct BotAvatarAsset: Equatable, Sendable {
    public let data: Data
    public let mimeType: String
    public init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }
}

extension BotAvatarAsset {
    public var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Byte identity, rather than image size, distinguishes our preview from a later uploaded photo.
    public func isStaticPreview(for appearance: BotAppearance?) -> Bool {
        appearance?.imageKind != "photo" && appearance?.bottoPreviewSHA256 == sha256
    }
}
