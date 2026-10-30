import Foundation

extension HermesBotService {
    public func updateProfile(_ edit: BotProfileEdit, for bot: BotProfile) async throws -> BotProfile {
        guard edit.name != nil || edit.description != nil else { return bot }
        let name = edit.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name?.isEmpty != true else { throw HermesServiceError.invalidProfileName }
        guard Self.safeSegment(bot.id), !savingAvatars.contains(bot.id) else { throw HermesServiceError.profileConflict }
        let socket = try readyGateway(), owner = connectionGeneration
        savingAvatars.insert(bot.id)
        defer { if owner == connectionGeneration { savingAvatars.remove(bot.id) } }
        var row = try await appearanceRow(profile: bot.id, socket: socket, owner: owner)
        guard let fresh = Self.profile(row), let revision = Self.appearanceRevision(row) else { throw HermesServiceError.incompatible }
        guard edit.name == nil || fresh.name.utf8.elementsEqual(bot.name.utf8),
              edit.description == nil || fresh.description.utf8.elementsEqual(bot.description.utf8) else {
            throw HermesServiceError.profileConflict
        }
        var params: [String: HermesJSON] = ["name": .string(bot.id)]
        if let name {
            var look = row["ui_meta"]["hermes-bots"].fields ?? [:]
            look["title"] = .string(name)
            params["ui_meta"] = .object(["hermes-bots": .object(look)])
            params["ui_meta_expected_revisions"] = .object(["hermes-bots": .number(Double(revision))])
        }
        if let description = edit.description {
            params["description"] = .string(description.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let reply: HermesJSON
        do {
            reply = try await socket.call("profiles.configure", params, mutation: true,
                                          validate: { try self.checkConnection(owner) })
            try checkConnection(owner)
        } catch HermesServiceError.rejected(let code) { throw HermesServiceError.rejected(code) }
        catch { throw HermesServiceError.uncertainProfile }
        let applied = reply["applied"]
        let nameSaved = name == nil || applied["ui_meta"].flag == true
        let descriptionSaved = edit.description == nil || applied["description"].flag == true
        guard nameSaved && descriptionSaved else {
            if edit.description == nil, applied["ui_meta_conflicts"] != .null { throw HermesServiceError.profileConflict }
            throw HermesServiceError.partialProfile
        }
        if name != nil {
            row["ui_meta"]["hermes-bots"] = params["ui_meta"]?["hermes-bots"] ?? .null
            row["ui_meta_revisions"]["hermes-bots"] = applied["ui_meta_revisions"]["hermes-bots"]
        }
        if edit.description != nil { row["description"] = params["description"] ?? .null }
        guard let saved = Self.profile(row) else { throw HermesServiceError.partialProfile }
        onEvent?(.botsChanged)
        return saved
    }
}
