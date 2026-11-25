import BottoCore
import CryptoKit
import Foundation
import Network
import Observation
import os

/// Owns local enrollment and the relay installation. The relay never receives a
/// T3 credential, Space identifier, or preview key.
actor T3PushBridge {
    private struct Device: Codable {
        let codeExpiry: Int
        var registration: T3PushRegistration
        var confirmed: Bool
        var providerRetired: Bool?
    }

    private struct RelayReply: Decodable {
        struct Target: Decodable {
            let deviceID: String
            let status: String

            enum CodingKeys: String, CodingKey { case deviceID = "device_id", status }
        }

        let v: Int
        let status: String
        let targets: [Target]?
    }

    private struct State: Codable {
        let relay: URL
        let token: String
        var devices: [String: Device] = [:]

        var installationID: String { Self.hex(SHA256.hash(data: Data(token.utf8))) }

        func opaque(_ values: [String]) throws -> String {
            let data = try JSONEncoder().encode(values)
            return Self.hex(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(token.utf8))))
        }

        static func hex(_ bytes: some Sequence<UInt8>) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    private let file: URL
    private let transport: T3PairingExchange.HTTPTransport
    private var state: State
    private var busy: Set<String> = []
    // Updated synchronously by the engine lifecycle. Relay work can suspend
    // without delaying or reordering a change in enrollment authority.
    private let scope = OSAllocatedUnfairLock<T3PushScope?>(initialState: nil)
    private let log = Logger(subsystem: "com.sree.botto.mac", category: "T3Push")

    init(relay: URL, file: URL,
         transport: @escaping T3PairingExchange.HTTPTransport = T3PairingExchange.directHTTP) throws {
        guard let parts = URLComponents(url: relay, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw T3PushRegistrationError.relayUnavailable }
        self.file = file
        self.transport = transport
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard state.relay == relay, PushEnvelope.validHex(state.token, count: 64) else {
                throw T3PushRegistrationError.relayUnavailable
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let token = SymmetricKey(size: .bits256).withUnsafeBytes { State.hex($0) }
            let fresh = State(relay: relay, token: token)
            try Self.save(fresh, to: file)
            state = fresh
        }
    }

    nonisolated func setScope(_ scope: T3PushScope?) {
        self.scope.withLock { $0 = scope }
    }

    func makeInvitation(host: String, port: UInt16) throws -> T3PushInvitation {
        guard let scope = scope.withLock({ $0 }) else { throw T3PushRegistrationError.bridgeUnavailable }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let expiresAt = Int(Date.now.timeIntervalSince1970) + 300
        return .init(host: host, port: port, scope: scope, deviceID: id,
                     expiresAt: expiresAt, secret: secret(id, expiresAt: expiresAt))
    }

    func secret(_ id: String, expiresAt: Int) -> Data {
        let input = Data("botto-t3-push-code-v1:\(id):\(expiresAt)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: Data(state.token.utf8))))
    }

    func register(_ id: String, expiresAt: Int, request: T3PushRegistration) async -> T3PushRegistrationReply {
        func reply(_ status: T3PushRegistrationReply.Status) -> T3PushRegistrationReply {
            .init(status, installationID: state.installationID)
        }
        guard (1...Int(Int32.max)).contains(request.generation),
              request.target?.isValid != false else { return reply(.retired) }
        guard !busy.contains(id) else { return reply(.retry) }
        let previous = state.devices[id]
        if let previous {
            guard previous.codeExpiry == expiresAt, previous.registration.scope == request.scope else { return reply(.differentWorkspace) }
            let old = previous.registration
            guard request.generation >= old.generation,
                  request.generation != old.generation || old == request,
                  old.target != nil || request.target == nil else { return reply(.retired) }
            if previous.providerRetired == true, let target = request.target, target == old.target {
                return reply(.retired)
            }
            if old == request, previous.confirmed, old.target == nil { return reply(.removed) }
        } else {
            let now = Int(Date.now.timeIntervalSince1970)
            if request.target == nil && expiresAt <= now { return reply(.removed) }
            guard expiresAt > now else { return reply(.retired) }
        }
        if request.target != nil, previous == nil || previous?.providerRetired == true,
           state.devices.values.count(where: { $0.registration.target != nil && $0.providerRetired != true }) >= 8 {
            return reply(.retry)
        }
        let confirmedEarlier = previous?.confirmed == true && previous?.registration == request
        // An existing pairing can revoke or recheck its target while the engine is asleep.
        guard request.target == nil || confirmedEarlier || scope.withLock({ $0 }) == request.scope
        else { return reply(.differentWorkspace) }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            if !confirmedEarlier {
                try saveDevice(id, Device(codeExpiry: expiresAt, registration: request, confirmed: false))
            }
            let path = "/devices/" + id
            if let target = request.target {
                let status = try await relay(path, method: "PUT", body: [
                    "v": 1, "generation": request.generation, "token": target.token, "bundle_id": target.bundleID,
                    "environment": target.environment.rawValue,
                    "preferences": ["replies": true, "requests": true, "failures": false, "previews": true],
                    "visible_chat": NSNull(), "visible_until": 0
                ]).status
                if status == "revoked" || status == "stale" {
                    try saveDevice(id, Device(codeExpiry: expiresAt, registration: request, confirmed: false, providerRetired: true))
                    return reply(.retired)
                }
                guard status == "accepted" || status == "duplicate" else { return reply(.retry) }
            } else {
                let status = try await relay(path + "/revoke", body: [
                    "v": 1, "generation": request.generation
                ]).status
                guard ["accepted", "duplicate", "revoked"].contains(status) else { return reply(.retry) }
            }
            if !confirmedEarlier {
                try saveDevice(id, Device(codeExpiry: expiresAt, registration: request, confirmed: true))
            }
            return reply(request.target == nil ? .removed : .registered)
        } catch {
            return reply(.retry)
        }
    }

    func publish(_ activity: T3PushActivity) async {
        guard activity.expiresAt > Int(Date.now.timeIntervalSince1970) else { return }
        do {
            let coordinates = [activity.scope.environmentID, activity.scope.projectID, activity.spaceID]
            let requestID = activity.kind == .reply ? nil : try state.opaque(["request"] + coordinates + [activity.id])
            if activity.cancelled, let requestID {
                guard state.devices.values.contains(where: {
                    $0.registration.scope == activity.scope && $0.providerRetired != true
                        && ($0.registration.target != nil || !$0.confirmed)
                }) else { return }
                _ = try await relay("/cancellations", body: [
                    "v": 1, "request_id": requestID, "expires_at": activity.expiresAt
                ])
                return
            }
            let devices = state.devices.filter {
                $0.value.confirmed && $0.value.registration.target != nil && $0.value.registration.scope == activity.scope
            }
            guard !devices.isEmpty else { return }
            let eventID = try state.opaque(["event", activity.kind.rawValue] + coordinates + [activity.id])
            let threadID = try state.opaque(["space"] + coordinates)
            let destination = activity.scope.destination(spaceID: activity.spaceID)
            let title = String(decoding: activity.title.utf8.prefix(156), as: UTF8.self)
            let message: String
            switch activity.kind {
            case .reply: message = "Work completed"
            case .approval: message = "Approval requested"
            case .question: message = "Question for you"
            case .failure: return
            }
            let preview = PushPreview(title: title, body: message, destination: destination)
            let routing = PushPreview(title: "", body: "", destination: destination)
            let targets: [[String: Any]] = try devices.map { id, device in
                let envelope = PushEnvelope(installationID: state.installationID, deviceID: id,
                    generation: device.registration.generation, eventID: eventID, kind: activity.kind,
                    expiresAt: activity.expiresAt, sealed: "")
                let key = T3PushInvitation.previewKey(secret: secret(id, expiresAt: device.codeExpiry))
                let sealed = try (try? envelope.encrypting(preview, key: key)) ?? envelope.encrypting(routing, key: key)
                return ["device_id": sealed.deviceID, "generation": sealed.generation, "sealed": sealed.sealed]
            }
            let delivery = try await relay("/events", body: [
                "v": 1, "event_id": eventID, "thread_id": threadID, "kind": activity.kind.rawValue,
                "request_id": requestID.map { $0 as Any } ?? NSNull(), "created_at": activity.createdAt,
                "expires_at": activity.expiresAt, "targets": targets
            ])
            for outcome in delivery.targets ?? [] where outcome.status == "invalid_target" || outcome.status == "revoked" {
                guard let sent = devices[outcome.deviceID], var current = state.devices[outcome.deviceID],
                      current.confirmed, sent.registration == current.registration else { continue }
                current.confirmed = false
                current.providerRetired = true
                try saveDevice(outcome.deviceID, current)
            }
        } catch {
            log.error("Couldn’t submit a T3 notification to the relay.")
        }
    }

    private func relay(_ suffix: String, method: String = "POST", body: [String: Any]) async throws -> RelayReply {
        var request = URLRequest(url: state.relay.appending(path: "/v1/installations/" + state.installationID + suffix))
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + state.token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode),
              let result = try? JSONDecoder().decode(RelayReply.self, from: data), result.v == 1 else {
            throw T3PushRegistrationError.relayUnavailable
        }
        return result
    }

    private func saveDevice(_ id: String, _ device: Device) throws {
        var updated = state
        updated.devices[id] = device
        try Self.save(updated, to: file)
        state = updated
    }

    private static func save(_ state: State, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

@MainActor @Observable final class T3PushListener {
    private let listener: NWListener
    private var activeConnections = 0
    private(set) var port: UInt16?
    private(set) var failed = false

    init(bridge: T3PushBridge, port: NWEndpoint.Port? = nil) throws {
        listener = try NWListener(using: .tcp, on: port ?? .any)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed = state { self.failed = true }
                self.port = state == .ready ? self.listener.port?.rawValue : nil
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.activeConnections < 16 else { connection.cancel(); return }
                self.activeConnections += 1
                await T3PushRegistrationChannel.accept(connection, secret: { await bridge.secret($0, expiresAt: $1) },
                                                       apply: { await bridge.register($0, expiresAt: $1, request: $2) })
                self.activeConnections -= 1
            }
        }
        listener.start(queue: DispatchQueue(label: "botto.t3.push-listener"))
    }

    func stop() { listener.cancel() }
}
