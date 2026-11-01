import Foundation

extension HermesBotService {
    public func conversations(profile: ExactID) async throws -> ConversationDirectory {
        let owner = connectionGeneration
        if let pending = catalogReads[profile], pending.owner == owner { return try await pending.task.value }
        catalogReads[profile]?.task.cancel()
        let task = Task { try await self.readDirectory(profile: profile, owner: owner) }
        let id = UUID()
        catalogReads[profile] = .init(id: id, owner: owner, task: task)
        defer { if catalogReads[profile]?.id == id { catalogReads[profile] = nil } }
        return try await task.value
    }

    func readDirectory(profile: ExactID, owner: Int) async throws -> ConversationDirectory {
        let socket = try readyGateway()
        guard let http else { throw HermesServiceError.disconnected }
        var summaries: [SessionSummary] = []
        var warning: String?
        var complete = true
        var total: Int?
        let canonical = try await canonicalRows(profile: profile.text, socket: socket)
        try checkConnection(owner)
        guard canonical.count == 1, let row = canonical.first else { throw HermesServiceError.missingChat }
        let main = try sessionSummary(row, profile: profile, canonical: true)
        merge(main, into: &summaries)
        var observed = summaries
        var observedTips: Set<SessionIdentity> = []
        if row["profile"].text.map({ exact($0, profile.text) }) != false,
           row["profile_name"].text.map({ exact($0, profile.text) }) != false,
           let count = main.messageCount, count >= 0 { observedTips.insert(main.identity) }
        do {
            var offset = 0
            repeat {
                let page = try await http.json("api/sessions", query: Self.directoryQuery(profile: profile, limit: 100, offset: offset, order: "recent"))
                try checkConnection(owner)
                guard let rows = page["sessions"].list, let count = page["total"].integer, count >= 0,
                      page["offset"].integer == offset, page["limit"].integer == 100 else { throw HermesServiceError.incompatible }
                if total == nil { total = count }
                for row in rows where row["archived"].flag != true {
                    guard row["profile"].text.map({ exact($0, profile.text) }) != false,
                          row["profile_name"].text.map({ exact($0, profile.text) }) != false else { throw HermesServiceError.wrongConversation }
                    let summary = try sessionSummary(row, profile: profile, canonical: false)
                    observedTips.insert(summary.identity)
                    merge(summary, into: &observed)
                    // A REST row proves persistence, so this is no longer an unpersisted draft exception.
                    for known in freshEmpty where known.profile == profile && !known.aliases.isDisjoint(with: summary.identity.aliases) {
                        freshEmpty.remove(known); createdRuntimes[known] = nil
                    }
                    merge(summary, into: &summaries)
                }
                // Pin backfills repeat and can exceed the requested window. Never advance by returned count.
                offset += 100
                if offset >= 100_000, offset < (total ?? 0) {
                    complete = false; warning = "Only the first 100,000 stored chats were scanned."; break
                }
            } while offset < (total ?? 0)
        } catch {
            try checkConnection(owner)
            complete = false; warning = "Stored chats could not be fully refreshed. Showing known chats."
            for old in catalogs[profile]?.summaries ?? [] { retainKnown(old, into: &summaries) }
        }
        for created in knownCreated[profile] ?? [] { retainKnown(created, into: &summaries) }
        // Retained creations can appear in the directory before a stored inventory row
        // exists. Their locally constructed count is not an inventory observation.
        observedInventory[profile] = observed.filter { summary in
            observedTips.contains { sameInventoryTip($0, summary.identity) }
        }
        for summary in summaries {
            for alias in summary.identity.aliases { knownAliasOwners[alias, default: []].insert(profile) }
        }
        // Publish alias knowledge before joining the process-wide sidecar activity sample.
        catalogs[profile] = ConversationDirectory(summaries: summaries, activity: [:], isComplete: complete, warning: warning)
        let activity = await sampleActivity(profile: profile, socket: socket, owner: owner)
        try checkConnection(owner)
        let directory = ConversationDirectory(summaries: summaries, activity: activity, isComplete: complete,
            warning: warning ?? (activity.values.contains { if case .unknown = $0 { true } else { false } } ? "Some chat activity could not be verified." : nil))
        catalogs[profile] = directory
        catalogCounts[profile] = complete ? total : nil
        return directory
    }

    static func directoryQuery(profile: ExactID, limit: Int, offset: Int, order: String) -> [URLQueryItem] {
        [URLQueryItem(name: "profile", value: profile.text), URLQueryItem(name: "limit", value: String(limit)),
         URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "order", value: order),
         URLQueryItem(name: "archived", value: "exclude"), URLQueryItem(name: "min_messages", value: "0"),
         URLQueryItem(name: "exclude_sources", value: "cron,kanban,oneshot,subagent,tool")]
    }

    func sessionSummary(_ row: HermesJSON, profile: ExactID, canonical: Bool) throws -> SessionSummary {
        guard let id = row["id"].nonempty else { throw HermesServiceError.incompatible }
        let root = try ExactID(row["_lineage_root_id"].nonempty ?? id)
        let stored = try ExactID(row["resolved_id"].nonempty ?? id)
        var aliases = Set(try (row["_lineage_ids"].list ?? []).compactMap(\.nonempty).map(ExactID.init))
        aliases.formUnion([root, stored, try ExactID(id)])
        return SessionSummary(identity: SessionIdentity(profile: profile, root: root, stored: stored, aliases: aliases),
            title: canonical ? "Main" : (row["title"].nonempty ?? "New Chat"), isCanonical: canonical, persistence: .durable,
            preview: row["preview"].text, updatedAt: row["last_active"].date ?? row["last_activity_at"].date,
            messageCount: row["message_count"].integer)
    }

    func retainKnown(_ known: SessionSummary, into rows: inout [SessionSummary]) {
        if let fresh = rows.first(where: { $0.identity.profile == known.identity.profile &&
            ($0.identity.root == known.identity.root || !$0.identity.aliases.isDisjoint(with: known.identity.aliases)) }) {
            let identity = SessionIdentity(profile: fresh.identity.profile, root: fresh.identity.root, stored: fresh.identity.stored,
                aliases: fresh.identity.aliases.union(known.identity.aliases))
            let merged = SessionSummary(identity: identity, title: fresh.title, isCanonical: fresh.isCanonical,
                persistence: fresh.persistence, preview: fresh.hasPreview == true ? fresh.preview : nil,
                updatedAt: fresh.updatedAt, messageCount: fresh.messageCount)
            rows.removeAll { $0.identity == fresh.identity }; merge(merged, into: &rows)
        } else { merge(known, into: &rows) }
    }

    func merge(_ incoming: SessionSummary, into rows: inout [SessionSummary]) {
        var merged = incoming
        let matches = rows.filter {
            $0.identity.profile == incoming.identity.profile &&
                ($0.identity.root == incoming.identity.root || !$0.identity.aliases.isDisjoint(with: incoming.identity.aliases))
        }
        for old in matches {
            let canonical = old.isCanonical || merged.isCanonical
            let root = old.isCanonical ? old.identity.root : merged.identity.root
            let preferred = merged.persistence == .liveOnly && old.persistence == .durable ? old : merged
            merged = SessionSummary(identity: SessionIdentity(profile: incoming.identity.profile, root: root,
                stored: preferred.identity.stored, aliases: old.identity.aliases.union(merged.identity.aliases)),
                title: canonical ? "Main" : preferred.title, isCanonical: canonical, persistence: preferred.persistence,
                preview: preferred.hasPreview == true ? preferred.preview : nil,
                updatedAt: preferred.updatedAt, messageCount: preferred.messageCount)
        }
        rows.removeAll { old in matches.contains { $0.identity == old.identity } }
        if merged.isCanonical { rows.insert(merged, at: 0) } else { rows.append(merged) }
    }

    public func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession {
        try Task.checkCancellation()
        return try await Task { try await self.createSession(profile: profile, operationID: operationID) }.value
    }

    func createSession(profile: ExactID, operationID: UUID) async throws -> CreatedSession {
        let socket = try readyGateway(), owner = connectionGeneration
        let dialect = adapter
        guard creatingSessions.insert(profile).inserted else { throw HermesServiceError.staleConversation }
        defer { creatingSessions.remove(profile) }
        try claimOperation(operationID)
        let reply = try await socket.call("session.create", dialect.ordinaryCreate(profile: profile.text, operationID: operationID),
            mutation: true, validate: { try self.checkConnection(owner) })
        guard let runtime = reply["session_id"].nonempty,
              let stored = reply["stored_session_id"].nonempty ?? reply["session_key"].nonempty ?? (dialect == .authority ? runtime : nil),
              reply["info"]["profile_name"].text.map({ exact($0, profile.text) }) != false else { throw HermesServiceError.uncertain }
        let key = try ExactID(stored)
        let identity = SessionIdentity(profile: profile, root: key, stored: key, aliases: [key])
        let summary = SessionSummary(identity: identity, title: "New Chat", isCanonical: false,
            persistence: dialect == .sidecar ? .liveOnly : .durable, messageCount: 0)
        // An identified creation stays in its origin inventory even if the caller has navigated away.
        if owner == connectionGeneration {
            var rows = knownCreated[profile] ?? []; merge(summary, into: &rows); knownCreated[profile] = rows
            runtimeOwners[try ExactID(runtime)] = identity
            if dialect == .sidecar { freshEmpty.insert(identity); createdRuntimes[identity] = try ExactID(runtime) }
            onEvent?(.botsChanged)
        }
        await cleanupAttachment(reply, profile: profile.text, socket: socket)
        return CreatedSession(operationID: operationID, summary: summary)
    }
}
