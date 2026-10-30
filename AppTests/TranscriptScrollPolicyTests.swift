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

    private func geometry(y: CGFloat, height: CGFloat = 1508, viewport: CGFloat = 364,
                          top: CGFloat = 116, bottom: CGFloat = 0) -> ScrollGeometry {
        ScrollGeometry(contentOffset: .init(x: 0, y: y), contentSize: .init(width: 402, height: height),
                       contentInsets: .init(top: top, leading: 0, bottom: bottom, trailing: 0),
                       containerSize: .init(width: 402, height: viewport))
    }

    @Test func explicitLatestCanReplaceDecelerationWithoutBecomingAUserScroll() {
        var policy = TranscriptScrollPolicy()
        let away = geometry(y: 363)
        policy.phaseChanged(from: .idle, to: .interacting, geometry: away)
        policy.phaseChanged(from: .interacting, to: .decelerating, geometry: away)
        let followsWhileReading = policy.snapshotChanged()
        #expect(!followsWhileReading)
        #expect(policy.showsLatest)
        policy.requestLatest()
        policy.phaseChanged(from: .decelerating, to: .animating, geometry: away)
        policy.phaseChanged(from: .animating, to: .idle, geometry: geometry(y: 1028))
        let followsNewReply = policy.snapshotChanged()
        #expect(followsNewReply)
        #expect(!policy.showsLatest)
    }

    @Test func immediateLatestIsNotUndoneByTheInterruptedUserScrollEnding() {
        var policy = TranscriptScrollPolicy()
        let away = geometry(y: 363)
        policy.phaseChanged(from: .idle, to: .interacting, geometry: away)
        policy.phaseChanged(from: .interacting, to: .decelerating, geometry: away)
        policy.requestLatest()
        // Reduced motion can end deceleration without an animating phase. The
        // interrupted scroll's geometry must not undo the explicit Latest request.
        policy.phaseChanged(from: .decelerating, to: .idle, geometry: away)
        let followsReply = policy.snapshotChanged()
        #expect(followsReply)
        #expect(!policy.showsLatest)
    }

    @Test func returningToTheCapturedBottomResumesFollowingAndClearsLatest() {
        var policy = TranscriptScrollPolicy()
        let away = geometry(y: 363)
        let bottom = geometry(y: 1028)
        policy.phaseChanged(from: .idle, to: .interacting, geometry: away)
        policy.phaseChanged(from: .interacting, to: .idle, geometry: away)
        let followsWhileReading = policy.snapshotChanged()
        #expect(!followsWhileReading)
        #expect(policy.showsLatest)
        policy.phaseChanged(from: .idle, to: .interacting, geometry: away)
        // The phase boundary must decide without waiting for a geometry action.
        policy.phaseChanged(from: .interacting, to: .decelerating, geometry: bottom)
        policy.phaseChanged(from: .decelerating, to: .idle, geometry: bottom)
        let followsNewReply = policy.snapshotChanged()
        #expect(followsNewReply)
        #expect(!policy.showsLatest)
    }

    @Test func readingHistorySurvivesMissingGeometryActionsAndIdleLazyHeightGrowth() {
        var policy = TranscriptScrollPolicy()
        let bottom = geometry(y: 1028)
        let away = geometry(y: 363)
        policy.phaseChanged(from: .idle, to: .interacting, geometry: bottom)
        // In the captured failure, the Equatable geometry action never ran during the swipe.
        policy.phaseChanged(from: .interacting, to: .decelerating, geometry: away)
        policy.phaseChanged(from: .decelerating, to: .idle, geometry: away)
        let followsHeightChange = policy.geometryChanged(from: .init(away), to: .init(geometry(y: 363, height: 1523)))
        let followsSnapshot = policy.snapshotChanged()
        #expect(!followsHeightChange)
        #expect(!followsSnapshot)
        #expect(policy.showsLatest)
    }

    @Test func bottomAndThresholdUseTheCurrentInsetsAndViewport() {
        // Captured keyboard and navigation layouts, plus bottom-inset and short-content controls.
        for (position, shouldFollow) in [
            (geometry(y: 1028), true),
            (geometry(y: 938), true),
            (geometry(y: 937), false),
            (geometry(y: 363), false),
            (geometry(y: 734, viewport: 658), true),
            (geometry(y: 700, viewport: 808, top: 0), true),
            (geometry(y: 1144, top: 0), true),
            (geometry(y: 1056, bottom: 28), true),
            (geometry(y: -116, height: 0, bottom: 28), true),
            (geometry(y: -116, height: 100), true)
        ] {
            var policy = TranscriptScrollPolicy()
            policy.phaseChanged(from: .idle, to: .interacting, geometry: position)
            policy.phaseChanged(from: .interacting, to: .idle, geometry: position)
            let followsReply = policy.snapshotChanged()
            #expect(followsReply == shouldFollow, "Position: \(position)")
            #expect(policy.showsLatest == !shouldFollow)
        }
    }

    @Test func geometryDuringDecelerationUpdatesReaderIntentBeforeIdle() {
        var policy = TranscriptScrollPolicy()
        let bottom = geometry(y: 1028)
        let away = geometry(y: 363)
        policy.phaseChanged(from: .idle, to: .interacting, geometry: bottom)
        policy.phaseChanged(from: .interacting, to: .decelerating, geometry: bottom)
        let followsDrag = policy.geometryChanged(from: .init(bottom), to: .init(away))
        let followsReply = policy.snapshotChanged()
        #expect(!followsDrag)
        #expect(!followsReply)
        #expect(policy.showsLatest)
        policy.phaseChanged(from: .decelerating, to: .idle, geometry: away)
        #expect(!policy.shouldFollowLatest)
    }

    @Test func anAlreadyAwayGeometryDoesNotNeedToCrossTheNearBottomThreshold() {
        var policy = TranscriptScrollPolicy()
        let away = geometry(y: 363)
        let followsUnchangedGeometry = policy.geometryChanged(from: .init(away), to: .init(away))
        #expect(!followsUnchangedGeometry)
        // The geometry was already away before input began; no Boolean transition follows.
        policy.phaseChanged(from: .idle, to: .interacting, geometry: away)
        policy.phaseChanged(from: .interacting, to: .idle, geometry: away)
        let followsGrowth = policy.geometryChanged(from: .init(away), to: .init(geometry(y: 363, height: 1523)))
        let followsReply = policy.snapshotChanged()
        #expect(!followsGrowth)
        #expect(!followsReply)
        #expect(policy.showsLatest)
    }

    @Test func readingHistoryIgnoresContentAndViewportChangesUntilLatest() {
        var policy = TranscriptScrollPolicy()
        let away = geometry(y: 363)
        policy.phaseChanged(from: .idle, to: .interacting, geometry: away)
        policy.phaseChanged(from: .interacting, to: .idle, geometry: away)
        var previous = TranscriptScrollPolicy.Metrics(away)
        for current in [geometry(y: 363, height: 1800),
                        geometry(y: 363, height: 1800, viewport: 658, top: 0),
                        geometry(y: 363, height: 1800, viewport: 364),
                        geometry(y: 363, height: 1800, viewport: 364, bottom: 28)] {
            let metrics = TranscriptScrollPolicy.Metrics(current)
            let followsGeometry = policy.geometryChanged(from: previous, to: metrics)
            let followsReply = policy.snapshotChanged()
            #expect(!followsGeometry)
            #expect(!followsReply)
            #expect(!policy.shouldFollowLatest)
            #expect(policy.showsLatest)
            previous = metrics
        }
        policy.requestLatest()
        #expect(policy.shouldFollowLatest)
        #expect(!policy.showsLatest)
        let followsNextReply = policy.snapshotChanged()
        #expect(followsNextReply)
    }

    @Test func newChatFollowsGrowthAndViewportChangesWithoutTreatingAnimationAsInput() {
        var policy = TranscriptScrollPolicy()
        let initialReply = policy.snapshotChanged()
        let followsGrowth = policy.geometryChanged(from: .init(geometry(y: -116, height: 0)),
                                                   to: .init(geometry(y: 1028)))
        #expect(initialReply)
        #expect(followsGrowth)
        policy.phaseChanged(from: .idle, to: .animating, geometry: geometry(y: 363))
        policy.phaseChanged(from: .animating, to: .idle, geometry: geometry(y: 1028))
        // Touch tracking alone is not a drag, and a viewport resize is not user input.
        policy.phaseChanged(from: .idle, to: .tracking, geometry: geometry(y: 363, viewport: 658))
        policy.phaseChanged(from: .tracking, to: .idle, geometry: geometry(y: 363))
        #expect(policy.shouldFollowLatest)
        #expect(!policy.showsLatest)
    }

    @Test func programmaticPhasesDoNotResumeFollowingWhileReadingHistory() {
        var policy = TranscriptScrollPolicy()
        policy.phaseChanged(from: .idle, to: .interacting, geometry: geometry(y: 363))
        policy.phaseChanged(from: .interacting, to: .idle, geometry: geometry(y: 363))
        // Programmatic geometry and idle callbacks must not impersonate a user returning to bottom.
        policy.phaseChanged(from: .idle, to: .animating, geometry: geometry(y: 1028))
        policy.phaseChanged(from: .animating, to: .idle, geometry: geometry(y: 1028))
        policy.phaseChanged(from: .idle, to: .idle, geometry: geometry(y: 1028))
        let followsReply = policy.snapshotChanged()
        #expect(!followsReply)
        #expect(policy.showsLatest)
    }
}
