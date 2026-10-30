import Foundation
import Testing
import BottoCore

@Test(arguments: ["[SILENT]", " silent ", "NO_REPLY", "**[SILENT]**", "静默。"])
func inboxPreviewOmitsSilenceMarkers(source: String) {
    #expect(ConversationPreview(message: .init(id: "quiet", role: .assistant, text: source)) == nil)
}

@Test(arguments: [
    "[IMPORTANT: Background process proc_56573e06a39f completed normally (exit code 0).\nCommand: example\nOutput: done]",
    "[IMPORTANT: Background process proc_56573e06a39f completed norm...",
    "\n[IMPORTANT: Background process proc_example failed (exit code 1).]"
])
func inboxPreviewSkipsTypedProcessWrappersWithoutReclassifyingUserPastes(source: String) {
    #expect(ConversationPreview(message: .init(id: "process", role: .user, text: source, displayKind: "process_complete")) == nil)
    let message = ChatMessage(id: "human-paste", role: .user, text: source)
    #expect(message.isOutgoingUserMessage && message.requiresAttention)
    #expect(message.notificationPresentation == nil && message.text == source)
    #expect(ConversationPreview(message: message)?.text.hasPrefix("[IMPORTANT: Background process ") == true)
}

@Test func inboxPreviewPreservesUserPastedSilenceTokens() {
    #expect(ConversationPreview(message: .init(id: "human", role: .user, text: "[SILENT]"))?.text == "[SILENT]")
}

@Test(arguments: [
    ("The marker [SILENT] means no reply.", "The marker [SILENT] means no reply."),
    ("[SILENT] Service failed", "[SILENT] Service failed"),
    ("Silent retry succeeded", "Silent retry succeeded"),
    ("Use **NO_REPLY** for this example.", "Use NO_REPLY for this example."),
    ("Background process output is useful.", "Background process output is useful.")
])
func inboxPreviewPreservesProseAboutControlMarkers(source: String, expected: String) {
    #expect(ReplyContent.summary(source) == expected)
}

@Test func inboxPreviewKeepsProseAndSkipsRichSource() {
    let source = "Before the dashboard, review the plan.\n\n```html\n<script>window.reviews = 0</script>\n```\n\nAfter."
    #expect(ReplyContent.summary(source) == "Before the dashboard, review the plan.")
}

@Test(arguments: [
    ("", ""), ("   \n", ""),
    ("```swift\nprint(1)\n```", "Shared code"),
    ("\n```html\n<p>ready</p>\n```", "Shared a preview"),
    ("::preview{file='/private/report.html'}", "Shared a file")
])
func inboxPreviewDescribesContentWithoutProse(source: String, expected: String) {
    #expect(ReplyContent.summary(source) == expected)
}

@Test func inboxPreviewUsesTheFirstReadableParagraph() {
    let source = "```mermaid\nflowchart LR; A --> B\n```\n\n# Review **the plan**\n\nThen decide."
    #expect(ReplyContent.summary(source) == "Review the plan")
}

@Test(arguments: [
    ("`::preview{file='/private/report.html'}`", "Shared code"),
    ("Before `::preview{file='/private/report.html'}` after.", "Before after."),
    ("`MEDIA:/private/report.html`\n\nHere is the plan.", "Here is the plan.")
])
func inboxPreviewSkipsInlineCode(source: String, expected: String) {
    #expect(ReplyContent.summary(source) == expected)
}

@Test(arguments: [
    "> ::preview{file='/private/report.html'}",
    "\\::preview{file='/private/report.html'}",
    "Use ::preview{file='/private/report.html'} for this example.",
    "> ::preview{file='/private/report.html'"
])
func inboxPreviewDescribesQuotedOrEscapedDirectives(source: String) {
    #expect(ReplyContent.summary(source) == "Shared a file")
}

@Test(arguments: [
    ("[/private/report.html](/private/report.html)", "report.html"),
    ("Read [the report](/private/report.html).", "Read report.html."),
    ("[**Private** report](../private/report.html)", "report.html"),
    ("[Report](file:///private/weekly%20report.html)", "weekly report.html"),
    ("[First](/private/report.html) and [second](/private/report.html)", "report.html and report.html"),
    ("[Public report](https://example.com/report.html)", "Public report")
])
func inboxPreviewProjectsLocalLinksBeforeDiscardingMarkdown(source: String, expected: String) {
    #expect(ReplyContent.summary(source) == expected)
}

@Test(arguments: ["\r\n\r\n", "\n \n"])
func inboxPreviewRecognizesParagraphLineEndings(separator: String) {
    #expect(ReplyContent.summary("First sentence." + separator + "Later paragraph.") == "First sentence.")
}

@Test(arguments: [
    "    print(1)",
    "- ```swift\n  print(1)\n  ```",
    "> ```html\n> <script>raw()</script>\n> ```"
])
func inboxPreviewSkipsIndentedAndNestedCode(code: String) {
    #expect(ReplyContent.summary(code + "\n\nHere is the plan.") == "Here is the plan.")
    #expect(ReplyContent.summary(code) == "Shared code")
}

@Test(arguments: [
    "@file:/private/report.html\n\n```swift\nprint(1)\n```",
    "```swift\nprint(1)\n```\n\n@file:/private/report.html",
    "```swift\nprint(1)\n```\n\nMEDIA:/private/report.html"
])
func inboxPreviewHidesHostPathsBesideCode(source: String) {
    #expect(ReplyContent.summary(source) == "report.html")
}

@Test func inboxPreviewSkipsRawHTML() {
    let html = "<html><script>window.reviews = 0</script><body>Hello</body></html>"
    #expect(ReplyContent.summary(html) == "Shared a preview")
    #expect(ReplyContent.summary(html + "\n\nHere is the plan.") == "Shared a preview")
    #expect(ReplyContent.summary("Hello <b>there</b>.") == "Shared a preview")
}

@Test(arguments: [
    "Update: <script>window.reviews = 0</script> done",
    "Style: <style>.body { color: red }</style> ready",
    "Update: <SCRIPT type='text/javascript'>window.x = 1</SCRIPT> done",
    "Update: <script>window.reviews = 0",
    "Hi <b><script>window.x = 1</script></b> done",
    "Hi <script>x()</script><style>.body { color: red }</style> done",
    "Hi <script>first();\n\nsecond();</script> done"
])
func inboxPreviewUsesGenericLabelForRawHTML(source: String) {
    #expect(ReplyContent.summary(source) == "Shared a preview")
}

@Test func inboxPreviewBoundsUnicodeWithoutChangingCanonicalText() {
    let sentence = String(repeating: "👩🏽‍💻", count: 170)
    let message = ChatMessage(id: "long", role: .assistant, text: sentence)
    #expect(ReplyContent.summary(message.text) == String(repeating: "👩🏽‍💻", count: 159) + "…")
    #expect(message.text == sentence)
}
