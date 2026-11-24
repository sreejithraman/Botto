import Foundation
import Testing
@testable import BottoCore

@Test func conversationPreviewKeepsLastReadableMessageAcrossQuietTurns() {
    let at = Date(timeIntervalSince1970: 123)
    let messages: [ChatMessage] = [
        .init(id: "user", role: .user, text: "Check the report"),
        .init(id: "answer", role: .assistant, text: "The report is **ready**.", timestamp: at),
        .init(id: "process", role: .user, text: "Raw process output", displayKind: "process_complete"),
        .init(id: "quiet", role: .assistant, text: "[SILENT]")
    ]
    let preview = ConversationPreview.latest(in: messages)
    #expect(preview?.messageID == "answer")
    #expect(preview?.text == "The report is ready.")
    #expect(preview?.timestamp == at)
    #expect(messages.last?.text == "[SILENT]")
}

@Test func conversationPreviewPreservesErrorsAndAttachmentsWithoutControlText() {
    let photo = ChatAttachment(name: "result.png", path: "/private/result.png", mimeType: "image/png")
    #expect(ConversationPreview(message: .init(id: "partial", role: .assistant, text: "[SI", isSilent: true)) == nil)
    #expect(ConversationPreview(message: .init(id: "photo", role: .assistant, text: "[SILENT]", attachments: [photo]))?.text == "Shared a photo")
    #expect(ConversationPreview(message: .init(id: "error", role: .assistant, text: "[SILENT]", displayKind: "failed_turn"))?.text == "Reply failed")
    #expect(ConversationPreview(message: .init(id: "empty-error", role: .assistant, text: "", displayKind: "failed_turn"))?.text == "Reply failed")
    #expect(ConversationPreview(message: .init(id: "file", role: .user, text: "", attachments: [.init(name: "report.pdf", path: "/private/report.pdf")]))?.text == "Shared a file")
}

@Test(arguments: ["", "Please inspect this photo."])
func conversationPreviewUsesTheUserAttachmentDisplay(caption: String) {
    let reference = "[The user attached an image: photo.png]\n[Examine it with the vision_analyze tool using image_url: /private/attachments/photo.png]"
    let raw = caption.isEmpty ? reference : caption + "\n\n" + reference
    let message = ChatMessage(id: "photo", role: .user, text: raw)
    let expected = caption.isEmpty ? "Shared a photo" : caption
    #expect(ConversationPreview(message: message)?.text == expected)
    #expect(message.text == raw && message.attachments.isEmpty)
}

@Test func conversationPreviewUsesAttributedContentAndSafeFailureTitles() throws {
    let dm = ChatMessage(id: "dm", role: .user, text: "Message from 🤖 Gustavo (@hermes): The service is healthy.", displayKind: "internal_notification")
    #expect(ConversationPreview(message: dm)?.text == "The service is healthy.")
    for kind in ["internal_notification", "process_complete", "async_delegation_complete"] {
        let routine = ChatMessage(id: "routine", role: .user, text: "Internal diagnostic payload", displayKind: kind)
        #expect(ConversationPreview(message: routine) == nil)
    }
    let process = ChatMessage(id: "failure", role: .user, text: "Command and diagnostic dump", displayKind: "process_complete", displayText: "Background process failed\nDetails: /private/output")
    #expect(ConversationPreview(message: process)?.text == "Background process failed")
    let agent = ChatMessage(id: "agent-failure", role: .user, text: "Internal task payload", displayKind: "async_delegation_complete", displayText: "Subagent task failed: report")
    #expect(ConversationPreview(message: agent)?.text == "Subagent task failed: report")
    let reply = ChatMessage(id: "summary", role: .assistant, text: "Scheduled result: the service needs attention.")
    let preview = try #require(ConversationPreview(message: reply))
    #expect(preview.text == reply.text)
    #expect(try JSONDecoder().decode(ConversationPreview.self, from: JSONEncoder().encode(preview)) == preview)
}
