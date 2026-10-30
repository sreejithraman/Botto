// Transcript fixtures adapted from Hermex HermesChatAttachmentTests.swift, revision
// 47809f2cd1f07bcbe592ee8960cf9c63e88b734c. Copyright (c) 2026 Uzair Ansar.
// MIT; see LICENSES/Hermex.txt.
import Foundation
import Testing
@testable import BottoCore

@Test func attachmentPresentationHidesCapturedFileContextWithoutChangingHistory() {
    // Captured live-file-sent.png Files upload on Hermes authority 4a0eaf79.
    // The header/fence also follows agent/context_references.py:_format_file_reference.
    let path = "/private/tmp/hot-runtime-current/hermes/profiles/ember/attachments/90DCC6B6-8DF5-4FDC-B68D-A46DD9298EA3-hot-probe.txt"
    let raw = "Read this\n\n@file:\(path)\n\n--- Attached Context ---\n\n"
        + "📄 @file:\(path) (16 tokens)\n```\n"
        + "Hot mobile file-provider verification. Disposable local sample.\n\n```"
    let message = ChatMessage(id: "stored:row:1", role: .user, text: raw)

    let shown = AttachmentPresentation.display(message)

    #expect(shown.text == "Read this")
    #expect(shown.attachments == [ChatAttachment(name: "hot-probe.txt", path: path, mimeType: "text/plain")])
    #expect(message.text == raw)
    #expect(message.attachments.isEmpty)
}

@Test func attachmentPresentationRestoresDonorTranscriptCards() {
    // Hermex testTheTranscriptShowsChipsAndNoHostPathsAfterARebuild, lines 310–332.
    let uuid = "0F6A3C1E-8D2B-4F7A-9C3D-5E6F7A8B9C0D"
    let image = "/home/u/.hermes/images/dashboard_20261004_031500_ab12cd34_photo.jpg"
    let notes = "/home/u/.hermes/attachments/\(uuid)-notes.txt"
    let report = "/home/u/.hermes/attachments/\(uuid)-Q3 report.pdf"
    let quoted = "@file:`\(report)`"
    let raw = "Compare these\n\n"
        + "[The user attached an image: dashboard_20261004_031500_ab12cd34_photo.jpg]\n"
        + "[Examine it with the vision_analyze tool using image_url: \(image)]\n\n"
        + "@file:\(notes)\n\n\(quoted)\n\n"
        + "--- Context Warnings ---\n- \(quoted): path is outside the allowed workspace"
    let shown = AttachmentPresentation.display(ChatMessage(id: "history", role: .user, text: raw))
    #expect(shown.text == "Compare these")
    #expect(shown.attachments.map(\.name) == ["photo.jpg", "notes.txt", "Q3 report.pdf"])
    #expect(shown.attachments.map(\.path) == [image, notes, report])
    #expect(shown.attachments.map(\.mimeType) == ["image/jpeg", "text/plain", "application/pdf"])
}

@Test func attachmentPresentationReadsWholePlainAndQuotedBlocks() {
    // Hermex testTheHermesReferenceRuleReadsOnlyWholeReferenceBlocks, lines 289–300.
    let raw = "First\n\n@file:'/h/a b.md'\n\nSecond\n\n"
        + "@file:`/h/0F6A3C1E-8D2B-4F7A-9C3D-5E6F7A8B9C0D-c (1).csv`\n\n"
        + "@file:\"/h/x y.txt\"\n\n@file:/h/plain.txt"
    let shown = AttachmentPresentation.display(ChatMessage(id: "history", role: .user, text: raw))
    #expect(shown.text == "First\n\nSecond")
    #expect(shown.attachments.map(\.name) == ["a b.md", "c (1).csv", "x y.txt", "plain.txt"])
    #expect(shown.attachments.map(\.path) == ["/h/a b.md", "/h/0F6A3C1E-8D2B-4F7A-9C3D-5E6F7A8B9C0D-c (1).csv", "/h/x y.txt", "/h/plain.txt"])
}

@Test func attachmentPresentationReadsTrustedLegacyDonorContext() {
    let raw = "Only files\n\n@file:\"/h/x y.txt\"\n\n--- Attached Context ---\n\n📄 @file:\"/h/x y.txt\"\nsecret text"
    let shown = AttachmentPresentation.display(ChatMessage(id: "legacy", role: .user, text: raw))
    #expect(shown.text == "Only files")
    #expect(shown.attachments.map(\.name) == ["x y.txt"])
}

@Test(arguments: [
    "See @file:src/app.swift line 3\n\n--- not a footer",
    "`@file:/h/example.txt`",
    "> @file:/h/quoted.txt",
    "    @file:/h/indented-code.txt",
    "```text\n\n@file:/h/example.txt\n\n```",
    "~~~text\n\n@file:/h/example.txt\n\n~~~",
    "```text\n\n@file:/h/unclosed-fence.txt",
    "@file:\"/h/unclosed.txt",
    "@file:'/h/mismatched.txt\"",
    "@file:/h/a b.txt",
    "@file:``",
    "@file:https://example.com/file.txt",
    "[The user attached an image: photo.jpg]",
    "[The user attached an image: photo.jpg]\n[Examine it with the vision_analyze tool using image_url: relative/photo.jpg]",
    "[The user attached an image: different.jpg]\n[Examine it with the vision_analyze tool using image_url: /h/photo.jpg]",
    "[image_url]",
    "Explain this\n\n--- Attached Context ---\n\nMy own notes.",
    "Read @folder:src\n\n--- Context Warnings ---\n- @folder:src: path is outside the allowed workspace"
])
func attachmentPresentationPreservesTypedExamplesAndUnknownFormats(_ raw: String) {
    let shown = AttachmentPresentation.display(ChatMessage(id: "typed", role: .user, text: raw))
    #expect(shown.text == raw)
    #expect(shown.attachments.isEmpty)
}

@Test func attachmentPresentationPreservesLiteralFooterEvenWithAFileReference() {
    let suffixes = [
        "--- Attached Context ---\n\nMy own notes.\n\n@file:/h/not-another-upload.txt",
        "--- Attached Context ---\n\n📄 @file:/h/different.txt (3 tokens)\n```\nnotes\n```",
        "--- Context Warnings ---\n- My own warning.",
        "--- Context Warnings ---\n- @file:/h/different.txt: file not found",
        "--- Attached Context ---\n\n📄 @file:/h/real.txt (3 tokens)\n```\nunclosed"
    ]
    for suffix in suffixes {
        let shown = AttachmentPresentation.display(ChatMessage(id: "literal", role: .user,
            text: "Read this\n\n@file:/h/real.txt\n\n" + suffix))
        #expect(shown.text == "Read this\n\n" + suffix)
        #expect(shown.attachments.map(\.path) == ["/h/real.txt"])
    }
}

@Test func attachmentPresentationKeepsCodeExamplesBesideRealReferences() {
    let typed = "Example\n\n```text\n\n@file:/h/example.txt\n\n--- Attached Context ---\n\nliteral\n\n```"
    let shown = AttachmentPresentation.display(ChatMessage(id: "code", role: .user,
        text: typed + "\n\n@file:/h/real.txt"))
    #expect(shown.text == typed)
    #expect(shown.attachments.map(\.name) == ["real.txt"])
}

@Test func attachmentPresentationDeduplicatesOnlyByFullPathAndKeepsOptimisticMetadata() {
    let optimistic = ChatAttachment(name: "Original report", path: "/h/report.pdf", mimeType: "application/pdf")
    let message = ChatMessage(id: "optimistic", role: .user,
        text: "Compare\n\n@file:/h/report.pdf\n\n@file:/other/report.pdf\n\n@file:/other/report.pdf",
        attachments: [optimistic])
    let shown = AttachmentPresentation.display(message)
    #expect(shown.text == "Compare")
    #expect(shown.attachments == [optimistic, ChatAttachment(name: "report.pdf", path: "/other/report.pdf", mimeType: "application/pdf")])
    #expect(message.attachments == [optimistic])
}

@Test func attachmentPresentationStripsOnlyKnownUploadPrefixes() {
    let names = ["0f6a3c1e-8d2b-4f7a-9c3d-5e6f7a8b9c0d-notes.txt", "1234-notes.txt",
                 "not-a-uuid-notes.txt", "0F6A3C1E-8D2B-4F7A-9C3D-ZZZZZZZZZZZZ-notes.txt"]
    let shown = AttachmentPresentation.display(ChatMessage(id: "names", role: .user,
        text: names.map { "@file:/h/" + $0 }.joined(separator: "\n\n")))
    #expect(shown.text.isEmpty)
    #expect(shown.attachments.map(\.name) == ["notes.txt", "1234-notes.txt", "not-a-uuid-notes.txt", "0F6A3C1E-8D2B-4F7A-9C3D-ZZZZZZZZZZZZ-notes.txt"])
}

@Test func attachmentPresentationSupportsWindowsHostPathsWithoutLoadingThem() {
    let raw = #"@file:"C:\work\Q3 report.pdf""# + "\n\n"
        + #"[The user attached an image: photo.png]"# + "\n"
        + #"[Examine it with the vision_analyze tool using image_url: C:\work\photo.png]"#
    let shown = AttachmentPresentation.display(ChatMessage(id: "windows", role: .user, text: raw))
    #expect(shown.text.isEmpty)
    #expect(shown.attachments.map(\.name) == ["Q3 report.pdf", "photo.png"])
    #expect(shown.attachments.map(\.path) == [#"C:\work\Q3 report.pdf"#, #"C:\work\photo.png"#])
    #expect(shown.attachments.map(\.mimeType) == ["application/pdf", "image/png"])
}

@Test(arguments: [ChatMessage.Role.assistant, .system, .tool])
func attachmentPresentationLeavesOtherRolesUnmodified(_ role: ChatMessage.Role) {
    let raw = "@file:/h/report.pdf\n\n--- Attached Context ---\n\n📄 @file:/h/report.pdf (2 tokens)\n```\nnotes\n```"
    let attachment = ChatAttachment(name: "A tool result", path: "/h/result.txt")
    let shown = AttachmentPresentation.display(ChatMessage(id: "other-role", role: role, text: raw, attachments: [attachment]))
    #expect(shown.text == raw)
    #expect(shown.attachments == [attachment])
}

@Test func attachmentPresentationKeepsAvailableImageAttachmentMetadata() {
    // contentText currently flattens image content parts to [image_url], without their URL.
    // Do not infer an image identity from that lossy marker. Already-projected metadata works.
    let photo = ChatAttachment(name: "photo.png", path: "/h/photo.png", mimeType: "image/png")
    let shown = AttachmentPresentation.display(ChatMessage(id: "image", role: .user, text: "Look", attachments: [photo]))
    #expect(shown.text == "Look")
    #expect(shown.attachments == [photo])
}

@Test func attachmentPresentationHidesGeneratedBinaryFileContext() {
    // Hermes authority 4a0eaf79 agent/context_references.py:_binary_reference_block.
    let raw = "Read this\n\n@file:/h/report.pdf\n\n--- Attached Context ---\n\n"
        + "📎 @file:/h/report.pdf (application/pdf, 1.0 KB) — binary file, not inlined as text. "
        + "It is available on disk at `/h/report.pdf`. Use your tools to work with it "
        + "(read or convert it, extract its text, or view/render it as needed); do not tell the user the file type is unsupported."
    let shown = AttachmentPresentation.display(ChatMessage(id: "binary", role: .user, text: raw))
    #expect(shown.text == "Read this")
    #expect(shown.attachments.map(\.name) == ["report.pdf"])
}

@Test func attachmentPresentationHidesCombinedGeneratedWarningsAndContext() {
    let raw = "Read\n\n@file:/h/missing.txt\n\n@file:/h/note.txt\n\n"
        + "--- Context Warnings ---\n- @file:/h/missing.txt: file not found\n\n"
        + "--- Attached Context ---\n\n📄 @file:/h/note.txt (2 tokens)\n```\nhello\n```"
    let shown = AttachmentPresentation.display(ChatMessage(id: "mixed", role: .user, text: raw))
    #expect(shown.text == "Read")
    #expect(shown.attachments.map(\.name) == ["missing.txt", "note.txt"])
}

@Test func attachmentPresentationHidesMultipleGeneratedFileBlocks() {
    let raw = "Compare\n\n@file:/h/note.txt\n\n@file:/h/report.pdf\n\n"
        + "--- Attached Context ---\n\n📄 @file:/h/note.txt (2 tokens)\n```\nhello\n```\n\n"
        + "📎 @file:/h/report.pdf (application/pdf, 1.0 KB) — binary file, not inlined as text. "
        + "It is available on disk at `/h/report.pdf`. Use your tools to work with it."
    let shown = AttachmentPresentation.display(ChatMessage(id: "multiple", role: .user, text: raw))
    #expect(shown.text == "Compare")
    #expect(shown.attachments.map(\.name) == ["note.txt", "report.pdf"])
}

@Test func attachmentPresentationSanitizesExistingCardNamesAndDuplicateIdentities() {
    let uploaded = ChatAttachment(name: "/h/0F6A3C1E-8D2B-4F7A-9C3D-5E6F7A8B9C0D-notes.txt", path: "/h/file", mimeType: "text/plain")
    let message = ChatMessage(id: "optimistic-name", role: .user, text: "Read", attachments: [uploaded, uploaded])
    let shown = AttachmentPresentation.display(message)
    #expect(shown.attachments == [ChatAttachment(name: "notes.txt", path: "/h/file", mimeType: "text/plain")])
    #expect(message.attachments == [uploaded, uploaded])
}
