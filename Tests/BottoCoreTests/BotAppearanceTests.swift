import Foundation
import Testing
@testable import BottoCore

@Test(arguments: [BotAvatarChoice.automatic, .shape(.hexagon), .face(BotFace(shape: .hexagon, color: "#ef4444"))])
func completeChoicesKeepUneditedExpressionWhenAppliedToAnExistingLook(choice: BotAvatarChoice) {
    let current = BotAppearance(shape: .cloud, color: "#123456", expression: "curious")
    #expect(choice.applying(to: current).expression == "curious")
    #expect(choice.appearance.expression == nil)
}

@MainActor @Test(arguments: [true, false], ["aliceblue", "color(display-p3 1 0 0)", "var(--avatar-color)"])
func shapeOnlyEditKeepsUnrecognizedColorAndFreshMetadata(authority: Bool, color: String) async throws {
    let host = try HermesTestHost(authority: authority)
    let original: [String: HermesJSON] = ["shape": .string("cloud"), "color": .string(color),
        "custom": .bool(true), "imageKind": .string("shape"), "future": .bool(true), "title": .string("Kept title")]
    host.profiles = .object(["profiles": .array([.object(["name": .string("inbox-triage"), "has_avatar": .bool(false),
        "ui_meta_revisions": .object(["hermes-bots": .number(2)]),
        "ui_meta": .object(["hermes-bots": .object(original)])])])])
    var written: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.configure" {
            written = frame["params"]["ui_meta"]["hermes-bots"]
            return .object(["applied": .object(["ui_meta": .bool(true)])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    let choice = BotAvatarChoice.edit(BotAvatarEdit(shape: .hexagon))
    let saved = try await service.setAvatar(choice, for: bot)
    var expected = original; expected["shape"] = .string("hexagon")
    #expect(written == .object(expected))
    #expect(saved.appearance?.rawShape == "hexagon" && saved.appearance?.color == color)
    #expect(choice.applying(to: bot.appearance ?? BotAppearance()).color == color)
}

@MainActor @Test(arguments: [true, false], ["sigil-4", "tetrahedron", "future-outline"])
func colorOnlyEditKeepsRawShapeAndOtherMetadata(authority: Bool, raw: String) async throws {
    let host = try HermesTestHost(authority: authority)
    let original: [String: HermesJSON] = ["shape": .string(raw), "color": .string("#123456"),
        "custom": .bool(true), "imageKind": .string("shape"), "future": .bool(true), "expression": .string("curious")]
    host.profiles = .object(["profiles": .array([.object(["name": .string("inbox-triage"), "has_avatar": .bool(false),
        "ui_meta_revisions": .object(["hermes-bots": .number(2)]),
        "ui_meta": .object(["hermes-bots": .object(original)])])])])
    var written: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.configure" {
            written = frame["params"]["ui_meta"]["hermes-bots"]
            return .object(["applied": .object(["ui_meta": .bool(true)])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    let choice = BotAvatarChoice.edit(BotAvatarEdit(color: .value("#ef4444")))
    let saved = try await service.setAvatar(choice, for: bot)
    var expected = original; expected["color"] = .string("hsl(0 68% 58%)")
    #expect(written == .object(expected))
    #expect(saved.appearance?.rawShape == raw)
    #expect(choice.applying(to: bot.appearance ?? BotAppearance()).rawShape == raw)
}

@MainActor @Test(arguments: [BotAvatarEdit(), BotAvatarEdit(color: .value("aliceblue")),
                            BotAvatarEdit(shape: .sun), BotAvatarEdit(shape: .nub)])
func invalidNewEditsCannotWriteMetadata(edit: BotAvatarEdit) async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    await #expect(throws: HermesServiceError.invalidAvatar) {
        _ = try await service.setAvatar(.edit(edit), for: host.bot)
    }
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: [BotAvatarEdit.Color.automatic, .value("#ef4444")])
func generatedColorEditNeedsExplicitClassicConversion(color: BotAvatarEdit.Color) async throws {
    let host = try HermesTestHost()
    host.profiles = .object(["profiles": .array([.object(["name": .string("inbox-triage"), "has_avatar": .bool(false),
        "ui_meta_revisions": .object(["hermes-bots": .number(2)]),
        "ui_meta": .object(["hermes-bots": .object(["shape": .string("blobatar:locked:round"), "custom": .bool(true)])])])])])
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    await #expect(throws: HermesServiceError.invalidAvatar) {
        _ = try await service.setAvatar(.edit(BotAvatarEdit(color: color)), for: bot)
    }
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: [true, false])
func matchingNameRemovesColorOverrideAndKeepsChosenShape(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority)
    host.profiles = .object(["profiles": .array([.object(["name": .string("inbox-triage"),
        "has_avatar": .bool(false), "ui_meta_revisions": .object(["hermes-bots": .number(2)]),
        "ui_meta": .object(["hermes-bots": .object(["shape": .string("hexagon"), "color": .string("#ffffff"),
            "custom": .bool(true), "title": .string("Kept title"), "future": .bool(true),
            "expression": .string("happy")])])])])])
    var written: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.configure" {
            written = frame["params"]["ui_meta"]["hermes-bots"]
            #expect(frame["params"]["ui_meta_expected_revisions"]["hermes-bots"].integer == 2)
            return .object(["applied": .object(["ui_meta": .bool(true)])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    let saved = try await service.setAvatar(.shape(.hexagon), for: bot)
    #expect(written?["color"] == .null)
    #expect(written?["shape"].text == "hexagon" && written?["custom"].flag == true)
    #expect(written?["future"].flag == true && written?["title"].text == "Kept title")
    #expect(written?["expression"].text == "happy")
    #expect(saved.appearance?.color == nil)
    // Independent pinned Desktop fixture: inbox-triage hashes to hue 99 (Botto's lime family).
    #expect(saved.face == BotFace(shape: .hexagon, color: "hsl(90 68% 58%)"))
}

@MainActor @Test(arguments: [true, false], [
    ("#ef4444", "hsl(0 68% 58%)"),
    ("hsl(360deg 68% 58%)", "hsl(0 68% 58%)"),
    ("rgb(220.728 147.9 75.072)", "hsl(30 68% 58%)")
])
func shapeOnlySavesCanonicalizeRecognizedPresets(authority: Bool, fixture: (String, String)) async throws {
    let (source, canonical) = fixture
    let host = try HermesTestHost(authority: authority)
    host.profiles = .object(["profiles": .array([.object(["name": .string("inbox-triage"),
        "has_avatar": .bool(false), "ui_meta_revisions": .object(["hermes-bots": .number(2)]),
        "ui_meta": .object(["hermes-bots": .object(["shape": .string("cloud"), "color": .string(source),
            "custom": .bool(true), "title": .string("Preset fixture"), "future": .bool(true)])])])])])
    var written: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.configure" {
            written = frame["params"]["ui_meta"]["hermes-bots"]
            return .object(["applied": .object(["ui_meta": .bool(true)])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    #expect(bot.face.color == source)
    let saved = try await service.setAvatar(.face(.init(shape: .hexagon, color: bot.face.color)), for: bot)
    #expect(written?["color"].text == canonical)
    #expect(written?["future"].flag == true && written?["title"].text == "Preset fixture")
    #expect(saved.face.color == canonical)
}

@MainActor @Test(arguments: [true, false])
func rosterUsesSharedAppearanceAndKeepsLegacyCacheReadable(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority)
    host.profiles = .object(["profiles": .array([
        .object(["name": .string("inbox-triage"), "has_avatar": .bool(true),
                 "ui_meta_revisions": .object(["hermes-bots": .number(7)]),
                 "ui_meta": .object(["hermes-bots": .object([
                    "title": .string("Renamed"), "shape": .string("cloud"), "color": .string("#ffffff"),
                    "imageKind": .string("photo"), "expression": .string("happy"), "pinned": .bool(true)])])]),
        .object(["name": .string("default")])
    ])])
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bots = try await service.bots()
    let first = try #require(bots.first)
    #expect(first.name == "Renamed" && first.isPinned)
    #expect(first.hasAvatar == true && first.lookRevision == 7)
    #expect(first.appearance?.shape == .cloud)
    #expect(first.appearance?.color == "#ffffff")
    #expect(first.appearance?.imageKind == "photo")
    #expect(first.appearance?.expression == "happy")
    #expect(bots[1].face.shape == .squircle && bots[1].face.color == "#8b5cf6")
    let oldJSON = Data(#"{"id":"default","name":"Old name","emoji":"🌿","description":"","preview":"","status":"idle","isPinned":false}"#.utf8)
    let cached = try JSONDecoder().decode(BotProfile.self, from: oldJSON)
    #expect(cached.face == bots[1].face)
    #expect(cached.emoji == "🌿")
    #expect(try JSONDecoder().decode(BotProfile.self, from: JSONEncoder().encode(first)) == first)
}

@MainActor @Test(arguments: [true, false], [true, false])
func creationPersistsSharedFaceWithoutBottoEmoji(authority: Bool, automaticColor: Bool) async throws {
    let host = try HermesTestHost(authority: authority)
    var look: HermesJSON = .null
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "profiles.create":
            return .object(["ok": .bool(true), "model_set": .bool(true)])
        case "profiles.configure":
            #expect(frame["params"]["name"].text == "inbox-triage")
            #expect(frame["params"]["ui_meta"]["botto"] == .null)
            #expect(frame["params"]["ui_meta_expected_revisions"] == .object(["hermes-bots": .number(0)]))
            look = frame["params"]["ui_meta"]["hermes-bots"]
            host.profiles = .object(["profiles": .array([.object(["name": .string("inbox-triage"),
                "model": .string("default-model"), "ui_meta": .object(["hermes-bots": look])])])])
            return .object(["applied": .object(["ui_meta": .bool(true)])])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    host.profiles = .object(["profiles": .array([])])
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let draft = BotDraft(name: "Inbox triage", avatar: automaticColor ? .shape(.drop) : .face(.init(shape: .drop, color: "#14b8a6")))
    let created = try await service.createBot(draft)
    #expect(created.face == BotFace(shape: .drop, color: automaticColor ? "hsl(90 68% 58%)" : "hsl(180 68% 58%)"))
    var expected: [String: HermesJSON] = ["title": .string("Inbox triage"), "shape": .string("drop"),
        "custom": .bool(true), "imageKind": .string("shape")]
    if !automaticColor { expected["color"] = .string("hsl(180 68% 58%)") }
    #expect(look == .object(expected))
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "profiles.set_asset" })
}

@MainActor @Test(arguments: [true, false])
func selectingFaceMergesFreshLookAndClearsImageAfterCAS(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority)
    let row: HermesJSON = .object(["name": .string("inbox-triage"), "has_avatar": .bool(true),
        "ui_meta_revisions": .object(["hermes-bots": .number(9)]), "ui_meta": .object([
            "botto": .object(["emoji": .string("🌿")]), "hermes-bots": .object([
                "title": .string("Changed elsewhere"), "pinned": .bool(true), "groupId": .string("family"),
                "future": .object(["nested": .number(42)]), "expression": .string("curious"), "imageKind": .string("photo")])])])
    var presentedRow = row
    presentedRow["ui_meta_revisions"]["hermes-bots"] = .number(3)
    presentedRow["ui_meta"]["hermes-bots"]["title"] = .string("Before edit")
    presentedRow["ui_meta"]["hermes-bots"]["pinned"] = .bool(false)
    presentedRow["ui_meta"]["hermes-bots"]["groupId"] = .string("old-group")
    host.profiles = .object(["profiles": .array([presentedRow])])
    var configured = false, cleared = false
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "profiles.configure":
            #expect(frame["params"]["name"].text == "inbox-triage")
            #expect(frame["params"]["ui_meta_expected_revisions"] == .object(["hermes-bots": .number(9)]))
            let look = frame["params"]["ui_meta"]["hermes-bots"]
            #expect(look["title"].text == "Changed elsewhere")
            #expect(look["pinned"].flag == true && look["groupId"].text == "family")
            #expect(look["future"]["nested"].integer == 42 && look["expression"].text == "curious")
            #expect(look["shape"].text == "hexagon" && look["color"].text == "hsl(120 68% 58%)")
            #expect(look["imageKind"].text == "shape" && look["custom"].flag == true)
            #expect(frame["params"]["ui_meta"].fields?.count == 1)
            configured = true
            return .object(["applied": .object(["ui_meta": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(10)])])])
        case "profiles.set_asset":
            #expect(configured)
            #expect(frame["params"] == .object(["name": .string("inbox-triage"), "asset": .string("avatar"), "clear": .bool(true)]))
            cleared = true
            return .object(["ok": .bool(true), "asset": .string("avatar"), "size": .number(0)])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let stale = try #require(try await service.bots().first)
    host.profiles = .object(["profiles": .array([row])])
    let saved = try await service.setAvatar(.face(.init(shape: .hexagon, color: "#22c55e")), for: stale)
    #expect(cleared && saved.hasAvatar == false)
    #expect(saved.name == "Changed elsewhere" && saved.lookRevision == 10)
    #expect(saved.face == BotFace(shape: .hexagon, color: "hsl(120 68% 58%)"))
}

@MainActor @Test(arguments: ["conflict", "partial", "uncertain", "new-photo"])
func avatarSaveReportsUnconfirmedWritesWithoutRetrying(outcome: String) async throws {
    let host = try HermesTestHost()
    host.profiles = .object(["profiles": .array([.object(["name": .string("inbox-triage"),
        "has_avatar": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(2)])])])])
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "profiles.configure":
            if outcome == "uncertain" { return nil }
            if outcome == "conflict" {
                return .object(["applied": .object(["ui_meta": .bool(false), "ui_meta_conflicts": .object([
                    "hermes-bots": .object(["expected": .number(2), "actual": .number(3)])])])])
            }
            return .object(["applied": .object(["ui_meta": .bool(true)])])
        case "profiles.set_asset": socket.reject(frame, code: -32601); return nil
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    let service = host.service(requestTimeout: .milliseconds(50)); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    var bot = host.bot; bot.hasAvatar = outcome != "new-photo"
    let expected: HermesServiceError = outcome == "partial" ? .partialAvatar : outcome == "uncertain" ? .uncertainAvatar : .avatarConflict
    await #expect(throws: expected) { _ = try await service.setAvatar(.automatic, for: bot) }
    let calls = host.sockets[0].sent
    #expect(calls.filter { $0["method"].text == "profiles.configure" }.count == (outcome == "new-photo" ? 0 : 1))
    #expect(calls.filter { $0["method"].text == "profiles.set_asset" }.count == (outcome == "partial" ? 1 : 0))
}

@MainActor @Test func cancelledAppearanceReadCannotWriteToReplacementConnection() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    var held: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.list", socket === host.sockets.first {
            #expect(frame["params"]["profile"].text == host.bot.id)
            held = frame; return nil
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    let saving = Task { try await service.setAvatar(.face(.init(shape: .cloud, color: "#ffffff")), for: host.bot) }
    try await eventually { held != nil }
    service.disconnect()
    _ = try await service.connect(configuration: host.configuration)
    if let held { host.sockets[0].push(.object(["id": held["id"], "result": host.profiles])) }
    await #expect(throws: HermesServiceError.disconnected) { _ = try await saving.value }
    #expect(!host.sockets.flatMap(\.sent).contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

@MainActor @Test func defaultFaceUsesCanonicalProfileIDRatherThanTitleOrBottoEmoji() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    host.profiles = .object(["profiles": .array([.object(["name": .string("inbox-triage"),
        "ui_meta": .object(["hermes-bots": .object(["title": .string("Renamed helper")]),
                            "botto": .object(["emoji": .string("🌞")])])])])])
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    // Pinned Desktop reference: the 31-based shape hash selects cloud;
    // profileColor derives hue 99, represented by the nearest preset (90).
    #expect(bot.face == BotFace(shape: .cloud, color: "hsl(90 68% 58%)"))
    #expect(bot.name == "Renamed helper")
    #expect(BotDraft(name: "Inbox triage").profileID == bot.id)
}

@MainActor @Test(arguments: [true, false], ["photo", "shape", "color", "expression", "removed-image"])
func avatarSaveRejectsObservableAppearanceChanges(authority: Bool, change: String) async throws {
    let host = try HermesTestHost(authority: authority)
    var row: HermesJSON = .object(["name": .string("inbox-triage"), "has_avatar": .bool(true),
        "ui_meta_revisions": .object(["hermes-bots": .number(1)]),
        "ui_meta": .object(["hermes-bots": .object([
            "custom": .bool(true), "shape": .string("cloud"), "color": .string("#14b8a6"), "imageKind": .string("shape")])])])
    host.profiles = .object(["profiles": .array([row])])
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.configure" {
            return .object(["applied": .object(["ui_meta": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(3)])])])
        }
        if frame["method"].text == "profiles.set_asset" { return .object(["ok": .bool(true), "asset": .string("avatar")]) }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let presented = try #require(try await service.bots().first)
    switch change {
    case "photo": row["ui_meta"]["hermes-bots"]["imageKind"] = .string("photo")
    case "shape": row["ui_meta"]["hermes-bots"]["shape"] = .string("drop")
    case "color": row["ui_meta"]["hermes-bots"]["color"] = .string("#ffffff")
    case "expression": row["ui_meta"]["hermes-bots"]["expression"] = .string("happy")
    default: row["has_avatar"] = .bool(false)
    }
    row["ui_meta_revisions"]["hermes-bots"] = .number(2)
    host.profiles = .object(["profiles": .array([row])])
    await #expect(throws: HermesServiceError.avatarConflict) {
        _ = try await service.setAvatar(.face(.init(shape: .hexagon, color: "#22c55e")), for: presented)
    }
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: [true, false], ["future-outline", "blobatar:locked:sun"])
func rosterRetainsRawChoicesForCachesAndConflictDetection(authority: Bool, raw: String) async throws {
    let host = try HermesTestHost(authority: authority)
    var row: HermesJSON = .object(["name": .string("inbox-triage"), "has_avatar": .bool(false),
        "ui_meta_revisions": .object(["hermes-bots": .number(1)]),
        "ui_meta": .object(["hermes-bots": .object([
            "shape": .string(raw), "custom": .bool(true), "expression": .string("curious")])])])
    host.profiles = .object(["profiles": .array([row])])
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let presented = try #require(try await service.bots().first)
    #expect(presented.appearance?.rawShape == raw)
    let cached = try JSONDecoder().decode(BotProfile.self, from: JSONEncoder().encode(presented))
    #expect(cached == presented && cached.appearance?.rawShape == raw)
    _ = cached.face
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
    row["ui_meta"]["hermes-bots"]["shape"] = .string("another-future-outline")
    row["ui_meta_revisions"]["hermes-bots"] = .number(2)
    host.profiles = .object(["profiles": .array([row])])
    await #expect(throws: HermesServiceError.avatarConflict) {
        _ = try await service.setAvatar(.automatic, for: cached)
    }
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: ["sun", "nub"])
func displayOnlySilhouettesRequireAClassicChoiceBeforeSaving(raw: String) async throws {
    let shape = try #require(BotAvatarShape(rawValue: raw))
    #expect(BotAvatarShape.pickerCases == [.circle, .blob, .squircle, .pill, .triangle, .hexagon, .cloud, .drop])
    #expect(!BotAvatarShape.pickerCases.contains(shape))
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    for choice in [BotAvatarChoice.shape(shape), .face(.init(shape: shape, color: "#ffffff"))] {
        await #expect(throws: HermesServiceError.invalidAvatar) {
            _ = try await service.setAvatar(choice, for: host.bot)
        }
    }
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: [true, false], ["#AbC123", "#aBcD", "rgb(10 20 30 / .4)", "hsl(225 42% 67%)"])
func changingClassicShapePreservesExactCustomColorAndOtherMetadata(authority: Bool, color: String) async throws {
    let host = try HermesTestHost(authority: authority)
    let original: [String: HermesJSON] = [
        "shape": .string("cloud"), "color": .string(color), "custom": .bool(true), "imageKind": .string("shape"),
        "title": .string("Custom helper"), "expression": .string("curious"), "pinned": .bool(true),
        "groupId": .string("family"), "future": .object(["nested": .number(42)])]
    host.profiles = .object(["profiles": .array([.object(["name": .string("inbox-triage"), "has_avatar": .bool(false),
        "ui_meta_revisions": .object(["hermes-bots": .number(7)]),
        "ui_meta": .object(["hermes-bots": .object(original)])])])])
    var configured: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "profiles.configure" {
            configured = frame["params"]["ui_meta"]["hermes-bots"]
            #expect(frame["params"]["ui_meta_expected_revisions"] == .object(["hermes-bots": .number(7)]))
            return .object(["applied": .object(["ui_meta": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(8)])])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    #expect(bot.face == BotFace(shape: .cloud, color: color))
    var face = bot.face
    face.shape = .triangle
    let saved = try await service.setAvatar(.face(face), for: bot)
    var expected = original
    expected["shape"] = .string("triangle")
    #expect(configured == .object(expected))
    #expect(saved.face == BotFace(shape: .triangle, color: color))
    #expect(saved.appearance?.expression == "curious" && saved.lookRevision == 8)
}

@MainActor @Test(arguments: [true, false], [true, false])
func rosterHonorsExplicitCustomizationFlagForSeededPrimaryAppearance(authority: Bool, custom: Bool) async throws {
    let host = try HermesTestHost(authority: authority)
    host.profiles = .object(["profiles": .array([.object(["name": .string("default"),
        "ui_meta": .object(["hermes-bots": .object([
            "shape": .string("blobatar:Locked:sun"), "color": .string("#123456"), "custom": .bool(custom),
            "title": .string("Renamed primary"), "expression": .string("curious")])])])])])
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    let cached = try JSONDecoder().decode(BotProfile.self, from: JSONEncoder().encode(bot))
    #expect(cached.appearance?.rawShape == "blobatar:Locked:sun" && cached.appearance?.custom == custom)
    let expected = custom ? BotFace(shape: .sun, color: BotAvatarColors.blobatarColor(hue: 239.96370445936918))
                          : BotFace(shape: .squircle, color: "#8b5cf6")
    #expect(bot.face == expected && cached.face == expected)
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: ["invalid", "#12", "rgb(nope)"])
func invalidFaceColorCannotWriteSharedMetadata(color: String) async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    await #expect(throws: HermesServiceError.invalidAvatar) {
        _ = try await service.setAvatar(.face(.init(shape: .cloud, color: color)), for: host.bot)
    }
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}
