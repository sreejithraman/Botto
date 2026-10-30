// Request parsing and transcript reconciliation adapted from Hermex; see LICENSES/Hermex.txt.
import Foundation

struct HermesRequestRoute: Equatable {
    enum Kind: Equatable { case approval, question, batch(String), unsupported }
    let kind: Kind
    let hostID: String
    let generation: Int?
    let authority: Bool
}

struct HermesConversationState {
    var motion = HermesConversationMotion()
    var conversation: Conversation
    var root: String
    var epoch: String
    var generation: Int?
    var subscription: String?
    var profileIdentity: String?
    var routes: [String: HermesRequestRoute] = [:]
    var serverRequestIDs: Set<String> = []
    var streamingID: String?
    var turnID = UUID().uuidString
    var optimistic: [String] = []
    struct StartingSubmission {
        let id: String
        var admission: String?
    }
    var startingSubmission: StartingSubmission?
    // Changes whenever host evidence can supersede an in-flight queued receipt.
    var queueObservation = UUID()
    // Exists only while one replacement RPC is in flight. Its ACK can arrive after
    // several turns, so retain their first rows rather than the current stream.
    struct QueuedReplacement {
        struct Turn {
            let admission: String
            var beforeMessageID: String?
        }
        let submission: String
        var durableUserID: String?
        var turns: [Turn] = []

        func turn(_ admission: String) -> Turn? { turns.first { exact($0.admission, admission) } }
    }
    var queuedReplacement: QueuedReplacement?

    init(profile: String, root: String, stored: String, runtime: String, epoch: String) {
        self.root = root; self.epoch = epoch
        conversation = Conversation(id: runtime, storedID: stored, profileID: profile)
    }

    mutating func restore(_ snapshot: HermesJSON, history: [HermesJSON], authority: Bool) throws {
        guard exact(snapshot["session_id"].text, conversation.id),
              exact(snapshot["stored_session_id"].text ?? snapshot["session_key"].text, conversation.storedID),
              snapshot["info"]["profile_name"].text.map({ exact($0, conversation.profileID) }) != false
        else { throw HermesServiceError.wrongConversation }
        if authority {
            guard let epoch = snapshot["replay_epoch"].nonempty, let sequence = snapshot["last_sequence"].integer,
                  sequence >= 0, let generation = snapshot["execution_generation"].integer,
                  let subscription = snapshot["subscription_id"].nonempty,
                  let profileIdentity = snapshot["info"]["profile_id"].nonempty,
                  snapshot["pending"].list != nil, snapshot["prompts"].list != nil else { throw HermesServiceError.incompatible }
            self.epoch = epoch; self.generation = generation; self.subscription = subscription
            self.profileIdentity = profileIdentity
            conversation.lastSequence = sequence
        }
        conversation.messages = Self.messages(history, stored: conversation.storedID)
        conversation.isWorking = snapshot["running"].flag == true
        motion.restore(working: conversation.isWorking, generation: generation,
                       replying: !authority && snapshot["inflight"]["assistant"].nonempty != nil)
        conversation.pendingRequests = []; routes = [:]; serverRequestIDs = []; streamingID = nil; optimistic = []
        turnID = UUID().uuidString; queuedReplacement = nil; startingSubmission = nil
        for row in snapshot["prompts"].list ?? [] { addPrompt(row, authority: true) }
        for envelope in snapshot["open_requests"].list ?? [] { serverRequest(envelope) }
        if let queue = snapshot["pending_approval"]["request_id"].nonempty,
           !routes.values.contains(where: { $0.hostID == queue }) {
            addPrompt(snapshot["pending_approval"], authority: false, envelopeID: "approval:" + queue)
        }
        if snapshot["pending_connection"].fields != nil {
            unsupported(id: "connection:" + (snapshot["pending_connection"]["op_id"].text ?? "pending"),
                        title: "Connection setup needed", detail: "Continue this request in Hermes Desktop.")
        }
        if authority { applyPending(snapshot["pending"]) }
        else {
            applySidecarQueue(snapshot["queued"])
        }
        if !authority, conversation.isWorking {
            let inflight = snapshot["inflight"]
            if let user = inflight["user"].nonempty {
                // Identity wins; otherwise use the turn's timestamp boundary, never repeated
                // prompt text, to establish that this user row was already persisted.
                let rowID = inflight["user_row_id"].integer
                let started = inflight["started_at"].date ?? snapshot["turn_started_at"].date
                let users = conversation.messages.filter { $0.role == .user }
                let savedByDate = started.map { start in
                    users.last?.timestamp.map { $0 >= start } == true &&
                        (users.count < 2 || users[users.count - 2].timestamp.map { $0 < start } == true)
                } ?? false
                let savedByID = rowID.map { id in conversation.messages.contains { $0.role == .user && $0.id == rowKey(id) } } ?? false
                let persistedID = savedByID ? rowID.map(rowKey) : (savedByDate ? users.last?.id : nil)
                let persistedUser = persistedID.flatMap { id in conversation.messages.first { $0.role == .user && $0.id == id } }
                let savedRow = rowID.flatMap { id in
                    history.first { $0["role"].text == "user" && ($0["row_id"].integer ?? $0["_row_id"].integer ?? $0["id"].integer) == id }
                }
                let kind = inflight["display_kind"].text ?? savedRow?["display_kind"].text ?? persistedUser?.displayKind
                let metadata = inflight["display_metadata"].fields != nil ? inflight["display_metadata"] : savedRow?["display_metadata"] ?? .null
                let displayText = metadata.fields != nil ? metadata["display_text"].text : persistedUser?.displayText
                if kind == "hidden" || metadata["model_only"].flag == true {
                    if let id = persistedID {
                        conversation.messages.removeAll { $0.id == id && $0.role == .user }
                    }
                } else if let id = persistedID, let index = conversation.messages.firstIndex(where: { $0.role == .user && $0.id == id }) {
                    conversation.messages[index].displayKind = kind
                    conversation.messages[index].displayText = displayText
                } else if !savedByDate {
                    conversation.messages.append(ChatMessage(id: "inflight-user", role: .user, text: user, timestamp: started,
                        displayKind: kind, displayText: displayText))
                }
            }
            if let text = inflight["assistant"].nonempty { setStream(text) }
        }
    }

    /// The authority snapshot contains durable rows; only the unfinished segment is transient.
    /// Rebuild that segment from the current execution's replay, never replay a completed turn
    /// over history. Missing ring entries leave durable history intact.
    mutating func restoreAuthorityStream(_ events: [HermesJSON], through watermark: Int) {
        guard conversation.isWorking else { return }
        var text = ""
        var activeTools: [String: HermesJSON] = [:]
        for event in events where (event["seq"].integer ?? Int.max) <= watermark {
            guard exact(event["session_id"].text, conversation.id),
                  event["execution_generation"].integer == generation else { continue }
            motion.reduce(event, authority: true, live: false)
            let payload = event["payload"]
            switch event["type"].text {
            case "message.start", "message.interim", "message.complete": text = ""; activeTools = [:]
            case "message.delta": text += payload["text"].text ?? ""
            case "tool.start": if let id = payload["tool_id"].text { activeTools[id] = payload }; text = ""
            case "tool.complete": if let id = payload["tool_id"].text { activeTools[id] = nil }
            default: break
            }
        }
        if !text.isEmpty { setStream(text) }
        for id in activeTools.keys.sorted() { updateTool(activeTools[id]!, complete: false) }
    }

    /// Current authority snapshots do not include its one-shot server request envelopes.
    /// Preserve a visible, non-actionable reminder during recovery until cancellation is
    /// known. Fresh prompt snapshots still own all ordinary approval/clarify controls.
    mutating func retainUnprojectedRequests(from prior: HermesConversationState, replay: [HermesJSON]) {
        guard exact(prior.conversation.id, conversation.id), exact(prior.conversation.profileID, conversation.profileID),
              exact(prior.conversation.storedID, conversation.storedID) else { return }
        let cancelled = Set(replay.filter { $0["type"].text == "request.cancel" }.compactMap { $0["payload"]["id"].text })
        for card in prior.conversation.pendingRequests {
            guard let route = prior.routes[card.id], prior.serverRequestIDs.contains(route.hostID),
                  !cancelled.contains(route.hostID), routes[card.id] == nil else { continue }
            let reminder = PendingRequest(id: card.id, kind: .unsupported, title: card.title,
                detail: "This request was received before the connection was refreshed. Check Hermes Desktop to resolve or confirm its outcome.")
            addCard(reminder, route: HermesRequestRoute(kind: .unsupported, hostID: route.hostID, generation: nil, authority: false))
            serverRequestIDs.insert(route.hostID)
        }
    }

    mutating func reduce(_ event: HermesJSON, authority: Bool, live: Bool = true) {
        if let next = event["seq"].integer { conversation.lastSequence = next }
        guard motion.acceptsTranscript(event, authority: authority) else { return }
        motion.reduce(event, authority: authority, live: live)
        let payload = event["payload"]
        if let value = event["execution_generation"].integer { generation = value }
        switch event["type"].text {
        case "message.start":
            let displayKind = payload["display_kind"].text
            startingSubmission = nil
            if authority {
                queueObservation = UUID()
                if let id = event["admission_id"].text {
                    if queuedReplacement != nil, queuedReplacement?.turn(id) == nil {
                        queuedReplacement?.turns.append(.init(admission: id))
                    }
                    if let queued = conversation.queuedMessages.first(where: { exact($0.id, id) && !$0.isSteering }),
                       let submission = queued.submissionID, queued.sourceMessage == nil {
                        let userID = "submission:" + submission
                        if let index = conversation.messages.firstIndex(where: { exact($0.id, userID) }) {
                            let message = conversation.messages.remove(at: index)
                            conversation.messages.append(message)
                            captureReplacementBoundary(message.id)
                        } else { addSubmittedText(queued.text, submission: submission) }
                        if let index = conversation.messages.firstIndex(where: { exact($0.id, userID) }) {
                            conversation.messages[index].displayKind = displayKind
                            conversation.messages[index].displayText = payload["display_text"].text
                        }
                    }
                    conversation.queuedMessages.removeAll { exact($0.id, id) && !$0.isSteering }
                }
            }
            streamingID = nil; turnID = event["admission_id"].text ?? UUID().uuidString
            conversation.isWorking = true
        case "message.delta":
            guard let text = payload["text"].text else { settleStreamSilence(); streamingID = nil; return }
            appendStream(text)
        case "message.interim":
            if payload["already_streamed"].flag != true, let text = payload["text"].nonempty { setStream(text) }
            settleStreamSilence()
            streamingID = nil
        case "tool.start": updateTool(payload, complete: false)
        case "tool.complete": updateTool(payload, complete: true)
        case "message.complete":
            if let admission = event["admission_id"].nonempty,
               exact(startingSubmission?.admission, admission) { startingSubmission = nil }
            if authority, event["execution_generation"].integer == nil,
               let admission = event["admission_id"].nonempty,
               ["cancelled", "steered"].contains(payload["outcome"].text ?? "") {
                // Queued cancellation/transfer settlement is not the running claim's
                // completion. In particular, replacing a queued row must not erase
                // the assistant segment that is still streaming ahead of it.
                queueObservation = UUID()
                conversation.queuedMessages.removeAll { exact($0.id, admission) }
                return
            }
            let finalID = payload["persisted_turn"]["final_assistant_row_id"].integer.map(rowKey)
            if let finalID, conversation.messages.contains(where: { $0.id == finalID }) {
                // A sidecar history read can include this completion before its held event
                // is released. Its durable row already owns the final answer.
                if let streamingID, streamingID != finalID {
                    renameReplacementBoundary(streamingID, to: finalID)
                    conversation.messages.removeAll { $0.id == streamingID }
                }
                streamingID = nil
            } else if let text = payload["text"].text { setStream(text) }
            if let finalID, let id = streamingID,
               let index = conversation.messages.firstIndex(where: { $0.id == id }) {
                renameReplacementBoundary(id, to: finalID)
                conversation.messages[index].id = finalID
            }
            // A completion can belong to a different client while our input is queued.
            // Authority carries the submitted identity; the sidecar has no such proof.
            let submitted = payload["persisted_turn"]["submission_id"].text.map { "submission:" + $0 }
            if authority, let replacement = queuedReplacement,
               exact(payload["persisted_turn"]["submission_id"].text, replacement.submission),
               let row = payload["persisted_turn"]["user_row_id"].integer {
                let durableID = rowKey(row)
                queuedReplacement?.durableUserID = durableID
            }
            if authority, let id = submitted, optimistic.contains(id),
               let row = payload["persisted_turn"]["user_row_id"].integer,
               let index = conversation.messages.firstIndex(where: { $0.id == id }) {
                renameReplacementBoundary(id, to: rowKey(row))
                if conversation.messages.contains(where: { $0.id == rowKey(row) }) { conversation.messages.remove(at: index) }
                else { conversation.messages[index].id = rowKey(row) }
                optimistic.removeAll { $0 == id }
            }
            if ["error", "interrupted", "cancelled", "unknown"].contains(payload["status"].text ?? "") {
                note("The turn ended without completing. Check the host before trying again.", id: "outcome:" + turnID)
            }
            if let id = finalID ?? streamingID, let index = conversation.messages.firstIndex(where: { $0.id == id }) {
                if payload["status"].text != "complete" {
                    // History can arrive before a held completion. Its explicit failed
                    // outcome overrides a legacy marker projection on the durable row.
                    conversation.messages[index].displayKind = "failed_turn"
                    conversation.messages[index].isSilent = false
                } else if streamingID != nil {
                    conversation.messages[index].isSilent = HermesMessagePresentation.isSilence(conversation.messages[index].text)
                }
            }
            conversation.isWorking = false; streamingID = nil
        case "session.info":
            if let running = payload["running"].flag { conversation.isWorking = running }
            if let value = payload["execution_generation"].integer { generation = value }
            if authority, payload["pending"].list != nil { applyPending(payload["pending"]) }
            if !authority, payload.fields?["queued"] != nil { applySidecarQueue(payload["queued"]) }
        case "approval.request", "clarify.request": addPrompt(payload, authority: true)
        case "approval.settled", "clarify.settled":
            if let id = payload["prompt_id"].text { removeRequest(id) }
        case "request.cancel":
            if let id = payload["id"].text {
                for key in Array(routes.keys) where key == id || routes[key]?.hostID == id { removeRequest(key) }
            }
        case "approval.cancelled":
            if let id = payload["request_id"].text {
                for key in Array(routes.keys) where routes[key]?.hostID == id { removeRequest(key) }
            }
        case "connection.request", "connection.update":
            let id = "connection:" + (payload["op_id"].text ?? "pending")
            if ["resolved", "completed", "cancelled"].contains(payload["status"].text ?? "") { removeRequest(id) }
            else { unsupported(id: id, title: "Connection setup needed", detail: "Continue this request in Hermes Desktop.") }
        case "error": note("Hermes reported a problem with this turn. Check the host for details.", id: "error:" + turnID)
        default: break
        }
    }

    mutating func serverRequest(_ frame: HermesJSON) {
        guard let id = frame["id"].nonempty, let method = frame["method"].nonempty,
              exact(frame["params"]["session_id"].text, conversation.id) else { return }
        let params = frame["params"]
        switch method {
        case "approval": addPrompt(params, authority: false, envelopeID: id)
        case "clarify":
            if let questions = params["questions"].list, !questions.isEmpty {
                var parsed = 0
                for question in questions {
                    guard let qid = question["qid"].nonempty ?? question["id"].nonempty,
                          let title = question["question"].nonempty, params["answers"][qid].text == nil else { continue }
                    let key = id + ":" + qid
                    addCard(PendingRequest(id: key, kind: .question, title: title, choices: choices(question["choices"])),
                            route: HermesRequestRoute(kind: .batch(qid), hostID: id, generation: nil, authority: false))
                    parsed += 1
                }
                if parsed == 0, questions.contains(where: { ($0["qid"].text ?? $0["id"].text) == nil }) {
                    unsupported(id: id, title: "Question needs Hermes Desktop", detail: "The host sent an unsupported question format.")
                }
            } else if let title = params["question"].nonempty {
                addCard(PendingRequest(id: id, kind: .question, title: title, choices: choices(params["choices"])),
                        route: HermesRequestRoute(kind: .question, hostID: id, generation: nil, authority: false))
            } else { unsupported(id: id, title: "Question needs Hermes Desktop", detail: "The host sent an unsupported question format.") }
        default:
            unsupported(id: id, title: "Request needs Hermes Desktop", detail: "This bot is waiting for a request that Botto cannot answer.")
        }
        serverRequestIDs.insert(id)
    }

    mutating func addPrompt(_ payload: HermesJSON, authority: Bool, envelopeID: String? = nil) {
        let hostID = authority ? payload["prompt_id"].nonempty : payload["request_id"].nonempty
        guard let hostID else {
            if let envelopeID { unsupported(id: envelopeID, title: "Request needs Hermes Desktop", detail: "The request identity is incomplete.") }
            return
        }
        let id = envelopeID ?? hostID
        let kind = payload["kind"].text ?? "approval"
        if kind == "approval" {
            let known = ["once", "session", "always", "deny"]
            var offered: [String]
            if payload.fields?["choices"] != nil { offered = (payload["choices"].list ?? []).compactMap(\.text).filter { known.contains($0) } }
            else {
                offered = ["once"]
                if payload["smart_denied"].flag != true, payload["allow_session"].flag != false {
                    offered.append("session"); if payload["allow_permanent"].flag != false { offered.append("always") }
                }
            }
            if !offered.contains("deny") { offered.append("deny") }
            let labels = ["once": "Allow once", "session": "Allow for this session", "always": "Always allow", "deny": "Deny"]
            var seen = Set<String>()
            let card = PendingRequest(id: id, kind: .approval, title: "Approval needed",
                detail: [payload["command"].text, payload["description"].text].compactMap { $0 }.joined(separator: "\n"),
                choices: offered.filter { seen.insert($0).inserted }.map { RequestChoice(id: $0, label: labels[$0]!) }, queueID: hostID)
            addCard(card, route: HermesRequestRoute(kind: .approval, hostID: hostID,
                generation: payload["execution_generation"].integer, authority: authority))
        } else if kind == "clarify", let title = payload["question"].nonempty {
            addCard(PendingRequest(id: id, kind: .question, title: title, choices: choices(payload["choices"])),
                    route: HermesRequestRoute(kind: .question, hostID: hostID,
                        generation: payload["execution_generation"].integer, authority: authority))
        } else { unsupported(id: id, title: "Request needs Hermes Desktop", detail: "This bot is waiting for an unsupported request.") }
    }

    mutating func removeRequest(_ id: String) { routes[id] = nil; conversation.pendingRequests.removeAll { $0.id == id } }
    mutating func addCard(_ card: PendingRequest, route: HermesRequestRoute) {
        removeRequest(card.id); routes[card.id] = route; conversation.pendingRequests.append(card)
    }
    mutating func unsupported(id: String, title: String, detail: String) {
        addCard(PendingRequest(id: id, kind: .unsupported, title: title, detail: detail),
                route: HermesRequestRoute(kind: .unsupported, hostID: id, generation: nil, authority: false))
    }
    private func choices(_ value: HermesJSON) -> [RequestChoice] {
        (value.list ?? []).enumerated().compactMap { index, item in
            guard let text = item.text else { return nil }; return RequestChoice(id: String(index), label: text)
        }
    }
    mutating func applyPending(_ pending: HermesJSON) {
        queueObservation = UUID()
        conversation.queuedMessages = []
        conversation.messages.removeAll { $0.id.hasPrefix("queue:") }
        for id in Array(routes.keys) where id.hasPrefix("unknown:") { removeRequest(id) }
        let rows = pending.list ?? []
        if let starting = startingSubmission, let first = rows.first {
            let isHead = exact(first["input_id"].text, starting.id)
                || starting.admission.map { exact(first["admission_id"].text, $0) } == true
            let blocked = conversation.isWorking || !conversation.pendingRequests.isEmpty
                || rows.contains(where: { $0["status"].text == "unknown" })
            if !isHead || blocked { startingSubmission = nil }
        }
        for row in rows {
            guard let id = row["admission_id"].nonempty else { continue }
            let steering = row["steering"].flag == true
            if row["status"].text == "queued", !steering, isStartingSubmission(row["input_id"].nonempty) {
                startingSubmission?.admission = id
                continue
            }
            if row["status"].text == "queued" || (row["status"].text == "started" && steering) {
                conversation.queuedMessages.append(QueuedMessage(id: id, text: row["text"].text ?? "Message",
                    canEdit: !steering && row["status"].text == "queued" && row["controls"].list?.contains(.string("replace")) == true,
                    submissionID: row["input_id"].nonempty, isSteering: steering))
            } else if row["status"].text == "unknown" {
                unsupported(id: "unknown:" + id, title: "Turn outcome unknown",
                            detail: "The host restarted before this turn was settled. Resolve it in Hermes Desktop before sending it again.")
            }
        }
        if let admission = startingSubmission?.admission,
           !rows.contains(where: { exact($0["admission_id"].text, admission) }) {
            startingSubmission = nil
        }
    }

    /// The sidecar exposes only the head's text, without admission or submission identity.
    /// This is a local presentation key and never authorizes a remote mutation.
    mutating func applySidecarQueue(_ queued: HermesJSON) {
        queueObservation = UUID()
        conversation.queuedMessages = queued["user"].text.map {
            [QueuedMessage(id: "sidecar-queue-head", text: $0)]
        } ?? []
    }

    mutating func confirmQueuedReceipt(admission: String, text: String, submission: String, observation: UUID?) {
        // A newer pending/start frame owns both membership and controls, even if it
        // precedes the RPC ACK. A receipt alone never grants editing capability.
        if isStartingSubmission(submission) {
            startingSubmission?.admission = admission
            return
        }
        guard queueObservation == observation,
              !conversation.queuedMessages.contains(where: { exact($0.id, admission) }) else { return }
        conversation.queuedMessages.append(QueuedMessage(id: admission, text: text, submissionID: submission))
    }

    private func isStartingSubmission(_ submission: String?) -> Bool {
        guard let submission, !conversation.isWorking, conversation.pendingRequests.isEmpty else { return false }
        return exact(startingSubmission?.id, submission)
    }

    mutating func addSubmittedText(_ text: String, submission: String, beforeMessageID: String? = nil) {
        let durableID = exact(queuedReplacement?.submission, submission) ? queuedReplacement?.durableUserID : nil
        let id = durableID ?? "submission:" + submission
        guard !conversation.messages.contains(where: { exact($0.id, id) }) else { return }
        let message = ChatMessage(id: id, role: .user, text: text, timestamp: .now)
        if let beforeMessageID, let index = conversation.messages.firstIndex(where: { exact($0.id, beforeMessageID) }) {
            conversation.messages.insert(message, at: index)
        } else { conversation.messages.append(message) }
        captureReplacementBoundary(id)
        if durableID == nil { optimistic.append(id) }
    }
    private mutating func captureReplacementBoundary(_ id: String) {
        guard var replacement = queuedReplacement else { return }
        for index in replacement.turns.indices where replacement.turns[index].beforeMessageID == nil {
            replacement.turns[index].beforeMessageID = id
        }
        queuedReplacement = replacement
    }
    private mutating func renameReplacementBoundary(_ id: String, to durableID: String) {
        guard var replacement = queuedReplacement else { return }
        for index in replacement.turns.indices where exact(replacement.turns[index].beforeMessageID, id) {
            replacement.turns[index].beforeMessageID = durableID
        }
        queuedReplacement = replacement
    }
    mutating func note(_ text: String, id: String) {
        guard !conversation.messages.contains(where: { $0.id == id }) else { return }
        conversation.messages.append(ChatMessage(id: id, role: .system, text: text))
        captureReplacementBoundary(id)
    }
    mutating func settleStreamSilence() {
        guard let id = streamingID, let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        conversation.messages[index].isSilent = HermesMessagePresentation.isSilence(conversation.messages[index].text)
    }
    mutating func appendStream(_ text: String) {
        guard !text.isEmpty else { return }
        if let id = streamingID, let index = conversation.messages.firstIndex(where: { $0.id == id }) {
            conversation.messages[index].text += text
            conversation.messages[index].isSilent = HermesMessagePresentation.isSilence(conversation.messages[index].text)
        } else { setStream(text) }
    }
    mutating func setStream(_ text: String) {
        if let id = streamingID, let index = conversation.messages.firstIndex(where: { $0.id == id }) {
            conversation.messages[index].text = text
            conversation.messages[index].isSilent = HermesMessagePresentation.isSilence(text)
        } else if !text.isEmpty {
            let id = "live:" + UUID().uuidString; streamingID = id
            conversation.messages.append(ChatMessage(id: id, role: .assistant, text: text,
                isSilent: HermesMessagePresentation.isSilence(text)))
            captureReplacementBoundary(id)
        }
    }
    mutating func updateTool(_ payload: HermesJSON, complete: Bool) {
        let id = "tool:" + turnID + ":" + (payload["tool_id"].text ?? String(conversation.lastSequence))
        let name = payload["name"].text ?? "Tool"
        let result = payload["result_text"].text ?? payload.fields?["result"].flatMap(Self.toolResultText)
        let text = complete ? (result ?? payload["summary"].text ?? "Finished") : (payload["args"]["command"].text ?? "Running…")
        let row = ChatMessage(id: id, role: .tool, text: text, toolName: name)
        if let index = conversation.messages.firstIndex(where: { $0.id == id }) { conversation.messages[index] = row }
        else { conversation.messages.append(row); captureReplacementBoundary(id) }
    }
    func rowKey(_ id: Int) -> String { conversation.storedID + ":row:" + String(id) }

    static func messages(_ rows: [HermesJSON], stored: String) -> [ChatMessage] {
        var seen = Set<String>()
        return rows.enumerated().compactMap { offset, row in
            guard row["display_kind"].text != "hidden", row["display_metadata"]["model_only"].flag != true,
                  let roleName = row["role"].text, let role = ChatMessage.Role(rawValue: roleName) else { return nil }
            let id = (row["row_id"].integer ?? row["_row_id"].integer ?? row["id"].integer).map { stored + ":row:" + String($0) }
                ?? stored + ":index:" + String(offset)
            guard seen.insert(id).inserted else { return nil }
            let images = role == .user ? historyImages(row["content"], messageID: id) : (attachments: [], parts: Set<Int>())
            let text = row["text"].text ?? (role == .tool ? toolResultText(row["content"]) ?? "" : contentText(row["content"], omitting: images.parts))
            if text.isEmpty, images.attachments.isEmpty, row["tool_calls"].list != nil { return nil }
            let failed = row["display_kind"].text == "failed_turn" || row["failed"].flag == true ||
                row["display_metadata"]["failed"].flag == true ||
                row["status"].text.map({ !["complete", "completed", "success"].contains($0) }) == true ||
                row["display_metadata"]["error"] != .null || row["display_metadata"]["error_surface"] != .null
            return ChatMessage(id: id, role: role, text: text, timestamp: row["timestamp"].date,
                               toolName: row["name"].text, attachments: images.attachments,
                               displayKind: failed && role == .assistant ? "failed_turn" : row["display_kind"].text,
                               isSilent: role == .assistant && !failed && HermesMessagePresentation.isSilence(text),
                               displayText: row["display_metadata"]["display_text"].text)
        }
    }
    /// Both tested Hermes pins' agent/image_routing.py emit nested image_url parts.
    /// Retain descriptors only: inline bytes and remote addresses never become card identities.
    private static func historyImages(_ content: HermesJSON, messageID: String) -> (attachments: [ChatAttachment], parts: Set<Int>) {
        var attachments: [ChatAttachment] = []
        var omitted = Set<Int>()
        var images: [(index: Int, url: String, mime: String)] = []
        for (index, part) in (content.list ?? []).enumerated() {
            guard part["type"].text == "image_url", let fields = part.fields,
                  Set(fields.keys).isSubset(of: ["type", "image_url"]),
                  let url = part["image_url"]["url"].text,
                  let image = url.wholeMatch(of: /data:(image\/(?:png|jpeg|gif|webp));base64,([A-Za-z0-9+\/]+={0,2})/),
                  image.2.count.isMultiple(of: 4) else { continue }
            images.append((index, url, String(image.1)))
        }
        let hints = historyImagePaths(content)
        var seen = Set<String>()
        for (offset, image) in images.enumerated() {
            omitted.insert(image.index)
            let localPath = hints.count == images.count ? hints[offset] : nil
            let first = images.first(where: { $0.url == image.url })?.index ?? image.index
            let path = localPath ?? messageID + ":image:" + String(first)
            guard seen.insert(path).inserted else { continue }
            let mime = image.mime
            let ext = mime == "image/jpeg" ? "jpg" : String(mime.dropFirst("image/".count))
            let name = localPath?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "Image." + ext
            attachments.append(ChatAttachment(name: name, path: path, mimeType: mime))
        }
        return (attachments, omitted)
    }

    /// Filename hints have different persisted text shapes in native and sidecar turns.
    /// Only a complete suffix paired one-for-one with supported image parts can supply paths.
    private static func historyImagePaths(_ content: HermesJSON) -> [String] {
        guard let first = content.list?.first, first["type"].text == "text", let text = first["text"].text,
              let hints = AttachmentPresentation.imageHints(in: text) else { return [] }
        for value in hints.paths {
            guard let path = try? HermesAttachment.hostPath(value), path.utf8.count <= 4096,
                  !path.hasSuffix("/"), !path.hasSuffix("\\"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !path.contains("?"), !path.contains("#"),
                  !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains(where: { $0 == "." || $0 == ".." })
            else { return [] }
        }
        return hints.paths
    }

    private static func toolResultText(_ value: HermesJSON) -> String? {
        if let text = value.text { return text }
        if let parts = value.list, !parts.isEmpty, parts.allSatisfy({ part in
            guard let fields = part.fields else { return false }
            switch part["type"].text {
            case "text": return Set(fields.keys).isSubset(of: ["type", "text"]) && part["text"].text != nil
            case "image_url": return Set(fields.keys).isSubset(of: ["type", "image_url"])
            default: return false
            }
        }) {
            // Prompt-style multimodal blocks keep their existing resource-safe projection.
            return contentText(value)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func contentText(_ value: HermesJSON, omitting: Set<Int> = []) -> String {
        if let text = value.text { return text }
        if let list = value.list {
            return list.enumerated().compactMap { index, part -> String? in
                guard !omitting.contains(index) else { return nil }
                return part["text"].text ?? part.text ?? (part["type"].text.map { "[\($0)]" } ?? "")
            }.joined(separator: "\n")
        }
        return value["text"].text ?? ""
    }
}
