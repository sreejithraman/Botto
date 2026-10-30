import Foundation

extension HermesBotService {
    public func pushStatus(profileID: String) async throws -> PushHostStatus {
        let status: PushHostStatus = try await pushRequest("api/plugins/botto-push/status", profileID: profileID)
        guard status.v == 1, !status.pluginVersion.isEmpty,
              status.installationID == nil || PushEnvelope.validHex(status.installationID!, count: 64)
        else { throw PushError.invalidPayload }
        return status
    }

    public func enrollPushDevice(_ request: PushEnrollmentRequest, profileID: String) async throws -> PushEnrollment {
        let response: PushEnrollment = try await pushRequest("api/plugins/botto-push/devices", body: request, profileID: profileID)
        let validated = try response.validated()
        guard validated.deviceID == request.deviceID else { throw PushError.invalidPayload }
        return validated
    }

    public func removePushDevice(deviceID: String, operationID: UUID, profileID: String) async throws -> PushRemovalResult {
        guard PushEnvelope.validHex(deviceID, count: 32) else { throw PushError.invalidPayload }
        return try await pushRequest("api/plugins/botto-push/devices/\(deviceID)/remove",
            body: PushRemoveRequest(operationID: operationID.uuidString.lowercased()), profileID: profileID)
    }

    public func testPushDevice(deviceID: String, destination: PushDestination, profileID: String) async throws {
        guard PushEnvelope.validHex(deviceID, count: 32) else { throw PushError.invalidPayload }
        _ = try destination.validated()
        let _: PushRemovalResult = try await pushRequest("api/plugins/botto-push/devices/\(deviceID)/test", body: PushTestRequest(destination: destination), profileID: profileID)
    }

    public func installPushPlugin(identifier: String, ref: String, profileID: String) async throws -> PushPluginInstallResult {
        guard let url = URL(string: identifier), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, PushEnvelope.validHex(ref, count: 40) else { throw PushError.invalidPayload }
        let result: PushPluginInstallResult = try await pushRequest("api/dashboard/agent-plugins/install-profile",
            body: PushInstallRequest(identifier: identifier, ref: ref, profile: profileID), profileID: profileID)
        guard result.ok, let confirmed = result.profileID, confirmed.utf8.elementsEqual(profileID.utf8) else { throw PushError.invalidPayload }
        return result
    }

    private func pushRequest<Response: Decodable>(_ path: String, profileID: String) async throws -> Response {
        let owner = connectionGeneration
        guard let http else { throw HermesServiceError.disconnected }
        _ = try ExactID(profileID)
        let response = try await http.json(path, query: [.init(name: "profile", value: profileID)], validate: { try self.checkConnection(owner) })
        try checkConnection(owner)
        return try JSONDecoder().decode(Response.self, from: response.data)
    }

    private func pushRequest<Body: Encodable, Response: Decodable>(_ path: String, body: Body, profileID: String) async throws -> Response {
        let owner = connectionGeneration
        guard let http else { throw HermesServiceError.disconnected }
        guard let body = try HermesJSON.decode(JSONEncoder().encode(body)).fields else { throw PushError.invalidPayload }
        _ = try ExactID(profileID)
        let response = try await http.json(path, body: body, query: [.init(name: "profile", value: profileID)], validate: { try self.checkConnection(owner) })
        try checkConnection(owner)
        return try JSONDecoder().decode(Response.self, from: response.data)
    }
}

private struct PushRemoveRequest: Encodable { let v = 1; let operationID: String; enum CodingKeys: String, CodingKey { case v, operationID = "operation_id" } }
private struct PushTestRequest: Encodable {
    let v = 1
    let destination: PushDestination
}
private struct PushInstallRequest: Encodable { let identifier: String; let ref: String; let profile: String; let force = false; let enable = true }
