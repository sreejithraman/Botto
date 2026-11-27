import Foundation

public struct ConnectionConfiguration: Codable, Equatable, Sendable {
    public var id: UUID
    public var serverURL: URL
    public var username: String
    public var password: String
    public var installID: String?
    public var nativeCredential: NativeCredential?
    public var connectionHeaders: [String: String]
    public var t3: T3Connection?
    /// Further reviewed routes to the same Mac, in pairing order. `serverURL` stays the primary route.
    /// Nil in setups saved before a pairing could hold more than one route.
    public var alternateRoutes: [URL]?
    /// The route the last connection reached, tried first next time.
    public var lastReachedRoute: URL?
    /// The origin in the existing file-cache key after a confirmed re-pair changes the primary route.
    /// This origin is never used to connect.
    public var artifactCacheOrigin: URL?

    public init(id: UUID = UUID(), serverURL: URL, username: String = "", password: String = "", installID: String? = nil, nativeCredential: NativeCredential? = nil, connectionHeaders: [String: String] = [:], t3: T3Connection? = nil,
                alternateRoutes: [URL]? = nil, lastReachedRoute: URL? = nil) {
        self.id = id
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.installID = installID
        self.nativeCredential = nativeCredential
        self.connectionHeaders = connectionHeaders
        self.t3 = t3
        self.alternateRoutes = alternateRoutes
        self.lastReachedRoute = lastReachedRoute
    }
}

public struct NativeCredential: Codable, Equatable, Sendable {
    public var refreshToken: String
    public var provider: String
    public init(refreshToken: String, provider: String) {
        self.refreshToken = refreshToken; self.provider = provider
    }
}

public struct ServerInfo: Equatable, Sendable {
    public var version: String
    public var installID: String?
    public init(version: String, installID: String? = nil) {
        self.version = version
        self.installID = installID
    }
}

public enum BotStatus: String, Codable, Sendable { case idle, working, waiting }

public struct BotProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Legacy local cache compatibility only; never used to render or write shared avatars.
    public var emoji: String
    public var description: String
    public var preview: String
    public var updatedAt: Date?
    public var status: BotStatus
    public var isPinned: Bool
    public var model: String?
    public var appearance: BotAppearance?
    public var hasAvatar: Bool?
    public var lookRevision: Int?
    public init(id: String, name: String, emoji: String = "✳️", description: String = "", preview: String = "", updatedAt: Date? = nil, status: BotStatus = .idle, isPinned: Bool = false, model: String? = nil, appearance: BotAppearance? = nil, hasAvatar: Bool? = nil, lookRevision: Int? = nil) {
        self.id = id; self.name = name; self.emoji = emoji; self.description = description
        self.preview = preview; self.updatedAt = updatedAt; self.status = status
        self.isPinned = isPinned; self.model = model
        self.appearance = appearance; self.hasAvatar = hasAvatar; self.lookRevision = lookRevision
    }
}

/// Only fields deliberately changed in the profile editor. Identity remains stable.
public struct BotProfileEdit: Equatable, Sendable {
    public var name: String?
    public var description: String?

    public init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

public struct ChatAttachment: Identifiable, Codable, Equatable, Sendable {
    public var id: String { stagingID?.uuidString ?? path }
    public var stagingID: UUID?
    public var name: String
    public var path: String
    public var mimeType: String
    /// The prepared upload size, when supplied by the service. Older cached cards omit it.
    public var byteCount: Int?
    public init(name: String, path: String, mimeType: String = "application/octet-stream", byteCount: Int? = nil, stagingID: UUID? = nil) {
        self.name = name; self.path = path; self.mimeType = mimeType; self.byteCount = byteCount; self.stagingID = stagingID
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public nonisolated static func isStableID(_ id: Data, storedID: String) -> Bool {
        guard id != Data("inflight-user".utf8) else { return false }
        guard !id.starts(with: Data((storedID + ":index:").utf8)) else { return false }
        let row = Data((storedID + ":row:").utf8)
        guard id.starts(with: row) else { return true }
        let suffix = id.dropFirst(row.count)
        guard let number = Int(String(decoding: suffix, as: UTF8.self)), number >= 0 else { return false }
        return Data(String(number).utf8) == suffix
    }
    public enum Role: String, Codable, Sendable { case user, assistant, tool, system }
    public var id: String
    public var role: Role
    public var text: String
    public var timestamp: Date?
    public var toolName: String?
    public var attachments: [ChatAttachment]
    /// A local occurrence can use current service authority but cannot identify a durable capture.
    public var transientID: UUID?
    /// Read-only disclosure continuity; never a durable row or artifact identity.
    public var workDetailsID: String? = nil
    /// Keys outside this list, including those older builds saved, are ignored when decoding.
    private enum CodingKeys: String, CodingKey {
        case id, role, text, timestamp, toolName, attachments, transientID
    }
    public nonisolated func hasStableIdentity(storedID: String) -> Bool {
        transientID == nil && Self.isStableID(Data(id.utf8), storedID: storedID)
    }
    public init(id: String, role: Role, text: String, timestamp: Date? = nil, toolName: String? = nil, attachments: [ChatAttachment] = [], transientID: UUID? = nil, workDetailsID: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.timestamp = timestamp
        self.toolName = toolName; self.attachments = attachments
        self.transientID = transientID; self.workDetailsID = workDetailsID
    }
}

public struct RequestChoice: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
    /// It can let the bot repeat matching actions without asking, so the person confirms it first.
    public var allowsFutureActions: Bool {
        id.localizedCaseInsensitiveContains("always") || label.localizedCaseInsensitiveContains("always")
    }
}

public struct PendingRequest: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case approval, question, unsupported }
    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var choices: [RequestChoice]
    public init(id: String, kind: Kind, title: String, detail: String = "", choices: [RequestChoice] = []) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
        self.choices = choices
    }

    /// Wire revisions preserve UTF-8 spelling, including canonically equivalent strings.
    public nonisolated func hasSameWireRevision(as other: Self) -> Bool {
        func sameBytes(_ first: String?, _ second: String?) -> Bool {
            switch (first, second) {
            case (nil, nil): true
            case let (first?, second?): first.utf8.elementsEqual(second.utf8)
            default: false
            }
        }
        return kind == other.kind && sameBytes(id, other.id) && sameBytes(title, other.title) &&
            sameBytes(detail, other.detail) && choices.count == other.choices.count &&
            zip(choices, other.choices).allSatisfy { sameBytes($0.id, $1.id) && sameBytes($0.label, $1.label) }
    }
}

public enum RequestResponse: Equatable, Sendable { case choice(String), text(String) }

public struct QueuedMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var canEdit: Bool
    public var submissionID: String?
    public var isSteering: Bool
    public init(id: String, text: String, canEdit: Bool = false, submissionID: String? = nil, isSteering: Bool = false) {
        self.id = id; self.text = text; self.canEdit = canEdit
        self.submissionID = submissionID; self.isSteering = isSteering
    }
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var storedID: String
    public var profileID: String
    public var messages: [ChatMessage]
    /// Stored history is incomplete; live updates do not prove the missing content was restored.
    public var hasEarlierMessages: Bool
    public var pendingRequests: [PendingRequest]
    public var queuedMessages: [QueuedMessage]
    public var isWorking: Bool
    public var lastSequence: Int
    public init(id: String, storedID: String, profileID: String, messages: [ChatMessage] = [], pendingRequests: [PendingRequest] = [], queuedMessages: [QueuedMessage] = [], isWorking: Bool = false, lastSequence: Int = 0, hasEarlierMessages: Bool = false) {
        self.id = id; self.storedID = storedID; self.profileID = profileID
        self.messages = messages; self.pendingRequests = pendingRequests
        self.hasEarlierMessages = hasEarlierMessages
        self.queuedMessages = queuedMessages
        self.isWorking = isWorking; self.lastSequence = lastSequence
    }

    private enum CodingKeys: String, CodingKey {
        case id, storedID, profileID, messages, hasEarlierMessages, pendingRequests, queuedMessages, isWorking, lastSequence
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        storedID = try values.decode(String.self, forKey: .storedID)
        profileID = try values.decode(String.self, forKey: .profileID)
        messages = try values.decode([ChatMessage].self, forKey: .messages)
        hasEarlierMessages = try values.decodeIfPresent(Bool.self, forKey: .hasEarlierMessages) ?? false
        pendingRequests = try values.decode([PendingRequest].self, forKey: .pendingRequests)
        queuedMessages = try values.decodeIfPresent([QueuedMessage].self, forKey: .queuedMessages) ?? []
        isWorking = try values.decode(Bool.self, forKey: .isWorking)
        lastSequence = try values.decode(Int.self, forKey: .lastSequence)
    }
}

public enum BotServiceEvent: Sendable {
    case conversation(OpenedConversation), botsChanged, disconnected(String)
    case activity(profile: ExactID, observations: [SessionIdentity: ObservedActivity])
    case activityBatch([ProfileActivityUpdate])
    case conversationDirectoryChanged(profile: ExactID)
    case configuration(ConnectionConfiguration), connected(ServerInfo)
}
/// One host connection and one selected live attachment. Mutations require service-owned access.
public enum MessageDelivery: Equatable, Sendable {
    case queue
    case steer
}

@MainActor public protocol BotService: AnyObject {
    var onEvent: ((BotServiceEvent) -> Void)? { get set }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo
    func disconnect()
    func bots() async throws -> [BotProfile]
    func updateProfile(_ edit: BotProfileEdit, for bot: BotProfile) async throws -> BotProfile
    func setAvatar(_ choice: BotAvatarChoice, for bot: BotProfile) async throws -> BotProfile
    func conversations(profile: ExactID) async throws -> ConversationDirectory
    func recentConversationHistory(_ identity: SessionIdentity) async throws -> ConversationHistoryWindow?
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess,
              operationID: UUID) async throws -> MutationReceipt
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt
    func replaceQueuedMessage(_ message: QueuedMessage, text: String, access: ConversationAccess,
                              operationID: UUID) async throws -> MutationReceipt
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess,
                 operationID: UUID) async throws -> MutationReceipt
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact
}

public extension BotService {
    func recentConversationHistory(_ identity: SessionIdentity) async throws -> ConversationHistoryWindow? {
        nil
    }

    func updateProfile(_ edit: BotProfileEdit, for bot: BotProfile) async throws -> BotProfile {
        throw ConversationServiceError.rejected(-32601)
    }
    func replaceQueuedMessage(_ message: QueuedMessage, text: String, access: ConversationAccess,
                              operationID: UUID) async throws -> MutationReceipt {
        throw ConversationServiceError.rejected(-32601)
    }

    func send(text: String, attachments: [ChatAttachment], access: ConversationAccess,
              operationID: UUID) async throws -> MutationReceipt {
        try await send(text: text, attachments: attachments, delivery: .queue, access: access, operationID: operationID)
    }

    func setAvatar(_ choice: BotAvatarChoice, for bot: BotProfile) async throws -> BotProfile {
        throw ConversationServiceError.rejected(-32601)
    }
}
