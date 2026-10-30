import Foundation

/// Validated bytes from the authenticated avatar RPC. No URL fetching or UIKit in BottoCore.
nonisolated public struct BotAvatarAsset: Equatable, Sendable {
    public let data: Data
    public let mimeType: String
    public init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }

    init?(reply: HermesJSON) {
        guard reply["found"].flag == true, let text = reply["data"].text,
              text.utf8.count <= 3_000_000, let comma = text.firstIndex(of: ","),
              let mime = reply["mime"].text, ["image/png", "image/jpeg", "image/webp"].contains(mime),
              text[..<comma] == "data:\(mime);base64",
              let size = reply["size"].integer, size > 0, size <= 2_000_000,
              let data = Data(base64Encoded: String(text[text.index(after: comma)...])), data.count == size else { return nil }
        let bytes = [UInt8](data.prefix(12))
        let matches: Bool
        switch mime {
        case "image/png": matches = bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case "image/jpeg": matches = bytes.starts(with: [255, 216, 255])
        case "image/webp": matches = bytes.count == 12 && bytes.prefix(4) == Array("RIFF".utf8)[...] && bytes.suffix(4) == Array("WEBP".utf8)[...]
        default: matches = false
        }
        guard matches else { return nil }
        self.init(data: data, mimeType: mime)
    }
}
