import Foundation
import Testing
@testable import BottoCore
@testable import BottoMac

@MainActor struct T3PushBridgeTests {
    @Test func rejectsOneCharacterBundleIDBeforeSendingRegistration() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let relay = RelayFixture()
        let bridge = try T3PushBridge(relay: #require(URL(string: "https://relay.example")),
            file: directory.appending(path: "bridge.json"), transport: { try await relay.send($0) })
        let scope = T3PushScope(environmentID: "my-engine", projectID: "my-project")
        bridge.setScope(scope)
        let code = try await bridge.makeInvitation(host: "127.0.0.1", port: 3775)
        let token = String(repeating: "12", count: 32)
        let invalid = T3PushRegistration(scope: scope, generation: 1,
            target: .init(token: token, bundleID: "a", environment: .sandbox))
        let valid = T3PushRegistration(scope: scope, generation: 1,
            target: .init(token: token, bundleID: "a1", environment: .sandbox))

        #expect(await bridge.register(code.deviceID, expiresAt: code.expiresAt, request: invalid).status == .retired)
        #expect(await relay.methods.isEmpty)
        #expect(await bridge.register(code.deviceID, expiresAt: code.expiresAt, request: valid).status == .registered)
        #expect(await relay.methods == ["PUT"])
    }

    @Test func pairsOverLocalTCPAndSealsTheExactSpaceForAPNs() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "bridge.json")
        let relay = RelayFixture()
        let origin = try #require(URL(string: "https://relay.example"))
        let bridge = try T3PushBridge(relay: origin, file: file, transport: { try await relay.send($0) })
        let listener = try T3PushListener(bridge: bridge)
        defer { listener.stop() }
        let deadline = ContinuousClock.now + .seconds(3)
        while listener.port == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let port = try #require(listener.port)
        let scope = T3PushScope(environmentID: "my-engine", projectID: "my-project")
        bridge.setScope(scope)
        let invite = try await bridge.makeInvitation(host: "127.0.0.1", port: port)
        let phoneCode = try T3PushInvitation(code: invite.code())
        let target = T3PushRegistration.Target(token: String(repeating: "12", count: 32), bundleID: "com.sree.botto", environment: .sandbox)
        let registration = T3PushRegistration(scope: scope, generation: 1, target: target)
        let result = try await T3PushRegistrationChannel.send(registration, invitation: phoneCode)
        #expect(result.status == .registered)
        #expect(await relay.methods == ["PUT"])
        #expect(try await T3PushRegistrationChannel.send(registration, invitation: phoneCode) == result)
        #expect(await relay.methods == ["PUT", "PUT"])

        let now = Int(Date.now.timeIntervalSince1970)
        await bridge.publish(.init(scope: scope, spaceID: "originating-space", title: "Release plans",
            id: "run-1", kind: .reply, createdAt: now, expiresAt: now + 3_600, cancelled: false))
        let event = try #require(await relay.event)
        let payload: [String: Any] = [
            "v": 1, "installation_id": result.installationID, "device_id": event.deviceID,
            "generation": 1, "event_id": event.id, "kind": "reply", "expires_at": now + 3_600, "sealed": event.sealed
        ]
        let envelope = try PushEnvelope.parse(userInfo: ["botto": payload])
        let clear = try envelope.decrypt(key: phoneCode.previewKey)
        #expect(clear.destination == PushDestination(profileID: "my-project", rootID: "originating-space", storedID: "originating-space"))
        #expect(clear.title == "Release plans")
        #expect(clear.body == "Work completed")
        #expect(!event.wire.contains("originating-space") && !event.wire.contains("Release plans"))
        #expect(throws: (any Error).self) { try envelope.decrypt(key: Data(repeating: 0, count: 32)) }

        let remove = T3PushRegistration(scope: scope, generation: 2, target: nil)
        bridge.setScope(nil)
        #expect(try await T3PushRegistrationChannel.send(remove, invitation: phoneCode).status == .removed)
        #expect(try await T3PushRegistrationChannel.send(registration, invitation: phoneCode).status == .retired)
        let reopened = try T3PushBridge(relay: origin, file: file, transport: { try await relay.send($0) })
        #expect(await reopened.register(invite.deviceID, expiresAt: invite.expiresAt, request: remove).status == .removed)
        #expect(await relay.methods == ["PUT", "PUT", "POST", "POST"])
    }

    @Test func deviceRetirementAndCancellationSurviveAScopeDisconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let relay = RelayFixture()
        let origin = try #require(URL(string: "https://relay.example"))
        let bridge = try T3PushBridge(relay: origin, file: directory.appending(path: "bridge.json"),
                                      transport: { try await relay.send($0) })
        let scope = T3PushScope(environmentID: "my-engine", projectID: "my-project")
        bridge.setScope(scope)
        let retired = try await bridge.makeInvitation(host: "127.0.0.1", port: 3775)
        let keepsReceiving = try await bridge.makeInvitation(host: "127.0.0.1", port: 3775)
        let target = T3PushRegistration.Target(token: String(repeating: "12", count: 32),
                                               bundleID: "com.sree.botto", environment: .sandbox)
        let initial = T3PushRegistration(scope: scope, generation: 1, target: target)
        for code in [retired, keepsReceiving] {
            #expect(await bridge.register(code.deviceID, expiresAt: code.expiresAt, request: initial).status == .registered)
        }
        await relay.setRetired(retired.deviceID)
        bridge.setScope(nil)
        let now = Int(Date.now.timeIntervalSince1970)
        await bridge.publish(.init(scope: scope, spaceID: "space", title: "Release plans",
            id: "run-1", kind: .reply, createdAt: now, expiresAt: now + 3_600, cancelled: false))
        #expect(await relay.deliveredTargets.last?.count == 2)
        #expect(await bridge.register(retired.deviceID, expiresAt: retired.expiresAt, request: initial).status == .retired)

        await bridge.publish(.init(scope: scope, spaceID: "space", title: "Release plans",
            id: "approval", kind: .approval, createdAt: now, expiresAt: now + 300, cancelled: false))
        #expect(await relay.deliveredTargets.last == [keepsReceiving.deviceID])
        let requestID = try #require(await relay.latestRequestID)
        bridge.setScope(scope)
        let rotatedTarget = T3PushRegistration.Target(token: String(repeating: "ab", count: 32),
                                                       bundleID: target.bundleID, environment: target.environment)
        let rotated = T3PushRegistration(scope: scope, generation: 2, target: rotatedTarget)
        await relay.failNextPut()
        #expect(await bridge.register(keepsReceiving.deviceID, expiresAt: keepsReceiving.expiresAt,
                                      request: rotated).status == .retry)
        bridge.setScope(nil)
        await bridge.publish(.init(scope: scope, spaceID: "space", title: "Release plans",
            id: "approval", kind: .approval, createdAt: now, expiresAt: now + 300, cancelled: true))
        #expect(await relay.cancelledRequestID == requestID)

        bridge.setScope(scope)
        #expect(await bridge.register(retired.deviceID, expiresAt: retired.expiresAt, request: rotated).status == .registered)
    }

    @Test func revalidationDetectsRetirementAfterRelayRetries() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let relay = RelayFixture()
        let bridge = try T3PushBridge(relay: #require(URL(string: "https://relay.example")),
                                      file: directory.appending(path: "bridge.json"), transport: { try await relay.send($0) })
        let scope = T3PushScope(environmentID: "my-engine", projectID: "my-project")
        bridge.setScope(scope)
        let code = try await bridge.makeInvitation(host: "127.0.0.1", port: 3775)
        let target = T3PushRegistration.Target(token: String(repeating: "12", count: 32),
                                               bundleID: "com.sree.botto", environment: .sandbox)
        let initial = T3PushRegistration(scope: scope, generation: 1, target: target)
        #expect(await bridge.register(code.deviceID, expiresAt: code.expiresAt, request: initial).status == .registered)
        await relay.queueEvents()
        let now = Int(Date.now.timeIntervalSince1970)
        await bridge.publish(.init(scope: scope, spaceID: "space", title: "Release plans",
            id: "run-1", kind: .reply, createdAt: now, expiresAt: now + 3_600, cancelled: false))
        await relay.revokeOnRevalidation()
        #expect(await bridge.register(code.deviceID, expiresAt: code.expiresAt, request: initial).status == .retired)
        #expect(await relay.methods == ["PUT", "POST", "PUT"])
    }

    private actor RelayFixture {
        struct Event: Sendable { let id: String; let deviceID: String; let sealed: String; let wire: String }
        var methods: [String] = []
        var event: Event?
        var deliveredTargets: [[String]] = []
        var latestRequestID: String?
        var cancelledRequestID: String?
        var retiredID: String?
        var failPut = false
        var putStatus = "accepted"
        var eventStatus = "accepted"

        func queueEvents() { eventStatus = "queued" }
        func revokeOnRevalidation() { putStatus = "revoked" }
        func setRetired(_ id: String) { retiredID = id }
        func failNextPut() { failPut = true }

        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            methods.append(try #require(request.httpMethod))
            if request.httpMethod == "PUT", failPut {
                failPut = false
                throw T3PushRegistrationError.relayUnavailable
            }
            let data = try #require(request.httpBody)
            let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var result: [String: Any] = ["v": 1, "status": request.httpMethod == "PUT" ? putStatus : "accepted"]
            if url.lastPathComponent == "events" {
                let targets = try #require(body["targets"] as? [[String: Any]])
                let target = try #require(targets.first)
                let ids = try targets.map { try #require($0["device_id"] as? String) }
                deliveredTargets.append(ids)
                latestRequestID = body["request_id"] as? String
                result["targets"] = ids.map { ["device_id": $0, "status": $0 == retiredID ? "invalid_target" : eventStatus] }
                event = try .init(id: #require(body["event_id"] as? String),
                                  deviceID: #require(target["device_id"] as? String),
                                  sealed: #require(target["sealed"] as? String), wire: String(decoding: data, as: UTF8.self))
            } else if url.lastPathComponent == "cancellations" {
                cancelledRequestID = body["request_id"] as? String
            }
            return (try JSONSerialization.data(withJSONObject: result),
                    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }
}
