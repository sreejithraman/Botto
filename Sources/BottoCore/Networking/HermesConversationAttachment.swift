import Foundation

extension HermesBotService {
    public func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        try Task.checkCancellation()
        pendingStopObservation = nil
        let socket = try readyGateway(), connectionOwner = connectionGeneration
        selectionGeneration += 1
        let owner = selectionGeneration
        retireAccess(); attached = false
        refreshingChat?.cancel(); refreshingChat = nil
        let old = state
        state = nil; selectedTarget = nil; attaching = false; held = []
        if let old { await detach(old, socket: socket) }
        try checkSelection(owner, connection: connectionOwner)
        let identity: SessionIdentity
        var canonicalSummary: SessionSummary?
        var canonicalSource: SessionIdentity?
        switch target {
        case .canonical(let profile, let expectedRoot):
            selectedCanonical = true
            let rows = try await canonicalRows(profile: profile.text, socket: socket)
            try checkSelection(owner, connection: connectionOwner)
            guard rows.count == 1, let row = rows.first else { throw HermesServiceError.missingChat }
            let summary = try sessionSummary(row, profile: profile, canonical: true)
            identity = summary.identity
            if row["profile"].text.map({ exact($0, profile.text) }) != false,
               row["profile_name"].text.map({ exact($0, profile.text) }) != false {
                canonicalSource = summary.identity
                if let count = summary.messageCount, count >= 0 { canonicalSummary = summary }
            }
            if let expectedRoot, expectedRoot != identity.root,
               !identity.aliases.contains(expectedRoot) { throw HermesServiceError.wrongConversation }
        case .stored(let stored):
            identity = try await storedIdentityProof(stored, selection: owner, connection: connectionOwner)
            selectedCanonical = catalogs[identity.profile]?.summaries.contains { $0.isCanonical && $0.identity.root == identity.root } == true
        }
        try checkSelection(owner, connection: connectionOwner)
        selectedTarget = identity
        return try await attach(identity: identity, owner: owner, canonicalSummary: canonicalSummary, sourceBeforeRead: canonicalSource,
                                activityPredecessor: old)
    }

    func detach(_ old: HermesConversationState, socket: HermesGateway) async {
        guard adapter == .authority, let subscription = old.subscription else { return }
        _ = try? await socket.call("session.detach", ["profile": .string(old.conversation.profileID),
            "session_id": .string(old.conversation.id), "subscription_id": .string(subscription)], timeoutPolicy: .requestOnly)
    }

    func cleanupAttachment(_ snapshot: HermesJSON, profile: String, socket: HermesGateway) async {
        guard let subscription = snapshot["subscription_id"].nonempty,
              let runtime = snapshot["session_id"].nonempty else { return }
        await Task {
            _ = try? await socket.call("session.detach", ["profile": .string(profile),
                "session_id": .string(runtime), "subscription_id": .string(subscription)], timeoutPolicy: .requestOnly)
        }.value
    }

    func attach(identity suppliedIdentity: SessionIdentity, owner: Int,
                canonicalSummary: SessionSummary? = nil,
                sourceBeforeRead: SessionIdentity? = nil,
                activityPredecessor: HermesConversationState? = nil) async throws -> OpenedConversation {
        let socket = try readyGateway(), connectionOwner = connectionGeneration
        let priorActivity = activityPredecessor ?? state
        // Capture before the first resume/history/replay request. Later catalog replies
        // may invalidate the tip, but cannot supply this read's observation retroactively.
        let summaryBeforeRead = readSummary(for: suppliedIdentity) ?? canonicalSummary
        let observedSource = sourceBeforeRead ?? catalogs[suppliedIdentity.profile]?.summaries
            .first(where: { sameInventoryTip($0.identity, suppliedIdentity) })?.identity ?? summaryBeforeRead?.identity
        let historyReadStartedAt = ContinuousClock.now
        var identity = suppliedIdentity
        let profile = identity.profile.text, root = identity.root.text
        var stored = identity.stored.text
        retireAccess(); attached = false
        if !attaching { held = []; holdOverflow = false }
        attaching = true
        defer { if owner == selectionGeneration { attaching = false; reconciling = false } }
        var acquired: HermesJSON?
        var completed = false
        defer {
            if !completed, let acquired {
                Task { await self.cleanupAttachment(acquired, profile: profile, socket: socket) }
            }
        }
        var resume = adapter.resume(profile: profile, stored: stored, omitMessages: adapter == .sidecar)
        let initialResume = resume
        let first = try await Task { try await socket.call("session.resume", initialResume,
            validate: { try self.checkSelection(owner, connection: connectionOwner) }) }.value
        acquired = first
        try checkSelection(owner, connection: connectionOwner)
        guard let runtime = first["session_id"].nonempty else { throw HermesServiceError.incompatible }
        let returnedStored = first["stored_session_id"].nonempty ?? first["session_key"].nonempty
        guard let returnedStored, first["info"]["profile_name"].text.map({ exact($0, profile) }) != false else { throw HermesServiceError.wrongConversation }
        if !exact(returnedStored, stored) {
            // A resume can follow a compression continuation. Verify that edge against the
            // scoped server catalog before admitting a new tip into the durable identity.
            let returned = try ExactID(returnedStored)
            if knownIdentityProof(identity, returnedStored: returned) == nil {
                _ = try await conversations(profile: identity.profile)
                try checkSelection(owner, connection: connectionOwner)
            }
            guard let verified = knownIdentityProof(identity, returnedStored: returned) else { throw HermesServiceError.wrongConversation }
            identity = verified
            stored = returnedStored
            resume = adapter.resume(profile: profile, stored: stored, omitMessages: adapter == .sidecar)
        }
        let epoch = adapter == .authority ? first["replay_epoch"].nonempty : socket.replayEpoch
        guard let epoch else { throw HermesServiceError.incompatible }
        var fresh = HermesConversationState(profile: profile, root: root, stored: stored, runtime: runtime, epoch: epoch)
        let isAuthority = adapter == .authority
        // Full ring read permits recovery of the authority's unfinished segment. The atomic
        // snapshot watermark, not the gateway process epoch, determines which events are new.
        let replay = try await socket.call("session.events.since", adapter.replay(profile: profile, runtime: runtime, sequence: 0, epoch: epoch))
        try checkSelection(owner, connection: connectionOwner)
        guard let events = replay["events"].list, let latest = replay["latest_seq"].integer, latest >= 0 else { throw HermesServiceError.incompatible }
        for event in events {
            guard exact(event["session_id"].text, runtime), let seq = event["seq"].integer, seq > 0, seq <= latest else { throw HermesServiceError.wrongConversation }
        }
        let snapshot: HermesJSON
        if isAuthority, replay["snapshot_required"].flag != true { snapshot = first }
        else { snapshot = try await Task { try await socket.call("session.resume", resume,
            validate: { try self.checkSelection(owner, connection: connectionOwner) }) }.value }
        acquired = snapshot
        try checkSelection(owner, connection: connectionOwner)
        let history = try await readHistory(snapshot: snapshot, stored: stored, profile: profile, owner: connectionOwner, identity: identity)
        try checkSelection(owner, connection: connectionOwner)
        try fresh.restore(snapshot, history: history.rows, authority: isAuthority)
        if let prior = state, let identity = prior.profileIdentity, !exact(identity, fresh.profileIdentity) {
            throw HermesServiceError.wrongConversation
        }
        if isAuthority {
            if let prior = state { fresh.retainUnprojectedRequests(from: prior, replay: events) }
            if exact(fresh.epoch, replay["replay_epoch"].text), replay["truncated"].flag != true {
                fresh.restoreAuthorityStream(events, through: fresh.conversation.lastSequence)
                for event in events where (event["seq"].integer ?? 0) > fresh.conversation.lastSequence {
                    guard exact(event["replay_epoch"].text, fresh.epoch),
                          event["seq"].integer == fresh.conversation.lastSequence + 1 else { throw HermesServiceError.incompatible }
                    fresh.reduce(event, authority: true, live: false)
                }
            }
        } else {
            fresh.conversation.lastSequence = latest
            // The sidecar snapshot lacks a watermark. Its inflight text may contain deltas
            // received during the snapshot read; remove only the exact overlapping prefix.
            var reconstructed = events.reduce("") { text, event in
                switch event["type"].text {
                case "message.start", "message.interim", "message.complete": return ""
                case "message.delta": return text + (event["payload"]["text"].text ?? "")
                default: return text
                }
            }
            let inflight = snapshot["inflight"]["assistant"].text ?? ""
            var matched: Set<Int> = []
            var trial: [Int] = []
            for event in held where exact(event["session_id"].text, runtime) && (event["seq"].integer ?? 0) > latest {
                guard event["type"].text == "message.delta", let seq = event["seq"].integer else { continue }
                reconstructed += event["payload"]["text"].text ?? ""; trial.append(seq)
                if reconstructed == inflight { matched = Set(trial) }
            }
            held = held.map { frame in
                guard let seq = frame["seq"].integer, matched.contains(seq), exact(frame["session_id"].text, runtime) else { return frame }
                var frame = frame; frame["type"] = .string("botto.covered_delta"); return frame
            }
        }
        guard !holdOverflow else { throw HermesServiceError.disconnected }
        let replayComplete = replay["truncated"].flag != true && (!isAuthority ||
            (exact(fresh.epoch, replay["replay_epoch"].text) && fresh.conversation.lastSequence >= latest))
        // An idle authority snapshot contains the complete durable transcript. Its
        // watermark can cover the read even when older replay entries have expired.
        let idleSnapshotCoversReplay = isAuthority && snapshot["running"].flag == false &&
            exact(fresh.epoch, replay["replay_epoch"].text) &&
            (snapshot["last_sequence"].integer ?? -1) >= latest
        if let prior = priorActivity, exact(prior.root, fresh.root),
           exact(prior.conversation.id, fresh.conversation.id),
           exact(prior.conversation.profileID, fresh.conversation.profileID),
           exact(prior.conversation.storedID, fresh.conversation.storedID), exact(prior.epoch, fresh.epoch) {
            fresh.motion.retainClock(from: prior.motion)
            fresh.retainToolIdentities(from: prior, replay: replayComplete ? events : [])
        }
        state = fresh
        attaching = false; attached = true; reconciling = true
        selectedTarget = identity
        runtimeOwners[try ExactID(runtime)] = identity
        let buffered = held; held = []
        // Never restore cached cards: a request/cancel received during resume wins over it.
        for frame in buffered { receive(frame) }
        guard attached, let result = state?.conversation else { throw HermesServiceError.disconnected }
        _ = result
        let evidence: ConversationReadEvidence?
        if replayComplete || idleSnapshotCoversReplay, history.isComplete, snapshot["hydrating"].flag != true,
           snapshot["status"].text != "resuming",
           let summaryBeforeRead, sameInventoryTip(summaryBeforeRead.identity, identity),
           !catalogTipChanged(for: identity) {
            evidence = ConversationReadEvidence(summaryObservedBeforeRead: summaryBeforeRead)
        } else { evidence = nil }
        let sourceProof = observedSource.flatMap { sameInventoryTip($0, identity) && !catalogTipChanged(for: identity) ? $0 : nil }
        reconciling = false; emitConversation(readEvidence: evidence, historyReadStartedAt: historyReadStartedAt, observedSource: sourceProof)
        guard let publication else { throw HermesServiceError.disconnected }
        completed = true
        return publication
    }

    func sameInventoryTip(_ lhs: SessionIdentity, _ rhs: SessionIdentity) -> Bool {
        lhs.profile == rhs.profile && lhs.root == rhs.root && lhs.stored == rhs.stored
    }

    func readSummary(for identity: SessionIdentity) -> SessionSummary? {
        observedInventory[identity.profile]?.first { sameInventoryTip($0.identity, identity) }
    }

    func catalogTipChanged(for identity: SessionIdentity) -> Bool {
        catalogs[identity.profile]?.summaries.contains {
            $0.identity.profile == identity.profile && $0.identity.root == identity.root && $0.identity.stored != identity.stored
        } == true
    }

    func readHistory(snapshot: HermesJSON, stored: String, profile: String, owner: Int,
                     identity: SessionIdentity) async throws -> (rows: [HermesJSON], isComplete: Bool) {
        // Sidecar resume flattens structured image parts. Read its raw REST rows
        // after the replay/snapshot fence, while incoming events remain held.
        if adapter == .authority, snapshot["messages_omitted"].flag != true, let messages = snapshot["messages"].list,
           !messages.contains(where: { $0["archived_truncated"].flag == true }) {
            return (messages, HermesConversationState.unavailableMessageIDs(messages, stored: stored).isEmpty)
        }
        guard let http, Self.safeSegment(stored) else { throw HermesServiceError.incompatible }
        var rows: [HermesJSON] = [], offset = 0, seen = Set<Int>(), complete = true
        while true {
            let page: HermesJSON
            do { page = try await http.json("api/sessions/\(stored)/messages", query: [
                URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "order", value: "latest"),
                URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "include_compacted", value: "true"), URLQueryItem(name: "inline_images", value: "false")])
            } catch HermesServiceError.rejected(404) {
                // Provenance is service held. Caller-supplied persistence metadata is never authority.
                guard adapter == .sidecar, offset == 0, freshEmpty.contains(identity),
                      (snapshot["running"].flag == false || snapshot["running"] == .null),
                      snapshot["message_count"].integer == 0,
                      (snapshot["messages"].list ?? []).isEmpty,
                      snapshot["inflight"]["user"].nonempty == nil,
                      snapshot["inflight"]["assistant"].nonempty == nil,
                      exact(snapshot["stored_session_id"].text ?? snapshot["session_key"].text, stored),
                      snapshot["info"]["profile_name"].text.map({ exact($0, profile) }) != false,
                      snapshot["session_id"].nonempty.flatMap({ try? ExactID($0) }) == createdRuntimes[identity]
                else { throw HermesServiceError.rejected(404) }
                if snapshot["running"] == .null {
                    try await confirmUnpersistedDraftIsEmpty(snapshot, identity: identity, owner: owner)
                }
                return ([], true)
            }
            try checkConnection(owner)
            guard exact(page["session_id"].text, stored), exact(page["profile"].text, profile),
                  let batch = page["messages"].list else { throw HermesServiceError.wrongConversation }
            if batch.contains(where: { $0["archived_truncated"].flag == true }) { complete = false }
            if page["messages_omitted"].flag == true { complete = false }
            if page["pagination"] != .null {
                let paging = page["pagination"]
                if paging["offset"].integer != offset || paging["limit"].integer != 100 ||
                    paging["order"].text != "latest" || paging["returned"].integer != batch.count {
                    complete = false
                }
            }
            if !batch.isEmpty { freshEmpty.remove(identity) }
            let unique = batch.filter { row in
                guard let id = row["row_id"].integer ?? row["_row_id"].integer ?? row["id"].integer else { return true }
                return seen.insert(id).inserted
            }
            if unique.count != batch.count { complete = false }
            rows.insert(contentsOf: batch, at: 0)
            if batch.count < 100 { return (rows, complete) }
            guard !unique.isEmpty, offset < 100_000 else { throw HermesServiceError.incompatible }
            offset += batch.count
        }
    }


    func confirmUnpersistedDraftIsEmpty(_ snapshot: HermesJSON, identity: SessionIdentity, owner: Int) async throws {
        // ca678285 _resume_live_unpersisted omits running/inflight, and its omitted
        // wire messages also mask the actual memory count. Never infer idle from that shape.
        guard exact(snapshot["info"]["profile_name"].text, identity.profile.text),
              snapshot["messages"].list?.isEmpty == true, noDraftWork(snapshot),
              let runtime = createdRuntimes[identity] else { throw HermesServiceError.rejected(404) }
        let socket = try readyGateway(), selection = selectionGeneration
        let proof = try await socket.call("session.activate", ["profile": .string(identity.profile.text),
            "session_id": .string(runtime.text), "omit_messages": .bool(true)], timeoutPolicy: .requestOnly,
            validate: { try self.checkSelection(selection, connection: owner) })
        try checkSelection(selection, connection: owner)
        // activate's _live_session_payload reports running plus the actual memory-history count.
        guard freshEmpty.contains(identity), createdRuntimes[identity] == runtime,
              exact(proof["session_id"].text, runtime.text),
              exact(proof["stored_session_id"].text ?? proof["session_key"].text, identity.stored.text),
              proof["info"]["profile_name"].text.map({ exact($0, identity.profile.text) }) != false,
              proof["running"].flag == false, proof["messages_omitted"].flag == true,
              proof["message_count"].integer == 0, proof["messages"].list?.isEmpty == true,
              ["idle", "starting"].contains(proof["status"].text ?? ""), noDraftWork(proof)
        else { throw HermesServiceError.rejected(404) }
    }

    func noDraftWork(_ snapshot: HermesJSON) -> Bool {
        let inflight = snapshot["inflight"]
        return (inflight == .null || inflight.fields?.isEmpty == true)
            && snapshot["queued"] == .null && snapshot["pending_approval"] == .null
            && snapshot["pending_connection"] == .null
            && (snapshot["open_requests"] == .null || snapshot["open_requests"].list?.isEmpty == true)
            && (snapshot["status"] == .null || ["idle", "starting"].contains(snapshot["status"].text ?? ""))
    }

}
