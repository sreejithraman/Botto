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
