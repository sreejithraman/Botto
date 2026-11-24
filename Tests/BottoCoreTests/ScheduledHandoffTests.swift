import Foundation
import Testing
@testable import BottoCore

@Test func legacyPartialControlProjectionCannotHideRealText() throws {
    let data = Data(#"{"id":"old","role":"assistant","text":"No","attachments":[],"isSilent":true}"#.utf8)
    let message = try JSONDecoder().decode(ChatMessage.self, from: data)
    #expect(message.isVisible && message.requiresAttention)
}
