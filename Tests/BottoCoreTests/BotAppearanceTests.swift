import Foundation
import Testing
@testable import BottoCore

@Test(arguments: [BotAvatarChoice.automatic, .shape(.hexagon), .face(BotFace(shape: .hexagon, color: "#ef4444"))])
func completeChoicesKeepUneditedExpressionWhenAppliedToAnExistingLook(choice: BotAvatarChoice) {
    let current = BotAppearance(shape: .cloud, color: "#123456", expression: "curious")
    #expect(choice.applying(to: current).expression == "curious")
    #expect(choice.appearance.expression == nil)
}

@Test(arguments: [BotAvatarEdit(), BotAvatarEdit(color: .value("aliceblue")),
                  BotAvatarEdit(shape: .sun), BotAvatarEdit(shape: .nub)])
func invalidAvatarEditsAreRejected(edit: BotAvatarEdit) {
    #expect(throws: ConversationServiceError.invalidAvatar) {
        try BotAvatarChoice.edit(edit).validate()
    }
}

@Test(arguments: [BotAvatarEdit.Color.automatic, .value("#ef4444")])
func generatedColorEditsRequireAClassicShape(color: BotAvatarEdit.Color) throws {
    let current = BotAppearance(rawShape: "blobatar:locked:round", custom: true)
    #expect(throws: ConversationServiceError.invalidAvatar) {
        try BotAvatarChoice.edit(.init(color: color)).validate(current: current)
    }
    try BotAvatarChoice.edit(.init(shape: .circle, color: color)).validate(current: current)
}

@Test(arguments: [BotAvatarShape.sun, .nub])
func displayOnlySilhouettesCannotBeSavedAsClassicFaces(shape: BotAvatarShape) {
    for choice in [BotAvatarChoice.shape(shape), .face(.init(shape: shape, color: "#ffffff"))] {
        #expect(throws: ConversationServiceError.invalidAvatar) { try choice.validate() }
    }
}

@Test(arguments: ["invalid", "#12", "rgb(nope)"])
func invalidFaceColorsAreRejected(color: String) {
    #expect(throws: ConversationServiceError.invalidAvatar) {
        try BotAvatarChoice.face(.init(shape: .cloud, color: color)).validate()
    }
}

@Test func earlierSavedBotProfilesKeepTheirFallbackFace() throws {
    let legacy = Data(#"{"id":"default","name":"Old name","emoji":"🌿","description":"","preview":"","status":"idle","isPinned":false}"#.utf8)
    let restored = try JSONDecoder().decode(BotProfile.self, from: legacy)
    #expect(restored.emoji == "🌿")
    #expect(restored.appearance == nil && restored.hasAvatar == nil && restored.lookRevision == nil)
    #expect(restored.face.shape == .squircle && restored.face.color == "#8b5cf6")

    let current = BotProfile(id: "default", name: "Renamed", appearance: .init(shape: .cloud, color: "#ffffff"),
                             hasAvatar: true, lookRevision: 7)
    let saved = try JSONEncoder().encode(current)
    #expect(try JSONDecoder().decode(BotProfile.self, from: saved) == current)
}

/// Older bot.json files can carry image fields from before T3. They still decode, round-trip,
/// and the next look edit clears the preview hash while keeping the rest.
@Test func savedBotJSONWithImageFieldsStillDecodes() throws {
    let hash = String(repeating: "ab", count: 32)
    let saved = Data(##"{"displayName":"Kit","avatar":{"shape":"cloud","color":"#123456","custom":true,"imageKind":"photo","expression":"curious","bottoPreviewSHA256":"\##(hash)"}}"##.utf8)
    let manifest = try JSONDecoder().decode(T3BotManifest.self, from: saved)
    let avatar = try #require(manifest.avatar)
    #expect(avatar.shape == .cloud && avatar.color == "#123456" && avatar.custom)
    #expect(avatar.imageKind == "photo" && avatar.bottoPreviewSHA256 == hash && avatar.expression == "curious")
    #expect(try JSONDecoder().decode(T3BotManifest.self, from: JSONEncoder().encode(manifest)) == manifest)

    let edited = BotAvatarChoice.edit(.init(shape: .drop)).applying(to: avatar)
    #expect(edited.bottoPreviewSHA256 == nil && edited.imageKind == "shape")
    #expect(edited.shape == .drop && edited.color == "#123456" && edited.expression == "curious")
}
