import Foundation
import Observation
import BottoCore

struct QueuedMessageEdit: Identifiable {
    let id = UUID()
    let source: SessionIdentity
    let message: QueuedMessage
    var text: String
    var operation: UUID?
    var error: String?
    var isUncertain = false
    var isSaving: Bool { operation != nil }
}

/// Local edits survive a queue departure or access refresh. Only a confirmed
/// replacement can consume them; keeping a draft never starts a network action.
@MainActor @Observable final class QueuedMessageEditing {
    private var edits: [ChatID: QueuedMessageEdit] = [:]

    func edit(_ chat: ChatID) -> QueuedMessageEdit? { edits[chat] }

    func begin(_ message: QueuedMessage, source: SessionIdentity, chat: ChatID) {
        guard edits[chat] == nil else { return }
        edits[chat] = .init(source: source, message: message, text: message.text)
    }

    func update(_ text: String, chat: ChatID) {
        guard edits[chat]?.isSaving == false else { return }
        edits[chat]?.text = text
    }

    func cancel(_ chat: ChatID) {
        guard edits[chat]?.isSaving == false else { return }
        edits[chat] = nil
    }

    func canReplace(_ chat: ChatID, source: SessionIdentity, messages: [QueuedMessage]) -> Bool {
        guard let edit = edits[chat], sameSource(edit.source, source) else { return false }
        return messages.contains { matches($0, edit.message) && $0.canEdit && !$0.isSteering }
    }

    func canSave(_ chat: ChatID, source: SessionIdentity, messages: [QueuedMessage]) -> Bool {
        guard let edit = edits[chat], !edit.isSaving, !edit.isUncertain,
              !edit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !edit.text.utf8.elementsEqual(edit.message.text.utf8) else { return false }
        return canReplace(chat, source: source, messages: messages)
    }

    func save(_ chat: ChatID, source: SessionIdentity, messages: [QueuedMessage],
              perform: @MainActor (QueuedMessage, String, UUID) async throws -> MutationReceipt) async -> MutationReceipt? {
        guard canSave(chat, source: source, messages: messages), let edit = edits[chat] else { return nil }
        let operation = UUID()
        edits[chat]?.operation = operation
        edits[chat]?.error = nil
        defer {
            if edits[chat]?.id == edit.id, edits[chat]?.operation == operation {
                edits[chat]?.operation = nil
            }
        }
        do {
            let receipt = try await perform(edit.message, edit.text, operation)
            guard receipt.operationID == operation, sameSource(receipt.source, source),
                  receipt.admissionID != nil else { throw HermesServiceError.uncertain }
            if edits[chat]?.id == edit.id { edits[chat] = nil }
            return receipt
        } catch {
            guard edits[chat]?.id == edit.id else { return nil }
            edits[chat]?.error = error.localizedDescription
            // An unconfirmed replacement may already have moved to a new admission.
            // Never issue a second replacement automatically or encourage a blind retry.
            edits[chat]?.isUncertain = error as? HermesServiceError == .uncertain
            return nil
        }
    }

    private func sameSource(_ lhs: SessionIdentity, _ rhs: SessionIdentity) -> Bool {
        lhs.profile == rhs.profile && lhs.root == rhs.root && lhs.stored == rhs.stored
    }

    private func matches(_ lhs: QueuedMessage, _ rhs: QueuedMessage) -> Bool {
        Data(lhs.id.utf8) == Data(rhs.id.utf8) && Data(lhs.text.utf8) == Data(rhs.text.utf8)
    }
}
