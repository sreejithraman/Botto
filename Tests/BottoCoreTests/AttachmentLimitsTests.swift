import Foundation
import Testing
@testable import BottoCore

@Test func reservingAHEICAttachmentAllowsForItsConvertedBytes() {
    #expect(ConversationServiceError.attachmentLimit.localizedDescription == AttachmentLimits.message)
    #expect(AttachmentLimits.reservationBytes(dataCount: 1, filename: "photo.heic", mimeType: "application/octet-stream") == AttachmentLimits.fileBytes)
}
