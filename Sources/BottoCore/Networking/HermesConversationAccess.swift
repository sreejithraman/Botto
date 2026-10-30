import Foundation

extension HermesBotService {
    /// Captured before dispatch and kept alive until the host has settled the write.
    struct AccessContext {
        let identity: SessionIdentity
        let state: HermesConversationState
        let selection: Int
        let connection: Int
    }

    func retireAccess() { issuer.retireAttachment(); publication = nil }

    func accessContextChanged(_ next: AccessContext) -> Bool {
        guard let publication, let old = try? issuer.resolve(publication.access) else { return true }
        return old.selection != next.selection || old.connection != next.connection || old.identity != next.identity
            || old.state.generation != next.state.generation || old.state.epoch != next.state.epoch
            || old.state.subscription != next.state.subscription || old.state.routes != next.state.routes
            || old.state.conversation.pendingRequests != next.state.conversation.pendingRequests
    }

    func resolve(_ access: ConversationAccess) throws -> AccessContext {
        let context = try issuer.resolve(access)
        try checkSelected(context.state.conversation, selection: context.selection, connection: context.connection)
        return context
    }

    func validate(_ access: ConversationAccess) throws { _ = try resolve(access) }

    func receipt(_ operation: UUID, context: AccessContext, admission: String? = nil,
                 journal: JournalDurability = .saved) -> MutationReceipt {
        MutationReceipt(operationID: operation, source: context.identity, admissionID: admission, journal: journal)
    }

    func accessKey(_ access: ConversationAccess, _ request: String) -> String { String(describing: access) + ":" + request }

    func claimOperation(_ operation: UUID) throws {
        guard operations.insert(operation).inserted else { throw HermesServiceError.staleConversation }
    }

    func isSelected(_ context: AccessContext) -> Bool {
        context.selection == selectionGeneration && context.connection == connectionGeneration && attached
    }
}

/// Swift String equality folds canonically equivalent Unicode. Protocol identities do not.
func exact(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return Data(lhs.utf8) == Data(rhs.utf8)
}

func exactAttachment(_ lhs: ChatAttachment, _ rhs: ChatAttachment) -> Bool {
    lhs.stagingID == rhs.stagingID && lhs.byteCount == rhs.byteCount && exact(lhs.name, rhs.name)
        && exact(lhs.path, rhs.path) && exact(lhs.mimeType, rhs.mimeType)
}
