import BottoCore

extension HapticEvent {
    static func failure(_ error: any Error) -> HapticEvent {
        switch error as? HermesServiceError {
        case .uncertain, .steeringUnavailable, .partialCreation, .missingModel,
             .partialAvatar, .uncertainAvatar, .avatarRefresh, .avatarConflict,
             .partialProfile, .uncertainProfile, .profileConflict:
            .warning
        default:
            .error
        }
    }
}
