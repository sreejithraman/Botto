import Foundation

/// Messages never include a server response body, URL, password, cookie or ticket.
public enum ConversationServiceError: Error, LocalizedError, Equatable, Sendable {
    case incompatible
    case redirected, disconnected, staleConversation, wrongConversation, missingChat, uncertain
    case unsupportedRequest, invalidResponse, attachmentLimit, invalidAttachment
    case profileUnavailable, staleGeneration
    case steeringUnavailable, steeringAttachments
    case queuedMessageUnavailable

    case avatarConflict, invalidAvatar, avatarRefresh
    case artifactTooLarge

    public var errorDescription: String? {
        switch self {
        case .queuedMessageUnavailable: "This message is no longer queued or available to edit. Your edit is still here. Refresh the chat to check its state."
        case .steeringUnavailable: "Steering requires an active turn. Your draft is still here."
        case .steeringAttachments: "Messages with attachments must be queued as a follow-up. Your draft and files are still here."
        case .artifactTooLarge: "This file is too large to open in Botto. The download limit is 25 MiB."
        case .avatarRefresh: "Your look was saved, but Botto couldn’t show it yet. Pull down on your spaces to refresh before changing it again."
        case .avatarConflict: "This look changed while you were choosing. Close this page, pull down on your spaces to refresh, then choose again."
        case .invalidAvatar: "Choose a valid avatar shape and color."
        case .incompatible: "The host returned unexpected data. Check the connection and try again."
        case .redirected: "The server redirected the request. Check the host address and try again."
        case .disconnected: "The connection to the host was lost. Reconnect to read the latest state."
        case .staleConversation: "This chat changed while the action was preparing. Reopen it before trying again."
        case .wrongConversation: "The host returned a different conversation. Reopen the conversation from the list."
        case .missingChat: "This bot has no available conversation. Open one and try again."
        case .uncertain: "The server didn’t confirm this action. It may have succeeded. Reconnect and check before trying again."
        case .unsupportedRequest: "Answer this request on the host. Botto does not support this request type."
        case .invalidResponse: "Choose one of the offered answers, or enter a nonempty answer."
        case .attachmentLimit: AttachmentLimits.message
        case .invalidAttachment: "This attachment is invalid or belongs to another chat. Attach the file again."
        case .profileUnavailable: "The host has not made this profile available. Wait a moment and refresh."
        case .staleGeneration: "This turn changed before the action reached the host. Refresh the chat before trying again."
        }
    }
}
