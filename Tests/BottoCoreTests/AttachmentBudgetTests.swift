import Foundation
import Testing
@testable import BottoCore

@MainActor @Test func uploadsReportTheActualPreparedSizeForStagingBudgets() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    for (data, name, mime) in [(Data("hello".utf8), "notes.txt", "text/plain"), (attachmentPNG, "pixel.png", "image/png")] {
        let prepared = try HermesAttachment.prepare(data: data, filename: name, mime: mime)
        let uploaded = try await service.upload(data: data, filename: name, mimeType: mime, access: chat.access)
        #expect(uploaded.byteCount == prepared.data.count)
    }
    let legacy = Data(#"{"name":"old.txt","path":"/host/old.txt","mimeType":"text/plain"}"#.utf8)
    #expect(try JSONDecoder().decode(ChatAttachment.self, from: legacy).byteCount == nil)
    #expect(HermesServiceError.attachmentLimit.localizedDescription == AttachmentLimits.message)
    #expect(AttachmentLimits.reservationBytes(dataCount: 1, filename: "photo.heic", mimeType: "application/octet-stream") == AttachmentLimits.fileBytes)
}
