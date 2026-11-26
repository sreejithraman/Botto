import Foundation
import Testing
@testable import BottoCore

@Suite struct T3PushObserverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = T3PushScope(environmentID: "local-environment", projectID: "botto-project")
    private let timestamp = "2027-01-15T08:00:00Z"

    @Test func emitsSettledSpaceWorkOnce() throws {
        var observer = T3PushObserver(scope: scope, since: now.addingTimeInterval(-10))
        let shell: JSONValue = .object([
            "id": .string("space-42"), "title": .string("Trips"), "status": .string("completed"),
            "latestRunId": .string("routine-run"), "latestRunCompletedAt": .string(timestamp)
        ])
        var busy = shell
        busy["pendingBackgroundTasks"] = .array([.object(["kind": .string("subagent")])])
        #expect(observer.shellActivity(in: busy, now: now) == nil)
        busy["pendingBackgroundTasks"] = .array([.object(["kind": .string("monitor")])])
        busy["latestRunBackgroundWake"] = .bool(true)
        #expect(observer.shellActivity(in: busy, now: now) == nil)
        var stopped = shell
        stopped["latestRunStopRequested"] = .bool(true)
        #expect(observer.shellActivity(in: stopped, now: now) == nil)

        let emitted = observer.shellActivity(in: shell, now: now)
        let complete = try #require(emitted)
        #expect(complete.kind == .reply)
        #expect(complete.spaceID == "space-42")
        #expect(complete.id == "routine-run")
        #expect(observer.shellActivity(in: shell, now: now) == nil)
    }

    @Test func emitsActionableRequestsOnceAndCancelsThem() {
        var observer = T3PushObserver(scope: scope, since: now.addingTimeInterval(-10))
        let shell: JSONValue = .object(["id": .string("space-42"), "title": .string("Trips")])
        let approval = ["id": "approve", "status": "pending", "kind": "command", "createdAt": timestamp]
        let question = ["id": "ask", "status": "pending", "kind": "user_input", "createdAt": timestamp]
        #expect(observer.requests(frame(approval, space: "other"), in: shell, now: now).isEmpty)
        #expect(observer.requests(frame(approval), in: shell, now: now).first?.kind == .approval)
        #expect(observer.requests(frame(approval), in: shell, now: now).isEmpty)
        #expect(observer.requests(frame(question), in: shell, now: now).first?.kind == .question)
        #expect(observer.requests(frame(question.merging(["status": "resolved"]) { _, new in new }),
                                  in: shell, now: now).first?.cancelled == true)
    }

    @Test func ignoresHistoryAndInternalRequests() {
        var observer = T3PushObserver(scope: scope, since: now.addingTimeInterval(-600))
        let shell: JSONValue = .object(["id": .string("space-42")])
        let records = [
            ["id": "internal", "kind": "auth_refresh", "status": "pending", "createdAt": timestamp],
            ["id": "expired", "kind": "command", "status": "pending", "createdAt": "2027-01-15T07:54:00Z"]
        ]
        for payload in records { #expect(observer.requests(frame(payload), in: shell, now: now).isEmpty) }
        var old = shell
        old["status"] = .string("completed")
        old["latestRunId"] = .string("old")
        old["latestRunCompletedAt"] = .string("2027-01-15T07:40:00Z")
        #expect(observer.shellActivity(in: old, now: now) == nil)
    }

    @Test func reconcilesFreshSnapshotAndRejectsOutOfOrderPendingReplay() throws {
        var observer = T3PushObserver(scope: scope, since: now.addingTimeInterval(-60))
        let shell: JSONValue = .object(["id": .string("space-42")])
        let request = ["id": "question", "status": "resolved", "kind": "user_input", "createdAt": timestamp]
        let snapshot: JSONValue = .object(["kind": .string("snapshot"), "projection": .object([
            "thread": .object(["id": .string("space-42")]),
            "runtimeRequests": .array([.object(request.mapValues(JSONValue.string))])
        ])])
        let cancellation = try #require(observer.requests(snapshot, in: shell, now: now).first)
        #expect(cancellation.cancelled)
        let pending = request.merging(["status": "pending"]) { _, new in new }
        #expect(observer.requests(frame(pending), in: shell, now: now).isEmpty)
    }

    @Test func childThreadsOnlyNotifyForSupportedApprovals() {
        var observer = T3PushObserver(scope: scope, since: now.addingTimeInterval(-10))
        var child: JSONValue = .object([
            "id": .string("space-42"), "status": .string("completed"), "latestRunId": .string("child-run"),
            "latestRunCompletedAt": .string(timestamp),
            "lineage": .object(["relationshipToParent": .string("subagent")])
        ])
        #expect(observer.shellActivity(in: child, now: now) == nil)
        child["activityRunStatus"] = .string("waiting")
        child["pendingRuntimeRequest"] = .object(["id": .string("input"), "kind": .string("user_input"), "createdAt": .string(timestamp)])
        #expect(observer.shellActivity(in: child, now: now) == nil)
        child["pendingRuntimeRequest"]["userOnly"] = .bool(true)
        #expect(observer.shellActivity(in: child, now: now) == nil)
        child["pendingRuntimeRequest"]["kind"] = .string("command")
        #expect(observer.shellActivity(in: child, now: now)?.kind == .approval)
    }

    private func frame(_ fields: [String: String], space: String = "space-42") -> JSONValue {
        .object(["kind": .string("event"), "event": .object([
            "type": .string("runtime-request.updated"), "threadId": .string(space), "payload": .object(fields.mapValues(JSONValue.string))
        ])])
    }
}
