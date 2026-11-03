import Foundation

public enum BotAvatarGenerationError: Error, LocalizedError, Equatable, Sendable {
    case invalidDescription, alreadyGenerating, unsupportedHost, missingChat, invalidResult, failed, timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidDescription: "Describe a character using 1–1,000 characters."
        case .alreadyGenerating: "A character is already being created for this bot."
        case .unsupportedHost: "This Hermes connection cannot create characters in Botto. Update Hermes and reconnect through its gateway, then try again."
        case .missingChat: "This bot needs a unique Main chat before creating a character. Open its chat in Hermes Desktop, then refresh."
        case .invalidResult: "Hermes returned an invalid character. Your previous avatar is unchanged. Try a simpler description."
        case .failed: "Hermes couldn’t create this character. Check its model configuration, then try again."
        case .timedOut: "Creating the character took too long. Your previous avatar is unchanged. Try again when Hermes is ready."
        }
    }
}

extension HermesBotService {
    public func generateAvatar(description: String, for bot: BotProfile) async throws -> BotAvatarGeometry {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, description.count <= 1_000, description.utf8.count <= 4_096 else {
            throw BotAvatarGenerationError.invalidDescription
        }
        guard Self.safeSegment(bot.id) else { throw HermesServiceError.profileUnavailable }
        let socket = try readyGateway(), owner = connectionGeneration
        // Older sidecars can silently use an auxiliary route for a cold session.
        guard adapter == .authority else { throw BotAvatarGenerationError.unsupportedHost }
        guard avatarGenerations[bot.id] == nil else { throw BotAvatarGenerationError.alreadyGenerating }
        let attempt = UUID()
        avatarGenerations[bot.id] = attempt
        defer { if avatarGenerations[bot.id] == attempt { avatarGenerations[bot.id] = nil } }
        do {
            let instructions = try Self.avatarGenerationInstructions()
            let session = try await avatarGenerationSession(for: bot, socket: socket, owner: owner)
            try checkAvatarGeneration(owner: owner, socket: socket)
            let result = try await socket.call("llm.oneshot", [
                "profile": .string(bot.id), "session_id": .string(session),
                "instructions": .string(instructions), "input": .string(description),
                "max_tokens": .number(3_072), "temperature": .number(0.5), "task": .string("botto_avatar")
            ], timeoutPolicy: .requestOnly, timeout: timing.avatarGeneration,
                validate: { try self.checkAvatarGeneration(owner: owner, socket: socket) })
            try checkAvatarGeneration(owner: owner, socket: socket)
            guard let text = result["text"].text, text.utf8.count <= 8_192 else { throw BotAvatarGenerationError.invalidResult }
            do {
                let geometry = try BotAvatarGeometry(json: text)
                let validated = try await withAvatarRendererRecovery(socket: socket, owner: owner) {
                    try await self.avatarEngine.validate(geometry)
                }
                _ = try await withAvatarRendererRecovery(socket: socket, owner: owner) {
                    try await self.avatarEngine.prepare(validated)
                }
                return validated
            } catch is BotAvatarGeometry.DefinitionError {
                try checkAvatarGeneration(owner: owner, socket: socket)
                throw BotAvatarGenerationError.invalidResult
            } catch BotAvatarEngineError.invalidDefinition(_) {
                try checkAvatarGeneration(owner: owner, socket: socket)
                throw BotAvatarGenerationError.invalidResult
            }
        } catch HermesServiceError.rejected(-32601) {
            throw BotAvatarGenerationError.unsupportedHost
        } catch HermesServiceError.rejected(5030) {
            throw BotAvatarGenerationError.failed
        } catch HermesServiceError.timeout {
            throw BotAvatarGenerationError.timedOut
        }
    }

    private func avatarGenerationSession(for bot: BotProfile, socket: HermesGateway, owner: Int) async throws -> String {
        if attached, let current = state?.conversation, exact(current.profileID, bot.id) { return current.id }
        let reply = try await socket.call("session.list", ["profile": .string(bot.id),
            "title": .string("Bot Chat"), "include_hidden": .bool(true)], timeoutPolicy: .requestOnly,
            validate: { try self.checkAvatarGeneration(owner: owner, socket: socket) })
        try checkAvatarGeneration(owner: owner, socket: socket)
        guard let rows = reply["sessions"].list, rows.count == 1, let row = rows.first else {
            throw BotAvatarGenerationError.missingChat
        }
        guard row["profile"].text.map({ exact($0, bot.id) }) != false,
              row["profile_name"].text.map({ exact($0, bot.id) }) != false else { throw HermesServiceError.wrongConversation }
        return try sessionSummary(row, profile: ExactID(bot.id), canonical: true).identity.root.text
    }

    private func checkAvatarGeneration(owner: Int, socket: HermesGateway) throws {
        try Task.checkCancellation()
        try checkConnection(owner)
        guard gateway === socket, socket.isOpen else { throw HermesServiceError.disconnected }
    }

    func canonicalAvatarChoice(_ choice: BotAvatarChoice, socket: HermesGateway, owner: Int) async throws -> BotAvatarChoice {
        guard case .geometry(let geometry, let color) = choice else { return choice }
        do {
            let validated = try await withAvatarRendererRecovery(socket: socket, owner: owner) {
                try await self.avatarEngine.validate(geometry)
            }
            return .geometry(validated, color: color)
        } catch BotAvatarEngineError.invalidDefinition(_) {
            try checkAvatarGeneration(owner: owner, socket: socket)
            throw HermesServiceError.invalidAvatar
        }
    }

    func staticAvatarPreview(_ appearance: BotAppearance, profileID: String,
                             socket: HermesGateway, owner: Int) async throws -> BotAvatarAsset? {
        guard let geometry = appearance.geometry else { return nil }
        let asset = try await withAvatarRendererRecovery(socket: socket, owner: owner) {
            try await self.avatarEngine.prepare(geometry)
        }
        let color = appearance.face(for: profileID).color
        let render = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try BotAvatarStaticPreview.render(asset, color: color)
        }
        let preview = try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
        try checkAvatarGeneration(owner: owner, socket: socket)
        return preview
    }

    private func withAvatarRendererRecovery<Value: Sendable>(socket: HermesGateway, owner: Int,
        operation: @MainActor () async throws -> Value) async throws -> Value {
        var failures = 0
        while true {
            try checkAvatarGeneration(owner: owner, socket: socket)
            do {
                let value = try await operation()
                try checkAvatarGeneration(owner: owner, socket: socket)
                return value
            } catch {
                try checkAvatarGeneration(owner: owner, socket: socket)
                switch error {
                case BotAvatarEngineError.unavailable, BotAvatarEngineError.invalidFrame:
                    guard failures < 2 else { throw error }
                    failures += 1
                    try await Task.sleep(for: .milliseconds(250 * failures))
                default: throw error
                }
            }
        }
    }

    // Canonical prompt pinned to Open Bot Avatar 3a511987; MIT; see THIRD_PARTY_NOTICES.md.
    private static func avatarGenerationInstructions() throws -> String {
        guard let url = Bundle.module.url(forResource: "OpenBotAvatarPrompt", withExtension: "md"),
              let canonical = try? String(contentsOf: url, encoding: .utf8) else {
            throw BotAvatarGenerationError.unsupportedHost
        }
        return "Botto avatar geometry\n\n" + canonical
    }
}
