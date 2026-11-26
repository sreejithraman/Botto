import XCTest

final class WorkDetailsUITests: XCTestCase {
    @MainActor func testToolsShareAReadableSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--work-details-demo"]
        app.launch()
        WorkspaceNavigation.openSpace("milo", in: app)
        let transcript = app.collectionViews["chat-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        // The closed Spaces drawer stays in the XCUITest tree, so transcript queries stay inside the transcript.
        let tools = transcript.buttons["work-details-work-one"].firstMatch
        for _ in 0..<6 where !tools.isHittable { transcript.swipeDown() }
        XCTAssertTrue(tools.isHittable)
        tools.tap()
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Close"].exists)
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The service is healthy.")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        // Tool rows open collapsed; their formatted output is one deliberate expansion away.
        app.buttons["Expand terminal"].tap()
        let metadata = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\"exit_code\": 0")).firstMatch
        XCTAssertTrue(metadata.waitForExistence(timeout: 5))
        XCTAssertFalse(content.label.contains("\\n"))
        XCTAssertTrue(app.buttons["work-details-copy-work-one"].exists)
        let formatted = XCTAttachment(screenshot: app.screenshot())
        formatted.name = "work-details-formatted-tool-sheet"; formatted.lifetime = .keepAlways; add(formatted)
        let mediumY = grabber.frame.minY
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: top, withVelocity: .slow, thenHoldForDuration: 0.1)
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            grabber.exists && grabber.frame.minY < mediumY - 100
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 4), .completed)
        let large = XCTAttachment(screenshot: app.screenshot())
        large.name = "work-details-expanded-tool-sheet"; large.lifetime = .keepAlways; add(large)
        dismissDetailsSheet(app)
        XCTAssertTrue(transcript.exists)
    }

    @MainActor private func dismissDetailsSheet(_ app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0.1)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: grabber)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }
}
