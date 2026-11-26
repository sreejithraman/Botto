import SwiftUI
import Testing
import BottoCore
@testable import Botto

struct TranscriptScrollPolicyTests {
    @Test func indexedMessageValidationKeepsExactIdentityAndRawDuplicateQuarantine() {
        let composed = ChatMessage(id: "é", role: .assistant, text: "Original reply")
        let decomposed = ChatMessage(id: "e\u{301}", role: .assistant, text: "Other reply")
        let hidden = ChatMessage(id: "hidden", role: .assistant, text: "Hidden", isSilent: true)
        let snapshot = Conversation(id: "chat", storedID: "stored", profileID: "profile",
                                    messages: [composed, decomposed, hidden])
        let index = TranscriptMessageIndex(snapshot)
        #expect(index.matches(composed) && index.matches(decomposed))
        #expect(!index.matches(hidden) && !index.containsVisible(Data(hidden.id.utf8)))
        var edited = composed; edited.text = "Changed reply"
        #expect(!index.matches(edited))
        var duplicate = snapshot
        var invisibleDuplicate = composed; invisibleDuplicate.isSilent = true
        duplicate.messages.append(invisibleDuplicate)
        let quarantined = TranscriptMessageIndex(duplicate)
        #expect(!quarantined.matches(composed) && !quarantined.containsVisible(Data(composed.id.utf8)))
        #expect(quarantined.matches(decomposed))
        #expect(!TranscriptMessageIndex(nil).matches(composed))
        for snapshot in [snapshot, duplicate] {
            let index = TranscriptMessageIndex(snapshot)
            for message in snapshot.messages + [edited] {
                #expect(index.matches(message) == TranscriptContentRevision.uniqueMessage(message, in: snapshot))
            }
        }
    }

    @Test func canonicalOnlyRevisionReplacesSnapshotsWithoutClaimingAttention() {
        let projected = ChatMessage(id: "stored:row:3", role: .user, text: "Can you check the parser?",
                                    canonicalText: "[CONTEXT COMPACTION] summary")
        let revisions: [String?] = [nil, "", "[CONTEXT COMPACTION] other summary"]
        let snapshot = Conversation(id: "chat", storedID: "stored", profileID: "profile", messages: [projected])
        for canonicalText in revisions {
            var revised = projected; revised.canonicalText = canonicalText
            var incoming = snapshot; incoming.messages = [revised]
            #expect(!TranscriptContentRevision.sameMessage(projected, revised))
            #expect(!TranscriptContentRevision.sameSnapshotContent(snapshot, incoming))
            #expect(!TranscriptMessageIndex(incoming).matches(projected))
            #expect(!TranscriptContentRevision.uniqueMessage(projected, in: incoming))
            #expect(NativeTranscriptRowValue.workDetails([projected]) != .workDetails([revised]))

            #expect(!TranscriptScrollPolicy.attentionChanged(from: snapshot, to: incoming))
            var following = TranscriptScrollPolicy()
            let follows = following.snapshotChanged(from: snapshot, to: incoming)
            #expect(!follows)
            var reading = TranscriptScrollPolicy()
            reading.readerChanged(isUserScrolling: false, isNearBottom: false)
            let moved = reading.snapshotChanged(from: snapshot, to: incoming)
            #expect(!moved && !reading.showsLatest)
        }
        // Swift String equality would treat these as one revision.
        var composed = projected, decomposed = projected
        composed.canonicalText = "caf\u{E9}"; decomposed.canonicalText = "cafe\u{301}"
        #expect(!TranscriptContentRevision.sameMessage(composed, decomposed))
        #expect(TranscriptContentRevision.sameMessage(composed, composed))

        var edited = projected; edited.text = "Different words"
        var visible = snapshot; visible.messages = [edited]
        #expect(TranscriptScrollPolicy.attentionChanged(from: snapshot, to: visible))
    }

    @Test func rawQuietSnapshotsDoNotBorrowAttentionFromAnUnchangedRequestButReclassificationDoes() {
        let payload = "[Cronjob \"Daily check\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\nPayload"
        let ordinary = ChatMessage(id: "ordinary", role: .assistant, text: "Existing reply")
        let request = PendingRequest(id: "request", kind: .question, title: "Unchanged request")
        var snapshot = Conversation(id: "chat", storedID: "stored", profileID: "profile", messages: [ordinary], pendingRequests: [request])
        var policy = TranscriptScrollPolicy()
        policy.readerChanged(isUserScrolling: false, isNearBottom: false)
        var incoming = snapshot
        incoming.messages.append(.init(id: "scheduled", role: .user, text: payload, displayKind: "internal_notification"))
        incoming.messages.append(.init(id: "silent", role: .assistant, text: "Hidden", isSilent: true))
        let attentionChange0 = policy.snapshotChanged(from: snapshot, to: incoming)
        #expect(!attentionChange0 && !policy.showsLatest)
        snapshot = incoming; incoming.isWorking = true
        let attentionChange1 = policy.snapshotChanged(from: snapshot, to: incoming)
        #expect(!attentionChange1 && !policy.showsLatest)
        snapshot = incoming; incoming.messages[1].timestamp = Date(timeIntervalSince1970: 100)
        let attentionChange2 = policy.snapshotChanged(from: snapshot, to: incoming)
        #expect(!attentionChange2 && !policy.showsLatest)
        snapshot = incoming; incoming.messages[1].displayKind = nil
        let attentionChange3 = policy.snapshotChanged(from: snapshot, to: incoming)
        #expect(!attentionChange3 && policy.showsLatest)
        policy.requestLatest(); snapshot = incoming; incoming.messages[1].displayKind = "internal_notification"
        let attentionChange4 = policy.snapshotChanged(from: snapshot, to: incoming)
        #expect(attentionChange4 && !policy.showsLatest)
        policy.readerChanged(isUserScrolling: false, isNearBottom: false)
        snapshot = incoming; incoming.pendingRequests[0].title = "Changed request"
        let attentionChange5 = policy.snapshotChanged(from: snapshot, to: incoming)
        #expect(!attentionChange5 && policy.showsLatest)
    }

    @Test func attentionEditsUseExactBytesAndSemanticMetadata() {
        var first = Conversation(id: "chat", storedID: "stored", profileID: "profile",
            messages: [.init(id: "same", role: .assistant, text: "é")])
        var next = first; next.messages[0].text = "e\u{301}"
        var policy = TranscriptScrollPolicy()
        let attentionChange6 = policy.snapshotChanged(from: first, to: next)
        #expect(attentionChange6)
        first = next; next.messages[0].timestamp = Date(timeIntervalSince1970: 100)
        let attentionChange7 = policy.snapshotChanged(from: first, to: next)
        #expect(attentionChange7)
        first = next; next.messages[0].displayKind = "é"
        let attentionChange8 = policy.snapshotChanged(from: first, to: next)
        #expect(attentionChange8)
        first = next; next.messages[0].displayKind = "e\u{301}"
        let attentionChange9 = policy.snapshotChanged(from: first, to: next)
        #expect(attentionChange9)
        first = next; next.messages[0].isSilent = true
        let attentionChange10 = policy.snapshotChanged(from: first, to: next)
        #expect(attentionChange10)
    }
}
