import XCTest
import Vision

/// Public multi-chat workflows. These tests do not select chats through store setters.
final class MultipleChatUITests: XCTestCase {
    @MainActor private func keepScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testWorkingComposerSteersByDefaultAndStopsFromSendButton() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("reply.hold"))
        let app = launch(gateDirectory: directory)
        app.buttons["Keep draft"].tap()
        XCTAssertTrue(app.buttons["Keep draft"].waitForNonExistence(timeout: 5))
        editor(app).tap(); editor(app).typeText("Start a reply")
        app.buttons["Send message"].tap()
        let indicator = app.descendants(matching: .any)["chat-working-indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop response"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat-typing-indicator"].exists)
        editor(app).tap(); editor(app).typeText("Make it shorter")
        app.buttons["Steer message"].tap()
        XCTAssertTrue(revealTranscriptText("Make it shorter", app: app, timeout: 5))
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        transcript.swipeUp(velocity: .slow)
        XCTAssertTrue(app.buttons["Stop response"].exists)
        XCTAssertTrue(indicator.exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Working indicator and composer stop"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["Stop response"].tap()
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Send message"].exists)
        editor(app).tap(); editor(app).typeText("Start again")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 5))
        editor(app).tap(); editor(app).typeText("Keep this draft")
        app.buttons["Steer message"].press(forDuration: 0.7)
        app.buttons["Stop response"].tap()
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor(app).value as? String, "Keep this draft")
    }

    @MainActor func testStopRemainsAvailableWhileSendAwaitsAcknowledgment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("reply.hold"))
        let acknowledgment = directory.appendingPathComponent("send-ack.hold")
        try Data().write(to: acknowledgment)
        let app = launch(gateDirectory: directory)
        editor(app).tap(); editor(app).typeText("Still awaiting acknowledgment")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["Sending…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop response"].isEnabled)
        app.buttons["Stop response"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-typing-indicator"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor(app).value as? String, "Still awaiting acknowledgment")
        try FileManager.default.removeItem(at: acknowledgment)
    }

    @MainActor func testLongPressQueuesDraftAndKeepsCurrentReplyRunning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hold = directory.appendingPathComponent("reply.hold")
        try Data().write(to: hold)
        let app = launch(gateDirectory: directory)
        editor(app).tap(); editor(app).typeText("First prompt")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 5))
        editor(app).tap(); editor(app).typeText("A follow-up for later")
        app.buttons["Steer message"].press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["Queue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Steer"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Steer and Queue menu"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["Queue"].tap()
        XCTAssertTrue(app.buttons["queued-messages-toggle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["queued-messages-toggle"].value as? String, "Collapsed")
        app.buttons["queued-messages-toggle"].tap()
        XCTAssertTrue(app.buttons["queued-message-1"].label.contains("A follow-up for later"))
        XCTAssertFalse(app.staticTexts["Steering: A follow-up for later"].exists)
        XCTAssertTrue(app.buttons["Stop response"].exists)
        try FileManager.default.removeItem(at: hold)
        XCTAssertTrue(app.buttons["Send message"].waitForExistence(timeout: 8))
        let replies = renderedReplyIDs(prefix: "You’ve got the idea.", app: app, timeout: 8)
        XCTAssertEqual(replies.count, 2, "Queue must preserve the first reply and run the follow-up afterwards")
    }

    @MainActor func testLatestMessagesReturnsToVisibleReplyWhileFollowupIsQueued() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hold = directory.appendingPathComponent("performance-stream-1.hold")
        try Data().write(to: hold)
        let app = XCUIApplication()
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        app.launchArguments = ["--demo", "--performance-demo", "--reduce-motion"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        app.launch()
        WorkspaceNavigation.openSpace("scout", in: app)
        let composer = editor(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("Stream")
        app.buttons["Send message"].tap()
        let reply = app.otherElements["transcript-message-performance-reply-1"]
        let words = reply.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Word 19.")).firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 20))
        XCTAssertTrue(words.isHittable, "The held reply must be visible before reading older history.")
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        let swipeStarted = Date.now
        transcript.swipeDown()
        let swipeDuration = Date.now.timeIntervalSince(swipeStarted)
        print("Held-stream history swipe: \(swipeDuration) seconds")
        XCTAssertLessThan(swipeDuration, 10, "Reading history must keep the event loop responsive.")
        transcript.swipeDown()
        composer.tap(); composer.typeText("Later")
        app.buttons["Steer message"].press(forDuration: 0.7)
        app.buttons["Queue"].tap()
        XCTAssertTrue(app.buttons["queued-messages-toggle"].waitForExistence(timeout: 5))
        let latest = app.buttons["Latest messages"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertFalse(words.isHittable)
        latest.tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in words.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed,
                       "Latest must target a rendered reply while the queued echo is hidden.")
        XCTAssertTrue(app.otherElements["chat-typing-indicator"].isHittable,
                      "Latest must also reveal the typing bubble while the reply is held.")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Latest reply with typing bubble and collapsed queue"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor func testQueuedEditSurvivesMessageStartingWhileSaveWaits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reply = directory.appendingPathComponent("reply.hold")
        let replacement = directory.appendingPathComponent("replace-queued.hold")
        try Data().write(to: reply)
        try Data().write(to: replacement)
        let app = launch(gateDirectory: directory)
        editor(app).tap(); editor(app).typeText("Start")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 5))
        editor(app).tap(); editor(app).typeText("Follow-up")
        app.buttons["Steer message"].press(forDuration: 0.7)
        app.buttons["Queue"].tap()
        let toggle = app.buttons["queued-messages-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["edit-queued-message-1"].exists)
        let collapsed = XCTAttachment(screenshot: app.screenshot())
        collapsed.name = "Queue pill collapsed"; collapsed.lifetime = .keepAlways; add(collapsed)
        editor(app).tap(); editor(app).typeText("Keep")
        toggle.tap()
        let editButton = app.buttons["edit-queued-message-1"]
        var previousFrame: CGRect?
        let readyToEdit = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard editButton.exists, editButton.isEnabled, editButton.isHittable else { previousFrame = nil; return false }
            let frame = editButton.frame
            defer { previousFrame = frame }
            return frame.width >= 44 && frame.height >= 44 && frame == previousFrame
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [readyToEdit], timeout: 5), .completed)
        editButton.tap()
        let queuedEditor = app.textViews["queued-message-editor"]
        XCTAssertTrue(queuedEditor.waitForExistence(timeout: 5))
        let editViewport = app.scrollViews["queued-message-edit-scroll"]
        XCTAssertTrue(editViewport.exists)
        XCTAssertTrue(queuedEditor.isHittable)
        XCTAssertGreaterThanOrEqual(queuedEditor.frame.intersection(editViewport.frame).height, 44)
        XCTAssertGreaterThan(editViewport.frame.height, 0)
        XCTAssertGreaterThanOrEqual(editViewport.frame.minY, app.navigationBars.firstMatch.frame.maxY - 1)
        XCTAssertLessThanOrEqual(editViewport.frame.maxY, editor(app).frame.minY + 1)
        let cancel = app.buttons["Cancel"].firstMatch
        let save = app.buttons["save-queued-message"]
        XCTAssertTrue(cancel.frame.intersection(save.frame).isEmpty, "Queued edit actions must not overlap in the compact pane.")
        queuedEditor.tap()
        queuedEditor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Follow-up".count) + "Edited\nline")
        XCTAssertEqual(queuedEditor.value as? String, "Edited\nline")
        app.buttons["save-queued-message"].tap()
        let admitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("replace-queued.started").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [admitted], timeout: 5), .completed)
        try FileManager.default.removeItem(at: reply)
        XCTAssertTrue(app.staticTexts["Message has left the queue"].waitForExistence(timeout: 5))
        XCTAssertEqual(queuedEditor.value as? String, "Edited\nline")
        XCTAssertEqual(app.buttons["save-queued-message"].label, "Saving…")
        XCTAssertFalse(app.buttons["save-queued-message"].isEnabled)
        XCTAssertFalse(app.buttons["keep-queued-edit-as-draft"].isEnabled)
        try FileManager.default.removeItem(at: replacement)
        XCTAssertTrue(app.staticTexts["queued-message-edit-error"].waitForExistence(timeout: 5))
        XCTAssertTrue(queuedEditor.isHittable)
        XCTAssertGreaterThanOrEqual(queuedEditor.frame.intersection(editViewport.frame).height, 44,
                                    "The saved multiline edit must remain visibly editable after its queue entry leaves.")
        XCTAssertEqual(queuedEditor.value as? String, "Edited\nline")
        let departed = XCTAttachment(screenshot: app.screenshot())
        departed.name = "Started queue item retains multiline edit"; departed.lifetime = .keepAlways; add(departed)
        app.buttons["keep-queued-edit-as-draft"].tap()
        XCTAssertEqual(editor(app).value as? String, "Keep\n\nEdited\nline")
        XCTAssertFalse(queuedEditor.exists)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("send.calls"), encoding: .utf8), "2")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("replace-queued.calls"), encoding: .utf8), "1")
    }

    // Native collection cells expose rendered rows. Discover older content by
    // scrolling instead of treating the mounted AX tree as the whole history.
    @MainActor private func revealTranscriptText(_ text: String, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let target = app.staticTexts[text]
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        let deadline = Date.now.addingTimeInterval(timeout)
        while !target.exists && Date.now < deadline { transcript.swipeDown(velocity: .slow) }
        return target.exists
    }

    @MainActor private func renderedReplyIDs(prefix: String, app: XCUIApplication, timeout: TimeInterval) -> Set<String> {
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript-message-"))
        let content = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let deadline = Date.now.addingTimeInterval(timeout)
        var found = Set<String>()
        repeat {
            // `count`, because `firstMatch.exists` on an index-bound row reported rows that hold no match.
            for row in rows.allElementsBoundByIndex where row.label.hasPrefix(prefix) || row.staticTexts.matching(content).count > 0 {
                found.insert(row.identifier)
            }
            if found.count < 2 && Date.now < deadline { transcript.swipeDown(velocity: .slow) }
        } while found.count < 2 && Date.now < deadline
        return found
    }

    @MainActor private func launch(largeText: Bool = false, gateDirectory: URL? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        if let gateDirectory { app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = gateDirectory.path }
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        WorkspaceNavigation.openSpace("milo", in: app)
        return app
    }

    @MainActor private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat-composer"]
    }

    @MainActor private func assertTitle(_ title: String, app: XCUIApplication,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["t3-chat-header"].label.hasPrefix(title == "Main" ? "Main Space" : title)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, file: file, line: line)
    }

    @MainActor private func picker(_ app: XCUIApplication) {
        WorkspaceNavigation.openDrawer(in: app)
    }

    @MainActor private func card(_ title: String, app: XCUIApplication) -> XCUIElement {
        let id = title == "Main" ? "milo" : "demo-milo-weekend"
        return WorkspaceNavigation.space(id, in: app)
    }

    @MainActor private func select(_ title: String, app: XCUIApplication) {
        WorkspaceNavigation.openSpace(title == "Main" ? "milo" : "demo-milo-weekend", in: app)
        assertTitle(title, app: app)
    }

    /// Supply a real Files-visible disposable fixture name on the runner. Selection,
    /// upload, switching, removal, and text editing still use native public controls.
    @MainActor func testStagedFileAndDraftStayWithSourceChat() throws {
        guard let filename = ProcessInfo.processInfo.environment["BOTTO_UI_TEST_IMPORT_FILENAME"] else {
            throw XCTSkip("Provide BOTTO_UI_TEST_IMPORT_FILENAME for a fixture visible in the native Files picker.")
        }
        let app = launch()
        app.buttons["Add attachment"].tap()
        let chooseFile = app.buttons["Choose a file"]
        var previousFrame = CGRect.null
        let menuReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                guard chooseFile.exists, chooseFile.isHittable else {
                    previousFrame = .null; return false
                }
                let frame = chooseFile.frame
                defer { previousFrame = frame }
                return frame == previousFrame
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [menuReady], timeout: 5), .completed,
                       "Wait for the native attachment menu to settle.")
        chooseFile.tap()
        // Browse the durable provider directly. Recents search uses a separate
        // index and can omit a file just exported by another application.
        let browse = app.tabBars.buttons["Browse"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 20))
        if !browse.isSelected { browse.tap() }
        let localLocation = app.cells["DOC.sidebar.item.On My iPhone"].firstMatch
        if localLocation.exists && localLocation.isHittable { localLocation.tap() }
        let stem = (filename as NSString).deletingPathExtension
        let file = app.collectionViews.cells.containing(NSPredicate(
            format: "label CONTAINS %@", stem)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        // The picker takes several files, so a choice needs confirming.
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        let remove = app.buttons["Remove " + filename]
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        editor(app).tap(); editor(app).typeText("Draft with a file")
        select("Weekend plan", app: app)
        XCTAssertFalse(remove.exists)
        editor(app).tap(); editor(app).typeText("Different draft")
        select("Main", app: app)
        XCTAssertEqual(editor(app).value as? String, "Draft with a file")
        XCTAssertTrue(remove.exists)
        XCTAssertTrue(app.buttons["Send message"].isEnabled, "An unconsumed source upload survives ordinary navigation")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["Draft with a file"].waitForExistence(timeout: 5))
        XCTAssertFalse(remove.exists, "Positive admission clears only this source’s staging")
    }
    private func waitForMarker(_ name: String, directory: URL) {
        let marker = directory.appendingPathComponent(name)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: marker.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

}
