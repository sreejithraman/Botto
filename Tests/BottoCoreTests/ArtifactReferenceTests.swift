// Source-shaped cases for Hermes/Hermex syntax; no live transcript captures.
// Donor syntax: Copyright (c) 2026 Uzair Ansar. MIT; see LICENSES/Hermex.txt.
// Exact source pins and intentional differences are in Fixtures/ArtifactReferences/manifest.json.
import Foundation
import Testing
@testable import BottoCore

@Test func artifactReferencesProjectMixedTextWithoutChangingCanonicalMessage() {
    let raw = "Ready: MEDIA:/host/reports/result.pdf\nFinished."
    let message = ChatMessage(id: "reply", role: .assistant, text: raw)
    #expect(ArtifactReferences.segments(in: message.text) == [
        .text("Ready: "),
        .attachment(ChatAttachment(name: "result.pdf", path: "/host/reports/result.pdf", mimeType: "application/pdf")),
        .text("\nFinished.")
    ])
    #expect(message.text == raw)
    #expect(message.attachments.isEmpty)
}

@Test func artifactReferencesKeepCodeExamplesAndIncompleteStreamingSyntax() {
    let raw = "`MEDIA:/host/example.pdf` and ``MEDIA:/host/other.pdf`` then MEDIA:/host/real.pdf"
    #expect(ArtifactReferences.segments(in: raw) == [
        .text("`MEDIA:/host/example.pdf` and ``MEDIA:/host/other.pdf`` then "),
        .attachment(ChatAttachment(name: "real.pdf", path: "/host/real.pdf", mimeType: "application/pdf"))
    ])
    let examples = [
        "```text\nMEDIA:/host/example.pdf\n```", "~~~\nMEDIA:/host/example.pdf\n~~~",
        "````text\n```\nMEDIA:/host/example.pdf\n````", "`MEDIA:/host/incomplete.pdf",
        "MEDIA:", "MEDIA:/", "MEDIA:\"/host/incomplete.pdf", "MEDIA:<>",
        "    MEDIA:/host/indented.pdf"
    ]
    for text in examples { #expect(ArtifactReferences.segments(in: text) == [.text(text)]) }
}

@Test func artifactReferencesReadDelimitedMediaAndLocalFileURLsInOrder() {
    let raw = #"MEDIA:"/host/Q3 report.pdf" + MEDIA:</host/a (1).txt> + MEDIA:'/host/chart.svg' + file:///host/a%20b.csv."#
    #expect(ArtifactReferences.segments(in: raw) == [
        .attachment(ChatAttachment(name: "Q3 report.pdf", path: "/host/Q3 report.pdf", mimeType: "application/pdf")),
        .text(" + "),
        .attachment(ChatAttachment(name: "a (1).txt", path: "/host/a (1).txt", mimeType: "text/plain")),
        .text(" + "),
        .attachment(ChatAttachment(name: "chart.svg", path: "/host/chart.svg", mimeType: "image/svg+xml")),
        .text(" + "),
        .attachment(ChatAttachment(name: "a b.csv", path: "/host/a b.csv", mimeType: "text/csv")),
        .text(".")
    ])
}

@Test func artifactReferencesReadExplicitMarkdownPathsWithNestedEscapedDelimiters() {
    let raw = #"Before [build [one]](/host/build(1)/report.pdf "Report") ![a\]b](</host/a b.png>) [notes]("./a (2).txt") [home](~/notes.md) [up](../notes.md) [escaped](/host/a\)b.pdf) after"#
    #expect(ArtifactReferences.segments(in: raw) == [
        .text("Before "),
        .attachment(ChatAttachment(name: "report.pdf", path: "/host/build(1)/report.pdf", mimeType: "application/pdf")),
        .text(" "),
        .attachment(ChatAttachment(name: "a b.png", path: "/host/a b.png", mimeType: "image/png")),
        .text(" "),
        .attachment(ChatAttachment(name: "a (2).txt", path: "./a (2).txt", mimeType: "text/plain")),
        .text(" "),
        .attachment(ChatAttachment(name: "notes.md", path: "~/notes.md", mimeType: "text/markdown")),
        .text(" "),
        .attachment(ChatAttachment(name: "notes.md", path: "../notes.md", mimeType: "text/markdown")),
        .text(" "),
        .attachment(ChatAttachment(name: "a)b.pdf", path: "/host/a)b.pdf", mimeType: "application/pdf")),
        .text(" after")
    ])
}

@Test func artifactReferencesKeepStandaloneRefTextPlacementsAndFullPathIdentities() {
    let raw = "First\n\n@file:`/host/Q3 report.pdf`\n\n@file:src/notes.txt\n\n@file:~/notes.txt\n\n@file:/a/result.pdf\n\n@file:/b/result.pdf\n\n@file:/a/result.pdf\nLast"
    #expect(ArtifactReferences.segments(in: raw) == [
        .text("First\n\n"),
        .attachment(ChatAttachment(name: "Q3 report.pdf", path: "/host/Q3 report.pdf", mimeType: "application/pdf")),
        .text("\n\n"),
        .attachment(ChatAttachment(name: "notes.txt", path: "src/notes.txt", mimeType: "text/plain")),
        .text("\n\n"),
        .attachment(ChatAttachment(name: "notes.txt", path: "~/notes.txt", mimeType: "text/plain")),
        .text("\n\n"),
        .attachment(ChatAttachment(name: "result.pdf", path: "/a/result.pdf", mimeType: "application/pdf")),
        .text("\n\n"),
        .attachment(ChatAttachment(name: "result.pdf", path: "/b/result.pdf", mimeType: "application/pdf")),
        .text("\n\n"),
        .attachment(ChatAttachment(name: "result.pdf", path: "/a/result.pdf", mimeType: "application/pdf")),
        .text("\nLast")
    ])
    let cards = ArtifactReferences.segments(in: raw).compactMap { part -> ChatAttachment? in
        if case let .attachment(value) = part { return value }; return nil
    }
    #expect(cards.suffix(3).map(\.id) == ["/a/result.pdf", "/b/result.pdf", "/a/result.pdf"])
}

@Test func artifactReferencesPreserveUnsupportedAndMalformedSourceFixtures() throws {
    let url = try #require(Bundle.module.url(forResource: "preserved-text", withExtension: "json", subdirectory: "Fixtures/ArtifactReferences"))
    let examples = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
    for text in examples {
        #expect(ArtifactReferences.segments(in: text) == [.text(text)], "Preserve: \(text)")
    }
    #expect(ArtifactReferences.segments(in: "").isEmpty)
}

@Test func artifactReferencesStreamingCompletionAndDisplayMetadata() {
    let partial = #"Report: [download](</host/Q3 report.pdf>"#
    #expect(ArtifactReferences.segments(in: partial) == [.text(partial)])
    #expect(ArtifactReferences.segments(in: partial + ")") == [
        .text("Report: "),
        .attachment(ChatAttachment(name: "Q3 report.pdf", path: "/host/Q3 report.pdf", mimeType: "application/pdf"))
    ])
    let cases: [(String, ChatAttachment)] = [
        (#"MEDIA:`/host/a b.pdf`"#, ChatAttachment(name: "a b.pdf", path: "/host/a b.pdf", mimeType: "application/pdf")),
        (#"@file:"./a b.txt""#, ChatAttachment(name: "a b.txt", path: "./a b.txt", mimeType: "text/plain")),
        (#"@file:'../a b.txt'"#, ChatAttachment(name: "a b.txt", path: "../a b.txt", mimeType: "text/plain")),
        ("file://localhost/host/%E6%97%A5%E6%9C%AC.pdf", ChatAttachment(name: "日本.pdf", path: "/host/日本.pdf", mimeType: "application/pdf")),
        ("MEDIA:/host/Dockerfile", ChatAttachment(name: "Dockerfile", path: "/host/Dockerfile")),
        (#"[unknown](/host/file.unknown-botto-artifact)"#, ChatAttachment(name: "file.unknown-botto-artifact", path: "/host/file.unknown-botto-artifact")),
        (#"[backslash](/host/a\b.pdf)"#, ChatAttachment(name: #"a\b.pdf"#, path: #"/host/a\b.pdf"#, mimeType: "application/pdf")),
        (#"[percent](/host/100%20literal.pdf)"#, ChatAttachment(name: "100%20literal.pdf", path: "/host/100%20literal.pdf", mimeType: "application/pdf"))
    ]
    for (text, expected) in cases { #expect(ArtifactReferences.segments(in: text) == [.attachment(expected)]) }
}

@Test func artifactReferencesQuotedRefTextRetainsLiteralFilenamePunctuation() {
    let raw = #"@file:"/host/Alice's [final] report.pdf""#
    #expect(ArtifactReferences.segments(in: raw) == [
        .attachment(ChatAttachment(name: "Alice's [final] report.pdf", path: "/host/Alice's [final] report.pdf", mimeType: "application/pdf"))
    ])
    let escaped = #"[download](/host/a\"b.pdf)"#
    #expect(ArtifactReferences.segments(in: escaped) == [
        .attachment(ChatAttachment(name: #"a"b.pdf"#, path: #"/host/a"b.pdf"#, mimeType: "application/pdf"))
    ])
}
