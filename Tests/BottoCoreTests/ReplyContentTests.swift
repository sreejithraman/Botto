import Foundation
import Testing
import BottoCore

@Test func replyContentRecognizesHostFilePreviewAndPreservesSurroundingText() throws {
    let text = "Before\r\n::preview{file=\"/Users/example.world/.hermes/workspace/inline-visual-test.html\" height='480'}\r\nAfter"
    let reply = ReplyContent(assistantText: text)
    #expect(reply.blocks.count == 3)
    let reference = try #require(reply.blocks[1].filePreview)
    #expect(reference.attachment.path == "/Users/example.world/.hermes/workspace/inline-visual-test.html")
    #expect(reference.attachment.name == "inline-visual-test.html")
    #expect(reference.isHTML)
    #expect(reference.initialHeight == 480)
    #expect(reply.blocks.map(\.rawText).joined() == text)
    #expect(ReplyContent(assistantText: text, isStreaming: true).blocks[1].isComplete == false)
}

@Test(arguments: [
    "`::preview{file=\"a.html\"}`", "\\::preview{file=\"a.html\"}",
    "    ::preview{file=\"a.html\"}", "> ::preview{file=\"a.html\"}",
    "::preview{file=\"https://example.com/a.html\"}", "::preview{file=\"//host/a.html\"}",
    "::preview{file=\"a.html\"", "::preview{file=a.html}", "::preview{file=\"\"}",
    "```text\n::preview{file=\"a.html\"}\n```", "`\n::preview{file=\"a.html\"}\n`"
])
func replyContentKeepsPreviewExamplesAndInvalidReferencesAsSource(_ text: String) {
    #expect(!ReplyContent(assistantText: text).blocks.contains { $0.filePreview != nil })
    #expect(ReplyContent(assistantText: text).blocks.map(\.rawText).joined() == text)
}

@Test func replyContentFilesWaitForSettleAndRejectInvalidOrOversizedHTML() throws {
    let directive = "::preview{File='reports/a b.HTML' height='9000'}"
    let block = try #require(ReplyContent(assistantText: directive).blocks.first)
    #expect(block.filePreview?.initialHeight == 1200)
    #expect(block.filePreview?.attachment.path == "reports/a b.HTML")
    let good = DownloadedArtifact(data: Data("<p>Report</p>".utf8), filename: "a b.HTML", mimeType: "text/html")
    #expect(block.resolvingFile(good)?.source == "<p>Report</p>")
    #expect(ReplyContent(assistantText: directive, isStreaming: true).blocks[0].resolvingFile(good) == nil)
    for bytes in [Data(), Data([0xff]), Data([0]), Data(repeating: 65, count: 131_073)] {
        #expect(block.resolvingFile(.init(data: bytes, filename: "a.HTML", mimeType: "text/html")) == nil)
    }
    for role in [ChatMessage.Role.user, .tool, .system] {
        #expect(ReplyContent(message: .init(id: "m", role: role, text: directive)).blocks[0].filePreview == nil)
    }
}

@Test func filePreviewWaitsWhileWorkContinuesAfterToolAndQueuedUserRows() {
    let chat = Conversation(id: "r", storedID: "s", profileID: "p", messages: [
        .init(id: "old", role: .assistant, text: "::preview{file='old.html'}"),
        .init(id: "user", role: .user, text: "Make a visual"),
        .init(id: "preview", role: .assistant, text: "::preview{file='new.html'}"),
        .init(id: "tool", role: .tool, text: "Writing file"),
        .init(id: "queued", role: .user, text: "Queued follow-up")
    ], isWorking: true)
    #expect(ReplyContent(message: chat.messages[2], filePreviewsAreSettled: !chat.isWorking).blocks[0].isComplete == false)
}

@Test(arguments: ["A literal backtick: `\n\n", "`\n\n`\n\n", "`unmatched\n"])
func unmatchedCodeDelimitersDoNotHideLaterFilePreviews(_ prefix: String) {
    let text = prefix + "::preview{file='report.html'}"
    #expect(ReplyContent(assistantText: text).blocks.last?.filePreview?.attachment.path == "report.html")
    #expect(ReplyContent(assistantText: text).blocks.map(\.rawText).joined() == text)
}

@Test func codeSpansCannotCrossFencesAndHideAFileDirective() {
    let text = "Use the ` character to quote code.\n```text\nExample\n```\n::preview{file='report.html'}\nThen open `report.html`."
    #expect(ReplyContent(assistantText: text).blocks.contains { $0.filePreview?.attachment.path == "report.html" })
    #expect(ReplyContent(assistantText: text).blocks.map(\.rawText).joined() == text)
}

@Test(arguments: ["# Report", "> A quote", "- A list", "1. A list", "---", "Title\n==="])
func markdownBlockBoundariesDoNotJoinUnrelatedBackticks(_ boundary: String) {
    let text = "Use the ` character.\n" + boundary + "\n::preview{file='report.html'}\nThen open `report.html`."
    #expect(ReplyContent(assistantText: text).blocks.contains { $0.filePreview?.attachment.path == "report.html" })
}

@Test(arguments: ["```", "~~~"])
func nestedFencedExamplesNeverBecomeFilePreviews(_ fence: String) {
    let text = "- " + fence + "text\n  ::preview{file='example.html'}\n  " + fence
        + "\n\n::preview{file='report.html'}\n\n```html\n<p>Live HTML</p>\n```"
    let reply = ReplyContent(assistantText: text)
    #expect(reply.blocks.compactMap(\.filePreview).map(\.attachment.path) == ["report.html"])
    #expect(reply.blocks.last?.previewFormat == .html)
    #expect(ReplyContent(assistantText: text).blocks.map(\.rawText).joined() == text)
}

@Test func replyContentPreservesOrderedNativeTextCodeAndRichBlocks() {
    let text = "Before\n\n```html\n<b>Hello</b>\n```\nAfter\n\n~~~swift\nprint(1)\n~~~\nEnd"
    let reply = ReplyContent(assistantText: text)
    #expect(reply.canonicalText == text)
    #expect(reply.blocks.map(\.kind) == [.text, .preview(.html), .text, .code(language: "swift"), .text])
    #expect(reply.blocks.map(\.source) == ["Before\n\n", "<b>Hello</b>\n", "After\n\n", "print(1)\n", "End"])
    #expect(reply.blocks.map(\.rawText).joined() == text)
}

@Test(arguments: [ChatMessage.Role.user, .tool, .system])
func replyContentNeverExecutesOtherRoles(_ role: ChatMessage.Role) {
    let text = "```html\n<script>alert(1)</script>\n```"
    let reply = ReplyContent(message: ChatMessage(id: "role", role: role, text: text))
    #expect(reply.blocks.count == 1)
    #expect(reply.blocks[0].kind == .text)
    #expect(reply.blocks[0].source == text)
}

@Test func replyContentRecognizesMatchingFencesAndPreservesUnicodeAndLineEndings() {
    let text = "前\r\n  ~~~~sVg\r\n<svg/>\r\n~~~\r\n```\r\n~~~~ trailing\r\n   ~~~~~\t\r\n後"
    let reply = ReplyContent(assistantText: text)
    #expect(reply.blocks.map(\.kind) == [.text, .preview(.svg), .text])
    #expect(reply.blocks[1].source == "<svg/>\r\n~~~\r\n```\r\n~~~~ trailing\r\n")
    #expect(reply.blocks.map(\.rawText).joined() == text)
    #expect(reply.blocks[1].id == 5)
}

@Test(arguments: ["<b>prose</b>", "    ```html\nhi\n    ```", "> ```html\n> hi\n> ```", "```html`bad\nhi\n```", "`<svg/>`", "graph LR; A-->B"])
func replyContentDoesNotInferPreviews(_ text: String) {
    let reply = ReplyContent(assistantText: text)
    #expect(!reply.blocks.contains { $0.previewFormat != nil })
    #expect(reply.blocks.map(\.rawText).joined() == text)
}

@Test func replyContentDoesNotConsumeNestedExamplesAsRenderableFences() {
    let text = "````markdown\n```html\n<b>example</b>\n```\n````\n~~~HTM\n<p>preview</p>\n~~~"
    let reply = ReplyContent(assistantText: text)
    #expect(reply.blocks.map(\.kind) == [.code(language: "markdown"), .preview(.html)])
    #expect(reply.blocks.map(\.rawText).joined() == text)
    #expect(ReplyContent(assistantText: "").blocks.isEmpty)
}

@Test func replyContentKeepsOversizedPreviewsAsCompleteUntruncatedSource() {
    let html = String(repeating: "é", count: 65_537)
    let text = "```html\n" + html + "\n```"
    let block = ReplyContent(assistantText: text).blocks[0]
    #expect(block.kind == .code(language: "html"))
    #expect(block.source == html + "\n")
    #expect(block.rawText == text)
    #expect(block.isComplete)
    let mermaid = String(repeating: "A-->B\n", count: 3_000)
    #expect(ReplyContent(assistantText: "~~~mermaid\n" + mermaid + "~~~").blocks[0].kind == .code(language: "mermaid"))
}

@Test func replyContentWaitsForUnambiguousStreamingClosureAndKeepsCompletedIDs() {
    let prefix = "🌿 Intro\n```HTML\n<button>Local</button>\n```"
    let provisional = ReplyContent(assistantText: prefix, isStreaming: true)
    #expect(provisional.blocks.last?.kind == .code(language: "html"))
    #expect(provisional.blocks.last?.isComplete == false)
    let closed = ReplyContent(assistantText: prefix + "\n", isStreaming: true)
    let more = ReplyContent(assistantText: prefix + "\nLater\n~~~mermaid\ngraph LR\nA-->B", isStreaming: true)
    #expect(closed.blocks.last?.kind == .preview(.html))
    #expect(Array(more.blocks.prefix(2)) == closed.blocks)
    #expect(more.blocks.last?.isComplete == false)
    #expect(ReplyContent(assistantText: prefix).blocks.last?.kind == .preview(.html))
    #expect(ReplyContent(assistantText: prefix + "x", isStreaming: true).blocks.last?.isComplete == false)
}
