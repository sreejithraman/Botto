import XCTest

/// Real Canvas regression. The optical component loop additionally samples
/// frames during scroll itself; XCTest queries observe the settled UI boundary.
final class DiagramScrollUITests: XCTestCase {
    @MainActor func testDiagramPixelsRemainAvailableAcrossRepeatedScrollAndExpansion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        WorkspaceNavigation.revealBot("bot-row-canvas", in: app)
        let canvas = app.buttons["bot-row-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.tap()
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 6)
        let source = app.buttons["Show Mermaid source"]
        func revealDiagram() {
            for _ in 0..<8 {
                let viewport = transcript.frame.intersection(app.frame)
                let delta: CGFloat
                if source.exists && !source.frame.isEmpty {
                    let top = max(viewport.minY, app.navigationBars.firstMatch.frame.maxY) + 80
                    delta = source.frame.midY - top
                    if abs(delta) <= 16 { return }
                } else {
                    delta = -viewport.height * 0.4
                }
                let distance = max(-viewport.height * 0.4, min(viewport.height * 0.4, delta))
                // Stay in the outer gutter and hold before release, including
                // while finding the header, so inertia cannot hide the pixels.
                let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: distance > 0 ? 0.75 : 0.25))
                let end = start.withOffset(CGVector(dx: 0, dy: -distance))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            }
            XCTFail("The Canvas diagram must be reachable")
        }
        revealDiagram()
        let pixels = app.images["Mermaid diagram"].firstMatch
        XCTAssertTrue(pixels.waitForExistence(timeout: 21), "The public diagram must produce native rendered pixels")
        assertControlsOutsideDiagram(in: app)
        for index in 0..<3 {
            transcript.swipeUp()
            transcript.swipeUp()
            Thread.sleep(forTimeInterval: index == 0 ? 6 : 0.5)
            revealDiagram()
            let visibleReturn = NSPredicate { _, _ in pixels.exists && pixels.isHittable }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visibleReturn, object: nil)], timeout: 3), .completed,
                           "A rendered diagram must keep visible native pixels on return")
            assertControlsOutsideDiagram(in: app)
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "Canvas diagram return \(index)"
            capture.lifetime = .keepAlways
            add(capture)
        }
        XCTAssertTrue(source.isEnabled && source.isHittable)
        source.tap()
        XCTAssertTrue(app.buttons["Close Mermaid source"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["Preview source"].exists)
        app.buttons["Close Mermaid source"].tap()
        XCTAssertTrue(pixels.waitForExistence(timeout: 3))
        let expand = app.buttons["Expand Mermaid diagram"]
        XCTAssertTrue(expand.isEnabled && expand.isHittable)
        expand.tap()
        XCTAssertTrue(app.buttons["Close Mermaid diagram"].waitForExistence(timeout: 3))
        let visiblePixels = NSPredicate { _, _ in
            app.images.matching(identifier: "Mermaid diagram").allElementsBoundByIndex.contains { $0.isHittable }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visiblePixels, object: nil)], timeout: 21), .completed)
        assertControlsOutsideDiagram(in: app)
        XCTAssertTrue(app.buttons["Show Mermaid source"].exists)
        guard let zoom = app.buttons.matching(identifier: "Zoom diagram").allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("Expanded diagrams must expose an accessible zoom control"); return
        }
        zoom.tap()
        guard let fit = app.buttons.matching(identifier: "Fit diagram").allElementsBoundByIndex.first(where: { $0.isHittable && $0.isEnabled }) else {
            XCTFail("Zoomed diagrams must expose an accessible reset control"); return
        }
        fit.tap()
        assertControlsOutsideDiagram(in: app)
        // Native toolbar pills can report visual bounds smaller than their hit
        // targets. Exercise both ends of a 44-point target instead of measuring
        // the pill. Custom inline/zoom controls keep their bounds checks below.
        for verticalOffset in [-21.0, 21.0] {
            guard let toolbarSource = app.buttons.matching(identifier: "Show Mermaid source")
                .allElementsBoundByIndex.first(where: { $0.isHittable }) else {
                XCTFail("Expanded diagrams must expose their native Source action"); return
            }
            toolbarSource.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: verticalOffset)).tap()
            XCTAssertTrue(app.buttons["Close Mermaid source"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.descendants(matching: .any)["Preview source"].exists)
            app.buttons["Close Mermaid source"].tap()
            XCTAssertTrue(pixels.waitForExistence(timeout: 3))
            expand.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visiblePixels, object: nil)], timeout: 21), .completed)
            assertControlsOutsideDiagram(in: app)
        }
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Expanded Canvas diagram"
        expanded.lifetime = .keepAlways
        add(expanded)
        app.buttons["Close Mermaid diagram"].tap()
        XCTAssertTrue(pixels.waitForExistence(timeout: 3))
        assertControlsOutsideDiagram(in: app)
    }

    @MainActor private func assertControlsOutsideDiagram(in app: XCUIApplication) {
        // XCUI's screen transforms can round a 44-point side just below 44.
        let coordinateTolerance: CGFloat = 0.000001
        guard let image = app.images.matching(identifier: "Mermaid diagram").allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("The fitted diagram must be visible"); return
        }
        let expanded = app.buttons["Close Mermaid diagram"].exists
        let viewport = expanded ? app.frame : app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch.frame.intersection(app.frame)
        XCTAssertTrue(viewport.contains(image.frame), "The full fitted diagram must be inside the viewport.")
        var controls: [XCUIElement] = []
        for name in ["Zoom diagram", "Fit diagram"] {
            guard let control = app.buttons.matching(identifier: name).allElementsBoundByIndex.first(where: {
                !$0.frame.isEmpty && viewport.contains($0.frame)
            }) else {
                XCTFail("The diagram must expose \(name)"); continue
            }
            if name == "Fit diagram" {
                XCTAssertFalse(control.isEnabled, "Fit is disabled while the diagram is already fitted.")
            } else {
                XCTAssertTrue(control.isEnabled && control.isHittable)
            }
            XCTAssertGreaterThanOrEqual(control.frame.minY, image.frame.maxY,
                                        "Diagram controls must sit below the pixels in both inline and expanded views")
            XCTAssertGreaterThanOrEqual(control.frame.height + coordinateTolerance, 44)
            XCTAssertGreaterThanOrEqual(control.frame.width + coordinateTolerance, 44)
            controls.append(control)
        }
        if controls.count == 2 {
            XCTAssertFalse(controls[0].frame.intersects(controls[1].frame), "Zoom and Fit must not overlap")
        }
        for name in expanded ? ["Show Mermaid source"] : ["Show Mermaid source", "Expand Mermaid diagram"] {
            guard let control = app.buttons.matching(identifier: name).allElementsBoundByIndex.first(where: {
                $0.isHittable && viewport.contains($0.frame)
            }) else {
                XCTFail("The diagram must expose a fully visible \(name)"); continue
            }
            XCTAssertTrue(control.isEnabled)
            if !expanded { XCTAssertGreaterThanOrEqual(control.frame.height + coordinateTolerance, 44) }
            XCTAssertGreaterThanOrEqual(control.frame.width + coordinateTolerance, 44)
            XCTAssertFalse(control.frame.intersects(image.frame), "Source and Expand must not cover the pixels")
            for other in controls {
                XCTAssertFalse(control.frame.intersects(other.frame), "Diagram actions must not overlap")
            }
            controls.append(control)
        }
    }
}
