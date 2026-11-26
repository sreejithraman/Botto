import Foundation
import Testing
@testable import BottoCore

private func userRow(_ text: String, _ attachments: [ChatAttachment]) -> ChatMessage {
    ChatMessage(id: "thread-1:item-1", role: .user, text: text, attachments: attachments)
}

@Test func userAttachmentsShowOncePerPathKeepingTheFirst() {
    let first = ChatAttachment(name: "report.pdf", path: "t3-attachment:report", mimeType: "application/pdf")
    let again = ChatAttachment(name: "report copy.pdf", path: "t3-attachment:report", mimeType: "application/pdf")
    let other = ChatAttachment(name: "report.pdf", path: "t3-attachment:other", mimeType: "application/pdf")
    let message = userRow("Compare", [first, again, other])
    #expect(AttachmentPresentation.display(message).attachments == [first, other])
    #expect(message.attachments == [first, again, other])
}

@Test func userAttachmentNamesDropAnUploadUUIDPrefix() {
    let names = ["0F6A3C1E-8D2B-4F7A-9C3D-5E6F7A8B9C0D-notes.txt", "0f6a3c1e-8d2b-4f7a-9c3d-5e6f7a8b9c0d-notes.txt",
                 "/host/0F6A3C1E-8D2B-4F7A-9C3D-5E6F7A8B9C0D-Q3 report.pdf",
                 "1234-notes.txt", "0F6A3C1E-8D2B-4F7A-9C3D-ZZZZZZZZZZZZ-notes.txt",
                 "0F6A3C1E-8D2B-4F7A-9C3D-5E6F7A8B9C0D-"]
    let attachments = names.enumerated().map { ChatAttachment(name: $1, path: "t3-attachment:\($0)", mimeType: "text/plain") }
    #expect(AttachmentPresentation.display(userRow("Read", attachments)).attachments.map(\.name)
        == ["notes.txt", "notes.txt", "Q3 report.pdf", "1234-notes.txt",
            "0F6A3C1E-8D2B-4F7A-9C3D-ZZZZZZZZZZZZ-notes.txt", "0F6A3C1E-8D2B-4F7A-9C3D-5E6F7A8B9C0D-"])
}

@Test func photoNamesDropHostUploadPrefixes() {
    let photos = ["dashboard_20261004_031500_ab12cd34_photo.jpg", "upload_bz7wz_3o.jpg", "upload_notes.jpg"]
        .enumerated().map { ChatAttachment(name: $1, path: "t3-attachment:photo-\($0)", mimeType: "image/jpeg") }
    let files = ["dashboard_20261004_031500_ab12cd34_photo.txt", "upload_abcd1234.txt"]
        .enumerated().map { ChatAttachment(name: $1, path: "t3-attachment:file-\($0)", mimeType: "text/plain") }
    #expect(AttachmentPresentation.display(userRow("", photos + files)).attachments.map(\.name)
        == ["photo.jpg", "Photo.jpg", "upload_notes.jpg", "dashboard_20261004_031500_ab12cd34_photo.txt", "upload_abcd1234.txt"])
}

@Test func aPhotoSentWithOnlyTheImagePromptShowsAlone() throws {
    let photo = ChatAttachment(name: "upload_bz7wz_3o.jpg", path: "t3-attachment:photo", mimeType: "image/jpeg")
    let message = userRow(AttachmentPresentation.imageOnlyPrompt, [photo])
    #expect(AttachmentPresentation.display(message).text.isEmpty)
    #expect(try #require(ConversationPreview(message: message)).text == "Shared a photo")

    let file = ChatAttachment(name: "notes.txt", path: "t3-attachment:notes", mimeType: "text/plain")
    #expect(ConversationPreview(message: userRow(AttachmentPresentation.imageOnlyPrompt, [file]))?.text == "Shared a file")

    for kept in [userRow(AttachmentPresentation.imageOnlyPrompt, []), userRow(AttachmentPresentation.imageOnlyPrompt + " Thanks", [photo]),
                 ChatMessage(id: "reply", role: .assistant, text: AttachmentPresentation.imageOnlyPrompt, attachments: [photo])] {
        #expect(AttachmentPresentation.display(kept).text == kept.text)
        #expect(ConversationPreview(message: kept)?.text == kept.text)
    }
}

@Test func aT3UserRowWithTextAndAnAttachmentShowsUnchanged() throws {
    let attachment = ChatAttachment(name: "report.pdf", path: "t3-attachment:report", mimeType: "application/pdf", byteCount: 42)
    let message = userRow("Can you summarize this report?", [attachment])
    let shown = AttachmentPresentation.display(message)
    #expect(shown.text == message.text)
    #expect(shown.attachments == message.attachments)
    #expect(try #require(ConversationPreview(message: message)).text == message.text)
}

@Test(arguments: [ChatMessage.Role.assistant, .system, .tool])
func otherRolesShowTheirAttachmentsAsSent(_ role: ChatMessage.Role) {
    let attachment = ChatAttachment(name: "0F6A3C1E-8D2B-4F7A-9C3D-5E6F7A8B9C0D-result.txt", path: "t3-attachment:result")
    let message = ChatMessage(id: "other", role: role, text: AttachmentPresentation.imageOnlyPrompt, attachments: [attachment, attachment])
    let shown = AttachmentPresentation.display(message)
    #expect(shown.text == message.text)
    #expect(shown.attachments == message.attachments)
}
