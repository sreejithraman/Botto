import XCTest
import UIKit
import Vision

/// Public workspace journeys shared by phone and wider available space.
/// Window resizing across compact and wide layouts needs separate acceptance checks.
final class DuoWorkspaceUITests: XCTestCase {
    @MainActor func testProfileTapRegionFollowsChatPaneDuringFilePairing() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Requires paired iPad layout") }
        let app = launch(bot: "Canvas")
        openNotes(app)
        let profile = app.buttons["bot-profile-button"]
        let chats = app.buttons["chat-picker-button"]
        let close = app.buttons["bot-profile-done"]
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(profile.waitForExistence(timeout: 5))
            let bar = app.navigationBars["Canvas"]
            XCTAssertGreaterThan(abs(profile.frame.midX - bar.frame.midX), profile.frame.width,
                                 "The file and chat must occupy separate paired panes.")
            capture("Paired header tap region \(orientation.rawValue)", app: app)
            let strayPoint = CGVector(dx: bar.frame.midX, dy: chats.frame.midY + 8)
            app.coordinate(withNormalizedOffset: .zero).withOffset(strayPoint).tap()
            XCTAssertFalse(close.exists, "Empty navigation-bar space must not open a distant profile.")
            let avatarPoint = CGVector(dx: profile.frame.midX, dy: chats.frame.midY + 8)
            app.coordinate(withNormalizedOffset: .zero).withOffset(avatarPoint).tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            profile.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.4)).tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
        }
        tap("artifact-done", app: app)
        let avatarPoint = CGVector(dx: profile.frame.midX, dy: chats.frame.midY + 8)
        app.coordinate(withNormalizedOffset: .zero).withOffset(avatarPoint).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
    }

    @MainActor func testProfileAndChatTabsAreSeparateAndPreserveTheCurrentDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.buttons["pinned-bot-milo"].tap()
        let draft = "Keep this while browsing Milo’s chats and profile."
        enterDraft(draft, app: app)
        capture("Compact bot and current-chat header", app: app)
        tap("bot-profile-button", app: app)
        XCTAssertFalse(app.buttons["new-chat"].exists)
        XCTAssertFalse(app.textFields["chat-picker-search"].exists)
        let change = app.buttons["bot-profile-edit"]
        let scroll = app.scrollViews["bot-details-scroll"]
        for _ in 0..<8 where !change.isHittable { scroll.swipeUp() }
        assertUsable(change)
        capture("Bot overview with direct profile edit", app: app)
        XCTAssertFalse(app.buttons["Pinned close at hand"].exists)
        change.tap()
        XCTAssertTrue(app.buttons["save-bot-profile"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-bot-profile"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["bot-profile-done"].waitForExistence(timeout: 5))
        app.buttons["bot-profile-done"].tap()
        assertConversation(bot: "Milo", title: "Main", draft: draft, app: app)
        tap("chat-picker-button", app: app)
        assertUsable(app.buttons["new-chat"])
        XCTAssertFalse(app.buttons["bot-profile-edit"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat-card-", "Current chat")).firstMatch.exists)
        capture("Separate chat tabs", app: app)
        app.buttons["chat-picker-button"].tap()
        selectChat("Weekend plan", bot: "Milo", app: app)
        assertConversation(bot: "Milo", title: "Weekend plan", app: app)
        selectChat("Main", bot: "Milo", app: app)
        assertConversation(bot: "Milo", title: "Main", draft: draft, app: app)
    }

    @MainActor func testCanvasSendKeepsTheNewReplyVisibleAfterRichPreviewAndBotRoundTrip() {
        assertCanvasSendKeepsTheNewReplyVisible()
    }

    @MainActor private func assertCanvasSendKeepsTheNewReplyVisible() {
        let app = launch(bot: "Canvas")
        wait("The existing HTML file preview has rendered before sending", timeout: 20) {
            app.buttons.matching(NSPredicate(format: "label == %@", "Update preview"))
                .allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
        }
        let draft = "Canvas tail after rich preview\n  keep this source draft  "
        enterDraft(draft, app: app)
        tapBots(app)
        chooseBot("Milo", app: app)
        tapBots(app)
        chooseBot("Canvas", app: app)
        assertConversation(bot: "Canvas", title: "Main", draft: draft, app: app)
        capture("Rich transcript before sending the retained draft", app: app)

        tap("Send message", app: app)
        wait("Send clears the composer") {
            let input = self.editor(app)
            let value = input.value as? String
            return input.exists && input.label == "Message to Canvas" && (value == nil || value == "")
        }
        // Sending and rich-file remeasurement must leave the actual tail in
        // view. Do not repair the position by scrolling or reopening the chat.
        let reply = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label ENDSWITH %@",
            "You’ve got the idea.", "This demo stays on your phone and doesn’t perform any work.")).firstMatch
        wait("The new demo reply is visible without recovery navigation", timeout: 20) {
            reply.exists && reply.isHittable && RenderedTranscriptText.line(
                "any work.", in: reply, viewport: self.transcript(app).frame, app: app) != nil
        }
        capture("Latest Canvas reply remains visible after Send", app: app)
    }

    @MainActor func testPDFZoomAndScrolledViewportSurviveFullScreenReturnAndClose() {
        let app = launch(bot: "Canvas")
        let draft = "Keep this exact PDF review draft\nwhile I inspect the page."
        enterDraft(draft, app: app)
        openPDF(app)
        assertExpansionAction("Full screen", app: app)
        capturePDF("PDF contextual fit", app: app)
        let fit = pdfText(app).frame.size
        XCTAssertGreaterThan(fit.width, 0)
        XCTAssertGreaterThan(fit.height, 0)

        artifactReader(app).pinch(withScale: 2, velocity: 1)
        wait("The actual PDF page grows after pinch", timeout: 15) {
            let page = self.pdfText(app)
            return page.exists && page.frame.width > fit.width * 1.25
                && page.frame.height > fit.height * 1.25
        }
        capturePDF("PDF after contextual zoom", app: app)
        let inkBeforePan = pdfInk(app)

        // Pan the real zoomed page toward its top-left content. This also
        // reveals the two printed lines if the pinch anchor clipped them.
        let reader = artifactReader(app)
        let start = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
        let end = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65))
        start.press(forDuration: 0.05, thenDragTo: end)
        wait("Scrolling leaves both PDF lines visibly readable", timeout: 15) {
            self.pdfInk(app) != nil
        }
        capturePDF("PDF zoomed and scrolled contextual viewport", app: app)
        guard let contextualInk = pdfInk(app) else {
            XCTFail("The zoomed viewport must visibly contain both printed PDF lines.")
            return
        }
        if let inkBeforePan {
            XCTAssertGreaterThan(hypot(contextualInk.title.midX - inkBeforePan.title.midX,
                                       contextualInk.title.midY - inkBeforePan.title.midY), 12,
                                 "The public pan must actually move the printed PDF content.")
        }
        // If the pre-pan lines were clipped, their newly readable pixels above
        // are the observable scroll result. Do not infer it from a gesture alone.
        let contextualSize = pdfText(app).frame.size
        XCTAssertGreaterThan(contextualSize.width, fit.width * 1.25)
        XCTAssertGreaterThan(contextualSize.height, fit.height * 1.25)

        tap("artifact-toggle-expanded", app: app)
        assertExpansionAction("Exit full screen", app: app)
        XCTAssertTrue(pdfText(app).waitForExistence(timeout: 15),
                      "Full screen must still contain the actual Canvas PDF.")
        wait("Full screen visibly renders both printed PDF lines", timeout: 15) {
            self.pdfInk(app) != nil
        }
        capturePDF("PDF explicit full screen", app: app)

        tap("artifact-toggle-expanded", app: app)
        assertExpansionAction("Full screen", app: app)
        wait("Return preserves PDF zoom and its useful scrolled viewport", timeout: 15) {
            let page = self.pdfText(app)
            guard page.exists, let returnedInk = self.pdfInk(app) else { return false }
            let size = page.frame.size
            return abs(size.width - contextualSize.width) <= contextualSize.width * 0.10
                && abs(size.height - contextualSize.height) <= contextualSize.height * 0.10
                && self.samePDFViewport(contextualInk, returnedInk)
        }
        capturePDF("PDF returned with the same zoom and viewport", app: app)
        XCTAssertGreaterThan(pdfText(app).frame.width, fit.width * 1.25,
                             "Returning must not silently reset the page to fit.")
        assertOutputActions(app)

        tap("artifact-done", app: app)
        assertNoArtifact(app)
        assertConversation(bot: "Canvas", title: "Main", draft: draft, app: app)
        assertUsable(editor(app))
        capture("Conversation and exact draft after PDF close", app: app)
    }

    @MainActor func testDraftSurvivesFileFullScreenReturnAndClose() {
        let app = launch(bot: "Canvas")
        let draft = "Review this draft\nbefore publishing."
        enterDraft(draft, app: app)
        openNotes(app)
        capture("Contextual notes", app: app)

        assertExpansionAction("Full screen", app: app)
        tap("artifact-toggle-expanded", app: app)
        assertExpansionAction("Exit full screen", app: app)
        assertNotes(app)
        capture("Full screen notes", app: app)

        tap("artifact-toggle-expanded", app: app)
        assertExpansionAction("Full screen", app: app)
        assertNotes(app)
        tap("artifact-done", app: app)
        assertNoArtifact(app)
        assertConversation(bot: "Canvas", title: "Main", draft: draft, app: app)
        assertUsable(editor(app))
    }

    @MainActor func testBotsBrowseAndReopenPreservesDraftAndClosesFile() {
        let app = launch(bot: "Canvas")
        let draft = "Keep my file and this unsent draft"
        enterDraft(draft, app: app)
        openNotes(app)

        tapBots(app)
        WorkspaceNavigation.revealBot("bot-row-milo", in: app)
        assertUsable(botRow("Milo", app: app))
        XCTAssertFalse(app.buttons["Return to chat"].exists)
        chooseBot("Canvas", app: app)
        assertNoArtifact(app)
        capture("Chat reopened without the old file after browsing bots", app: app)
        assertConversation(bot: "Canvas", title: "Main", draft: draft, app: app)
    }

    @MainActor func testRealSelectionRetiresParkedFileAcrossReopening() {
        let app = launch(bot: "Canvas")
        let draft = "Canvas draft belongs to Canvas"
        enterDraft(draft, app: app)
        openNotes(app)
        tapBots(app)
        chooseBot("Milo", app: app)
        assertNoArtifact(app)

        selectChat("Weekend plan", bot: "Milo", app: app)
        XCTAssertTrue(app.staticTexts["Keep Saturday open for a long walk and a late lunch."].exists)
        tapBots(app)
        chooseBot("Milo", app: app, title: "Weekend plan")
        assertConversation(bot: "Milo", title: "Weekend plan", app: app)
        assertNoArtifact(app)

        tapBots(app)
        chooseBot("Canvas", app: app)
        assertConversation(bot: "Canvas", title: "Main", draft: draft, app: app)
        assertNoArtifact(app)
        tapBots(app)
        chooseBot("Canvas", app: app)
        assertConversation(bot: "Canvas", title: "Main", draft: draft, app: app)
        assertNoArtifact(app)

        // A deliberate fresh open remains usable after retirement.
        openNotes(app)
        tap("artifact-done", app: app)
        assertConversation(bot: "Canvas", title: "Main", draft: draft, app: app)
    }

    @MainActor func testPublicRotationsKeepActiveSiblingDraftAndContext() {
        let app = launch(bot: "Milo")
        let mainDraft = "Main keeps its own draft"
        enterDraft(mainDraft, app: app)
        selectChat("Weekend plan", bot: "Milo", app: app)
        var weekendDraft = "Weekend keeps\nits own draft"
        enterDraft(weekendDraft, app: app)
        defer { XCUIDevice.shared.orientation = .portrait }

        // These public rotations do not guarantee a compact/wide boundary
        // crossing. Verify window resizing separately on supported targets.
        let orientations: [UIDeviceOrientation] = [.landscapeLeft, .portrait, .landscapeRight, .portrait]
        for (index, orientation) in orientations.enumerated() {
            XCUIDevice.shared.orientation = orientation
            assertConversation(bot: "Milo", title: "Weekend plan", draft: weekendDraft, app: app)
            assertUsable(editor(app))
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            XCTAssertTrue(app.staticTexts["Keep Saturday open for a long walk and a late lunch."].exists)
            // No refocus tap: the active editor must remain usable after reflow.
            let addition = " \(index + 1)"
            editor(app).typeText(addition)
            weekendDraft += addition
            assertConversation(bot: "Milo", title: "Weekend plan", draft: weekendDraft, app: app)
            capture("Rotation \(index + 1), window \(app.frame.width) by \(app.frame.height)", app: app)
        }

        // Header buttons are the only route used to select a sibling.
        selectChat("Main", bot: "Milo", app: app)
        assertConversation(bot: "Milo", title: "Main", draft: mainDraft, app: app)
        XCTAssertTrue(app.buttons["Keep draft"].exists)
        selectChat("Weekend plan", bot: "Milo", app: app)
        assertConversation(bot: "Milo", title: "Weekend plan", draft: weekendDraft, app: app)
    }

    @MainActor private func launch(bot: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        chooseBot(bot, app: app)
        assertConversation(bot: bot, title: "Main", app: app)
        assertUsable(app.buttons["Add attachment"])
        return app
    }

    @MainActor private func chooseBot(_ name: String, app: XCUIApplication, title: String = "Main") {
        WorkspaceNavigation.revealBot("bot-row-" + name.lowercased(), in: app)
        let row = botRow(name, app: app)
        assertUsable(row)
        row.tap()
        assertConversation(bot: name, title: title, app: app)
    }

    @MainActor private func botRow(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons["bot-row-" + name.lowercased()]
    }

    @MainActor private func editor(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat-composer"].firstMatch
    }

    @MainActor private func enterDraft(_ text: String, app: XCUIApplication) {
        let input = editor(app)
        assertUsable(input)
        input.tap()
        input.typeText(text)
        XCTAssertEqual(input.value as? String, text)
    }

    @MainActor private func assertConversation(bot: String, title: String, draft: String? = nil,
                                               app: XCUIApplication) {
        wait("Expected \(bot) / \(title) with its own draft") {
            let header = app.buttons["chat-picker-button"]
            let input = self.editor(app)
            return app.navigationBars[bot].exists
                && header.label == "Chats with \(bot)"
                && WorkspaceNavigation.displaysChat(title, in: app)
                && input.exists && input.label == "Message to \(bot)"
                && (draft == nil || input.value as? String == draft)
                && self.transcript(app).exists
        }
    }

    @MainActor private func selectChat(_ title: String, bot: String, app: XCUIApplication) {
        openChatPicker(app)
        let search = app.textFields["chat-picker-search"]
        assertUsable(search)
        search.tap()
        search.typeText(title + "\n")
        // Native context-menu rows may be PopUpButton, as in MultipleChatUITests.
        let card = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "chat-card-", title)).firstMatch
        assertUsable(card)
        card.tap()
        assertConversation(bot: bot, title: title, app: app)
    }

    @MainActor private func openNotes(_ app: XCUIApplication) {
        let card = revealFileCard("notes.txt", app: app)
        card.tap()
        assertNotes(app)
        assertOutputActions(app)
    }

    @MainActor private func openPDF(_ app: XCUIApplication) {
        let card = revealFileCard("report.pdf", app: app)
        card.tap()
        XCTAssertTrue(pdfText(app).waitForExistence(timeout: 15),
                      "Quick Look must render the real one-page Demo PDF.")
        XCTAssertFalse(app.descendants(matching: .any)["artifact-error"].exists)
        assertOutputActions(app)
    }

    @MainActor private func revealFileCard(_ name: String, app: XCUIApplication) -> XCUIElement {
        let transcript = self.transcript(app)
        let card = app.buttons["Open \(name)"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        for _ in 0..<10 {
            let viewport = transcript.frame
            guard !viewport.isNull && !viewport.isInfinite && viewport.width > 0 && viewport.height > 0 else {
                XCTFail("File discovery requires an actual nonempty transcript viewport.")
                return card
            }
            let frame = card.exists ? card.frame : .null
            let measured = !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
            // Offscreen virtual elements can have no valid activation point.
            // Require a complete visible card before asking for hit testing.
            if measured && viewport.contains(frame) { break }
            let towardNewer = measured && frame.maxY > viewport.maxY
            let distance = measured ? abs(frame.midY - viewport.midY) : viewport.height * 0.8
            let travel = min(viewport.height * 0.8, distance)
            let startY: CGFloat = towardNewer ? 0.9 : 0.1
            let endY = startY + (towardNewer ? -1 : 1) * travel / viewport.height
            let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: startY))
            let end = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: endY))
            // End a deliberate slow drag inside this small keyboard-sized
            // viewport instead of flinging past the card in both directions.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        wait("The actual \(name) card is visible, reachable and enabled") {
            guard card.exists else { return false }
            let frame = card.frame
            return !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0 &&
                transcript.frame.contains(frame) && card.isEnabled && card.isHittable
        }
        return card
    }

    @MainActor private func transcript(_ app: XCUIApplication) -> XCUIElement {
        // Both native collection and SwiftUI scroll hosts expose the same
        // public transcript. Preserve the workflow across its native AX roles.
        app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
    }

    @MainActor private func pdfText(_ app: XCUIApplication) -> XCUIElement {
        // Same real-page observation used by ArtifactExportUITests. PDF AX
        // origins may be local to the pane; only intrinsic size is compared.
        let texts = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Canvas demo"))
        return texts.allElementsBoundByIndex.first { $0.isHittable } ?? texts.firstMatch
    }

    @MainActor private func artifactReader(_ app: XCUIApplication) -> XCUIElement {
        let readers = app.descendants(matching: .any).matching(identifier: "artifact-preview")
        let reader = readers.allElementsBoundByIndex.first { $0.isHittable } ?? readers.firstMatch
        assertUsable(reader)
        return reader
    }

    private struct PDFInk {
        let title: CGRect
        let subtitle: CGRect
    }

    @MainActor private func pdfInk(_ app: XCUIApplication) -> PDFInk? {
        // Recognize actual screenshot pixels, independent of Quick Look's local
        // AX coordinates. Both known lines must be fully present and readable.
        guard let image = app.screenshot().image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        func bounds(of expected: String) -> CGRect? {
            let letters = expected.lowercased().filter(\.isLetter)
            guard let observation = request.results?.first(where: {
                $0.topCandidates(1).first?.string.lowercased().filter(\.isLetter) == letters
            }) else { return nil }
            // Vision uses normalized bottom-left coordinates. Screen-relative
            // points let before/return comparisons survive screenshot scaling.
            let box = observation.boundingBox
            let frame = app.frame
            return CGRect(x: frame.minX + box.minX * frame.width,
                          y: frame.minY + (1 - box.maxY) * frame.height,
                          width: box.width * frame.width, height: box.height * frame.height)
        }
        guard let title = bounds(of: "Canvas demo"),
              let subtitle = bounds(of: "Draft, review, then publish.") else { return nil }
        return PDFInk(title: title, subtitle: subtitle)
    }

    private func samePDFViewport(_ before: PDFInk, _ after: PDFInk) -> Bool {
        let originalBounds: [CGRect] = [before.title, before.subtitle]
        let returnedBounds: [CGRect] = [after.title, after.subtitle]
        for (original, returned) in zip(originalBounds, returnedBounds) {
            // Allow rasterization/rounding, but reject a fit reset or a pan back
            // to a different part of this one-page document.
            let widthTolerance: CGFloat = max(3, original.width * 0.10)
            let heightTolerance: CGFloat = max(2, original.height * 0.10)
            let positionTolerance: CGFloat = max(12, original.height * 0.75)
            let sameWidth: Bool = abs(returned.width - original.width) <= widthTolerance
            let sameHeight: Bool = abs(returned.height - original.height) <= heightTolerance
            let sameX: Bool = abs(returned.midX - original.midX) <= positionTolerance
            let sameY: Bool = abs(returned.midY - original.midY) <= positionTolerance
            if !sameWidth || !sameHeight || !sameX || !sameY { return false }
        }
        return true
    }

    @MainActor private func capturePDF(_ name: String, app: XCUIApplication) {
        capture(name, app: app)
        let page = pdfText(app)
        let ink = pdfInk(app)
        let evidence = XCTAttachment(string: """
        PDF AX bounds (origin may be local): \(page.exists ? page.frame.debugDescription : "missing")
        Rendered Canvas demo bounds: \(ink?.title.debugDescription ?? "not fully readable")
        Rendered subtitle bounds: \(ink?.subtitle.debugDescription ?? "not fully readable")
        \(app.debugDescription)
        """)
        evidence.name = name + " page bounds and hierarchy"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor private func assertNotes(_ app: XCUIApplication) {
        let contents = "Canvas demo\n\nDraft, review, then publish. All sample files stay on this device."
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", contents, contents)
        wait("The reader renders the actual notes text", timeout: 15) {
            // Native readers expose content as a text view or static text.
            // Match actual content, not a filename or title.
            let readers = app.textViews.matching(predicate).allElementsBoundByIndex
                + app.staticTexts.matching(predicate).allElementsBoundByIndex
            return readers.contains { $0.exists && $0.isHittable }
        }
        XCTAssertFalse(app.descendants(matching: .any)["artifact-error"].exists)
        XCTAssertFalse(app.buttons["artifact-retry"].exists)
    }

    @MainActor private func assertNoArtifact(_ app: XCUIApplication) {
        wait("Retired file and its export actions stay absent") {
            !app.descendants(matching: .any)["artifact-preview"].exists
                && !app.buttons["artifact-save"].exists && !app.buttons["artifact-share"].exists
                && !app.buttons["artifact-done"].exists
        }
    }

    @MainActor private func assertExpansionAction(_ label: String, app: XCUIApplication) {
        wait("File offers \(label)") {
            let toggle = self.activeButton("artifact-toggle-expanded", app: app)
            return toggle.exists && toggle.isHittable && toggle.label == label
        }
    }

    @MainActor private func tapBots(_ app: XCUIApplication) {
        let explicit = activeButton("workspace-browse-bots", app: app)
        if explicit.exists && explicit.isHittable {
            assertUsable(explicit); explicit.tap(); return
        }
        // Compact chat-only navigation uses the real native Back control.
        // File paths retain the explicit Bots action; do not substitute Close.
        XCTAssertFalse(app.buttons["artifact-done"].exists)
        let back = app.buttons["BackButton"].exists ? app.buttons["BackButton"] : app.buttons["Back"]
        assertUsable(back)
        back.tap()
    }

    @MainActor private func activeButton(_ identifier: String, app: XCUIApplication) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: identifier)
        return buttons.allElementsBoundByIndex.first { $0.isHittable } ?? buttons.firstMatch
    }

    @MainActor private func assertOutputActions(_ app: XCUIApplication) {
        let menu = activeButton("artifact-actions", app: app)
        assertUsable(menu)
        guard let dismiss = ArtifactOutputActions.dismissalCoordinate(for: artifactReader(app), in: app) else { return }
        menu.tap()
        // Native menu rows can expose their visible label instead of the
        // SwiftUI identifier. Require the actual enabled, reachable action.
        for (identifier, label) in [("artifact-save", "Save to Files"), ("artifact-share", "Share")] {
            let predicate = NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)
            let row = app.cells.matching(predicate).firstMatch
            let action = row.exists ? row : app.buttons.matching(predicate).firstMatch
            assertUsable(action)
        }
        // Dismiss the menu with an ordinary tap inside the displayed document.
        // This does not invoke an output or change the presentation extent.
        // The menu legitimately covers the reader. Use its previously verified
        // content coordinate rather than require the covered reader to be hittable.
        dismiss.tap()
        wait("File actions menu dismisses back to the usable reader") {
            menu.exists && menu.isHittable
                && !(app.buttons["artifact-save"].exists && app.buttons["artifact-save"].isHittable)
                && !(app.buttons["artifact-share"].exists && app.buttons["artifact-share"].isHittable)
                && !(app.cells["Save to Files"].exists && app.cells["Save to Files"].isHittable)
                && !(app.cells["Share"].exists && app.cells["Share"].isHittable)
        }
    }

    @MainActor private func openChatPicker(_ app: XCUIApplication) {
        tap("chat-picker-button", app: app)
    }

    @MainActor private func tap(_ identifier: String, app: XCUIApplication) {
        wait("\(identifier) is reachable and enabled") {
            let button = self.activeButton(identifier, app: app)
            return button.exists && button.isHittable && button.isEnabled
        }
        activeButton(identifier, app: app).tap()
    }

    @MainActor private func assertUsable(_ element: XCUIElement) {
        wait("Control is reachable and enabled") {
            element.exists && element.isHittable && element.isEnabled
        }
    }

    @MainActor private func wait(_ message: String, timeout: TimeInterval = 10,
                                 until condition: @escaping @MainActor () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { condition() }
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            let app = XCUIApplication()
            capture(message, app: app)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = message + " accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(result, .completed, message)
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
