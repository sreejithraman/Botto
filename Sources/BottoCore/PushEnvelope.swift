import CryptoKit
import Foundation

public struct PushPreview: Codable, Equatable, Sendable {
    public var v: Int
    public var title: String
    public var body: String
    public var profileID: String
    public var rootID: String
    public var storedID: String
    enum CodingKeys: String, CodingKey { case v, title, body, profileID = "profile_id", rootID = "root_id", storedID = "stored_id" }
    public var destination: PushDestination { .init(profileID: profileID, rootID: rootID, storedID: storedID) }
    public init(title: String, body: String, destination: PushDestination) {
        self.v = 1; self.title = title; self.body = body; self.profileID = destination.profileID
        self.rootID = destination.rootID; self.storedID = destination.storedID
    }
}

public struct PushEnvelope: Codable, Equatable, Sendable {
    public var v: Int
    public var installationID: String
    public var deviceID: String
    public var generation: Int
    public var eventID: String
    public var kind: PushEventKind
    public var expiresAt: Int
    public var sealed: String
    enum CodingKeys: String, CodingKey {
        case v, generation, kind, sealed
        case installationID = "installation_id", deviceID = "device_id", eventID = "event_id", expiresAt = "expires_at"
    }
    public init(installationID: String, deviceID: String, generation: Int, eventID: String,
                kind: PushEventKind, expiresAt: Int, sealed: String) {
        self.v = 1; self.installationID = installationID; self.deviceID = deviceID; self.generation = generation
        self.eventID = eventID; self.kind = kind; self.expiresAt = expiresAt; self.sealed = sealed
    }
    public static func parse(userInfo: [AnyHashable: Any]) throws -> Self {
        guard let object = userInfo["botto"] as? [String: Any], JSONSerialization.isValidJSONObject(object) else { throw PushError.invalidPayload }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= 4_096 else { throw PushError.invalidPayload }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func decrypt(key: Data, now: Date = .now) throws -> PushPreview {
        guard v == 1, Self.validHex(installationID, count: 64), Self.validHex(deviceID, count: 32),
              Self.validHex(eventID, count: 64), generation > 0, expiresAt > Int(now.timeIntervalSince1970),
              key.count == 32, let combined = Data(base64Encoded: sealed), combined.count >= 28, combined.count <= 3_072
        else { throw PushError.invalidPayload }
        let aad = Data("botto-push:v1\n\(installationID)\n\(deviceID)\n\(generation)\n\(eventID)".utf8)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key), authenticating: aad)
        guard clear.count <= 2_800 else { throw PushError.invalidPayload }
        let preview = try JSONDecoder().decode(PushPreview.self, from: clear)
        guard preview.v == 1, preview.title.utf8.count <= 160, preview.body.utf8.count <= 1_024 else { throw PushError.invalidPayload }
        _ = try preview.destination.validated()
        return preview
    }
    public static func validHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
