import Foundation
import Testing
@testable import BottoCore

private let catJSON = #"{"version":1,"id":"cat","name":"Cat","body":{"path":"M18 34 L18 12 Q18 8 23 12 L35 24 Q50 20 65 24 L77 12 Q82 8 82 12 L82 34 Q90 40 88 62 Q88 86 50 88 Q12 86 12 62 Q10 40 18 34 Z"},"eyes":{"x":50,"y":48,"spacing":16,"scale":1}}"#

@Test func customAvatarAcceptsNewSilhouetteAndRoundtripsItsShapeRecipe() throws {
    let cat = try BotAvatarGeometry(json: catJSON)
    #expect(cat.name == "Cat")
    #expect(cat.bodyPath.hasPrefix("M18 34"))
    #expect(BotAvatarGeometry.fromRecipe(cat.recipe) == cat)
    let appearance = BotAvatarChoice.geometry(cat).applying(to: BotAppearance(shape: .circle, color: "#123456"))
    #expect(appearance.geometry == cat && appearance.color == "#123456")
    let restored = try JSONDecoder().decode(BotAppearance.self, from: JSONEncoder().encode(appearance))
    #expect(restored == appearance && restored.geometry == cat)
}

@Test func customAvatarStructuralDecoderRejectsWrongSchemaAndExcessiveData() throws {
    let invalid = [
        catJSON.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
        catJSON.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"color\":\"red\""),
        catJSON.replacingOccurrences(of: "\"path\":", with: "\"path\":4,\"extra\":"),
        catJSON.replacingOccurrences(of: "18 34 Z", with: "18 34 Z" + String(repeating: " ", count: 6000)),
        catJSON + String(repeating: " ", count: 8192)
    ]
    for json in invalid { #expect(throws: (any Error).self) { try BotAvatarGeometry(json: json) } }
    for text in ["", "null", "{}", "[]", "```json\n" + catJSON + "\n```"] {
        #expect(throws: (any Error).self) { try BotAvatarGeometry(json: text) }
    }
    let missingID = catJSON.replacingOccurrences(of: #""id":"cat","#, with: "")
    #expect(throws: (any Error).self) { try BotAvatarGeometry(json: missingID) }
}

@Test func customAvatarStructuralDecoderPreservesTheFullCanonicalPathLanguage() async throws {
    let paths = [
        "m50 10 a40 40 0 1 1 0 80 a40 40 0 1 1 0 -80",
        "M20 20 h60 v60 h-60 z",
        "M30 12 C80 12 88 20 88 50 S80 88 50 88 C20 88 12 80 12 50 S20 12 30 12 Z",
        "M30 12 H70 Q88 12 88 30 V70 T70 88 H30 Q12 88 12 70 V30 T30 12 Z"
    ]
    for path in paths {
        let geometry = try geometryDefinition(path: path)
        #expect(geometry.bodyPath == path)
        #expect(try BotAvatarGeometry(json: geometry.json) == geometry)
        #expect(try await BotAvatarEngine.shared.validate(geometry).id == "fixture")
    }
    for scale in [0.6, 1.8] {
        let geometry = try geometryDefinition(path: paths[0], scale: scale)
        #expect(geometry.eyes.scale == scale)
        #expect(try await BotAvatarEngine.shared.validate(geometry).eyes.scale == scale)
    }
    // Coordinate controls and semantic path/face constraints belong to the reference engine.
    let broadControls = try geometryDefinition(path: "M20 20 C-20 20 120 80 80 80 Z")
    #expect(broadControls.bodyPath.contains("-20"))
    #expect(try geometryDefinition(path: "M8 8 L9 8").bodyPath == "M8 8 L9 8")
}

@Test func customAvatarCacheAndEditsKeepExactlyOneShapeIdentity() throws {
    let cat = try BotAvatarGeometry(json: catJSON)
    var appearance = BotAvatarChoice.geometry(cat).applying(to: BotAppearance(shape: .circle, color: "#123456"))
    appearance = BotAvatarChoice.edit(.init(color: .value("#654321"))).applying(to: appearance)
    #expect(appearance.geometry == cat && appearance.rawShape == cat.recipe)
    #expect(appearance.color == "#654321")
    let classic = BotAvatarChoice.edit(.init(shape: .cloud)).applying(to: appearance)
    #expect(classic.geometry == nil && classic.shape == .cloud)
    #expect(classic.color == "#654321")
    let automatic = BotAvatarChoice.automatic.applying(to: appearance)
    #expect(automatic.geometry == nil && automatic.rawShape == nil && automatic.color == nil)
    appearance.rawShape = "circle"
    #expect(appearance.geometry == nil)
    appearance.rawShape = cat.recipe
    #expect(appearance.geometry == cat)
    appearance.shape = .pill
    #expect(appearance.geometry == nil)
}

@Test func customAvatarUnknownFutureAndMalformedRecipesRemainOpaque() throws {
    let cat = try BotAvatarGeometry(json: catJSON)
    let values = ["botto-path:2:some-future-payload", "botto-path:1:invalid*", "botto-path:1:",
                  cat.recipe.replacingOccurrences(of: "botto-path:1:", with: "botto-path:3:")]
    for raw in values {
        #expect(BotAvatarGeometry.fromRecipe(raw) == nil)
        let appearance = BotAppearance(rawShape: raw, color: "#123456", custom: true)
        let restored = try JSONDecoder().decode(BotAppearance.self, from: JSONEncoder().encode(appearance))
        #expect(restored.rawShape == raw && restored.geometry == nil)
        let edited = BotAvatarChoice.edit(.init(color: .automatic)).applying(to: restored)
        #expect(edited.rawShape == raw && edited.color == nil)
    }
    let old = try JSONDecoder().decode(BotAppearance.self, from: Data(##"{"shape":"cloud","custom":true,"color":"#123456"}"##.utf8))
    #expect(old.shape == .cloud && old.geometry == nil)
}

@Test func customAvatarStagedColorChoiceKeepsTheNewGeometry() throws {
    let cat = try BotAvatarGeometry(json: catJSON)
    let current = BotAppearance(shape: .cloud, color: "unsupported-shared-color")
    let untouched = BotAvatarChoice.geometry(cat).applying(to: current)
    #expect(untouched.geometry == cat && untouched.color == "unsupported-shared-color")
    let orange = BotAvatarChoice.geometry(cat, color: .value("#f97316"))
    #expect(orange.applying(to: current).geometry == cat)
    #expect(orange.applying(to: current).color == BotAvatarColors.preset(for: "#f97316")?.shared)
    let original: [String: HermesJSON] = ["shape": .string("cloud"), "color": .string("unsupported-shared-color"), "title": .string("Keep")]
    let colored = orange.merging(into: original)
    #expect(colored["shape"]?.text == cat.recipe && colored["title"]?.text == "Keep")
    #expect(colored["color"]?.text == orange.applying(to: current).color)
    let automatic = BotAvatarChoice.geometry(cat, color: .automatic)
    #expect(automatic.applying(to: current).geometry == cat && automatic.applying(to: current).color == nil)
    #expect(automatic.merging(into: original)["color"] == nil)
    #expect(throws: HermesServiceError.invalidAvatar) {
        try BotAvatarChoice.geometry(cat, color: .value("unrecognized-explicit-color")).validate()
    }
}

@Test func customAvatarUsesTheOpenBotAvatarV1IdentityAndCanonicalJSON() throws {
    let cat = try BotAvatarGeometry(json: catJSON)
    #expect(cat.id == "cat")
    #expect(try BotAvatarGeometry(json: cat.json) == cat)
    let object = try #require(JSONSerialization.jsonObject(with: Data(cat.json.utf8)) as? [String: Any])
    #expect(Set(object.keys) == ["version", "id", "name", "body", "eyes"])
    #expect(object["id"] as? String == "cat")
}

@Test func customAvatarCanonicalEngineOwnsSemanticRejectionAndNormalization() async throws {
    let tooSmall = try geometryDefinition(path: "M8 8 L9 8 L9 9 Z")
    await #expect(throws: (any Error).self) { try await BotAvatarEngine.shared.validate(tooSmall) }
    for id in ["", "-cat", "cat-", "Cat", "cat_2", "cät", "cat.cat", String(repeating: "a", count: 41)] {
        let json = catJSON.replacingOccurrences(of: #""id":"cat""#, with: "\"id\":\"\(id)\"")
        let structural = try BotAvatarGeometry(json: json)
        await #expect(throws: (any Error).self) { try await BotAvatarEngine.shared.validate(structural) }
    }
    let whitespace = try BotAvatarGeometry(json: catJSON.replacingOccurrences(of: #""name":"Cat""#, with: #""name":"  Cat  ""#))
    let normalized = try await BotAvatarEngine.shared.validate(whitespace)
    #expect(normalized.name == "Cat")
}

@Test func hermesAvatarCatalogKeepsAOneToOneShapeFamilyMapping() {
    #expect(BotAvatarShape.allCases.count == 10)
    let definitions = BotAvatarShape.allCases.map { BotAvatarCatalog.geometry(for: $0) }
    #expect(Set(definitions.map(\.id)) == Set(BotAvatarShape.allCases.map(\.rawValue)))
    for shape in BotAvatarShape.allCases {
        let geometry = BotAvatarCatalog.geometry(for: shape)
        #expect(geometry.id == shape.rawValue)
        #expect(geometry.eyes.x == 50)
        #expect(geometry.eyes.y == (shape == .triangle ? 59 : 46))
    }
}

@Test func hermesAvatarCatalogDefinitionsPassCanonicalValidation() async throws {
    for shape in BotAvatarShape.allCases {
        let geometry = BotAvatarCatalog.geometry(for: shape)
        let canonical = try await BotAvatarEngine.shared.validate(geometry)
        #expect(canonical.id == shape.rawValue)
    }
}

@Test func hermesAvatarCatalogPreservesDefaultsBlobatarSeedsAndSavedMetadata() throws {
    let defaults: [(String, BotAvatarShape, String)] = [
        ("default", .squircle, "#8b5cf6"),
        ("inbox-triage", .cloud, "hsl(90 68% 58%)"),
        ("🐱bot", .circle, "hsl(150 68% 58%)")
    ]
    for (profileID, shape, color) in defaults {
        let appearance = BotAppearance()
        let face = appearance.face(for: profileID)
        #expect(face == BotFace(shape: shape, color: color))
        #expect(BotAvatarCatalog.geometry(for: face.shape).id == shape.rawValue)
        #expect(appearance.rawShape == nil && !appearance.custom)
    }
    let blobatars: [(String, BotAvatarShape, Double)] = [
        ("fixture-2", .cloud, 346.9816969614476),
        ("fixture-15", .nub, 194.07705014571548),
        ("fixture-33", .sun, 335.02056087367237)
    ]
    for (profileID, shape, hue) in blobatars {
        let appearance = BotAppearance(rawShape: "blobatar", color: "#ff0000", custom: true)
        let face = appearance.face(for: profileID)
        #expect(face == BotFace(shape: shape, color: BotAvatarColors.blobatarColor(hue: hue)))
        #expect(BotAvatarCatalog.geometry(for: face.shape).id == shape.rawValue)
        #expect(appearance.rawShape == "blobatar" && appearance.color == "#ff0000")
        #expect(try JSONDecoder().decode(BotAppearance.self, from: JSONEncoder().encode(appearance)) == appearance)
    }
}

private func geometryDefinition(path: String, scale: Double = 1) throws -> BotAvatarGeometry {
    let definition: [String: Any] = ["version": 1, "id": "fixture", "name": "Fixture", "body": ["path": path],
        "eyes": ["x": 50, "y": 46, "spacing": 16, "scale": scale]]
    let data = try JSONSerialization.data(withJSONObject: definition)
    return try BotAvatarGeometry(json: String(decoding: data, as: UTF8.self))
}
