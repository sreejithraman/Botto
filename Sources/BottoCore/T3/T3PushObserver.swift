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

/// Only consumes detail streams for Spaces in the Botto project. A provider turn can end
/// while its T3 run is still working, so the run's terminal state owns the completion.
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

    mutating func receive(_ item: HermesJSON, spaceID: String, title: String, includesCompletion: Bool = true,
                          now: Date = .now) -> [T3PushActivity] {
        let records: [(String, HermesJSON)]
        switch item["kind"].text {
        case "snapshot":
            let projection = item["projection"]
            guard projection["thread"]["id"].text.map({ $0.utf8.elementsEqual(spaceID.utf8) }) == true else { return [] }
            records = (projection["runs"].list ?? []).map { ("run.updated", $0) }
                + (projection["runtimeRequests"].list ?? []).map { ("runtime-request.updated", $0) }
        case "event":
            let event = item["event"]
            guard event["threadId"].text.map({ $0.utf8.elementsEqual(spaceID.utf8) }) == true,
                  let type = event["type"].text else { return [] }
            records = [(type, event["payload"])]
        default:
            return []
        }
        let nowSeconds = Int(now.timeIntervalSince1970)
        if seen.count > 256 { seen = seen.filter { $0.value > nowSeconds } }
        return records.compactMap { type, record in
            let kind: PushEventKind
            let date: Date?
            let cancelled: Bool
            switch type {
            case "run.updated":
                guard includesCompletion, record["status"].text == "completed" else { return nil }
                kind = .reply
                date = T3ProjectionMapper.date(record["completedAt"])
                cancelled = false
            case "runtime-request.updated":
                guard let requestKind = record["kind"].text, let status = record["status"].text else { return nil }
                if T3ProjectionMapper.approvalKinds.contains(requestKind) { kind = .approval }
                else if requestKind == "user_input" { kind = .question }
                else { return nil }
                switch status {
                case "pending":
                    guard record["responseCapability"]["type"].text != "not_resumable" else { return nil }
                    cancelled = false
                case "resolved", "expired", "cancelled": cancelled = true
                default: return nil
                }
                date = T3ProjectionMapper.date(record["createdAt"])
            default:
                return nil
            }
            // A still-current cancellation can retire an alert queued before the Mac reconnected.
            guard let id = record["id"].nonempty, let date, cancelled || date >= since,
                  date <= now.addingTimeInterval(30) else { return nil }
            let createdAt = min(nowSeconds, Int(date.timeIntervalSince1970))
            let expiresAt = createdAt + (kind == .reply ? 3_600 : 300)
            guard expiresAt > nowSeconds else { return nil }
            let key = Key(space: Data(spaceID.utf8), id: Data(id.utf8), kind: kind, cancelled: cancelled)
            let cancellation = Key(space: key.space, id: key.id, kind: kind, cancelled: true)
            guard seen[key] == nil, cancelled || seen[cancellation] == nil else { return nil }
            seen[key] = expiresAt
            return T3PushActivity(scope: scope, spaceID: spaceID, title: title, id: id, kind: kind,
                                  createdAt: createdAt, expiresAt: expiresAt, cancelled: cancelled)
        }
    }
}
