import Foundation

extension HermesBotService {
    struct DirectoryProbe: Equatable, Sendable {
        let count: Int
        let identities: Set<SessionIdentity>
    }

    func publishDirectoryChanges(profiles: [HermesJSON], owner: Int, socket: HermesGateway) async throws {
        guard let http else { throw HermesServiceError.disconnected }
        let active = Set(profiles.compactMap { $0["name"].nonempty.flatMap { try? ExactID($0) } })
        catalogCounts = catalogCounts.filter { active.contains($0.key) }
        discoveryHints = discoveryHints.filter { active.contains($0.key) }
        let replies = await withTaskGroup(of: (ExactID, HermesJSON?).self) { group in
            for profile in active where catalogCounts[profile] != nil {
                group.addTask {
                    let reply = try? await http.json("api/sessions",
                        query: Self.directoryQuery(profile: profile, limit: 1, offset: 0, order: "created"))
                    return (profile, reply)
                }
            }
            var result: [(ExactID, HermesJSON?)] = []
            for await reply in group { result.append(reply) }
            return result
        }
        for (profile, reply) in replies {
            try checkConnection(owner)
            guard socket.isOpen else { throw HermesServiceError.disconnected }
            guard let probe = try? directoryProbe(reply, profile: profile),
                  let count = catalogCounts[profile], let directory = catalogs[profile] else { continue }
            let covered = probe.count == count && probe.identities.allSatisfy { incoming in
                directory.summaries.contains { known in
                    known.identity.stored == incoming.stored &&
                        (known.identity.root == incoming.root || !known.identity.aliases.isDisjoint(with: incoming.aliases))
                }
            }
            if covered { discoveryHints[profile] = nil; continue }
            guard discoveryHints[profile] != probe else { continue }
            discoveryHints[profile] = probe
            catalogReads.removeValue(forKey: profile)?.task.cancel()
            onEvent?(.conversationDirectoryChanged(profile: profile))
        }
        try checkConnection(owner)
        guard socket.isOpen else { throw HermesServiceError.disconnected }
    }

    private func directoryProbe(_ reply: HermesJSON?, profile: ExactID) throws -> DirectoryProbe {
        guard let reply, let count = reply["total"].integer, count >= 0,
              reply["limit"].integer == 1, reply["offset"].integer == 0,
              reply["storage"] == .null || reply["storage"].fields?.isEmpty == true,
              let rows = reply["sessions"].list, count == 0 || !rows.isEmpty else { throw HermesServiceError.incompatible }
        var identities: Set<SessionIdentity> = []
        for row in rows {
            guard row["profile"].text.map({ exact($0, profile.text) }) != false,
                  row["profile_name"].text.map({ exact($0, profile.text) }) != false else { throw HermesServiceError.wrongConversation }
            if row["archived"].flag == true { continue }
            identities.insert(try sessionSummary(row, profile: profile, canonical: false).identity)
        }
        guard count == 0 || !identities.isEmpty else { throw HermesServiceError.incompatible }
        return .init(count: count, identities: identities)
    }
}
