import SwiftUI
import Testing
import BottoCore
@testable import Botto

struct TranscriptScrollPolicyTests {
    @Test func indexedMessageValidationKeepsExactIdentityAndRawDuplicateQuarantine() {
        let composed = ChatMessage(id: "é", role: .assistant, text: "Original reply")
        let decomposed = ChatMessage(id: "e\u{301}", role: .assistant, text: "Other reply")
        let snapshot = Conversation(id: "chat", storedID: "stored", profileID: "profile",
                                    messages: [composed, decomposed])
        let index = TranscriptMessageIndex(snapshot)
        #expect(index.matches(composed) && index.matches(decomposed))
        #expect(index.contains(Data(composed.id.utf8)) && !index.contains(Data("missing".utf8)))
        var edited = composed; edited.text = "Changed reply"
        #expect(!index.matches(edited))
        var duplicate = snapshot
        duplicate.messages.append(edited)
        let quarantined = TranscriptMessageIndex(duplicate)
        #expect(!quarantined.matches(composed) && !quarantined.contains(Data(composed.id.utf8)))
        #expect(quarantined.matches(decomposed))
        #expect(!TranscriptMessageIndex(nil).matches(composed))
        for snapshot in [snapshot, duplicate] {
            let index = TranscriptMessageIndex(snapshot)
            for message in snapshot.messages + [edited] {
                #expect(index.matches(message) == TranscriptContentRevision.uniqueMessage(message, in: snapshot))
            }
        }
    }

    @Test func snapshotsDoNotBorrowAttentionFromAnUnchangedRequest() {
        let ordinary = ChatMessage(id: "ordinary", role: .assistant, text: "Existing reply")
        let request = PendingRequest(id: "request", kind: .question, title: "Unchanged request")
        var snapshot = Conversation(id: "chat", storedID: "stored", profileID: "profile", messages: [ordinary], pendingRequests: [request])
        var policy = TranscriptScrollPolicy()
        policy.readerChanged(isUserScrolling: false, isNearBottom: false)
        var incoming = snapshot; incoming.isWorking = true
        let workingOnly = policy.snapshotChanged(from: snapshot, to: incoming)
        #expect(!workingOnly && !policy.showsLatest)
        snapshot = incoming; incoming.messages[0].timestamp = Date(timeIntervalSince1970: 100)
        let revised = policy.snapshotChanged(from: snapshot, to: incoming)
        #expect(!revised && policy.showsLatest)
        policy.requestLatest()
        policy.readerChanged(isUserScrolling: false, isNearBottom: false)
        snapshot = incoming; incoming.pendingRequests[0].title = "Changed request"
        let changedRequest = policy.snapshotChanged(from: snapshot, to: incoming)
        #expect(!changedRequest && policy.showsLatest)
    }

    @Test func attentionEditsUseExactBytes() {
        var first = Conversation(id: "chat", storedID: "stored", profileID: "profile",
            messages: [.init(id: "same", role: .assistant, text: "é")])
        var next = first; next.messages[0].text = "e\u{301}"
        var policy = TranscriptScrollPolicy()
        let textChange = policy.snapshotChanged(from: first, to: next)
        #expect(textChange)
        first = next; next.messages[0].timestamp = Date(timeIntervalSince1970: 100)
        let timestampChange = policy.snapshotChanged(from: first, to: next)
        #expect(timestampChange)
    }
}
