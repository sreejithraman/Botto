import Foundation
import Testing
@testable import BottoCore

@Test func conversationPreviewUsesTheNewestNonEmptyMessage() {
    let at = Date(timeIntervalSince1970: 123)
    let messages: [ChatMessage] = [
        .init(id: "user", role: .user, text: "Check the report"),
        .init(id: "answer", role: .assistant, text: "The report is **ready**.", timestamp: at),
        .init(id: "tool", role: .tool, text: "Raw tool output", toolName: "Command"),
        .init(id: "empty", role: .assistant, text: "")
    ]
    let preview = ConversationPreview.latest(in: messages)
    #expect(preview?.messageID == "answer")
    #expect(preview?.text == "The report is ready.")
    #expect(preview?.timestamp == at)
}

@Test func conversationPreviewDescribesAttachmentsWithoutText() throws {
    let photo = ChatAttachment(name: "result.png", path: "t3-attachment:photo", mimeType: "image/png")
    #expect(ConversationPreview(message: .init(id: "photo", role: .assistant, text: "", attachments: [photo]))?.text == "Shared a photo")
    #expect(ConversationPreview(message: .init(id: "file", role: .user, text: "", attachments: [.init(name: "report.pdf", path: "t3-attachment:report")]))?.text == "Shared a file")
    #expect(ConversationPreview(message: .init(id: "note", role: .system, text: "A note")) == nil)
    let reply = ChatMessage(id: "summary", role: .assistant, text: "Scheduled result: the service needs attention.")
    let preview = try #require(ConversationPreview(message: reply))
    #expect(preview.text == reply.text)
    #expect(try JSONDecoder().decode(ConversationPreview.self, from: JSONEncoder().encode(preview)) == preview)
}
