// Name rules adapted from Hermex Models/MessageAttachment.swift,
// revision 47809f2cd1f07bcbe592ee8960cf9c63e88b734c. Copyright (c) 2026 Uzair Ansar.
// MIT; see LICENSES/Hermex.txt.
import Foundation

/// Read-only transcript projection. Host paths are identities, never local files or URLs to load.
public enum AttachmentPresentation {
    public static let imageOnlyPrompt = "Please examine the attached image."

    public static func display(_ message: ChatMessage) -> (text: String, attachments: [ChatAttachment]) {
        guard message.role == .user else { return (message.text, message.attachments) }
        var seen = Set<String>()
        let attachments = message.attachments.filter { seen.insert($0.path).inserted }.map { original in
            var attachment = original
            attachment.name = displayName(original.name, image: original.mimeType.hasPrefix("image/"))
            return attachment
        }
        return (message.text == imageOnlyPrompt && !attachments.isEmpty ? "" : message.text, attachments)
    }

    private static func displayName(_ value: String, image: Bool) -> String {
        let name = value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "File"
        var shown = name.replacing(/^[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}-/, with: "")
        if image {
            shown = shown.replacing(/^dashboard_\d{8}_\d{6}_[0-9a-f]{8}_/, with: "")
                .replacing(/^upload_[a-z0-9_]{8}(?=\.)/, with: "Photo")
        }
        return shown.isEmpty ? name : shown
    }
}
