import Foundation

extension HermesBotService {
    /// Cache descriptors name a target. Only server metadata, creation receipts, or
    /// previously verified attachments can prove that its root and segments belong together.
    func storedIdentityProof(_ target: SessionIdentity, selection: Int, connection: Int) async throws -> SessionIdentity {
        if let proven = knownIdentityProof(target) { return proven }
        _ = try await conversations(profile: target.profile)
        try checkSelection(selection, connection: connection)
        guard let proven = knownIdentityProof(target) else { throw HermesServiceError.wrongConversation }
        return proven
    }

    func knownIdentityProof(_ target: SessionIdentity, returnedStored: ExactID? = nil) -> SessionIdentity? {
        let candidates = (catalogs[target.profile]?.summaries.map(\.identity) ?? [])
            + (knownCreated[target.profile]?.map(\.identity) ?? [])
            + runtimeOwners.values.filter { $0.profile == target.profile }
        var requested = target.aliases
        requested.formUnion([target.root, target.stored])
        if let returnedStored { requested.insert(returnedStored) }
        guard let proof = candidates.first(where: {
            $0.profile == target.profile && requested.isSubset(of: $0.aliases.union([$0.root, $0.stored]))
        }) else { return nil }
        return SessionIdentity(profile: proof.profile, root: target.root, stored: returnedStored ?? target.stored,
            aliases: proof.aliases.union([proof.root, proof.stored]))
    }
}
