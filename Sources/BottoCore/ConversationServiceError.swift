import Foundation

/// Messages never include a server response body, URL, password, cookie or ticket.
public enum ConversationServiceError: Error, LocalizedError, Equatable, Sendable {
    case incompatible, authentication
    case redirected, disconnected, staleConversation, wrongConversation, missingChat, timeout, uncertain
    case rejected(Int), unsupportedRequest, invalidResponse, attachmentLimit, invalidAttachment
    case profileUnavailable, staleGeneration
    case steeringUnavailable, steeringAttachments
    case queuedMessageUnavailable
    case responseTooLong

    case avatarConflict, uncertainAvatar, invalidAvatar, avatarRefresh
    case profileConflict, partialProfile, uncertainProfile
    case artifactTooLarge

    public var errorDescription: String? {
        switch self {
        case .profileConflict: "This profile changed on the host. Reload it before saving again."
        case .partialProfile: "Some profile changes may have saved. Reload the profile to check what the host kept before saving again."
        case .uncertainProfile: "The host did not confirm the profile changes. They may have saved. Reload the profile before saving again."
        case .queuedMessageUnavailable: "This message is no longer queued or available to edit. Your edit is still here. Refresh the chat to check its state."
        case .steeringUnavailable: "Steering requires an active turn. Your draft is still here."
        case .steeringAttachments: "Messages with attachments must be queued as a follow-up. Your draft and files are still here."
        case .artifactTooLarge: "This file is too large to open in Botto. The download limit is 25 MiB."
        case .avatarRefresh: "Your avatar was saved, but Botto couldn’t refresh it. Reload the avatar before making another change."
        case .avatarConflict: "This avatar changed on the host. Reload it before choosing again."
        case .uncertainAvatar: "The host did not confirm the avatar change. It may have saved. Reload the avatar to check before saving again."
        case .invalidAvatar: "Choose a valid avatar shape and color."
        case .incompatible: "The host returned unexpected data. Check the connection and try again."
        case .authentication: "The host rejected the sign-in. Sign in again, or check the username and password."
        case .redirected: "The server redirected the request. Check the host address and try again."
        case .disconnected: "The connection to the host was lost. Reconnect to read the latest state."
        case .staleConversation: "This chat changed while the action was preparing. Reopen it before trying again."
        case .wrongConversation: "The host returned a different conversation. Reopen the conversation from the list."
        case .missingChat: "This bot has no available conversation. Open one and try again."
        case .timeout: "The host did not respond in time. Check the host and reconnect."
        case .uncertain: "The server didn’t confirm this action. It may have succeeded. Reconnect and check before trying again."
        case .rejected(-32601): "This connection does not support that action."
        case .rejected(let code): "The host refused this action (code \(code)). Check the host and refresh before trying again."
        case .unsupportedRequest: "Answer this request on the host. Botto does not support this request type."
        case .invalidResponse: "Choose one of the offered answers, or enter a nonempty answer."
        case .responseTooLong: "This answer is too long. Use 16,384 UTF-8 bytes or fewer, then submit again. Some characters use more than one byte. Nothing was sent."
        case .attachmentLimit: AttachmentLimits.message
        case .invalidAttachment: "This attachment is invalid or belongs to another chat. Attach the file again."
        case .profileUnavailable: "The host has not made this profile available. Wait a moment and refresh."
        case .staleGeneration: "This turn changed before the action reached the host. Refresh the chat before trying again."
        }
    }
}
