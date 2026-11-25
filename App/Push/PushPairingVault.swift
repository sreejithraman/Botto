import Foundation
import Security
import BottoCore

enum PushPairingVault {
    private static func query(_ account: String) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sree.botto.push", kSecAttrAccount as String: account]
        if let group = Bundle.main.object(forInfoDictionaryKey: "BottoPushKeychainGroup") as? String,
           !group.isEmpty, !group.contains("$(") { value[kSecAttrAccessGroup as String] = group }
        return value
    }
    static func loadT3() throws -> [T3PushPairing] {
        try load([T3PushPairing].self, account: "t3-pairing-v1") ?? []
    }

    static func saveT3(_ pairings: [T3PushPairing]) throws { try save(pairings, account: "t3-pairing-v1") }

    /// Retire the original enrollment without reading it or altering the T3 account.
    static func retireLegacyPairing(
        delete: ([String: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }
    ) throws {
        let status = delete(query("pairing-v1"))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PushError.unavailableStorage }
    }

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
    var invitation: T3PushInvitation
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
