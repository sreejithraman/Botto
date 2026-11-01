import Foundation
import Testing
@testable import BottoCore

@Test func artifactReferenceProvenanceDistinguishesDeliveryFromMention() {
    let parts = ArtifactReferences.parts(in: "MEDIA:/host/report.pdf\n@file:./notes.txt\n[Source](/host/source.csv) file:///host/chart.png")
    let references = parts.compactMap { part -> (String, ArtifactReferences.Provenance)? in
        if case .attachment(let attachment, let provenance) = part { return (attachment.path, provenance) }
        return nil
    }
    #expect(references.map(\.0) == ["/host/report.pdf", "./notes.txt", "/host/source.csv", "/host/chart.png"])
    #expect(references.map(\.1) == [.delivered, .delivered, .referenced, .referenced])
}

@Test func artifactDiscoverySeparatesOutputsFromFilesUsedInChat() {
    let messages: [ChatMessage] = [
        .init(id: "input", role: .user, text: "Use my source", attachments: [
            .init(name: "source.csv", path: "/host/source.csv", mimeType: "text/csv")]),
        .init(id: "reply", role: .assistant,
              text: "MEDIA:/host/report.pdf\n@file:./notes.txt\n[Source](/host/source.csv) file:///host/chart.png",
              attachments: [.init(name: "slides.pptx", path: "/host/slides.pptx")])
    ]
    let artifacts = ArtifactDiscovery.artifacts(in: messages)
    let outputs = artifacts.filter { $0.category == .output }
    let references = artifacts.filter { $0.category == .reference }
    #expect(Set(outputs.map(\.title)) == ["report.pdf", "notes.txt", "slides.pptx"])
    #expect(Set(references.map(\.title)) == ["source.csv", "chart.png"])
    #expect(artifacts.first { $0.title == "report.pdf" }?.kind == .document)
    #expect(artifacts.first { $0.title == "chart.png" }?.kind == .image)
    #expect(artifacts.allSatisfy { $0.attachment != nil && $0.block == nil })
}

@Test func artifactDiscoveryIncludesCompleteVisualsAndFilePreviews() throws {
    let message = ChatMessage(id: "visuals", role: .assistant, text: """
    ```html
    <h1>Quarterly report</h1>
    ```
    ```svg
    <svg></svg>
    ```
    ```mermaid
    flowchart LR
    A --> B
    ```
    ::preview{file="./dashboard.html" height="360"}
    ```swift
    let example = "MEDIA:/host/example.pdf"
    ```
    ```html
    <p>Unfinished
    """)
    let artifacts = ArtifactDiscovery.artifacts(in: [message])
    #expect(artifacts.count == 4)
    #expect(artifacts.allSatisfy { $0.category == .output })
    #expect(artifacts.filter { $0.kind == .preview }.count == 3)
    #expect(artifacts.compactMap(\.attachment).map(\.path) == ["./dashboard.html"])
    #expect(artifacts.contains { $0.searchableText.contains("Quarterly report") })
    let inline = try #require(artifacts.first { $0.block?.previewFormat == .html })
    let edited = ArtifactDiscovery.artifacts(in: [.init(id: "visuals", role: .assistant,
        text: "```html\n<h1>Revised report</h1>\n```")])
    #expect(edited.first?.id != inline.id)
}

@Test func artifactDiscoveryKeepsNewestOutputAndItsAttachmentMetadata() throws {
    let final = ChatAttachment(name: "Final report", path: "/host/report.bin", mimeType: "application/pdf", byteCount: 42)
    let messages: [ChatMessage] = [
        .init(id: "final", role: .assistant, text: "MEDIA:/host/report.bin", timestamp: Date(timeIntervalSince1970: 20), attachments: [final]),
        .init(id: "draft", role: .assistant, text: "MEDIA:/host/report.bin", timestamp: Date(timeIntervalSince1970: 10)),
        .init(id: "source", role: .assistant, text: "[Read it](/host/report.bin)", timestamp: Date(timeIntervalSince1970: 30))
    ]
    let artifacts = ArtifactDiscovery.artifacts(in: messages)
    #expect(artifacts.count == 1)
    let report = try #require(artifacts.first)
    #expect(report.messageID == "final")
    #expect(report.timestamp == Date(timeIntervalSince1970: 20))
    #expect(report.category == .output)
    #expect(report.attachment == final)
    #expect(report.title == "Final report")
}

@Test func artifactDiscoveryKeepsExamplesHiddenMessagesAndToolTrafficOut() {
    let ordinary = ChatMessage(id: "ordinary", role: .assistant, text: """
    `MEDIA:/host/inline.pdf`

        MEDIA:/host/indented.pdf

    ```text
    MEDIA:/host/fenced.pdf
    ```

    [Website](https://example.com/file.pdf)
    MEDIA:"/host/unfinished.pdf
    MEDIA:/host/delivered.pdf
    """)
    let hiddenAttachment = ChatAttachment(name: "hidden.txt", path: "/host/hidden.txt")
    let messages: [ChatMessage] = [
        ordinary,
        .init(id: "hidden", role: .assistant, text: "MEDIA:/host/hidden.txt", displayKind: "hidden"),
        .init(id: "silent", role: .assistant, text: "MEDIA:/host/silent.txt", isSilent: true),
        .init(id: "machinery", role: .user, text: "MEDIA:/host/machinery.txt", attachments: [hiddenAttachment], displayKind: "process_complete"),
        .init(id: "tool", role: .tool, text: "Downloaded /host/cache.pdf\nExample: `MEDIA:/host/log.pdf`", toolName: "terminal"),
        .init(id: "system", role: .system, text: "MEDIA:/host/system.pdf", attachments: [hiddenAttachment]),
        .init(id: "user-example", role: .user, text: "Please emit MEDIA:/host/user-example.pdf")
    ]
    let artifacts = ArtifactDiscovery.artifacts(in: messages)
    #expect(artifacts.map(\.title) == ["delivered.pdf"])
    #expect(artifacts.first?.category == .output)
}

@Test func artifactDiscoveryKeepsExactUnicodePathAndMessageIdentities() throws {
    let composed = "/host/caf\u{00e9}.pdf"
    let decomposed = "/host/cafe\u{0301}.pdf"
    let files = ArtifactDiscovery.artifacts(in: [.init(id: "paths", role: .assistant,
        text: "MEDIA:\(composed)\nMEDIA:\(decomposed)")])
    #expect(files.count == 2)
    #expect(Set(files.map(\.id)).count == 2)
    #expect(Set(files.compactMap(\.attachment).map { Data($0.path.utf8) }).count == 2)

    let first = try #require(ArtifactDiscovery.artifacts(in: [.init(id: "caf\u{00e9}", role: .assistant,
        text: "```html\n<p>Visual</p>\n```")]).first)
    let second = try #require(ArtifactDiscovery.artifacts(in: [.init(id: "cafe\u{0301}", role: .assistant,
        text: "```html\n<p>Visual</p>\n```")]).first)
    #expect(first.id != second.id)
}

@Test func artifactDiscoveryIncludesUserFileCardsAsReferences() {
    let messages: [ChatMessage] = [
        .init(id: "upload", role: .user, text: "Read my notes.\n\n@file:`/host/Q3 notes.txt`"),
        .init(id: "example", role: .user, text: "An example:\n\n```text\n@file:/host/example.txt\n```"),
        .init(id: "assistant", role: .assistant, text: "MEDIA:/host/result.pdf")
    ]
    let artifacts = ArtifactDiscovery.artifacts(in: messages)
    #expect(artifacts.filter { $0.category == .reference }.map(\.title) == ["Q3 notes.txt"])
    #expect(artifacts.filter { $0.category == .output }.map(\.title) == ["result.pdf"])
}

@Test func artifactDiscoveryUsesStrongOutputMetadataFromProducerTools() {
    let messages: [ChatMessage] = [
        .init(id: "generated", role: .tool, text: #"{"output_path":"/host/cover.png","results":[{"saved_to":"./report.pdf"}],"path":"/host/input.png","stdout":"MEDIA:/host/log.pdf"}"#, toolName: "image_generate"),
        .init(id: "read", role: .tool, text: #"{"output_path":"/host/read.png","path":"/host/input.png","stdout":"/host/used.txt"}"#, toolName: "file_read"),
        .init(id: "generic", role: .tool, text: #"{"path":"/host/generic.png","stdout":{"output_path":"/host/stdout.png"}}"#, toolName: "image_generate"),
        .init(id: "logs", role: .tool, text: "Saved result:\n{\"output_path\":\"/host/log.png\"}", toolName: "image_generate"),
        .init(id: "code", role: .tool, text: "```json\n{\"output_path\":\"/host/example.png\"}\n```", toolName: "image_generate"),
        .init(id: "url", role: .tool, text: #"{"generated_file":"https://example.com/remote.png","artifact_path":"//server/share/file.png"}"#, toolName: "image_generate")
    ]
    let artifacts = ArtifactDiscovery.artifacts(in: messages)
    #expect(Set(artifacts.compactMap(\.attachment).map(\.path)) == ["/host/cover.png", "./report.pdf"])
    #expect(artifacts.allSatisfy { $0.category == .output && $0.block == nil && $0.messageID == "generated" })
}

@Test func artifactDiscoveryRecognizesExplicitTerminalDeliveries() {
    let messages: [ChatMessage] = [
        .init(id: "delivery", role: .tool, text: "MEDIA:/host/result.custom", toolName: "terminal"),
        .init(id: "ordinary", role: .tool, text: "Read /host/source.pdf\n[Source](/host/source.pdf)\nfile:///host/source.pdf", toolName: "terminal"),
        .init(id: "example", role: .tool, text: "```text\nMEDIA:/host/example.pdf\n```", toolName: "terminal"),
        .init(id: "inline", role: .tool, text: "Example: `MEDIA:/host/inline.pdf`", toolName: "terminal"),
        .init(id: "read", role: .tool, text: "MEDIA:/host/read.pdf", toolName: "read_file")
    ]
    let artifacts = ArtifactDiscovery.artifacts(in: messages)
    #expect(artifacts.compactMap(\.attachment).map(\.path) == ["/host/result.custom"])
    #expect(artifacts.allSatisfy { $0.category == .output && $0.messageID == "delivery" })
}

@Test func artifactDiscoveryRecognizesWrappedTerminalDeliveriesWithoutScrapingLogs() {
    let messages: [ChatMessage] = [
        .init(id: "stdout", role: .tool, text: #"{"stdout":"MEDIA:/host/café.custom","exit_code":0}"#, toolName: "terminal"),
        .init(id: "output", role: .tool, text: #"{"output":{"stdout":"MEDIA:/host/cafe\u0301.custom"}}"#, toolName: "terminal"),
        .init(id: "mention", role: .tool, text: #"{"stdout":"Read /host/input.pdf\n[Source](/host/input.pdf)"}"#, toolName: "terminal"),
        .init(id: "example", role: .tool, text: #"{"stdout":"Example: `MEDIA:/host/example.pdf`","args":{"stdout":"MEDIA:/host/argument.pdf"},"stderr":"MEDIA:/host/error.pdf"}"#, toolName: "terminal"),
        .init(id: "failed", role: .tool, text: #"{"stdout":"MEDIA:/host/failed.pdf","exit_code":1}"#, toolName: "terminal")
    ]
    let artifacts = ArtifactDiscovery.artifacts(in: messages)
    #expect(artifacts.compactMap(\.attachment).map { Data($0.path.utf8) } == [Data("/host/café.custom".utf8), Data("/host/cafe\u{0301}.custom".utf8)])
    #expect(artifacts.allSatisfy { $0.category == .output })
}

@Test func artifactDiscoveryUsesStrongOutputMetadataWithoutProducerNames() {
    let messages: [ChatMessage] = [
        .init(id: "output", role: .tool, text: #"{"generated_file":"/host/generated.png","results":[{"output_file":"./report.pdf"}]}"#, toolName: "design_asset"),
        .init(id: "inputs", role: .tool, text: #"{"input":{"generated_file":"/host/input.png"},"source":{"output_file":"/host/source.pdf"},"args":{"output_path":"/host/requested.pdf"},"arguments":{"saved_to":"/host/argument.pdf"},"logs":{"output_file":"/host/log.pdf"},"stdout":{"output_path":"/host/stdout.pdf"},"example":{"output_path":"/host/example.pdf"},"path":"/host/generic.pdf"}"#, toolName: "design_asset"),
        .init(id: "producer-inputs", role: .tool, text: #"{"input":{"output_path":"/host/producer-input.pdf"},"args":{"generated_file":"/host/producer-args.pdf"}}"#, toolName: "image_generate"),
        .init(id: "failed", role: .tool, text: #"{"success":false,"output_file":"/host/failed.pdf"}"#, toolName: "design_asset"),
        .init(id: "hidden", role: .tool, text: #"{"output_file":"/host/hidden.pdf"}"#, toolName: "design_asset", displayKind: "hidden"),
        .init(id: "silent", role: .tool, text: #"{"output_file":"/host/silent.pdf"}"#, toolName: "design_asset", isSilent: true)
    ]
    let artifacts = ArtifactDiscovery.artifacts(in: messages)
    #expect(Set(artifacts.compactMap(\.attachment).map(\.path)) == ["/host/generated.png", "./report.pdf"])
    #expect(artifacts.allSatisfy { $0.category == .output && $0.messageID == "output" })
}

@Test func artifactDiscoveryRejectsFailedResultsButKeepsSuccessfulTerminalOutputMetadata() {
    var messages: [ChatMessage] = [
        .init(id: "terminal", role: .tool, text: #"{"output_file":"/host/terminal.pdf","exit_code":0}"#, toolName: "terminal")
    ]
    let failures = [#""success":false"#, #""ok":false"#, #""is_error":true"#, #""status":"error""#, #""error":"write failed""#, #""exit_code":2"#]
    for (index, failure) in failures.enumerated() {
        messages.append(.init(id: "failed-\(index)", role: .tool,
            text: "{\(failure),\"output_path\":\"/host/failed-\(index).pdf\"}", toolName: "image_generate"))
        messages.append(.init(id: "terminal-failed-\(index)", role: .tool,
            text: "{\(failure),\"stdout\":\"MEDIA:/host/terminal-failed-\(index).pdf\"}", toolName: "terminal"))
    }
    messages.append(.init(id: "nested-failure", role: .tool,
        text: #"{"results":[{"success":false,"output_file":"/host/nested-failed.pdf"}]}"#, toolName: "design_asset"))
    let artifacts = ArtifactDiscovery.artifacts(in: messages)
    #expect(artifacts.compactMap(\.attachment).map(\.path) == ["/host/terminal.pdf"])
    #expect(artifacts.allSatisfy { $0.category == .output })
}
