import Foundation

/// The first things a new workspace needs: someone to name its bot, and a provider to think with.
public enum T3FirstRun {
    /// A bot nobody has named, drawn or talked to yet. Everything it reads is shared on the host, so
    /// every device agrees. Space titles don't count: bot.json says what setup chose.
    public static func needsBotSetup(_ bot: BotProfile, spaces: [T3ChannelSummary]) -> Bool {
        bot.name == T3BotBootstrap.defaultManifest.displayName && bot.appearance == nil && !spaces.contains(where: \.hasMessages)
    }

    /// What to say when setup didn't finish. Trying again is always safe.
    public static func message(for error: any Error) -> String {
        error as? T3ServiceError == .invalidName ? "Enter a name." : "That didn’t save. Check the connection, then try again."
    }

    /// Providers to walk someone through, or none while any provider works.
    /// A host that reports nothing isn't asking for help.
    public static func providersNeedingSetup(_ providers: [T3ProviderStatus]) -> [T3ProviderStatus] {
        guard !providers.contains(where: { $0.state == .ready }) else { return [] }
        return providers.filter { $0.guide != nil }
    }
}

/// A model provider on the host, and what it still needs.
public struct T3ProviderStatus: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case ready, needsSignIn, notInstalled, notWorking, off }

    /// The two providers Botto explains how to set up.
    public enum Guide: String, CaseIterable, Sendable {
        case claude = "claudeAgent", codex

        public var name: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            }
        }
        public var installPage: URL {
            switch self {
            case .claude: URL(string: "https://claude.com/product/claude-code")!
            case .codex: URL(string: "https://developers.openai.com/codex/cli")!
            }
        }
        /// What to type in Terminal to sign in.
        public var signInCommand: String {
            switch self {
            case .claude: "claude auth login"
            case .codex: "codex login"
            }
        }
    }

    public let id: String
    public let driver: String
    public let state: State
    public var guide: Guide? { Guide(rawValue: driver) }

    public init(id: String, driver: String, state: State) {
        self.id = id
        self.driver = driver
        self.state = state
    }

    init?(_ provider: HermesJSON) {
        guard let id = provider["instanceId"].nonempty else { return nil }
        let state: State
        if provider["enabled"].flag != true { state = .off }
        else if provider["installed"].flag != true { state = .notInstalled }
        else if Self.isSignedOut(provider) { state = .needsSignIn }
        else if provider["models"].list?.isEmpty == false, provider["status"].text != "error" { state = .ready }
        else { state = .notWorking }
        self.init(id: id, driver: provider["driver"].text ?? "", state: state)
    }

    /// Only a provider that says so. Some can't tell.
    static func isSignedOut(_ provider: HermesJSON) -> Bool { provider["auth"]["status"].text == "unauthenticated" }
}

extension T3BotBrainControlling {
    /// Names the bot and saves its face in one `bot.json` edit, then gives its main space the same name. The
    /// choices are saved before the space is touched, and a failure can simply be tried again.
    public func setUpBot(name: String, face: BotFace) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw T3ServiceError.invalidName }
        let known = try await bots().first
        var manifest = try await loadBotBrain().manifest
        // Choices another device made since this one last looked stand; saving them again catches it up.
        if manifest.displayName == known?.name, manifest.avatar == known?.appearance {
            manifest.displayName = name
            manifest.avatar = BotAvatarChoice.face(face).applying(to: manifest.avatar ?? BotAppearance())
        }
        try await saveManifest(manifest)
        // Even to the same title: it is what tells the other connected devices.
        if let main = currentT3Channels.first(where: \.isMain) {
            try await renameChannel(threadID: main.id, title: manifest.displayName)
        }
    }
}
