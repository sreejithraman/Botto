import XCTest
import UIKit
import UniformTypeIdentifiers
import Vision

final class ConversationUITests: XCTestCase {
    @MainActor func testForegroundReturnKeepsCachedAvatarsNeutralWhileReconnecting() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        let milo = app.buttons["pinned-bot-milo"]
        XCTAssertTrue(milo.waitForExistence(timeout: 5))
        milo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-composer"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()

        for cycle in 1...3 {
            try Data().write(to: directory.appendingPathComponent("connect.hold"))
            let started = directory.appendingPathComponent("connect.started")
            try? FileManager.default.removeItem(at: started)
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
            app.activate()
            let reconnecting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: started.path)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [reconnecting], timeout: 5), .completed)
            XCTAssertTrue(milo.exists)
            XCTAssertEqual(milo.value as? String, "")
            XCTAssertFalse(app.staticTexts["You’re offline"].exists)
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "Foreground cycle \(cycle), cached avatars while reconnecting"
            capture.lifetime = .keepAlways
            add(capture)
            milo.tap()
            XCTAssertTrue(app.descendants(matching: .any)["chat-composer"].waitForExistence(timeout: 5))
            let profile = app.buttons["bot-profile-button"]
            XCTAssertTrue(profile.exists)
            XCTAssertEqual(profile.value as? String, "")
            try FileManager.default.removeItem(at: directory.appendingPathComponent("connect.hold"))
            app.buttons["Back"].tap()
            XCTAssertTrue(milo.waitForExistence(timeout: 5))
        }
    }

    @MainActor func testGlassComposerOverlaysTranscriptAndKeepsLatestRequestAboveMultilineInput() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let milo = app.buttons["pinned-bot-milo"]
        XCTAssertTrue(milo.waitForExistence(timeout: 5)); milo.tap()
        let composer = app.textViews["chat-composer"]
        let transcript = app.collectionViews["chat-transcript"]
        let keepDraft = app.buttons["Keep draft"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(keepDraft.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(transcript.frame.maxY, composer.frame.maxY)
        XCTAssertLessThan(keepDraft.frame.maxY, composer.frame.minY)
        composer.tap(); composer.typeText("First line\nSecond line\nThird line")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertLessThan(keepDraft.frame.maxY, composer.frame.minY,
                          "Growing input preserves scroll clearance for the latest message.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Floating glass composer with multiline input and readable latest action"
        screenshot.lifetime = .keepAlways; add(screenshot)
        let add = app.buttons["composer-add-attachment"]
        XCTAssertGreaterThanOrEqual(add.frame.width.rounded(), 44)
        XCTAssertGreaterThanOrEqual(add.frame.height.rounded(), 44)
        add.tap()
        XCTAssertTrue(app.buttons["Choose a file"].waitForExistence(timeout: 5))
    }

    @MainActor func testSelectionCanCopyAcrossReplyParagraphs() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        WorkspaceNavigation.revealBot("bot-row-iris", in: app)
        app.buttons["bot-row-iris"].tap()
        let opening = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Here’s a lighter opening:")).firstMatch
        XCTAssertTrue(opening.waitForExistence(timeout: 5))
        opening.press(forDuration: 1)
        let reply = app.otherElements["transcript-message-i2"]
        let leading = app.otherElements["com.apple.text.grabber.leading"]
        let trailing = app.otherElements["com.apple.text.grabber.trailing"]
        XCTAssertTrue(leading.waitForExistence(timeout: 3) && trailing.exists)
        leading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: reply.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.03)))
        trailing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: reply.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 1.2)))
        app.typeKey("c", modifierFlags: .command)
        let composer = app.descendants(matching: .any)["chat-composer"]
        composer.tap(); composer.typeKey("v", modifierFlags: .command)
        let allowPaste = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 1) { allowPaste.tap() }
        let expected = "Here’s a lighter opening:\n\n“We’ve been thinking about a simpler way to do this. Here’s what we tried, what surprised us, and where we’re going next.”\n\nIt gets to the idea sooner and gives people a reason to keep reading."
        XCTAssertEqual(composer.value as? String, expected)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Selected reply pasted across all three paragraphs"
        capture.lifetime = .keepAlways; add(capture)
    }

    @MainActor func testPendingActivityKeepsInboxAndPickerQuiet() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hold = directory.appendingPathComponent("directory.hold")
        try Data().write(to: hold)
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        let row = app.buttons["bot-row-milo"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("directory.started").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 5), .completed)
        XCTAssertFalse(row.label.contains("Activity unavailable"))
        XCTAssertFalse(app.staticTexts["Connecting to your Hermes…"].exists)
        let inbox = XCTAttachment(screenshot: app.screenshot())
        inbox.name = "Inbox while activity is pending"; inbox.lifetime = .keepAlways; add(inbox)
        row.tap()
        XCTAssertTrue(app.buttons["chat-picker-button"].waitForExistence(timeout: 5))
        app.buttons["chat-picker-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-picker"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Activity unavailable"].exists)
        XCTAssertFalse(app.staticTexts["Updating…"].exists)
        try FileManager.default.removeItem(at: hold)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat-card-", "Weekend plan")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat-card-", "Activity unavailable")).firstMatch.exists)
    }

    @MainActor func testHistoricalActivityIsQuietAndDoesNotCountAsLiveAttention() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-offline"]
        app.launch()
        let row = app.buttons["bot-row-milo"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Previously waiting"))
        XCTAssertFalse(row.label.contains("Activity unavailable"))
        XCTAssertFalse(row.label.contains("Needs you"))
        row.tap()
        XCTAssertTrue(app.buttons["chat-picker-button"].waitForExistence(timeout: 5))
        app.buttons["chat-picker-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-picker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat-card-", "Previously waiting")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["You’re offline"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Historical activity in cached picker"; capture.lifetime = .keepAlways; add(capture)
    }

    @MainActor func testInboxActivityIsKnownBeforeOpeningAnyBot() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        for profile in ["milo", "scout", "canvas"] {
            let row = app.buttons["bot-row-\(profile)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            let knownActivity = NSPredicate(format: "NOT label CONTAINS %@", "Activity unavailable")
            let observed = XCTNSPredicateExpectation(predicate: knownActivity, object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 5), .completed)
        }
        XCTAssertTrue(app.buttons["bot-row-milo"].label.contains("3 chats"))
        XCTAssertTrue(app.buttons["bot-row-milo"].label.contains("Needs you"))
        XCTAssertFalse(app.buttons["bot-profile-button"].exists)
        XCTAssertFalse(app.buttons["chat-picker-button"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Inbox activity before opening a bot"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor func testBotRowIdentitySurvivesUnpinning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-offline"]
        app.launch()
        let pinned = app.buttons["pinned-bot-milo"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 5))
        XCTAssertEqual(pinned.label, "Milo, pinned")
        let row = app.buttons["bot-row-milo"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: "bot-row-milo").count, 1)
        row.press(forDuration: 1)
        app.buttons["Unpin bot"].tap()
        XCTAssertTrue(pinned.waitForNonExistence(timeout: 3))
        WorkspaceNavigation.revealBot("bot-row-milo", in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "bot-row-milo").count, 1)
        XCTAssertTrue(row.label.contains("Milo"))
        XCTAssertFalse(row.label.contains("bot-row-"))
        row.tap()
        XCTAssertTrue(app.buttons["Profile for Milo"].waitForExistence(timeout: 5))
    }

    @MainActor func testDraftingWorksWhileUncachedConversationOpens() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("open.hold"))
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.buttons["pinned-bot-milo"].waitForExistence(timeout: 5))
        app.buttons["pinned-bot-milo"].tap()
        XCTAssertTrue(app.staticTexts["Opening your chat…"].waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Chat avatar while attachment is pending"
        capture.lifetime = .keepAlways
        add(capture)
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.isEnabled)
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        composer.typeText("A thought while history opens")
        XCTAssertEqual(composer.value as? String, "A thought while history opens")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("open.hold"))
        XCTAssertTrue(app.buttons["Keep draft"].waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "A thought while history opens")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("send.started").path))
    }

    @MainActor func testOfflineFileAndAttachmentActionsShowFeedbackWhenAttempted() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-offline"]
        app.launch()
        XCTAssertTrue(app.buttons["pinned-bot-canvas"].waitForExistence(timeout: 5))
        app.buttons["pinned-bot-canvas"].tap()
        let card = app.buttons["Open notes.txt"].firstMatch
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        for _ in 0..<8 where !card.isHittable { transcript.swipeDown() }
        XCTAssertTrue(card.isEnabled && card.isHittable)
        XCTAssertFalse(app.staticTexts["You’re offline"].exists)
        card.tap()
        XCTAssertTrue(app.staticTexts["You’re offline"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["artifact-done"].exists)
        XCTAssertTrue(app.buttons["Reconnect"].isHittable)
        app.buttons["Add attachment"].tap()
        app.buttons["Choose a file"].tap()
        XCTAssertTrue(app.staticTexts["You’re offline"].exists)
        XCTAssertFalse(app.navigationBars["Browse"].exists)
    }

    @MainActor func testOfflineDecisionRequiresDeliberateRetryAfterRecovery() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-offline"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.buttons["pinned-bot-milo"].waitForExistence(timeout: 5))
        app.buttons["pinned-bot-milo"].tap()
        XCTAssertTrue(app.buttons["Keep draft"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["You’re offline"].exists)
        app.buttons["Keep draft"].tap()
        XCTAssertTrue(app.staticTexts["You’re offline"].waitForExistence(timeout: 3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("answer.started").path))
        app.buttons["Reconnect"].tap()
        XCTAssertTrue(app.staticTexts["You’re offline"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("answer.started").path))
        app.buttons["Keep draft"].tap()
        XCTAssertTrue(app.staticTexts["Understood. I’ll keep the draft here."].waitForExistence(timeout: 5))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("answer.calls"), encoding: .utf8), "1")
    }

    @MainActor func testOfflineBrowsingAndDraftingWaitUntilSendToShowConnectionFeedback() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("connect.hold"))
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-offline"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        let milo = app.buttons["pinned-bot-milo"]
        XCTAssertTrue(milo.waitForExistence(timeout: 5))
        XCTAssertEqual(milo.value as? String, "Offline")
        let offlineRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label != %@",
                                                        "Milo,", "Milo, pinned")).firstMatch
        XCTAssertEqual(offlineRow.value as? String, "Offline")
        XCTAssertFalse(app.staticTexts["You’re offline"].exists)
        XCTAssertTrue(app.buttons["New bot"].isEnabled)
        milo.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertEqual(app.buttons["bot-profile-button"].value as? String, "Offline")
        XCTAssertFalse(app.staticTexts["You’re offline"].exists)
        composer.tap()
        composer.typeText("Keep this thought while offline")
        XCTAssertTrue(app.buttons["Send message"].isEnabled)
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["You’re offline"].waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Keep this thought while offline")
        XCTAssertTrue(app.buttons["Reconnect"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Connection feedback after Send, draft retained"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("send.started").path))
        app.buttons["Reconnect"].tap()
        XCTAssertTrue(app.staticTexts["Connecting to your Hermes…"].waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Keep this thought while offline")
        composer.tap(); composer.typeText(" and connecting")
        let connectingDraft = try XCTUnwrap(composer.value as? String)
        XCTAssertEqual(connectingDraft.count, "Keep this thought while offline and connecting".count)
        XCTAssertEqual(connectingDraft.replacingOccurrences(of: " and connecting", with: ""),
                       "Keep this thought while offline")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("connect.hold"))
        XCTAssertTrue(app.staticTexts["Connecting to your Hermes…"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["bot-profile-button"].value as? String, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("send.started").path))
        XCTAssertEqual(composer.value as? String, connectingDraft)
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "You’ve got the idea."))
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("send.calls"), encoding: .utf8), "1")
    }

    @MainActor private func assertDecisionActionsVisible(in app: XCUIApplication,
                                                        file: StaticString = #filePath, line: UInt = #line) {
        let keep = app.buttons["Keep draft"], allow = app.buttons["Allow once"]
        let composer = app.descendants(matching: .any)["chat-composer"]
        var visibilityDetails = "No visibility sample completed."
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // Each property read can request another accessibility snapshot. Read
            // each frame once so a valid CI sample can finish within the deadline.
            let navigationBottom = app.navigationBars.firstMatch.frame.maxY
            let composerTop = composer.frame.minY
            var details = ["navigation bottom=\(navigationBottom), composer top=\(composerTop)"]
            let results = [("Allow once", allow), ("Keep draft", keep)].map { name, button in
                guard button.exists else {
                    details.append("\(name): missing")
                    return false
                }
                let frame = button.frame
                let hittable = button.isHittable
                details.append("\(name): frame=\(frame), hittable=\(hittable)")
                // Off-screen lazy elements can exist with a zero frame. A tap would
                // auto-scroll them into view and conceal the initial layout failure.
                return !frame.isEmpty && hittable &&
                    frame.minY > navigationBottom && frame.maxY <= composerTop
            }
            visibilityDetails = details.joined(separator: "; ")
            return results.allSatisfy { $0 }
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 3)
        XCTAssertEqual(result, .completed, visibilityDetails, file: file, line: line)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Decision actions before any tap or scroll"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testLargestTextStartsWithDecisionActionsAboveComposer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let milo = app.buttons["bot-row-milo"]
        XCTAssertTrue(milo.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "bot-row-milo").count, 1)
        XCTAssertTrue(milo.label.contains("Milo"))
        XCTAssertFalse(app.buttons["pinned-bot-milo"].exists, "The pinned rail is hidden at an accessibility text size.")
        milo.tap()
        let keep = app.buttons["Keep draft"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        assertDecisionActionsVisible(in: app)
        keep.tap()
        XCTAssertTrue(app.staticTexts["Understood. I’ll keep the draft here."].waitForExistence(timeout: 3))
    }

    /// Opt in only against the disposable host and its deterministic BOTTO_QUESTION provider.
    @MainActor func testLiveOversizedQuestionKeepsDraftUntilCorrectedSubmission() throws {
        continueAfterFailure = false
        guard let address = ProcessInfo.processInfo.environment["BOTTO_UI_TEST_HERMES_URL"],
              let url = URL(string: address), url.scheme == "http",
              ["127.0.0.1", "localhost"].contains(url.host ?? "") else {
            throw XCTSkip("Set BOTTO_UI_TEST_HERMES_URL to the disposable loopback clarification host.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-server", address]
        app.launch()
        XCTAssertTrue(app.buttons["New bot"].waitForExistence(timeout: 15))
        app.buttons["New bot"].tap()
        let name = app.textFields["What shall we call them?"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap(); name.typeText("Botto answer " + String(UUID().uuidString.prefix(8)))
        let create = app.buttons["Create bot"]
        for _ in 0..<6 where !create.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        }
        XCTAssertTrue(create.isHittable); create.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 65))
        composer.tap(); composer.typeText("BOTTO_QUESTION")
        app.buttons["Send message"].tap()
        let question = app.staticTexts["What should the note say?"]
        XCTAssertTrue(question.waitForExistence(timeout: 60))
        // The placeholder stops being the accessibility name once this field has text.
        let answerFields = app.textFields.matching(NSPredicate(format: "identifier != %@", "chat-composer"))
        let answer = answerFields.firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 3))
        XCTAssertEqual(answerFields.count, 1)
        let oversized = String(repeating: "a", count: 16_385)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: oversized]],
                                     options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
        answer.tap(); answer.typeKey("v", modifierFlags: .command)
        let allowPaste = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 1) { allowPaste.tap() }
        XCTAssertEqual(answer.value as? String, oversized)
        let error = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "This answer is too long.")).firstMatch
        XCTAssertFalse(error.exists, "Drafting must stay quiet until Submit is attempted.")
        app.buttons["Submit answer"].tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("16,384"))
        XCTAssertTrue(error.label.contains("Nothing was sent."))
        XCTAssertTrue(question.exists)
        XCTAssertEqual(answer.value as? String, oversized)
        let rejected = XCTAttachment(screenshot: app.screenshot())
        rejected.name = "Oversized answer rejected with draft and question retained"
        rejected.lifetime = .keepAlways; add(rejected)
        answer.tap(); answer.typeKey("a", modifierFlags: .command)
        answer.typeText("A short note")
        XCTAssertEqual(answer.value as? String, "A short note")
        app.buttons["Submit answer"].tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 15))
        // Streaming can publish the completion marker before its answer bytes.
        let completed = app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "BOTTO_TOOL_DONE", "A short note")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 30))
        XCTAssertTrue(completed.label.contains("A short note"))
        let corrected = XCTAttachment(screenshot: app.screenshot())
        corrected.name = "Corrected answer returned by Hermes"
        corrected.lifetime = .keepAlways; add(corrected)
    }

    /// Opt in only against the disposable host: creates a profile and executes its harmless probe.
    @MainActor func testLiveApprovalArrivingWhileTypingStaysAboveComposer() throws {
        continueAfterFailure = false
        guard let address = ProcessInfo.processInfo.environment["BOTTO_UI_TEST_HERMES_URL"] else {
            throw XCTSkip("Set BOTTO_UI_TEST_HERMES_URL on the test runner to use a disposable host.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-server", address]
        app.launch()
        XCTAssertTrue(app.buttons["New bot"].waitForExistence(timeout: 10))
        app.buttons["New bot"].tap()
        let name = app.textFields["What shall we call them?"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Botto UI " + String(UUID().uuidString.prefix(8)))
        let create = app.buttons["Create bot"]
        for _ in 0..<6 where !create.isHittable {
            // Keep the gesture in the visible form above the software keyboard.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        }
        XCTAssertTrue(create.isHittable)
        create.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 65))
        composer.tap()
        composer.typeText("BOTTO_APPROVAL")
        app.buttons["Send message"].tap()
        let allow = app.buttons["Allow once"], lastChoice = app.buttons["Always allow"], add = app.buttons["Add attachment"]
        XCTAssertTrue(allow.waitForExistence(timeout: 60))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            allow.exists && lastChoice.exists && add.exists && lastChoice.frame.maxY <= add.frame.minY && allow.frame.minY > 100
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 3), .completed)
        allow.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "BOTTO_TOOL_DONE"))
            .firstMatch.waitForExistence(timeout: 60))
    }

    @MainActor func testDecisionActionsStayAboveComposerWhenKeyboardOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["pinned-bot-milo"].waitForExistence(timeout: 5))
        app.buttons["pinned-bot-milo"].tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let keep = app.buttons["Keep draft"]
        assertDecisionActionsVisible(in: app)
        keep.tap()
        XCTAssertTrue(app.staticTexts["Understood. I’ll keep the draft here."].waitForExistence(timeout: 3))
    }

    @MainActor func testInitialConversationShowsBothDecisionActionsAboveComposer() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let bot = app.buttons["pinned-bot-milo"]
        XCTAssertTrue(bot.waitForExistence(timeout: 5))
        bot.tap()
        let keep = app.buttons["Keep draft"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        assertDecisionActionsVisible(in: app)
        XCTAssertTrue(keep.isHittable,
                      "The newest decision must be reachable without scrolling on first load.")
        let profile = app.buttons["bot-profile-button"]
        XCTAssertTrue(profile.exists && profile.isHittable)
        captureReadingState(app, name: "Initial Milo history beneath the floating header with reachable approval actions")
        keep.tap()
        XCTAssertTrue(app.staticTexts["Understood. I’ll keep the draft here."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Allow once"].exists)
    }

    @MainActor func testReadingHistoryDoesNotJumpWhenKeyboardAndNewMessagesArrive() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let milo = app.buttons["pinned-bot-milo"]
        XCTAssertTrue(milo.waitForExistence(timeout: 5))
        milo.tap()
        let keep = app.buttons["Keep draft"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        XCTAssertTrue(app.staticTexts["Understood. I’ll keep the draft here."].waitForExistence(timeout: 3))
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("A little more conversation history")
        app.buttons["Send message"].tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "You’ve got the idea.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))

        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        transcript.swipeDown()
        transcript.swipeDown()
        let firstMessage = app.staticTexts["Help me get a handle on tomorrow."]
        XCTAssertTrue(firstMessage.isHittable)
        composer.tap()
        composer.typeText("Keep my place while replying")
        XCTAssertTrue(firstMessage.isHittable, "Opening the keyboard must preserve the history being read.")
        let readingY = firstMessage.frame.minY
        app.buttons["Send message"].tap()
        let latest = app.buttons["Latest messages"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["Send message"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 5), .completed)
        XCTAssertTrue(firstMessage.isHittable)
        XCTAssertEqual(firstMessage.frame.minY, readingY, accuracy: 2,
                       "Incoming content must not move the history being read.")
        latest.tap()
        XCTAssertTrue(app.staticTexts["Keep my place while replying"].isHittable)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "You’ve got the idea."))
            .allElementsBoundByIndex.contains { $0.isHittable })
    }

    @MainActor func testReadingHistoryDoesNotJumpWhenChatAccessRotates() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--rotate-chat-access-demo"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        app.launch()
        let milo = app.buttons["Milo, pinned"]
        XCTAssertTrue(milo.waitForExistence(timeout: 5))
        milo.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("A little more conversation history")
        XCTAssertEqual(composer.value as? String, "A little more conversation history")
        app.buttons["Send message"].tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "You’ve got the idea.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Sending…"].exists)
        XCTAssertTrue(["", "Message Milo"].contains(composer.value as? String ?? "<missing>"),
                      "The first admitted send must clear its captured draft after access rotates.")

        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        transcript.swipeDown()
        transcript.swipeDown()
        let firstMessage = app.staticTexts["Help me get a handle on tomorrow."]
        XCTAssertTrue(firstMessage.isHittable)
        composer.tap()
        composer.typeText("Keep my place while replying")
        XCTAssertEqual(composer.value as? String, "Keep my place while replying")
        // XCTest text injection can hide the software keyboard. Restore and
        // verify it before measuring the reader's position or sending.
        composer.tap()
        let keyboardVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            return keyboard.exists && keyboard.isHittable && keyboard.frame.height > 100 &&
                keyboard.frame.midY < app.frame.maxY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardVisible], timeout: 3), .completed)
        XCTAssertTrue(firstMessage.isHittable, "Opening the keyboard must preserve the history being read.")
        let readingY = firstMessage.frame.minY
        let hold = directory.appendingPathComponent("send-ack-2.hold")
        try Data().write(to: hold)
        app.buttons["Send message"].tap()
        let admitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("send-ack-2.started").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [admitted], timeout: 5), .completed)
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["Send message"].exists && app.staticTexts["Sending…"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed)
        let latest = app.buttons["Latest messages"]
        XCTAssertTrue(firstMessage.isHittable, "Refreshing same-chat access must preserve the old message being read.")
        XCTAssertEqual(firstMessage.frame.minY, readingY, accuracy: 2)
        XCTAssertTrue(latest.isHittable, "Latest must remain available while reading older messages.")

        try FileManager.default.removeItem(at: hold)
        let acknowledged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.staticTexts["Sending…"].exists &&
                ["", "Message Milo"].contains(composer.value as? String ?? "<missing>")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [acknowledged], timeout: 5), .completed,
                       "A positive ACK must settle the captured source after its grant retires.")
        XCTAssertTrue(firstMessage.isHittable)
        XCTAssertEqual(firstMessage.frame.minY, readingY, accuracy: 2,
                       "Completion and its late ACK must not move the history being read.")
        XCTAssertTrue(latest.isHittable, "Latest must remain until explicitly tapped.")
        latest.tap()
        assertDecisionActionsVisible(in: app)
        XCTAssertFalse(latest.exists)
    }

    @MainActor func testLongTranscriptOpensWithoutEagerlyRenderingHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--performance-demo", "--reduce-motion"]
        app.launch()
        let scout = app.buttons["Scout, pinned"]
        XCTAssertTrue(scout.waitForExistence(timeout: 10))
        let start = ContinuousClock.now
        let deadline = start + .seconds(10)
        scout.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        let finalMessage = app.descendants(matching: .any)["transcript-message-performance-399"]
        let finalParagraph = finalMessage.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Paragraph 7.")).firstMatch
        let transcript = app.descendants(matching: .any)["chat-transcript"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            composer.exists && composer.isEnabled && composer.isHittable &&
                finalParagraph.exists && finalParagraph.isHittable &&
                finalParagraph.frame.maxY <= composer.frame.minY &&
                RenderedTranscriptText.line("words arrive.", in: finalParagraph, viewport: transcript.frame, app: app) != nil
        }, object: nil)
        let remaining = ContinuousClock.now.duration(to: deadline)
        let timeout = max(0, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
                       "Message 399's end and an enabled, visible composer must be ready within ten seconds.")
        let elapsed = start.duration(to: .now)
        print("BOTTO_LONG_CHAT_READY seconds=\(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
        XCTAssertLessThan(elapsed, .seconds(10))
    }

    @MainActor func testPerformanceFixtureFirstStreamCompletesUnderBudget() throws {
        try performanceFixtureStreams(preservingReading: false)
    }

    @MainActor func testPerformanceFixtureStreamsWithoutLosingDraftOrReadingPosition() throws {
        try performanceFixtureStreams(preservingReading: true)
    }

    @MainActor private func performanceFixtureStreams(preservingReading: Bool) throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for invocation in 2...5 {
            try Data().write(to: directory.appendingPathComponent("performance-stream-\(invocation).hold"))
        }
        let app = XCUIApplication()
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        app.launchArguments = ["--demo", "--performance-demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.buttons["Scout, pinned"].waitForExistence(timeout: 10))
        app.buttons["Scout, pinned"].tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Stream the performance fixture")
        let streamStart = ContinuousClock.now
        let streamDeadline = streamStart + .seconds(20)
        app.buttons["Send message"].tap()
        let finished = app.staticTexts.containing(NSPredicate(format: "label ENDSWITH %@", "Performance stream 1 complete.")).firstMatch
        let remaining = ContinuousClock.now.duration(to: streamDeadline)
        let timeout = max(0, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
        let firstCompleted = finished.waitForExistence(timeout: timeout)
        if !firstCompleted { captureReadingState(app, name: "First stream deadline") }
        XCTAssertTrue(firstCompleted)
        let streamElapsed = streamStart.duration(to: .now)
        XCTAssertLessThan(streamElapsed, .seconds(20), "The budget includes the Send tap and completed reply.")
        print("BOTTO_NATIVE_STREAM seconds=\(Double(streamElapsed.components.seconds) + Double(streamElapsed.components.attoseconds) / 1e18) fragments=200")
        let words = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Word 199.")).firstMatch
        XCTAssertTrue(words.exists, "The final streamed words must reach the native transcript.")
        XCTAssertFalse(app.descendants(matching: .any)["chat-typing-indicator"].exists)
        XCTAssertFalse(app.buttons["Stop"].exists)
        if !preservingReading { return }
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        for cycle in 0..<3 {
            // Read the previous reply through its exact row identity. Its long text
            // spans several keyboard-sized viewports, so reach a visible point first.
            let historicalRow = app.otherElements["transcript-message-performance-reply-\(cycle + 1)"]
            let landmark = historicalRow.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Word 0.")).firstMatch
            let completionText = "Performance stream \(cycle + 1) complete."
            var calibration: RenderedTranscriptText.Observation?
            let calibrated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                calibration = RenderedTranscriptText.observe(completionText, in: landmark,
                    viewport: transcript.frame, app: app)
                return calibration != nil
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [calibrated], timeout: 5), .completed)
            let visibleCompletion = try XCTUnwrap(calibration, "Calibrate the actual completion in a stable text frame.")
            let calibratedSize = visibleCompletion.textFrame.size
            let completionInset = visibleCompletion.textFrame.maxY - visibleCompletion.bounds.minY
            func previousCompletion() -> CGRect {
                XCTAssertEqual(landmark.frame.size, calibratedSize, "The calibrated text layout must remain unchanged.")
                return CGRect(x: visibleCompletion.bounds.minX, y: landmark.frame.maxY - completionInset,
                              width: visibleCompletion.bounds.width, height: visibleCompletion.bounds.height)
            }
            let expectedWords = (0..<200).map { "Word \($0)." }.joined(separator: " ")
            var readingLine: ReadingLine?
            for attempt in 0...8 {
                if landmark.exists,
                   previousCompletion().minY > transcript.frame.maxY + 120 {
                    XCTAssertEqual(landmark.label.split(whereSeparator: \.isWhitespace).joined(separator: " "), expectedWords + " " + completionText)
                    readingLine = visibleReadingLine(app, paragraph: landmark, transcript: transcript)
                    if readingLine != nil {
                        // OCR uses another snapshot. Accept the reading position
                        // only if its required distance still holds afterward.
                        if previousCompletion().minY > transcript.frame.maxY + 120 { break }
                        readingLine = nil
                    }
                }
                if attempt == 8 { break }
                // Keep both ends inside the currently visible transcript. The
                // paragraph's AX hit point can lie several viewports above it.
                let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25))
                let end = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.75))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            captureReadingState(app, name: "Older reading precondition cycle \(cycle)")
            print("BOTTO_READING_START cycle=\(cycle) paragraph=\(landmark.frame) viewport=\(transcript.frame) completion=\(previousCompletion()) hittable=\(landmark.isHittable)")
            let originalLine = try XCTUnwrap(readingLine, "Actual words from the exact previous reply must be readable in cycle \(cycle).")
            XCTAssertGreaterThan(previousCompletion().minY, transcript.frame.maxY + 120,
                                 "Read more than the 90-point following threshold away from the newest content.")
            let readingY = landmark.frame.minY
            composer.tap()
            composer.typeText("Keep reading \(cycle)")
            app.buttons["Send message"].tap()
            XCTAssertTrue(app.buttons["Latest messages"].waitForExistence(timeout: 5))
            let paused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("performance-stream-\(cycle + 2).started").path)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
            XCTAssertTrue(app.buttons["Stop response"].exists)
            composer.tap()
            composer.typeText("Draft after send \(cycle)")
            XCTAssertEqual(composer.value as? String, "Draft after send \(cycle)")
            try FileManager.default.removeItem(at: directory.appendingPathComponent("performance-stream-\(cycle + 2).hold"))
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.buttons["Send message"].exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 20), .completed)
            XCTAssertEqual(composer.value as? String, "Draft after send \(cycle)")
            let readingFrame = landmark.frame
            XCTAssertEqual(readingFrame.minY, readingY, accuracy: 2)
            // This paragraph spans multiple viewports. Latest can cover its AX hit
            // point even while its text remains readable at the exact same offset.
            let readable = readingFrame.intersection(transcript.frame.insetBy(dx: 0, dy: 48))
            XCTAssertFalse(readable.isEmpty)
            XCTAssertGreaterThanOrEqual(readable.height, 40)
            captureReadingState(app, name: "Older reading after incoming cycle \(cycle)")
            let preservedLine = try XCTUnwrap(visibleReadingLine(app, paragraph: landmark, transcript: transcript,
                                                               matching: originalLine.words),
                                              "The same visible words must survive incoming content.")
            XCTAssertEqual(preservedLine.y, originalLine.y, accuracy: 2)
            print("BOTTO_READING cycle=\(cycle) beforeY=\(readingY) afterY=\(readingFrame.minY) visibleHeight=\(readable.height)")
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "Reading position and newer draft cycle \(cycle)"
            capture.lifetime = .keepAlways
            add(capture)
            app.buttons["Latest messages"].tap()
            let currentText = "Performance stream \(cycle + 2) complete."
            let currentCompletion = app.staticTexts.containing(NSPredicate(format: "label ENDSWITH %@", currentText)).firstMatch
            XCTAssertTrue(currentCompletion.waitForExistence(timeout: 5))
            XCTAssertTrue(currentCompletion.isHittable)
            let currentLine = try XCTUnwrap(RenderedTranscriptText.line(currentText, in: currentCompletion,
                viewport: transcript.frame, app: app), "Latest must reveal the actual completion line.")
            XCTAssertGreaterThan(currentLine.minY, app.navigationBars.firstMatch.frame.maxY)
            XCTAssertLessThanOrEqual(currentLine.maxY, composer.frame.minY)
            XCTAssertFalse(app.buttons["Latest messages"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["chat-typing-indicator"].exists)
            composer.tap()
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Draft after send \(cycle)".count))
        }
        // Returning while a reply is pending must survive the next live snapshot.
        transcript.swipeDown()
        transcript.swipeDown()
        composer.tap()
        composer.typeText("Follow the pending reply")
        app.buttons["Send message"].tap()
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("performance-stream-5.started").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["Stop response"].exists)
        composer.tap()
        composer.typeText("Draft while following")
        XCTAssertTrue(app.buttons["Latest messages"].waitForExistence(timeout: 5))
        app.buttons["Latest messages"].tap()
        let pendingRow = app.otherElements["transcript-message-performance-reply-5"]
        let pendingWords = pendingRow.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Word 19.")).firstMatch
        XCTAssertTrue(pendingWords.waitForExistence(timeout: 5))
        XCTAssertTrue(pendingWords.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["chat-typing-indicator"].isHittable)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("performance-stream-5.hold"))
        let finalCompletion = pendingRow.staticTexts.containing(NSPredicate(format: "label ENDSWITH %@", "Performance stream 5 complete.")).firstMatch
        let finalReplyCompleted = finalCompletion.waitForExistence(timeout: 20)
        if !finalReplyCompleted {
            let globalCompletion = app.staticTexts.containing(NSPredicate(format: "label ENDSWITH %@", "Performance stream 5 complete.")).firstMatch.exists
            let sendAvailable = app.buttons["Send message"].exists
            print("BOTTO_FINAL_REPLY globalCompletion=\(globalCompletion) sendAvailable=\(sendAvailable)")
            let failure = XCTAttachment(screenshot: app.screenshot())
            failure.name = "Fifth reply after completion deadline"
            failure.lifetime = .keepAlways
            add(failure)
        }
        XCTAssertTrue(finalReplyCompleted)
        XCTAssertTrue(finalCompletion.isHittable)
        let finalLine = try XCTUnwrap(RenderedTranscriptText.line("Performance stream 5 complete.", in: finalCompletion,
            viewport: transcript.frame, app: app), "The final completion must actually paint above the composer.")
        XCTAssertLessThanOrEqual(finalLine.maxY, composer.frame.minY)
        XCTAssertFalse(app.descendants(matching: .any)["chat-typing-indicator"].exists)
        XCTAssertFalse(app.buttons["Latest messages"].exists)
        XCTAssertEqual(composer.value as? String, "Draft while following")
    }

    @MainActor func testTypedDraftSurvivesSwitchingBots() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let milo = app.buttons["pinned-bot-milo"]
        XCTAssertTrue(milo.waitForExistence(timeout: 5))
        milo.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("A thought to keep")
        WorkspaceNavigation.browseBots(in: app)
        app.buttons["pinned-bot-scout"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-composer"].waitForExistence(timeout: 3))
        WorkspaceNavigation.browseBots(in: app)
        app.buttons["pinned-bot-milo"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["chat-composer"].value as? String, "A thought to keep")
    }
    @MainActor private func captureReadingState(_ app: XCUIApplication, name: String) {
        let pixels = XCTAttachment(screenshot: app.screenshot())
        pixels.name = name
        pixels.lifetime = .keepAlways
        add(pixels)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private struct ReadingLine {
        let words: [Int]
        let y: CGFloat
    }

    @MainActor private func visibleReadingLine(_ app: XCUIApplication, paragraph: XCUIElement,
                                               transcript: XCUIElement, matching expected: [Int]? = nil) -> ReadingLine? {
        guard paragraph.exists else { return nil }
        let region = paragraph.frame.intersection(transcript.frame.insetBy(dx: 0, dy: 48)).intersection(app.frame)
        guard !region.isNull, region.height >= 40,
              let image = app.screenshot().image.cgImage else { return nil }
        let frame = app.frame
        let scaleX = CGFloat(image.width) / frame.width
        let scaleY = CGFloat(image.height) / frame.height
        let pixels = CGRect(x: (region.minX - frame.minX) * scaleX,
                            y: (region.minY - frame.minY) * scaleY,
                            width: region.width * scaleX, height: region.height * scaleY)
        guard let cropped = image.cropping(to: pixels.integral) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request]) }
        catch { return nil }
        let regex = try! NSRegularExpression(pattern: #"\bWord\s+(\d+)\b"#)
        for line in request.results ?? [] {
            guard let text = line.topCandidates(1).first?.string else { continue }
            let words = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Int? in
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                return Int(text[range])
            }
            guard words.count >= 3 else { continue }
            for offset in 0...(words.count - 3) {
                let sequence = Array(words[offset..<(offset + 3)])
                guard sequence[0] >= 0, sequence[2] < 200,
                      sequence[1] == sequence[0] + 1, sequence[2] == sequence[1] + 1,
                      expected == nil || sequence == expected else { continue }
                let y = (pixels.integral.minY + (1 - line.boundingBox.maxY) * CGFloat(cropped.height)) / scaleY + frame.minY
                return ReadingLine(words: sequence, y: y)
            }
        }
        return nil
    }

}
