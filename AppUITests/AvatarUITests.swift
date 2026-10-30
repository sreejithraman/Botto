import XCTest
import BottoCore

final class AvatarUITests: XCTestCase {
    @MainActor func testAvatarAndNameReopenProfileFromChat() {
        checkAvatarAndNameProfileTaps(inGrid: false)
    }

    @MainActor func testAvatarAndNameReopenProfileFromChatGrid() {
        checkAvatarAndNameProfileTaps(inGrid: true)
    }

    @MainActor func testShortAvatarAndNameReopenProfileFromGrid() {
        checkAvatarAndNameProfileTaps(inGrid: true, shortAvatar: true)
    }

    @MainActor func testAvatarAndNameReopenProfileFromEmptyChat() {
        checkAvatarAndNameProfileTaps(inGrid: false, emptyChat: true)
    }

    @MainActor private func checkAvatarAndNameProfileTaps(inGrid: Bool, shortAvatar: Bool = false, emptyChat: Bool = false) {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        app.buttons["pinned-bot-milo"].tap()
        let profile = app.buttons["bot-profile-button"]
        let chats = app.buttons["chat-picker-button"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Profile for Milo")).count, 1)
        if shortAvatar {
            profile.tap()
            let edit = app.buttons["bot-profile-edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
            let name = app.textFields["bot-profile-name"]
            name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "Hedwig")
            chooseCustomAvatar(in: app)
            let pill = app.buttons["avatar-shape-pill"]
            reach(pill, in: app); pill.tap()
            app.buttons["save-bot-profile"].tap()
            let close = app.buttons["bot-profile-done"]
            XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
            XCTAssertTrue(profile.waitForExistence(timeout: 5))
        }
        if emptyChat {
            chats.tap()
            let create = app.buttons["new-chat"]
            XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Hello, Milo.")).firstMatch.waitForExistence(timeout: 5))
        }
        if inGrid {
            chats.tap()
            XCTAssertTrue(app.buttons["new-chat"].waitForExistence(timeout: 5))
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = shortAvatar ? "Short avatar profile tap target" : "Avatar profile tap target"
        screenshot.lifetime = .keepAlways; add(screenshot)
        for tap in 0..<3 {
            if shortAvatar && tap > 0 {
                profile.coordinate(withNormalizedOffset: CGVector(dx: tap == 1 ? 0.08 : 0.92, dy: 0.4)).tap()
            } else if tap == 1 {
                profile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
            } else {
                let point = CGVector(dx: profile.frame.midX, dy: chats.frame.midY + 8)
                app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
            }
            let close = app.buttons["bot-profile-done"]
            XCTAssertTrue(close.waitForExistence(timeout: 5), "Every avatar/name tap must open the profile (tap \(tap)).")
            close.tap()
            XCTAssertTrue(profile.waitForExistence(timeout: 5))
            XCTAssertEqual(app.descendants(matching: .any)["chat-picker"].exists, inGrid)
        }
    }

    @MainActor func testFloatingProfilePillOverlapsTranscriptAndKeepsItsLowerTouchTarget() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        app.buttons["pinned-bot-milo"].tap()
        let profile = app.buttons["bot-profile-button"]
        let transcript = app.collectionViews["chat-transcript"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertFalse((profile.value as? String ?? "").contains("Offline"))
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertLessThan(transcript.frame.minY, app.navigationBars.firstMatch.frame.maxY - 20)
        XCTAssertGreaterThan(profile.frame.intersection(transcript.frame).height, 20,
                             "Messages scroll behind the floating name pill.")
        XCTAssertGreaterThanOrEqual(profile.frame.height.rounded(), 44)
        profile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 5))
    }

    @MainActor func testNewBotsMatchNameAndCustomChoicesSurviveModeChanges() {
        let app = launch()
        app.buttons["New bot"].tap()
        let name = app.textFields["What shall we call them?"]
        XCTAssertTrue(name.waitForExistence(timeout: 3)); name.tap(); name.typeText("Aster\n")
        let mode = app.buttons["avatar-mode"]
        XCTAssertTrue(mode.exists)
        XCTAssertTrue((mode.label + (mode.value as? String ?? "")).contains("Match the name"))
        XCTAssertFalse(app.buttons["avatar-shape-hexagon"].exists)
        let create = app.buttons["Create bot"]
        reach(create, in: app); create.tap()
        XCTAssertTrue(app.buttons["Profile for Aster"].waitForExistence(timeout: 5))
        app.buttons["Profile for Aster"].tap()
        app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(app.buttons["save-bot-profile"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["save-bot-profile"].isEnabled)
        XCTAssertFalse(app.buttons["avatar-shape-hexagon"].exists)
        chooseCustomAvatar(in: app)
        let shape = app.buttons["avatar-shape-hexagon"]
        reach(shape, in: app); shape.tap()
        let color = app.buttons["avatar-color-teal"]
        reach(color, in: app); color.tap()
        reach(mode, in: app); mode.tap(); app.buttons["Match the name"].tap()
        XCTAssertFalse(shape.exists)
        chooseCustomAvatar(in: app)
        XCTAssertTrue(avatarPreview("Hexagon · Teal", in: app, timeout: 0))
        app.buttons["Cancel"].tap()
        app.buttons["bot-profile-edit"].tap()
        XCTAssertFalse(shape.exists)
        XCTAssertFalse(app.buttons["save-bot-profile"].isEnabled)
    }

    @MainActor func testProfileSaveBlocksSheetDismissalUntilItCompletes() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hold = directory.appendingPathComponent("avatar.hold")
        try Data().write(to: hold)
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = directory.path
        app.launch()
        XCTAssertTrue(app.buttons["pinned-bot-milo"].waitForExistence(timeout: 5))
        editMilo(in: app)
        let shape = app.buttons["avatar-shape-hexagon"]
        reach(shape, in: app); shape.tap()
        let save = app.buttons["save-bot-profile"]
        save.tap()
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("avatar.started").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 5), .completed)
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.exists)
        func dismissSheet() {
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        dismissSheet()
        XCTAssertTrue(app.navigationBars["Edit bot"].exists)
        XCTAssertTrue(save.exists && !save.isEnabled)
        XCTAssertFalse(app.buttons["Cancel"].isEnabled)
        try FileManager.default.removeItem(at: hold)
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 5))
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("avatar.calls"), encoding: .utf8), "1")
        dismissSheet()
        XCTAssertTrue(app.buttons["bot-profile-button"].waitForExistence(timeout: 5),
                      "The same gesture must dismiss the sheet after saving completes")
    }

    @MainActor func testProfileNameAndDescriptionSaveTogetherWithoutLosingChatDraft() {
        let app = launch()
        app.buttons["pinned-bot-milo"].tap()
        let composer = app.textViews["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Keep this exact draft")
        app.buttons["bot-profile-button"].tap()
        app.buttons["bot-profile-edit"].tap()
        let name = app.textFields["bot-profile-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "Milo Updated")
        let description = app.textViews["bot-profile-description"]
        XCTAssertEqual(description.value as? String, "Your chief of staff. Turns loose ends into a clear next step.")
        description.tap()
        description.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        description.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 61) + "Keep the important things moving.")
        XCTAssertEqual(description.value as? String, "Keep the important things moving.")
        let save = app.buttons["save-bot-profile"]
        XCTAssertTrue(save.isEnabled); save.tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["bot-profile-edit"].exists && app.buttons["bot-profile-edit"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["Milo Updated"].exists)
        XCTAssertTrue(app.staticTexts["Keep the important things moving."].exists)
        app.buttons["bot-profile-edit"].tap()
        XCTAssertEqual(name.value as? String, "Milo Updated")
        XCTAssertEqual(description.value as? String, "Keep the important things moving.")
        XCTAssertFalse(save.isEnabled)
        app.buttons["Cancel"].tap()
        app.buttons["bot-profile-done"].tap()
        XCTAssertEqual(composer.value as? String, "Keep this exact draft")
        XCTAssertTrue(app.buttons["Profile for Milo Updated"].exists)
    }

    @MainActor func testOfflineSelectionSurvivesBackgroundAndWaitsForSave() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-offline"]
        app.launch()
        XCTAssertTrue(app.buttons["pinned-bot-milo"].waitForExistence(timeout: 5))
        app.buttons["pinned-bot-milo"].tap()
        let profile = app.buttons["bot-profile-button"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profile.value as? String, "Offline")
        WorkspaceNavigation.browseBots(in: app)
        editMilo(in: app)
        XCTAssertFalse(app.staticTexts["You’re offline"].exists)
        let name = app.textFields["bot-profile-name"]
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "Milo Offline")
        let description = app.textViews["bot-profile-description"]
        description.tap()
        description.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        description.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 61) + "Preserve this unfinished profile.")
        let shape = app.buttons["avatar-shape-hexagon"]
        reach(shape, in: app); shape.tap()
        let color = app.buttons["avatar-color-teal"]
        reach(color, in: app); color.tap()
        XCTAssertTrue(app.buttons["save-bot-profile"].isEnabled)
        app.buttons["save-bot-profile"].tap()
        XCTAssertTrue(app.staticTexts["You’re offline"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Reconnect"].isHittable)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["Edit bot"].waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Milo Offline")
        XCTAssertEqual(description.value as? String, "Preserve this unfinished profile.")
        app.buttons["Reconnect"].tap()
        XCTAssertTrue(app.staticTexts["You’re offline"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["save-bot-profile"].isEnabled)
        app.buttons["save-bot-profile"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 5))
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Hexagon · Teal", in: app, timeout: 3))
        XCTAssertEqual(name.value as? String, "Milo Offline")
        XCTAssertEqual(description.value as? String, "Preserve this unfinished profile.")
    }

    @MainActor func testLiveForeignValueEditsAndSavedImageCancel() async throws {
        continueAfterFailure = false
        guard let address = ProcessInfo.processInfo.environment["BOTTO_UI_TEST_AVATAR_URL"] else {
            throw XCTSkip("Set BOTTO_UI_TEST_AVATAR_URL to the disposable avatar fixture host; use a signed build.")
        }
        let profiles = try await avatarProfiles(at: address)
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-server", address]
        func openEditor(_ title: String) throws {
            app.launch()
            let profile = try XCTUnwrap(profiles.first { $0.name == title }, "Missing owned fixture \(title)")
            let row = app.buttons["bot-row-" + profile.id]
            XCTAssertTrue(row.waitForExistence(timeout: 20)); row.tap()
            app.buttons["Profile for \(title)"].tap()
                reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        }
        try openEditor("Avatar Foreign Color")
        let hexagon = app.buttons["avatar-shape-hexagon"]
        reach(hexagon, in: app); hexagon.tap(); app.buttons["save-bot-profile"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 10))
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Hexagon · Custom color", in: app, timeout: 5))
        app.buttons["Cancel"].tap(); app.terminate()

        try openEditor("Avatar Foreign Shape")
        XCTAssertTrue(avatarPreview("Shared shape · Custom color", in: app, timeout: 5))
        let red = app.buttons["avatar-color-red"]
        reach(red, in: app); red.tap(); app.buttons["save-bot-profile"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 10))
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Shared shape · Red", in: app, timeout: 5))
        app.buttons["Cancel"].tap(); app.terminate()

        for title in ["Avatar Pet", "Avatar Image"] {
            try openEditor(title)
            XCTAssertTrue(avatarPreview("Current avatar", in: app, timeout: 5))
            XCTAssertFalse(app.buttons["save-bot-profile"].isEnabled)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(title) saved asset preview"
            screenshot.lifetime = .keepAlways; add(screenshot)
            app.buttons["Cancel"].tap(); app.terminate()
        }
    }

    /// Uses the owned Avatar Preset fixture; verifies that automatic color persists as no override.
    @MainActor func testLiveMatchNameKeepsShapeAndDoesNotRestoreColorOnShapeEdit() async throws {
        continueAfterFailure = false
        guard let address = ProcessInfo.processInfo.environment["BOTTO_UI_TEST_AVATAR_URL"] else {
            throw XCTSkip("Set BOTTO_UI_TEST_AVATAR_URL to the disposable avatar fixture host; use a signed build.")
        }
        let profiles = try await avatarProfiles(at: address)
        let profile = try XCTUnwrap(profiles.first { $0.name == "Avatar Preset" }, "Missing owned Avatar Preset fixture")
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-server", address]
        app.launch()
        let preset = app.buttons["bot-row-" + profile.id]
        XCTAssertTrue(preset.waitForExistence(timeout: 20)); preset.tap()
        app.buttons["Profile for Avatar Preset"].tap()
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        let hexagon = app.buttons["avatar-shape-hexagon"]
        reach(hexagon, in: app); hexagon.tap()
        let automaticColor = app.buttons["avatar-color-auto"]
        reach(automaticColor, in: app); automaticColor.tap()
        app.buttons["save-bot-profile"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 10))
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Hexagon · Match the name", in: app, timeout: 5))
        let triangle = app.buttons["avatar-shape-triangle"]
        reach(triangle, in: app); triangle.tap()
        app.buttons["save-bot-profile"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 10))
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Triangle · Match the name", in: app, timeout: 5))
        let green = app.buttons["avatar-color-green"]
        reach(green, in: app); green.tap()
        app.buttons["Cancel"].tap()
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Triangle · Match the name", in: app, timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Live Hermes name color retained after later shape edit and Cancel"
        screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Cancel"].tap()
    }

    /// Requires a signed build and owned Avatar Sun/Avatar Custom fixtures on a disposable host.
    @MainActor func testLiveSharedIdentityAndCustomColorPreservation() async throws {
        continueAfterFailure = false
        guard let address = ProcessInfo.processInfo.environment["BOTTO_UI_TEST_AVATAR_URL"] else {
            throw XCTSkip("Set BOTTO_UI_TEST_AVATAR_URL to the disposable avatar fixture host; use a signed build.")
        }
        let profiles = try await avatarProfiles(at: address)
        let sunProfile = try XCTUnwrap(profiles.first { $0.name == "Avatar Sun" }, "Missing owned Avatar Sun fixture")
        let customProfile = try XCTUnwrap(profiles.first { $0.name == "Avatar Custom" }, "Missing owned Avatar Custom fixture")
        let app = XCUIApplication()
        app.launchArguments = ["--fixture-server", address]
        app.launch()
        let sun = app.buttons["bot-row-" + sunProfile.id]
        XCTAssertTrue(sun.waitForExistence(timeout: 20)); sun.tap()
        app.buttons["Profile for Avatar Sun"].tap()
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(app.staticTexts["Choosing a shape or color saves a classic face to Hermes and replaces this generated avatar."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-bot-profile"].isEnabled)
        let red = app.buttons["avatar-color-red"]
        reach(red, in: app)
        XCTAssertFalse(red.isEnabled, "A generated Sun needs a deliberate classic shape before color conversion.")
        app.buttons["Cancel"].tap()
        app.buttons["bot-profile-done"].tap()
        app.terminate()

        app.launch()
        let custom = app.buttons["bot-row-" + customProfile.id]
        XCTAssertTrue(custom.waitForExistence(timeout: 20)); custom.tap()
        app.buttons["Profile for Avatar Custom"].tap()
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Cloud · Custom color", in: app, timeout: 5))
        XCTAssertFalse(app.buttons["save-bot-profile"].isEnabled)
        let shape = app.buttons["avatar-shape-hexagon"]
        reach(shape, in: app); shape.tap()
        XCTAssertTrue(avatarPreview("Hexagon · Custom color", in: app, timeout: 0))
        app.buttons["save-bot-profile"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 10))
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Hexagon · Custom color", in: app, timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Live Hermes custom color preserved after shape edit"
        screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Cancel"].tap()
    }

    @MainActor private func avatarPreview(_ value: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let preview = app.descendants(matching: .any).matching(identifier: "bot-avatar-preview").firstMatch
        if timeout == 0 { return preview.exists && preview.value as? String == value }
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            preview.exists && preview.value as? String == value
        }, object: nil)
        return XCTWaiter.wait(for: [expected], timeout: timeout) == .completed
    }

    @MainActor private func avatarProfiles(at address: String) async throws -> [BotProfile] {
        let url = try XCTUnwrap(URL(string: address))
        XCTAssertTrue(["127.0.0.1", "localhost"].contains(url.host ?? ""), "Avatar fixtures must use the owned local host")
        guard ["127.0.0.1", "localhost"].contains(url.host ?? "") else {
            throw URLError(.unsupportedURL)
        }
        let service = HermesBotService()
        defer { service.disconnect() }
        _ = try await service.connect(configuration: .init(serverURL: url, username: "botto-test", password: "botto-test"))
        return try await service.bots()
    }

    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["pinned-bot-milo"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func editMilo(in app: XCUIApplication) {
        app.buttons["pinned-bot-milo"].tap()
        XCTAssertTrue(app.buttons["bot-profile-button"].waitForExistence(timeout: 5))
        app.buttons["bot-profile-button"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 3))
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(app.buttons["save-bot-profile"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["save-bot-profile"].isEnabled, "Opening the editor must not change or clear an avatar.")
        chooseCustomAvatar(in: app)
    }

    @MainActor private func chooseCustomAvatar(in app: XCUIApplication) {
        let mode = app.buttons["avatar-mode"]
        reach(mode, in: app); mode.tap()
        app.buttons["Custom"].tap()
    }

    @MainActor private func reach(_ element: XCUIElement, in app: XCUIApplication) {
        let profileScroll = app.scrollViews.containing(.textField, identifier: "bot-profile-name").firstMatch
        let scroll = profileScroll.exists ? profileScroll : app.scrollViews.firstMatch
        for _ in 0..<8 where !element.isHittable {
            let window = app.frame
            let frame = scroll.frame.intersection(window)
            let navigation = app.navigationBars.firstMatch
            let keyboard = app.keyboards.firstMatch
            let top = max(frame.minY, navigation.exists ? navigation.frame.maxY : frame.minY)
            let bottom = min(frame.maxY, keyboard.exists ? keyboard.frame.minY : frame.maxY)
            let viewport = CGRect(x: frame.minX, y: top, width: frame.width, height: bottom - top)
            guard !viewport.isNull && !viewport.isInfinite && viewport.width > 0 && viewport.height > 44 else {
                XCTFail("Reaching an avatar control requires the visible form above the keyboard.")
                return
            }
            let target = element.exists ? element.frame : .null
            let towardEarlier = !target.isNull && !target.isEmpty && target.minY < viewport.minY
            // The form's padding keeps the drag outside the nested TextEditor.
            let x = viewport.minX + min(12, viewport.width * 0.1)
            let fromY = viewport.minY + viewport.height * (towardEarlier ? 0.2 : 0.8)
            let toY = viewport.minY + viewport.height * (towardEarlier ? 0.8 : 0.2)
            let root = app.coordinate(withNormalizedOffset: .zero)
            let from = root.withOffset(CGVector(dx: x - window.minX, dy: fromY - window.minY))
            let to = root.withOffset(CGVector(dx: x - window.minX, dy: toY - window.minY))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor func testExistingAvatarSaveAndCancel() {
        let app = launch()
        editMilo(in: app)
        let shape = app.buttons["avatar-shape-hexagon"]
        reach(shape, in: app); shape.tap()
        let color = app.buttons["avatar-color-teal"]
        reach(color, in: app); color.tap()
        app.buttons["save-bot-profile"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 5))
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        // A draft starts unchanged; the profile summary exposes the saved result.
        XCTAssertTrue(avatarPreview("Hexagon · Teal", in: app, timeout: 3))
        let different = app.buttons["avatar-shape-circle"]
        reach(different, in: app); different.tap()
        app.buttons["Cancel"].tap()
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Hexagon · Teal", in: app, timeout: 3))
        XCTAssertFalse(app.buttons["save-bot-profile"].isEnabled)
    }

    @MainActor func testNewBotKeepsChosenSharedAvatar() {
        let app = launch()
        app.buttons["New bot"].tap()
        let name = app.textFields["What shall we call them?"]
        XCTAssertTrue(name.waitForExistence(timeout: 3)); name.tap(); name.typeText("Fern\n")
        chooseCustomAvatar(in: app)
        let shape = app.buttons["avatar-shape-drop"]
        reach(shape, in: app); shape.tap()
        let color = app.buttons["avatar-color-green"]
        reach(color, in: app); color.tap()
        let create = app.buttons["Create bot"]
        reach(create, in: app); create.tap()
        XCTAssertTrue(app.buttons["Profile for Fern"].waitForExistence(timeout: 5))
        app.buttons["Profile for Fern"].tap()
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Drop · Green", in: app, timeout: 3))
    }

    @MainActor func testMatchNameKeepsShapeThroughSaveAndLaterShapeEdits() {
        let app = launch()
        editMilo(in: app)
        let hexagon = app.buttons["avatar-shape-hexagon"]
        reach(hexagon, in: app); hexagon.tap()
        let teal = app.buttons["avatar-color-teal"]
        reach(teal, in: app); teal.tap()
        let automaticColor = app.buttons["avatar-color-auto"]
        reach(automaticColor, in: app); automaticColor.tap()
        app.buttons["save-bot-profile"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 5))
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Hexagon · Match the name", in: app, timeout: 3))
        let circle = app.buttons["avatar-shape-circle"]
        reach(circle, in: app); circle.tap()
        app.buttons["save-bot-profile"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 5))
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Circle · Match the name", in: app, timeout: 3))
        reach(teal, in: app); teal.tap()
        app.buttons["Cancel"].tap()
        reach(app.buttons["bot-profile-edit"], in: app); app.buttons["bot-profile-edit"].tap()
        XCTAssertTrue(avatarPreview("Circle · Match the name", in: app, timeout: 3))
        XCTAssertFalse(app.buttons["save-bot-profile"].isEnabled)
    }

    @MainActor func testLargestTextCanSelectAndCancelAvatarWithReducedMotion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reduce-motion", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let milo = app.buttons["bot-row-milo"]
        XCTAssertTrue(milo.waitForExistence(timeout: 5)); milo.tap()
        app.buttons["bot-profile-button"].tap()
        let change = app.buttons["bot-profile-edit"]
        reach(change, in: app); change.tap()
        chooseCustomAvatar(in: app)
        let shape = app.buttons["avatar-shape-cloud"]
        reach(shape, in: app); shape.tap()
        let color = app.buttons["avatar-color-auto"]
        reach(color, in: app); color.tap()
        XCTAssertTrue(app.buttons["save-bot-profile"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Avatar picker, largest text, Reduce Motion"
        screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["bot-profile-edit"].waitForExistence(timeout: 3))
    }
}
