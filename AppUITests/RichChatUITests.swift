import XCTest

final class RichChatUITests: XCTestCase {
    @MainActor func testCachedRichReplyHasShortReadableInboxLabel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-offline", "--rich-inbox-demo"]
        app.launch()
        WorkspaceNavigation.revealBot("bot-row-canvas", in: app)
        let row = app.buttons["bot-row-canvas"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let label = row.label
        XCTAssertTrue(label.contains("Before the dashboard, here is the plan"), "Unexpected inbox label: \(label)")
        XCTAssertLessThanOrEqual(label.count, 220)
        XCTAssertFalse(label.contains("window.reviews"))
        XCTAssertFalse(label.contains("<!doctype"))
        XCTAssertFalse(label.contains("::preview"))
        XCTAssertTrue(row.isEnabled)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testHostFileDirectiveRendersInteractiveHTMLWithSourceAndExpand() {
        continueAfterFailure = false
        let app = openCanvas()
        let update = app.buttons["Update preview"]
        XCTAssertTrue(update.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Three milestones, loaded from an HTML file."].exists)
        update.tap()
        XCTAssertTrue(app.staticTexts["Preview updated"].waitForExistence(timeout: 3))
        let source = app.buttons.matching(identifier: "Show HTML source").allElementsBoundByIndex.last!
        source.tap()
        XCTAssertTrue(app.buttons["Close HTML source"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Three milestones, loaded from an HTML file.")).firstMatch.exists)
        app.buttons["Close HTML source"].tap()
        app.buttons.matching(identifier: "Expand HTML preview").allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(app.buttons["Close HTML preview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Update preview"].waitForExistence(timeout: 8))
        app.buttons["Update preview"].tap()
        XCTAssertTrue(app.staticTexts["Preview updated"].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Interactive host-file directive in the native expanded preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Close HTML preview"].tap()
    }
    @MainActor func testExpandedHTMLSourceKeepsItsFullTouchTarget() {
        continueAfterFailure = false
        for verticalOffset in [-21.0, 21.0] {
            let app = openCanvas()
            defer { app.terminate() }
            let expansions = app.buttons.matching(identifier: "Expand HTML preview")
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                expansions.allElementsBoundByIndex.contains { $0.isHittable }
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            guard let expand = expansions.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
                XCTFail("The HTML file must expose Expand"); return
            }
            XCTAssertTrue(expand.waitForExistence(timeout: 10))
            expand.tap()
            XCTAssertTrue(app.buttons["Close HTML preview"].waitForExistence(timeout: 3))
            guard let source = app.buttons.matching(identifier: "Show HTML source")
                .allElementsBoundByIndex.first(where: { $0.isHittable }) else {
                XCTFail("The expanded preview must expose Source"); return
            }
            let toolbar = XCTAttachment(screenshot: app.screenshot())
            toolbar.name = "Expanded HTML toolbar before edge tap \(verticalOffset)"
            toolbar.lifetime = .keepAlways; add(toolbar)
            source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: verticalOffset)).tap()
            let close = app.buttons["Close HTML source"]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: verticalOffset)).tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        }
    }

    @MainActor private func openCanvas() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        WorkspaceNavigation.revealBot("bot-row-canvas", in: app)
        let canvas = app.buttons["bot-row-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch.waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func reveal(_ button: XCUIElement, in app: XCUIApplication) {
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        for _ in 0..<8 {
            if button.exists && button.isHittable { return }
            transcript.swipeDown()
        }
        XCTAssertTrue(button.exists && button.isHittable, "The file card must be reachable in the conversation.")
    }

    @MainActor func testFileCardOpensNativePreviewWithExportActions() {
        continueAfterFailure = false
        let app = openCanvas()
        let report = app.buttons["Open report.pdf"]
        reveal(report, in: app)
        report.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifact-preview"].waitForExistence(timeout: 5))
        ArtifactOutputActions.assertAvailable(in: app, timeout: 5)
        XCTAssertFalse(app.descendants(matching: .any)["artifact-error"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Downloaded report in native artifact preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["artifact-done"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch.exists)
    }

    @MainActor func testHTMLStillWorksAfterReadingFilesBelowIt() {
        continueAfterFailure = false
        let app = openCanvas()
        // A reader starts at the newest text and spends time there before
        // scrolling back. Offscreen WebKit throttling must not poison previews.
        Thread.sleep(forTimeInterval: 6)
        let source = app.buttons.matching(identifier: "Show HTML source").firstMatch
        reveal(source, in: app)
        let counter = app.buttons["Add review"]
        XCTAssertTrue(counter.waitForExistence(timeout: 8), "The HTML above the files must render when reached.")
        reveal(counter, in: app)
        let html = app.otherElements["HTML preview"].firstMatch
        // WebKit exposes the number and suffix separately on iOS 26 and as
        // one text element on iOS 27. Require the exact value in either form.
        let zero = html.staticTexts.matching(NSPredicate(format: "label IN %@", ["0", "0 reviews"])).firstMatch
        XCTAssertTrue(zero.waitForExistence(timeout: 3))
        counter.tap()
        let one = html.staticTexts.matching(NSPredicate(format: "label IN %@", ["1", "1 reviews"])).firstMatch
        XCTAssertTrue(one.waitForExistence(timeout: 3))
        XCTAssertTrue(html.staticTexts.matching(NSPredicate(format: "label IN %@", ["reviews", "1 reviews"])).firstMatch.exists)
        source.tap()
        XCTAssertTrue(app.buttons["Close HTML source"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "window.reviews=0")).firstMatch.exists)
        app.buttons["Close HTML source"].tap()
        app.buttons.matching(identifier: "Expand HTML preview").firstMatch.tap()
        XCTAssertTrue(app.buttons["Close HTML preview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add review"].waitForExistence(timeout: 8))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Expanded interactive HTML from the ordinary demo"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Close HTML preview"].tap()
    }
}
