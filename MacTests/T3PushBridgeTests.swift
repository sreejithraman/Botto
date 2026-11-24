import Foundation
import Testing
@testable import BottoCore
@testable import BottoMac

@MainActor struct T3PushBridgeTests {
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
        await bridge.setScope(scope)
        let invite = try await bridge.makeInvitation(host: "127.0.0.1", port: port, scope: scope)
        let phoneCode = try T3PushInvitation(code: invite.code())
        let target = T3PushRegistration.Target(token: String(repeating: "12", count: 32), bundleID: "com.sree.botto", environment: .sandbox)
        let registration = T3PushRegistration(scope: scope, generation: 1, target: target)
        let result = try await T3PushRegistrationChannel.send(registration, invitation: phoneCode)
        #expect(result.status == .registered)
        #expect(await relay.methods == ["PUT"])
        #expect(try await T3PushRegistrationChannel.send(registration, invitation: phoneCode) == result)
        #expect(await relay.methods == ["PUT"])

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
        await bridge.setScope(nil)
        #expect(try await T3PushRegistrationChannel.send(remove, invitation: phoneCode).status == .removed)
        #expect(try await T3PushRegistrationChannel.send(registration, invitation: phoneCode).status == .retired)
        let reopened = try T3PushBridge(relay: origin, file: file, transport: { try await relay.send($0) })
        #expect(await reopened.register(invite.deviceID, expiresAt: invite.expiresAt, request: remove).status == .removed)
        #expect(await relay.methods == ["PUT", "POST", "POST"])
    }

    private actor RelayFixture {
        struct Event: Sendable { let id: String; let deviceID: String; let sealed: String; let wire: String }
        var methods: [String] = []
        var event: Event?

        func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            methods.append(try #require(request.httpMethod))
            if url.lastPathComponent == "events" {
                let data = try #require(request.httpBody)
                let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let targets = try #require(body["targets"] as? [[String: Any]])
                let target = try #require(targets.first)
                event = try .init(id: #require(body["event_id"] as? String),
                                  deviceID: #require(target["device_id"] as? String),
                                  sealed: #require(target["sealed"] as? String), wire: String(decoding: data, as: UTF8.self))
            }
            return (Data(#"{"v":1,"status":"accepted"}"#.utf8),
                    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }
}
