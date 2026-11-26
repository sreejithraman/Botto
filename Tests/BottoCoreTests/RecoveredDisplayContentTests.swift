import Foundation
import Testing
@testable import BottoCore

private let recoveredAsk = "Can you check the parser?"
private let compactionCarrier = "[PRIOR CONTEXT — for reference only; not a new message]\n\(recoveredAsk)\n\n"

@Test func canonicalTextSurvivesCodableAndDistinguishesRevisions() throws {
    let projected = ChatMessage(id: "chat:row:1", role: .user, text: "", displayText: "Title",
                                canonicalText: compactionCarrier)
    let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(projected))
    #expect(restored == projected)
    #expect(restored.text.isEmpty && restored.canonicalText == compactionCarrier && restored.displayText == "Title")

    var changed = projected
    changed.canonicalText = "Different scaffolding"
    #expect(changed != projected)
}

@Test func ordinaryMessagesEncodeExactlyAsBeforeAndLegacyCachesDecode() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let ordinary = ChatMessage(id: "chat:row:1", role: .assistant, text: "Plain", isSilent: false)
    #expect(String(decoding: try encoder.encode(ordinary), as: UTF8.self)
        == #"{"attachments":[],"id":"chat:row:1","isSilent":false,"role":"assistant","text":"Plain"}"#)

    let legacy = Data(#"{"id":"old","role":"user","text":"Saved words","attachments":[],"displayText":"Title"}"#.utf8)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: legacy)
    #expect(decoded.canonicalText == nil)
    #expect(decoded.text == "Saved words" && decoded.displayText == "Title")
}

@Test func presentationAndDiscoveryNeverReadCanonicalText() {
    let scaffolding = "MEDIA:/home/u/handoff-summary.pdf"
    let control = ChatMessage(id: "1", role: .assistant, text: scaffolding)
    #expect(ArtifactDiscovery.artifacts(in: [control]).count == 1)

    let projected = ChatMessage(id: "1", role: .assistant, text: "Visible reply", canonicalText: scaffolding)
    #expect(ArtifactDiscovery.artifacts(in: [projected]).isEmpty)
    #expect(ReplyContent(message: projected).blocks.map(\.source) == ["Visible reply"])
    #expect(AttachmentPresentation.display(projected).text == "Visible reply")
    #expect(ConversationPreview(message: projected)?.text == "Visible reply")
    #expect(projected.attributedText == "Visible reply")
    #expect(projected.notificationPresentation == nil)

    let silent = ChatMessage(id: "2", role: .assistant, text: "[SILENT]", canonicalText: "Canonical words")
    #expect(ConversationPreview(message: silent) == nil)
}

@Test func disclosureIdentityDoesNotChangeDurableMessageBytes() throws {
    let durable = ChatMessage(id: "stored:row:5", role: .tool, text: "MEDIA:/report.txt", toolName: "terminal")
    var displayed = durable; displayed.workDetailsID = "tool:live:call"
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(displayed) == encoder.encode(durable))
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoder.encode(displayed))
    #expect(decoded == durable)
}
