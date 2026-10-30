import Foundation
import Testing
@testable import BottoCore

@MainActor struct PushHostClientTests {
    @Test func pushUsesAuthenticatedConnectionAndExplicitProfileScope() async throws {
        let host = try HermesTestHost()
        let original = host.transport.handler
        host.transport.handler = { request in
            if request.url?.path == "/api/plugins/botto-push/status" {
                return .object(["v": .number(1), "plugin_version": .string("0.1.0"), "supported": .bool(true),
                    "installation_id": .string(String(repeating: "a", count: 64)), "relay_url": .string("https://relay.invalid"),
                    "capabilities": .object(["native_session_events": .number(1)]), "devices": .array([])])
            }
            return try original?(request) ?? .null
        }
        let service = host.service()
        defer { service.disconnect() }
        var configuration = host.configuration
        configuration.connectionHeaders = ["CF-Access-Client-Id": "fixture-access-id", "CF-Access-Client-Secret": "fixture-only"]
        _ = try await service.connect(configuration: configuration)
        let status = try await service.pushStatus(profileID: "inbox-triage")
        #expect(status.supported && status.capabilities["native_session_events"] == 1)
        let request = try #require(host.transport.requests.last)
        #expect(request.url?.path == "/api/plugins/botto-push/status")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "fixture-access-id")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "profile", value: "inbox-triage")])
    }

    @Test(arguments: ["confirmed", "wrong-profile", "missing-profile", "old-host"])
    func installationRequiresAnExplicitProfileContractAndMatchingAcknowledgment(control: String) async throws {
        let host = try HermesTestHost()
        let original = host.transport.handler
        host.transport.handler = { request in
            if request.url?.path.hasPrefix("/api/dashboard/agent-plugins/") == true {
                if control == "old-host" { host.transport.responseStatus = 405; return .object([:]) }
                var result: [String: HermesJSON] = ["ok": .bool(true), "restart_required": .bool(true), "warnings": .array([])]
                if control != "missing-profile" { result["profile"] = .string(control == "wrong-profile" ? "default" : "inbox-triage") }
                return .object(result)
            }
            return try original?(request) ?? .null
        }
        let service = host.service()
        defer { service.disconnect() }
        _ = try await service.connect(configuration: host.configuration)
        let source = "https://example.invalid/plugin", ref = String(repeating: "a", count: 40)
        if control == "confirmed" {
            let result = try await service.installPushPlugin(identifier: source, ref: ref, profileID: "inbox-triage")
            #expect(result.ok && result.restartRequired)
        } else {
            await #expect(throws: (any Error).self) {
                try await service.installPushPlugin(identifier: source, ref: ref, profileID: "inbox-triage")
            }
        }
        let requests = host.transport.requests.filter { $0.url?.path.hasPrefix("/api/dashboard/agent-plugins/") == true }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.path == "/api/dashboard/agent-plugins/install-profile")
        let body = try HermesJSON.decode(#require(request.httpBody))
        #expect(body["profile"].text == "inbox-triage" && body["identifier"].text == source && body["ref"].text == ref)
        #expect(body["force"] == .bool(false) && body["enable"] == .bool(true))
    }

    @Test func enrollmentSerializesOnlyTheScopedTypedContract() async throws {
        let host = try HermesTestHost()
        let original = host.transport.handler
        let device = String(repeating: "b", count: 32)
        host.transport.handler = { request in
            if request.url?.path == "/api/plugins/botto-push/devices" {
                return .object(["v": .number(1), "status": .string("accepted"),
                    "installation_id": .string(String(repeating: "a", count: 64)), "device_id": .string(device),
                    "generation": .number(1), "preferences": .object(["replies": .bool(true), "requests": .bool(true), "failures": .bool(true), "previews": .bool(true)])])
            }
            return try original?(request) ?? .null
        }
        let service = host.service()
        defer { service.disconnect() }
        _ = try await service.connect(configuration: host.configuration)
        let input = PushEnrollmentRequest(deviceID: device, token: String(repeating: "1", count: 64),
            bundleID: "com.example.botto", environment: .sandbox, previewKey: Data(0..<32), preferences: .init(), expectedGeneration: 7)
        let response = try await service.enrollPushDevice(input, profileID: "inbox-triage")
        #expect(response.generation == 1 && response.deviceID == device)
        let request = try #require(host.transport.requests.last)
        let body = try HermesJSON.decode(#require(request.httpBody))
        #expect(request.httpMethod == "POST")
        #expect(body["preview_key"].text == Data(0..<32).base64EncodedString())
        #expect(body["operation_id"].text == input.operationID)
        #expect(body["expected_generation"].integer == 7)
        #expect(body["username"] == .null && body["password"] == .null)
        service.disconnect()
        await #expect(throws: HermesServiceError.self) { try await service.pushStatus(profileID: "inbox-triage") }
    }
}
