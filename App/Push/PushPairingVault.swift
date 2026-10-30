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
    private static var query: [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sree.botto.push", kSecAttrAccount as String: "pairing-v1"]
        if let group = Bundle.main.object(forInfoDictionaryKey: "BottoPushKeychainGroup") as? String,
           !group.isEmpty, !group.contains("$(") { value[kSecAttrAccessGroup as String] = group }
        return value
    }
    static func load() throws -> PushSavedState {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return .init() }
        guard status == errSecSuccess, let data = result as? Data else { throw PushError.unavailableStorage }
        do { return try JSONDecoder().decode(PushSavedState.self, from: data) }
        catch { throw PushError.unavailableStorage }
    }
    static func save(_ state: PushSavedState) throws {
        let data = try JSONEncoder().encode(state)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PushError.unavailableStorage }
        } else if status != errSecSuccess { throw PushError.unavailableStorage }
    }
}
