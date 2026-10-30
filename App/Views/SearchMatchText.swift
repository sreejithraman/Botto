import SwiftUI
import UIKit
import BottoCore

/// Shared projection of the text surfaces rendered by native message rows.
nonisolated enum NativeMessageText {
    struct MarkdownBlock: Identifiable, Sendable {
        let id: Int
        let text: String
        let code: Bool
    }

    static func segments(for message: ChatMessage) -> [String] {
        guard message.isVisible, message.notificationPresentation == nil else { return [] }
        if message.botSender != nil { return nonempty([message.attributedText]) }
        if message.role == .user { return nonempty([AttachmentPresentation.display(message).text]) }
        if message.role == .assistant {
            return ReplyContent(message: message).blocks.flatMap { block -> [String] in
                switch block.kind {
                case .code: return nonempty([block.source])
                case .text:
                    return ArtifactReferences.segments(in: block.source).flatMap { segment -> [String] in
                        guard case .text(let source) = segment else { return [] }
                        return markdownBlocks(in: source).map { native in
                            native.code ? native.text : String(markdownAttributed(native.text, isReply: true).characters)
                        }
                    }
                case .preview, .filePreview: return []
                }
            }
        }
        if message.role == .system, ["error:", "outcome:", "uncertain:"].contains(where: message.id.hasPrefix) {
            return nonempty([message.text])
        }
        return []
    }

    static func markdownBlocks(in text: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var lines: [String] = []
        var inCode = false
        func flush() {
            if !lines.isEmpty {
                let source = lines.joined(separator: "\n")
                let content = inCode ? source : source.trimmingCharacters(in: .newlines)
                if !content.isEmpty { result.append(MarkdownBlock(id: result.count, text: content, code: inCode)) }
                lines = []
            }
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { flush(); inCode.toggle() }
            else { lines.append(line) }
        }
        flush()
        return result
    }

    static func markdownAttributed(_ text: String, isReply: Bool) -> AttributedString {
        var result = AttributedString()
        for (index, paragraph) in text.components(separatedBy: "\n\n").enumerated() {
            if index > 0 { result.append(AttributedString("\n\n")) }
            let leadingNewlines = paragraph.prefix(while: { $0 == "\n" })
            result.append(AttributedString(String(leadingNewlines)))
            let paragraph = String(paragraph.dropFirst(leadingNewlines.count))
            let heading = paragraph.hasPrefix("#")
            let content = heading ? String(paragraph.drop(while: { $0 == "#" || $0 == " " })) : paragraph
            var attributed = (try? AttributedString(markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
            if heading { attributed.font = isReply ? .title3.weight(.semibold) : .headline }
            result.append(attributed)
        }
        return result
    }

    private static func nonempty(_ texts: [String]) -> [String] {
        texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Presentation only. The scene supplies this value to one validated message.
struct NativeSearchMatch: Equatable, Sendable {
    let id: UUID
    let query: String

    static func contains(query: String, in message: ChatMessage) -> Bool {
        guard !query.isEmpty else { return false }
        return NativeMessageText.segments(for: message).contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
        }
    }
}

private struct NativeSearchMatchKey: EnvironmentKey {
    static let defaultValue: NativeSearchMatch? = nil
}
private struct NativeTranscriptBlockIDKey: EnvironmentKey {
    static let defaultValue = 0
}
extension EnvironmentValues {
    var nativeSearchMatch: NativeSearchMatch? {
        get { self[NativeSearchMatchKey.self] }
        set { self[NativeSearchMatchKey.self] = newValue }
    }
    var nativeTranscriptBlockID: Int {
        get { self[NativeTranscriptBlockIDKey.self] }
        set { self[NativeTranscriptBlockIDKey.self] = newValue }
    }
}

/// Keeps native Text selection, links and traits while marking real glyph bounds.
struct SearchMatchText: View {
    let text: AttributedString
    @Environment(\.nativeSearchMatch) private var match
    @Environment(\.nativeTranscriptRow) private var row
    @Environment(\.nativeTranscriptBlockID) private var block
    @State private var measurement = SearchMatchMeasurement()
    @State private var presence = NativeTranscriptBlockPresence()
    @State private var layoutSize = CGSize.zero

    init(_ text: String) { self.text = AttributedString(text) }
    init(_ text: AttributedString) { self.text = text }

    var body: some View {
        Group {
            if let match, !match.query.isEmpty {
                let prepared = Self.prepared(text, query: match.query)
                let renderedSize = layoutSize
                Text(prepared.styled)
                .overlay(alignment: .topLeading) {
                    prepared.geometry.textRenderer(SearchMatchGeometryRenderer { rect in
                        Task { @MainActor in
                            measurement.observe(rect, match: match, text: text, size: renderedSize)
                        }
                    })
                    .textSelection(.disabled)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { layoutSize = $0 }
                .background(alignment: .topLeading) {
                    if let row, let rect = measurement.rect(for: match, text: text, size: layoutSize) {
                        NativeTranscriptMarker(scope: row, presence: presence, block: block, role: .search(match.id))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            } else { Text(text) }
        }
    }

    private struct Prepared {
        let styled: AttributedString
        let geometry: Text
    }
    private static func prepared(_ source: AttributedString, query: String) -> Prepared {
        let plain = String(source.characters)
        var result = Text("")
        var styled = source
        var cursor = plain.startIndex
        var first = true
        while cursor < plain.endIndex,
              let range = plain.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<plain.endIndex, locale: .current),
              !range.isEmpty,
              let before = Range(cursor..<range.lowerBound, in: source),
              let selected = Range(range, in: source) {
            styled[selected].backgroundColor = BottoTheme.selection
            styled[selected].foregroundColor = BottoTheme.ink
            let marked = AttributedString(styled[selected])
            let prefix = Text(AttributedString(source[before]))
            let hit = first ? Text(marked).customAttribute(SearchMatchAttribute()) : Text(marked)
            result = Text("\(result)\(prefix)\(hit)")
            first = false
            cursor = range.upperBound
        }
        if let suffix = Range(cursor..<plain.endIndex, in: source) {
            result = Text("\(result)\(Text(AttributedString(source[suffix])))")
        }
        return Prepared(styled: styled, geometry: result)
    }
}

@MainActor @Observable private final class SearchMatchMeasurement {
    private var observed: (NativeSearchMatch, AttributedString, CGSize, CGRect)?
    func observe(_ rect: CGRect?, match: NativeSearchMatch, text: AttributedString, size: CGSize) {
        guard let rect, size.width > 0, size.height > 0, rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite else { return }
        if let observed, observed.0 == match, observed.1 == text, observed.2 == size, observed.3 == rect { return }
        observed = (match, text, size, rect)
    }
    func rect(for match: NativeSearchMatch, text: AttributedString, size: CGSize) -> CGRect? {
        guard let observed, observed.0 == match, observed.1 == text, observed.2 == size else { return nil }
        return observed.3
    }
}
private struct SearchMatchAttribute: TextAttribute {}
/// Only the focused text has a second layout. Default Text paints every glyph;
/// the transparent renderer supplies range geometry without rasterizing its body.
private struct SearchMatchGeometryRenderer: TextRenderer {
    let report: @Sendable (CGRect?) -> Void
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var first: CGRect?
        for line in layout {
            for run in line {
                if first == nil, run[SearchMatchAttribute.self] != nil { first = run.typographicBounds.rect }
            }
        }
        report(first)
    }
}
