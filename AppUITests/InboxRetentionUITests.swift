import XCTest
import Vision

final class InboxRetentionUITests: XCTestCase {
    @MainActor func testHTMLArtifactCoversRenderWithoutOpeningTheReader() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Artifacts"].tap()
        let gallery = app.scrollViews["artifact-library"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        let png = app.buttons["library-artifact-chart.png"]
        for _ in 0..<8 {
            if png.exists && png.isHittable { break }
            gallery.swipeUp()
        }
        XCTAssertTrue(png.waitForExistence(timeout: 5))
        let imageReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { self.hasRenderedChartColors(png) }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [imageReady], timeout: 15), .completed,
                       "The PNG must display its colored chart before any reader is opened.")
        for (title, renderedText) in [("HTML preview", "Launch dashboard"), ("inline-visual-test.html", "File preview")] {
            let card = app.buttons["library-artifact-\(title)"]
            for _ in 0..<8 {
                if card.exists && card.isHittable { break }
                gallery.swipeUp()
            }
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    RenderedTranscriptText.line(renderedText, in: card, viewport: card.frame, app: app) != nil
                }
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed,
                           "The gallery must show a rendered HTML cover before the reader is opened.")
            XCTAssertFalse(app.buttons["artifact-done"].exists)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Automatic gallery cover for \(title)"; image.lifetime = .keepAlways; add(image)
        }
    }

    @MainActor func testReopeningArtifactsKeepsItsRenderedCovers() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion", "-botto.appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Artifacts"].tap()
        let png = app.buttons["library-artifact-chart.png"]
        XCTAssertTrue(png.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { self.hasRenderedChartColors(png) }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        let position = png.frame
        for _ in 0..<3 {
            app.tabBars.buttons["Bots"].tap()
            app.tabBars.buttons["Artifacts"].tap()
            XCTAssertTrue(png.exists && png.isHittable)
            XCTAssertTrue(hasRenderedChartColors(png))
            XCTAssertEqual(png.frame.minY, position.minY, accuracy: 1)
            XCTAssertFalse(app.otherElements["library-status"].exists)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Three gallery reopens keep cached covers and card position"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor private func hasRenderedChartColors(_ card: XCUIElement) -> Bool {
        guard card.exists, card.isHittable, let image = card.screenshot().image.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        var blue = 0, green = 0
        for offset in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            if pixels[offset] < 120 && pixels[offset + 2] > 180 { blue += 1 }
            if pixels[offset] < 80 && pixels[offset + 1] > 160 && pixels[offset + 2] < 140 { green += 1 }
        }
        return blue > 100 && green > 100
    }

    @MainActor func testSearchJumpsToAnOlderMatchInsideATallMessage() {
        assertSearchRevealsOlderMatch(keepingDraft: true)
    }

    @MainActor func testSearchJumpFromBotsOpensTheExactOlderMessage() {
        assertSearchRevealsOlderMatch(keepingDraft: false)
    }

    @MainActor private func assertSearchRevealsOlderMatch(keepingDraft: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion", "--search-navigation-proof"]
        app.launchArguments += ["-botto.appearance", keepingDraft ? "light" : "dark"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        let composer = app.descendants(matching: .any)["chat-composer"]
        let draft = keepingDraft ? "Keep my draft while I find an older message" : ""
        if keepingDraft {
            app.buttons["bot-row-canvas"].tap()
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            composer.tap(); composer.typeText(draft)
            WorkspaceNavigation.browseBots(in: app)
        }
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Copper lantern checkpoint")
        let result = app.buttons["library-message-search-deep-user-match"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()

        let transcript = app.descendants(matching: .any)["chat-transcript"]
        let message = app.descendants(matching: .any)["transcript-message-search-deep-user-match"]
        let text = message.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Copper lantern checkpoint")).firstMatch
        let visibleMatch = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                guard transcript.exists, composer.exists, composer.isEnabled,
                      (composer.value as? String ?? "") == draft else { return false }
                let viewport = transcript.frame.intersection(CGRect(x: app.frame.minX, y: app.frame.minY,
                    width: app.frame.width, height: max(0, composer.frame.minY - app.frame.minY)))
                return RenderedTranscriptText.line("Copper lantern", in: text,
                    viewport: viewport, app: app) != nil &&
                    RenderedTranscriptText.line("checkpoint", in: text, viewport: viewport, app: app) != nil
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleMatch], timeout: 15), .completed,
            "The actual matching glyphs must be visible without a corrective swipe; exposing the tall message's top is insufficient.")
        XCTAssertTrue(app.buttons["chat-picker-button"].label.contains("Canvas"))
        let tail = app.descendants(matching: .any)["transcript-message-search-history-tail"]
        XCTAssertFalse(tail.exists && tail.isHittable, "Opening the origin at its newest message is not a successful match jump.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Older Search match visible inside a tall native message"
        screenshot.lifetime = .keepAlways; add(screenshot)

        assertTranscriptDoesNotShowThroughControls(in: app, composer: composer)

        let latest = app.buttons["Latest messages"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        latest.tap()
        XCTAssertTrue(tail.waitForExistence(timeout: 5))
        XCTAssertTrue(tail.isHittable)
        XCTAssertEqual(composer.value as? String ?? "", draft)
    }

    @MainActor private func assertTranscriptDoesNotShowThroughControls(in app: XCUIApplication, composer: XCUIElement) {
        let profile = app.buttons["bot-profile-button"]
        XCTAssertTrue(profile.exists)
        guard let image = app.screenshot().image.cgImage else {
            return XCTFail("The chat controls must have a rendered screenshot.")
        }
        let scale = CGFloat(image.height) / app.frame.height
        let statusBottom = max(0, app.navigationBars.firstMatch.frame.minY - app.frame.minY) * scale
        let composerTop = max(0, composer.frame.minY - app.frame.minY) * scale
        let regions = [
            ("status bar", CGRect(x: 0, y: 0, width: CGFloat(image.width), height: statusBottom)),
            ("composer", CGRect(x: 0, y: composerTop, width: CGFloat(image.width),
                                height: CGFloat(image.height) - composerTop))
        ]
        let transcriptPhrases = ["practical", "discussion", "project", "history entry", "ordinary update", "to review"]
        for (name, region) in regions {
            guard let crop = image.cropping(to: region) else {
                XCTFail("The \(name) must occupy a visible region.")
                continue
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: crop).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ").lowercased()
                XCTAssertFalse(transcriptPhrases.contains(where: text.contains),
                               "Transcript text must not show through the \(name); rendered text: \(text)")
            } catch {
                XCTFail("Cannot inspect the rendered \(name): \(error)")
            }
        }
    }

    @MainActor func testSearchPresentsReadableMessagesAndArtifactPreviews() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let recent = app.buttons["library-chat-Weekend plan"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        XCTAssertTrue(recent.label.contains("Milo"))
        let recentImage = XCTAttachment(screenshot: app.screenshot())
        recentImage.name = "Search recent chats with bot avatars"; recentImage.lifetime = .keepAlways; add(recentImage)
        search.tap(); search.typeText("chart.png")
        let image = app.buttons["library-search-artifact-chart.png"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertTrue(image.label.contains("Canvas"))
        let imageResult = XCTAttachment(screenshot: app.screenshot())
        imageResult.name = "Search artifact image result"; imageResult.lifetime = .keepAlways; add(imageResult)
        image.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifact-preview"].waitForExistence(timeout: 10))
        app.buttons["artifact-done"].tap()
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "chart.png".count) + "small project update")
        let message = app.buttons["library-message-canvas-request"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains("You"))
        XCTAssertTrue(message.label.contains("small project update"))
        let match = XCTAttachment(screenshot: app.screenshot())
        match.name = "Search matching message in chat styling"; match.lifetime = .keepAlways; add(match)
        message.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(app.buttons["chat-picker-button"].label.contains("Canvas"))
    }

    @MainActor func testLibraryReaderOpensAnEditableOriginatingChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Artifacts"].tap()
        let file = app.buttons["library-artifact-chart.png"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        let openChat = app.buttons["library-open-chat"]
        XCTAssertTrue(openChat.waitForExistence(timeout: 10))
        openChat.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        let editable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { composer.exists && composer.isEnabled && composer.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [editable], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["chat-picker-button"].label.contains("Canvas"))
        XCTAssertFalse(app.tabBars.buttons["Artifacts"].isHittable)
        composer.tap()
        composer.typeText("Draft from my artifact")
        XCTAssertEqual(composer.value as? String, "Draft from my artifact")
    }

    @MainActor func testSearchBotResultOpensAnUnselectedBot() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Canvas")
        let result = app.buttons["library-bot-canvas"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isEnabled)
        XCTAssertTrue(app.buttons["chat-picker-button"].label.contains("Canvas"))
    }

    @MainActor func testLibraryTabsKeepDraftAndOpenTheMatchingChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.scrollViews["bot-inbox"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Bots"].exists)
        XCTAssertTrue(app.tabBars.buttons["Artifacts"].exists)
        XCTAssertTrue(app.tabBars.buttons["Search"].exists)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        app.buttons["bot-row-milo"].tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Artifacts"].isHittable)
        composer.tap()
        composer.typeText("Keep this while I browse outputs")
        WorkspaceNavigation.browseBots(in: app)
        app.tabBars.buttons["Artifacts"].tap()
        XCTAssertTrue(app.scrollViews["artifact-library"].waitForExistence(timeout: 10))
        let file = app.buttons["library-artifact-chart.png"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifact-preview"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["artifact-actions"].waitForExistence(timeout: 10))
        app.buttons["artifact-done"].tap()
        app.tabBars.buttons["Bots"].tap()
        app.buttons["bot-row-milo"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Keep this while I browse outputs")
        WorkspaceNavigation.browseBots(in: app)
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Weekend plan")
        let result = app.buttons["library-chat-Weekend plan"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(WorkspaceNavigation.displaysChat("Weekend plan", in: app))
    }

    @MainActor func testLibraryReferencesAndInlineOutputSharing() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Artifacts"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Artifacts"].tap()
        let list = app.scrollViews["artifact-library"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let visual = app.buttons["library-artifact-HTML preview"]
        XCTAssertTrue(visual.waitForExistence(timeout: 10))
        visual.tap()
        XCTAssertTrue(app.buttons["Show HTML source"].waitForExistence(timeout: 10))
        ArtifactOutputActions.open(in: app)
        ArtifactOutputActions.action("artifact-share", label: "Share", in: app).tap()
        ArtifactOutputActions.dismissShare(in: app)
        XCTAssertTrue(app.buttons["artifact-done"].isHittable)
        app.buttons["artifact-done"].tap()
        let filters = app.descendants(matching: .any)["library-filters"].firstMatch
        XCTAssertTrue(filters.isHittable)
        filters.tap()
        ArtifactOutputActions.action("Include references", label: "Include references", in: app).tap()
        let reference = app.buttons["library-artifact-notes.txt"]
        for _ in 0..<5 where !reference.isHittable { list.swipeUp() }
        XCTAssertTrue(reference.isHittable)
        XCTAssertTrue(reference.label.contains("Reference"))
    }

    @MainActor func testHiddenInboxKeepsScroll() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--performance-demo", "--reduce-motion"]
        app.launch()
        let list = app.scrollViews["bot-inbox"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Your bots"].exists)
        XCTAssertFalse(app.textFields["Search bots"].exists)
        XCTAssertFalse(app.buttons["All bots"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Needs you ·")).firstMatch.exists)
        for _ in 0..<3 { list.swipeUp() }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bot-row-performance-bot-"))
        let visibleRows = rows.allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.minY > 150 && $0.frame.maxY < list.frame.maxY - 60
        }
        let landmark = try XCTUnwrap(visibleRows.first)
        let row = try XCTUnwrap(visibleRows.last)
        XCTAssertNotEqual(landmark.identifier, row.identifier)
        // Opening marks a row read and can move it; track a row above it.
        let identifier = landmark.identifier, originalY = landmark.frame.minY
        row.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        WorkspaceNavigation.browseBots(in: app, expectedBotRow: identifier)
        let restored = app.buttons[identifier]
        XCTAssertTrue(restored.isHittable)
        XCTAssertLessThan(abs(restored.frame.minY - originalY), 5)
        XCTAssertFalse(app.buttons["workspace-return-to-conversation"].exists)
        XCTAssertFalse(restored.isSelected)
    }

    @MainActor func testRevealedInboxShowsReplyAndReopeningKeepsDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        app.launchArguments = ["--demo", "--reduce-motion"]
        app.launch()
        let pinnedScout = app.buttons["pinned-bot-scout"]
        XCTAssertTrue(pinnedScout.waitForExistence(timeout: 10))
        pinnedScout.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["bot-profile-button"].label, "Profile for Scout")
        composer.tap(); composer.typeText("Inventory refresh proof")
        app.buttons["Send message"].tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label ENDSWITH %@",
            "This demo stays on your phone and doesn’t perform any work.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        composer.tap(); composer.typeText("Keep this local draft")
        WorkspaceNavigation.browseBots(in: app)
        WorkspaceNavigation.revealBot("bot-row-scout", in: app)
        let row = app.buttons["bot-row-scout"]
        XCTAssertTrue(row.isHittable)
        XCTAssertTrue(row.label.contains("You’ve got the idea."))
        XCTAssertFalse(row.isSelected)
        row.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["bot-profile-button"].label, "Profile for Scout")
        XCTAssertEqual(composer.value as? String, "Keep this local draft")
    }
}
