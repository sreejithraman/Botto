// Syntax and delimiter handling adapted from Hermex TranscriptMedia.swift and FileReference.swift,
// revisions 47809f2cd1f07bcbe592ee8960cf9c63e88b734c and 1a12ab2b90d7459c96c45598936b671af412c04f.
// Copyright (c) 2026 Uzair Ansar. MIT; see LICENSES/Hermex.txt.
import Foundation
import UniformTypeIdentifiers

public enum ArtifactReferencePart: Equatable, Sendable {
    case text(String)
    case attachment(ChatAttachment)
}

/// A read-only projection for native assistant paragraphs, after ReplyContent separates fences.
/// Paths are opaque server identities. This parser never resolves or opens a local file.
public enum ArtifactReferences {
    public enum Provenance: Equatable, Sendable { case delivered, referenced }
    public enum Part: Equatable, Sendable {
        case text(String)
        case attachment(ChatAttachment, provenance: Provenance)
    }

    public static func segments(in text: String) -> [ArtifactReferencePart] {
        parts(in: text).map { part in
            switch part {
            case .text(let text): .text(text)
            case .attachment(let attachment, _): .attachment(attachment)
            }
        }
    }

    public static func parts(in text: String) -> [Part] {
        guard !text.isEmpty else { return [] }
        // The caller owns fenced blocks. Unexpected fences fail closed as one source paragraph;
        // this avoids maintaining another whole-transcript fence parser here.
        guard !text.components(separatedBy: .newlines).contains(where: { line in
            (line.contains("```") || line.contains("~~~")) &&
                line.firstMatch(of: /^ {0,3}(?:`{3,}|~{3,})/) != nil
        }) else { return [.text(text)] }

        var parts: [Part] = []
        var cursor = text.startIndex
        var textStart = cursor
        var lineRange = text.lineRange(for: cursor..<cursor)
        while cursor < text.endIndex {
            if !lineRange.contains(cursor) { lineRange = text.lineRange(for: cursor..<cursor) }
            if text[cursor] == "\\" {
                let escaped = text.index(after: cursor)
                if escaped < text.endIndex, text[escaped...].hasPrefix("![") {
                    cursor = markdown(in: text, from: escaped).end
                } else {
                    cursor = escaped < text.endIndex ? text.index(after: escaped) : escaped
                }
                continue
            }
            if text[cursor] == "`" {
                cursor = codeEnd(in: text, from: cursor)
                continue
            }
            let lineStart = lineRange.lowerBound
            let indented = text[lineStart...].hasPrefix("    ") || text[lineStart] == "\t"
            var reference: (path: String, end: String.Index, provenance: Provenance)?
            if !indented, text[cursor] == "[" || text[cursor...].hasPrefix("![") {
                let link = markdown(in: text, from: cursor)
                if let path = link.path {
                    reference = (path, link.end, .referenced)
                } else {
                    cursor = link.end
                    continue
                }
            } else if !indented, isBoundary(in: text, at: cursor) {
                if text[cursor...].hasPrefix("@file:"),
                   text[lineStart..<cursor].allSatisfy(\.isWhitespace),
                   let token = token(in: text, from: text.index(cursor, offsetBy: 6)),
                   text[token.end..<(text[token.end...].firstIndex(where: \.isNewline) ?? text.endIndex)].allSatisfy(\.isWhitespace),
                   let path = localPath(token.value, relative: true, bareRelative: true) {
                    reference = (path, token.end, .delivered)
                } else if text[cursor...].hasPrefix("MEDIA:"),
                   let token = token(in: text, from: text.index(cursor, offsetBy: 6)),
                   let path = localPath(token.value, relative: false) {
                    reference = (path, token.end, .delivered)
                } else if text[cursor...].hasPrefix("file://"),
                          let token = token(in: text, from: cursor),
                          let path = localPath(token.value, relative: false) {
                    reference = (path, token.end, .referenced)
                }
            }
            if let reference {
                if textStart < cursor { parts.append(.text(String(text[textStart..<cursor]))) }
                parts.append(.attachment(attachment(path: reference.path), provenance: reference.provenance))
                cursor = reference.end
                textStart = cursor
                continue
            }
            // A malformed delimited MEDIA value may contain marker-like text. Do not
            // reinterpret any of that unfinished value as a second, shorter attachment.
            if text[cursor...].hasPrefix("MEDIA:") {
                let valueStart = text.index(cursor, offsetBy: 6)
                if valueStart < text.endIndex, "\"'<`".contains(text[valueStart]) {
                    cursor = text[cursor...].firstIndex(where: \.isNewline) ?? text.endIndex
                    continue
                }
            }
            cursor = text.index(after: cursor)
        }
        if textStart < text.endIndex { parts.append(.text(String(text[textStart...]))) }
        return parts
    }

    private static func markdown(in text: String, from start: String.Index) -> (path: String?, end: String.Index) {
        let lineEnd = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
        let labelStart = text[start] == "!" ? text.index(after: start) : start
        guard let labelEnd = balancedClose(in: text, from: labelStart, until: lineEnd, open: "[", close: "]")
        else { return (nil, lineEnd) }
        var cursor = text.index(after: labelEnd)
        guard cursor < lineEnd, text[cursor] == "(" else { return (nil, cursor) }
        cursor = text.index(after: cursor)
        skipSpaces(in: text, cursor: &cursor, until: lineEnd)
        guard cursor < lineEnd else { return (nil, lineEnd) }
        let destination: String
        if ["<", "\"", "'"].contains(text[cursor]) {
            guard let quoted = enclosed(in: text, from: cursor, until: lineEnd) else { return (nil, lineEnd) }
            destination = quoted.value
            cursor = quoted.end
        } else {
            let valueStart = cursor
            var depth = 0
            while cursor < lineEnd {
                let character = text[cursor]
                if character == "\\" {
                    cursor = text.index(after: cursor)
                    guard cursor < lineEnd else { return (nil, lineEnd) }
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    if depth == 0 { break }
                    depth -= 1
                } else if character.isWhitespace { break }
                cursor = text.index(after: cursor)
            }
            guard depth == 0 else { return (nil, lineEnd) }
            destination = unescaped(String(text[valueStart..<cursor]))
        }
        let destinationEnd = cursor
        skipSpaces(in: text, cursor: &cursor, until: lineEnd)
        if cursor < lineEnd, text[cursor] != ")" {
            // Only a complete optional Markdown title can follow the destination.
            guard cursor > destinationEnd, ["\"", "'", "("].contains(text[cursor]),
                  let title = enclosed(in: text, from: cursor, until: lineEnd) else { return (nil, lineEnd) }
            cursor = title.end
            skipSpaces(in: text, cursor: &cursor, until: lineEnd)
        }
        guard cursor < lineEnd, text[cursor] == ")" else { return (nil, lineEnd) }
        return (localPath(destination, relative: true), text.index(after: cursor))
    }

    private static func skipSpaces(in text: String, cursor: inout String.Index, until end: String.Index) {
        while cursor < end, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
    }

    private static func balancedClose(
        in text: String, from start: String.Index, until end: String.Index, open: Character, close: Character
    ) -> String.Index? {
        var depth = 1
        var cursor = text.index(after: start)
        while cursor < end {
            if text[cursor] == "\\" {
                cursor = text.index(after: cursor)
            } else if text[cursor] == open {
                depth += 1
            } else if text[cursor] == close {
                depth -= 1
                if depth == 0 { return cursor }
            }
            if cursor < end { cursor = text.index(after: cursor) }
        }
        return nil
    }

    private static func enclosed(in text: String, from start: String.Index, until end: String.Index) -> (value: String, end: String.Index)? {
        let opening = text[start]
        let closing: Character = opening == "<" ? ">" : opening == "(" ? ")" : opening
        let valueStart = text.index(after: start)
        var cursor = valueStart
        while cursor < end {
            if text[cursor] == "\\" {
                cursor = text.index(after: cursor)
            } else if text[cursor] == closing {
                return (unescaped(String(text[valueStart..<cursor])), text.index(after: cursor))
            }
            if cursor < end { cursor = text.index(after: cursor) }
        }
        return nil
    }

    private static func unescaped(_ value: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        var result = ""
        var cursor = value.startIndex
        while cursor < value.endIndex {
            if value[cursor] == "\\" {
                let next = value.index(after: cursor)
                if next < value.endIndex, value[next].unicodeScalars.allSatisfy({ $0.isASCII && punctuation.contains($0) }) {
                    cursor = next
                }
            }
            result.append(value[cursor])
            cursor = value.index(after: cursor)
        }
        return result
    }

    private static func isBoundary(in text: String, at index: String.Index) -> Bool {
        index == text.startIndex || text[text.index(before: index)].isWhitespace
    }

    private static func token(in text: String, from start: String.Index) -> (value: String, end: String.Index)? {
        guard start < text.endIndex else { return nil }
        let first = text[start]
        if let closing: Character = ["\"": "\"", "'": "'", "<": ">", "`": "`"][first] {
            var cursor = text.index(after: start)
            let valueStart = cursor
            while cursor < text.endIndex, !text[cursor].isNewline {
                if text[cursor] == closing {
                    let end = text.index(after: cursor)
                    guard end == text.endIndex || text[end].isWhitespace || ".,;!?".contains(text[end]) else { return nil }
                    return (String(text[valueStart..<cursor]), end)
                }
                cursor = text.index(after: cursor)
            }
            return nil
        }
        var end = start
        while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
        while end > start, ".,;!?".contains(text[text.index(before: end)]) { end = text.index(before: end) }
        guard start < end else { return nil }
        let value = String(text[start..<end])
        guard !value.contains(where: { "\"'<>`".contains($0) }) else { return nil }
        return (value, end)
    }

    static func localPath(_ value: String, relative: Bool, bareRelative: Bool = false) -> String? {
        var path = value
        if value.lowercased().hasPrefix("file://") {
            guard let components = URLComponents(string: value), components.scheme?.lowercased() == "file",
                  components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
                  components.user == nil, components.password == nil, components.port == nil,
                  components.query == nil, components.fragment == nil,
                  let decoded = components.percentEncodedPath.removingPercentEncoding else { return nil }
            path = decoded
        }
        guard !path.isEmpty, !path.hasPrefix("//"), !path.hasPrefix("\\\\"), !path.hasSuffix("/"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.-]*:/) == nil,
              path.hasPrefix("/") || bareRelative || (relative && (path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("~/")))
        else { return nil }
        return path
    }

    static func attachment(path: String) -> ChatAttachment {
        let name = String(path.split(separator: "/").last ?? "File")
        let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ChatAttachment(name: name, path: path, mimeType: mime)
    }

    private static func codeEnd(in text: String, from start: String.Index) -> String.Index {
        var end = start
        while end < text.endIndex, text[end] == "`" { end = text.index(after: end) }
        let length = text.distance(from: start, to: end)
        var cursor = end
        while cursor < text.endIndex {
            guard text[cursor] == "`" else { cursor = text.index(after: cursor); continue }
            var next = cursor
            while next < text.endIndex, text[next] == "`" { next = text.index(after: next) }
            if text.distance(from: cursor, to: next) == length { return next }
            cursor = next
        }
        // Incomplete streaming code remains source until its closing delimiter arrives.
        return text.endIndex
    }
}
