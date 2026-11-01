import Foundation
import Testing
import UIKit
import BottoCore
@testable import Botto

@Suite(.serialized) @MainActor struct ArtifactTextReaderTests {
    @Test func unicodeTextKeepsExactCharactersAndLineEndings() throws {
        let original = "Canvas demo\r\n  Review café 🦊\n下一段\tunchanged"
        let bytes = Data(original.utf8)
        #expect(try ArtifactPlainText.decode(bytes, mimeType: "text/plain").get() == original)
    }
    @Test(arguments: [
        ([0xEF, 0xBB, 0xBF, 0x41], "A"),
        ([0xFF, 0xFE, 0x41, 0x00, 0x3D, 0xD8, 0x80, 0xDE], "A🚀"),
        ([0xFE, 0xFF, 0x00, 0x41, 0xD8, 0x3D, 0xDE, 0x80], "A🚀"),
        ([0xFF, 0xFE, 0, 0, 0x41, 0, 0, 0, 0x80, 0xF6, 1, 0], "A🚀"),
        ([0, 0, 0xFE, 0xFF, 0, 0, 0, 0x41, 0, 1, 0xF6, 0x80], "A🚀")
    ])
    func unicodeBOMsSelectExplicitEncoding(bytes: [UInt8], expected: String) throws {
        #expect(try ArtifactPlainText.decode(Data(bytes), mimeType: "text/plain").get() == expected)
    }

    @Test func declaredEncodingAndUnsupportedBytesHaveVisibleFailurePolicy() throws {
        #expect(try ArtifactPlainText.decode(Data([0x41, 0]), mimeType: "text/plain; charset=\"UTF-16LE\"").get() == "A")
        #expect(throws: ArtifactPlainText.Failure.unsupportedEncoding) {
            try ArtifactPlainText.decode(Data("ASCII".utf8), mimeType: "text/plain; charset=windows-1252").get()
        }
        for bytes: [UInt8] in [[0xFF], [0xFF, 0xFE, 0x00], [0xFF, 0xFE, 0x00, 0xD8], [0x41, 0]] {
            #expect(throws: ArtifactPlainText.Failure.invalidText) {
                try ArtifactPlainText.decode(Data(bytes), mimeType: "text/plain").get()
            }
        }
    }

    @Test func onlyPlainFormatsUseNativeTextWithoutParsingHTML() {
        for (name, mime) in [("notes.txt", "text/plain"), ("source.swift", "application/octet-stream"), ("data.json", "application/json"), ("rows.csv", "text/csv"), ("plain", "text/plain")] {
            #expect(ArtifactPlainText.supports(filename: name, mimeType: mime))
        }
        for (name, mime) in [("page.html", "text/plain"), ("notes.txt", "text/html"), ("rich.rtf", "text/rtf"), ("chart.svg", "image/svg+xml"), ("report.pdf", "application/pdf"), ("photo.png", "image/png")] {
            #expect(!ArtifactPlainText.supports(filename: name, mimeType: mime))
        }
    }

    @Test func nativeTextIsReadOnlySelectableAndKeepsPassageAndSelectionAcrossReflow() async throws {
        let text = (0..<100).map { "Paragraph \($0): café 🦊 " + String(repeating: "Readable words stay in this passage. ", count: 8) }.joined(separator: "\n\n")
        let bytes = Data(text.utf8)
        let file = try await ArtifactPreviewFile.write(.init(data: bytes, filename: "notes.txt", mimeType: "text/plain"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); window.rootViewController = host
        let reader = ArtifactTextReaderView(file: file)
        host.view.addSubview(reader); reader.frame = CGRect(x: 0, y: 0, width: 380, height: 329)
        window.makeKeyAndVisible(); reader.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let native = try #require(reader.subviews.compactMap { $0 as? UITextView }.first)
        #expect(native.text == text && !native.isEditable && native.isSelectable && native.dataDetectorTypes.isEmpty)
        let passage = (text as NSString).range(of: "Paragraph 60:")
        let selected = NSRange(location: passage.location, length: passage.length)
        native.selectedRange = selected
        if let manager = native.textLayoutManager, let content = manager.textContentManager {
            manager.ensureLayout(for: content.documentRange)
        }
        let passagePosition = try #require(native.position(from: native.beginningOfDocument, offset: passage.location))
        native.setContentOffset(CGPoint(x: 0, y: native.caretRect(for: passagePosition).minY), animated: false)
        reader.layoutIfNeeded()
        let position = try #require(native.closestPosition(to: CGPoint(x: 21, y: native.bounds.minY + 1)))
        let originalOffset = native.offset(from: native.beginningOfDocument, to: position)
        #expect(originalOffset >= passage.location && originalOffset < passage.location + 400,
                "The fixture must actually scroll to the middle of the document before resizing")
        let originalY = native.caretRect(for: position).minY - native.contentOffset.y
        for size in [CGSize(width: 867, height: 559), CGSize(width: 466, height: 220), CGSize(width: 380, height: 559), CGSize(width: 380, height: 329)] {
            reader.frame.size = size
            reader.layoutIfNeeded()
            reader.show(file) // Ordinary representable update with the same file.
            #expect(native.text == text && native.selectedRange == selected)
            #expect(abs(native.caretRect(for: position).minY - native.contentOffset.y - originalY) < 2,
                    Comment(rawValue: "size=\(size) caret=\(native.caretRect(for: position)) offset=\(native.contentOffset) initialY=\(originalY) contentSize=\(native.contentSize) bounds=\(native.bounds)"))
        }
        let diskBytes = try Data(contentsOf: file.url)
        #expect(file.data == bytes && diskBytes == bytes)
    }

}
