import SwiftUI
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
