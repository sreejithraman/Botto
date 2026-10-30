// Adapted from Hermex Models/MessageAttachment.swift (hermesReferences and name rules),
// revision 47809f2cd1f07bcbe592ee8960cf9c63e88b734c. Copyright (c) 2026 Uzair Ansar.
// MIT; see LICENSES/Hermex.txt.
import Foundation
import UniformTypeIdentifiers

/// Read-only transcript projection. Host paths are identities, never local files or URLs to load.
public enum AttachmentPresentation {
    public static func display(_ message: ChatMessage) -> (text: String, attachments: [ChatAttachment]) {
        guard message.role == .user else { return (message.text, message.attachments) }
        var seen = Set<String>()
        var attachments = message.attachments.filter { seen.insert($0.path).inserted }.map { original in
            var attachment = original
            attachment.name = displayName(original.name, image: original.mimeType.hasPrefix("image/"))
            return attachment
        }
        var kept: [String] = []
        var references: [String] = []
        var extracted = false
        var fence: String?
        let imageText = textWithoutImageHints(message.text, attachments: attachments)
        let blocks = imageText.components(separatedBy: "\n\n")
        for (index, block) in blocks.enumerated() {
            let inCode = fence != nil
            updateFence(in: block, active: &fence)
            if inCode { kept.append(block); continue }
            if block == "--- Attached Context ---" || block.hasPrefix("--- Context Warnings ---\n") {
                let footer = blocks[index...].joined(separator: "\n\n")
                if !generatedContext(footer, references: references) { kept.append(footer) }
                break
            }
            if block.hasPrefix("@file:"), let file = block.wholeMatch(of: /@file:(?:`([^`\n]+)`|"([^"\n]+)"|'([^'\n]+)'|([^`"'\s]+))/),
               let value = file.1 ?? file.2 ?? file.3 ?? file.4, isFilePath(String(value)) {
                let path = String(value)
                references.append(block)
                extracted = true
                if !attachments.contains(where: { $0.path == path }) {
                    attachments.append(attachment(path: path))
                }
            } else if block.hasPrefix("[The user attached an image: "), let image = block.wholeMatch(of: /\[The user attached an image: ([^\n]+)\]\n\[Examine it with the vision_analyze tool using image_url: ((?:\/|[A-Za-z]:[\\\/])[^\n]+)\]/),
                      isFilePath(String(image.2)), String(image.1) == basename(String(image.2)) {
                let path = String(image.2)
                extracted = true
                if !attachments.contains(where: { $0.path == path }) {
                    attachments.append(attachment(path: path, image: true))
                }
            } else { kept.append(block) }
        }
        guard extracted else { return (imageText, attachments) }
        return (kept.joined(separator: "\n\n").trimmingCharacters(in: .newlines), attachments)
    }

    private static func textWithoutImageHints(_ text: String, attachments: [ChatAttachment]) -> String {
        let paths = Set(attachments.filter { $0.mimeType.hasPrefix("image/") }.map(\.path))
        guard !paths.isEmpty, let hints = imageHints(in: text), hints.paths.allSatisfy(paths.contains) else { return text }
        return hints.text
    }

    /// Source-generated suffixes in native content and sidecar persisted text. A caller
    /// must still match these paths to image parts/cards before hiding any hint.
    static func imageHints(in text: String) -> (text: String, paths: [String])? {
        var fence: String?
        updateFence(in: text, active: &fence)
        guard fence == nil else { return nil }
        var lines = text.components(separatedBy: "\n")
        var paths: [String] = []
        var native: Bool?
        while let line = lines.last {
            let value: String
            let isNative: Bool
            if let hint = line.wholeMatch(of: /\[Image attached at: ([^\n]+)\]/) {
                value = String(hint.1); isNative = true
            }
            else if let hint = line.wholeMatch(of: /@image:(?:`([^`\n]+)`|"([^"\n]+)"|'([^'\n]+)'|([^`"'\s]+))/),
                    let path = hint.1 ?? hint.2 ?? hint.3 ?? hint.4 {
                value = String(path); isNative = false
            }
            else { break }
            if let native, native != isNative { return nil }
            native = isNative
            paths.insert(value, at: 0)
            lines.removeLast()
        }
        guard !paths.isEmpty, native != true || lines.last == "" else { return nil }
        while lines.last == "" { lines.removeLast() }
        return (lines.joined(separator: "\n"), paths)
    }

    private static func updateFence(in block: String, active: inout String?) {
        for line in block.components(separatedBy: "\n") {
            guard line.contains("```") || line.contains("~~~"),
                  let marker = line.wholeMatch(of: /^ {0,3}(`{3,}|~{3,})(.*)$/) else { continue }
            if let current = active {
                if marker.1.first == current.first, marker.1.count >= current.count,
                   marker.2.trimmingCharacters(in: .whitespaces).isEmpty { active = nil }
            } else { active = String(marker.1) }
        }
    }

    private static func isFilePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("//") && !path.hasPrefix("\\\\")
            && !path.hasSuffix("/") && !path.hasSuffix("\\")
            && path.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) == nil
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func basename(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "File"
    }

    private static func attachment(path: String, image: Bool = false) -> ChatAttachment {
        let shown = displayName(path, image: image)
        let mime = UTType(filenameExtension: (shown as NSString).pathExtension)?.preferredMIMEType
            ?? (image ? "image/jpeg" : "application/octet-stream")
        return ChatAttachment(name: shown, path: path, mimeType: mime)
    }

    private static func displayName(_ value: String, image: Bool) -> String {
        let name = basename(value)
        var shown = name.replacing(/^[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}-/, with: "")
        if image { shown = shown.replacing(/^dashboard_\d{8}_\d{6}_[0-9a-f]{8}_/, with: "") }
        return shown.isEmpty ? name : shown
    }

    private static func generatedContext(_ footer: String, references: [String]) -> Bool {
        guard !references.isEmpty else { return false }
        var context = footer
        if context.hasPrefix("--- Context Warnings ---\n") {
            let sections = context.components(separatedBy: "\n\n--- Attached Context ---\n\n")
            let warnings = sections[0].components(separatedBy: "\n").dropFirst()
            guard !warnings.isEmpty, warnings.allSatisfy({ line in
                references.contains { line.hasPrefix("- \($0): ") && line.count > $0.count + 4 }
            }) else { return false }
            guard sections.count > 1 else { return true }
            context = "--- Attached Context ---\n\n" + sections.dropFirst().joined(separator: "\n\n--- Attached Context ---\n\n")
        }
        guard context.hasPrefix("--- Attached Context ---\n\n") else { return false }
        var content = String(context.dropFirst("--- Attached Context ---\n\n".count))
        // The donor's tested older text shape lacks the token count/fence. Its header
        // must still name a whole reference extracted above; a delimiter alone is inert.
        if references.contains(where: { content.hasPrefix("📄 \($0)\n") }) { return true }
        while !content.isEmpty {
            let end: String.Index
            if let text = content.prefixMatch(of: /📄 ([^\n]+) \([0-9]+ tokens\)\n```[^\n]*\n[\s\S]*?\n```(?=\n\n(?:📄 |📎 )|$)/),
               references.contains(String(text.1)) { end = text.range.upperBound }
            else if let binary = content.prefixMatch(of: /📎 ([^\n]+) \([^\n]+\) — (?:binary file, not inlined as text\.|too large to inline safely\.) It is available on disk at `[^`\n]+`\. [^\n]+/),
                    references.contains(String(binary.1)) { end = binary.range.upperBound }
            else { return false }
            content = String(content[end...])
            if content.isEmpty { return true }
            guard content.hasPrefix("\n\n") else { return false }
            content.removeFirst(2)
        }
        return false
    }
}
