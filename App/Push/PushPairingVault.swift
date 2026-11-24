import Foundation
import Security
import BottoCore

struct PushHostBinding: Codable, Hashable, Sendable {
    let serverURL: URL
    let installID: String
    let username: String
    let provider: String
    var profileID: String

    init?(_ configuration: ConnectionConfiguration, profileID: String) {
        guard let install = configuration.installID, !install.isEmpty else { return nil }
        serverURL = configuration.serverURL; installID = install; username = configuration.username
        provider = configuration.nativeCredential?.provider ?? "basic"
        self.profileID = profileID
    }
    func sameConnection(as other: Self) -> Bool {
        connectionIdentity == other.connectionIdentity
    }
    private var connectionIdentity: [Data] { [serverURL.absoluteString, installID, username, provider].map { Data($0.utf8) } }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sameConnection(as: rhs) && lhs.profileID.utf8.elementsEqual(rhs.profileID.utf8)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(connectionIdentity); hasher.combine(Data(profileID.utf8)) }
}

struct PushPairing: Codable, Equatable, Sendable {
    var host: PushHostBinding
    var installationID: String?
    var deviceID: String
    var generation: Int
    var key: Data
    var preferences: PushPreferences
    var pendingEnrollment: PushEnrollmentRequest?
    var remoteConfirmed: Bool
    var lastEnrollment: PushEnrollmentRequest?
    var retirement: PushRetirement? = nil
}

struct PushRetirement: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable { case relay, removed }
    var reason: Reason
    var token: String?
}

struct PushPendingRemoval: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let host: PushHostBinding
    let deviceID: String
}

struct PushSavedState: Codable, Equatable, Sendable {
    var pairings: [PushPairing] = []
    var removals: [PushPendingRemoval] = []
}

@MainActor struct PushPersistence {
    var load: () throws -> PushSavedState
    var save: (PushSavedState) throws -> Void
    static var keychain: Self { .init(load: PushPairingVault.load, save: PushPairingVault.save) }
}

enum PushPairingVault {
    private static func query(_ account: String) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sree.botto.push", kSecAttrAccount as String: account]
        if let group = Bundle.main.object(forInfoDictionaryKey: "BottoPushKeychainGroup") as? String,
           !group.isEmpty, !group.contains("$(") { value[kSecAttrAccessGroup as String] = group }
        return value
    }
    static func load() throws -> PushSavedState {
        try load(PushSavedState.self, account: "pairing-v1") ?? .init()
    }

    static func save(_ state: PushSavedState) throws { try save(state, account: "pairing-v1") }

    static func loadT3() throws -> [T3PushPairing] {
        try load([T3PushPairing].self, account: "t3-pairing-v1") ?? []
    }

    static func saveT3(_ pairings: [T3PushPairing]) throws { try save(pairings, account: "t3-pairing-v1") }

    private static func load<Value: Decodable>(_ type: Value.Type, account: String) throws -> Value? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PushError.unavailableStorage }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw PushError.unavailableStorage }
    }

    private static func save(_ value: some Encodable, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let query = query(account)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PushError.unavailableStorage }
        } else if status != errSecSuccess { throw PushError.unavailableStorage }
    }
}

struct T3PushPairing: Codable, Equatable, Sendable {
    let invitation: T3PushInvitation
    var registration: T3PushRegistration
    var installationID: String?
    var confirmed: Bool

    func matches(_ envelope: PushEnvelope) -> Bool {
        registration.target != nil && invitation.deviceID == envelope.deviceID && installationID == envelope.installationID
            && (1...registration.generation).contains(envelope.generation)
    }

    func preview(_ envelope: PushEnvelope) -> PushPreview? {
        guard matches(envelope), let preview = try? envelope.decrypt(key: invitation.previewKey),
              preview.destination == invitation.scope.destination(spaceID: preview.storedID) else { return nil }
        return preview
    }
}
