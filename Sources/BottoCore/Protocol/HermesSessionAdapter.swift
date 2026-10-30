import Foundation

/// The two wire dialects deliberately do not share mutation parameters.
/// Source contracts: Hermes ca678285 (sidecar), 4a0eaf79 (authority).
enum HermesSessionAdapter: Equatable, Sendable {
    case sidecar, authority

    func resume(profile: String, stored: String, omitMessages: Bool = false) -> [String: HermesJSON] {
        var params: [String: HermesJSON] = ["profile": .string(profile), "session_id": .string(stored),
                                          "omit_messages": .bool(omitMessages)]
        if self == .sidecar { params["close_on_disconnect"] = .bool(false); params["source"] = .string("gui") }
        return params
    }
    func create(profile: String, requestID: String) -> [String: HermesJSON] {
        var params: [String: HermesJSON] = ["profile": .string(profile), "title": .string("Bot Chat"),
            "hidden": .bool(true), "follow_profile_config": .bool(true), "source": .string("gui")]
        if self == .authority { params["request_id"] = .string(requestID) }
        return params
    }
    func ordinaryCreate(profile: String, operationID: UUID) -> [String: HermesJSON] {
        var params: [String: HermesJSON] = ["profile": .string(profile), "source": .string("gui")]
        if self == .authority { params["request_id"] = .string(operationID.uuidString) }
        else { params["close_on_disconnect"] = .bool(false) }
        return params
    }
    func replay(profile: String, runtime: String, sequence: Int, epoch: String) -> [String: HermesJSON] {
        var params: [String: HermesJSON] = ["profile": .string(profile), "session_id": .string(runtime)]
        if self == .authority {
            params["last_sequence"] = .number(Double(sequence)); params["replay_epoch"] = .string(epoch)
        } else { params["last_seen"] = .number(Double(sequence)) }
        return params
    }
    func submit(_ conversation: Conversation, text: String, submission: String, images: [HermesJSON]) -> [String: HermesJSON] {
        var params: [String: HermesJSON] = ["profile": .string(conversation.profileID),
            "session_id": .string(conversation.id), "text": .string(text), "queued": .bool(true)]
        if self == .authority {
            params["submission_id"] = .string(submission)
            if !images.isEmpty { params["attachments"] = .array(images) }
        }
        return params
    }
    func control(_ conversation: Conversation, generation: Int?) throws -> [String: HermesJSON] {
        var params: [String: HermesJSON] = ["profile": .string(conversation.profileID), "session_id": .string(conversation.id)]
        if self == .authority {
            guard let generation, generation >= 0 else { throw HermesServiceError.staleConversation }
            params["execution_generation"] = .number(Double(generation))
        }
        return params
    }
}
