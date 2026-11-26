import Foundation
import Testing
@testable import BottoCore

@Test func completePageAndSourceIDsDoNotImplyProducerIdentityProof() throws {
    let source = SessionIdentity(profile: try ExactID("bot"), root: try ExactID("chat"), stored: try ExactID("chat"), aliases: [])
    let message = ChatMessage(id: "chat:row:1", role: .assistant, text: "Visible candidate")
    let ids: Set<Data> = [Data(message.id.utf8)]
    let weak = ConversationHistoryPage(messages: [message], nextOffset: nil, isComplete: true, sourceIDs: ids)
    #expect(weak.isComplete && weak.unavailableMessageIDs.isEmpty)
    #expect(weak.sourceIDs == ids)
    #expect(weak.identityRead == nil)
    let checked = ConversationHistoryPage(messages: [message], nextOffset: nil, isComplete: true, sourceIDs: ids,
        identityRead: .init(identity: source, messageIDs: ids))
    #expect(checked.identityRead?.matches(source) == true)
    #expect(checked.identityRead?.messageIDs == ids)
}

@Test func historyIdentityReadMatchesOnlyItsExactProfileRootAndStoredTip() throws {
    let profile = try ExactID("profile"), root = try ExactID("root"), stored = try ExactID("stored"), other = try ExactID("other")
    let identity = SessionIdentity(profile: profile, root: root, stored: stored, aliases: [])
    let proof = ConversationIdentityRead(identity: identity, messageIDs: [])
    #expect(proof.matches(.init(profile: profile, root: root, stored: stored, aliases: [try ExactID("another-alias")])))
    #expect(!proof.matches(.init(profile: other, root: root, stored: stored, aliases: [])))
    #expect(!proof.matches(.init(profile: profile, root: other, stored: stored, aliases: [])))
    #expect(!proof.matches(.init(profile: profile, root: root, stored: other, aliases: [])))
}
