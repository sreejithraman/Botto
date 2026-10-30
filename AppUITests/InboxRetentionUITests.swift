import XCTest

final class InboxRetentionUITests: XCTestCase {
    @MainActor func testHiddenInboxKeepsScroll() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--performance-demo", "--reduce-motion"]
        app.launch()
        let list = app.scrollViews["bot-inbox"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Your bots"].exists)
        XCTAssertFalse(app.textFields["Search bots"].exists)
        XCTAssertFalse(app.buttons["All bots"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Needs you ·")).firstMatch.exists)
        for _ in 0..<3 { list.swipeUp() }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bot-row-performance-bot-"))
        let visibleRows = rows.allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.minY > 150 && $0.frame.maxY < list.frame.maxY - 60
        }
        let landmark = try XCTUnwrap(visibleRows.first)
        let row = try XCTUnwrap(visibleRows.last)
        XCTAssertNotEqual(landmark.identifier, row.identifier)
        // Opening marks a row read and can move it; track a row above it.
        let identifier = landmark.identifier, originalY = landmark.frame.minY
        row.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        WorkspaceNavigation.browseBots(in: app, expectedBotRow: identifier)
        let restored = app.buttons[identifier]
        XCTAssertTrue(restored.isHittable)
        XCTAssertLessThan(abs(restored.frame.minY - originalY), 5)
        XCTAssertFalse(app.buttons["workspace-return-to-conversation"].exists)
        XCTAssertFalse(restored.isSelected)
    }

    @MainActor func testRevealedInboxShowsReplyAndReopeningKeepsDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--performance-demo", "--reduce-motion"]
        app.launch()
        let pinnedScout = app.buttons["pinned-bot-scout"]
        XCTAssertTrue(pinnedScout.waitForExistence(timeout: 10))
        pinnedScout.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Inventory refresh proof")
        app.buttons["Send message"].tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label ENDSWITH %@", "Performance stream 1 complete.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        composer.tap(); composer.typeText("Keep this local draft")
        WorkspaceNavigation.browseBots(in: app)
        WorkspaceNavigation.revealBot("bot-row-scout", in: app, maximumSwipes: 60)
        let row = app.buttons["bot-row-scout"]
        XCTAssertTrue(row.isHittable)
        XCTAssertTrue(row.label.contains("Word 0."))
        XCTAssertFalse(row.isSelected)
        row.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Keep this local draft")
    }
}
