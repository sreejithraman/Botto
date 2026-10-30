import Foundation

extension HermesBotService {
    func sampleActivity(profile: ExactID, socket: HermesGateway, owner: Int) async -> [SessionIdentity: ObservedActivity] {
        let summaries = catalogs[profile]?.summaries ?? []
        let params: [String: HermesJSON] = adapter == .authority ? ["profile": .string(profile.text)] : [:]
        let reply = try? await socket.call("session.active_list", params, timeoutPolicy: .requestOnly,
            validate: { try self.checkConnection(owner) })
        return observedActivity(profile: profile, summaries: summaries, rows: reply?["sessions"].list)
    }

    func observedActivity(profile: ExactID, summaries: [SessionSummary], rows: [HermesJSON]?,
                          at date: Date = Date()) -> [SessionIdentity: ObservedActivity] {
        guard let rows else {
            return Dictionary(uniqueKeysWithValues: summaries.map { ($0.identity, .unknown("Activity unavailable")) })
        }
        var result: [SessionIdentity: ObservedActivity] = [:]
        for summary in summaries {
            var ambiguous = false, statuses: [BotStatus] = []
            for row in rows {
                guard let stored = row["session_key"].nonempty, let key = try? ExactID(stored) else { ambiguous = true; continue }
                if adapter == .authority, !summary.identity.aliases.contains(key), summary.identity.root != key { continue }
                guard let status = Self.liveStatus(row["status"].text) else { ambiguous = true; continue }
                let runtime = row["id"].nonempty.flatMap { try? ExactID($0) }
                if adapter == .authority {
                    if summary.identity.aliases.contains(key) || summary.identity.root == key { statuses.append(status) }
                } else if let runtime, let verified = runtimeOwners[runtime] {
                    if verified.profile == profile, verified.root == summary.identity.root { statuses.append(status) }
                } else {
                    let candidates = catalogs.values.flatMap(\.summaries).filter { $0.identity.aliases.contains(key) || $0.identity.root == key }
                    let owners = Set(candidates.map { $0.identity.profile }).union(knownAliasOwners[key] ?? [])
                    if owners.count == 1 {
                        if owners.first == profile, summary.identity.aliases.contains(key) || summary.identity.root == key { statuses.append(status) }
                    } else { ambiguous = true }
                }
            }
            if let status = Self.strongest(statuses) { result[summary.identity] = .known(status, date) }
            else if !ambiguous { result[summary.identity] = .known(.idle, date) }
            else { result[summary.identity] = .unknown("A live session could not be attributed to this chat") }
        }
        return result
    }

    func publishActivity(profiles: [HermesJSON], replies: [ExactID: HermesJSON], owner: Int, socket: HermesGateway) throws {
        var updates: [ProfileActivityUpdate] = []
        for row in profiles {
            guard let name = row["name"].nonempty, let profile = try? ExactID(name) else { continue }
            var summaries = catalogs[profile]?.summaries ?? []
            for created in knownCreated[profile] ?? [] { retainKnown(created, into: &summaries) }
            if let canonical = try? sessionSummary(row["canonical_session"], profile: profile, canonical: true) {
                // Fresh directory lineage metadata remains the stronger identity observation.
                retainKnown(canonical, into: &summaries)
            }
            if let identity = selectedTarget, identity.profile == profile, !summaries.contains(where: { $0.identity.root == identity.root }) {
                summaries.append(SessionSummary(identity: identity, title: "", isCanonical: selectedCanonical, persistence: .unknown))
            }
            let date = Date()
            var values = observedActivity(profile: profile, summaries: summaries, rows: replies[profile]?["sessions"].list, at: date)
            if attached, let identity = selectedTarget, identity.profile == profile, let state,
               let selected = summaries.first(where: { $0.identity.root == identity.root }) {
                values[selected.identity] = .known(state.conversation.pendingRequests.isEmpty
                    ? (state.conversation.isWorking ? .working : .idle) : .waiting, date)
            }
            updates.append(.init(profile: profile, observations: values))
        }
        try checkConnection(owner)
        guard socket.isOpen else { throw HermesServiceError.disconnected }
        onEvent?(.activityBatch(updates))
        try checkConnection(owner)
        guard socket.isOpen else { throw HermesServiceError.disconnected }
    }

    func matchesSelectedActivity(_ row: HermesJSON, profile: String, canonicalKeys: [String: Set<String>]) -> Bool {
        guard attached, let state, exact(state.conversation.profileID, profile),
              !selectedCanonical || canonicalKeys[profile]?.contains(state.root) != false else { return false }
        return [row["id"].text, row["session_key"].text].compactMap { $0 }.contains {
            exact($0, state.root) || exact($0, state.conversation.storedID) || exact($0, state.conversation.id)
        }
    }

    static func strongest(_ statuses: [BotStatus]) -> BotStatus? {
        if statuses.contains(.waiting) { return .waiting }
        if statuses.contains(.working) { return .working }
        return statuses.contains(.idle) ? .idle : nil
    }
}
