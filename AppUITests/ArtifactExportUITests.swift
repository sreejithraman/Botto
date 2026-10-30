import XCTest
import UIKit

final class ArtifactExportUITests: XCTestCase {
    @MainActor func testCompletedPreviewAndExportRemainUsableAcrossBackgroundRecovery() {
        let app = openArtifact("notes.txt")
        let expected = "All sample files stay on this device."
        let text = app.textViews.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", expected, expected)).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        app.activate()
        assertOutputActions(in: app)
        XCTAssertTrue(text.exists)
        XCTAssertFalse(app.descendants(matching: .any)["artifact-error"].exists)
        tapOutput("artifact-share", label: "Share", in: app)
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 5))
        ArtifactOutputActions.dismissShare(in: app)
        assertOutputActions(in: app)
        capture("Completed local file after background recovery", app: app)
    }

    @MainActor private func openArtifact(_ filename: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        WorkspaceNavigation.revealBot("bot-row-canvas", in: app)
        let canvas = app.buttons["bot-row-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.tap()
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let card = app.buttons["Open " + filename].firstMatch
        for _ in 0..<8 {
            if card.exists && card.isHittable { break }
            transcript.swipeDown()
        }
        XCTAssertTrue(card.exists && card.isHittable)
        card.tap()
        assertOutputActions(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["artifact-error"].exists)
        return app
    }

    @MainActor private func outputAction(_ identifier: String, label: String, in app: XCUIApplication) -> XCUIElement {
        ArtifactOutputActions.action(identifier, label: label, in: app)
    }

    @MainActor private func openOutputMenu(in app: XCUIApplication) {
        ArtifactOutputActions.open(in: app)
    }

    @MainActor private func assertOutputActions(in app: XCUIApplication) {
        ArtifactOutputActions.assertAvailable(in: app)
    }

    @MainActor private func tapOutput(_ identifier: String, label: String, in app: XCUIApplication) {
        openOutputMenu(in: app)
        let action = outputAction(identifier, label: label, in: app)
        XCTAssertTrue(action.waitForExistence(timeout: 5) && action.isHittable && action.isEnabled)
        action.tap()
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor func testPDFPreviewZoomAndShareCancellation() {
        let app = openArtifact("report.pdf")
        let text = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Canvas demo")).firstMatch
        let displayed = text.waitForExistence(timeout: 15)
        capture("PDF loaded state", app: app)
        XCTAssertTrue(displayed, "Quick Look must display the actual PDF page, not merely accept its file type.")
        capture("PDF before zoom", app: app)
        let original = text.frame
        app.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(text.frame.width, original.width * 1.25, "The native PDF page must actually zoom.")
        capture("PDF after zoom", app: app)
        tapOutput("artifact-share", label: "Share", in: app)
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 5))
        capture("Native PDF Share", app: app)
        ArtifactOutputActions.dismissShare(in: app)
        assertOutputActions(in: app)
        XCTAssertTrue(text.exists)
        app.buttons["artifact-done"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testTextPreviewSaveCancellationAndConnectionReplacement() {
        let app = openArtifact("notes.txt")
        let text = app.textViews.containing(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "All sample files stay on this device.", "All sample files stay on this device.")).firstMatch
        let displayed = text.waitForExistence(timeout: 15)
        capture("Native text preview", app: app)
        XCTAssertTrue(displayed, "The text reader must render the downloaded UTF-8 content.")

        tapOutput("artifact-save", label: "Save to Files", in: app)
        let picker = readyFilesPicker(in: app, captureName: "Native Save to Files")
        cancelFilesPicker(in: app, picker: picker)
        assertOutputActions(in: app)
        capture("Text preview after Save cancellation", app: app)
        XCTAssertTrue(text.exists)
        XCTAssertFalse(app.alerts["Export Failed"].exists)

        // Native cancellation must release this output session. Reopening must
        // present a usable exporter before the external route wins.
        tapOutput("artifact-save", label: "Save to Files", in: app)
        _ = readyFilesPicker(in: app, captureName: "Reopened Save before connection replacement")
        assertConnectionReplacement(in: app)
        XCTAssertFalse(filesPicker(in: app).exists, "Connection replacement must close the child exporter.")
        XCTAssertFalse(app.textFields["DOCPicker.filenameTextField"].exists)
    }

    @MainActor func testSaveToFilesAndReopenSavedOriginal() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The durable export fixture writes only to an owned CI simulator.")
        #else
        // The check script supplies a proof UUID for independent readback;
        // other runs generate their own unique filename.
        let requestedID = ProcessInfo.processInfo.environment["BOTTO_ARTIFACT_EXPORT_PROOF_ID"] ?? UUID().uuidString
        let proofID = UUID(uuidString: requestedID)
        XCTAssertNotNil(proofID, "BOTTO_ARTIFACT_EXPORT_PROOF_ID must be a fresh UUID for this CI run.")
        let stem = "botto-artifact-export-proof-\(try XCTUnwrap(proofID).uuidString.lowercased())"
        let filename = stem + ".txt"
        let identity = XCTAttachment(string: filename)
        identity.name = "Artifact export proof filename"
        identity.lifetime = .keepAlways
        add(identity)

        let app = openArtifact("notes.txt")
        tapOutput("artifact-save", label: "Save to Files", in: app)
        let picker = readyFilesPicker(in: app, captureName: "Files picker before unique filename", requiresFilename: true)
        let filenameField = app.textFields["DOCPicker.filenameTextField"]
        let originalName = try XCTUnwrap(filenameField.value as? String)
        XCTAssertFalse(originalName.isEmpty)
        // Tap the current field's trailing edge to put the insertion point after
        // its short default name. Do not depend on changing edit-menu labels.
        filenameField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        filenameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalName.count) + stem)
        capture("Files picker with unique export filename", app: app)
        XCTAssertEqual(filenameField.value as? String, stem)

        let save = picker.buttons["Save"]
        let canSave = save.waitForExistence(timeout: 5)
        capture("Files picker before actual Save", app: app)
        XCTAssertTrue(canSave && save.isEnabled && save.isHittable)
        save.tap()
        let dismissed = picker.waitForNonExistence(timeout: 5)
        capture("Preview after actual Files Save", app: app)
        XCTAssertTrue(dismissed, "The native exporter must dismiss after Save.")
        XCTAssertFalse(app.textFields["DOCPicker.filenameTextField"].exists)
        XCTAssertFalse(app.alerts["Export Failed"].exists)
        assertOutputActions(in: app)

        app.buttons["artifact-done"].tap()
        let closed = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch.waitForExistence(timeout: 5)
        capture("Closed preview after Files Save", app: app)
        XCTAssertTrue(closed)
        app.terminate()
        reopenSavedOriginalInFiles(stem: stem)
        // Retain this run's file for independent byte readback.
        #endif
    }

    @MainActor private func filesPicker(in app: XCUIApplication) -> XCUIElement {
        app.otherElements.matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage,"
        )).firstMatch
    }

    @MainActor private func readyFilesPicker(in app: XCUIApplication, captureName: String,
                                            requiresFilename: Bool = false) -> XCUIElement {
        let picker = filesPicker(in: app)
        let field = app.textFields["DOCPicker.filenameTextField"]
        // The local provider starts after the exporter appears. Wait for its
        // actual root and Save action. Cancellation does not require a filename
        // editor; the durable rename/save test independently requires that field.
        let hasPicker = picker.waitForExistence(timeout: 10)
        let save = picker.buttons["Save"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { save.exists && save.isHittable && save.isEnabled }
        }, object: nil)
        let hasSave = hasPicker && XCTWaiter.wait(for: [ready], timeout: 5) == .completed
        let hasField = !requiresFilename || (hasPicker && field.waitForExistence(timeout: 20))
        capture(captureName, app: app)
        XCTAssertTrue(hasPicker && hasSave && hasField,
                      "Require the actual local Files root and usable Save; durable renaming also requires its filename editor.")
        return picker
    }

    @MainActor private func cancelFilesPicker(in app: XCUIApplication, picker: XCUIElement) {
        let cancel = app.buttons["Cancel"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else {
            // CI's native sheet has no Cancel button. Start in its top margin,
            // above the navigation bar and scrollable file list, using live bounds.
            let frame = picker.frame
            capture("Files picker before sheet dismissal gesture", app: app)
            XCTAssertFalse(frame.isNull || frame.isInfinite || frame.isEmpty)
            XCTAssertGreaterThan(frame.height, 100)
            let start = picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
            let end = picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let dismissed = picker.waitForNonExistence(timeout: 5)
        capture("Artifact preview after native picker cancellation", app: app)
        XCTAssertTrue(dismissed, "Canceling the native picker must dismiss it.")
        XCTAssertFalse(app.textFields["DOCPicker.filenameTextField"].exists)
    }

    @MainActor private func reopenSavedOriginalInFiles(stem: String) {
        // Bundle identity confirmed from the installed Files.app Info.plist.
        // Open from the provider's durable directory rather than Recents search,
        // whose separate index may not include a file just saved by another app.
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.activate()
        let foreground = files.wait(for: .runningForeground, timeout: 5)
        capture("Files app opened independently", app: files)
        XCTAssertTrue(foreground)
        let browse = files.tabBars.buttons["Browse"].firstMatch
        let oldPreview = files.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].firstMatch
        // Files can resume the previous run's Quick Look document. Its Browse
        // tab still exists underneath, but cannot be tapped until preview closes.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                (browse.exists && browse.isHittable) || (oldPreview.exists && oldPreview.isHittable)
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        capture("Files before Browse", app: files)
        if oldPreview.exists && oldPreview.isHittable {
            oldPreview.tap()
            XCTAssertTrue(oldPreview.waitForNonExistence(timeout: 5))
            capture("Files after closing its previous document", app: files)
        }
        let hasBrowse = browse.waitForExistence(timeout: 5)
        XCTAssertTrue(hasBrowse && browse.isHittable)
        // Retapping the selected Browse tab navigates from the provider directory
        // back to Locations. Keep an already visible directory in place.
        if !browse.isSelected { browse.tap() }
        let localLocation = files.cells["DOC.sidebar.item.On My iPhone"].firstMatch
        if localLocation.exists && localLocation.isHittable { localLocation.tap() }
        let localFiles = filesPicker(in: files)
        let hasLocalFiles = localFiles.waitForExistence(timeout: 5)
        capture("Files local provider before reopening saved original", app: files)
        XCTAssertTrue(hasLocalFiles)
        // Files presents documents as collection cells, with extension display
        // controlled by the system. Match this run's complete stem in that cell.
        let savedFile = localFiles.collectionViews.cells.containing(NSPredicate(
            format: "label CONTAINS %@", stem)).firstMatch
        let visibleFile = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { savedFile.exists && savedFile.isHittable }
        }, object: nil)
        let found = XCTWaiter.wait(for: [visibleFile], timeout: 15)
        capture("Unique saved original in Files local provider", app: files)
        XCTAssertEqual(found, .completed, "Files must expose this run's exact saved output for opening.")
        savedFile.tap()
        let title = files.navigationBars.matching(NSPredicate(format: "identifier CONTAINS %@", stem)).firstMatch
        let expected = "Canvas demo\n\nDraft, review, then publish. All sample files stay on this device.\n"
        let text = files.textViews.matching(NSPredicate(format: "value == %@", expected)).firstMatch
        let loaded = text.waitForExistence(timeout: 15)
        capture("Saved original reopened through Files", app: files)
        XCTAssertTrue(loaded, "Files must render the entire exact text, including both newlines and the final newline.")
        XCTAssertEqual(text.value as? String, expected)
        XCTAssertTrue(title.exists, "The reopened preview must identify this run's unique filename.")
    }

    @MainActor func testImagePreviewAndShareConnectionReplacement() {
        let app = openArtifact("chart.png")
        // The fixture is a three-bar image. Count its known colors in actual
        // rendered pixels, so a supported-type check or empty QL view cannot pass.
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { self.hasChartPixels(app.screenshot().image) }
        }, object: nil)
        let result = XCTWaiter.wait(for: [rendered], timeout: 15)
        capture("Native chart image preview", app: app)
        XCTAssertEqual(result, .completed, "Quick Look must display all three bars.")
        tapOutput("artifact-share", label: "Share", in: app)
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 5))
        capture("Native image Share", app: app)
        assertConnectionReplacement(in: app)
    }

    @MainActor private func assertConnectionReplacement(in app: XCUIApplication) {
        // Open through the system in the existing scene, not app.open/launch.
        XCUIDevice.shared.system.open(URL(string:
            "botto://hermes/connect?url=https%3A%2F%2Freplacement.example")!)
        let replaced = app.navigationBars["Connect Hermes"].waitForExistence(timeout: 8)
        capture("Connection review replaces preview and native children", app: app)
        XCTAssertTrue(replaced)
        XCTAssertFalse(app.buttons["artifact-save"].exists)
        XCTAssertFalse(app.buttons["artifact-share"].exists)
        XCTAssertFalse(filesPicker(in: app).exists)
        XCTAssertFalse(app.textFields["DOCPicker.filenameTextField"].exists)
        XCTAssertFalse(app.cells["Copy"].exists, "Connection replacement must retire native Share too.")
        let review = app.buttons["Review destination"]
        for _ in 0..<8 {
            if review.exists && review.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(review.exists && review.isHittable)
        review.tap()
        let reviewed = app.staticTexts["https://replacement.example"].waitForExistence(timeout: 5)
        capture("Connection replaces artifact presentation", app: app)
        XCTAssertTrue(reviewed)
        app.buttons["Cancel"].tap()
        let returned = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch.waitForExistence(timeout: 5)
        capture("Transcript after canceling replacement connection", app: app)
        XCTAssertTrue(returned)
        XCTAssertFalse(app.buttons["artifact-save"].exists, "The retired preview must not reappear.")
    }

    private func hasChartPixels(_ image: UIImage) -> Bool {
        guard let source = image.cgImage else { return false }
        let width = source.width, height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        let colors = [(34, 197, 94), (99, 102, 241), (56, 189, 248)]
        var counts = [0, 0, 0]
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            for (index, color) in colors.enumerated() {
                if abs(Int(bytes[offset]) - color.0) <= 10 &&
                    abs(Int(bytes[offset + 1]) - color.1) <= 10 &&
                    abs(Int(bytes[offset + 2]) - color.2) <= 10 { counts[index] += 1 }
            }
        }
        return counts.allSatisfy { $0 > 100 }
    }

}
