import XCTest

final class DeveloperToolsUITests: XCTestCase {
    @MainActor func testDeveloperToolsMatchBuildConfiguration() throws {
        #if targetEnvironment(simulator)
        let configuration = try XCTUnwrap(Bundle(for: Self.self)
            .object(forInfoDictionaryKey: "BottoBuildConfiguration") as? String)
        let app = openSettings()
        switch configuration {
        case "Debug", "Internal":
            let developer = app.buttons["settings.developerMenu"]
            reveal(developer, in: app)
            XCTAssertTrue(developer.waitForExistence(timeout: 5))
            developer.tap()
            app.buttons["developer.avatarPlayground"].tap()
            XCTAssertTrue(app.navigationBars["Avatar playground"].waitForExistence(timeout: 5))
            app.buttons["Try in demo"].tap()
            XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
            visibleButton("Settings", in: app).tap()
            visibleButton("Leave demo", in: app).tap()
            XCTAssertTrue(app.navigationBars["Avatar playground"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Try in demo"].exists)
            XCTAssertFalse(app.buttons["Connect your Hermes"].isHittable)
            app.buttons["Done"].tap()
            XCTAssertTrue(app.buttons["developer.hapticsPlayground"].waitForExistence(timeout: 5))
            app.buttons["developer.hapticsPlayground"].tap()
            XCTAssertTrue(app.navigationBars["Haptics"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["haptics.mode"].exists)
            app.buttons["Done"].tap()
            XCTAssertTrue(app.buttons["developer.avatarPlayground"].waitForExistence(timeout: 5))
        case "Release":
            XCTAssertTrue(app.buttons["settings.haptics"].exists)
            reveal(app.buttons["Open-source licenses"], in: app)
            XCTAssertTrue(app.buttons["Open-source licenses"].exists)
            XCTAssertFalse(app.buttons["settings.developerMenu"].exists)
        default:
            XCTFail("Unexpected build configuration: \(configuration)")
        }
        app.terminate()
        let ordinaryDemo = openSettings()
        visibleButton("Leave demo", in: ordinaryDemo).tap()
        XCTAssertTrue(ordinaryDemo.buttons["Explore the demo"].waitForExistence(timeout: 5))
        #else
        throw XCTSkip("This automated check uses Simulator-only isolated connection storage.")
        #endif
    }

    @MainActor private func openSettings() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--isolated-ui-test"]
        app.launch()
        addTeardownBlock { app.terminate() }
        let demo = app.buttons["Explore the demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }

    @MainActor private func visibleButton(_ name: String, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<6 {
            if let button = app.buttons.matching(identifier: name).allElementsBoundByIndex.first(where: { $0.isHittable }) {
                return button
            }
            app.swipeUp()
        }
        XCTFail("Missing visible button: \(name)")
        return app.buttons[name].firstMatch
    }
}
