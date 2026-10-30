import XCTest

final class ScheduledHandoffUITests: XCTestCase {
    @MainActor func testCollapsedEventDetailsAndUsefulReplyInLightAndDark() throws {
        continueAfterFailure = false
        for appearance in ["Light", "Dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--demo", "--automation-demo", "-botto.appearance", appearance.lowercased()]
            app.launch()
            XCTAssertTrue(app.buttons["pinned-bot-milo"].waitForExistence(timeout: 8))
            app.buttons["pinned-bot-milo"].tap()
            let details = app.descendants(matching: .any).matching(identifier: "scheduled-details-scheduled-check").firstMatch
            XCTAssertTrue(details.waitForExistence(timeout: 5))
            XCTAssertTrue(details.label.contains("Mac service incident diagnosis"))
            XCTAssertFalse(app.staticTexts["work-details-section-0-part-0"].exists)
            XCTAssertFalse(app.staticTexts["[SILENT]"].exists)
            XCTAssertTrue(app.staticTexts["The service recovered and is healthy. No restart is needed. I’ll keep monitoring it."].exists)
            XCTAssertTrue(app.buttons["Allow once"].exists)
            let collapsed = XCTAttachment(screenshot: app.screenshot())
            collapsed.name = "scheduled-collapsed-" + appearance
            collapsed.lifetime = .keepAlways; add(collapsed)
            details.tap()
            let raw = app.staticTexts["work-details-section-0-part-0"]
            XCTAssertTrue(raw.waitForExistence(timeout: 5))
            let firstSection = app.staticTexts["work-details-section-0-part-0"]
            XCTAssertTrue(firstSection.isHittable)
            XCTAssertTrue(firstSection.label.hasPrefix("[Cronjob \"Mac service incident diagnosis\" output —"))
            XCTAssertTrue(firstSection.label.contains("\"ack\":\"inspection only\""))
            app.buttons["work-details-copy-scheduled-check"].tap()
            XCTAssertTrue(app.buttons["work-details-copy-scheduled-check"].label.contains("Copied"))
            let expanded = XCTAttachment(screenshot: app.screenshot())
            expanded.name = "scheduled-details-" + appearance
            expanded.lifetime = .keepAlways; add(expanded)
            dismissDetailsSheet(app)
            XCTAssertTrue(details.exists)
            XCTAssertFalse(raw.exists)
            app.terminate()
        }
    }

    @MainActor func testEventAndDetailsAtAccessibilityTextSize() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--automation-demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["bot-row-milo"].waitForExistence(timeout: 8))
        app.buttons["bot-row-milo"].tap()
        let details = app.descendants(matching: .any).matching(identifier: "scheduled-details-scheduled-check").firstMatch
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        for _ in 0..<8 {
            let window = app.frame
            let viewport = transcript.frame.intersection(window)
            XCTAssertFalse(viewport.isNull || viewport.isInfinite)
            XCTAssertGreaterThan(viewport.width, 0)
            XCTAssertGreaterThan(viewport.height, 0)
            let target = details.exists ? details.frame : .null
            if details.isHittable && target.intersection(viewport).height >= 44 { break }
            let towardOlder = target.isNull || target.midY < viewport.midY
            let x = viewport.minX + viewport.width * 0.2
            let fromY = viewport.minY + viewport.height * (towardOlder ? 0.05 : 0.95)
            let toY = viewport.minY + viewport.height * (towardOlder ? 0.95 : 0.05)
            let root = app.coordinate(withNormalizedOffset: .zero)
            let from = root.withOffset(CGVector(dx: x - window.minX, dy: fromY - window.minY))
            let to = root.withOffset(CGVector(dx: x - window.minX, dy: toY - window.minY))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(details.isHittable)
        XCTAssertGreaterThanOrEqual(details.frame.height, 44)
        XCTAssertGreaterThanOrEqual(details.frame.intersection(transcript.frame.intersection(app.frame)).height, 44)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "scheduled-accessibility-xxxl"; capture.lifetime = .keepAlways; add(capture)
        details.tap()
        XCTAssertTrue(app.staticTexts["work-details-section-0-part-0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Close"].exists)
        XCTAssertTrue(app.buttons["work-details-copy-scheduled-check"].isHittable)
    }
    @MainActor func testQuietLiveHandoffPreservesReadingPositionAndReplyOffersLatest() async throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["automation", "automation-reply"] {
            try Data().write(to: directory.appendingPathComponent(name + ".hold"))
        }
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--automation-live-demo"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.buttons["pinned-bot-milo"].waitForExistence(timeout: 8))
        app.buttons["pinned-bot-milo"].tap()
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        transcript.swipeDown(); transcript.swipeDown()
        let anchor = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Monitoring history ")).allElementsBoundByIndex.first { $0.isHittable }
        let landmark = try XCTUnwrap(anchor)
        let y = landmark.frame.minY
        try FileManager.default.removeItem(at: directory.appendingPathComponent("automation.hold"))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("automation.delivered").path)
        }, object: nil)], timeout: 10)
        // Allow layout and inventory refresh to settle before checking for a jump.
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(landmark.frame.minY, y, accuracy: 4)
        XCTAssertFalse(app.buttons["Latest messages"].exists)
        XCTAssertFalse(app.staticTexts["[SILENT]"].exists)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("automation-reply.hold"))
        XCTAssertTrue(app.buttons["Latest messages"].waitForExistence(timeout: 5))
        XCTAssertEqual(landmark.frame.minY, y, accuracy: 4)
        app.buttons["Latest messages"].tap()
        XCTAssertTrue(app.staticTexts["The service needs your attention."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "scheduled-details-scheduled-check").firstMatch.exists)
    }

    @MainActor func testQuietLiveEventDoesNotMoveBottomAndDetailsSheetSurvivesReply() async throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["automation", "automation-reply"] { try Data().write(to: directory.appendingPathComponent(name + ".hold")) }
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--automation-live-demo"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.buttons["pinned-bot-milo"].waitForExistence(timeout: 8))
        app.buttons["pinned-bot-milo"].tap()
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Monitoring history 23.")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertTrue(last.isHittable)
        let y = last.frame.minY
        try FileManager.default.removeItem(at: directory.appendingPathComponent("automation.hold"))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("automation.delivered").path)
        }, object: nil)], timeout: 10)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(last.frame.minY, y, accuracy: 4)
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        let details = app.descendants(matching: .any).matching(identifier: "scheduled-details-scheduled-check").firstMatch
        for _ in 0..<3 where !details.isHittable { transcript.swipeUp() }
        XCTAssertTrue(details.isHittable)
        details.tap()
        let raw = app.staticTexts["work-details-section-0-part-0"]
        XCTAssertTrue(raw.waitForExistence(timeout: 5))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("automation-reply.hold"))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(raw.exists)
        XCTAssertFalse(app.buttons["Close"].exists)
        dismissDetailsSheet(app)
        XCTAssertTrue(transcript.exists)
    }

    @MainActor func testToolsProcessesAndQueuedUpdatesShareAReadableSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--attribution-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["pinned-bot-milo"].waitForExistence(timeout: 8))
        app.buttons["pinned-bot-milo"].tap()
        let transcript = app.collectionViews["chat-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["[SILENT]"].exists)
        let tools = app.buttons["work-details-work-one"]
        for _ in 0..<6 where !tools.isHittable { transcript.swipeDown() }
        XCTAssertTrue(tools.isHittable)
        tools.tap()
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Close"].exists)
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The service is healthy.")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        let metadata = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\"exit_code\": 0")).firstMatch
        XCTAssertTrue(metadata.exists)
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

        let process = app.buttons["notification-details-process-result"]
        for _ in 0..<6 where !process.isHittable { transcript.swipeUp() }
        XCTAssertTrue(process.isHittable)
        XCTAssertFalse(process.label.contains("/usr/bin"))
        process.tap()
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["work-details-copy-process-result"].exists)
        dismissDetailsSheet(app)

        app.buttons["queued-messages-toggle"].tap()
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "work-details-copy-")).firstMatch.exists)
        dismissDetailsSheet(app)
        XCTAssertTrue(transcript.exists)
        XCTAssertFalse(app.staticTexts["[SILENT]"].exists)
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
