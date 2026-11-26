import Foundation
import Testing
@testable import BottoCore

@Test func historyIdentityReadMatchesOnlyItsExactProfileRootAndStoredTip() throws {
    let profile = try ExactID("profile"), root = try ExactID("root"), stored = try ExactID("stored"), other = try ExactID("other")
    let identity = SessionIdentity(profile: profile, root: root, stored: stored, aliases: [])
    let proof = ConversationIdentityRead(identity: identity, messageIDs: [])
    #expect(proof.matches(.init(profile: profile, root: root, stored: stored, aliases: [try ExactID("another-alias")])))
    #expect(!proof.matches(.init(profile: other, root: root, stored: stored, aliases: [])))
    #expect(!proof.matches(.init(profile: profile, root: other, stored: stored, aliases: [])))
    #expect(!proof.matches(.init(profile: profile, root: root, stored: other, aliases: [])))
}
