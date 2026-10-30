import Foundation
import Testing
@testable import BottoCore

// Source-backed wire fixtures, not captured traffic. Both Hermes 4a0eaf79 and
// ca678285 agent/image_routing.py:build_native_content_parts emit this image part.
// The tiny PNG is from tests/agent/test_image_routing.py:_png_bytes in both pins.
private let historyPNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg=="

@Test func historyImageOnlyRowHasACardInsteadOfAGeneratedPlaceholder() throws {
    let row: HermesJSON = .object(["id": .number(7), "role": .string("user"), "content": .array([
        .object(["type": .string("image_url"), "image_url": .object(["url": .string(historyPNG)])])
    ])])
    let message = try #require(HermesConversationState.messages([row], stored: "chat").first)
    #expect(message.text.isEmpty)
    #expect(message.attachments.count == 1)
    #expect(message.attachments.first?.name == "Image.png")
    #expect(message.attachments.first?.mimeType == "image/png")
    #expect(message.attachments.first?.path.contains("data:") == false)
    #expect(message.attachments.first?.path.count ?? 0 < 100)
    let encoded = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    #expect(!encoded.contains("base64"))
    #expect(row["content"].list?.last?["image_url"]["url"].text == historyPNG)
}

@Test func historyImageNativeCaptionKeepsCanonicalTextAndProjectsItsLocalFilename() throws {
    // 4a0eaf79 gateway/run_turn_runner.py:_native_image_run_message and
    // agent/image_routing.py:build_native_content_parts. Authority resume sends raw history.
    let path = "/home/u/.hermes/cache/documents/native-inputs/840a243a8b7fd77e97919216dec4f4ee0287203d15282b4662d4c930fc31f5cd/scan.png"
    let caption = "Inspect this\n\n[Image attached at: \(path)]"
    let message = try historyImageMessage(text: caption)
    #expect(message.text == caption)
    #expect(message.attachments == [ChatAttachment(name: "scan.png", path: path, mimeType: "image/png")])
    let shown = AttachmentPresentation.display(message)
    #expect(shown.text == "Inspect this")
    #expect(shown.attachments.map(\.name) == ["scan.png"])
}

@Test func historyImageSidecarCaptionAndPhotoOnlyRowsKeepTheirCards() throws {
    // ca678285 tui_gateway/session_history.py:_build_persist_user_message, proven by
    // tests/tui_gateway/test_tui_gateway_server.py:test_persist_user_message_mirrors_the_shape_sent_to_the_model.
    for (caption, expected) in [("what is this?\n", "what is this?"), ("", "")] {
        let text = caption + "@image:`/h/cat photo.png`"
        let message = try historyImageMessage(text: text)
        #expect(message.text == text)
        #expect(message.attachments.map(\.name) == ["cat photo.png"])
        #expect(AttachmentPresentation.display(message).text == expected)
    }
}

private func historyImageMessage(text: String, urls: [String] = [historyPNG]) throws -> ChatMessage {
    let parts: [HermesJSON] = [.object(["type": .string("text"), "text": .string(text)])]
        + urls.map { .object(["type": .string("image_url"), "image_url": .object(["url": .string($0)])]) }
    let row: HermesJSON = .object(["id": .number(7), "role": .string("user"), "content": .array(parts)])
    return try #require(HermesConversationState.messages([row], stored: "chat").first)
}

@Test func historyImageDuplicatesUseStableSmallIdentities() throws {
    let first = try historyImageMessage(text: "Compare", urls: [historyPNG, historyPNG])
    let second = try historyImageMessage(text: "Compare", urls: [historyPNG, historyPNG])
    #expect(first.text == "Compare")
    #expect(first.attachments.count == 1)
    #expect(first.attachments == second.attachments)
    #expect(first.attachments.first?.path == "chat:row:7:image:1")
}

@Test func historyImageIdenticalBytesAtDifferentNamedPathsKeepBothCards() throws {
    let caption = "Compare\n\n[Image attached at: /h/a.png]\n[Image attached at: /h/b.png]"
    let message = try historyImageMessage(text: caption, urls: [historyPNG, historyPNG])
    #expect(message.attachments.map(\.path) == ["/h/a.png", "/h/b.png"])
    #expect(AttachmentPresentation.display(message).text == "Compare")
}

@Test func historyImageKeepsTypedPlaceholderAndUnknownParts() throws {
    let row: HermesJSON = .object(["id": .number(7), "role": .string("user"), "content": .array([
        .object(["type": .string("text"), "text": .string("Typed [image_url]")]),
        .object(["type": .string("audio")]),
        .object(["type": .string("image_url"), "image_url": .object(["url": .string(historyPNG)])]),
        .string("  unchanged  ")
    ])])
    let message = try #require(HermesConversationState.messages([row], stored: "chat").first)
    #expect(message.text == "Typed [image_url]\n[audio]\n  unchanged  ")
    #expect(message.attachments.count == 1)
}

@Test(arguments: [
    "https://user:password@example.com/photo.png?token=private",
    "file:///private/tmp/photo.png", "/private/tmp/photo.png",
    "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", "data:text/html;base64,PHNjcmlwdD4=",
    "data:image/png;base64,", "data:image/png;base64,not base64!", "data:image/png;base64,AAA",
    "hermes-retained:840a243a8b7fd77e97919216dec4f4ee0287203d15282b4662d4c930fc31f5cd"
])
func historyImageUntrustedResourcesStayUnknownWithoutRetainingTheirURLs(_ url: String) throws {
    let message = try historyImageMessage(text: "Look", urls: [url])
    #expect(message.text == "Look\n[image_url]")
    #expect(message.attachments.isEmpty)
}

@Test(arguments: [ChatMessage.Role.assistant, .tool, .system])
func historyImageOtherRolesKeepTheirExistingTextProjection(_ role: ChatMessage.Role) throws {
    let row: HermesJSON = .object(["id": .number(7), "role": .string(role.rawValue), "content": .array([
        .object(["type": .string("text"), "text": .string("Reply")]),
        .object(["type": .string("image_url"), "image_url": .object(["url": .string(historyPNG)])])
    ])])
    let message = try #require(HermesConversationState.messages([row], stored: "chat").first)
    #expect(message.text == "Reply\n[image_url]")
    #expect(message.attachments.isEmpty)
}

@Test func historyImageTextOverrideAndPhotoOnlyEmptyToolCallsSurvive() throws {
    let row: HermesJSON = .object(["id": .number(7), "role": .string("user"), "text": .string("[image_url]"),
        "tool_calls": .array([]), "content": .array([
            .object(["type": .string("image_url"), "image_url": .object(["url": .string(historyPNG)])])
        ])])
    let message = try #require(HermesConversationState.messages([row], stored: "chat").first)
    #expect(message.text == "[image_url]")
    #expect(message.attachments.count == 1)
    var imageOnly = row
    imageOnly["text"] = .string("")
    #expect(HermesConversationState.messages([imageOnly], stored: "chat").first?.attachments.count == 1)
}

@Test(arguments: [
    "Example\n\n```\n\n[Image attached at: /h/photo.png]",
    "Example\n\n~~~\n@image:/h/photo.png",
    "Example\n\n[Image attached at: https://user:password@example.com/photo.png]",
    "Example\n\n[Image attached at: /h/../private.png]",
    "Example\n\n[Image attached at: /h/photo.png?token=private]",
    "Example\n\n[Image attached at: /h/]",
    "Example\n\n[Image attached at: relative/photo.png]",
    "Example\n\n[Image attached at: /h/a.png]\n[Image attached at: /h/b.png]"
])
func historyImageUntrustedOrMismatchedHintsKeepTypedText(_ text: String) throws {
    let message = try historyImageMessage(text: text)
    #expect(message.text == text)
    #expect(message.attachments.map(\.name) == ["Image.png"])
    #expect(message.attachments.first?.path == "chat:row:7:image:1")
    #expect(AttachmentPresentation.display(message).text == text)
}

@MainActor @Test(arguments: [true, false])
func historyImageCardsSurviveServiceRestoreAndReconnect(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    // Authority resume returns raw history (session_controls.py:resume). Sidecar
    // resume flattens it; its omitted-history path reads raw REST /messages rows.
    let text = authority ? "Look\n\n[Image attached at: /h/photo.png]" : "Look\n@image:/h/photo.png"
    let row: HermesJSON = .object(["id": .number(7), "role": .string("user"), "content": .array([
        .object(["type": .string("text"), "text": .string(text)]),
        .object(["type": .string("image_url"), "image_url": .object(["url": .string(historyPNG)])])
    ])])
    if authority { host.snapshot["messages"] = .array([row]) }
    else {
        host.snapshot["messages_omitted"] = .bool(true)
        let original = host.transport.handler
        host.transport.handler = { request in
            if request.url?.path.hasSuffix("/messages") == true {
                return .object(["session_id": .string(host.root), "profile": .string(host.bot.id), "messages": .array([row])])
            }
            return try original?(request) ?? .object([:])
        }
    }
    _ = try await service.connect(configuration: host.configuration)
    let first = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    service.disconnect()
    _ = try await service.connect(configuration: host.configuration)
    let restored = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let message = try #require(restored.snapshot.messages.first)
    #expect(restored.snapshot.storedID == first.snapshot.storedID)
    #expect(message.text == text)
    #expect(message.attachments == first.snapshot.messages.first?.attachments)
    #expect(message.attachments == [ChatAttachment(name: "photo.png", path: "/h/photo.png", mimeType: "image/png")])
    #expect(AttachmentPresentation.display(message).text == "Look")
}

@Test func historyImageUnknownPartShapesKeepTheirText() throws {
    let parts: [HermesJSON] = [
        .object(["type": .string("input_image"), "image_url": .string(historyPNG)]),
        .object(["type": .string("image_url"), "image_url": .string(historyPNG)]),
        .object(["type": .string("image_url"), "text": .string("literal"), "image_url": .object(["url": .string(historyPNG)])])
    ]
    let row: HermesJSON = .object(["id": .number(7), "role": .string("user"), "content": .array(parts)])
    let message = try #require(HermesConversationState.messages([row], stored: "chat").first)
    #expect(message.text == "[input_image]\n[image_url]\nliteral")
    #expect(message.attachments.isEmpty)
}
