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
