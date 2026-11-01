import Foundation

/// One authenticated HTTP session and one multiplexed socket for a host's bots.
/// Closing the client never stops server work. Mutations are sent once, never retried.
@MainActor public final class HermesBotService: BotService {
    public var onEvent: ((BotServiceEvent) -> Void)?
    let transportFactory: () -> any HermesTransport
    let timing: HermesGateway.Timing
    let journal: HermesSubmissionJournal
    var configuration: ConnectionConfiguration?
    var info: ServerInfo?
    var http: HermesHTTPConnection?
    var retiredHTTP: [HermesHTTPConnection] = []
    var gateway: HermesGateway?
    var adapter = HermesSessionAdapter.sidecar
    var connecting: Task<ServerInfo, Error>?
    var reconnecting: Task<Void, Never>?
    var refreshingChat: Task<Void, Never>?
    var connectionGeneration = 0
    var selectionGeneration = 0
    var selectedTarget: SessionIdentity?
    var selectedCanonical = false
    var issuer = ConversationIssuer<AccessContext>()
    var publication: OpenedConversation?
    var reconciling = false
    var catalogs: [ExactID: ConversationDirectory] = [:]
    var observedInventory: [ExactID: [SessionSummary]] = [:]
    struct CatalogRead {
        let id: UUID
        let owner: Int
        let task: Task<ConversationDirectory, Error>
    }
    var catalogReads: [ExactID: CatalogRead] = [:]
    var catalogCounts: [ExactID: Int] = [:]
    var discoveryHints: [ExactID: DirectoryProbe] = [:]
    var knownCreated: [ExactID: [SessionSummary]] = [:]
    var freshEmpty: Set<SessionIdentity> = []
    var createdRuntimes: [SessionIdentity: ExactID] = [:]
    var knownAliasOwners: [ExactID: Set<ExactID>] = [:]
    var runtimeOwners: [ExactID: SessionIdentity] = [:]
    var creatingSessions: Set<ExactID> = []
    var operations: Set<UUID> = []
    var state: HermesConversationState?
    var attaching = false
    var attached = false
    var held: [HermesJSON] = []
    var pendingStopObservation: HermesStopObservation?
    var holdOverflow = false
    var active = true
    var savingAvatars = Set<String>()
    var creating = false
    var sending: Set<SessionIdentity> = []
    var answering: Set<String> = []
    var uploads: [String: UploadedFile] = [:]
    struct UploadedFile {
        let attachment: ChatAttachment
        let profile: String
        let stored: String
        let bytes: Int
        let reference: String?
        let nativeImage: Bool
    }

    public convenience init() {
        self.init(transportFactory: { NativeHermesTransport() }, timing: .init(), journal: HermesSubmissionJournal())
    }
    init(transportFactory: @escaping () -> any HermesTransport, timing: HermesGateway.Timing = .init(),
         journal: HermesSubmissionJournal = HermesSubmissionJournal()) {
        self.transportFactory = transportFactory; self.timing = timing; self.journal = journal
    }

    public func connect(configuration supplied: ConnectionConfiguration) async throws -> ServerInfo {
        active = true
        if let current = configuration, current.id == supplied.id, current.serverURL == supplied.serverURL,
           current.username == supplied.username, current.password == supplied.password,
           current.connectionHeaders == supplied.connectionHeaders,
           current.nativeCredential == supplied.nativeCredential,
           current.installID == supplied.installID || supplied.installID == nil {
            if let connecting { return try await connecting.value }
            if let info, gateway?.isOpen == true { return info }
        } else {
            disconnect()
            active = true; selectedTarget = nil; catalogs = [:]; catalogCounts = [:]; discoveryHints = [:]; observedInventory = [:]; knownCreated = [:]; freshEmpty = []; createdRuntimes = [:]; knownAliasOwners = [:]; runtimeOwners = [:]; operations = []; state = nil; uploads = [:]
            configuration = supplied
        }
        configuration = configuration ?? supplied
        return try await establish()
    }

    func establish() async throws -> ServerInfo {
        if let connecting { return try await connecting.value }
        guard let configuration else { throw HermesServiceError.disconnected }
        connectionGeneration += 1
        let owner = connectionGeneration
        gateway?.close()
        if let http { http.retire(); retiredHTTP.append(http) }
        retireAccess(); uploads = [:]
        attached = false
        let attempt = Task { @MainActor [weak self] () throws -> ServerInfo in
            guard let self else { throw HermesServiceError.disconnected }
            let oldConnections = retiredHTTP
            for old in oldConnections { await old.finishRefresh() }
            retiredHTTP.removeAll { old in oldConnections.contains { $0 === old } }
            try checkConnection(owner)
            let current = self.configuration?.id == configuration.id ? self.configuration! : configuration
            let http = try HermesHTTPConnection(configuration: current, transport: transportFactory())
            self.http = http
            http.onConfiguration = { [weak self] updated in
                guard let self else { return }
                if self.configuration?.id == updated.id, self.configuration?.serverURL == updated.serverURL,
                   self.configuration?.username == updated.username { self.configuration = updated }
                self.onEvent?(.configuration(updated))
            }
            do {
                let info = try await http.authenticate()
                try checkConnection(owner)
                let socket = HermesGateway(http: http, timing: timing)
                gateway = socket
                socket.onFrame = { [weak self] frame in
                    guard let self, self.connectionGeneration == owner else { return }
                    self.observeStop(frame)
                    self.receive(frame)
                }
                socket.onDisconnect = { [weak self] error in
                    guard let self, self.connectionGeneration == owner else { return }; self.lost(error)
                }
                try await socket.open()
                try checkConnection(owner)
                adapter = socket.usesAuthority ? .authority : .sidecar
                if adapter == .authority {
                    let description = try await socket.call("runtime.describe", [:])
                    guard description["capabilities"].list?.contains(.string("durable-admission-v1")) == true,
                          description["capabilities"].list?.contains(.string("event-replay-v1")) == true,
                          description["session_create"]["sources"].list?.contains(.string("gui")) == true
                    else { throw HermesServiceError.incompatible }
                }
                self.info = info
                return info
            } catch {
                if owner == connectionGeneration { resetGateway(); http.retire() }
                throw error
            }
        }
        connecting = attempt
        defer { if owner == connectionGeneration { connecting = nil } }
        return try await attempt.value
    }

    public func disconnect() {
        issuer.close(); issuer = ConversationIssuer<AccessContext>(); publication = nil; uploads = [:]
        active = false; connectionGeneration += 1; selectionGeneration += 1
        reconnecting?.cancel(); reconnecting = nil
        refreshingChat?.cancel(); refreshingChat = nil
        connecting?.cancel(); connecting = nil
        resetGateway()
        if let http { http.retire(); retiredHTTP.append(http) }
        http = nil
        attached = false; attaching = false; held = []; answering = []; savingAvatars = []
    }

    public func bots() async throws -> [BotProfile] {
        let gateway = try readyGateway()
        let owner = connectionGeneration
        let reply = try await gateway.call("profiles.list", ["include_sessions": .bool(true)])
        try checkConnection(owner)
        if let install = reply["install_id"].nonempty, install != info?.installID { throw HermesServiceError.differentHost }
        guard var rows = reply["profiles"].list else { throw HermesServiceError.incompatible }
        // Authority inventory belongs to the routed profile. Legacy sidecars instead
        // return every runtime without a profile, so repeated stored keys are ambiguous.
        var canonicalKeys: [String: Set<String>] = [:]
        for row in rows {
            guard let profile = row["name"].nonempty else { continue }
            for key in [row["canonical_session"]["id"].nonempty, row["canonical_session"]["resolved_id"].nonempty].compactMap({ $0 }) {
                canonicalKeys[profile, default: []].insert(key)
                if let alias = try? ExactID(key), let owner = try? ExactID(profile) { knownAliasOwners[alias, default: []].insert(owner) }
            }
        }
        for directory in catalogs.values {
            for summary in directory.summaries {
                for alias in summary.identity.aliases { knownAliasOwners[alias, default: []].insert(summary.identity.profile) }
            }
        }
        var statuses: [String: BotStatus] = [:]
        var activityReplies: [ExactID: HermesJSON] = [:]
        if adapter == .authority {
            // Independent reads share the multiplexed socket. Collect locally before
            // applying them, rather than accumulating one profile's latency per await.
            let reads = await withTaskGroup(of: (String, Bool, HermesJSON?).self) { group in
                for profile in rows.compactMap({ $0["name"].nonempty }) {
                    group.addTask {
                        let reply = await self.activeSessions(profile: profile, socket: gateway, owner: owner)
                        return (profile, false, reply)
                    }
                }
                // Authority discovery rows omit image presence and CAS revisions. Only
                // the routed profile's own row is authoritative for its appearance.
                let incomplete = Set(rows.filter { !Self.hasAppearanceMetadata($0) }.compactMap { $0["name"].nonempty })
                for profile in incomplete {
                    group.addTask {
                        let row = try? await self.appearanceRow(profile: profile, socket: gateway, owner: owner)
                        return (profile, true, row)
                    }
                }
                var activities: [String: HermesJSON] = [:], appearances: [String: HermesJSON] = [:]
                for await (profile, appearance, reply) in group {
                    if appearance { appearances[profile] = reply } else { activities[profile] = reply }
                }
                return (activities: activities, appearances: appearances)
            }
            try checkConnection(owner)
            for index in rows.indices {
                guard let profile = rows[index]["name"].text, let appearance = reads.appearances[profile] else { continue }
                for key in ["ui_meta", "ui_meta_revisions", "has_avatar"] { rows[index][key] = appearance[key] }
            }
            for (profile, activity) in reads.activities {
                if let key = try? ExactID(profile) { activityReplies[key] = activity }
                for item in activity["sessions"].list ?? [] {
                    guard item["session_key"].nonempty != nil,
                          let status = Self.liveStatus(item["status"].text) else { continue }
                    if matchesSelectedActivity(item, profile: profile, canonicalKeys: canonicalKeys) { continue }
                    statuses[profile] = Self.strongest([statuses[profile], status].compactMap { $0 })
                }
            }
        } else if let activity = try? await gateway.call("session.active_list", [:], validate: { try self.checkConnection(owner) }) {
            try checkConnection(owner)
            for row in rows {
                if let name = row["name"].nonempty, let profile = try? ExactID(name) { activityReplies[profile] = activity }
            }
            for item in activity["sessions"].list ?? [] {
                guard let status = Self.liveStatus(item["status"].text) else { continue }
                let profile: String
                if let runtime = item["id"].nonempty.flatMap({ try? ExactID($0) }), let verified = runtimeOwners[runtime] {
                    profile = verified.profile.text
                } else if let key = item["session_key"].nonempty.flatMap({ try? ExactID($0) }),
                          let owners = knownAliasOwners[key], owners.count == 1, let owner = owners.first {
                    profile = owner.text
                } else { continue }
                if matchesSelectedActivity(item, profile: profile, canonicalKeys: canonicalKeys) { continue }
                statuses[profile] = Self.strongest([statuses[profile], status].compactMap { $0 })
            }
        }
        var result = rows.compactMap(Self.profile)
        for index in result.indices {
            if let status = statuses[result[index].id] { result[index].status = status }
        }
        if let state, attached, (!selectedCanonical || canonicalKeys[state.conversation.profileID]?.contains(state.root) != false),
           let index = result.firstIndex(where: { $0.id == state.conversation.profileID }) {
            result[index].status = Self.strongest([result[index].status, state.conversation.pendingRequests.isEmpty ? (state.conversation.isWorking ? .working : .idle) : .waiting]) ?? .idle
        }
        try checkConnection(owner)
        guard gateway.isOpen else { throw HermesServiceError.disconnected }
        try await publishDirectoryChanges(profiles: rows, owner: owner, socket: gateway)
        try publishActivity(profiles: rows, replies: activityReplies, owner: owner, socket: gateway)
        return result
    }

    public func createBot(_ draft: BotDraft) async throws -> BotProfile {
        try draft.avatar.validate()
        guard !creating else { throw HermesServiceError.staleConversation }
        guard draft.model?.isEmpty != false else { throw HermesServiceError.modelSelection }
        let name = draft.profileID
        guard Self.validProfileName(name), !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HermesServiceError.invalidName }
        creating = true; defer { creating = false }
        let socket = try readyGateway(), owner = connectionGeneration
        guard !(try await bots()).contains(where: { $0.id == name }) else { throw HermesServiceError.nameTaken }
        try checkConnection(owner)
        var params: [String: HermesJSON] = ["name": .string(name), "share_auth": .bool(true)]
        if adapter == .authority { params["no_alias"] = .bool(true) }
        if !draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { params["soul"] = .string(draft.instructions) }
        let reply = try await socket.call("profiles.create", params, mutation: true, validate: { try self.checkConnection(owner) })
        guard reply["ok"].flag == true else { throw HermesServiceError.uncertain }
        onEvent?(.botsChanged)
        do {
            try checkConnection(owner)
            guard draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reply["soul_written"].flag == true else { throw HermesServiceError.partialCreation }
            let look = draft.avatar.merging(into: ["title": .string(draft.name)])
            let configured = try await socket.call("profiles.configure", ["name": .string(name),
                "ui_meta": .object(["hermes-bots": .object(look)]),
                "ui_meta_expected_revisions": .object(["hermes-bots": .number(0)])], mutation: true,
                validate: { try self.checkConnection(owner) })
            guard configured["applied"]["ui_meta"].flag == true else { throw HermesServiceError.partialCreation }
            let rows = try await awaitCreatedProfile(name, socket: socket, owner: owner)
            if rows.isEmpty {
                let created = try await socket.call("session.create", adapter.create(profile: name, requestID: UUID().uuidString),
                                                    mutation: true, validate: { try self.checkConnection(owner) })
                guard let runtime = created["session_id"].nonempty else { throw HermesServiceError.partialCreation }
                if adapter == .sidecar {
                    do { _ = try await socket.call("session.title", ["profile": .string(name), "session_id": .string(runtime), "title": .string("Bot Chat")],
                                                    mutation: true, validate: { try self.checkConnection(owner) }) }
                    catch HermesServiceError.rejected(4022) {
                        guard try await canonicalRows(profile: name, socket: socket).count == 1 else { throw HermesServiceError.partialCreation }
                    }
                }
            } else if rows.count != 1 { throw HermesServiceError.partialCreation }
            guard let bot = try await bots().first(where: { $0.id == name }) else { throw HermesServiceError.partialCreation }
            onEvent?(.botsChanged)
            if reply["model_set"].flag != true, reply["mirrored"]["model_inherited"].flag != true,
               bot.model?.isEmpty != false {
                // Inheritance also reports false when create_profile already seeded a
                // model. Read the effective profile before diagnosing a missing model.
                let details = try await socket.call("profiles.describe", ["name": .string(name)])
                try checkConnection(owner)
                guard details["model"]["default"].nonempty != nil else { throw HermesServiceError.missingModel }
            }
            return bot
        } catch HermesServiceError.missingModel { throw HermesServiceError.missingModel }
        catch { onEvent?(.botsChanged); throw HermesServiceError.partialCreation }
    }

    public func avatarAsset(for bot: BotProfile) async throws -> BotAvatarAsset? {
        guard Self.safeSegment(bot.id) else { throw HermesServiceError.profileUnavailable }
        let socket = try readyGateway(), owner = connectionGeneration
        let reply = try await socket.call("profiles.get_asset", ["name": .string(bot.id), "asset": .string("avatar")],
            timeoutPolicy: .requestOnly, validate: { try self.checkConnection(owner) })
        try checkConnection(owner)
        let asset = await Task.detached(priority: .utility) { BotAvatarAsset(reply: reply) }.value
        try checkConnection(owner)
        return asset
    }

    /// Explicit user selection only. Read, merge and CAS the shared look before clearing an image.
    /// The two RPCs cannot be atomic; a partial or uncertain write is never retried here.
    public func setAvatar(_ choice: BotAvatarChoice, for bot: BotProfile) async throws -> BotProfile {
        try choice.validate()
        guard Self.safeSegment(bot.id), !savingAvatars.contains(bot.id) else { throw HermesServiceError.avatarConflict }
        let socket = try readyGateway(), owner = connectionGeneration
        savingAvatars.insert(bot.id)
        defer { if owner == connectionGeneration { savingAvatars.remove(bot.id) } }
        var row = try await appearanceRow(profile: bot.id, socket: socket, owner: owner)
        guard let fresh = Self.profile(row), let revision = Self.appearanceRevision(row) else { throw HermesServiceError.incompatible }
        // Only the avatar that was presented may be replaced. The namespace revision
        // also covers title/pins/groups, so merge those changes rather than rejecting
        // every revision bump. Asset bytes have no revision/CAS: an asset-only change
        // with identical metadata (or one after this read) cannot be detected here.
        guard (fresh.hasAvatar == true) == (bot.hasAvatar == true),
              (fresh.appearance ?? BotAppearance()) == (bot.appearance ?? BotAppearance()) else {
            throw HermesServiceError.avatarConflict
        }
        try choice.validate(current: fresh.appearance)
        let look = choice.merging(into: row["ui_meta"]["hermes-bots"].fields ?? [:])
        let configured: HermesJSON
        do {
            configured = try await socket.call("profiles.configure", ["name": .string(bot.id),
                "ui_meta": .object(["hermes-bots": .object(look)]),
                "ui_meta_expected_revisions": .object(["hermes-bots": .number(Double(revision))])],
                mutation: true, validate: { try self.checkConnection(owner) })
            try checkConnection(owner)
        } catch HermesServiceError.rejected(let code) { throw HermesServiceError.rejected(code) }
        catch { throw HermesServiceError.uncertainAvatar }
        guard configured["applied"]["ui_meta"].flag == true else {
            if configured["applied"]["ui_meta_conflicts"] != .null { throw HermesServiceError.avatarConflict }
            throw HermesServiceError.uncertainAvatar
        }
        if fresh.hasAvatar == true {
            do {
                let cleared = try await socket.call("profiles.set_asset", ["name": .string(bot.id), "asset": .string("avatar"), "clear": .bool(true)],
                    mutation: true, validate: { try self.checkConnection(owner) })
                try checkConnection(owner)
                guard cleared["ok"].flag == true, cleared["asset"].text == "avatar" else { throw HermesServiceError.partialAvatar }
            } catch { throw HermesServiceError.partialAvatar }
        }
        try checkConnection(owner)
        row["ui_meta"]["hermes-bots"] = .object(look)
        row["ui_meta_revisions"]["hermes-bots"] = configured["applied"]["ui_meta_revisions"]["hermes-bots"]
        row["has_avatar"] = .bool(false)
        guard let saved = Self.profile(row) else { throw HermesServiceError.partialAvatar }
        onEvent?(.botsChanged)
        return saved
    }

    func receive(_ frame: HermesJSON) {
        if ["sessions.changed", "profiles.changed"].contains(frame["type"].text ?? "") { onEvent?(.botsChanged); return }
        if attaching {
            if held.count < 2048 { held.append(frame) } else { holdOverflow = true }
            return
        }
        guard attached, let current = state else { return }
        if frame["id"].text != nil, frame["method"].text != nil {
            guard exact(frame["params"]["session_id"].text, current.conversation.id),
                  frame["params"]["profile_name"].text.map({ exact($0, current.conversation.profileID) }) != false else { return }
            retireAccess(); state?.serverRequest(frame, live: !reconciling); emitConversation(); onEvent?(.botsChanged); return
        }
        if frame["type"].text == "session.reclaimed",
           exact(frame["payload"]["session_id"].text, current.conversation.id) { scheduleRefresh(); return }
        guard exact(frame["session_id"].text, current.conversation.id),
              frame["profile_name"].text.map({ exact($0, current.conversation.profileID) }) != false,
              frame["profile_id"].text.map({ exact($0, current.profileIdentity) }) != false else { return }
        if frame["type"].text == "session.replay_gap" { scheduleRefresh(); return }
        if adapter == .authority, !exact(frame["replay_epoch"].text, current.epoch) { scheduleRefresh(); return }
        guard let next = frame["seq"].integer, next > 0 else { scheduleRefresh(); return }
        if next <= current.conversation.lastSequence { return }
        guard next == current.conversation.lastSequence + 1 else { scheduleRefresh(); return }
        let acceptedExecution = current.motion.acceptsTranscript(frame, authority: adapter == .authority)
        if ["approval.request", "approval.settled", "clarify.request", "clarify.settled", "request.cancel", "approval.cancelled"].contains(frame["type"].text ?? "") { retireAccess() }
        state?.reduce(frame, authority: adapter == .authority, live: !reconciling)
        emitConversation()
        if acceptedExecution, ["message.complete", "session.info", "approval.request", "approval.settled", "clarify.request", "clarify.settled", "request.cancel"].contains(frame["type"].text ?? "") {
            onEvent?(.botsChanged)
        }
        if acceptedExecution, frame["type"].text == "message.complete", !reconciling { scheduleRefresh() }
    }

    func scheduleRefresh() {
        guard refreshingChat == nil, let target = selectedTarget, active, gateway?.isOpen == true else { return }
        retireAccess()
        attached = false; attaching = true; held = []; holdOverflow = false
        let owner = selectionGeneration
        refreshingChat = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.selectionGeneration == owner else { return }
            defer { if self.selectionGeneration == owner { self.refreshingChat = nil } }
            do { _ = try await self.attach(identity: target, owner: owner) }
            catch {
                guard self.selectionGeneration == owner, self.active, !Task.isCancelled else { return }
                self.lost(error as? HermesServiceError ?? .disconnected)
            }
        }
    }

    func lost(_ error: HermesServiceError) {
        resetGateway()
        refreshingChat?.cancel(); refreshingChat = nil
        onEvent?(.disconnected(error.localizedDescription))
        guard Self.retryable(error) else { reconnecting?.cancel(); reconnecting = nil; return }
        guard active, reconnecting == nil else { return }
        reconnecting = Task { [weak self] in
            let delays = self?.timing.reconnectDelays ?? []
            for delay in delays {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.active else { return }
                var recoveredGateway: HermesGateway?
                do {
                    let info = try await self.establish()
                    recoveredGateway = self.gateway
                    if let target = self.selectedTarget {
                        self.selectionGeneration += 1
                        _ = try await self.attach(identity: target, owner: self.selectionGeneration)
                    }
                    self.reconnecting = nil
                    self.onEvent?(.connected(info)); self.onEvent?(.botsChanged)
                    return
                } catch {
                    if let recoveredGateway, self.gateway === recoveredGateway { self.resetGateway() }
                    guard self.active, !Task.isCancelled else { return }
                    let failure = error as? HermesServiceError ?? .disconnected
                    self.onEvent?(.disconnected(failure.localizedDescription))
                    if !Self.retryable(failure) { self.reconnecting = nil; return }
                }
            }
            self?.reconnecting = nil
        }
    }

    func resetGateway() {
        pendingStopObservation = nil
        state?.motion.canRetain = false
        retireAccess(); runtimeOwners = [:]
        for read in catalogReads.values { read.task.cancel() }
        catalogReads = [:]; discoveryHints = [:]
        gateway?.close(); gateway = nil; info = nil
        attached = false; attaching = false; held = []; holdOverflow = false
    }

    func readyGateway() throws -> HermesGateway {
        guard active, let gateway, gateway.isOpen, connecting == nil else { throw HermesServiceError.disconnected }
        return gateway
    }
    func requireSelected(_ conversation: Conversation) throws -> HermesGateway {
        let gateway = try readyGateway()
        guard attached, exact(state?.conversation.id, conversation.id), exact(state?.conversation.profileID, conversation.profileID),
              exact(state?.conversation.storedID, conversation.storedID) else { throw HermesServiceError.staleConversation }
        return gateway
    }
    func checkSelected(_ conversation: Conversation, selection: Int, connection: Int) throws {
        try checkSelection(selection, connection: connection); _ = try requireSelected(conversation)
    }
    func checkSelection(_ selection: Int, connection: Int) throws {
        try checkConnection(connection)
        guard selection == selectionGeneration else { throw HermesServiceError.staleConversation }
    }
    func checkConnection(_ owner: Int) throws {
        guard owner == connectionGeneration, active, !Task.isCancelled else { throw HermesServiceError.disconnected }
    }
    func canonicalRows(profile: String, socket: HermesGateway) async throws -> [HermesJSON] {
        let reply = try await socket.call("session.list", ["profile": .string(profile), "title": .string("Bot Chat"), "include_hidden": .bool(true)])
        guard let rows = reply["sessions"].list else { throw HermesServiceError.incompatible }
        return rows
    }
    func activeSessions(profile: String, socket: HermesGateway, owner: Int) async -> HermesJSON? {
        try? await socket.call("session.active_list", ["profile": .string(profile)],
            validate: { try self.checkConnection(owner) })
    }
    func appearanceRow(profile: String, socket: HermesGateway, owner: Int) async throws -> HermesJSON {
        guard Self.safeSegment(profile) else { throw HermesServiceError.profileUnavailable }
        var params: [String: HermesJSON] = ["include_sessions": .bool(false)]
        if adapter == .authority { params["profile"] = .string(profile) }
        let reply = try await socket.call("profiles.list", params, timeoutPolicy: .requestOnly,
            validate: { try self.checkConnection(owner) })
        try checkConnection(owner)
        if let install = reply["install_id"].nonempty, install != info?.installID { throw HermesServiceError.differentHost }
        let matches = reply["profiles"].list?.filter { $0["name"].text == profile } ?? []
        guard matches.count == 1, let row = matches.first else { throw HermesServiceError.profileUnavailable }
        guard Self.hasAppearanceMetadata(row) else { throw HermesServiceError.incompatible }
        return row
    }
    static func appearanceRevision(_ row: HermesJSON) -> Int? {
        // A present map feature-detects CAS. An absent namespace in that map means
        // revision zero; a missing map is unknown and must never authorize a write.
        guard let revisions = row["ui_meta_revisions"].fields else { return nil }
        guard let value = revisions["hermes-bots"] else { return 0 }
        guard let revision = value.integer, revision >= 0 else { return nil }
        return revision
    }
    static func hasAppearanceMetadata(_ row: HermesJSON) -> Bool {
        appearanceRevision(row) != nil && row["has_avatar"].flag != nil
            && (row["ui_meta"] == .null || row["ui_meta"].fields != nil)
            && (row["ui_meta"]["hermes-bots"] == .null || row["ui_meta"]["hermes-bots"].fields != nil)
    }
    func awaitCreatedProfile(_ name: String, socket: HermesGateway, owner: Int) async throws -> [HermesJSON] {
        // A current authority starts serving a newly created profile on its reconciler.
        // Wait on reads only; a creation or title mutation is never repeated.
        for attempt in 0..<45 {
            try checkConnection(owner)
            if adapter == .authority, let http {
                let status = try await http.json("api/status")
                try checkConnection(owner)
                if let install = status["install_id"].text, install != info?.installID { throw HermesServiceError.differentHost }
                if let served = status["gateway_shared_with"].list, !served.contains(.string(name)) {
                    if attempt == 44 { throw HermesServiceError.profileUnavailable }
                    try await Task.sleep(for: .seconds(1)); continue
                }
            }
            do { return try await canonicalRows(profile: name, socket: socket) }
            catch HermesServiceError.profileUnavailable where adapter == .authority && attempt < 44 {
                try await Task.sleep(for: .seconds(1)); try checkConnection(owner)
            }
        }
        throw HermesServiceError.profileUnavailable
    }
    func emitConversation(readEvidence: ConversationReadEvidence? = nil) {
        guard !reconciling, attached else { return }
        projectStoppedOutcome()
        guard let state, let identity = selectedTarget else { return }
        let context = AccessContext(identity: identity, state: state, selection: selectionGeneration, connection: connectionGeneration)
        do {
            if publication == nil || accessContextChanged(context) {
                publication = OpenedConversation(identity: identity, snapshot: state.conversation, access: try issuer.issue(context),
                    readEvidence: readEvidence, activity: state.motion.activity)
            } else if let old = publication {
                publication = OpenedConversation(identity: identity, snapshot: state.conversation, access: old.access,
                    readEvidence: readEvidence, activity: state.motion.activity)
            }
            if let publication { onEvent?(.conversation(publication)) }
            self.state?.motion.reaction = nil
            self.state?.motion.signal = nil
        } catch { retireAccess() }
    }
    static func retryable(_ error: HermesServiceError) -> Bool {
        switch error {
        case .disconnected, .timeout, .uncertain, .rejected(408), .rejected(429), .rejected(500...599), .rejected(4007), .rejected(4009): true
        default: false
        }
    }
    static func profile(_ row: HermesJSON) -> BotProfile? {
        guard let id = row["name"].nonempty else { return nil }
        let look = row["ui_meta"]["hermes-bots"], canonical = row["canonical_session"]
        return BotProfile(id: id, name: look["title"].nonempty ?? row["display_name"].nonempty ?? id,
            emoji: row["ui_meta"]["botto"]["emoji"].nonempty ?? "✳️", description: row["description"].text ?? "",
            preview: canonical["preview"].text ?? "", updatedAt: canonical["last_active"].date,
            status: .idle, isPinned: look["pinned"].flag == true, model: row["model"].nonempty,
            appearance: BotAppearance(rawShape: look["shape"].text,
                color: look["color"].text, custom: look["custom"].flag == true,
                imageKind: look["imageKind"].text, expression: look["expression"].text),
            hasAvatar: row["has_avatar"].flag, lookRevision: appearanceRevision(row))
    }
    static func liveStatus(_ wire: String?) -> BotStatus? {
        switch wire {
        case "waiting": .waiting
        case "working", "starting", "streaming": .working
        case "idle": .idle
        default: nil
        }
    }
    static func validProfileName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first.isNumber,
              !["hermes", "default", "test", "tmp", "root", "sudo"].contains(name), name.count <= 64 else { return false }
        return true
    }
    static func safeSegment(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}
