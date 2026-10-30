import Foundation
import UniformTypeIdentifiers

/// The composer and service share one per-message upload budget.
nonisolated public enum AttachmentLimits {
    public static let count = 8
    public static let fileBytes = 25 * 1024 * 1024
    public static let totalBytes = 50 * 1024 * 1024
    // LocalizedError reads this immutable text from a nonisolated context.
    nonisolated public static let message = "Use up to 8 attachments, 25 MB each and 50 MB total."

    public static func reservationBytes(dataCount: Int, filename: String, mimeType: String) -> Int {
        // Image preparation can expand compressed input. Reserve its full possible size
        // until the service reports the prepared byte count; older services keep this bound.
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        return mimeType.hasPrefix("image/") || type?.conforms(to: .image) == true ? fileBytes : dataCount
    }
}
