import XCTest
import BottoCore

/// Exercises NewBotView through the real shared sheet and external-link path.
final class NewBotUITests: XCTestCase {
    @MainActor func testOfflineFormWaitsForCreateAndRecoveryRequiresDeliberateRetry() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-offline"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launch()
        XCTAssertTrue(app.buttons["New bot"].waitForExistence(timeout: 5))
        app.buttons["New bot"].tap()
        let name = app.textFields["What shall we call them?"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["You’re offline"].exists)
        name.tap(); name.typeText("Orbit")
        app.swipeUp()
        let create = app.buttons["Create bot"]
        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(app.staticTexts["You’re offline"].waitForExistence(timeout: 3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("create.started").path))
        app.buttons["Reconnect"].tap()
        XCTAssertTrue(app.staticTexts["You’re offline"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("create.started").path))
        XCTAssertEqual(name.value as? String, "Orbit")
        create.tap()
        XCTAssertTrue(app.buttons["Profile for Orbit"].waitForExistence(timeout: 5))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("create.calls"), encoding: .utf8), "1")
    }

    @MainActor private func beginCreation(holding operation: String?) throws -> (XCUIApplication, URL) {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let operation { try Data().write(to: directory.appendingPathComponent("\(operation).hold")) }
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        app.launch()
        XCTAssertTrue(app.buttons["New bot"].waitForExistence(timeout: 5))
        app.buttons["New bot"].tap()
        let name = app.textFields["What shall we call them?"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Orbit")
        app.swipeUp()
        app.buttons["Create bot"].tap()
        return (app, directory)
    }

    private func waitForReturn(_ operation: String, in directory: URL) {
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(operation).returned").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
    }

    @MainActor private func replaceSheet(in app: XCUIApplication, holding operation: String, directory: URL) {
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(operation).started").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed)
        // The system opens the link in the existing scene. App.open would
        // relaunch Botto and discard the pending operation we need to exercise.
        XCUIDevice.shared.system.open(URL(string: "botto://hermes/connect?url=https%3A%2F%2Freplacement.example")!)
        XCTAssertTrue(app.navigationBars["Connect Hermes"].waitForExistence(timeout: 3))
        let review = app.buttons["Review destination"]
        for _ in 0..<8 where !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.isHittable)
        review.tap()
        XCTAssertTrue(app.staticTexts["https://replacement.example"].waitForExistence(timeout: 3))
    }

    @MainActor func testLateCreateDoesNotNavigateOrDismissReplacementConnection() throws {
        try assertLateCreationPreservesReplacement(holding: "create")
    }

    @MainActor func testLateRefreshDoesNotNavigateOrDismissReplacementConnection() throws {
        try assertLateCreationPreservesReplacement(holding: "refresh")
    }

    @MainActor private func assertLateCreationPreservesReplacement(holding operation: String) throws {
        let (app, directory) = try beginCreation(holding: operation)
        replaceSheet(in: app, holding: operation, directory: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(operation).hold"))
        waitForReturn(operation, in: directory)
        XCTAssertTrue(app.navigationBars["Connect Hermes"].exists)
        XCTAssertTrue(app.staticTexts["https://replacement.example"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["New bot"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["chat-composer"].exists)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("create.calls"), encoding: .utf8), "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("open.started").path))
    }

    @MainActor func testLateOpenDoesNotDismissReplacementConnection() throws {
        let (app, directory) = try beginCreation(holding: "open")
        replaceSheet(in: app, holding: "open", directory: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("open.hold"))
        waitForReturn("open", in: directory)
        XCTAssertTrue(app.navigationBars["Connect Hermes"].exists)
        XCTAssertTrue(app.staticTexts["https://replacement.example"].exists)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("create.calls"), encoding: .utf8), "1")
    }

    @MainActor func testCurrentPresentationCreatesOpensAndDismisses() throws {
        let (app, directory) = try beginCreation(holding: "create")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("create.hold"))
        XCTAssertTrue(app.descendants(matching: .any)["chat-composer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Hi, I’m Orbit. What would you like to work on?"].exists)
        let creationSheet = app.navigationBars["New bot"]
        let dismissed = creationSheet.waitForNonExistence(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = dismissed ? "Created Orbit after sheet dismissal" : "Orbit creation sheet did not dismiss"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if !dismissed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Orbit creation dismissal hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(dismissed)
        XCTAssertFalse(creationSheet.exists)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("create.calls"), encoding: .utf8), "1")
    }
}
