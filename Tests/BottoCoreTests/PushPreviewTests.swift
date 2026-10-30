import Foundation
import Testing
@testable import BottoCore

struct PushPreviewTests {
    // Independently produced with Python cryptography AESGCM, fixed key and nonce.
    private let sealed = "AAECAwQFBgcICQoLPCCgOf/U7jn5KOPn1MtCT86/61vSV30eVwOcpydLUtdgdNfeg+Ni6hvCFoHt2EFczGNC7zWigfYd5UV2bLycitIG5Ai8vlJDMHbZGoD9a4xn461ATEEgHJKP+6hajfUVL4DWs/om/9SHZPToHdw="

    @Test func pythonEnvelopeDecryptsAndRetainsExactDestination() throws {
        let envelope = PushEnvelope(installationID: String(repeating: "a", count: 64),
            deviceID: String(repeating: "b", count: 32), generation: 1,
            eventID: String(repeating: "c", count: 64), kind: .reply,
            expiresAt: 2_000_000_000, sealed: sealed)
        let preview = try envelope.decrypt(key: Data(0..<32), now: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(preview.title == "Milo" && preview.body == "Ready")
        #expect(preview.destination == PushDestination(profileID: "bot", rootID: "root", storedID: "stored"))
        var wrong = envelope
        wrong.eventID = String(repeating: "d", count: 64)
        #expect(throws: (any Error).self) { try wrong.decrypt(key: Data(0..<32), now: Date(timeIntervalSince1970: 1_900_000_000)) }
    }

    @Test func pythonEnvelopeParsesFromTheBottoAPNsNamespace() throws {
        let envelope: [String: Any] = [
            "v": 1, "installation_id": String(repeating: "a", count: 64),
            "device_id": String(repeating: "b", count: 32), "generation": 1,
            "event_id": String(repeating: "c", count: 64), "kind": "reply",
            "expires_at": 2_000_000_000, "sealed": sealed,
        ]
        let parsed = try PushEnvelope.parse(userInfo: ["botto": envelope])
        let preview = try parsed.decrypt(key: Data(0..<32), now: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(preview.title == "Milo" && preview.body == "Ready")
        #expect(throws: PushError.invalidPayload) {
            try PushEnvelope.parse(userInfo: ["unrelated": envelope])
        }
    }

    @Test func expiredOrWrongDeviceEnvelopeDoesNotYieldPreview() throws {
        let envelope = PushEnvelope(installationID: String(repeating: "a", count: 64),
            deviceID: String(repeating: "b", count: 32), generation: 1,
            eventID: String(repeating: "c", count: 64), kind: .reply,
            expiresAt: 1, sealed: sealed)
        #expect(throws: (any Error).self) { try envelope.decrypt(key: Data(0..<32), now: Date(timeIntervalSince1970: 2)) }
        var wrongDevice = envelope
        wrongDevice.expiresAt = 2_000_000_000
        wrongDevice.deviceID = String(repeating: "d", count: 32)
        #expect(throws: (any Error).self) { try wrongDevice.decrypt(key: Data(0..<32), now: Date(timeIntervalSince1970: 2)) }
    }

    @Test func destinationEqualityPreservesRemoteUTF8Spelling() {
        let composed = PushDestination(profileID: "bot", rootID: "caf\u{00e9}", storedID: "stored")
        let decomposed = PushDestination(profileID: "bot", rootID: "cafe\u{0301}", storedID: "stored")
        #expect(composed != decomposed)
    }

    @Test func sharedBoundaryEnvelopeRetainsItsFullPreviewAndExactLongDestination() throws {
        struct Fixture: Decodable {
            let key_base64: String
            let plaintext: PushPreview
            let envelope: PushEnvelope
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: root.appendingPathComponent("Push/fixtures/payload-boundary.json")))
        let key = try #require(Data(base64Encoded: fixture.key_base64))
        let preview = try fixture.envelope.decrypt(key: key, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(preview == fixture.plaintext)
        #expect(preview.body.utf8.count == 1024)
        #expect(preview.destination.rootID.utf8.count == 512)
        #expect(preview.destination.storedID.utf8.count == 512)
    }
}
