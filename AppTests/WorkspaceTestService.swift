import Foundation
import BottoCore
@testable import Botto

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
    var connectError: (any Error)?
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
    var directoryGate: WorkspaceGate?
    var uploadGate: WorkspaceGate?
    var downloadGate: WorkspaceGate?
    var createError: (any Error)?
    var directoryError: (any Error)?
    var directoryResult: ConversationDirectory?
    var directoryActivity: [SessionIdentity: ObservedActivity] = [:]
    var sends: [(String, [ChatAttachment], SessionIdentity, UUID)] = []
    var creates: [UUID] = []
    var opens: [SessionIdentity] = []
    var uploads: [SessionIdentity] = []
    var uploadError: (any Error)?
    var responses: [PendingRequest] = []
    var responseError: (any Error)?
    var responseOperations: [UUID] = []
    var directoryCalls = 0
    var rosterActivity: [SessionIdentity: ObservedActivity] = [:]
    var rosterStatus: BotStatus = .idle
    var rosterGate: WorkspaceGate?
    var rosterError: (any Error)?
    var rosterProfiles: [BotProfile]?
    var previewGate: WorkspaceGate?
    var previewError: (any Error)?
    var previewResult: ConversationHistoryWindow?
    var previewUnavailable = false
    var previewReads: [SessionIdentity] = []
    var directoryChanges: Set<ExactID> = []
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
        if let connectError { throw connectError }
        return .init(version: "test")
    }
    func disconnect() { issuer.retireAttachment() }
    func bots() async throws -> [BotProfile] {
        await rosterGate?.wait()
        if let rosterError { throw rosterError }
        let changes = directoryChanges; directoryChanges = []
        for profile in changes { onEvent?(.conversationDirectoryChanged(profile: profile)) }
        if !rosterActivity.isEmpty { onEvent?(.activity(profile: profile, observations: rosterActivity)) }
        return rosterProfiles ?? [.init(id: profile.text, name: "Milo", status: rosterStatus)]
    }
    func setAvatar(_ choice: BotAvatarChoice, for bot: BotProfile) async throws -> BotProfile { bot }
    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        directoryCalls += 1
        let captured = directoryResult
        await directoryGate?.wait()
        if let directoryError { throw directoryError }
        if let captured { return captured }
        return .init(summaries: summaries.filter { $0.identity.profile == profile }, activity: directoryActivity)
    }
    func recentConversationHistory(_ identity: SessionIdentity) async throws -> ConversationHistoryWindow? {
        previewReads.append(identity)
        let result: ConversationHistoryWindow? = previewUnavailable ? nil : previewResult ?? snapshots[identity.root].map { snapshot in
            .init(messages: snapshot.messages, hasEarlierMessages: snapshot.hasEarlierMessages)
        }
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
        // This method models a complete read; incremental publications use publication(_:).
        let opened = OpenedConversation(identity: identity, snapshot: snapshots[identity.root]!,
            access: try issuer.issue(identity), historyReadStartedAt: .now)
        await openGate?.wait()
        if let openError { throw openError }
        let result = try openResult?(opened) ?? opened
        beforeOpenReturn?(result)
        completedOpens.append(result)
        return result
    }
    func publication(_ identity: SessionIdentity) throws -> OpenedConversation {
        .init(identity: identity, snapshot: snapshots[identity.root]!, access: try issuer.issue(identity))
    }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access)
        sends.append((text, attachments, source, operationID))
        deliveries.append(delivery)
        await sendGate?.wait()
        if let sendError { throw sendError }
        return .init(operationID: operationID, source: source, admissionID: "accepted")
    }
    func replaceQueuedMessage(_ message: QueuedMessage, text: String, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access)
        replacements.append((message, text, source, operationID))
        if acceptsReplacementBeforeGate { try applyReplacement(message, text: text, source: source, operation: operationID) }
        await replacementGate?.wait()
        if let replacementError { throw replacementError }
        if !acceptsReplacementBeforeGate { try applyReplacement(message, text: text, source: source, operation: operationID) }
        return .init(operationID: operationID, source: source, admissionID: operationID.uuidString)
    }
    private func applyReplacement(_ message: QueuedMessage, text: String, source: SessionIdentity, operation: UUID) throws {
        guard let index = snapshots[source.root]?.queuedMessages.firstIndex(where: { $0 == message && $0.canEdit }) else {
            throw ConversationServiceError.queuedMessageUnavailable
        }
        snapshots[source.root]?.queuedMessages.remove(at: index)
        snapshots[source.root]?.queuedMessages.append(.init(id: operation.uuidString, text: text, canEdit: true,
                                                            submissionID: operation.uuidString))
    }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access); stops.append(operationID)
        await stopGate?.wait()
        return .init(operationID: operationID, source: source, admissionID: nil)
    }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access)
        responseOperations.append(operationID)
        await responseGate?.wait()
        if let responseError { throw responseError }
        responses.append(request)
        return .init(operationID: operationID, source: source, admissionID: nil)
    }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        uploads.append(try issuer.resolve(access))
        await uploadGate?.wait()
        if let uploadError { throw uploadError }
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

extension ConversationWorkspace {
    /// A bot's saved chats, Main first.
    func chats(_ profile: ExactID) -> [ChatRecord] { persisted().ordered(profile) }
    func isUnread(_ summary: SessionSummary) -> Bool? {
        chats(summary.identity.profile).first { $0.binding.identity?.root == summary.identity.root }?.isUnread
    }
    /// Opens a saved chat the way a Spaces drawer tap does.
    @discardableResult func openSaved(_ summary: SessionSummary) async -> Bool {
        guard let claim = captureNavigationClaim() else { return false }
        return await openStoredChat(summary, claim: claim)
    }
}
