import CryptoKit
import Foundation
import Network

public enum T3PushRegistrationError: LocalizedError, Sendable {
    case invalidCode, wrongMac, bridgeUnavailable, relayUnavailable, expiredCode

    public var errorDescription: String? {
        switch self {
        case .invalidCode: "Copy a notification code from Botto on your Mac."
        case .wrongMac: "This code belongs to a different Botto workspace."
        case .bridgeUnavailable: "Botto couldn’t reach the notification bridge. Check that your Mac is awake and reachable."
        case .relayUnavailable: "Your Mac couldn’t confirm the notification change with the relay. Try again."
        case .expiredCode: "Copy a fresh notification code from Botto on your Mac."
        }
    }
}

public struct T3PushInvitation: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let scope: T3PushScope
    public let deviceID: String
    public let expiresAt: Int
    public let secret: Data

    public init(host: String, port: UInt16, scope: T3PushScope, deviceID: String, expiresAt: Int, secret: Data) {
        self.host = host
        self.port = port
        self.scope = scope
        self.deviceID = deviceID
        self.expiresAt = expiresAt
        self.secret = secret
    }

    public init(code: String) throws {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "botto-push-v1."
        guard code.utf8.count <= 4_096, code.hasPrefix(prefix),
              let data = Data(base64Encoded: String(code.dropFirst(prefix.count))),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              PushEnvelope.validHex(value.deviceID, count: 32), value.secret.count == 32,
              (1...Int(UInt32.max)).contains(value.expiresAt),
              value.port != 0, !value.host.isEmpty, value.host.utf8.count <= 253 else {
            throw T3PushRegistrationError.invalidCode
        }
        self = value
    }

    public func code() throws -> String {
        "botto-push-v1." + (try JSONEncoder().encode(self)).base64EncodedString()
    }

    // Domain separation keeps the AES key shared with the extension independent of the wire key.
    public var previewKey: Data { Self.previewKey(secret: secret) }

    public static func previewKey(secret: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
            info: Data("botto-t3-apns-preview-v1".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}

public struct T3PushRegistration: Codable, Equatable, Sendable {
    public struct Target: Codable, Equatable, Sendable {
        public let token: String
        public let bundleID: String
        public let environment: PushEnvironment

        public init(token: String, bundleID: String, environment: PushEnvironment) {
            self.token = token
            self.bundleID = bundleID
            self.environment = environment
        }

        public var isValid: Bool {
            (32...512).contains(token.utf8.count) && token.utf8.count.isMultiple(of: 2)
                && PushEnvelope.validHex(token, count: token.utf8.count)
                && (2...200).contains(bundleID.utf8.count)
                && bundleID.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
        }
    }

    public let scope: T3PushScope
    public let generation: Int
    /// Nil revokes this device ID permanently.
    public let target: Target?

    public init(scope: T3PushScope, generation: Int, target: Target?) {
        self.scope = scope
        self.generation = generation
        self.target = target
    }
}

public struct T3PushRegistrationReply: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case registered, removed, retry, differentWorkspace, retired }
    public let status: Status
    public let installationID: String
    public init(_ status: Status, installationID: String) {
        self.status = status
        self.installationID = installationID
    }
}

/// One length-prefixed exchange with a device-bound AES-GCM capability. Responses
/// authenticate the request nonce, so an old acknowledgment can't confirm a new write.
public enum T3PushRegistrationChannel {
    private static let queue = DispatchQueue(label: "botto.t3.push-registration")
    private static let frameLimit = 4_096

    public static func send(_ value: T3PushRegistration, invitation: T3PushInvitation) async throws -> T3PushRegistrationReply {
        guard let port = NWEndpoint.Port(rawValue: invitation.port) else { throw T3PushRegistrationError.invalidCode }
        let connection = NWConnection(host: NWEndpoint.Host(invitation.host), port: port, using: .tcp)
        let request = try seal(value, secret: invitation.secret, context: requestContext(invitation.deviceID))
        let expiry = UInt32(clamping: invitation.expiresAt).bigEndian
        let header = Data(invitation.deviceID.utf8) + withUnsafeBytes(of: expiry) { Data($0) }
        let frame = header + request
        connection.start(queue: queue)
        return try await exchange(connection) {
            try await write(frame, to: connection)
            let reply = try await read(from: connection)
            return try open(reply, as: T3PushRegistrationReply.self, secret: invitation.secret,
                            context: responseContext(invitation.deviceID, request: request))
        }
    }

    public static func accept(_ connection: NWConnection,
                              secret: @escaping @Sendable (String, Int) async -> Data,
                              apply: @escaping @Sendable (String, Int, T3PushRegistration) async -> T3PushRegistrationReply) async {
        connection.start(queue: queue)
        _ = try? await exchange(connection) {
            let frame = try await read(from: connection)
            let deviceID = String(decoding: frame.prefix(32), as: UTF8.self)
            guard frame.count >= 64, PushEnvelope.validHex(deviceID, count: 32) else { return }
            let expiresAt = frame.dropFirst(32).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let secret = await secret(deviceID, expiresAt)
            let request = Data(frame.dropFirst(36))
            let value = try open(request, as: T3PushRegistration.self, secret: secret, context: requestContext(deviceID))
            let reply = await apply(deviceID, expiresAt, value)
            try await write(seal(reply, secret: secret, context: responseContext(deviceID, request: request)), to: connection)
        }
    }

    private static func requestContext(_ id: String) -> Data { Data("botto-t3-push-request-v1:\(id)".utf8) }

    private static func responseContext(_ id: String, request: Data) -> Data {
        Data("botto-t3-push-response-v1:\(id):".utf8) + request.prefix(12)
    }

    private static func seal(_ value: some Encodable, secret: Data, context: Data) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        guard let combined = try AES.GCM.seal(encoded, using: SymmetricKey(data: secret),
                                              authenticating: context).combined else { throw PushError.invalidPayload }
        return combined
    }

    private static func open<Value: Decodable>(_ data: Data, as type: Value.Type, secret: Data, context: Data) throws -> Value {
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: secret), authenticating: context)
        return try JSONDecoder().decode(type, from: clear)
    }

    private static func exchange<Value: Sendable>(_ connection: NWConnection,
                                                   operation: () async throws -> Value) async throws -> Value {
        let timeout = Task {
            try await Task.sleep(for: .seconds(15))
            connection.cancel()
        }
        defer { timeout.cancel(); connection.cancel() }
        return try await withTaskCancellationHandler {
            do { return try await operation() }
            catch { throw T3PushRegistrationError.bridgeUnavailable }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func read(from connection: NWConnection) async throws -> Data {
        let header = try await receive(2, from: connection)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (28...frameLimit).contains(size) else { throw PushError.invalidPayload }
        return try await receive(size, from: connection)
    }

    private static func receive(_ length: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let data, data.count == length { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? T3PushRegistrationError.bridgeUnavailable) }
            }
        }
    }

    private static func write(_ frame: Data, to connection: NWConnection) async throws {
        guard frame.count <= frameLimit else { throw PushError.invalidPayload }
        let bytes = Data([UInt8(frame.count >> 8), UInt8(frame.count & 255)]) + frame
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
