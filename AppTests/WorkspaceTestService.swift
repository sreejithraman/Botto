import Foundation
import BottoCore

@MainActor final class WorkspaceTestService: BotService {
    var onEvent: ((BotServiceEvent) -> Void)?
    var onOpen: (() -> Void)?
    var onDownload: (() -> Void)?
    var downloadData = Data("artifact".utf8)
    var downloadError: (any Error)?
    var downloads = 0
    let issuer = ConversationIssuer<SessionIdentity>()
    let profile: ExactID
    var summaries: [SessionSummary]
    var snapshots: [ExactID: Conversation] = [:]
    var openError: (any Error)?
    var beforeOpenReturn: ((OpenedConversation) -> Void)?
    var openResult: ((OpenedConversation) throws -> OpenedConversation)?
    var completedOpens: [OpenedConversation] = []
    var stopGate: WorkspaceGate?
    var responseGate: WorkspaceGate?
    var pushRemovalGate: WorkspaceGate?
    var pushStatusResult: PushHostStatus?
    var pushStatuses: [String: PushHostStatus] = [:]
    var pushStatusGate: WorkspaceGate?
    var pushStatusGatedProfileID: String?
    var pushStatusError: (any Error)?
    var pushStatusCalls: [String] = []
    var pushEnrollments: [(PushEnrollmentRequest, String, ConnectionConfiguration?)] = []
    private(set) var connectedConfiguration: ConnectionConfiguration?
    var connectError: (any Error)?
    private(set) var connectionAttempts = 0
    var stops: [UUID] = []
    var sendError: (any Error)?
    var deliveries: [MessageDelivery] = []
    var replacementGate: WorkspaceGate?
    var replacementError: (any Error)?
    var acceptsReplacementBeforeGate = false
    var replacements: [(QueuedMessage, String, SessionIdentity, UUID)] = []
    var sendGate: WorkspaceGate?
    var createGate: WorkspaceGate?
    var openGate: WorkspaceGate?
    var openGatedProfile: ExactID?
    var directoryGate: WorkspaceGate?
    var directoryGatedProfile: ExactID?
    var uploadGate: WorkspaceGate?
    var downloadGate: WorkspaceGate?
    var createError: (any Error)?
    var directoryError: (any Error)?
    var directoryComplete = true
    var directoryResult: ConversationDirectory?
    var readSummaryAvailable = true
    var directoryActivity: [SessionIdentity: ObservedActivity] = [:]
    var sends: [(String, [ChatAttachment], SessionIdentity, UUID)] = []
    var creates: [UUID] = []
    var opens: [SessionIdentity] = []
    var uploads: [SessionIdentity] = []
    var responses: [PendingRequest] = []
    var responseError: (any Error)?
    var responseOperations: [UUID] = []
    var directoryCalls = 0
    var rosterActivity: [SessionIdentity: ObservedActivity] = [:]
    var rosterStatus: BotStatus = .idle
    var rosterBot: BotProfile?
    var rosterGate: WorkspaceGate?
    private(set) var rosterCalls = 0
    var rosterError: (any Error)?
    var rosterProfiles: [BotProfile]?
    var previewGate: WorkspaceGate?
    var previewError: (any Error)?
    var previewResult: ConversationPreviewRead?
    var previewReads: [SessionIdentity] = []
    var directoryChanges: Set<ExactID> = []
    var journal: JournalDurability = .saved
    init() throws {
        profile = try ExactID("milo")
        let main = SessionIdentity(profile: profile, root: try ExactID("main-root"), stored: try ExactID("main-tip"), aliases: [])
        let other = SessionIdentity(profile: profile, root: try ExactID("other-root"), stored: try ExactID("other-tip"), aliases: [])
        summaries = [.init(identity: main, title: "Bot Chat", isCanonical: true, persistence: .durable),
                     .init(identity: other, title: "Other", isCanonical: false, persistence: .durable)]
        for summary in summaries {
            snapshots[summary.identity.root] = .init(id: summary.identity.root.text, storedID: summary.identity.stored.text,
                profileID: profile.text, messages: [.init(id: summary.identity.root.text + "-message", role: .assistant, text: summary.title)])
        }
    }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        connectionAttempts += 1
        if let connectError { throw connectError }
        connectedConfiguration = configuration
        return .init(version: "test")
    }
    func disconnect() { issuer.retireAttachment() }
    func pushStatus(profileID: String) async throws -> PushHostStatus {
        pushStatusCalls.append(profileID)
        let result = pushStatuses[profileID] ?? pushStatusResult
        if pushStatusGatedProfileID == nil || pushStatusGatedProfileID == profileID { await pushStatusGate?.wait() }
        if let pushStatusError { throw pushStatusError }
        guard let result else { throw PushError.unsupported }
        return result
    }
    func enrollPushDevice(_ request: PushEnrollmentRequest, profileID: String) async throws -> PushEnrollment {
        pushEnrollments.append((request, profileID, connectedConfiguration))
        guard let pushStatusResult, let installationID = pushStatusResult.installationID else { throw PushError.unsupported }
        return .init(installationID: installationID, deviceID: request.deviceID, generation: 1, preferences: request.preferences)
    }
    func removePushDevice(deviceID: String, operationID: UUID, profileID: String) async throws -> PushRemovalResult {
        await pushRemovalGate?.wait()
        return .init(status: "revoked")
    }
    func bots() async throws -> [BotProfile] {
        rosterCalls += 1
        await rosterGate?.wait()
        if let rosterError { throw rosterError }
        let changes = directoryChanges; directoryChanges = []
        for profile in changes { onEvent?(.conversationDirectoryChanged(profile: profile)) }
        if !rosterActivity.isEmpty { onEvent?(.activity(profile: profile, observations: rosterActivity)) }
        return rosterProfiles ?? [rosterBot ?? .init(id: profile.text, name: "Milo", status: rosterStatus)]
    }
    func createBot(_ draft: BotDraft) async throws -> BotProfile { .init(id: profile.text, name: draft.name) }
    func setAvatar(_ choice: BotAvatarChoice, for bot: BotProfile) async throws -> BotProfile { bot }
    func avatarAsset(for bot: BotProfile) async throws -> BotAvatarAsset? { nil }
    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        directoryCalls += 1
        let captured = directoryResult
        if directoryGatedProfile == nil || directoryGatedProfile == profile { await directoryGate?.wait() }
        if let directoryError { throw directoryError }
        if let captured { return captured }
        return .init(summaries: summaries.filter { $0.identity.profile == profile }, activity: directoryActivity, isComplete: directoryComplete)
    }
    func conversationPreview(_ identity: SessionIdentity) async throws -> ConversationPreviewRead {
        previewReads.append(identity)
        let result = previewResult ?? .init(preview: snapshots[identity.root].flatMap {
            ConversationPreview.latest(in: $0.messages)
        }, isComplete: true)
        await previewGate?.wait()
        if let previewError { throw previewError }
        return result
    }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession {
        creates.append(operationID)
        await createGate?.wait()
        if let createError { throw createError }
        let identity = SessionIdentity(profile: profile, root: try ExactID("created-\(operationID)"), stored: try ExactID("created-tip-\(operationID)"), aliases: [])
        let summary = SessionSummary(identity: identity, title: "New chat", isCanonical: false, persistence: .liveOnly)
        summaries.append(summary)
        snapshots[identity.root] = .init(id: identity.root.text, storedID: identity.stored.text, profileID: profile.text)
        return .init(operationID: operationID, summary: summary)
    }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let identity: SessionIdentity
        switch target {
        case .canonical(let profile, _): identity = summaries.first { $0.isCanonical && $0.identity.profile == profile }!.identity
        case .stored(let stored): identity = stored
        }
        opens.append(identity)
        onOpen?()
        issuer.retireAttachment()
        // This method models a complete read. Capture inventory before the held read,
        // never from metadata that arrives while it is suspended.
        let observed = readSummaryAvailable ? summaries.first { $0.identity.profile == identity.profile && $0.identity.root == identity.root
            && $0.identity.stored == identity.stored } : nil
        let opened = try publication(identity, readEvidence: observed.map(ConversationReadEvidence.init))
        if openGatedProfile == nil || openGatedProfile == identity.profile { await openGate?.wait() }
        if let openError { throw openError }
        let result = try openResult?(opened) ?? opened
        beforeOpenReturn?(result)
        completedOpens.append(result)
        return result
    }
    /// Incremental publications carry no read witness unless explicitly supplied by a full-read fixture.
    func publication(_ identity: SessionIdentity, readEvidence: ConversationReadEvidence? = nil) throws -> OpenedConversation {
        .init(identity: identity, snapshot: snapshots[identity.root]!, access: try issuer.issue(identity), readEvidence: readEvidence)
    }
    func fullReadPublication(_ identity: SessionIdentity) throws -> OpenedConversation {
        let observed = readSummaryAvailable ? summaries.first { $0.identity.profile == identity.profile && $0.identity.root == identity.root
            && $0.identity.stored == identity.stored } : nil
        return try publication(identity, readEvidence: observed.map(ConversationReadEvidence.init))
    }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access)
        sends.append((text, attachments, source, operationID))
        deliveries.append(delivery)
        await sendGate?.wait()
        if let sendError { throw sendError }
        return .init(operationID: operationID, source: source, admissionID: "accepted", journal: journal)
    }
    func replaceQueuedMessage(_ message: QueuedMessage, text: String, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access)
        replacements.append((message, text, source, operationID))
        if acceptsReplacementBeforeGate { try applyReplacement(message, text: text, source: source, operation: operationID) }
        await replacementGate?.wait()
        if let replacementError { throw replacementError }
        if !acceptsReplacementBeforeGate { try applyReplacement(message, text: text, source: source, operation: operationID) }
        return .init(operationID: operationID, source: source, admissionID: operationID.uuidString, journal: journal)
    }
    private func applyReplacement(_ message: QueuedMessage, text: String, source: SessionIdentity, operation: UUID) throws {
        guard let index = snapshots[source.root]?.queuedMessages.firstIndex(where: { $0 == message && $0.canEdit }) else {
            throw HermesServiceError.queuedMessageUnavailable
        }
        snapshots[source.root]?.queuedMessages.remove(at: index)
        snapshots[source.root]?.queuedMessages.append(.init(id: operation.uuidString, text: text, canEdit: true,
                                                            submissionID: operation.uuidString))
    }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access); stops.append(operationID)
        await stopGate?.wait()
        return .init(operationID: operationID, source: source, admissionID: nil, journal: .saved)
    }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access)
        responseOperations.append(operationID)
        await responseGate?.wait()
        if let responseError { throw responseError }
        responses.append(request)
        return .init(operationID: operationID, source: source, admissionID: nil, journal: .saved)
    }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        uploads.append(try issuer.resolve(access))
        await uploadGate?.wait()
        return .init(name: filename, path: "uploads/" + filename, mimeType: mimeType, byteCount: data.count)
    }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        _ = try issuer.resolve(access)
        downloads += 1
        onDownload?()
        await downloadGate?.wait()
        if let downloadError { throw downloadError }
        return .init(data: downloadData, filename: attachment.name, mimeType: attachment.mimeType)
    }
}

@MainActor final class WorkspaceGate {
    private var entries = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entries += 1
        let waiting = entryWaiters; entryWaiters = []; waiting.forEach { $0.resume() }
        await withCheckedContinuation { waiters.append($0) }
    }
    func entered() async {
        if entries > 0 { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { let waiting = waiters; waiters = []; waiting.forEach { $0.resume() } }
}
