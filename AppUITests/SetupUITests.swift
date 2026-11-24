import XCTest

final class SetupUITests: XCTestCase {
    @MainActor func testPairingLinkReviewsDestinationAndRequiresHTTPConsent() {
        continueAfterFailure = false
        let app = launch()
        XCUIDevice.shared.system.open(URL(string:
            "t3code://pair?url=http%3A%2F%2F192.168.1.10%3A3774&token=sample")!)
        let destination = app.staticTexts["t3-pair-destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 8))
        XCTAssertEqual(destination.label, "http://192.168.1.10:3774")
        let connect = app.buttons["t3-pair-connect"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled)
        let consent = app.switches["t3-pair-allow-http"]
        XCTAssertTrue(consent.isHittable)
        consent.tap()
        XCTAssertTrue(connect.isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Explore the demo"].waitForExistence(timeout: 5))
    }

    @MainActor func testManualPairingShowsScannerAndExplicitAddressReview() {
        continueAfterFailure = false
        let app = launch()
        app.buttons["Pair with your Mac"].tap()
        let scan = app.buttons["t3-pair-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan your Mac’s code"].waitForExistence(timeout: 5))
        let link = app.textViews["Pairing link"].firstMatch
        let field = link.exists ? link : app.textFields["Pairing link"].firstMatch
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText("https://mac.example/pair#token=sample")
        app.buttons["Review Address"].tap()
        XCTAssertEqual(app.staticTexts["t3-pair-destination"].label, "https://mac.example")
        XCTAssertTrue(app.buttons["t3-pair-connect"].isEnabled)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--isolated-ui-test"]
        app.launch()
        XCTAssertTrue(app.buttons["Pair with your Mac"].waitForExistence(timeout: 5))
        return app
    }
}
