import Foundation

public enum PushEnvironment: String, Codable, Sendable { case sandbox, production }
public enum PushEventKind: String, Codable, Sendable { case reply, approval, question, failure }

public struct PushDestination: Codable, Equatable, Sendable {
    public var profileID: String
    public var rootID: String
    public var storedID: String
    enum CodingKeys: String, CodingKey { case profileID = "profile_id", rootID = "root_id", storedID = "stored_id" }
    public init(profileID: String, rootID: String, storedID: String) {
        self.profileID = profileID; self.rootID = rootID; self.storedID = storedID
    }
    public init(identity: SessionIdentity) {
        self.init(profileID: identity.profile.text, rootID: identity.root.text, storedID: identity.stored.text)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profileID.utf8.elementsEqual(rhs.profileID.utf8) && lhs.rootID.utf8.elementsEqual(rhs.rootID.utf8) &&
            lhs.storedID.utf8.elementsEqual(rhs.storedID.utf8)
    }
    public func validated() throws -> Self {
        for value in [profileID, rootID, storedID] {
            guard !value.isEmpty, value.utf8.count <= 512,
                  !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
            else { throw PushError.invalidPayload }
        }
        return self
    }
}

public enum PushError: LocalizedError, Equatable, Sendable {
    case invalidPayload, unavailableStorage, permissionDenied, tokenUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidPayload: "Botto couldn’t verify this notification."
        case .unavailableStorage: "Botto couldn’t open its secure notification storage. Unlock your device and try again."
        case .permissionDenied: "Allow notifications for Botto in Settings to receive alerts."
        case .tokenUnavailable: "Apple hasn’t supplied a notification address yet. Try again when connected."
        }
    }
}
