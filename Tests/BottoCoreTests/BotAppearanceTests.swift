import Foundation
import Testing
@testable import BottoCore

@Test(arguments: [BotAvatarChoice.automatic, .shape(.hexagon), .face(BotFace(shape: .hexagon, color: "#ef4444"))])
func completeChoicesKeepUneditedExpressionWhenAppliedToAnExistingLook(choice: BotAvatarChoice) {
    let current = BotAppearance(shape: .cloud, color: "#123456", expression: "curious")
    #expect(choice.applying(to: current).expression == "curious")
    #expect(choice.appearance.expression == nil)
}
