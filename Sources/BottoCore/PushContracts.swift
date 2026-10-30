import Foundation

public struct PushPreferences: Codable, Equatable, Sendable {
    public var replies: Bool
    public var requests: Bool
    public var failures: Bool
    public var previews: Bool
    public init(replies: Bool = true, requests: Bool = true, failures: Bool = true, previews: Bool = true) {
        self.replies = replies; self.requests = requests; self.failures = failures; self.previews = previews
    }
}

public enum PushEnvironment: String, Codable, Sendable { case sandbox, production }
public enum PushEventKind: String, Codable, Sendable { case reply, approval, question, failure }
public enum PushDeviceState: String, Codable, Sendable {
    case active, pending, rejected, relayRetired = "relay_retired", removed
}

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

public struct PushDevice: Codable, Equatable, Sendable, Identifiable {
    public var deviceID: String
    public var generation: Int
    public var preferences: PushPreferences
    public var deviceName: String?
    public var active: Bool?
    public var pendingRemoval: Bool?
    public var state: PushDeviceState?
    public var id: String { deviceID }
    enum CodingKeys: String, CodingKey { case deviceID = "device_id", generation, preferences, deviceName = "device_name", active, pendingRemoval = "pending_removal", state }
    public init(deviceID: String, generation: Int, preferences: PushPreferences = .init(), deviceName: String? = nil, active: Bool? = nil, pendingRemoval: Bool? = nil, state: PushDeviceState? = nil) {
        self.deviceID = deviceID; self.generation = generation; self.preferences = preferences
        self.deviceName = deviceName; self.active = active; self.pendingRemoval = pendingRemoval; self.state = state
    }
}

public struct PushHostStatus: Codable, Equatable, Sendable {
    public var v: Int
    public var pluginVersion: String
    public var supported: Bool
    public var installationID: String?
    public var relayURL: URL?
    public var capabilities: [String: Int]
    public var devices: [PushDevice]
    public var reason: String?
    enum CodingKeys: String, CodingKey {
        case v, supported, capabilities, devices, reason
        case pluginVersion = "plugin_version", installationID = "installation_id", relayURL = "relay_url"
    }
    public init(pluginVersion: String, supported: Bool, installationID: String? = nil, relayURL: URL? = nil,
                capabilities: [String: Int] = [:], devices: [PushDevice] = [], reason: String? = nil) {
        self.v = 1; self.pluginVersion = pluginVersion; self.supported = supported; self.installationID = installationID
        self.relayURL = relayURL; self.capabilities = capabilities; self.devices = devices; self.reason = reason
    }
}

public struct PushEnrollmentRequest: Codable, Equatable, Sendable {
    public let v = 1
    public var operationID: String
    public var deviceID: String
    public var token: String
    public var bundleID: String
    public var environment: PushEnvironment
    public var previewKey: String?
    public var preferences: PushPreferences
    public var visibleChat: PushDestination?
    public var visibleUntil: Int
    public var deviceName: String?
    public var expectedGeneration: Int
    enum CodingKeys: String, CodingKey {
        case v, token, environment, preferences
        case operationID = "operation_id", deviceID = "device_id", bundleID = "bundle_id", previewKey = "preview_key", visibleChat = "visible_chat", visibleUntil = "visible_until", deviceName = "device_name", expectedGeneration = "expected_generation"
    }
    public init(operationID: UUID = UUID(), deviceID: String, token: String, bundleID: String, environment: PushEnvironment,
                previewKey: Data?, preferences: PushPreferences, visibleChat: PushDestination? = nil, visibleUntil: Int = 0, deviceName: String? = nil, expectedGeneration: Int = 0) {
        self.operationID = operationID.uuidString.lowercased(); self.deviceID = deviceID; self.token = token
        self.bundleID = bundleID; self.environment = environment; self.previewKey = previewKey?.base64EncodedString()
        self.preferences = preferences; self.visibleChat = visibleChat; self.visibleUntil = visibleUntil
        self.deviceName = deviceName
        self.expectedGeneration = expectedGeneration
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .v) == 1 else { throw PushError.invalidPayload }
        operationID = try values.decode(String.self, forKey: .operationID)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        token = try values.decode(String.self, forKey: .token)
        bundleID = try values.decode(String.self, forKey: .bundleID)
        environment = try values.decode(PushEnvironment.self, forKey: .environment)
        previewKey = try values.decodeIfPresent(String.self, forKey: .previewKey)
        preferences = try values.decode(PushPreferences.self, forKey: .preferences)
        visibleChat = try values.decodeIfPresent(PushDestination.self, forKey: .visibleChat)
        visibleUntil = try values.decode(Int.self, forKey: .visibleUntil)
        deviceName = try values.decodeIfPresent(String.self, forKey: .deviceName)
        expectedGeneration = try values.decodeIfPresent(Int.self, forKey: .expectedGeneration) ?? 0
        guard expectedGeneration >= 0 else { throw PushError.invalidPayload }
    }
}

public struct PushEnrollment: Codable, Equatable, Sendable {
    public var v: Int
    public var installationID: String
    public var deviceID: String
    public var generation: Int
    public var preferences: PushPreferences
    public var status: String
    enum CodingKeys: String, CodingKey {
        case v, generation, preferences, status
        case installationID = "installation_id", deviceID = "device_id"
    }
    public init(installationID: String, deviceID: String, generation: Int, preferences: PushPreferences, status: String = "accepted") {
        self.v = 1; self.installationID = installationID; self.deviceID = deviceID; self.generation = generation; self.preferences = preferences; self.status = status
    }
    public func validated() throws -> Self {
        guard v == 1, PushEnvelope.validHex(installationID, count: 64), PushEnvelope.validHex(deviceID, count: 32),
              generation > 0 else { throw PushError.invalidPayload }
        return self
    }
}

public struct PushRemovalResult: Codable, Equatable, Sendable {
    public var v: Int
    public var status: String
    public init(status: String) { self.v = 1; self.status = status }
    public var isConfirmed: Bool { v == 1 && ["revoked", "removed"].contains(status) }
}

public struct PushPluginInstallResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var restartRequired: Bool
    public var warnings: [String]
    public var profileID: String?
    enum CodingKeys: String, CodingKey { case ok, restartRequired = "restart_required", warnings, profileID = "profile" }
    public init(ok: Bool, restartRequired: Bool = false, warnings: [String] = [], profileID: String? = nil) {
        self.ok = ok; self.restartRequired = restartRequired; self.warnings = warnings; self.profileID = profileID
    }
}

public enum PushError: LocalizedError, Equatable, Sendable {
    case unsupported, invalidPayload, unavailableStorage, permissionDenied, tokenUnavailable, enrollmentChanged
    public var errorDescription: String? {
        switch self {
        case .unsupported: "This Hermes host does not offer supported Botto notifications yet."
        case .invalidPayload: "Botto couldn’t verify this notification."
        case .unavailableStorage: "Botto couldn’t open its secure notification storage. Unlock your device and try again."
        case .permissionDenied: "Allow notifications for Botto in Settings to receive alerts."
        case .tokenUnavailable: "Apple hasn’t supplied a notification address yet. Try again when connected."
        case .enrollmentChanged: "Notification setup changed while this request was running. Try again."
        }
    }
}
