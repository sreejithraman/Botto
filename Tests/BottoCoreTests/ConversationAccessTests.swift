import Foundation
import Testing
import BottoCore

@MainActor @Test func issuerRejectsForeignRevokedAndPreviouslySelectedGrants() throws {
    let owner = ConversationIssuer<String>(), foreign = ConversationIssuer<String>()
    let first = try owner.issue("A")
    #expect(try owner.resolve(first) == "A")
    #expect(throws: HermesServiceError.staleConversation) { try foreign.resolve(first) }
    _ = try owner.issue("B")
    let current = try owner.issue("A")
    #expect(throws: HermesServiceError.staleConversation) { try owner.resolve(first) }
    #expect(try owner.resolve(current) == "A")
    owner.retireAttachment()
    #expect(throws: HermesServiceError.staleConversation) { try owner.resolve(current) }
    #expect(try owner.resolve(owner.issue("A")) == "A")
    owner.close()
    #expect(throws: HermesServiceError.staleConversation) { try owner.issue("A") }
}

@Test func exactIDsPreserveUnicodeBytes() throws {
    #expect(try ExactID("é") != ExactID("e\u{301}"))
    #expect(throws: HermesServiceError.wrongConversation) { try ExactID("") }
}

@Test func decodedExactIDRejectsEmptyAndInvalidUTF8WithoutReplacement() throws {
    let decoder = JSONDecoder()
    for bytes in [Data(), Data([0xff, 0xfe])] {
        let wire = try JSONSerialization.data(withJSONObject: ["bytes": bytes.base64EncodedString()])
        #expect(throws: DecodingError.self) { try decoder.decode(ExactID.self, from: wire) }
    }
    let original = try ExactID("e\u{301}")
    #expect(try decoder.decode(ExactID.self, from: JSONEncoder().encode(original)) == original)
}
