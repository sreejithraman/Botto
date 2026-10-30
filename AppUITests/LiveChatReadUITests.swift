import XCTest
import BottoCore

/// Opt-in check against an owned disposable sidecar and saved app connection.
/// Install the signed app first; XCTest's remapped target has a different sandbox.
/// It sends one unique external message. It never runs against a remote account.
final class LiveChatReadUITests: XCTestCase {
    @MainActor func testCurrentReadPreservesHistoryPositionAndDraft() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BOTTO_UI_LIVE_READ"] == "1" else { throw XCTSkip("Requires the owned local sidecar fixture") }
        let profile = try XCTUnwrap(env["BOTTO_UI_LIVE_PROFILE"])
        let root = try XCTUnwrap(env["BOTTO_UI_LIVE_ROOT"])
        let botName = try XCTUnwrap(env["BOTTO_UI_LIVE_BOT_NAME"])
        let anchorText = try XCTUnwrap(env["BOTTO_UI_LIVE_ANCHOR"])
        guard profile.hasPrefix("botto-multiple-") else { throw XCTSkip("Not an owned fixture profile") }
        continueAfterFailure = false

        let app = XCUIApplication(bundleIdentifier: "com.sree.botto")
        app.launchArguments = []
        app.launch()
        addTeardownBlock { app.terminate() }
        let bot = app.buttons["bot-row-" + profile]
        XCTAssertTrue(bot.waitForExistence(timeout: 10))
        bot.tap()
        let service = HermesBotService()
        defer { service.disconnect() }
        var latest: OpenedConversation?
        service.onEvent = { if case .conversation(let opened) = $0 { latest = opened } }
        _ = try await service.connect(configuration: .init(serverURL: URL(string: "http://127.0.0.1:19131")!,
            username: "botto-test", password: "botto-test"))
        let directory = try await service.conversations(profile: ExactID(profile))
        let rootID = try ExactID(root)
        let summary = try XCTUnwrap(directory.summaries.first { $0.identity.root == rootID })
        let picker = app.buttons["chat-picker-button"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        picker.tap()
        let card = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", summary.title + ",")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["Add attachment"].isEnabled
        }, object: nil)], timeout: 10)

        // Attach the second client before establishing the reader's position.
        let external = try await service.openChat(.stored(summary.identity))
        composer.tap()
        if ["", "Message " + botName].contains(composer.value as? String ?? "") {
            composer.typeText("  Native reader draft  ")
        }
        composer.tap()
        let draft = try XCTUnwrap(composer.value as? String)
        XCTAssertFalse(draft.isEmpty)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let transcript = app.descendants(matching: .any).matching(identifier: "chat-transcript").firstMatch
        let anchor = app.staticTexts[anchorText]
        for _ in 0..<8 {
            if anchor.isHittable { break }
            transcript.swipeDown()
        }
        XCTAssertTrue(anchor.isHittable)
        let readingY = anchor.frame.minY
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "live-reader-before"
        before.lifetime = .keepAlways
        add(before)

        let marker = "BOTTO_CHAT_B_WORKS_NATIVE_READER_" + UUID().uuidString.lowercased()
        let source = XCTAttachment(string: "marker=" + marker + "\nroot=" + root)
        source.name = "live-reader-source"
        source.lifetime = .keepAlways
        add(source)
        let receipt = try await service.send(text: marker, attachments: [], access: external.access, operationID: UUID())
        XCTAssertEqual(receipt.source.root, summary.identity.root)
        let deadline = Date().addingTimeInterval(20)
        while latest?.snapshot.messages.contains(where: { $0.role == .assistant && $0.text.contains(marker) }) != true {
            if Date() >= deadline { XCTFail("External reply did not complete"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.descendants(matching: .any)["chat-typing-indicator"].exists && app.buttons["Add attachment"].isEnabled
        }, object: nil)], timeout: 10)
        // Observe stability after the completion and following owner/directory turns.
        try await Task.sleep(for: .seconds(2))
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "live-reader-after"
        after.lifetime = .keepAlways
        add(after)
        XCTAssertTrue(anchor.isHittable, "A completed read must retain the older message being read")
        XCTAssertEqual(anchor.frame.minY, readingY, accuracy: 2)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(app.keyboards.firstMatch.isHittable)
        let latestButton = app.buttons["Latest messages"]
        XCTAssertTrue(latestButton.isHittable)
        latestButton.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.waitForExistence(timeout: 5))

        let readback = try await service.openChat(.stored(summary.identity))
        XCTAssertEqual(readback.snapshot.messages.filter { $0.role == .user && $0.text == marker }.count, 1)
        let proof = XCTAttachment(string: "marker=" + marker + "\nroot=" + root + "\ndraft=" + draft)
        proof.name = "live-reader-source"
        proof.lifetime = .keepAlways
        add(proof)
        XCUIDevice.shared.press(.home)
    }
}
