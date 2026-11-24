import XCTest

final class AvatarUITests: XCTestCase {
    @MainActor func testOpeningBotPageAndCancelingALookPreservesTheDraft() {
        continueAfterFailure = false
        let app = launch()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("A draft for later")

        openLook(in: app)
        chooseShape("drop", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["botto-page-done"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "A draft for later")

        openLook(in: app)
        XCTAssertTrue(app.buttons["avatar-shape-squircle"].isSelected)
    }

    @MainActor func testExistingAvatarSaveUpdatesTheSharedPickerSelection() {
        continueAfterFailure = false
        let app = launch()
        openLook(in: app)
        chooseShape("drop", in: app)
        let save = app.buttons["botto-look-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.buttons["botto-page-change-look"].waitForExistence(timeout: 6))
        app.buttons["botto-page-change-look"].tap()
        XCTAssertTrue(app.buttons["avatar-shape-drop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["avatar-shape-drop"].isSelected)
    }

    @MainActor func testLargestTextWithReducedMotionCanReachAvatarChoices() {
        continueAfterFailure = false
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "--reduce-motion"])
        openLook(in: app)
        chooseShape("drop", in: app)
        let save = app.buttons["botto-look-save"]
        XCTAssertTrue(save.isHittable && save.isEnabled)
    }

    @MainActor func testDemoSampleCharacterCanBeColoredSavedAndRestoredAfterCancel() {
        continueAfterFailure = false
        let app = launch()
        openLook(in: app)
        app.buttons["Preview sample character"].tap()
        let cat = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Cat ·")).firstMatch
        XCTAssertTrue(cat.waitForExistence(timeout: 5))
        let teal = app.buttons["avatar-color-teal"]
        for _ in 0..<8 where !teal.isHittable { app.swipeUp() }
        XCTAssertTrue(teal.isHittable && teal.isEnabled)
        teal.tap()
        XCTAssertTrue(teal.isSelected)
        app.buttons["botto-look-save"].tap()

        let look = app.buttons["botto-page-change-look"]
        XCTAssertTrue(look.waitForExistence(timeout: 5))
        look.tap()
        XCTAssertTrue(cat.waitForExistence(timeout: 5))
        for _ in 0..<8 where !teal.isHittable { app.swipeUp() }
        XCTAssertTrue(teal.isSelected)
        for _ in 0..<8 where !app.buttons["avatar-shape-circle"].isHittable { app.swipeDown() }
        chooseShape("circle", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        look.tap()
        XCTAssertTrue(cat.waitForExistence(timeout: 5))
        for _ in 0..<8 where !teal.isHittable { app.swipeUp() }
        XCTAssertTrue(teal.isSelected)
    }

    @MainActor private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--isolated-ui-test", "--demo"] + arguments
        app.launch()
        return app
    }

    @MainActor private func openLook(in app: XCUIApplication) {
        let header = app.buttons["t3-chat-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        header.tap()
        let look = app.buttons["botto-page-change-look"]
        XCTAssertTrue(look.waitForExistence(timeout: 5))
        look.tap()
        XCTAssertTrue(app.buttons["botto-look-save"].waitForExistence(timeout: 5))
    }

    @MainActor private func chooseShape(_ shape: String, in app: XCUIApplication) {
        let choice = app.buttons["avatar-shape-" + shape]
        for _ in 0..<6 where !choice.isHittable { app.swipeUp() }
        XCTAssertTrue(choice.isHittable)
        choice.tap()
        XCTAssertTrue(choice.isSelected)
    }
}
