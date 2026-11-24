import Foundation
import Testing
@testable import BottoCore

@Test func conversationDecodesEarlierCacheWithoutLosingTranscript() throws {
    let data = Data(#"{"id":"runtime","storedID":"stored","profileID":"inbox","messages":[{"id":"row:1","role":"user","text":"Keep this","attachments":[]}],"pendingRequests":[],"isWorking":true,"lastSequence":42}"#.utf8)
    let conversation = try JSONDecoder().decode(Conversation.self, from: data)
    #expect(conversation.messages.map(\.text) == ["Keep this"])
    #expect(conversation.isWorking && conversation.lastSequence == 42)
    #expect(conversation.queuedMessages.isEmpty)
    var updated = conversation
    updated.queuedMessages = [QueuedMessage(id: "admission", text: "Later", canEdit: true, submissionID: "input")]
    #expect(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(updated)) == updated)
}

@Test func legacyChatHistoryDecodesWithoutAnEarlierHistoryQualifier() throws {
    let snapshot = Conversation(id: "runtime", storedID: "stored", profileID: "bot",
        messages: [.init(id: "stored:row:1", role: .assistant, text: "Saved reply")], hasEarlierMessages: true)
    let encoded = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(Conversation.self, from: encoded).hasEarlierMessages)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "hasEarlierMessages")
    let restored = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(!restored.hasEarlierMessages)
    #expect(restored.messages.last?.text == "Saved reply")
}
