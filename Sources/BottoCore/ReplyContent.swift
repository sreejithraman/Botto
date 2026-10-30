import Foundation

/// An ordered projection of an assistant reply. Canonical text is never rewritten.
/// Contiguous Markdown stays native; explicit closed fences and file directives preview.
public struct ReplyContent: Equatable, Sendable {
    public enum Format: String, Equatable, Sendable { case html, svg, mermaid }

    /// Preview budgets count UTF-8 bytes, not characters. Larger fences remain code.
    public static func previewByteLimit(for format: Format) -> Int {
        format == .mermaid ? 16_384 : 131_072
    }

    public struct Block: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case text
            case code(language: String?)
            case preview(Format)
            case filePreview(PreviewFileReference)
        }

        /// UTF-8 offset in this message, stable when more streaming text is appended.
        /// Scope ForEach to one message; different messages may have the same offsets.
        public let id: Int
        public let kind: Kind
        /// Markdown or fence contents, excluding the fence delimiters.
        public let source: String
        /// Exact input slice, including delimiters and line endings. Joining all slices
        /// recovers canonicalText, including incomplete and oversized fences.
        public let rawText: String
        public let isComplete: Bool

        public var previewFormat: Format? {
            if case .preview(let format) = kind { return format }
            return nil
        }

        public var filePreview: PreviewFileReference? {
            if case .filePreview(let reference) = kind { return reference }
            return nil
        }

        /// Only downloaded UTF-8 HTML may cross from a host file into the renderer.
        public func resolvingFile(_ artifact: DownloadedArtifact) -> Block? {
            guard filePreview?.isHTML == true, isComplete,
                  !artifact.data.isEmpty, artifact.data.count <= ReplyContent.previewByteLimit(for: .html),
                  let html = String(data: artifact.data, encoding: .utf8), !html.contains("\0") else { return nil }
            return Block(id: id, kind: .preview(.html), source: html, rawText: rawText, isComplete: true)
        }
    }

    public let canonicalText: String
    public let blocks: [Block]

    /// Use this entry point when the caller has a message. Other roles remain text.
    public init(message: ChatMessage, isStreaming: Bool = false, filePreviewsAreSettled: Bool? = nil) {
        canonicalText = message.text
        if message.role == .assistant {
            blocks = Self.parse(message.text, isStreaming: isStreaming, filesSettled: filePreviewsAreSettled ?? !isStreaming)
        } else {
            blocks = message.text.isEmpty ? [] : [Block(id: 0, kind: .text,
                source: message.text, rawText: message.text, isComplete: true)]
        }
    }

    /// For already-projected assistant text only. Never use for user/tool/system text.
    public init(assistantText: String, isStreaming: Bool = false) {
        canonicalText = assistantText
        blocks = Self.parse(assistantText, isStreaming: isStreaming, filesSettled: !isStreaming)
    }

    /// A short, read-only inbox projection, including for previews without a
    /// known message role. Parsing here never grants permission to render content.
    public static func summary(_ text: String) -> String {
        let blocks = parse(text, isStreaming: false, filesSettled: true)
        let source = blocks.map { $0.filePreview == nil ? $0.rawText : "\n\n" }.joined()
        var hasCode = false
        if let parsed = try? AttributedString(markdown: source) {
            // HTML runs can combine tags and leave script/style contents as
            // ordinary text. Use a content label for any raw HTML document.
            if parsed.runs.contains(where: {
                $0.inlinePresentationIntent?.contains(.blockHTML) == true
                    || $0.inlinePresentationIntent?.contains(.inlineHTML) == true
            }) { return "Shared a preview" }
            var paragraphID: Int?
            var previousLocalLink: URL?
            var plain = ""
            for run in parsed.runs {
                let intent = run.presentationIntent?.components
                if run.inlinePresentationIntent?.contains(.code) == true
                    || intent?.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) == true {
                    hasCode = true
                    continue
                }
                let value = String(parsed[run.range].characters)
                guard !value.isEmpty else { continue }
                let identity = intent?.first?.identity
                if !plain.isEmpty && identity != paragraphID { break }
                paragraphID = identity
                if let link = run.link, let path = ArtifactReferences.localPath(link.absoluteString, relative: true) {
                    if previousLocalLink != link { plain += ArtifactReferences.attachment(path: path).name }
                    previousLocalLink = link
                } else {
                    plain += value
                    previousLocalLink = nil
                }
            }
            // Quoted, escaped, or incomplete examples stay non-executable, but
            // their directive and host path do not belong in an inbox label.
            if plain.contains("::preview{") { return "Shared a file" }
            // Reference projection expects prose without fences. Run it after
            // Markdown has excluded code, rather than flattening the document first.
            let prose = ArtifactReferences.segments(in: plain).map { segment in
                switch segment {
                case .text(let text): text
                case .attachment(let attachment): attachment.name
                }
            }.joined()
            let collapsed = prose.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !collapsed.isEmpty {
                return collapsed.count > 160 ? String(collapsed.prefix(159)).trimmingCharacters(in: .whitespaces) + "…" : collapsed
            }
        }
        guard let first = blocks.first(where: { $0.kind != .text }) else {
            return hasCode ? "Shared code" : ""
        }
        switch first.kind {
        case .preview: return "Shared a preview"
        case .filePreview: return "Shared a file"
        case .code: return "Shared code"
        case .text: return ""
        }
    }

    private struct Fence {
        let marker: UInt8
        let count: Int
        let language: String?
    }

    private static func parse(_ text: String, isStreaming: Bool, filesSettled: Bool) -> [Block] {
        let bytes = Array(text.utf8)
        var result: [Block] = []
        var offset = 0
        var textStart = 0
        let code = codeRegions(in: text)
        var opened: (fence: Fence, start: Int, contentStart: Int)?
        func string(_ start: Int, _ end: Int) -> String {
            String(decoding: bytes[start..<end], as: UTF8.self)
        }
        func appendText(through end: Int) {
            guard end > textStart else { return }
            let value = string(textStart, end)
            result.append(Block(id: textStart, kind: .text, source: value,
                rawText: value, isComplete: true))
        }
        while offset < bytes.count {
            let lineStart = offset
            while offset < bytes.count && bytes[offset] != 10 && bytes[offset] != 13 { offset += 1 }
            let lineEnd = offset
            if offset < bytes.count {
                if bytes[offset] == 13 && offset + 1 < bytes.count && bytes[offset + 1] == 10 { offset += 1 }
                offset += 1
            }
            let line = bytes[lineStart..<lineEnd]
            let markerOffset = lineStart + line.prefix(while: { $0 == 32 }).count
            if let current = opened {
                if closes(line, fence: current.fence) && (!isStreaming || offset > lineEnd) {
                    let source = string(current.contentStart, lineStart)
                    let language = current.fence.language
                    let format = language.flatMap { $0 == "htm" ? .html : Format(rawValue: $0) }
                        .flatMap { source.utf8.count <= previewByteLimit(for: $0) ? $0 : nil }
                    result.append(Block(id: current.start,
                        kind: format.map { .preview($0) } ?? .code(language: language),
                        source: source, rawText: string(current.start, offset), isComplete: true))
                    opened = nil
                    textStart = offset
                }
            } else if !code.fences.contains(where: { $0.contains(markerOffset) }), let fence = opens(line) {
                appendText(through: lineStart)
                opened = (fence, lineStart, offset)
            } else if !code.directives.contains(where: { $0.contains(markerOffset) }),
                      let reference = PreviewFileReference(line: string(lineStart, lineEnd)) {
                appendText(through: lineStart)
                result.append(Block(id: lineStart, kind: .filePreview(reference),
                                    source: string(lineStart, lineEnd), rawText: string(lineStart, offset),
                                    isComplete: filesSettled))
                textStart = offset
            }
        }
        if let current = opened {
            result.append(Block(id: current.start, kind: .code(language: current.fence.language),
                source: string(current.contentStart, bytes.count),
                rawText: string(current.start, bytes.count), isComplete: false))
        } else {
            appendText(through: bytes.count)
        }
        return result
    }

    private struct CodeRegions {
        var directives: [Range<Int>] = []
        var fences: [Range<Int>] = []
    }

    private static func codeRegions(in text: String) -> CodeRegions {
        guard text.contains("::preview{") else { return CodeRegions() }
        // Foundation owns inline and nested block-code grammar. Source positions
        // preserve wire bytes, including Markdown list indentation and CRLF.
        guard let parsed = try? AttributedString(markdown: text,
            options: .init(appliesSourcePositionAttributes: true)) else {
            return CodeRegions(directives: [0..<text.utf8.count])
        }
        var result = CodeRegions()
        for run in parsed.runs {
            let inlineCode = run.inlinePresentationIntent?.contains(.code) == true
            let blockCode = run.presentationIntent?.components.contains {
                if case .codeBlock = $0.kind { true } else { false }
            } == true
            guard inlineCode || blockCode,
                  let position = run.markdownSourcePosition,
                  let range = Range(position, in: text) else { continue }
            let lower = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
            let upper = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
            result.directives.append(lower..<upper)
            // A nested fence closer cannot open a new top-level fence. Preserve
            // top-level rich fences; Foundation owns nesting and inline examples.
            if inlineCode || (blockCode && (run.presentationIntent?.components.count ?? 0) > 1) {
                result.fences.append(lower..<upper)
            }
        }
        return result
    }

    private static func unindented(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        let spaces = line.prefix(while: { $0 == 32 }).count
        guard spaces <= 3 else { return nil }
        return line.dropFirst(spaces)
    }

    private static func opens(_ line: ArraySlice<UInt8>) -> Fence? {
        guard let line = unindented(line), let marker = line.first,
              marker == 96 || marker == 126 else { return nil }
        let count = line.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = line.dropFirst(count)
        guard marker != 96 || !info.contains(96) else { return nil }
        let language = String(decoding: info, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace }).first.map { $0.lowercased() }
        return Fence(marker: marker, count: count, language: language)
    }

    private static func closes(_ line: ArraySlice<UInt8>, fence: Fence) -> Bool {
        guard let line = unindented(line) else { return false }
        let count = line.prefix(while: { $0 == fence.marker }).count
        return count >= fence.count && line.dropFirst(count).allSatisfy { $0 == 32 || $0 == 9 }
    }
}
