import XCTest
import Vision

/// Public multi-chat workflows. These tests do not select chats through store setters.
final class MultipleChatUITests: XCTestCase {
    @MainActor func testClosingSelectedTabReturnsToUsableMainThroughItsCard() {
        checkReturningToMainAfterClosingSelectedTab(usingCard: true)
    }

    @MainActor func testClosingSelectedTabReturnsToUsableMainThroughTheHeader() {
        checkReturningToMainAfterClosingSelectedTab(usingCard: false)
    }

    @MainActor private func checkReturningToMainAfterClosingSelectedTab(usingCard: Bool) {
        let app = launch()
        select("Weekend plan", app: app)
        picker(app)
        app.buttons["Close Weekend plan"].tap()
        XCTAssertTrue(card("Main", app: app).label.contains("Current chat"))
        if usingCard { card("Main", app: app).tap() }
        else { app.buttons["chat-picker-button"].tap() }
        assertTitle("Main", app: app)
        let text = "Main stays usable after closing another tab"
        editor(app).tap(); editor(app).typeText(text)
        app.buttons["Send message"].tap()
        picker(app)
        app.buttons["chat-picker-button"].tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
        let transcript = app.descendants(matching: .any)["chat-transcript"]
        let deadline = Date.now.addingTimeInterval(10)
        while !sent.exists && Date.now < deadline { transcript.swipeDown(velocity: .slow) }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Main after sending from restored tab"
        hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertTrue(sent.exists, app.debugDescription)
        picker(app)
        XCTAssertFalse(card("Weekend plan", app: app).exists)
        app.buttons["new-chat"].tap()
        assertTitle("New chat", app: app)
    }

    @MainActor func testCreatingFromCachedReplacementKeepsClosedTabClosed() {
        let app = launch()
        select("Weekend plan", app: app)
        picker(app)
        app.buttons["Close Weekend plan"].tap()
        XCTAssertTrue(app.buttons["new-chat"].isEnabled)
        app.buttons["new-chat"].tap()
        assertTitle("New chat", app: app)
        picker(app)
        XCTAssertFalse(card("Weekend plan", app: app).exists)
    }

    @MainActor func testClosingTabsKeepsTheGridAndReopeningPreservesDrafts() {
        let app = launch()
        picker(app)
        let weekend = card("Weekend plan", app: app)
        let id = weekend.identifier.replacingOccurrences(of: "chat-card-", with: "")
        XCTAssertFalse(app.buttons["Close Main"].exists)
        let close = app.buttons["Close Weekend plan"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertFalse(card("Weekend plan", app: app).exists)
        XCTAssertTrue(card("Main", app: app).label.contains("Current chat"),
                      "Closing another tab must not select it first.")
        app.buttons["undo-close-chat"].tap()
        XCTAssertTrue(card("Weekend plan", app: app).waitForExistence(timeout: 5))
        card("Weekend plan", app: app).tap()
        assertTitle("Weekend plan", app: app)
        let draft = "Keep my locally closed draft"
        editor(app).tap(); editor(app).typeText(draft)
        picker(app)
        app.buttons["Close Weekend plan"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-picker"].exists)
        XCTAssertFalse(card("Weekend plan", app: app).exists)
        XCTAssertTrue(card("Main", app: app).label.contains("Current chat"))
        app.buttons["closed-chats"].tap()
        app.buttons["reopen-chat-\(id)"].tap()
        XCTAssertTrue(card("Weekend plan", app: app).waitForExistence(timeout: 5))
        card("Weekend plan", app: app).tap()
        assertTitle("Weekend plan", app: app)
        XCTAssertEqual(editor(app).value as? String, draft)
    }

    @MainActor func testProfileSheetReturnsToTheFilteredChatGrid() {
        let app = launch()
        picker(app)
        let search = app.textFields["chat-picker-search"]
        search.tap(); search.typeText("Weekend\n")
        XCTAssertTrue(card("Weekend plan", app: app).exists)
        XCTAssertFalse(card("Main", app: app).exists)
        app.buttons["bot-profile-button"].tap()
        let close = app.buttons["bot-profile-done"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-picker"].waitForExistence(timeout: 5),
                      "Closing the bot sheet returns directly to the grid that presented it.")
        XCTAssertEqual(app.textFields["chat-picker-search"].value as? String, "Weekend")
        XCTAssertTrue(card("Weekend plan", app: app).isHittable)
        XCTAssertFalse(card("Main", app: app).exists)
        XCTAssertFalse(app.buttons["chat-picker-done"].exists)
    }

    @MainActor func testVisitedViewportPreviewSurvivesSwitchingToAnotherChat() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 5))
        picker(app)
        let original = card("Main", app: app)
        let before = previewText(in: original, app: app)
        XCTAssertTrue(before.contains("needsyou"), "Main's cropped preview shows the actual approval heading: \(before)")
        XCTAssertTrue(before.contains("drafted"), "Ordinary transcript text remains readable in the captured viewport: \(before)")
        card("Weekend plan", app: app).tap()
        assertTitle("Weekend plan", app: app)
        picker(app)
        let after = previewText(in: card("Main", app: app), app: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Visited Main viewport after selecting Weekend plan"
        screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertTrue(after.contains("needsyou"), "Returning to the overview must retain Main's actual approval heading: \(after)")
        XCTAssertTrue(after.contains("drafted"), "Retained viewport text keeps its real foreground and background: \(after)")
        card("Main", app: app).tap()
        assertTitle("Main", app: app)
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 5),
                      "Expanding Main's card returns to its actual approval controls.")
    }

    @MainActor private func previewText(in card: XCUIElement, app: XCUIApplication) -> String {
        guard let screen = app.screenshot().image.cgImage else { return "" }
        let bounds = card.frame
        let scaleX = CGFloat(screen.width) / app.frame.width
        let scaleY = CGFloat(screen.height) / app.frame.height
        let crop = CGRect(x: bounds.minX * scaleX, y: bounds.minY * scaleY,
                          width: bounds.width * scaleX, height: bounds.height * scaleY).integral
        guard let image = screen.cropping(to: crop) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined().lowercased().filter(\.isLetter)
    }

    @MainActor func testCachedChatDirectoryRetryShowsProgressWithoutHidingCards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = launch(gateDirectory: directory)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let failure = directory.appendingPathComponent("directory.fail")
        let hold = directory.appendingPathComponent("directory.hold")
        try Data().write(to: failure)
        picker(app)
        let retry = app.buttons["chat-picker-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(card("Main", app: app).isHittable)
        let before = try XCTUnwrap(Int(String(contentsOf: directory.appendingPathComponent("directory.calls"), encoding: .utf8)))
        try FileManager.default.removeItem(at: failure)
        try Data().write(to: hold)
        retry.tap()
        waitForMarker("directory-\(before + 1).started", directory: directory)
        let progress = app.descendants(matching: .any).matching(identifier: "chat-picker-refresh-progress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertFalse(retry.isEnabled)
        XCTAssertTrue(card("Main", app: app).isHittable)
        XCTAssertEqual(try Int(String(contentsOf: directory.appendingPathComponent("directory.calls"), encoding: .utf8)), before + 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Retry progress preserves cached chat previews"
        screenshot.lifetime = .keepAlways; add(screenshot)
        try FileManager.default.removeItem(at: hold)
        XCTAssertTrue(progress.waitForNonExistence(timeout: 5))
        XCTAssertTrue(retry.waitForNonExistence(timeout: 5))
        XCTAssertTrue(card("Main", app: app).isHittable)
    }

    @MainActor func testInboxUnreadDotFollowsReadChatWhilePickerKeepsUnreadSiblings() {
        let app = launch()
        picker(app)
        let main = card("Main", app: app), weekend = card("Weekend plan", app: app)
        XCTAssertFalse(main.label.contains("Unread"))
        XCTAssertTrue(weekend.label.contains("Unread"))
        main.tap()
        assertTitle("Main", app: app)
        let back = app.buttons["BackButton"].exists ? app.buttons["BackButton"] : app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let row = app.buttons["bot-row-milo"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.label.contains("Unread"), "Unread sibling chats must not light the inbox dot")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Read current chat with unread siblings"
        capture.lifetime = .keepAlways
        add(capture)
        row.tap()
        select("Weekend plan", app: app)
        let siblingBack = app.buttons["BackButton"].exists ? app.buttons["BackButton"] : app.buttons["Back"]
        XCTAssertTrue(siblingBack.waitForExistence(timeout: 5))
        siblingBack.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.label.contains("Unread"))
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
        XCTAssertTrue(app.buttons["Scout, pinned"].waitForExistence(timeout: 10))
        app.buttons["Scout, pinned"].tap()
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

    @MainActor func testOfflineChatCreationWaitsForAttemptAndDeliberateRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-offline"]
        app.launch()
        XCTAssertTrue(app.buttons["bot-row-milo"].waitForExistence(timeout: 8))
        app.buttons["bot-row-milo"].tap()
        XCTAssertTrue(editor(app).waitForExistence(timeout: 5))
        editor(app).tap(); editor(app).typeText("Keep my main draft")
        picker(app)
        XCTAssertFalse(app.descendants(matching: .any)["connection-feedback"].exists)
        let create = app.buttons["new-chat"]
        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(app.descendants(matching: .any)["connection-feedback"].waitForExistence(timeout: 3))
        app.buttons["Reconnect"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-picker"].waitForNonExistence(timeout: 8))
        assertTitle("Main", app: app)
        XCTAssertEqual(editor(app).value as? String, "Keep my main draft")
        picker(app)
        app.buttons["new-chat"].tap()
        assertTitle("New chat", app: app)
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
            for row in rows.allElementsBoundByIndex where row.label.hasPrefix(prefix) || row.staticTexts.matching(content).firstMatch.exists {
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
        let milo = app.buttons["bot-row-milo"]
        XCTAssertTrue(milo.waitForExistence(timeout: 8))
        milo.tap()
        XCTAssertTrue(editor(app).waitForExistence(timeout: 5))
        assertTitle("Main", app: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["Add attachment"].isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        return app
    }

    @MainActor private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat-composer"]
    }

    @MainActor private func assertTitle(_ title: String, app: XCUIApplication,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            WorkspaceNavigation.displaysChat(title, in: app)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, file: file, line: line)
    }

    @MainActor private func picker(_ app: XCUIApplication) {
        app.buttons["chat-picker-button"].tap()
        XCTAssertTrue(app.buttons["new-chat"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor private func card(_ title: String, app: XCUIApplication) -> XCUIElement {
        // Context-menu cards are exposed as PopUpButton on current iOS. Match
        // their stable public identity without forcing the legacy Button type.
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                        "chat-card-", title)).firstMatch
    }

    @MainActor private func select(_ title: String, app: XCUIApplication) {
        picker(app)
        let target = card(title, app: app)
        for _ in 0..<5 where !target.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(target.isHittable)
        target.tap()
        assertTitle(title, app: app)
    }

    @MainActor func testPickerCreatesSeparateChatAndRestoresSiblingDrafts() {
        let app = launch()
        editor(app).tap(); editor(app).typeText("Main draft stays here")
        select("Weekend plan", app: app)
        XCTAssertNotEqual(editor(app).value as? String, "Main draft stays here")
        editor(app).tap(); editor(app).typeText("Weekend draft stays here")
        select("Main", app: app)
        XCTAssertEqual(editor(app).value as? String, "Main draft stays here")
        XCTAssertTrue(app.buttons["Keep draft"].exists)
        picker(app)
        let main = card("Main", app: app), weekend = card("Weekend plan", app: app)
        XCTAssertLessThanOrEqual(main.frame.minY, weekend.frame.minY, "Main must remain pinned first")
        let research = card("Research notes", app: app)
        let list = app.scrollViews["chat-tabs-scroll"]
        for _ in 0..<4 where !research.isHittable { list.swipeUp() }
        XCTAssertTrue(research.exists && research.isHittable)
        let create = app.buttons["new-chat"]
        for _ in 0..<4 where !create.isHittable { list.swipeDown() }
        XCTAssertTrue(create.isHittable)
        create.tap()
        assertTitle("New chat", app: app)
        XCTAssertFalse(app.staticTexts["Help me get a handle on tomorrow."].exists)
        editor(app).tap(); editor(app).typeText("Only the new chat")
        app.buttons["Send message"].tap()
        XCTAssertTrue(revealTranscriptText("Only the new chat", app: app, timeout: 4))
        select("Weekend plan", app: app)
        XCTAssertEqual(editor(app).value as? String, "Weekend draft stays here")
        XCTAssertFalse(app.staticTexts["Only the new chat"].exists)
    }

    @MainActor func testPreferredOpeningDoesNotHideExactNeedsYouRoute() {
        let app = launch()
        picker(app)
        let search = app.textFields["Search chats with Milo"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap(); search.typeText("Research notes\n")
        let research = card("Research notes", app: app)
        for _ in 0..<4 where !research.isHittable { app.scrollViews.firstMatch.swipeUp() }
        research.press(forDuration: 1)
        app.buttons["Open by default"].tap()
        let preferred = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            research.label.contains("Opens by default")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [preferred], timeout: 5), .completed)
        app.buttons["chat-picker-button"].tap()
        XCTAssertTrue(app.buttons["new-chat"].waitForNonExistence(timeout: 5))
        WorkspaceNavigation.browseBots(in: app)
        app.buttons["pinned-bot-milo"].tap()
        assertTitle("Research notes", app: app)
        WorkspaceNavigation.browseBots(in: app)
        app.buttons["bot-row-milo"].press(forDuration: 1)
        app.buttons["Needs you"].tap()
        assertTitle("Main", app: app)
        XCTAssertTrue(app.buttons["Keep draft"].waitForExistence(timeout: 4))
        app.buttons["Keep draft"].tap()
        XCTAssertTrue(app.staticTexts["Understood. I’ll keep the draft here."].waitForExistence(timeout: 4))
    }

    @MainActor func testChatsUseTabGridAndCreationStaysInTheBottomBar() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        picker(app)
        let overview = app.descendants(matching: .any).matching(identifier: "chat-picker").firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        let profile = app.buttons["bot-profile-button"]
        let tabs = app.buttons["chat-picker-button"]
        let back = app.buttons["BackButton"].exists ? app.buttons["BackButton"] : app.buttons["Back"]
        XCTAssertTrue(profile.isHittable, "The bot header stays visible and usable above chat tabs.")
        XCTAssertTrue(tabs.isHittable, "The fixed tabs button remains available to close the overview.")
        XCTAssertTrue(back.isHittable, "The overview preserves the conversation's native Back control.")
        XCTAssertTrue(profile.label.contains("Milo"))
        XCTAssertFalse(app.navigationBars["Chats with Milo"].exists,
                       "Chat tabs retain the bot header instead of installing a second navigation title.")
        XCTAssertEqual(overview.frame.width, app.frame.width, accuracy: 1)
        XCTAssertLessThanOrEqual(overview.frame.minY, profile.frame.maxY + 1,
                                 "The overview fills the chat pane beneath the fixed header.")
        XCTAssertLessThanOrEqual(app.frame.maxY - overview.frame.maxY, app.frame.height * 0.06,
                                 "The overview reaches the window's usable bottom.")
        XCTAssertEqual(app.sheets.count, 0, "Chat tabs replace the chat pane rather than presenting a sheet.")
        let main = card("Main", app: app)
        let weekend = card("Weekend plan", app: app)
        XCTAssertTrue(main.exists && weekend.exists)
        XCTAssertEqual(main.frame.width, weekend.frame.width, accuracy: 1)
        XCTAssertEqual(main.frame.minY, weekend.frame.minY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(weekend.frame.minX, main.frame.maxX)
        XCTAssertGreaterThanOrEqual(main.frame.height, 220)
        XCTAssertTrue(main.label.contains("Needs you"), "Icon-only attention retains its spoken meaning")
        XCTAssertFalse(app.buttons["bot-profile-edit"].exists)
        let create = app.buttons["new-chat"]
        XCTAssertTrue(create.isHittable)
        XCTAssertGreaterThanOrEqual(create.frame.width.rounded(), 44)
        XCTAssertGreaterThanOrEqual(create.frame.height.rounded(), 44)
        XCTAssertGreaterThan(create.frame.minY, app.textFields["chat-picker-search"].frame.maxY)
        XCTAssertFalse(app.buttons["chat-picker-done"].exists)
        let count = overview.staticTexts["3 chats"]
        XCTAssertTrue(count.exists, app.debugDescription)
        XCTAssertEqual(count.frame.intersection(app.frame), count.frame, "The noninteractive count remains fully visible.")
        XCTAssertEqual(count.label, "3 chats")
        XCTAssertTrue(previewText(in: count, app: app).contains("chats"), "The passive count label remains readable.")
        // Both edges of the visible target must create an independent chat.
        for offset in [21.0, -21.0] {
            create.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: offset)).tap()
            assertTitle("New chat", app: app)
            picker(app)
            let search = app.textFields["chat-picker-search"]
            search.tap(); search.typeText("New chat\n")
            XCTAssertTrue(card("New chat", app: app).waitForExistence(timeout: 4))
        }
    }

    @MainActor func testRepeatedOverviewTogglePreservesDraftWhenCurrentCardIsFilteredOut() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        var draft = "Overview draft"
        editor(app).tap(); editor(app).typeText(draft)
        for cycle in 0..<3 {
            picker(app)
            XCTAssertTrue(!editor(app).exists || !editor(app).isEnabled, "The covered composer cannot accept input in the overview.")
            if cycle == 1 {
                let search = app.textFields["chat-picker-search"]
                search.tap(); search.typeText("No matching conversation\n")
                XCTAssertTrue(app.staticTexts["No matching chats"].waitForExistence(timeout: 5))
                XCTAssertFalse(card("Main", app: app).exists)
            }
            let close = app.buttons["chat-picker-button"]
            XCTAssertTrue(close.isHittable)
            close.tap()
            assertTitle("Main", app: app)
            let input = editor(app)
            XCTAssertTrue(input.isHittable)
            XCTAssertEqual(input.value as? String, draft)
            let suffix = " \(cycle + 1)"
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            input.typeText(suffix)
            draft += suffix
            XCTAssertEqual(input.value as? String, draft,
                           "No dismissed transition proxy may intercept subsequent editor input.")
        }
    }

    @MainActor func testEmptyComposerDragKeepsChatUntilHeaderPickerSelection() {
        let app = launch()
        let input = editor(app)
        let start = input.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = input.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        let switched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !WorkspaceNavigation.displaysChat("Main", in: app)
        }, object: nil)
        switched.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 1.5), .completed,
                       "Dragging the empty composer must not select an adjacent chat")
        assertTitle("Main", app: app)
        select("Weekend plan", app: app)
        select("Main", app: app)
    }

    @MainActor func testDraftSurvivesInboxReentryAndPickerSwitching() {
        let app = launch()
        editor(app).tap(); editor(app).typeText("Draft kept after leaving")
        WorkspaceNavigation.browseBots(in: app)
        app.buttons["bot-row-milo"].tap()
        assertTitle("Main", app: app)
        XCTAssertEqual(editor(app).value as? String, "Draft kept after leaving")
        select("Weekend plan", app: app)
        XCTAssertNotEqual(editor(app).value as? String, "Draft kept after leaving")
        select("Main", app: app)
        XCTAssertEqual(editor(app).value as? String, "Draft kept after leaving")
    }

    @MainActor func testSwitchingAwayKeepsWorkInSourceAndApprovalOutOfSibling() {
        let app = launch()
        editor(app).tap(); editor(app).typeText("Work only in Main")
        app.buttons["Send message"].tap()
        select("Weekend plan", app: app)
        XCTAssertFalse(app.buttons["Allow once"].exists)
        XCTAssertFalse(app.staticTexts["Work only in Main"].exists)
        select("Main", app: app)
        XCTAssertTrue(app.staticTexts["Work only in Main"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "You’ve got the idea.")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Keep draft"].exists)
    }

    @MainActor func testLargestTextPickerAndCreateRemainReachable() {
        let app = launch(largeText: true)
        picker(app)
        let create = app.buttons["new-chat"]
        let list = app.scrollViews["chat-tabs-scroll"]
        for _ in 0..<4 where !create.isHittable { list.swipeUp(velocity: .slow) }
        XCTAssertTrue(create.isHittable)
        XCTAssertGreaterThanOrEqual(create.frame.height.rounded(), 44)
        XCTAssertTrue(card("Main", app: app).exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Multi-chat picker at accessibility XXXL"
        screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["new-chat"].tap()
        assertTitle("New chat", app: app)
        XCTAssertTrue(editor(app).isHittable)
        XCTAssertTrue(app.buttons["Add attachment"].isHittable)
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
    @MainActor func testClosingSelectedSourceDuringCreationKeepsTheGrid() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hold = directory.appendingPathComponent("create-chat.hold")
        try Data().write(to: hold)
        let app = launch(gateDirectory: directory)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        select("Weekend plan", app: app)
        picker(app); app.buttons["new-chat"].tap()
        waitForMarker("create-chat.started", directory: directory)
        let opens = try String(contentsOf: directory.appendingPathComponent("open.calls"), encoding: .utf8)
        app.buttons["Close Weekend plan"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-picker"].exists)
        XCTAssertTrue(card("Main", app: app).label.contains("Current chat"))
        XCTAssertFalse(card("Weekend plan", app: app).exists)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("open.calls"), encoding: .utf8), opens)
        try FileManager.default.removeItem(at: hold)
        waitForMarker("create-chat.returned", directory: directory)
        XCTAssertTrue(card("New chat", app: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["chat-picker"].exists)
        XCTAssertTrue(card("Main", app: app).label.contains("Current chat"))
        XCTAssertFalse(card("Weekend plan", app: app).exists)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("open.calls"), encoding: .utf8), opens)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("create-chat.calls"), encoding: .utf8), "1")
        card("New chat", app: app).tap()
        assertTitle("New chat", app: app)
    }

    @MainActor func testDelayedCreatePreservesIndependentProfileEdits() throws {
        XCUIDevice.shared.orientation = .portrait
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hold = directory.appendingPathComponent("create-chat.hold")
        try Data().write(to: hold)
        let app = launch(gateDirectory: directory)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        picker(app); app.buttons["new-chat"].tap()
        waitForMarker("create-chat.started", directory: directory)
        app.buttons["bot-profile-button"].tap()
        let edit = app.buttons["bot-profile-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let name = app.textFields["bot-profile-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText(" Pending profile")
        let draft = name.value as? String
        try FileManager.default.removeItem(at: hold)
        waitForMarker("create-chat.returned", directory: directory)
        XCTAssertTrue(app.navigationBars["Edit bot"].exists)
        XCTAssertEqual(name.value as? String, draft)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        app.buttons["bot-profile-done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-picker"].waitForExistence(timeout: 5),
                      "Finishing creation must not replace the grid under the bot sheet.")
        XCTAssertTrue(card("New chat", app: app).waitForExistence(timeout: 5))
        card("New chat", app: app).tap()
        assertTitle("New chat", app: app)
    }

    @MainActor func testDelayedCreateCannotDismissReplacementConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hold = directory.appendingPathComponent("create-chat.hold")
        try Data().write(to: hold)
        let app = launch(gateDirectory: directory)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        picker(app); app.buttons["new-chat"].tap()
        waitForMarker("create-chat.started", directory: directory)
        XCUIDevice.shared.system.open(URL(string: "botto://hermes/connect?url=https%3A%2F%2Freplacement.example")!)
        XCTAssertTrue(app.navigationBars["Connect Hermes"].waitForExistence(timeout: 5))
        let review = app.buttons["Review destination"]
        for _ in 0..<8 {
            if review.exists && review.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(review.exists && review.isHittable)
        review.tap()
        XCTAssertTrue(app.staticTexts["https://replacement.example"].waitForExistence(timeout: 3))
        try FileManager.default.removeItem(at: hold)
        waitForMarker("create-chat.returned", directory: directory)
        XCTAssertTrue(app.navigationBars["Connect Hermes"].exists)
        XCTAssertTrue(app.staticTexts["https://replacement.example"].exists)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("create-chat.calls"), encoding: .utf8), "1")
    }

    @MainActor func testDelayedSiblingOpenCannotReplaceNewerSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = launch(gateDirectory: directory)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let hold = directory.appendingPathComponent("open-2.hold")
        try Data().write(to: hold)
        select("Weekend plan", app: app)
        waitForMarker("open-2.started", directory: directory)
        select("Research notes", app: app)
        try FileManager.default.removeItem(at: hold)
        waitForMarker("open-2.returned", directory: directory)
        assertTitle("Research notes", app: app)
        editor(app).tap(); editor(app).typeText("Newest owner")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["Newest owner"].waitForExistence(timeout: 5))
        select("Weekend plan", app: app)
        XCTAssertFalse(app.staticTexts["Newest owner"].exists)
    }

    @MainActor func testSameBotRichContentAndArtifactsRetireAcrossSiblingSelection() {
        let app = launch()
        WorkspaceNavigation.browseBots(in: app)
        WorkspaceNavigation.revealBot("bot-row-canvas", in: app)
        app.buttons["bot-row-canvas"].tap()
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        let report = app.buttons["Open report.pdf"]
        for _ in 0..<8 where !report.isHittable { transcript.swipeDown() }
        XCTAssertTrue(report.isHittable); report.tap()
        ArtifactOutputActions.assertAvailable(in: app, timeout: 8)
        app.buttons["artifact-done"].tap()
        picker(app); app.buttons["new-chat"].tap()
        assertTitle("New chat", app: app)
        XCTAssertFalse(app.descendants(matching: .any)["artifact-preview"].exists)
        XCTAssertFalse(app.buttons["Open report.pdf"].exists)
        XCTAssertFalse(app.buttons["Add review"].exists)
        editor(app).tap(); editor(app).typeText("Separate Canvas conversation")
        select("Main", app: app)
        for _ in 0..<8 where !report.isHittable { transcript.swipeDown() }
        XCTAssertTrue(report.isHittable); report.tap()
        ArtifactOutputActions.assertAvailable(in: app, timeout: 8)
        XCTAssertFalse(app.descendants(matching: .any)["artifact-error"].exists)
        app.buttons["artifact-done"].tap()
        select("New chat", app: app)
        XCTAssertEqual(editor(app).value as? String, "Separate Canvas conversation")
    }

    private func waitForMarker(_ name: String, directory: URL) {
        let marker = directory.appendingPathComponent(name)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: marker.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

}
