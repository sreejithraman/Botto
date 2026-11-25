import AppKit
import SwiftUI

// MARK: - Markdown

enum MacMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(marker: String, text: String, depth: Int)
    case quote(String)
    case code(language: String?, code: String)
    case rule
}

/// A small chat-sized Markdown reader: block structure here, inline styling by Foundation.
enum MacMarkdown {
    static func blocks(from text: String) -> [MacMarkdownBlock] {
        var blocks: [MacMarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var fence: (marker: Character, length: Int, language: String?, indent: Int)?
        var code: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            paragraph = []
            quote = []
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let indent = leadingIndent(raw)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if indent < 4, closes(line, marker: open.marker, length: open.length) {
                    blocks.append(.code(language: open.language, code: code.joined(separator: "\n")))
                    fence = nil
                    code = []
                } else {
                    code.append(dropIndent(raw, upTo: open.indent))
                }
                continue
            }
            if indent < 4, let opened = opening(line) {
                flush()
                fence = (opened.marker, opened.length, opened.language, indent)
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if indent < 4, let heading = heading(line) {
                flush()
                blocks.append(heading)
                continue
            }
            if indent < 4, isRule(line) {
                flush()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix(">") {
                if !paragraph.isEmpty {
                    blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                    paragraph = []
                }
                var body = line.dropFirst()
                if body.first == " " { body = body.dropFirst() }
                quote.append(String(body))
                continue
            }
            if let item = listItem(line, indent: indent) {
                flush()
                blocks.append(item)
                continue
            }
            if !quote.isEmpty { flush() }
            if paragraph.isEmpty, indent > 0, case .listItem(let marker, let text, let depth)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, text: text + "\n" + line, depth: depth)
                continue
            }
            paragraph.append(line)
        }
        if let open = fence {
            // A reply still streaming may not have closed its fence yet.
            blocks.append(.code(language: open.language, code: code.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func leadingIndent(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }

    private static func dropIndent(_ line: String, upTo indent: Int) -> String {
        var remaining = indent
        var index = line.startIndex
        while remaining > 0, index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
            remaining -= 1
        }
        return String(line[index...])
    }

    private static func opening(_ line: String) -> (marker: Character, length: Int, language: String?)? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let length = line.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = line.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return (marker, length, language?.isEmpty == false ? language : nil)
    }

    private static func closes(_ line: String, marker: Character, length: Int) -> Bool {
        line.count >= length && line.allSatisfy { $0 == marker }
    }

    private static func heading(_ line: String) -> MacMarkdownBlock? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String, indent: Int) -> MacMarkdownBlock? {
        let depth = min(indent / 2, 4)
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            let text = String(line.dropFirst(2))
            if text.hasPrefix("[ ] ") { return .listItem(marker: "☐", text: String(text.dropFirst(4)), depth: depth) }
            if text.lowercased().hasPrefix("[x] ") {
                return .listItem(marker: "☑", text: String(text.dropFirst(4)), depth: depth)
            }
            return .listItem(marker: "•", text: text, depth: depth)
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")", rest.dropFirst().first == " " else {
            return nil
        }
        return .listItem(marker: String(digits) + ".", text: String(rest.dropFirst(2)), depth: depth)
    }
}

struct MacMarkdownView: View {
    enum Style { case editorial, outgoing }

    let text: String
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MacMarkdown.blocks(from: text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .foregroundStyle(style == .outgoing ? MacTheme.onOutgoing : Color.primary)
        .tint(style == .outgoing ? MacTheme.onOutgoing : MacTheme.action)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MacMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
                .font(.body)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inline(text)
                .font(MacTheme.rounded(level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .bold))
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .foregroundStyle(style == .outgoing ? MacTheme.onOutgoing.opacity(0.7) : MacTheme.action)
                    .monospacedDigit()
                    .frame(minWidth: 12, alignment: .trailing)
                inline(text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            inline(text)
                .italic()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(MacTheme.action.opacity(0.5)).frame(width: 3)
                }
        case .code(let language, let code):
            MacCodeBlock(language: language, code: code, onOutgoing: style == .outgoing)
        case .rule:
            Rectangle().fill(MacTheme.hairline).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func inline(_ text: String) -> Text {
        var attributed = MacMarkdown.inline(text)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.body, design: .monospaced)
            attributed[run.range].backgroundColor = style == .outgoing
                ? MacTheme.onOutgoing.opacity(0.14) : MacTheme.surfaceDeep
            if style == .editorial { attributed[run.range].foregroundColor = MacTheme.pressedAction }
        }
        return Text(attributed)
    }
}

private struct MacCodeBlock: View {
    let language: String?
    let code: String
    var onOutgoing = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.lowercased() ?? "code")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(onOutgoing ? MacTheme.onOutgoing.opacity(0.15) : MacTheme.selection, in: .capsule)
                    .foregroundStyle(onOutgoing ? MacTheme.onOutgoing : MacTheme.action)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? MacTheme.running : Color.secondary)
                .accessibilityLabel(copied ? "Copied code" : "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(onOutgoing ? MacTheme.onOutgoing.opacity(0.06) : MacTheme.surfaceDeep.opacity(0.6))
            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(12)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(onOutgoing ? MacTheme.onOutgoing.opacity(0.08) : MacTheme.surface, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(MacTheme.hairline) }
        .clipShape(.rect(cornerRadius: 12))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}
