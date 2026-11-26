import SwiftUI

/// Shared projection of the text surfaces rendered by native message rows.
nonisolated enum NativeMessageText {
    struct MarkdownBlock: Identifiable, Sendable {
        let id: Int
        let text: String
        let code: Bool
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
}
