import Foundation
import BottoCore
@testable import Botto

/// Conformers issue real module-safe grants; no raw mutation route exists in these fixtures.
@MainActor final class TestConversationAuthority {
    private let issuer = ConversationIssuer<Conversation>()
    private var current: OpenedConversation?
    func identity(_ conversation: Conversation) throws -> SessionIdentity {
        .init(profile: try ExactID(conversation.profileID), root: try ExactID("test-root-" + conversation.profileID),
              stored: try ExactID(conversation.storedID), aliases: [])
    }
    func opened(_ conversation: Conversation) throws -> OpenedConversation {
        let identity = try identity(conversation)
        let access: ConversationAccess
        if let current, current.identity == identity, Data(current.snapshot.id.utf8) == Data(conversation.id.utf8),
           current.snapshot.pendingRequests == conversation.pendingRequests { access = current.access }
        else { access = try issuer.issue(conversation) }
        let opened = OpenedConversation(identity: identity, snapshot: conversation, access: access)
        current = opened
        return opened
    }
    func resolve(_ access: ConversationAccess) throws -> Conversation { try issuer.resolve(access) }
    func receipt(_ access: ConversationAccess, _ operation: UUID) throws -> MutationReceipt {
        .init(operationID: operation, source: try identity(resolve(access)), admissionID: "test-accepted", journal: .saved)
    }
    func profile(_ target: SessionTarget) -> String {
        switch target {
        case .canonical(let profile, _): profile.text
        case .stored(let identity): identity.profile.text
        }
    }
    func directory(_ profile: ExactID) -> ConversationDirectory {
        .init(summaries: [], activity: [:], isComplete: false)
    }
}

extension LocalHistory {
    func fixtureRecord(_ profile: String) throws -> ChatRecord? {
        guard let id = book.opening(try ExactID(profile)) else { return nil }
        return book.record(id)
    }
    /// Fixture construction still passes through the real book and production cache encoder.
    mutating func fixtureDraft(_ text: String, profile: String) throws {
        let id = book.ensureProfile(try ExactID(profile))
        book.update(id) { $0.draft = .init(text: text, revision: UUID()) }
    }
    mutating func fixtureConversation(_ chat: Conversation, profile: String) throws {
        let id = book.ensureProfile(try ExactID(profile))
        book.update(id) { $0.binding = .provisionalMain(legacyStored: try? ExactID(chat.storedID)) }
        book.update(id) { $0.transcript = chat }
    }
}

@MainActor extension AppStore {
    /// Test callers capture the actual workspace/owner before any suspension.
    func testEdit(_ text: String, for profile: String) async {
        if selectedBotID != profile || chats.screen(profile: try! ExactID(profile)) == nil {
            await open(.init(id: profile, name: profile))
        }
        let workspace = chats
        guard let screen = workspace.screen(profile: try! ExactID(profile)) else { return }
        workspace.editDraft(text, owner: screen.owner)
    }
    func testSend(_ profile: String) async {
        let workspace = chats
        guard let screen = workspace.screen(profile: try! ExactID(profile)), let intent = workspace.captureSend(screen.owner) else { return }
        await workspace.send(intent)
    }
    func testRemove(_ attachment: ChatAttachment, profile: String) {
        let workspace = chats
        guard let screen = workspace.screen(profile: try! ExactID(profile)) else { return }
        workspace.removeAttachment(attachment, owner: screen.owner)
    }
    func testImport(_ profile: String) -> ImportIntent? {
        let workspace = chats
        guard let screen = workspace.screen(profile: try! ExactID(profile)) else { return nil }
        return workspace.captureImport(screen.owner)
    }
    func testUpload(_ data: Data, filename: String, mimeType: String, intent: ImportIntent) async {
        let workspace = chats
        await workspace.upload(data, filename: filename, mimeType: mimeType, to: intent)
    }
}
