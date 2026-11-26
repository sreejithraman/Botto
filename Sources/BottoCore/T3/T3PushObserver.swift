import Foundation

public struct T3PushScope: Codable, Equatable, Sendable {
    public let environmentID: String
    public let projectID: String

    public init(environmentID: String, projectID: String) {
        self.environmentID = environmentID
        self.projectID = projectID
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.environmentID.utf8.elementsEqual(rhs.environmentID.utf8) &&
            lhs.projectID.utf8.elementsEqual(rhs.projectID.utf8)
    }

    public func destination(spaceID: String) -> PushDestination {
        PushDestination(profileID: projectID, rootID: spaceID, storedID: spaceID)
    }
}

public struct T3PushActivity: Sendable {
    public let scope: T3PushScope
    public let spaceID: String
    public let title: String
    public let id: String
    public let kind: PushEventKind
    public let createdAt: Int
    public let expiresAt: Int
    public let cancelled: Bool
}

/// A Space shell owns work completion. Detail streams identify individual pending requests.
struct T3PushObserver {
    let scope: T3PushScope
    let since: Date
    private var seen: [Key: Int] = [:]

    private struct Key: Hashable {
        let space: Data
        let id: Data
        let kind: PushEventKind
        let cancelled: Bool
    }

    init(scope: T3PushScope, since: Date) {
        self.scope = scope
        self.since = since
    }

    mutating func shellActivity(in shell: JSONValue, now: Date = .now) -> T3PushActivity? {
        guard !T3ProjectionMapper.isWorkflowStep(shell) else { return nil }
        if !Self.isListed(shell) { return childRequest(in: shell, now: now) }
        guard shell["settledOverride"].text != "settled",
              (shell["activityRunStatus"].text ?? shell["status"].text) == "completed",
              shell["latestRunStopRequested"].flag != true,
              shell["pendingRuntimeRequest"] == .null else { return nil }
        let holdsCompletion = (shell["pendingBackgroundTasks"].list ?? []).contains { work in
            let kind = work["kind"].text
            if work["awaited"].flag == true || kind == "subagent" || kind == "background_task" { return true }
            return kind == "monitor" && shell["latestRunBackgroundWake"].flag == true
                && work["taskId"].text?.hasPrefix("pull-request-watch:") != true
        }
        guard !holdsCompletion else { return nil }
        return activity(in: shell, id: shell["latestRunId"].nonempty, kind: .reply,
                        date: T3ProjectionMapper.date(shell["latestRunCompletedAt"]), cancelled: false, now: now)
    }

    mutating func requests(_ item: JSONValue, in shell: JSONValue, now: Date = .now) -> [T3PushActivity] {
        guard !T3ProjectionMapper.isWorkflowStep(shell), let spaceID = shell["id"].nonempty else { return [] }
        let listed = Self.isListed(shell)
        let records: [JSONValue]
        switch item["kind"].text {
        case "snapshot":
            let projection = item["projection"]
            guard projection["thread"]["id"].text?.utf8.elementsEqual(spaceID.utf8) == true else { return [] }
            records = projection["runtimeRequests"].list ?? []
        case "event":
            let event = item["event"]
            guard event["type"].text == "runtime-request.updated",
                  event["threadId"].text?.utf8.elementsEqual(spaceID.utf8) == true else { return [] }
            records = [event["payload"]]
        default:
            return []
        }

        return records.compactMap { request in
            let kind: PushEventKind
            let cancelled: Bool
            guard let requestKind = request["kind"].text else { return nil }
            if T3ProjectionMapper.approvalKinds.contains(requestKind) { kind = .approval }
            else if requestKind == "user_input" { kind = .question }
            else { return nil }
            switch request["status"].text {
            case "pending":
                guard listed, request["responseCapability"]["type"].text != "not_resumable" else { return nil }
                cancelled = false
            case "resolved", "expired", "cancelled": cancelled = true
            default: return nil
            }
            return activity(in: shell, id: request["id"].nonempty, kind: kind, date: T3ProjectionMapper.date(request["createdAt"]),
                            cancelled: cancelled, now: now)
        }
    }

    private static func isListed(_ shell: JSONValue) -> Bool {
        let lineage = shell["lineage"]
        return lineage["relationshipToParent"].text != "subagent" &&
            lineage["sideChat"].flag != true
    }

    private mutating func childRequest(in shell: JSONValue, now: Date) -> T3PushActivity? {
        let request = shell["pendingRuntimeRequest"]
        guard shell["lineage"]["relationshipToParent"].text == "subagent", shell["creationSource"].text != "provider",
              shell["activityRunStatus"] != .null, let requestKind = request["kind"].text,
              T3ProjectionMapper.approvalKinds.contains(requestKind) else { return nil }
        return activity(in: shell, id: request["id"].nonempty, kind: .approval, date: T3ProjectionMapper.date(request["createdAt"]),
                        cancelled: false, now: now)
    }

    private mutating func activity(in shell: JSONValue, id: String?, kind: PushEventKind, date: Date?,
                                   cancelled: Bool, now: Date) -> T3PushActivity? {
        let nowSeconds = Int(now.timeIntervalSince1970)
        if seen.count > 256 { seen = seen.filter { $0.value > nowSeconds } }
        // A still-current cancellation can retire an alert queued before the Mac reconnected.
        guard let id, let spaceID = shell["id"].nonempty, let date, cancelled || date >= since,
              date <= now.addingTimeInterval(30) else { return nil }
        let createdAt = min(nowSeconds, Int(date.timeIntervalSince1970))
        let expiresAt = createdAt + (kind == .reply ? 3_600 : 300)
        guard expiresAt > nowSeconds else { return nil }
        let key = Key(space: Data(spaceID.utf8), id: Data(id.utf8), kind: kind, cancelled: cancelled)
        let cancellation = Key(space: key.space, id: key.id, kind: kind, cancelled: true)
        guard seen[key] == nil, cancelled || seen[cancellation] == nil else { return nil }
        seen[key] = expiresAt
        return T3PushActivity(scope: scope, spaceID: spaceID, title: shell["title"].nonempty ?? "Botto",
                              id: id, kind: kind, createdAt: createdAt, expiresAt: expiresAt, cancelled: cancelled)
    }
}
