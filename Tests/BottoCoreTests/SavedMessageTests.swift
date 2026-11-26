import Foundation
import Testing
@testable import BottoCore

/// Rows saved by builds that still read Hermes message kinds. Their extra keys are ignored, and every row reads as plain text.
private let oldRows = #"""
[{"id":"scheduled","role":"user","text":"[Cronjob \"Nightly\" output — scheduled job, not the user.]\n\n{\"ok\":true}","attachments":[],"displayKind":"internal_notification"},
 {"id":"dm","role":"user","text":"Message from 🤖 Gustavo (@gustavo): The service is healthy.","attachments":[],"displayKind":"internal_notification"},
 {"id":"process","role":"user","text":"Command output","attachments":[],"displayKind":"process_complete","displayText":"Background process finished"},
 {"id":"hidden","role":"assistant","text":"Hidden answer","attachments":[],"displayKind":"hidden"},
 {"id":"quiet","role":"assistant","text":"[SILENT]","attachments":[],"isSilent":true},
 {"id":"compacted","role":"user","text":"Can you check it?","attachments":[],"canonicalText":"[PRIOR CONTEXT]\nCan you check it?"},
 {"id":"note","role":"system","text":"The turn failed","attachments":[]},
 {"id":"photo","role":"user","text":"@file:`/host/photo.png`","attachments":[{"name":"photo.png","path":"/host/photo.png","mimeType":"image/png"}]}]
"""#

@Test func oldMessageKindsDecodeAsPlainRows() throws {
    let rows = try JSONDecoder().decode([ChatMessage].self, from: Data(oldRows.utf8))
    #expect(rows.map(\.id) == ["scheduled", "dm", "process", "hidden", "quiet", "compacted", "note", "photo"])
    #expect(rows.map(\.role) == [.user, .user, .user, .assistant, .assistant, .user, .system, .user])
    #expect(rows[1].text == "Message from 🤖 Gustavo (@gustavo): The service is healthy.")
    #expect(rows[5].text == "Can you check it?")
    #expect(rows[7].attachments.map(\.path) == ["/host/photo.png"])
    // Re-encoding writes only the current keys.
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    #expect(String(decoding: try encoder.encode(rows[4]), as: UTF8.self)
        == #"{"attachments":[],"id":"quiet","role":"assistant","text":"[SILENT]"}"#)
    #expect(ConversationPreview(message: rows[0])?.text.hasPrefix("[Cronjob") == true)
    #expect(ConversationPreview(message: rows[3])?.text == "Hidden answer")
    #expect(ConversationPreview(message: rows[6]) == nil)
    #expect(ConversationPreview(message: rows[7]) != nil)
}

/// Cached file keys hash this encoding. A row shaped like the T3 mapper's must encode exactly as it did before.
@Test func t3RowsEncodeExactlyAsBefore() throws {
    let row = ChatMessage(id: "thread-1:item-7", role: .assistant, text: "Report ready.",
        timestamp: Date(timeIntervalSince1970: 1_790_000_000),
        attachments: [ChatAttachment(name: "report.txt", path: "t3-attachment:file-1", mimeType: "text/plain", byteCount: 12)])
    let tool = ChatMessage(id: "thread-1:item-8", role: .tool, text: "ls\nreport.txt",
        timestamp: Date(timeIntervalSince1970: 1_790_000_001), toolName: "Command")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    #expect(String(decoding: try encoder.encode([row]), as: UTF8.self)
        == #"[{"attachments":[{"byteCount":12,"mimeType":"text\/plain","name":"report.txt","path":"t3-attachment:file-1"}],"id":"thread-1:item-7","role":"assistant","text":"Report ready.","timestamp":811692800}]"#)
    #expect(String(decoding: try encoder.encode([tool]), as: UTF8.self)
        == #"[{"attachments":[],"id":"thread-1:item-8","role":"tool","text":"ls\nreport.txt","timestamp":811692801,"toolName":"Command"}]"#)
}

@Test func disclosureIdentityDoesNotChangeDurableMessageBytes() throws {
    let durable = ChatMessage(id: "stored:row:5", role: .tool, text: "MEDIA:/report.txt", toolName: "terminal")
    var displayed = durable; displayed.workDetailsID = "tool:live:call"
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(displayed) == encoder.encode(durable))
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoder.encode(displayed))
    #expect(decoded == durable)
}

/// A reply is shown as written, even when its whole text looks like an old silence marker.
@Test(arguments: ["Silent.", "NO REPLY", "[SILENT]", "NO_REPLY"])
func replyThatLooksLikeASilenceMarkerIsPreviewed(text: String) {
    #expect(ConversationPreview(message: .init(id: "reply", role: .assistant, text: text))?.text == text)
}

@Test func anOlderSavedAttachmentCanOmitItsByteCount() throws {
    let legacy = Data(#"{"name":"old.txt","path":"/host/old.txt","mimeType":"text/plain"}"#.utf8)
    #expect(try JSONDecoder().decode(ChatAttachment.self, from: legacy).byteCount == nil)
}
