import CryptoKit
import Foundation

enum T3ProjectionMapper {
    static let toolTypes: Set<String> = ["command_execution", "file_change", "file_search", "web_search"]
    static let activeStatuses: Set<String> = ["preparing", "starting", "running", "waiting"]
    static let approvalKinds: Set<String> = ["command", "file-read", "file-change", "permission", "mcp-elicitation"]

    static func identity(profile: ExactID, threadID: String) throws -> SessionIdentity {
        let thread = try ExactID(threadID)
        return SessionIdentity(profile: profile, root: thread, stored: thread, aliases: [])
    }

    static func directory(_ shells: [HermesJSON], profile: ExactID, observedAt: Date, mainThreadID: String? = nil,
                          previews: [String: ConversationPreview] = [:])
        throws -> (directory: ConversationDirectory, channels: [T3ChannelSummary]) {
        let channels = shells.compactMap { shell -> T3ChannelSummary? in
            guard let id = shell["id"].nonempty else { return nil }
            let latest = shell["latestVisibleMessage"]
            let cachedPreview = previews[id]
            let previewText = latest["text"].nonempty ?? cachedPreview?.text ?? ""
            let latestMessageAt = date(latest["updatedAt"])
                ?? date(shell["latestRunCompletedAt"])
                ?? date(shell["latestUserMessageAt"])
            let updatedAt = date(shell["updatedAt"]) ?? latestMessageAt ?? cachedPreview?.timestamp
            let visitedAt = date(shell["lastVisitedAt"]) ?? .distantPast
            let model = shell["modelSelection"]
            return T3ChannelSummary(id: id, title: shell["title"].nonempty ?? "Untitled", isMain: id == mainThreadID,
                                    isPinned: shell["pinnedAt"] != .null, isArchived: shell["archivedAt"] != .null,
                                    isUnread: latestMessageAt.map { $0 > visitedAt } ?? false,
                                    status: status(shell), preview: previewText, updatedAt: updatedAt,
                                    providerInstanceID: model["instanceId"].nonempty ?? model["provider"].nonempty,
                                    model: model["model"].nonempty, hasMessages: latestMessageAt != nil)
        }.sorted(by: listOrder)
        let entries = try channels.map { channel -> SessionSummary in
            SessionSummary(identity: try identity(profile: profile, threadID: channel.id), title: channel.displayTitle,
                           isCanonical: false, persistence: .durable,
                           preview: channel.preview.isEmpty ? nil : channel.preview, updatedAt: channel.updatedAt)
        }
        let activity = Dictionary(uniqueKeysWithValues: zip(entries, channels).map {
            ($0.identity, ObservedActivity.known($1.status, observedAt))
        })
        return (ConversationDirectory(summaries: entries, activity: activity, isComplete: true), channels)
    }

    /// Live spaces first: the main space, then pinned ones, then the most recently active.
    static func listOrder(_ lhs: T3ChannelSummary, _ rhs: T3ChannelSummary) -> Bool {
        if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
        if lhs.isMain != rhs.isMain { return lhs.isMain }
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.updatedAt != rhs.updatedAt { return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast) }
        return lhs.id < rhs.id
    }

    /// The most recently active live space, main or not.
    static func mostRecent(_ channels: [T3ChannelSummary]) -> T3ChannelSummary? {
        channels.filter { !$0.isArchived }.max { lhs, rhs in
            let left = lhs.updatedAt ?? .distantPast, right = rhs.updatedAt ?? .distantPast
            return left == right ? lhs.id > rhs.id : left < right
        }
    }

    /// The seed T3 turns into a space's title on its first message: the first words, on one line.
    static func titleSeed(_ text: String, limit: Int = 50) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        guard words.count > limit else { return words }
        return String(words.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func status(_ shell: HermesJSON) -> BotStatus {
        let state = shell["activityRunStatus"].text ?? shell["status"].text ?? "idle"
        if shell["pendingRuntimeRequest"] != .null || state == "waiting" { return .waiting }
        return activeStatuses.contains(state) || state == "queued" ? .working : .idle
    }

    static func visibleItems(_ rows: [HermesJSON]) -> [HermesJSON] {
        rows.sorted { ($0["position"].integer ?? 0) < ($1["position"].integer ?? 0) }.map { $0["item"] }
    }

    static func messageTextLookup(_ messages: [HermesJSON]) -> [String: String] {
        var lookup: [String: String] = [:]
        for message in messages {
            if let id = message["id"].nonempty, let text = message["text"].text { lookup[id] = text }
        }
        return lookup
    }

    static func resolvedText(_ item: HermesJSON, messagesByID: [String: String] = [:]) -> String {
        if item["textOmitted"].flag == true, let id = item["messageId"].nonempty, let text = messagesByID[id] {
            return text
        }
        return item["text"].text ?? ""
    }

    static func chatMessage(_ item: HermesJSON, messagesByID: [String: String] = [:]) -> ChatMessage? {
        guard let itemID = item["id"].nonempty else { return nil }
        let role: ChatMessage.Role
        let text: String
        let tool: String?
        switch item["type"].text {
        case "user_message", "assistant_message":
            role = item["type"].text == "user_message" ? .user : .assistant
            text = resolvedText(item, messagesByID: messagesByID)
            tool = nil
        case "proposed_plan":
            role = .assistant
            text = item["markdown"].text ?? ""
            tool = nil
        case "command_execution":
            role = .tool
            text = [item["input"].nonempty, item["output"].nonempty].compactMap { $0 }.joined(separator: "\n")
            tool = item["title"].nonempty ?? "Command"
        case "file_change", "file_search", "web_search":
            role = .tool
            let patterns = item["patterns"].list?.compactMap(\.text).joined(separator: ", ")
            text = item["fileName"].text ?? item["pattern"].text ?? patterns ?? ""
            tool = item["title"].nonempty ?? item["type"].text?.replacingOccurrences(of: "_", with: " ")
        default:
            return nil
        }
        return ChatMessage(id: itemID, role: role, text: text,
                           timestamp: date(item["startedAt"]) ?? date(item["updatedAt"]), toolName: tool,
                           attachments: item["attachments"].list?.compactMap(attachment) ?? [])
    }

    static func attachment(_ value: HermesJSON) -> ChatAttachment? {
        guard let id = value["id"].nonempty, let name = value["name"].nonempty,
              let mimeType = value["mimeType"].nonempty else { return nil }
        return ChatAttachment(name: name, path: "t3-attachment:" + id, mimeType: mimeType,
                              byteCount: value["sizeBytes"].integer)
    }

    static func pending(_ request: HermesJSON, item: HermesJSON?) -> PendingRequest? {
        guard request["status"].text == "pending", let id = request["id"].nonempty else { return nil }
        if request["responseCapability"]["type"].text == "not_resumable" {
            return PendingRequest(id: id, kind: .unsupported, title: "Request unavailable",
                                  detail: request["responseCapability"]["reason"].text ?? "")
        }
        let kind = request["kind"].text ?? ""
        if approvalKinds.contains(kind) {
            let options = item?["options"].list?.compactMap { option -> RequestChoice? in
                guard let decision = option["decision"].nonempty, let label = option["label"].nonempty else { return nil }
                return RequestChoice(id: decision, label: label)
            } ?? []
            return PendingRequest(id: id, kind: .approval, title: item?["prompt"].nonempty ?? item?["title"].nonempty ?? "Approval requested",
                                  detail: item?["reason"].text ?? "",
                                  choices: options.isEmpty ? [RequestChoice(id: "accept", label: "Allow"),
                                                             RequestChoice(id: "decline", label: "Decline")] : options)
        }
        if kind == "user_input", let questions = item?["questions"].list, let question = questions.first {
            let choices = question["options"].list?.compactMap { option -> RequestChoice? in
                guard let label = option["label"].nonempty else { return nil }
                return RequestChoice(id: option["value"].nonempty ?? label, label: label)
            } ?? []
            if questions.count == 1, question["multiSelect"].flag != true {
                return PendingRequest(id: id, kind: .question, title: question["header"].nonempty ?? "Question",
                                      detail: question["question"].text ?? "", choices: choices)
            }
            let prompts = questions.enumerated().map { index, prompt in
                let options = prompt["options"].list?.compactMap { $0["label"].text } ?? []
                let promptText = prompt["question"].text ?? ""
                return "\(index + 1). " + promptText + (options.isEmpty ? "" : " (" + options.joined(separator: ", ") + ")")
            }
            return PendingRequest(id: id, kind: .question, title: question["header"].nonempty ?? "Questions",
                                  detail: (prompts + ["Enter one answer per line. Separate multiple choices with commas."]).joined(separator: "\n"))
        }
        return PendingRequest(id: id, kind: .unsupported, title: "Request requires T3 Code")
    }

    static func date(_ value: HermesJSON) -> Date? { T3PairingExchange.date(value.text) }

    static func stableUUID(_ id: String) -> UUID {
        let hash = Array(SHA256.hash(data: Data(id.utf8)).prefix(16))
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }
}

struct T3ThreadProjection {
    private struct TimelineRow {
        let item: HermesJSON
        let isLocal: Bool

        var ordinal: Int? { item["ordinal"].integer }
    }

    private var thread: HermesJSON
    private var runs: [HermesJSON]
    private var messages: [HermesJSON]
    private var runtimeRequests: [HermesJSON]
    private var turnItems: [HermesJSON]
    private var timeline: [TimelineRow]
    private let oldestSnapshotLocalOrdinal: Int?
    private(set) var sequence: Int
    private let hasMoreHistory: Bool
    private(set) var activity: ConversationActivity

    init(snapshot: HermesJSON, sequence: Int, hasMoreHistory: Bool, lineage: UUID) {
        thread = snapshot["thread"]
        runs = snapshot["runs"].list ?? []
        messages = snapshot["messages"].list ?? []
        runtimeRequests = snapshot["runtimeRequests"].list ?? []
        turnItems = snapshot["turnItems"].list ?? []
        if let rows = snapshot["visibleTurnItems"].list {
            timeline = rows.sorted { ($0["position"].integer ?? 0) < ($1["position"].integer ?? 0) }.map {
                TimelineRow(item: $0["item"], isLocal: ($0["visibility"].text ?? "local") == "local")
            }
        } else {
            timeline = turnItems.map { TimelineRow(item: $0, isLocal: true) }
        }
        oldestSnapshotLocalOrdinal = timeline.first { $0.isLocal && $0.ordinal != nil }?.ordinal
        self.sequence = sequence
        self.hasMoreHistory = hasMoreHistory
        activity = ConversationActivity(lineage: lineage, phase: nil, workStartedAt: nil, phaseStartedAt: nil)
        refreshActivity()
    }

    var threadID: String? { thread["id"].nonempty }

    private var activeRun: HermesJSON? {
        runs.filter { T3ProjectionMapper.activeStatuses.contains($0["status"].text ?? "") }
            .max { ($0["ordinal"].integer ?? 0) < ($1["ordinal"].integer ?? 0) }
    }

    var activeRunID: String? { activeRun?["id"].nonempty }

    var hasUserMessages: Bool {
        messages.contains { $0["role"].text == "user" }
            || turnItems.contains { $0["type"].text == "user_message" }
            || timeline.contains { $0.item["type"].text == "user_message" }
    }

    private var queuedRuns: [HermesJSON] {
        runs.filter { $0["status"].text == "queued" }.sorted {
            let first = $0["queuePosition"].integer ?? .max
            let second = $1["queuePosition"].integer ?? .max
            if first != second { return first < second }
            return ($0["ordinal"].integer ?? 0) < ($1["ordinal"].integer ?? 0)
        }
    }

    var pendingRequests: [PendingRequest] {
        let runtime = runtimeRequests.compactMap { T3ProjectionMapper.pending($0, item: requestItem($0["id"].text)) }
        let nativeCards = turnItems.compactMap { item -> PendingRequest? in
            guard let id = item["id"].nonempty else { return nil }
            switch item["type"].text {
            case "secret_request" where item["secretStatus"].text == "pending":
                return PendingRequest(id: id, kind: .unsupported, title: "Secret request requires T3 Code")
            case "link_request" where item["linkStatus"].text == "pending":
                return PendingRequest(id: id, kind: .unsupported, title: "Environment link requires T3 Code")
            default: return nil
            }
        }
        return runtime + nativeCards
    }

    func requestItem(_ id: String?) -> HermesJSON? {
        guard let id else { return nil }
        return turnItems.last { $0["requestId"].text == id } ?? timeline.last { $0.item["requestId"].text == id }?.item
    }

    func conversation(_ identity: SessionIdentity) -> Conversation {
        let removedRuns = Set(runs.filter { $0["status"].text == "rolled_back" }.compactMap { $0["id"].text })
        let undeliveredRuns = Set(runs.filter {
            $0["status"].text == "queued" || ($0["status"].text == "cancelled" && $0["startedAt"] == .null)
        }.compactMap { $0["id"].text })
        let queued = queuedRuns.compactMap { run -> QueuedMessage? in
            guard let runID = run["id"].nonempty, let messageID = run["userMessageId"].nonempty else { return nil }
            let text = messages.first { $0["id"].text == messageID }?["text"].text
                ?? turnItems.first { $0["messageId"].text == messageID }?["text"].text ?? ""
            return QueuedMessage(id: runID, text: text, canEdit: true, submissionID: messageID,
                                 isSteering: run["steerWhenReadyRunId"] != .null)
        }
        let messagesByID = T3ProjectionMapper.messageTextLookup(messages)
        let rows = timeline.filter { row in
            let item = row.item
            guard row.isLocal, let run = item["runId"].text else { return true }
            return !removedRuns.contains(run) && !(Self.isHeldInput(item) && undeliveredRuns.contains(run))
        }.compactMap { T3ProjectionMapper.chatMessage($0.item, messagesByID: messagesByID) }
        return Conversation(id: identity.root.text, storedID: identity.stored.text, profileID: identity.profile.text,
                            messages: rows, pendingRequests: pendingRequests, queuedMessages: queued,
                            isWorking: activeRunID != nil, lastSequence: sequence, hasEarlierMessages: hasMoreHistory)
    }

    mutating func apply(_ event: HermesJSON, sequence: Int, live: Bool) {
        guard sequence > self.sequence, event["threadId"].text == threadID else { return }
        self.sequence = sequence
        let payload = event["payload"]
        var reaction: TurnReaction?
        var signal: ConversationActivity.Signal?
        let eventTime = T3ProjectionMapper.date(event["occurredAt"])
        let eventID = event["id"].nonempty.map(T3ProjectionMapper.stableUUID)
        let previousActive = activeRunID
        switch event["type"].text {
        case "run.created", "run.updated":
            let oldRunStatus = runs.first { $0["id"] == payload["id"] }?["status"].text
            Self.upsert(payload, into: &runs)
            if oldRunStatus == "queued", payload["status"].text != "queued", let runID = payload["id"].text {
                // A snapshot can retain a held prompt in turnItems but exclude it from the timeline.
                for item in turnItems where item["runId"].text == runID && Self.isHeldInput(item) {
                    updateTimeline(item, wasLoaded: true)
                }
            }
            if live, let eventID, let oldRunStatus, T3ProjectionMapper.activeStatuses.contains(oldRunStatus) {
                if let completedAt = T3ProjectionMapper.date(payload["completedAt"]) ?? eventTime {
                    switch payload["status"].text {
                    case "completed": reaction = TurnReaction(id: eventID, kind: .succeeded, occurredAt: completedAt)
                    case "failed": reaction = TurnReaction(id: eventID, kind: .failed, occurredAt: completedAt)
                    case "interrupted", "cancelled": signal = .init(id: eventID, kind: .stopped)
                    default: break
                    }
                }
            }
        case "runtime-request.updated":
            let old = runtimeRequests.first { $0["id"] == payload["id"] }
            Self.upsert(payload, into: &runtimeRequests)
            if live, let eventID, payload["status"].text == "pending", old?["status"].text != "pending" {
                signal = .init(id: eventID, kind: .request)
            }
        case "message.updated":
            Self.upsert(payload, into: &messages)
        case "turn-item.updated":
            Self.upsert(payload, into: &turnItems)
            if let id = payload["id"].nonempty, T3ProjectionMapper.chatMessage(payload) != nil {
                let messagesByID = T3ProjectionMapper.messageTextLookup(messages)
                let old = timeline.last { $0.item["id"].text == id }?.item
                let oldText = old.map { T3ProjectionMapper.resolvedText($0, messagesByID: messagesByID) } ?? ""
                let newText = T3ProjectionMapper.resolvedText(payload, messagesByID: messagesByID)
                updateTimeline(payload)
                if live, let eventID, payload["type"].text == "assistant_message",
                   !newText.isEmpty, oldText != newText {
                    signal = .init(id: eventID, kind: .replyText)
                }
            }
        case let kind? where kind.hasPrefix("thread.") && payload["id"].text == threadID:
            thread = payload
        default: return
        }
        if live, let eventID, previousActive == nil, activeRunID != nil {
            signal = .init(id: eventID, kind: .turnStarted)
        }
        refreshActivity(eventTime: eventTime, reaction: reaction, signal: signal, sameRun: previousActive == activeRunID)
    }

    private static func isHeldInput(_ item: HermesJSON) -> Bool {
        item["type"].text == "user_message" && item["inputIntent"].text == "queued_turn"
    }

    private mutating func updateTimeline(_ item: HermesJSON, wasLoaded: Bool = false) {
        let row = TimelineRow(item: item, isLocal: true)
        let existing = timeline.lastIndex { $0.item["id"] == item["id"] }
        if let existing {
            if timeline[existing].isLocal, timeline[existing].ordinal == row.ordinal {
                timeline[existing] = row
                return
            }
            timeline.remove(at: existing)
        } else if hasMoreHistory, !wasLoaded, let ordinal = row.ordinal,
                  let oldest = oldestSnapshotLocalOrdinal,
                  ordinal < oldest {
            // Older active rows may join the timeline without expanding the snapshot's history window.
            let run = runs.first { $0["id"] == item["runId"] }
            let status = run?["status"].text ?? ""
            guard status == "queued" || T3ProjectionMapper.activeStatuses.contains(status) else { return }
        }
        let insertion = row.ordinal.flatMap { ordinal in
            timeline.firstIndex { $0.isLocal && ($0.ordinal ?? ordinal) > ordinal }
        } ?? timeline.endIndex
        timeline.insert(row, at: insertion)
    }

    private mutating func refreshActivity(eventTime: Date? = nil, reaction: TurnReaction? = nil,
                                          signal: ConversationActivity.Signal? = nil, sameRun: Bool = true) {
        let run = activeRun
        let runID = run?["id"].text
        let startedAt = run.flatMap {
            T3ProjectionMapper.date($0["workStartedAt"]) ?? T3ProjectionMapper.date($0["startedAt"])
                ?? T3ProjectionMapper.date($0["requestedAt"])
        }
        var phase: ConversationWorkPhase? = runID == nil ? nil : .working
        var phaseAt = eventTime ?? startedAt
        if let runID {
            let candidates = turnItems.reversed().compactMap { item -> (ConversationWorkPhase, Date)? in
                guard item["runId"].text == runID,
                      let kind = item["type"].text else { return nil }
                let time = T3ProjectionMapper.date(item["updatedAt"]) ?? phaseAt ?? .distantPast
                if item["streaming"].flag == true {
                    if kind == "reasoning" { return (.thinking, time) }
                    if kind == "assistant_message" { return (.replying, time) }
                }
                if T3ProjectionMapper.toolTypes.contains(kind), item["status"].text == "running" { return (.tools, time) }
                return nil
            }
            if let newest = candidates.max(by: { $0.1 < $1.1 }) {
                phase = newest.0
                phaseAt = newest.1 == .distantPast ? nil : newest.1
            }
        }
        if sameRun, phase == activity.phase { phaseAt = activity.phaseStartedAt ?? phaseAt }
        activity = ConversationActivity(lineage: activity.lineage, phase: phase, workStartedAt: startedAt,
                                        phaseStartedAt: phase == nil ? nil : phaseAt, reaction: reaction, signal: signal)
    }

    private static func upsert(_ value: HermesJSON, into items: inout [HermesJSON]) {
        guard let id = value["id"].nonempty else { return }
        if let index = items.lastIndex(where: { $0["id"].text == id }) { items[index] = value }
        else { items.append(value) }
    }
}
