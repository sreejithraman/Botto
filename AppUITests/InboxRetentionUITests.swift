import XCTest

final class InboxRetentionUITests: XCTestCase {
    @MainActor func testSearchJumpsToAnOlderMatchInsideATallMessage() {
        assertSearchRevealsOlderMatch(keepingDraft: true)
    }

    @MainActor func testSearchJumpFromBotsOpensTheExactOlderMessage() {
        assertSearchRevealsOlderMatch(keepingDraft: false)
    }

    @MainActor private func assertSearchRevealsOlderMatch(keepingDraft: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion", "--search-navigation-proof"]
        if !keepingDraft { app.launchArguments += ["-botto.appearance", "dark"] }
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        let composer = app.descendants(matching: .any)["chat-composer"]
        let draft = keepingDraft ? "Keep my draft while I find an older message" : ""
        if keepingDraft {
            app.buttons["bot-row-canvas"].tap()
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            composer.tap(); composer.typeText(draft)
            WorkspaceNavigation.browseBots(in: app)
        }
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Copper lantern checkpoint")
        let result = app.buttons["library-message-search-deep-user-match"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()

        let transcript = app.descendants(matching: .any)["chat-transcript"]
        let message = app.descendants(matching: .any)["transcript-message-search-deep-user-match"]
        let text = message.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Copper lantern checkpoint")).firstMatch
        let visibleMatch = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                guard transcript.exists, composer.exists, composer.isEnabled,
                      (composer.value as? String ?? "") == draft else { return false }
                let viewport = transcript.frame.intersection(CGRect(x: app.frame.minX, y: app.frame.minY,
                    width: app.frame.width, height: max(0, composer.frame.minY - app.frame.minY)))
                return RenderedTranscriptText.line("Copper lantern", in: text,
                    viewport: viewport, app: app) != nil &&
                    RenderedTranscriptText.line("checkpoint", in: text, viewport: viewport, app: app) != nil
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleMatch], timeout: 15), .completed,
            "The actual matching glyphs must be visible without a corrective swipe; exposing the tall message's top is insufficient.")
        XCTAssertTrue(app.buttons["chat-picker-button"].label.contains("Canvas"))
        let tail = app.descendants(matching: .any)["transcript-message-search-history-tail"]
        XCTAssertFalse(tail.exists && tail.isHittable, "Opening the origin at its newest message is not a successful match jump.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Older Search match visible inside a tall native message"
        screenshot.lifetime = .keepAlways; add(screenshot)

        let latest = app.buttons["Latest messages"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        latest.tap()
        XCTAssertTrue(tail.waitForExistence(timeout: 5))
        XCTAssertTrue(tail.isHittable)
        XCTAssertEqual(composer.value as? String ?? "", draft)
    }

    @MainActor func testSearchPresentsReadableMessagesAndArtifactPreviews() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let recent = app.buttons["library-chat-Weekend plan"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        XCTAssertTrue(recent.label.contains("Milo"))
        let recentImage = XCTAttachment(screenshot: app.screenshot())
        recentImage.name = "Search recent chats with bot avatars"; recentImage.lifetime = .keepAlways; add(recentImage)
        search.tap(); search.typeText("chart.png")
        let image = app.buttons["library-search-artifact-chart.png"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertTrue(image.label.contains("Canvas"))
        let imageResult = XCTAttachment(screenshot: app.screenshot())
        imageResult.name = "Search artifact image result"; imageResult.lifetime = .keepAlways; add(imageResult)
        image.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifact-preview"].waitForExistence(timeout: 10))
        app.buttons["artifact-done"].tap()
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "chart.png".count) + "small project update")
        let message = app.buttons["library-message-canvas-request"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains("You"))
        XCTAssertTrue(message.label.contains("small project update"))
        let match = XCTAttachment(screenshot: app.screenshot())
        match.name = "Search matching message in chat styling"; match.lifetime = .keepAlways; add(match)
        message.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(app.buttons["chat-picker-button"].label.contains("Canvas"))
    }

    @MainActor func testLibraryReaderOpensAnEditableOriginatingChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Artifacts"].tap()
        let file = app.buttons["library-artifact-chart.png"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        let openChat = app.buttons["library-open-chat"]
        XCTAssertTrue(openChat.waitForExistence(timeout: 10))
        openChat.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        let editable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { composer.exists && composer.isEnabled && composer.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [editable], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["chat-picker-button"].label.contains("Canvas"))
        XCTAssertFalse(app.tabBars.buttons["Artifacts"].isHittable)
        composer.tap()
        composer.typeText("Draft from my artifact")
        XCTAssertEqual(composer.value as? String, "Draft from my artifact")
    }

    @MainActor func testSearchBotResultOpensAnUnselectedBot() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Canvas")
        let result = app.buttons["library-bot-canvas"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(app.buttons["chat-picker-button"].label.contains("Canvas"))
    }

    @MainActor func testLibraryTabsKeepDraftAndOpenTheMatchingChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Bots"].exists)
        XCTAssertTrue(app.tabBars.buttons["Artifacts"].exists)
        XCTAssertTrue(app.tabBars.buttons["Search"].exists)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        app.buttons["bot-row-milo"].tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Artifacts"].isHittable)
        composer.tap()
        composer.typeText("Keep this while I browse outputs")
        WorkspaceNavigation.browseBots(in: app)
        app.tabBars.buttons["Artifacts"].tap()
        XCTAssertTrue(app.scrollViews["artifact-library"].waitForExistence(timeout: 10))
        let file = app.buttons["library-artifact-chart.png"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifact-preview"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["artifact-actions"].waitForExistence(timeout: 10))
        app.buttons["artifact-done"].tap()
        app.tabBars.buttons["Bots"].tap()
        app.buttons["bot-row-milo"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Keep this while I browse outputs")
        WorkspaceNavigation.browseBots(in: app)
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Weekend plan")
        let result = app.buttons["library-chat-Weekend plan"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(WorkspaceNavigation.displaysChat("Weekend plan", in: app))
    }

    @MainActor func testLibraryReferencesAndInlineOutputSharing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Artifacts"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Artifacts"].tap()
        let list = app.scrollViews["artifact-library"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let visual = app.buttons["library-artifact-HTML preview"]
        XCTAssertTrue(visual.waitForExistence(timeout: 10))
        visual.tap()
        XCTAssertTrue(app.buttons["Show HTML source"].waitForExistence(timeout: 10))
        ArtifactOutputActions.open(in: app)
        ArtifactOutputActions.action("artifact-share", label: "Share", in: app).tap()
        ArtifactOutputActions.dismissShare(in: app)
        XCTAssertTrue(app.buttons["artifact-done"].isHittable)
        app.buttons["artifact-done"].tap()
        let filters = app.descendants(matching: .any)["library-filters"].firstMatch
        XCTAssertTrue(filters.isHittable)
        filters.tap()
        ArtifactOutputActions.action("Include references", label: "Include references", in: app).tap()
        let reference = app.buttons["library-artifact-notes.txt"]
        for _ in 0..<5 where !reference.isHittable { list.swipeUp() }
        XCTAssertTrue(reference.isHittable)
        XCTAssertTrue(reference.label.contains("Reference"))
    }

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
