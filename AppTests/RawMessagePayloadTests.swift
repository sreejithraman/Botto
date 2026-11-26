import Foundation
import Testing
@testable import Botto

struct RawMessagePayloadTests {
    @Test func largeRawDetailsUseBoundedSectionsWithoutLosingBytes() {
        let payload = "{\"diagnostic\":true}\n" + String(repeating: "Diagnostic: healthy 🦊\n", count: 5000) + String(repeating: "x", count: 2000)
        let sections = RawMessagePayload.sections(payload)
        #expect(sections.count > 100)
        #expect(sections.allSatisfy { !$0.isEmpty && $0.count <= 512 })
        #expect(Data(sections.joined().utf8) == Data(payload.utf8))
        #expect(sections.first?.hasPrefix("{\"diagnostic\"") == true)
    }
}
