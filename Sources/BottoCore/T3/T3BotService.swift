import Foundation

public enum T3ServiceError: Error, Equatable, LocalizedError, Sendable {
    case missingConnection, differentEnvironment, differentWorkspace, disconnected, invalidProject, invalidResponse
    case missingModel, missingChannel, mainSpaceSynchronizing, invalidName, unsupported
    case mainSpaceRecoveryRequired
    case invalidPath, proseChanged
    case protectedMainSpace

    public var errorDescription: String? {
        switch self {
        case .missingConnection: "Pair Botto with a T3 Code environment first."
        case .differentEnvironment: "This address belongs to a different T3 Code environment. Pair it again."
        case .differentWorkspace: "Botto’s saved workspace changed. Pair again to open it."
        case .disconnected: "Reconnect to T3 Code to continue."
        case .invalidProject: "T3 Code returned an invalid bot project."
        case .invalidResponse: "T3 Code returned unexpected data."
        case .missingModel: "Set up a model on the T3 Code host before starting a space."
        case .missingChannel: "This space is no longer available."
        case .mainSpaceSynchronizing: "The Main Space is still syncing. Try opening it again."
        case .mainSpaceRecoveryRequired:
            "T3 Code has reserved the Main Space’s replacement ID. Set mainThreadID in the Botto project’s bot.json to an active Space’s T3 thread ID, then reopen Botto."
        case .invalidName: "Enter a name."
        case .unsupported: "This action requires T3 Code."
        case .invalidPath: "Choose a file inside the bot project."
        case .proseChanged: "This file changed elsewhere. Copy your edits before reloading it from the host."
        case .protectedMainSpace: "The main space stays. You can rename it instead."
        }
    }
}

@MainActor public final class T3BotService: BotService {
    public typealias WebSocketFactory = @Sendable (URLRequest) throws -> any T3WebSocketTransport
    public var onEvent: ((BotServiceEvent) -> Void)?
    public var onPushActivity: ((T3PushActivity) -> Void)?
    public var currentPushScope: T3PushScope? {
        guard let session, session.ready else { return nil }
        return pushScope(session)
    }
    private var pushObserver: T3PushObserver?
    public private(set) var currentT3Channels: [T3ChannelSummary] = []
    public var currentBotWorkspaceRoot: String? { session.flatMap { $0.ready ? $0.workspace : nil } }

    @MainActor fileprivate final class Session {
        let rpc: T3RPCClient
        let profile: ExactID
        let issuer = ConversationIssuer<SessionIdentity>()
        let origin: URL
        let token: String
        let workspace: String
        var configuration: ConnectionConfiguration
        var config: JSONValue
        var project: JSONValue
        var manifest = T3BotBootstrap.defaultManifest
        var shellTask: Task<Void, Never>?
        var pushTasks: [String: Task<Void, Never>] = [:]
        var shellFailure: Error?
        var shells: [String: JSONValue] = [:]
        var archivedShells: [String: JSONValue] = [:]
        var archiveSnapshotSequence: Int?
        var archiveRefresh: Task<Void, Never>?
        var workflowWrites: Set<UUID> = []
        var workflowAnswers: Set<String> = []
        var ready = false
        /// Profile edits apply one at a time, each to the manifest the previous one saved.
        var manifestTail: Task<Void, Error>?
        /// Autosaved brain files write in order; an edit superseded while it waits is skipped.
        var fileWrites: [String: (token: UUID, tail: Task<Void, Error>)] = [:]
        var selection: Selection?
        var selectedIdentity: SessionIdentity?
        var openAttempt = UUID()
        var previews: [String: ConversationPreview] = [:]
        var attachments: [UUID: StagedAttachment] = [:]

        init(rpc: T3RPCClient, profile: ExactID, origin: URL, token: String, configuration: ConnectionConfiguration,
             config: JSONValue, project: JSONValue, workspace: String) {
            self.rpc = rpc
            self.profile = profile
            self.origin = origin
            self.token = token
            self.configuration = configuration
            self.config = config
            self.project = project
            self.workspace = workspace
        }

        func subscribeThread(_ id: String) async throws -> T3RPCClient.Stream {
            try await rpc.subscribe("orchestration.subscribeThread", payload: .object([
                "threadId": .string(id), "requestCompletionMarker": .bool(true),
                "acceptBoundedSnapshot": .bool(config["threadSnapshotPagination"].flag == true)
            ]))
        }
    }

    @MainActor fileprivate final class Selection {
        let identity: SessionIdentity
        let lineage = UUID()
        var task: Task<Void, Never>?
        var streamFailure: Error?
        var projection: T3ThreadProjection?
        var access: ConversationAccess?
        var isSynchronized = false

        init(identity: SessionIdentity) { self.identity = identity }
    }

    fileprivate struct StagedAttachment {
        let attachment: ChatAttachment
        let wire: JSONValue
        let identity: SessionIdentity
    }

    private let http: T3PairingExchange
    private let webSocket: WebSocketFactory
    private let reconnectDelays: [Duration]
    private var connectionAttempt = UUID()
    private var connectingRPC: T3RPCClient?
    private var reconnectTask: Task<Void, Never>?
    private var session: Session?
    /// Bots whose prompts were rewritten for an edit that never reached bot.json.
    private var unsettledPrompts: Set<ExactID> = []

    public init(transport: @escaping T3PairingExchange.HTTPTransport = T3PairingExchange.directHTTP,
                webSocket: @escaping WebSocketFactory = { T3URLSessionWebSocketTransport(request: $0) },
                reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]) {
        http = T3PairingExchange(transport: transport)
        self.webSocket = webSocket
        self.reconnectDelays = reconnectDelays
    }

    public func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        disconnect()
        return try await establish(configuration, attempt: connectionAttempt, reattaching: nil)
    }

    private func establish(_ configuration: ConnectionConfiguration, attempt: UUID,
                           reattaching identity: SessionIdentity?) async throws -> ServerInfo {
        guard var paired = configuration.t3, !paired.accessToken.isEmpty else { throw T3ServiceError.missingConnection }
        let primary = try T3PairingExchange.validatedOrigin(configuration.serverURL.absoluteString)
        try checkAttempt(attempt)
        let token = paired.accessToken
        // The token is sent only once a route has answered as the paired environment. A route that
        // answers but can't mint a ticket, open the socket, return its config as that environment, or
        // list its projects counts as failed, and the next is tried. Nothing in the workspace is
        // written until a route has made all of those reads.
        let (origin, descriptor, rpc, config, projects) = try await http.reach(
            configuration.connectionRoutes, environmentID: paired.environmentID.isEmpty ? nil : paired.environmentID,
            isRouteFailure: T3UnreachableRoutes.isRouteFailure
        ) { origin, descriptor in
            try checkAttempt(attempt)
            let ticket = try await http.mintWebSocketTicket(origin: origin, accessToken: token)
            try checkAttempt(attempt)
            let request = try T3RPCClient.socketRequest(origin: origin, ticket: ticket.ticket, accessToken: token)
            let rpc = T3RPCClient(transport: try webSocket(request))
            connectingRPC = rpc
            do {
                let config = try await rpc.call("server.getConfig")
                // A route is chosen only once its own config names the environment it answered as.
                switch config["environment"]["environmentId"].text {
                case descriptor.environmentId: break
                case nil: throw T3ServiceError.invalidResponse
                default: throw T3ServiceError.differentEnvironment
                }
                try checkAttempt(attempt)
                let projects = try await listProjects(origin: origin, token: token)
                try checkAttempt(attempt)
                return (origin, descriptor, rpc, config, projects)
            } catch {
                if connectingRPC === rpc { connectingRPC = nil }
                await rpc.close()
                throw error
            }
        }

        do {
            let project = try await resolveProject(in: projects, paired: paired, rpc: rpc, attempt: attempt,
                                                   environmentID: descriptor.environmentId)
            guard let id = project["id"].nonempty, let root = project["workspaceRoot"].nonempty else {
                throw T3ServiceError.invalidProject
            }
            var updated = configuration
            updated.serverURL = primary
            updated.reached(origin)
            updated.installID = descriptor.environmentId
            paired.environmentID = descriptor.environmentId
            paired.label = descriptor.label
            paired.projectID = id
            paired.workspaceRoot = root
            updated.t3 = paired
            let connected = Session(rpc: rpc, profile: try ExactID(id), origin: origin, token: token, configuration: updated,
                                    config: config, project: project, workspace: root)
            session = connected
            connectingRPC = nil
            try await subscribeToShell(connected)
            try await bootstrap(connected)
            try? await refreshArchive(connected)
            // A host that can't hold a main space yet (no model, a refused command) still connects.
            try? await ensureMain(connected)
            try checkAttempt(attempt)
            try check(connected)
            if let identity, identity.profile == connected.profile,
               connected.shells[identity.stored.text] != nil || connected.archivedShells[identity.stored.text] != nil {
                _ = try await attach(identity, in: connected, attempt: connected.openAttempt)
            }
            try checkAttempt(attempt)
            try check(connected)
            if let failure = connected.shellFailure ?? connected.selection?.streamFailure { throw failure }
            updateConfiguration(connected)
            connected.ready = true
            syncPushSpaces(connected)
            reconnectTask = nil
            let info = ServerInfo(version: descriptor.serverVersion, installID: descriptor.environmentId)
            if connected.configuration != configuration { onEvent?(.configuration(connected.configuration)) }
            try check(connected)
            onEvent?(.connected(info))
            try check(connected)
            publishDirectory(connected)
            try check(connected)
            if let selection = connected.selection { publishConversation(selection, in: connected) }
            try check(connected)
            return info
        } catch {
            if connectionAttempt == attempt, session?.rpc === rpc || connectingRPC === rpc { resetConnection() }
            await rpc.close()
            throw error
        }
    }

    public func disconnect() {
        connectionAttempt = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        resetConnection()
    }

    private func resetConnection() {
        if let session {
            session.issuer.close()
            session.shellTask?.cancel()
            session.pushTasks.values.forEach { $0.cancel() }
            session.archiveRefresh?.cancel()
            session.selection?.task?.cancel()
            let rpc = session.rpc
            Task { await rpc.close() }
        }
        if let connectingRPC { Task { await connectingRPC.close() } }
        connectingRPC = nil
        session = nil
        currentT3Channels = []
    }

    private func connectionLost(_ session: Session, error: Error) {
        let configuration = session.configuration
        let identity = session.selectedIdentity
        let attempt = connectionAttempt
        resetConnection()
        onEvent?(.disconnected(error.localizedDescription))
        guard connectionAttempt == attempt, Self.shouldRetry(error) else { return }
        reconnectTask = Task { [weak self, reconnectDelays] in
            for delay in reconnectDelays {
                do {
                    try await Task.sleep(for: delay)
                } catch { return }
                guard let self, self.connectionAttempt == attempt else { return }
                do {
                    _ = try await self.establish(configuration, attempt: attempt, reattaching: identity)
                    return
                } catch {
                    guard self.connectionAttempt == attempt, !Task.isCancelled else { return }
                    self.onEvent?(.disconnected(error.localizedDescription))
                    if !Self.shouldRetry(error) { break }
                }
            }
            if let self, self.connectionAttempt == attempt { self.reconnectTask = nil }
        }
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        switch error {
        case T3PairingError.credentialRefused, T3PairingError.httpStatus(401), T3PairingError.httpStatus(403),
             T3PairingError.incompatibleProtocol,
             T3ServiceError.differentEnvironment, T3ServiceError.differentWorkspace, T3ServiceError.missingConnection:
            return false
        default:
            return true
        }
    }

    public func bots() async throws -> [BotProfile] { [profile(try requireSession())] }


    public func updateProfile(_ edit: BotProfileEdit, for bot: BotProfile) async throws -> BotProfile {
        let session = try requireSession(profile: ExactID(bot.id))
        try await editManifest(session) { manifest in
            if let name = edit.name { manifest.displayName = try Self.name(name) }
            if let description = edit.description { manifest.description = description }
        }
        return profile(session)
    }

    public func setAvatar(_ choice: BotAvatarChoice, for bot: BotProfile) async throws -> BotProfile {
        let session = try requireSession(profile: ExactID(bot.id))
        try await editManifest(session) { manifest in
            try choice.validate(current: manifest.avatar)
            manifest.avatar = choice.applying(to: manifest.avatar ?? BotAppearance())
        }
        return profile(session)
    }

    public func loadBotBrain() async throws -> T3BotBrainSnapshot {
        let session = try requireSession()
        let manifest = try await readManifest(session)
        let soul = try await readFile("SOUL.md", in: session)
        let memory = try await readFile("MEMORY.md", in: session)
        let entries = try await listEntries(in: session)
        let skills: [String]
        if entries.contains(where: { $0["path"].text == "skills" && $0["kind"].text == "directory" }) {
            let children = try await listEntries(in: session, directory: "skills")
            skills = children.compactMap { $0["path"].text }.sorted()
        } else {
            skills = []
        }
        return T3BotBrainSnapshot(manifest: manifest, soulMarkdown: soul ?? "", memoryMarkdown: memory ?? "",
                                  skills: skills, workspaceRoot: session.workspace)
    }

    public func saveSoul(_ markdown: String, replacing expected: String? = nil) async throws {
        try await autosave("SOUL.md", contents: markdown, replacing: expected, in: requireSession())
    }

    public func saveMemory(_ markdown: String, replacing expected: String? = nil) async throws {
        try await autosave("MEMORY.md", contents: markdown, replacing: expected, in: requireSession())
    }

    public func saveManifest(_ manifest: T3BotManifest) async throws {
        try await editManifest(requireSession()) { current in
            // The service owns the main space; an edit started before it existed must not drop it.
            let main = current.mainThreadID
            current = manifest
            current.mainThreadID = main
        }
    }

    @discardableResult public func setDefaultModel(_ option: T3ModelOption?) async throws -> T3BotManifest {
        let session = try requireSession()
        try await editManifest(session) { manifest in
            manifest.providerInstanceID = option?.providerInstanceID
            manifest.model = option?.modelID
        }
        try check(session)
        return session.manifest
    }

    public func availableModels() async throws -> [T3ModelOption] {
        let session = try requireSession()
        let config = try await session.rpc.call("server.getConfig")
        try check(session)
        session.config = config
        updateConfiguration(session)
        if currentMain(session) == nil { try? await ensureMain(session) }
        try check(session)
        return modelOptions(config).map(\.option)
    }

    public func providers() async throws -> [T3ProviderStatus] {
        let session = try requireSession()
        let reply = try await session.rpc.call("server.refreshProviders")
        try check(session)
        guard let providers = reply["providers"].list else { throw T3ServiceError.invalidResponse }
        session.config["providers"] = .array(providers)
        return providers.compactMap(T3ProviderStatus.init)
    }

    public func readProjectFile(relativePath: String) async throws -> String {
        guard let contents = try await readFile(relativePath, in: requireSession()) else {
            throw T3ServiceError.invalidResponse
        }
        return contents
    }

    public func listOutputs() async throws -> [T3OutputFile] {
        let session = try requireSession()
        let root = try await listEntries(in: session)
        guard root.contains(where: { $0["path"].text == "outputs" && $0["kind"].text == "directory" }) else { return [] }
        var directories = ["outputs"]
        var files: [T3OutputFile] = []
        while let directory = directories.popLast() {
            for entry in try await listEntries(in: session, directory: directory) {
                guard let path = entry["path"].text, let slash = path.lastIndex(of: "/"),
                      path[..<slash] == directory else { continue }
                guard (try? Self.validateRelativePath(path)) != nil else { continue }
                switch entry["kind"].text {
                case "directory":
                    directories.append(path)
                case "file":
                    let name = String(path[path.index(after: slash)...])
                    files.append(T3OutputFile(name: name, relativePath: path, mimeType: Self.outputMIMEType(name)))
                default: continue
                }
            }
        }
        return files.sorted {
            $0.name == $1.name ? $0.relativePath < $1.relativePath : $0.name < $1.name
        }
    }

    public func downloadOutput(_ output: T3OutputFile) async throws -> DownloadedArtifact {
        try Self.validateRelativePath(output.relativePath)
        guard output.relativePath.hasPrefix("outputs/") else { throw T3ServiceError.invalidPath }
        let session = try requireSession()
        let path = try await signedAssetPath(for: .object([
            "_tag": .string("draft-workspace-file"), "cwd": .string(session.workspace),
            "path": .string(output.relativePath), "disposition": .string("attachment")
        ]), in: session)
        try check(session)
        let data = try await fetchAsset(path, in: session)
        try check(session)
        return DownloadedArtifact(data: data, filename: output.name, mimeType: output.mimeType)
    }

    public var workflowRoutinesAvailable: Bool {
        session?.ready == true && session?.config["settings"]["workflowsEnabled"].flag == true
    }

    public func proposeWorkflowRoutine(name: String, prompt: String, schedule: T3RoutineSchedule,
                                       threadID: String) throws -> T3WorkflowRoutineProposal {
        let session = try requireSession()
        guard workflowRoutinesAvailable, let environmentID = session.configuration.t3?.environmentID else {
            throw T3WorkflowRoutineError.unavailable
        }
        guard session.shells[threadID] != nil else { throw ConversationServiceError.wrongConversation }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw T3WorkflowRoutineError.emptyPrompt }
        return try T3WorkflowRoutineProposal(id: UUID(), name: Self.name(name), prompt: prompt, schedule: schedule,
                                             threadID: threadID, environmentID: environmentID, projectID: session.profile.text)
    }

    public func listWorkflowRoutines() async throws -> [T3WorkflowRoutine] {
        guard workflowRoutinesAvailable else { return [] }
        return try await workflowRoutines(in: requireSession())
            .sorted { $0.proposal.name.localizedStandardCompare($1.proposal.name) == .orderedAscending }
    }

    public func turnOnWorkflowRoutine(_ proposal: T3WorkflowRoutineProposal) async throws -> T3WorkflowRoutine {
        let session = try beginWorkflowRoutineWrite(proposal)
        defer { session.workflowWrites.remove(proposal.id) }
        guard session.shells[proposal.threadID] != nil else { throw ConversationServiceError.wrongConversation }
        let requested = T3WorkflowRoutine(proposal: proposal, version: 1)
        let files = try await workflowRoutineFiles(in: session)
        if let file = files.first(where: { $0["name"].text == requested.fileName }) {
            guard T3WorkflowRoutine(file: file, scope: proposal.scope) == requested else {
                throw T3WorkflowRoutineError.changed
            }
            return requested
        }
        guard session.shells[proposal.threadID] != nil else { throw ConversationServiceError.wrongConversation }
        try await saveWorkflowRoutine(requested, in: session)
        return requested
    }

    public func setWorkflowRoutineEnabled(_ routine: T3WorkflowRoutine, enabled: Bool) async throws -> T3WorkflowRoutine {
        let proposal = routine.proposal
        let session = try beginWorkflowRoutineWrite(proposal)
        defer { session.workflowWrites.remove(proposal.id) }
        let files = try await workflowRoutineFiles(in: session)
        guard let file = files.first(where: { $0["name"].text == routine.fileName }),
              let current = T3WorkflowRoutine(file: file, scope: proposal.scope),
              current.proposal == proposal else { throw T3WorkflowRoutineError.changed }
        let version = routine.enabled == enabled ? routine.version : routine.version + 1
        if current.version == version { return current }
        guard current == routine else { throw T3WorkflowRoutineError.changed }
        if enabled, session.shells[proposal.threadID] == nil { throw ConversationServiceError.wrongConversation }
        let updated = T3WorkflowRoutine(proposal: proposal, version: version)
        try await saveWorkflowRoutine(updated, in: session)
        return updated
    }

    public func deleteWorkflowRoutine(_ routine: T3WorkflowRoutine) async throws {
        let proposal = routine.proposal
        let session = try beginWorkflowRoutineWrite(proposal)
        defer { session.workflowWrites.remove(proposal.id) }
        let files = try await workflowRoutineFiles(in: session)
        guard let file = files.first(where: { $0["name"].text == routine.fileName }) else { return }
        guard T3WorkflowRoutine(file: file, scope: proposal.scope) == routine else { throw T3WorkflowRoutineError.changed }
        let payload: JSONValue = .object(["name": .string(routine.fileName)])
        guard try await changeWorkflowDefinition("workflows.deleteDefinition", payload: payload, in: session) else {
            throw T3WorkflowRoutineError.deleteRejected
        }
        guard try await !workflowRoutineFiles(in: session).contains(where: { $0["name"].text == routine.fileName }) else {
            throw ConversationServiceError.uncertain
        }
    }

    private func beginWorkflowRoutineWrite(_ proposal: T3WorkflowRoutineProposal) throws -> Session {
        let session = try requireSession()
        guard workflowRoutinesAvailable else { throw T3WorkflowRoutineError.unavailable }
        guard proposal.scope == pushScope(session) else { throw ConversationServiceError.wrongConversation }
        guard session.workflowWrites.insert(proposal.id).inserted else { throw T3WorkflowRoutineError.updating }
        return session
    }

    private func workflowRoutineFiles(in session: Session) async throws -> [JSONValue] {
        let reply = try await session.rpc.call("workflows.getDefinition")
        try check(session)
        guard reply["single"].flag == false else { throw T3WorkflowRoutineError.unavailable }
        guard let files = reply["files"].list else { throw T3ServiceError.invalidResponse }
        return files
    }

    private func saveWorkflowRoutine(_ routine: T3WorkflowRoutine, in session: Session) async throws {
        let source = try routine.definitionSource()
        let payload: JSONValue = .object(["name": .string(routine.fileName), "source": .string(source)])
        guard try await changeWorkflowDefinition("workflows.saveDefinition", payload: payload, in: session) else {
            throw T3WorkflowRoutineError.saveRejected
        }
        let files = try await workflowRoutineFiles(in: session)
        guard files.contains(where: { T3WorkflowRoutine(file: $0, scope: routine.proposal.scope) == routine }) else {
            throw ConversationServiceError.uncertain
        }
    }

    private func changeWorkflowDefinition(_ method: String, payload: JSONValue, in session: Session) async throws -> Bool {
        let reply = try await mutationReply(method, payload: payload, in: session)
        try check(session)
        guard let changed = reply["changed"].flag else { throw T3ServiceError.invalidResponse }
        // T3 can report warnings after writing. The caller reads back what took effect.
        return changed
    }

    func workflowRoutineActivity(threadID: String) async throws -> [T3WorkflowRoutineActivity] {
        guard workflowRoutinesAvailable else { return [] }
        let session = try requireSession()
        guard session.shells[threadID] != nil else { return [] }
        return try await workflowRoutineActivity(threadID: threadID, in: session)
    }

    public func watchWorkflowRoutineActivity(threadID: String) async throws
        -> AsyncThrowingStream<[T3WorkflowRoutineActivity], Error> {
        let session = try requireSession()
        guard workflowRoutinesAvailable, session.shells[threadID] != nil else {
            return AsyncThrowingStream { $0.finish() }
        }
        let updates = try await session.rpc.subscribe("workflows.subscribe")
        try check(session)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { output in
            let task = Task { [weak self, weak session] in
                do {
                    var revision: Int?
                    var routines: [T3WorkflowRoutine]?
                    for try await snapshot in updates {
                        guard let self, let session else { break }
                        try self.check(session)
                        guard session.shells[threadID] != nil else { break }
                        let latest = snapshot["definition"]["revision"].integer
                        if routines == nil || latest == nil || latest != revision {
                            routines = try await self.workflowRoutines(threadID: threadID, in: session)
                            revision = latest
                        }
                        output.yield(try T3WorkflowRoutineActivity.read(snapshot, routines: routines ?? []))
                    }
                    output.finish()
                } catch { output.finish(throwing: error) }
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    public func answerWorkflowRoutineQuestion(_ question: T3WorkflowRoutineQuestion, choice: String,
                                              access: ConversationAccess) async throws {
        let (session, selection) = try resolve(access)
        let proposal = question.proposal
        guard selection.identity.stored.text.utf8.elementsEqual(proposal.threadID.utf8) else {
            throw ConversationServiceError.wrongConversation
        }
        guard workflowRoutinesAvailable, proposal.scope == pushScope(session),
              session.shells[proposal.threadID] != nil, question.choices.contains(choice),
              session.workflowAnswers.insert(question.runID).inserted else {
            throw T3WorkflowRoutineError.questionChanged
        }
        defer { session.workflowAnswers.remove(question.runID) }
        let activities = try await workflowRoutineActivity(threadID: proposal.threadID, in: session)
        guard session.shells[proposal.threadID] != nil,
              activities.contains(where: { $0.question == question }) else {
            throw T3WorkflowRoutineError.questionChanged
        }
        _ = try resolve(access)
        _ = try await mutationReply("workflows.answer", payload: .object([
            "runId": .string(question.runID), "name": .string(T3WorkflowRoutineQuestion.name), "choice": .string(choice),
        ]), in: session)
        try check(session)
    }

    private func workflowRoutineActivity(threadID: String, in session: Session) async throws -> [T3WorkflowRoutineActivity] {
        let routines = try await workflowRoutines(threadID: threadID, in: session)
        guard !routines.isEmpty else { return [] }
        let snapshot = try await session.rpc.call("workflows.subscribe", firstStreamValue: true)
        try check(session)
        return try T3WorkflowRoutineActivity.read(snapshot, routines: routines)
    }

    private func workflowRoutines(threadID: String, in session: Session) async throws -> [T3WorkflowRoutine] {
        try await workflowRoutines(in: session)
            .filter { $0.proposal.threadID.utf8.elementsEqual(threadID.utf8) }
    }

    private func workflowRoutines(in session: Session) async throws -> [T3WorkflowRoutine] {
        let scope = pushScope(session)
        return try await workflowRoutineFiles(in: session)
            .compactMap { T3WorkflowRoutine(file: $0, scope: scope) }
    }

    public func listRoutines() async throws -> [T3ScheduledRoutine] {
        try await routines(in: requireSession()).map(Self.routine)
    }

    private func routines(in session: Session) async throws -> [JSONValue] {
        let reply = try await session.rpc.call("scheduledTasks.subscribe", firstStreamValue: true)
        try check(session)
        guard let tasks = reply["tasks"].list else { throw T3ServiceError.invalidResponse }
        return tasks.filter { $0["projectId"].text == session.profile.text }
    }

    public func createRoutine(name: String, prompt: String, schedule: T3RoutineSchedule, threadID: String?) async throws -> T3ScheduledRoutine {
        let session = try requireSession()
        let title = try Self.name(name)
        let model = modelSelection(session)
        guard model != .null else { throw T3ServiceError.missingModel }
        // A routine without a space gets its own, named after it, so its results stay together.
        let destination: String
        if let threadID { destination = threadID }
        else { destination = try await createThread(title: title, operationID: UUID(), in: session).summary.identity.stored.text }
        let identity = try T3ProjectionMapper.identity(profile: session.profile, threadID: destination)
        try validate(identity, in: session)
        let runtime = session.config["settings"]["defaultRuntimeMode"].nonempty ?? "approval-required"
        let reply = try await mutationReply("scheduledTasks.upsert", payload: .object([
            "commandId": .string(UUID().uuidString), "title": .string(title), "prompt": .string(prompt), "enabled": .bool(true),
            "schedule": Self.routineSchedulePayload(schedule), "projectId": .string(session.profile.text), "threadId": .string(destination),
            "threadMode": .string("continue"), "workspaceStrategy": .object(["type": .string("root")]),
            "modelSelection": model, "runtimeMode": .string(runtime), "interactionMode": .string("default"),
            "createdBy": .string("user"), "creationSource": .string("mobile")
        ]), in: session)
        try check(session)
        let task = reply["task"]
        guard task["projectId"].text == session.profile.text, let created = try? Self.routine(task) else {
            throw ConversationServiceError.uncertain
        }
        return created
    }

    public func setRoutineEnabled(id: String, enabled: Bool) async throws {
        let session = try requireSession()
        guard try await routines(in: session).contains(where: { $0["id"].text == id }) else {
            throw T3ServiceError.invalidResponse
        }
        let reply = try await session.rpc.call("scheduledTasks.setEnabled", payload: .object([
            "id": .string(id), "enabled": .bool(enabled)
        ]))
        try check(session)
        guard reply["task"]["id"].text == id, reply["task"]["projectId"].text == session.profile.text,
              reply["task"]["enabled"].flag == enabled else {
            throw T3ServiceError.invalidResponse
        }
    }

    public func deleteRoutine(id: String) async throws {
        let session = try requireSession()
        guard try await routines(in: session).contains(where: { $0["id"].text == id }) else {
            throw T3ServiceError.invalidResponse
        }
        let reply = try await session.rpc.call("scheduledTasks.delete", payload: .object(["id": .string(id)]))
        try check(session)
        guard reply["id"].text == id else { throw T3ServiceError.invalidResponse }
    }

    public func conversations(profile: ExactID) async throws -> ConversationDirectory {
        try directory(requireSession(profile: profile)).directory
    }

    public func createChat(title: String?) async throws -> CreatedSession {
        try await createThread(title: title, operationID: UUID(), in: requireSession())
    }

    public func renameChannel(threadID: String, title: String) async throws {
        try await channelCommand("thread.metadata.update", threadID: threadID, fields: ["title": .string(Self.name(title))])
    }

    public func setChannelPinned(threadID: String, pinned: Bool) async throws {
        try await channelCommand(pinned ? "thread.pin" : "thread.unpin", threadID: threadID)
    }

    public func archiveChannel(threadID: String, archived: Bool) async throws {
        let session = try requireSession()
        guard !archived || threadID != session.manifest.mainThreadID else { throw T3ServiceError.protectedMainSpace }
        try await channelCommand(archived ? "thread.archive" : "thread.unarchive", threadID: threadID)
        try? await refreshArchive(session)
    }

    public func markChannelVisited(threadID: String) async throws {
        let session = try requireSession()
        let identity = try T3ProjectionMapper.identity(profile: session.profile, threadID: threadID)
        try await visitChannel(identity, in: session)
    }

    public func setChannelModel(threadID: String, providerInstanceID: String, model: String) async throws {
        let selection = Self.modelSelection(provider: providerInstanceID, model: model)
        guard selection != .null else { throw T3ServiceError.missingModel }
        try await channelCommand("thread.model-selection.set", threadID: threadID, fields: ["modelSelection": selection])
    }

    public func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let session = try requireSession()
        let attempt = UUID()
        session.openAttempt = attempt
        let identity: SessionIdentity
        switch target {
        case .stored(let requested):
            try validate(requested, in: session)
            identity = requested
        case .canonical(let profile, let expectedRoot):
            // A bare open lands in the main space, else the latest space, else a new one.
            guard profile == session.profile else { throw ConversationServiceError.wrongConversation }
            if let expectedRoot {
                identity = try T3ProjectionMapper.identity(profile: profile, threadID: expectedRoot.text)
                try validate(identity, in: session)
            } else {
                if currentMain(session) == nil { try await ensureMain(session) }
                try check(session)
                if let home = try currentMain(session) ?? T3ProjectionMapper.mostRecent(directory(session).channels) {
                    identity = try T3ProjectionMapper.identity(profile: profile, threadID: home.id)
                } else {
                    // Nobody asked for this space, so it isn't made where only a signed-out provider could answer.
                    guard modelSelection(session, allowingSignedOut: false) != .null else { throw T3ServiceError.missingModel }
                    identity = try await createThread(title: nil, operationID: UUID(), in: session).summary.identity
                }
            }
            guard session.openAttempt == attempt else { throw ConversationServiceError.staleConversation }
        }
        let opened = try await attach(identity, in: session, attempt: attempt)
        Task { [weak self, weak session] in
            guard let self, let session else { return }
            try? await self.visitChannel(identity, in: session, through: opened.snapshot.visitMark)
        }
        return opened
    }

    /// Moves the host's read watermark to a shown snapshot's host time, so a reply that arrives after the display stays unread.
    public func markVisited(through mark: VisitMark, access: ConversationAccess) async throws {
        let (session, selection) = try resolve(access)
        try await visitChannel(selection.identity, in: session, through: mark, opened: false)
    }

    private func visitChannel(_ identity: SessionIdentity, in session: Session, through mark: VisitMark? = nil, opened: Bool = true) async throws {
        try validate(identity, in: session)
        // As in T3's own clients, an open sets `opened`, which the host counts by its own clock, and a visit
        // to an open space only moves the watermark. Only a visit with no snapshot falls back to the phone's clock.
        var fields: [String: JSONValue] = [
            "visitedAt": .string(mark?.hostTime ?? Date().ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        ]
        if opened { fields["opened"] = .bool(true) }
        _ = try await dispatch("thread.visit", identity: identity, operationID: UUID(), in: session, fields: fields)
    }

    private func attach(_ identity: SessionIdentity, in session: Session, attempt: UUID) async throws -> OpenedConversation {
        try check(session)
        guard session.openAttempt == attempt else { throw ConversationServiceError.staleConversation }
        session.issuer.retireAttachment()
        session.selection?.task?.cancel()
        let selection = Selection(identity: identity)
        session.selection = selection
        do {
            try await subscribeToThread(selection, in: session)
            try check(session)
            guard session.openAttempt == attempt, session.selection === selection, let projection = selection.projection else {
                throw ConversationServiceError.staleConversation
            }
            if let failure = selection.streamFailure { throw failure }
            let access = try session.issuer.issue(identity)
            selection.access = access
            session.selectedIdentity = identity
            let snapshot = projection.conversation(identity)
            recordPreview(from: snapshot.messages, for: identity.stored.text, in: session)
            return OpenedConversation(identity: identity, snapshot: snapshot,
                                      access: access, activity: projection.activity)
        } catch {
            selection.task?.cancel()
            if session.selection === selection { session.selection = nil }
            throw error
        }
    }

    public func recentConversationHistory(_ identity: SessionIdentity) async throws -> ConversationHistoryWindow? {
        let session = try requireSession()
        try validate(identity, in: session)
        let page = try await newestHistory(identity, in: session)
        let messages = T3ProjectionMapper.visibleItems(page.rows)
            .compactMap { T3ProjectionMapper.chatMessage($0, messagesByID: page.messagesByID) }
        recordPreview(from: messages, for: identity.stored.text, in: session)
        return ConversationHistoryWindow(messages: messages, hasEarlierMessages: page.more)
    }

    public func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery,
                     access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let (session, selection) = try resolve(access)
        let identity = selection.identity
        let active = selection.projection?.activeRunID
        let mode: JSONValue
        if delivery == .steer {
            guard let active else { throw ConversationServiceError.steeringUnavailable }
            guard attachments.isEmpty else { throw ConversationServiceError.steeringAttachments }
            mode = .object(["type": .string("steer_active"), "targetRunId": .string(active)])
        } else {
            mode = .object(["type": .string(active == nil ? "start_immediately" : "queue_after_active")])
        }
        var bytes = 0
        let uploaded = try attachments.map { attachment -> JSONValue in
            guard let id = attachment.stagingID, let uploaded = session.attachments[id],
                  uploaded.identity == identity, uploaded.attachment == attachment else { throw ConversationServiceError.invalidAttachment }
            bytes += uploaded.attachment.byteCount ?? 0
            return uploaded.wire
        }
        guard uploaded.count <= AttachmentLimits.count, bytes <= AttachmentLimits.totalBytes else {
            throw ConversationServiceError.attachmentLimit
        }
        let messageID = operationID.uuidString
        var fields: [String: JSONValue] = [
            "createdBy": .string("user"), "creationSource": .string("mobile"), "messageId": .string(messageID),
            "text": .string(text), "attachments": .array(uploaded), "dispatchMode": mode
        ]
        // T3 titles an untitled space from this seed and its first message; it ignores the seed afterwards.
        if selection.projection?.hasUserMessages == false,
           let seed = T3ProjectionMapper.titleSeed(text) ?? uploaded.first?["name"].nonempty {
            fields["titleSeed"] = .string(seed)
        }
        let receipt = try await dispatch("message.dispatch", identity: identity, operationID: operationID, in: session,
                                         fields: fields, admissionID: messageID)
        for attachment in attachments {
            if let id = attachment.stagingID { session.attachments.removeValue(forKey: id) }
        }
        return receipt
    }

    public func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let (session, selection) = try resolve(access)
        guard let run = selection.projection?.activeRunID else {
            throw ConversationServiceError.staleGeneration
        }
        return try await dispatch("run.interrupt", identity: selection.identity, operationID: operationID,
                                  in: session, fields: ["runId": .string(run)])
    }

    public func replaceQueuedMessage(_ message: QueuedMessage, text: String, access: ConversationAccess,
                                     operationID: UUID) async throws -> MutationReceipt {
        let (session, selection) = try resolve(access)
        guard let current = selection.projection?.conversation(selection.identity).queuedMessages.first(where: { $0.id == message.id }),
              current == message, current.canEdit else { throw ConversationServiceError.queuedMessageUnavailable }
        return try await dispatch("queued-run.edit", identity: selection.identity, operationID: operationID,
                                  in: session, fields: ["runId": .string(message.id), "text": .string(text)],
                                  admissionID: current.submissionID)
    }

    public func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess,
                        operationID: UUID) async throws -> MutationReceipt {
        let (session, selection) = try resolve(access)
        guard let projection = selection.projection,
              let current = projection.pendingRequests.first(where: { $0.id == request.id }),
              current.hasSameWireRevision(as: request) else { throw ConversationServiceError.staleGeneration }
        var fields: [String: JSONValue] = ["requestId": .string(request.id)]
        switch request.kind {
        case .approval:
            guard case .choice(let decision) = response, request.choices.contains(where: { $0.id == decision }) else {
                throw ConversationServiceError.invalidResponse
            }
            fields["decision"] = .string(decision)
        case .question:
            let questions = projection.requestItem(request.id)?["questions"].list ?? []
            fields["answers"] = .object(try Self.answers(response, questions: questions))
        case .unsupported: throw T3ServiceError.unsupported
        }
        return try await dispatch("runtime-request.respond", identity: selection.identity, operationID: operationID,
                                  in: session, fields: fields)
    }

    public func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        let (session, selection) = try resolve(access)
        let images = ["image/jpeg", "image/png", "image/webp", "image/gif"]
        let isImage = images.contains(mimeType.lowercased())
        let type = isImage ? "image" : "file"
        let limit = isImage ? 10 * 1024 * 1024 : AttachmentLimits.fileBytes
        guard !data.isEmpty, data.count <= limit, !filename.isEmpty,
              filename.utf16.count <= 255, !mimeType.isEmpty, mimeType.utf16.count <= 100 else {
            throw ConversationServiceError.invalidAttachment
        }
        var wire: [String: JSONValue] = [
            "type": .string(type), "name": .string(filename), "mimeType": .string(mimeType.lowercased()),
            "sizeBytes": .number(Double(data.count))
        ]
        let issued = try await session.rpc.call("attachments.createUploadUrl", payload: .object(wire))
        _ = try resolve(access)
        guard let id = issued["attachmentId"].nonempty, let path = issued["relativeUrl"].text,
              path.hasPrefix("/api/attachments/upload/") else { throw T3ServiceError.invalidResponse }
        _ = try await http.request(origin: session.origin, path: path, method: "POST", body: data,
                                   headers: ["Content-Type": mimeType])
        _ = try resolve(access)
        wire["id"] = .string(id)
        let stagedID = UUID()
        let attachment = ChatAttachment(name: filename, path: "t3-attachment:" + id, mimeType: mimeType,
                                        byteCount: data.count, stagingID: stagedID)
        session.attachments[stagedID] = StagedAttachment(attachment: attachment, wire: .object(wire), identity: selection.identity)
        return attachment
    }

    public func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        let (session, selection) = try resolve(access)
        let artifact = try await download(attachment, identity: selection.identity, in: session, access: access)
        _ = try resolve(access)
        return artifact
    }
}

private extension T3BotService {
    func checkAttempt(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard connectionAttempt == attempt else { throw T3ServiceError.disconnected }
    }

    func check(_ session: Session) throws {
        try Task.checkCancellation()
        guard self.session === session else { throw T3ServiceError.disconnected }
        if let failure = session.shellFailure { throw failure }
    }

    func requireSession(profile: ExactID? = nil) throws -> Session {
        guard let session, session.ready else { throw T3ServiceError.disconnected }
        if let profile, session.profile != profile { throw ConversationServiceError.wrongConversation }
        return session
    }

    func validate(_ identity: SessionIdentity, in session: Session) throws {
        try check(session)
        guard identity.profile == session.profile, identity.root == identity.stored,
              identity.aliases.subtracting([identity.root, identity.stored]).isEmpty,
              session.shells[identity.stored.text] != nil || session.archivedShells[identity.stored.text] != nil
        else { throw ConversationServiceError.wrongConversation }
    }

    func resolve(_ access: ConversationAccess) throws -> (Session, Selection) {
        let session = try requireSession()
        let identity = try session.issuer.resolve(access)
        guard let selection = session.selection, selection.identity == identity, selection.access == access else {
            throw ConversationServiceError.staleConversation
        }
        try validate(identity, in: session)
        return (session, selection)
    }

    /// The projects a route's environment holds. A read, so a failure here is the route's.
    func listProjects(origin: URL, token: String) async throws -> [JSONValue] {
        let data = try await http.request(origin: origin, path: "/api/projects", token: token)
        guard let projects = try JSONDecoder().decode(JSONValue.self, from: data)["projects"].list else {
            throw T3ServiceError.invalidProject
        }
        return projects
    }

    func resolveProject(in projects: [JSONValue], paired: T3Connection, rpc: T3RPCClient, attempt: UUID,
                        environmentID: String) async throws -> JSONValue {
        let projectID = T3ProjectionMapper.stableUUID("botto-main-project:" + environmentID).uuidString
        let available = projects.filter { $0["deletedAt"] == .null }
        if let savedID = paired.projectID.nonempty {
            guard let project = available.first(where: { $0["id"].text?.utf8.elementsEqual(savedID.utf8) == true }),
                  paired.workspaceRoot.nonempty.map({ root in
                      project["workspaceRoot"].text?.utf8.elementsEqual(root.utf8) == true
                  }) ?? true else { throw T3ServiceError.differentWorkspace }
            return project
        }
        if let root = paired.workspaceRoot.nonempty, let project = available.first(where: { $0["workspaceRoot"].text == root }) {
            return project
        }
        if let project = available.first(where: { $0["id"].text == projectID }) { return project }
        let targetWorkspace = paired.workspaceRoot.nonempty ?? T3BotBootstrap.workspaceRoot
        let commandID = T3ProjectionMapper.stableUUID("botto-main-project-create:" + environmentID).uuidString
        let project = try await createProject(id: projectID, commandID: commandID, workspace: targetWorkspace,
                                              rpc: rpc, attempt: attempt)
        if project["deletedAt"] == .null { return project }
        // A fresh pairing can recover a removed project. T3 enforces one live project per workspace root.
        guard project["id"].text == projectID, let previousRoot = project["workspaceRoot"].nonempty else {
            throw T3ServiceError.invalidProject
        }
        if let replacement = available.first(where: { $0["workspaceRoot"].text == previousRoot }) { return replacement }
        let id = UUID().uuidString
        let replacement = try await createProject(id: id, commandID: UUID().uuidString, workspace: previousRoot,
                                                   rpc: rpc, attempt: attempt)
        guard replacement["deletedAt"] == .null, replacement["id"].text == id else { throw T3ServiceError.invalidProject }
        return replacement
    }

    func createProject(id: String, commandID: String, workspace: String, rpc: T3RPCClient,
                       attempt: UUID) async throws -> JSONValue {
        let project = try await rpc.call("projects.mutate", payload: .object([
            "type": .string("project.create"), "commandId": .string(commandID), "projectId": .string(id),
            "title": .string(T3BotBootstrap.defaultManifest.displayName),
            "workspaceRoot": .string(workspace), "createWorkspaceRootIfMissing": .bool(true)
        ]))
        try checkAttempt(attempt)
        return project
    }

    func bootstrap(_ session: Session) async throws {
        if let contents = try await readFile("bot.json", in: session, allowMissing: true) {
            session.manifest = try JSONDecoder().decode(T3BotManifest.self, from: Data(contents.utf8))
        } else {
            try await writeFile("bot.json", contents: T3BotBootstrap.manifestJSON(session.manifest), in: session)
        }
        // Custom text is kept. The short prompt earlier builds generated counts as missing.
        let legacy = T3BotBootstrap.legacyAgentsMarkdown(session.manifest)
        let defaults = [
            ("SOUL.md", T3BotBootstrap.soulMarkdown, nil),
            ("MEMORY.md", T3BotBootstrap.memoryMarkdown, nil),
            ("AGENTS.md", T3BotBootstrap.agentsMarkdown(session.manifest), legacy),
            ("CLAUDE.md", T3BotBootstrap.claudeMarkdown(session.manifest), legacy)
        ]
        for (path, contents, replaced) in defaults {
            let current = try await readFile(path, in: session, allowMissing: true)
            if current == nil || current == replaced { try await writeFile(path, contents: contents, in: session) }
        }
    }

    func readManifest(_ session: Session) async throws -> T3BotManifest {
        guard let json = try await readFile("bot.json", in: session) else { throw T3ServiceError.invalidResponse }
        return try JSONDecoder().decode(T3BotManifest.self, from: Data(json.utf8))
    }

    func editManifest(_ session: Session, update: @escaping @MainActor (inout T3BotManifest) throws -> Void) async throws {
        try await queueManifest(session) { service in
            var manifest = try await service.readManifest(session)
            let previous = manifest
            try update(&manifest)
            manifest.displayName = try Self.name(manifest.displayName)
            // Looks, models and spaces never touch the prompt; only what it actually says about the bot does.
            // bot.json comes last, so a retry still sees what changed and writes the prompts again.
            if T3BotBootstrap.agentsMarkdown(manifest) != T3BotBootstrap.agentsMarkdown(previous)
                || service.unsettledPrompts.contains(session.profile) {
                service.unsettledPrompts.insert(session.profile)
                try await service.writeFile("AGENTS.md", contents: T3BotBootstrap.agentsMarkdown(manifest), in: session)
                try await service.writeFile("CLAUDE.md", contents: T3BotBootstrap.claudeMarkdown(manifest), in: session)
            }
            try await service.persistManifest(manifest, in: session)
            service.unsettledPrompts.remove(session.profile)
        }
    }

    /// While the bot waits to be set up, a space that changes may mean another device did it; bot.json says.
    func catchUpOnSetup(_ session: Session) {
        guard session.ready, T3FirstRun.needsBotSetup(profile(session), spaces: currentT3Channels) else { return }
        Task { [weak self] in
            try? await self?.queueManifest(session) { service in
                session.manifest = try await service.readManifest(session)
                service.publishDirectory(session)
            }
        }
    }

    func queueManifest(_ session: Session, work: @escaping @MainActor (T3BotService) async throws -> Void) async throws {
        let previous = session.manifestTail
        let edit = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self else { throw T3ServiceError.disconnected }
            try await work(self)
        }
        session.manifestTail = edit
        try await edit.value
    }

    /// The main space while it is live.
    func currentMain(_ session: Session) -> T3ChannelSummary? {
        guard let id = session.manifest.mainThreadID, session.shells[id] != nil else { return nil }
        return try? directory(session).channels.first { $0.id == id }
    }

    /// Adopts the bot's main space, or creates one named after the bot. Its name is the user's from then on.
    func ensureMain(_ session: Session) async throws {
        try await queueManifest(session) { service in
            var manifest = try await service.readManifest(session)
            let savedID = manifest.mainThreadID
            if let savedID, try await service.mainExists(savedID, in: session) {
                session.manifest = manifest
                if session.shells[savedID] == nil { try await service.refreshArchive(session) }
                guard session.shells[savedID] != nil || session.archivedShells[savedID] != nil else {
                    throw T3ServiceError.mainSpaceSynchronizing
                }
                try await service.restoreMain(savedID, in: session)
                if session.ready { service.publishDirectory(session) }
                return
            }
            // T3 reserves the thread identity on create. Two clients repairing the same anchor target the same thread.
            let generation = savedID.map { "replacement:" + $0 } ?? "initial"
            let id = T3ProjectionMapper.stableUUID("botto-main:\(session.profile.text):\(generation)").uuidString
            if session.shells[id] == nil, session.archivedShells[id] == nil {
                guard service.modelSelection(session, allowingSignedOut: false) != .null else { return }
                let name = manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    _ = try await service.createThread(title: name.isEmpty ? T3BotBootstrap.defaultManifest.displayName : name,
                                                        operationID: UUID(), in: session, publish: false, threadID: id)
                } catch T3RPCError.remote(let tag, let message)
                    where tag == "OrchestrationV2DispatchCommandError"
                    && message == "Thread \(id) already exists. Use a new thread id." {
                    if try await service.mainExists(id, in: session) { throw T3ServiceError.mainSpaceSynchronizing }
                    throw T3ServiceError.mainSpaceRecoveryRequired
                }
            }
            manifest = try await service.readManifest(session)
            guard manifest.mainThreadID == savedID || manifest.mainThreadID == id else { return }
            manifest.mainThreadID = id
            try await service.restoreMain(id, in: session)
            try await service.persistManifest(manifest, in: session)
        }
    }

    func mainExists(_ id: String, in session: Session) async throws -> Bool {
        let response = try await session.rpc.call("orchestration.getThreadLinkMetadata", payload: .object([
            "threadIds": .array([.string(id)])
        ]))
        try check(session)
        guard let rows = response.fields else { throw T3ServiceError.invalidResponse }
        guard let row = rows[id] else { return false }
        guard row["projectId"].text?.utf8.elementsEqual(session.profile.text.utf8) == true else {
            throw T3ServiceError.invalidProject
        }
        return true
    }

    /// The anchor stays live, and never keeps the "#general" earlier builds gave it.
    func restoreMain(_ id: String, in session: Session) async throws {
        let identity = try T3ProjectionMapper.identity(profile: session.profile, threadID: id)
        if session.shells[id] == nil, var shell = session.archivedShells[id] {
            _ = try await dispatch("thread.unarchive", identity: identity, operationID: UUID(), in: session, fields: [:])
            try check(session)
            shell["archivedAt"] = .null
            session.archivedShells.removeValue(forKey: id)
            session.shells[id] = session.shells[id] ?? shell
        }
        if session.shells[id]?["title"].text == "#general" {
            let title = JSONValue.string(try Self.name(session.manifest.displayName))
            _ = try await dispatch("thread.metadata.update", identity: identity, operationID: UUID(), in: session,
                                   fields: ["title": title])
            try check(session)
            session.shells[id]?["title"] = title
        }
    }

    func autosave(_ path: String, contents: String, replacing expected: String?, in session: Session) async throws {
        let token = UUID()
        let previous = session.fileWrites[path]?.tail
        let write = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self else { throw T3ServiceError.disconnected }
            guard session.fileWrites[path]?.token == token else { return }
            if let expected {
                let current = try await self.readFile(path, in: session)
                guard current?.utf8.elementsEqual(expected.utf8) == true else { throw T3ServiceError.proseChanged }
            }
            try await self.writeFile(path, contents: contents, in: session)
        }
        session.fileWrites[path] = (token, write)
        defer { if session.fileWrites[path]?.token == token { session.fileWrites[path] = nil } }
        try await write.value
    }

    func persistManifest(_ manifest: T3BotManifest, in session: Session) async throws {
        try await writeFile("bot.json", contents: T3BotBootstrap.manifestJSON(manifest), in: session)
        session.manifest = manifest
        updateConfiguration(session)
        if session.ready { publishDirectory(session) }
        try check(session)
    }

    func readFile(_ path: String, in session: Session, allowMissing: Bool = false) async throws -> String? {
        try Self.validateRelativePath(path)
        try check(session)
        let response = try await session.rpc.call("projects.readFile", payload: .object([
            "cwd": .string(session.workspace), "relativePath": .string(path), "allowMissing": .bool(allowMissing)
        ]))
        try check(session)
        if allowMissing, response["exists"].flag == false { return nil }
        guard response["truncated"].flag != true, let contents = response["contents"].text else {
            throw T3ServiceError.invalidResponse
        }
        return contents
    }

    func writeFile(_ path: String, contents: String, in session: Session) async throws {
        try check(session)
        let response = try await session.rpc.call("projects.writeFile", payload: .object([
            "cwd": .string(session.workspace), "relativePath": .string(path), "contents": .string(contents)
        ]))
        try check(session)
        guard response["relativePath"].text == path else { throw T3ServiceError.invalidResponse }
    }

    func listEntries(in session: Session, directory: String = "") async throws -> [JSONValue] {
        try check(session)
        let result = try await session.rpc.call("projects.listEntries", payload: .object([
            "cwd": .string(session.workspace), "directoryPath": .string(directory)
        ]))
        try check(session)
        guard let entries = result["entries"].list else { throw T3ServiceError.invalidResponse }
        return entries
    }

    static func modelSelection(provider: String?, model: String?) -> JSONValue {
        guard let provider = provider.nonempty, let model = model.nonempty else { return .null }
        return .object(["instanceId": .string(provider), "model": .string(model)])
    }

    func modelOptions(_ config: JSONValue) -> [(option: T3ModelOption, isDefault: Bool)] {
        let providers = config["providers"].list ?? []
        // A signed-out provider can't answer, so it never becomes a space's model.
        return providers.filter {
            $0["enabled"].flag == true && $0["installed"].flag == true && !T3ProviderStatus.isSignedOut($0)
        }.flatMap { provider in
            guard let instance = provider["instanceId"].nonempty else { return [(T3ModelOption, Bool)]() }
            let name = provider["displayName"].nonempty ?? provider["driver"].nonempty ?? instance
            return (provider["models"].list ?? []).compactMap { model in
                guard let slug = model["slug"].nonempty else { return nil }
                let option = T3ModelOption(id: "\(instance.utf8.count):\(instance)\(slug)", providerInstanceID: instance,
                                           providerName: name, modelID: slug, label: model["name"].nonempty ?? slug)
                return (option, model["isDefault"].flag == true)
            }
        }
    }

    func modelSelection(_ session: Session, allowingSignedOut: Bool = true) -> JSONValue {
        let manifest = Self.modelSelection(provider: session.manifest.providerInstanceID, model: session.manifest.model)
        let defaults = [manifest, session.project["defaultModelSelection"],
                        session.config["settings"]["defaultModelSelection"]]
            .filter { $0["instanceId"].nonempty != nil && $0["model"].nonempty != nil }
        let signedOut = (session.config["providers"].list ?? []).filter(T3ProviderStatus.isSignedOut).compactMap { $0["instanceId"].nonempty }
        if let selected = defaults.first(where: { !signedOut.contains($0["instanceId"].nonempty ?? "") }) { return selected }
        let options = modelOptions(session.config)
        guard let candidate = options.first(where: { $0.isDefault })?.option ?? options.first?.option else {
            // Nothing else works either, so the chosen one waits for its sign-in.
            return allowingSignedOut ? defaults.first ?? .null : .null
        }
        return Self.modelSelection(provider: candidate.providerInstanceID, model: candidate.modelID)
    }

    func updateConfiguration(_ session: Session) {
        let selection = modelSelection(session)
        let previous = session.configuration
        session.configuration.t3?.workspaceRoot = session.workspace
        session.configuration.t3?.providerInstanceID = selection["instanceId"].nonempty
        session.configuration.t3?.model = selection["model"].nonempty
        if session.ready, previous != session.configuration { onEvent?(.configuration(session.configuration)) }
    }

    func profile(_ session: Session) -> BotProfile {
        let latest = T3ProjectionMapper.mostRecent(currentT3Channels)
        let status: BotStatus
        if currentT3Channels.contains(where: { $0.status == .waiting }) { status = .waiting }
        else if currentT3Channels.contains(where: { $0.status == .working }) { status = .working }
        else { status = .idle }
        return BotProfile(id: session.profile.text, name: session.manifest.displayName, description: session.manifest.description,
                          preview: latest?.preview ?? "", updatedAt: latest?.updatedAt, status: status,
                          isPinned: session.project["pinnedAt"] != .null, model: session.configuration.t3?.model,
                          appearance: session.manifest.avatar, hasAvatar: false)
    }

    func directory(_ session: Session) throws -> (directory: ConversationDirectory, channels: [T3ChannelSummary]) {
        try T3ProjectionMapper.directory(botShells(session), profile: session.profile, observedAt: Date(),
                                         mainThreadID: session.manifest.mainThreadID, previews: session.previews)
    }

    func recordPreview(from messages: [ChatMessage], for threadID: String, in session: Session) {
        guard self.session === session, let preview = ConversationPreview.latest(in: messages) else { return }
        guard session.previews[threadID] != preview else { return }
        session.previews[threadID] = preview
        guard session.ready, let result = try? directory(session) else { return }
        currentT3Channels = result.channels
        onEvent?(.botsChanged)
    }

    func botShells(_ session: Session) -> [JSONValue] {
        Array(session.archivedShells.merging(session.shells) { _, live in live }.values)
    }

    func publishDirectory(_ session: Session) {
        guard self.session === session, let result = try? directory(session) else { return }
        currentT3Channels = result.channels
        onEvent?(.botsChanged)
        guard self.session === session else { return }
        onEvent?(.activityBatch([ProfileActivityUpdate(profile: session.profile, observations: result.directory.activity)]))
        guard self.session === session else { return }
        onEvent?(.conversationDirectoryChanged(profile: session.profile))
    }

    func publishConversation(_ selection: Selection, in session: Session) {
        guard session.ready, let access = selection.access, let projection = selection.projection else { return }
        let identity = selection.identity
        let snapshot = projection.conversation(identity)
        recordPreview(from: snapshot.messages, for: identity.stored.text, in: session)
        guard self.session === session, session.selection === selection else { return }
        onEvent?(.conversation(OpenedConversation(identity: identity, snapshot: snapshot, access: access,
                                                  activity: projection.activity)))
    }

    func subscribeToShell(_ session: Session) async throws {
        let stream = try await session.rpc.subscribe("orchestration.subscribeShell",
                                                      payload: .object(["requestCompletionMarker": .bool(true)]))
        let (ready, signal) = AsyncThrowingStream<Void, Error>.makeStream()
        session.shellTask = Task { [weak self, weak session] in
            do {
                var sawSnapshot = false
                for try await item in stream {
                    guard let self, let session, self.session === session, !Task.isCancelled else { break }
                    switch item["kind"].text {
                    case "snapshot" where item["resolvedRepositoryIdentityRoots"] == .null: sawSnapshot = true
                    case "synchronized":
                        guard sawSnapshot else { throw T3ServiceError.invalidResponse }
                        signal.yield(())
                        signal.finish()
                    default: break
                    }
                    try self.applyShell(item, in: session)
                }
                throw T3RPCError.closed
            } catch {
                signal.finish(throwing: error)
                guard let self, let session, self.session === session, !Task.isCancelled else { return }
                session.shellFailure = error
                if session.ready { self.connectionLost(session, error: error) }
            }
        }
        try await Self.waitForSubscription(ready)
    }

    func pushScope(_ session: Session) -> T3PushScope {
        .init(environmentID: session.configuration.t3?.environmentID ?? "", projectID: session.profile.text)
    }

    func syncPushSpaces(_ session: Session) {
        guard onPushActivity != nil else { return }
        let scope = pushScope(session)
        if pushObserver?.scope != scope { pushObserver = .init(scope: scope, since: .now) }
        for id in Array(session.pushTasks.keys) where session.shells[id] == nil {
            session.pushTasks.removeValue(forKey: id)?.cancel()
        }
        for (id, shell) in session.shells {
            if let activity = pushObserver?.shellActivity(in: shell) { onPushActivity?(activity) }
            guard session.pushTasks[id] == nil else { continue }
            session.pushTasks[id] = Task { [weak self, weak session] in
                guard let session else { return }
                while !Task.isCancelled {
                    do {
                        let stream = try await session.subscribeThread(id)
                        for try await item in stream {
                            guard let self, self.session === session, !Task.isCancelled,
                                  let shell = session.shells[id] else { return }
                            let activities = self.pushObserver?.requests(item, in: shell) ?? []
                            for activity in activities { self.onPushActivity?(activity) }
                        }
                    } catch {
                        // A denied or interrupted detail subscription must not end the chat connection.
                    }
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                }
            }
        }
    }

    func applyShell(_ item: JSONValue, in session: Session) throws {
        var changed = false
        switch item["kind"].text {
        case "snapshot":
            let snapshot = item["snapshot"]
            let project = snapshot["projects"].list?.first { $0["id"].text == session.profile.text }
            if item["resolvedRepositoryIdentityRoots"] == .null {
                guard project != nil else { throw T3ServiceError.differentWorkspace }
                guard let channels = snapshot["threads"].list, let archived = snapshot["archivedThreads"].list else {
                    throw T3ServiceError.invalidResponse
                }
                session.shells = indexShells(channels, in: session)
                if session.archiveSnapshotSequence == nil {
                    session.archivedShells = indexShells(archived, in: session)
                }
                changed = true
            }
            if let project {
                guard project["workspaceRoot"].text?.utf8.elementsEqual(session.workspace.utf8) == true else {
                    throw T3ServiceError.differentWorkspace
                }
                session.project = project
                updateConfiguration(session)
            }
        case "thread.updated":
            let shell = item["thread"]
            guard shell["projectId"].text == session.profile.text, let id = shell["id"].nonempty else { return }
            if T3ProjectionMapper.isWorkflowStep(shell) {
                let active = session.shells.removeValue(forKey: id)
                let archived = session.archivedShells.removeValue(forKey: id)
                changed = active != nil || archived != nil
            } else {
                catchUpOnSetup(session)
                if shell["archivedAt"] == .null {
                    session.shells[id] = shell
                    session.archivedShells.removeValue(forKey: id)
                } else {
                    session.archivedShells[id] = shell
                    session.shells.removeValue(forKey: id)
                }
                changed = true
            }
        case "thread.removed":
            guard let id = item["threadId"].nonempty else { return }
            if item["location"].text == "archive" {
                changed = session.archivedShells.removeValue(forKey: id) != nil
            } else {
                changed = session.shells.removeValue(forKey: id) != nil
                if session.ready, changed || session.archivedShells[id] != nil {
                    session.archiveRefresh?.cancel()
                    session.archiveRefresh = Task { [weak self, weak session] in
                        guard let self, let session else { return }
                        try? await self.refreshArchive(session)
                    }
                }
            }
        case "project.updated":
            let project = item["project"]
            guard project["id"].text == session.profile.text else { return }
            guard project["workspaceRoot"].text?.utf8.elementsEqual(session.workspace.utf8) == true else {
                throw T3ServiceError.differentWorkspace
            }
            session.project = project
            updateConfiguration(session)
            changed = true
        case "project.removed":
            if item["projectId"].text == session.profile.text { throw T3ServiceError.differentWorkspace }
        case "snapshot-required": throw T3ServiceError.invalidResponse
        default: break
        }
        if changed, session.ready {
            syncPushSpaces(session)
            publishDirectory(session)
        }
    }

    // Current T3 streams active shells. An active removal can also be a move into the archive.
    func refreshArchive(_ session: Session) async throws {
        try check(session)
        let snapshot = try await session.rpc.call("orchestration.getArchivedShellSnapshot")
        try check(session)
        guard let sequence = snapshot["snapshotSequence"].integer, let rows = snapshot["threads"].list else {
            throw T3ServiceError.invalidResponse
        }
        guard sequence >= (session.archiveSnapshotSequence ?? 0) else { return }
        session.archiveSnapshotSequence = sequence
        let shells = indexShells(rows, in: session)
        guard shells != session.archivedShells else { return }
        session.archivedShells = shells
        if session.ready { publishDirectory(session) }
    }

    func indexShells(_ rows: [JSONValue], in session: Session) -> [String: JSONValue] {
        var shells: [String: JSONValue] = [:]
        for row in rows where row["projectId"].text == session.profile.text && !T3ProjectionMapper.isWorkflowStep(row) {
            if let id = row["id"].nonempty { shells[id] = row }
        }
        return shells
    }

    func subscribeToThread(_ selection: Selection, in session: Session) async throws {
        let stream = try await session.subscribeThread(selection.identity.stored.text)
        let (ready, signal) = AsyncThrowingStream<Void, Error>.makeStream()
        selection.task = Task { [weak self, weak session, weak selection] in
            do {
                for try await item in stream {
                    guard let self, let session, let selection, self.session === session,
                          session.selection === selection, !Task.isCancelled else { break }
                    let hasUpdate = try self.applyThread(item, to: selection)
                    if selection.isSynchronized {
                        signal.yield(())
                        signal.finish()
                    }
                    if hasUpdate { self.publishConversation(selection, in: session) }
                }
                throw T3RPCError.closed
            } catch {
                signal.finish(throwing: error)
                guard let self, let session, let selection, self.session === session,
                      session.selection === selection, !Task.isCancelled else { return }
                selection.streamFailure = error
                if session.ready, selection.isSynchronized { self.connectionLost(session, error: error) }
            }
        }
        try await Self.waitForSubscription(ready)
    }

    func applyThread(_ item: JSONValue, to selection: Selection) throws -> Bool {
        switch item["kind"].text {
        case "snapshot":
            let projection = T3ThreadProjection(snapshot: item["projection"], sequence: item["snapshotSequence"].integer ?? 0,
                                                hasMoreHistory: item["hasMoreHistory"].flag == true, lineage: selection.lineage)
            guard projection.threadID == selection.identity.stored.text else { throw ConversationServiceError.wrongConversation }
            selection.projection = projection
            return true
        case "synchronized":
            guard selection.projection != nil else { throw T3ServiceError.invalidResponse }
            selection.isSynchronized = true
            return false
        case "event":
            guard let sequence = item["sequence"].integer, let previous = selection.projection?.sequence else {
                throw T3ServiceError.invalidResponse
            }
            selection.projection?.apply(item["event"], sequence: sequence, live: selection.isSynchronized && selection.access != nil)
            return sequence != previous && selection.projection?.sequence == sequence
        default: return false
        }
    }

    static func waitForSubscription(_ stream: AsyncThrowingStream<Void, Error>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard try await iterator.next() != nil else { throw T3RPCError.closed }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw T3RPCError.timeout
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Without a title, the thread starts untitled and T3 names it from the first message.
    func createThread(title requested: String?, operationID: UUID, in session: Session,
                      publish: Bool = true, threadID: String? = nil) async throws -> CreatedSession {
        let title = try requested.map(Self.name) ?? T3ChannelSummary.untitledWireTitle
        let id = threadID ?? T3ProjectionMapper.stableUUID("botto-channel:" + operationID.uuidString).uuidString
        let identity = try T3ProjectionMapper.identity(profile: session.profile, threadID: id)
        let model = modelSelection(session)
        guard model != .null else { throw T3ServiceError.missingModel }
        let runtime = session.config["settings"]["defaultRuntimeMode"].nonempty ?? "approval-required"
        _ = try await dispatch("thread.create", identity: identity, operationID: operationID, in: session, fields: [
            "createdBy": .string("user"), "creationSource": .string("mobile"),
            "projectId": .string(session.profile.text), "title": .string(title),
            "titleRenamed": .bool(requested != nil), "modelSelection": model, "runtimeMode": .string(runtime), "interactionMode": .string("default"),
            "branch": .null, "worktreePath": .null
        ])
        try check(session)
        if session.shells[id] == nil {
            session.shells[id] = .object(["id": .string(id), "projectId": .string(session.profile.text),
                                          "title": .string(title), "status": .string("idle"), "modelSelection": model,
                                          "updatedAt": .string(Date().ISO8601Format())])
        }
        let listing = try directory(session)
        guard let summary = listing.directory.summaries.first(where: { $0.identity == identity }) else {
            throw T3ServiceError.invalidResponse
        }
        if publish { publishDirectory(session) }
        return CreatedSession(operationID: operationID, summary: summary)
    }

    func channelCommand(_ command: String, threadID: String, fields: [String: JSONValue] = [:]) async throws {
        let session = try requireSession()
        let identity = try T3ProjectionMapper.identity(profile: session.profile, threadID: threadID)
        try validate(identity, in: session)
        _ = try await dispatch(command, identity: identity, operationID: UUID(), in: session, fields: fields)
    }

    func dispatch(_ command: String, identity: SessionIdentity, operationID: UUID, in session: Session,
                  fields: [String: JSONValue], admissionID: String? = nil) async throws -> MutationReceipt {
        var payload = fields
        payload["type"] = .string(command)
        payload["commandId"] = .string(operationID.uuidString)
        payload["threadId"] = .string(identity.stored.text)
        let result = try await mutationReply("orchestration.dispatchCommand", payload: .object(payload), in: session)
        guard let sequence = result["sequence"].integer, sequence >= 0 else { throw ConversationServiceError.uncertain }
        return MutationReceipt(operationID: operationID, source: identity, admissionID: admissionID)
    }

    func mutationReply(_ method: String, payload: JSONValue, in session: Session) async throws -> JSONValue {
        try check(session)
        do {
            return try await session.rpc.call(method, payload: payload)
        } catch {
            if case T3RPCError.remote = error { throw error }
            throw ConversationServiceError.uncertain
        }
    }

    func download(_ attachment: ChatAttachment, identity: SessionIdentity, in session: Session,
                  access: ConversationAccess) async throws -> DownloadedArtifact {
        let marker = "t3-attachment:"
        let resource: JSONValue
        if attachment.path.hasPrefix(marker) {
            let id = String(attachment.path.dropFirst(marker.count))
            guard !id.isEmpty else { throw ConversationServiceError.invalidAttachment }
            resource = .object(["_tag": .string("attachment"), "attachmentId": .string(id),
                                "fileName": .string(attachment.name), "mimeType": .string(attachment.mimeType)])
        } else {
            resource = .object(["_tag": .string("workspace-file"), "threadId": .string(identity.stored.text),
                                "path": .string(attachment.path)])
        }
        let path = try await signedAssetPath(for: resource, in: session)
        _ = try resolve(access)
        let data = try await fetchAsset(path, in: session)
        return DownloadedArtifact(data: data, filename: attachment.name, mimeType: attachment.mimeType)
    }

    func signedAssetPath(for resource: JSONValue, in session: Session) async throws -> String {
        let reply = try await session.rpc.call("assets.createUrl", payload: .object(["resource": resource]))
        guard let path = reply["relativeUrl"].text, path.hasPrefix("/api/assets/") else {
            throw T3ServiceError.invalidResponse
        }
        return path
    }

    func fetchAsset(_ path: String, in session: Session) async throws -> Data {
        let data = try await http.request(origin: session.origin, path: path)
        guard data.count <= DownloadedArtifact.maximumBytes else { throw ConversationServiceError.artifactTooLarge }
        return data
    }

    static func outputMIMEType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md": "text/markdown"
        case "txt": "text/plain"
        case "json": "application/json"
        case "html": "text/html"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "pdf": "application/pdf"
        case "csv": "text/csv"
        case "svg": "image/svg+xml"
        default: "application/octet-stream"
        }
    }

    static func routineSchedulePayload(_ schedule: T3RoutineSchedule) -> JSONValue {
        var payload: [String: JSONValue] = [
            "type": .string("fixed_time"),
            "timeOfDay": .string(String(format: "%02d:%02d", schedule.hour, schedule.minute))
        ]
        if schedule.days != T3RoutineSchedule.everyDay {
            payload["weekdays"] = .array(schedule.days.sorted().map { .number(Double($0)) })
        }
        return .object(payload)
    }

    static func routine(_ task: JSONValue) throws -> T3ScheduledRoutine {
        let wireSchedule = task["schedule"]
        guard let id = task["id"].nonempty, let title = task["title"].nonempty,
              let prompt = task["prompt"].nonempty, let enabled = task["enabled"].flag,
              let type = wireSchedule["type"].nonempty else {
            throw T3ServiceError.invalidResponse
        }
        let schedule: T3RoutineSchedule?
        if type == "fixed_time" {
            let time = wireSchedule["timeOfDay"].text?.split(separator: ":")
            let days = Set((wireSchedule["weekdays"].list ?? []).compactMap(\.integer))
            guard let time, time.count == 2, let hour = Int(time[0]), let minute = Int(time[1]),
                  let fixed = T3RoutineSchedule(hour: hour, minute: minute, days: days.isEmpty ? T3RoutineSchedule.everyDay : days) else {
                throw T3ServiceError.invalidResponse
            }
            schedule = fixed
        } else {
            schedule = nil
        }
        return T3ScheduledRoutine(id: id, name: title, prompt: prompt, schedule: schedule, enabled: enabled,
                                  threadID: task["threadId"].text, nextRunAt: T3ProjectionMapper.date(task["nextRunAt"]),
                                  lastRunAt: T3ProjectionMapper.date(task["lastRunAt"]))
    }

    func newestHistory(_ identity: SessionIdentity, in session: Session) async throws
        -> (rows: [JSONValue], messagesByID: [String: String], more: Bool) {
        let thread = try Self.pathSegment(identity.stored.text)
        let reply = try await httpJSON(session, path: "/api/orchestration/threads/" + thread + "/bounded",
                                       headers: ["x-t3-orchestration-protocol": T3RPCClient.orchestrationProtocol])
        try validate(identity, in: session)
        let projection = reply["projection"]
        guard projection["thread"]["id"].text == identity.stored.text, let rows = projection["visibleTurnItems"].list,
              let more = reply["hasMoreHistory"].flag, !more || reply["historyCursor"].nonempty != nil else {
            throw T3ServiceError.invalidResponse
        }
        let messagesByID = T3ProjectionMapper.messageTextLookup(projection["messages"].list ?? [])
        return (rows, messagesByID, more)
    }

    func httpJSON(_ session: Session, path: String, headers: [String: String]) async throws -> JSONValue {
        let data = try await http.request(origin: session.origin, path: path, token: session.token, headers: headers)
        try check(session)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"), !path.contains(":"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw T3ServiceError.invalidPath
        }
    }

    static func pathSegment(_ value: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard value != ".", value != "..", let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw T3ServiceError.invalidPath
        }
        return encoded
    }

    static func name(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw T3ServiceError.invalidName }
        return name
    }

    static func answers(_ response: RequestResponse, questions: [JSONValue]) throws -> [String: JSONValue] {
        let lines: [String]
        switch response {
        case .choice(let value):
            guard questions.count == 1 else { throw ConversationServiceError.invalidResponse }
            lines = [value]
        case .text(let input):
            if questions.count == 1 { lines = [input] }
            else { lines = input.components(separatedBy: .newlines) }
        }
        guard !questions.isEmpty, lines.count == questions.count else { throw ConversationServiceError.invalidResponse }
        var result: [String: JSONValue] = [:]
        for (question, line) in zip(questions, lines) {
            guard let id = question["id"].nonempty else { throw ConversationServiceError.invalidResponse }
            let options = question["options"].list ?? []
            let multi = question["multiSelect"].flag == true
            let answers = try (multi ? line.components(separatedBy: ",") : [line]).compactMap { value -> JSONValue? in
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty, question["required"].flag == false { return nil }
                guard !value.isEmpty else { throw ConversationServiceError.invalidResponse }
                if let choice = options.first(where: { $0["value"].text == value || $0["label"].text == value }) {
                    return .string(choice["value"].nonempty ?? value)
                }
                guard options.isEmpty || question["allowCustomAnswer"].flag == true else {
                    throw ConversationServiceError.invalidResponse
                }
                return .string(value)
            }
            if multi { result[id] = .array(answers) }
            else { result[id] = answers.first }
        }
        return result
    }
}
