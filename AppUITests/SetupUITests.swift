import XCTest
import UIKit

final class SetupUITests: XCTestCase {
    @MainActor private func launch(largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        if largeText {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["Connect your Hermes"].waitForExistence(timeout: 10))
        reach(app.buttons["Connect your Hermes"], in: app)
        app.buttons["Connect your Hermes"].tap()
        reach(app.buttons["Review destination"], in: app)
        return app
    }

    @MainActor private func reach(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<12 {
            if element.isHittable { return }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func dismissPromptPreview(in app: XCUIApplication) {
        let title = app.navigationBars["Setup prompt"]
        XCTAssertFalse(app.buttons["Done"].exists)
        for _ in 0..<2 {
            if !title.exists { break }
            let grabber = app.buttons.matching(NSPredicate(format: "label == %@", "Sheet Grabber")).firstMatch
            XCTAssertTrue(grabber.waitForExistence(timeout: 5))
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            if title.waitForNonExistence(timeout: 2) { break }
        }
        XCTAssertFalse(title.exists)
        XCTAssertFalse(app.descendants(matching: .any)["setup-prompt-text"].exists)
    }

    @MainActor private func addressField(in app: XCUIApplication) -> XCUIElement {
        let label = "Hermes server address or connection code"
        for _ in 0..<8 {
            if app.textFields[label].exists { return app.textFields[label] }
            if app.textViews[label].exists { return app.textViews[label] }
            app.swipeDown()
        }
        XCTFail("The server address input must remain available.")
        return app.textFields[label]
    }

    @MainActor private func assertPastedPrompt(in app: XCUIApplication) {
        let paste = app.buttons["Paste"]
        reach(paste, in: app, towardTop: true)
        paste.tap()
        let field = addressField(in: app)
        let pasted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", HermesSetupPrompt.text), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 5), .completed)
        XCTAssertEqual(field.value as? String, HermesSetupPrompt.text)
    }

    @MainActor private func copyFromShareSheet(in app: XCUIApplication) {
        let share = app.otherElements["ShareSheet.RemoteContainerView"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        let caption = share.otherElements["LP.CaptionBar.BottomCaption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(caption.label.hasPrefix("Help me connect Botto,"))
        let copy = share.cells.matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        if !copy.waitForExistence(timeout: 10) {
            let viewMore = share.cells.matching(NSPredicate(format: "label == %@", "View More")).firstMatch
            XCTAssertTrue(viewMore.waitForExistence(timeout: 5))
            viewMore.tap()
        }
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        capture("Native setup share contents", in: app)
        UIPasteboard.general.string = "Before native setup share export"
        copy.tap()
    }

    @MainActor func testCopyAndRepeatCopyExportCompletePrompt() {
        for repeated in [false, true] {
            let app = launch()
            let copy = app.buttons["setup-copy-prompt"]
            reach(copy, in: app)
            if repeated { copy.tap() }
            UIPasteboard.general.string = repeated ? "Before repeated export" : "Before first export"
            copy.tap()
            XCTAssertTrue(app.staticTexts["Prompt copied. Paste it into your chat with Hermes."].exists)
            capture(repeated ? "Setup prompt copied again" : "Setup prompt copied", in: app)
            assertPastedPrompt(in: app)
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.buttons["Connect your Hermes"].waitForExistence(timeout: 5))
        }
    }

    @MainActor func testSharePreviewAndRetainedAddress() {
        let app = launch()
        let preview = app.buttons["Preview setup prompt"]
        reach(preview, in: app)
        preview.tap()
        XCTAssertTrue(app.navigationBars["Setup prompt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["setup-prompt-text"].label.hasPrefix("Help me connect Botto,"))
        dismissPromptPreview(in: app)

        let field = addressField(in: app)
        reach(field, in: app, towardTop: true)
        field.tap()
        field.typeText("https://hermes.example.com")

        let share = app.buttons["setup-share-prompt"]
        reach(share, in: app)
        share.tap()
        capture("Native setup share sheet", in: app)
        copyFromShareSheet(in: app)
        XCTAssertEqual(field.value as? String, "https://hermes.example.com")

        let review = app.buttons["Review destination"]
        reach(review, in: app, towardTop: true)
        review.tap()
        XCTAssertTrue(app.staticTexts["https://hermes.example.com"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Change address"].exists)
        capture("Destination remains under review", in: app)
        app.buttons["Change address"].tap()
        XCTAssertEqual(field.value as? String, "https://hermes.example.com")
        assertPastedPrompt(in: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Connect your Hermes"].waitForExistence(timeout: 5))
    }

    @MainActor func testSetupActionsAtLargestTextSize() {
        let app = launch(largeText: true)
        let copy = app.buttons["setup-copy-prompt"]
        reach(copy, in: app)
        UIPasteboard.general.string = "Before large-text setup export"
        copy.tap()
        XCTAssertTrue(app.staticTexts["Prompt copied. Paste it into your chat with Hermes."].exists)
        capture("Setup copy at accessibility XXXL", in: app)
        let preview = app.buttons["Preview setup prompt"]
        reach(preview, in: app)
        preview.tap()
        XCTAssertTrue(app.navigationBars["Setup prompt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["setup-prompt-text"].label.hasPrefix("Help me connect Botto,"))
        capture("Setup preview at accessibility XXXL", in: app)
        dismissPromptPreview(in: app)
        let share = app.buttons["setup-share-prompt"]
        reach(share, in: app)
        share.tap()
        copyFromShareSheet(in: app)
        assertPastedPrompt(in: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Connect your Hermes"].waitForExistence(timeout: 5))
    }

    @MainActor func testReturnedLinkStillRequiresDestinationReview() {
        let app = launch()
        XCUIDevice.shared.system.open(URL(string:
            "botto://hermes/connect?url=https%3A%2F%2Freplacement.example")!)
        let field = addressField(in: app)
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value == %@", "botto://hermes/connect?url=https%3A%2F%2Freplacement.example"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 5), .completed)
        XCTAssertEqual(field.value as? String, "botto://hermes/connect?url=https%3A%2F%2Freplacement.example")
        XCTAssertFalse(app.buttons["Change address"].exists)
        let review = app.buttons["Review destination"]
        reach(review, in: app, towardTop: true)
        review.tap()
        XCTAssertTrue(app.staticTexts["https://replacement.example"].waitForExistence(timeout: 5))
        capture("Returned link waits for sign-in", in: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Connect your Hermes"].waitForExistence(timeout: 5))
    }
    @MainActor func testReturnedLinkClosesPreviewSheetAndKeepsReviewExplicit() {
        let app = launch()
        let preview = app.buttons["Preview setup prompt"]
        reach(preview, in: app)
        preview.tap()
        XCTAssertTrue(app.descendants(matching: .any)["setup-prompt-text"].exists)
        XCUIDevice.shared.system.open(URL(string:
            "botto://hermes/connect?url=https%3A%2F%2Freplacement.example")!)
        let field = addressField(in: app)
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value == %@", "botto://hermes/connect?url=https%3A%2F%2Freplacement.example"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 5), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["setup-prompt-text"].exists)
        XCTAssertFalse(app.buttons["Change address"].exists)
        let review = app.buttons["Review destination"]
        reach(review, in: app, towardTop: true)
        review.tap()
        XCTAssertTrue(app.staticTexts["https://replacement.example"].waitForExistence(timeout: 5))
    }

    @MainActor func testPreviewSheetDismissalPreservesAddressAndCanReopen() {
        let app = launch()
        let field = addressField(in: app)
        field.tap()
        field.typeText("https://hermes.example.com")
        let preview = app.buttons["Preview setup prompt"]
        reach(preview, in: app)
        preview.tap()
        let sheetTitle = app.navigationBars["Setup prompt"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5))
        capture("Setup prompt bottom sheet", in: app)
        dismissPromptPreview(in: app)
        XCTAssertTrue(sheetTitle.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "https://hermes.example.com")
        reach(preview, in: app)
        preview.tap()
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5))
        dismissPromptPreview(in: app)
        XCTAssertTrue(sheetTitle.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "https://hermes.example.com")
    }

    @MainActor func testScanActionOpensScannerFromAddressRow() {
        let app = launch()
        app.buttons["Scan connection QR"].tap()
        XCTAssertTrue(app.navigationBars["Connect to Hermes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Review Address"].exists)
    }

}
