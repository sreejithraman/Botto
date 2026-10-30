import Foundation

public extension QueuedMessage {
    /// Presentation hint only: pending receipts omit provenance and retain an opaque input ID.
    /// Never use this inferred kind to authorize transcript classification or assistant silence.
    /// Source: gateway/session_authority.py and gateway/run_notifications.py at ef75bc70.
    var sourceMessage: ChatMessage? {
        guard !canEdit, !isSteering, let submissionID, submissionID.utf8.count <= 1024 else { return nil }
        let kind: String
        if submissionID.hasPrefix("bot:"), submissionID.count > 4 {
            kind = "internal_notification"
        } else {
            guard let identity = try? HermesJSON.decode(Data(submissionID.utf8)).list,
                  identity.count == 3, identity[1].nonempty != nil else { return nil }
            switch identity[0].text {
            case "completion":
                guard let started = identity[2].number, started.isFinite, started >= 0 else { return nil }
                kind = "process_complete"
            case "async_delegation":
                guard let notice = identity[2].text,
                      notice.isEmpty || notice.wholeMatch(of: /task_failure:[0-9]+/) != nil else { return nil }
                kind = "async_delegation_complete"
            case "watch_match", "watch_disabled", "heartbeat":
                guard identity[2].nonempty != nil else { return nil }
                kind = "internal_notification"
            default: return nil
            }
        }
        return ChatMessage(id: id, role: .user, text: text, displayKind: kind)
    }
}
