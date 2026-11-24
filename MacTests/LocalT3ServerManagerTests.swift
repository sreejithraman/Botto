import Foundation
import Testing
@testable import BottoMac

struct LocalT3ServerManagerTests {
    @Test func parsesServeOutput() {
        var links = T3PairingOutput()
        links.consume("T3 Code server is ready.")
        links.consume("Connection string: http://192.168.3.172:3774")
        links.consume("Pairing URL: http://192.168.3.172:3774/pair#token=EXAMPLE12345")
        links.consume("App link: t3code://pair?pairingUrl=http%3A%2F%2F192.168.3.172%3A3774%2Fpair%23token%3DEXAMPLE12345")
        #expect(links.pairingURL == "http://192.168.3.172:3774/pair#token=EXAMPLE12345")
        #expect(links.appLink == "t3code://pair?pairingUrl=http%3A%2F%2F192.168.3.172%3A3774%2Fpair%23token%3DEXAMPLE12345")
    }

    @Test func parsesPairOutput() {
        var links = T3PairingOutput()
        links.consume("  Pairing URL: https://botto.example.com/pair#token=FRESH1234567")
        links.consume("  App link: t3code://pair?pairingUrl=https%3A%2F%2Fbotto.example.com%2Fpair%23token%3DFRESH1234567\r")
        #expect(links.pairingURL == "https://botto.example.com/pair#token=FRESH1234567")
        #expect(links.appLink == "t3code://pair?pairingUrl=https%3A%2F%2Fbotto.example.com%2Fpair%23token%3DFRESH1234567")
    }

    @Test(arguments: [
        "http://192.168.1.10:3774",
        "http://100.64.1.2:3774",
        "https://botto.example.com",
    ])
    func rewritesPairingRoute(origin: String) throws {
        let route = try #require(URL(string: origin))
        let rewritten = T3RouteFormatter.pairingURL(
            from: "http://127.0.0.1:3774/pair#token=ABC", routeOrigin: route
        )
        #expect(rewritten == origin + "/pair#token=ABC")
    }

    @Test func preservesEncodedTokenBytes() throws {
        let route = try #require(URL(string: "https://botto.example.com:9443/"))
        let raw = "http://127.0.0.1:3774/pair#token=Ab%2bc%2F%25%3d+_%E2%98%83"
        let rewritten = T3RouteFormatter.pairingURL(from: raw, routeOrigin: route)
        #expect(rewritten == "https://botto.example.com:9443/pair#token=Ab%2bc%2F%25%3d+_%E2%98%83")
    }

    @Test(arguments: [
        "ftp://botto.example.com", "https:///missing-host", "/relative", "https://user:pass@botto.example.com",
        "https://botto.example.com/prefix", "https://botto.example.com?debug=1", "https://botto.example.com#fragment",
        "https://botto.example.com:0", "https://botto.example.com:65536",
    ])
    func rejectsInvalidOrigins(origin: String) throws {
        let route = try #require(URL(string: origin))
        #expect(T3RouteFormatter.pairingURL(from: "http://127.0.0.1:3774/pair#token=ABC", routeOrigin: route) == nil)
    }
}

struct MacMarkdownTests {
    @Test func splitsFencedCodeWithLanguage() {
        let blocks = MacMarkdown.blocks(from: "Here you go:\n\n```swift\nlet a = 1\n\n  print(a)\n```\nDone **now**.")
        #expect(blocks == [
            .paragraph("Here you go:"),
            .code(language: "swift", code: "let a = 1\n\n  print(a)"),
            .paragraph("Done **now**."),
        ])
    }

    @Test func keepsUnclosedFenceWhileStreaming() {
        #expect(MacMarkdown.blocks(from: "~~~\nlet partial") == [.code(language: nil, code: "let partial")])
    }

    @Test func shorterFenceDoesNotCloseLongerOne() {
        let blocks = MacMarkdown.blocks(from: "````md\n```\ninner\n```\n````")
        #expect(blocks == [.code(language: "md", code: "```\ninner\n```")])
    }

    @Test func readsHeadingsListsQuotesAndRules() {
        let text = "# Plan\n- one\n  more\n2. two\n- [x] done\n> quoted\n---\nplain\nline"
        #expect(MacMarkdown.blocks(from: text) == [
            .heading(level: 1, text: "Plan"),
            .listItem(marker: "•", text: "one\nmore", depth: 0),
            .listItem(marker: "2.", text: "two", depth: 0),
            .listItem(marker: "☑", text: "done", depth: 0),
            .quote("quoted"),
            .rule,
            .paragraph("plain\nline"),
        ])
    }

    @Test func hashtagWithoutSpaceStaysProse() {
        #expect(MacMarkdown.blocks(from: "#general is busy") == [.paragraph("#general is busy")])
    }

    @Test func inlineMarkdownKeepsLinksAndCode() {
        let attributed = MacMarkdown.inline("Use `swift test` at [docs](https://example.com)")
        #expect(String(attributed.characters) == "Use swift test at docs")
        #expect(attributed.runs.contains { $0.link == URL(string: "https://example.com") })
        #expect(attributed.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }
}

struct MacSessionPersistenceTests {
    final class MemorySlot: MacSecretSlot, @unchecked Sendable {
        var stored: Data?
        let accepts: Bool
        init(accepts: Bool = true) { self.accepts = accepts }
        func read() -> Data? { stored }
        func write(_ data: Data) -> Bool {
            if accepts { stored = data }
            return accepts
        }
        func delete() { stored = nil }
    }

    private func defaults() throws -> UserDefaults {
        let suite = "botto.mac.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func migratesLegacyDefaultsIntoSlot() throws {
        let defaults = try defaults()
        let legacy = Data("legacy".utf8)
        defaults.set(legacy, forKey: MacSessionPersistence.legacyDefaultsKey)
        let slot = MemorySlot()
        let persistence = MacSessionPersistence(slot: slot, defaults: defaults)
        #expect(persistence.load() == legacy)
        #expect(slot.stored == legacy)
        #expect(defaults.data(forKey: MacSessionPersistence.legacyDefaultsKey) == nil)
    }

    @Test func keepsSessionInMemoryWhenSlotRefuses() throws {
        let defaults = try defaults()
        let persistence = MacSessionPersistence(slot: MemorySlot(accepts: false), defaults: defaults)
        persistence.save(Data("fresh".utf8))
        #expect(persistence.load() == Data("fresh".utf8))
        #expect(defaults.data(forKey: MacSessionPersistence.legacyDefaultsKey) == nil)
    }
}

struct MacAvatarActivityTests {
    @Test func needsYouOutranksWork() {
        #expect(MacAvatarActivity(status: .working, phase: .tools, needsResponse: true) == .waiting)
        #expect(MacAvatarActivity(status: .working, phase: .tools) == .tools)
        #expect(MacAvatarActivity(status: .working) == .working)
        #expect(MacAvatarActivity(status: .idle) == .idle)
    }
}
