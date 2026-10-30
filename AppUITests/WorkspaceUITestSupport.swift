import XCTest
import Vision

@MainActor enum RenderedTranscriptText {
    struct Observation {
        let bounds: CGRect
        let textFrame: CGRect
    }
    static func line(_ text: String, in element: XCUIElement, viewport: CGRect,
                     app: XCUIApplication) -> CGRect? {
        observe(text, in: element, viewport: viewport, app: app)?.bounds
    }
    static func observe(_ text: String, in element: XCUIElement, viewport: CGRect,
                     app: XCUIApplication) -> Observation? {
        guard element.exists else { return nil }
        let textFrame = element.frame, appFrame = app.frame
        let region = textFrame.intersection(viewport).intersection(appFrame)
        guard !region.isNull, region.width > 0, region.height > 0,
              let image = app.screenshot().image.cgImage else { return nil }
        let scaleX = CGFloat(image.width) / appFrame.width
        let scaleY = CGFloat(image.height) / appFrame.height
        let pixels = CGRect(x: (region.minX - appFrame.minX) * scaleX,
                            y: (region.minY - appFrame.minY) * scaleY,
                            width: region.width * scaleX, height: region.height * scaleY).integral
        guard let crop = image.cropping(to: pixels) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: crop).perform([request])
            let matches = try (request.results ?? []).compactMap { observation -> CGRect? in
                guard let candidate = observation.topCandidates(1).first,
                      let range = candidate.string.range(of: text),
                      let box = try candidate.boundingBox(for: range)?.boundingBox else { return nil }
                return CGRect(x: appFrame.minX + (pixels.minX + box.minX * CGFloat(crop.width)) / scaleX,
                              y: appFrame.minY + (pixels.minY + (1 - box.maxY) * CGFloat(crop.height)) / scaleY,
                              width: box.width * CGFloat(crop.width) / scaleX,
                              height: box.height * CGFloat(crop.height) / scaleY)
            }
            guard let bounds = matches.max(by: { $0.maxY < $1.maxY }),
                  element.frame == textFrame, app.frame == appFrame,
                  textFrame.insetBy(dx: -1, dy: -1).contains(bounds) else { return nil }
            return Observation(bounds: bounds, textFrame: textFrame)
        } catch { return nil }
    }
}

/// The file pane owns one native Actions menu. Menu items may be exposed as
/// cells or buttons, depending on the OS presentation.
@MainActor enum ArtifactOutputActions {
    static func dismissalCoordinate(for reader: XCUIElement, in app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) -> XCUICoordinate? {
        let window = app.frame
        let document = reader.frame.intersection(window)
        guard !window.isNull && !window.isInfinite && window.width > 0 && window.height > 0,
              !document.isNull && !document.isInfinite && document.width > 0 && document.height > 0 else {
            XCTFail("Dismissing Actions requires a visible document inside the app window.", file: file, line: line)
            return nil
        }
        // Freeze the verified document point before presenting the menu. The
        // app root keeps its window coordinate space while the reader is covered.
        let point = CGPoint(x: document.midX, y: document.minY + document.height * 0.8)
        return app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: point.x - window.minX, dy: point.y - window.minY))
    }

    static func dismissShare(in app: XCUIApplication, timeout: TimeInterval = 5,
                             file: StaticString = #filePath, line: UInt = #line) {
        let sheet = app.otherElements["ActivityListView"].firstMatch
        guard sheet.waitForExistence(timeout: timeout) else {
            XCTFail("The native Share sheet must be present before cancellation.", file: file, line: line)
            return
        }
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", "header.closeButton", "Close")
        let buttons = sheet.buttons.matching(predicate).allElementsBoundByIndex.filter { $0.isEnabled && $0.isHittable }
        guard buttons.count == 1, let close = buttons.first else {
            XCTFail("The native Share sheet must have one usable Close control.", file: file, line: line)
            return
        }
        close.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { !sheet.exists }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: timeout), .completed,
                       "Cancel must dismiss the actual native Share sheet.", file: file, line: line)
    }

    static func action(_ identifier: String, label: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)
        let row = app.cells.matching(predicate).firstMatch
        return row.exists ? row : app.buttons.matching(predicate).firstMatch
    }

    static func open(in app: XCUIApplication, timeout: TimeInterval = 15,
                     file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.buttons["artifact-actions"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { menu.exists && menu.isHittable && menu.isEnabled }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
                       "The loaded file must offer a reachable Actions menu.", file: file, line: line)
        menu.tap()
    }

    static func assertAvailable(in app: XCUIApplication, timeout: TimeInterval = 15,
                                file: StaticString = #filePath, line: UInt = #line) {
        let reader = app.descendants(matching: .any)["artifact-preview"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: timeout) && reader.isHittable, file: file, line: line)
        guard let dismiss = dismissalCoordinate(for: reader, in: app, file: file, line: line) else { return }
        open(in: app, timeout: timeout, file: file, line: line)
        for (identifier, label) in [("artifact-save", "Save to Files"), ("artifact-share", "Share")] {
            let item = action(identifier, label: label, in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5) && item.isHittable && item.isEnabled,
                          "The actual \(label) menu action must be usable.", file: file, line: line)
        }
        // This content coordinate was verified before presenting the menu.
        dismiss.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let save = action("artifact-save", label: "Save to Files", in: app)
                let share = action("artifact-share", label: "Share", in: app)
                let menu = app.buttons["artifact-actions"].firstMatch
                return !(save.exists && save.isHittable) && !(share.exists && share.isHittable) &&
                    reader.exists && reader.isHittable && menu.exists && menu.isHittable
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed,
                       "Dismissing Actions must return to the usable preview.", file: file, line: line)
    }
}

@MainActor enum WorkspaceNavigation {
    static func revealBot(_ identifier: String, in app: XCUIApplication, maximumSwipes: Int = 8,
                          file: StaticString = #filePath, line: UInt = #line) {
        let list = app.scrollViews["bot-inbox"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), file: file, line: line)
        let row = app.buttons[identifier]
        for _ in 0..<maximumSwipes where !row.isHittable { list.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable, file: file, line: line)
    }

    static func displaysChat(_ title: String, in app: XCUIApplication) -> Bool {
        let header = app.buttons["chat-picker-button"]
        let overview = app.descendants(matching: .any).matching(identifier: "chat-picker").firstMatch
        return !overview.exists && header.exists && header.isHittable && header.isEnabled && header.value as? String == title
    }

    static func browseBots(in app: XCUIApplication, expectedBotRow: String? = nil,
                           file: StaticString = #filePath, line: UInt = #line) {
        let explicit = app.descendants(matching: .any).matching(identifier: "workspace-browse-bots").firstMatch
        if explicit.exists && explicit.isHittable {
            explicit.tap()
        } else {
            XCTAssertFalse(app.descendants(matching: .any)["artifact-preview"].exists,
                           "A file uses its explicit Bots control.", file: file, line: line)
            let predicate = NSPredicate(format: "identifier == %@ OR label == %@", "BackButton", "Back")
            // Native navigation can place Back in its reserved toolbar rail.
            let native = app.descendants(matching: .any).matching(predicate).firstMatch
            XCTAssertTrue(native.exists && native.isHittable && native.isEnabled,
                          "Chat-only navigation must offer native Back.", file: file, line: line)
            native.tap()
        }
        let destination = expectedBotRow.map { app.buttons[$0] } ?? app.scrollViews["bot-inbox"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5),
                      "Browsing must reach the actual Bots list.", file: file, line: line)
    }
}
