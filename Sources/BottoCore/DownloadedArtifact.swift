import Foundation

/// Exact host bytes and response metadata. Host paths never become local file URLs.
public struct DownloadedArtifact: Equatable, Sendable {
    public static let maximumBytes = 25 * 1024 * 1024
    public var data: Data
    public var filename: String
    public var mimeType: String

    public init(data: Data, filename: String, mimeType: String) {
        self.data = data; self.filename = filename; self.mimeType = mimeType
    }
}
