import Foundation
import Testing
@testable import BottoCore

@Suite struct T3PushObserverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = T3PushScope(environmentID: "local-environment", projectID: "botto-project")

    @Test func emitsLiveCompletionsAndActionableRequestsOnce() throws {
        var observer = T3PushObserver(scope: scope, since: now.addingTimeInterval(-10))
        let ended = ["id": "routine-run", "status": "completed", "completedAt": "2027-01-15T08:00:00Z"]
        let approval = ["id": "approve", "status": "pending", "kind": "command", "createdAt": "2027-01-15T08:00:00Z"]
        let question = ["id": "ask", "status": "pending", "kind": "user_input", "createdAt": "2027-01-15T08:00:00Z"]
        #expect(observer.receive(frame("run.updated", ended, space: "other"), spaceID: "space-42", title: "Trips", now: now).isEmpty)
        let complete = try #require(observer.receive(frame("run.updated", ended), spaceID: "space-42", title: "Trips", now: now).first)
        #expect(complete.kind == .reply)
        #expect(complete.spaceID == "space-42")
        #expect(complete.id == "routine-run")
        #expect(observer.receive(frame("run.updated", ended), spaceID: "space-42", title: "Trips", now: now).isEmpty)
        #expect(observer.receive(frame("runtime-request.updated", approval), spaceID: "space-42", title: "Trips", now: now).first?.kind == .approval)
        #expect(observer.receive(frame("runtime-request.updated", question), spaceID: "space-42", title: "Trips", now: now).first?.kind == .question)
        #expect(observer.receive(frame("runtime-request.updated", question.merging(["status": "resolved"]) { _, new in new }),
                                 spaceID: "space-42", title: "Trips", now: now).first?.cancelled == true)
    }

    @Test func ignoresHistoryFailedRunsAndUnavailableRequests() {
        var observer = T3PushObserver(scope: scope, since: now.addingTimeInterval(-600))
        let records: [(String, [String: String])] = [
            ("run.updated", ["id": "older", "status": "completed", "completedAt": "2027-01-15T07:40:00Z"]),
            ("run.updated", ["id": "failed", "status": "failed", "completedAt": "2027-01-15T08:00:00Z"]),
            ("runtime-request.updated", ["id": "internal", "kind": "auth_refresh", "status": "pending",
                                         "createdAt": "2027-01-15T08:00:00Z"]),
            ("runtime-request.updated", ["id": "expired", "kind": "command", "status": "pending",
                                         "createdAt": "2027-01-15T07:54:00Z"])
        ]
        for (type, payload) in records {
            #expect(observer.receive(frame(type, payload), spaceID: "space-42", title: "Trips", now: now).isEmpty)
        }
    }

    @Test func reconcilesFreshSnapshotAndRejectsOutOfOrderPendingReplay() throws {
        var observer = T3PushObserver(scope: scope, since: now.addingTimeInterval(-60))
        let request = ["id": "question", "status": "resolved", "kind": "user_input", "createdAt": "2027-01-15T08:00:00Z"]
        let snapshot: HermesJSON = .object(["kind": .string("snapshot"), "projection": .object([
            "thread": .object(["id": .string("space-42")]),
            "runtimeRequests": .array([.object(request.mapValues(HermesJSON.string))])
        ])])
        let cancellation = try #require(observer.receive(snapshot, spaceID: "space-42", title: "Trips", now: now).first)
        #expect(cancellation.cancelled)
        let pending = request.merging(["status": "pending"]) { _, new in new }
        #expect(observer.receive(frame("runtime-request.updated", pending), spaceID: "space-42", title: "Trips", now: now).isEmpty)
    }

    @Test func childThreadsOnlyNotifyForActionableRequests() {
        var observer = T3PushObserver(scope: scope, since: now.addingTimeInterval(-10))
        let run = frame("run.updated", ["id": "child-run", "status": "completed", "completedAt": "2027-01-15T08:00:00Z"])
        let approval = frame("runtime-request.updated", ["id": "approval", "kind": "command", "status": "pending",
                                                           "createdAt": "2027-01-15T08:00:00Z"])
        #expect(observer.receive(run, spaceID: "space-42", title: "Child", includesCompletion: false, now: now).isEmpty)
        #expect(observer.receive(approval, spaceID: "space-42", title: "Child", includesCompletion: false, now: now).first?.kind == .approval)
    }

    private func frame(_ type: String, _ fields: [String: String], space: String = "space-42") -> HermesJSON {
        .object(["kind": .string("event"), "event": .object([
            "type": .string(type), "threadId": .string(space), "payload": .object(fields.mapValues(HermesJSON.string))
        ])])
    }
}
