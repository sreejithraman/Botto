import Foundation

/// A Hermes `::preview` file is an opaque host path, never an iPhone file URL.
public struct PreviewFileReference: Equatable, Sendable {
    public let attachment: ChatAttachment
    public let initialHeight: Int?
    public var isHTML: Bool {
        ["html", "htm", "xhtml"].contains((attachment.path as NSString).pathExtension.lowercased())
    }

    // The desktop contract accepts quoted attributes and a bounded brace body.
    // Keep malformed directives as readable source, rather than guessing a path.
    init?(line: String) {
        // Most transcript lines are prose. Avoid constructing the regex unless
        // the line can contain the exact directive marker required below.
        guard line.contains("::preview{") else { return nil }
        guard let match = line.wholeMatch(of: /^ {0,3}::preview\{([^{}\r\n]{0,2048})\}[ \t]*$/) else { return nil }
        let body = String(match.1)
        var attributes: [String: String] = [:]
        var remaining = body[...]
        while !remaining.isEmpty {
            remaining = remaining.drop(while: { $0 == " " || $0 == "\t" })
            if remaining.isEmpty { break }
            guard let pair = remaining.prefixMatch(of: /([A-Za-z][A-Za-z0-9_-]{0,63})=(?:"([^"\r\n]*)"|'([^'\r\n]*)')/) else { return nil }
            attributes[String(pair.1).lowercased()] = String(pair.2 ?? pair.3 ?? "")
            remaining = remaining[pair.range.upperBound...]
        }
        guard let raw = attributes["file"],
              let path = ArtifactReferences.localPath(raw, relative: true, bareRelative: true) else { return nil }
        attachment = ArtifactReferences.attachment(path: path)
        initialHeight = attributes["height"].flatMap(Int.init).map { min(1200, max(120, $0)) }
    }
}
