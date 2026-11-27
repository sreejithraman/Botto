import BottoCore

extension HapticEvent {
    static func failure(_ error: any Error) -> HapticEvent {
        switch error as? ConversationServiceError {
        case .uncertain, .steeringUnavailable,
             .avatarRefresh, .avatarConflict:
            .warning
        default:
            .error
        }
    }
}
