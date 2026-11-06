import Foundation
import Testing
@testable import BottoCore

@Test(arguments: [
    ("clip.mov", "video/quicktime"),
    ("book.epub", "application/epub+zip"),
    ("backup.tar.gz", "application/x-gzip"),
    ("notes.md", "text/markdown"),
])
func filesKeepTheirNameAndTypeWhateverTheirKind(name: String, mime: String) throws {
    let prepared = try HermesAttachment.prepare(data: Data([1, 2, 3]), filename: name, mime: "application/octet-stream")
    #expect(prepared.name == name)
    #expect(prepared.mime == mime)
    #expect(prepared.data == Data([1, 2, 3]))
    #expect(!prepared.image)
}

@Test func aFileWithoutAnExtensionKeepsTheTypeItsSourceReported() throws {
    let reported = try HermesAttachment.prepare(data: Data([1]), filename: "README", mime: "text/plain")
    #expect(reported.name == "README" && reported.mime == "text/plain")
    let unknown = try HermesAttachment.prepare(data: Data([1]), filename: "payload", mime: "application/octet-stream")
    #expect(unknown.mime == "application/octet-stream")
}

@Test func vectorImagesStayFilesBecauseOnlyRasterImagesCanBeReencoded() throws {
    let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)
    let prepared = try HermesAttachment.prepare(data: svg, filename: "logo.svg", mime: "image/svg+xml")
    #expect(!prepared.image)
    #expect(prepared.name == "logo.svg" && prepared.mime == "image/svg+xml" && prepared.data == svg)
}

@Test func damagedImagesExplainTheReadFailureInsteadOfBlamingTheChat() {
    #expect(throws: HermesServiceError.unreadableImage) {
        try HermesAttachment.prepare(data: Data([0, 1, 2, 3]), filename: "broken.png", mime: "image/png")
    }
    let message = HermesServiceError.unreadableImage.localizedDescription
    #expect(!message.localizedCaseInsensitiveContains("chat"))
}

@Test func filenamesThatCouldEscapeTheHostDirectoryStayRejected() {
    for name in ["a/b.txt", "a\\b.txt", "..", ".", "line\nbreak.txt", ""] {
        #expect(throws: HermesServiceError.invalidAttachment) {
            try HermesAttachment.prepare(data: Data([1]), filename: name, mime: "text/plain")
        }
    }
}
