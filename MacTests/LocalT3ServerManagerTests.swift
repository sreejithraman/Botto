import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BottoCore
@testable import BottoMac

struct LocalT3ServerManagerTests {
    @Test func settingsOverrideWinsOverTheBundleAndPATH() throws {
        try withEngineFiles { resources, path, override in
            let engine = try T3EngineExecutable.resolve(
                override: "  \(override.path)  ", resources: resources, searchDirectories: [path.path]
            )
            #expect(engine.url == override)
            #expect(engine.source == .settings)
        }
    }

    @Test func bundledExecutableWinsOverPATHAndReadsThePin() throws {
        try withEngineFiles { resources, path, _ in
            let bundle = resources.appending(path: "T3Engine")
            let pin = """
            {
              "version": "1.2.3",
              "commit": "abcdef0123456789",
              "runtime": {"name": "Node.js", "version": "26.1.0", "extra": true},
              "upstream": {"ref": "v1.2.3"}
            }
            """
            try Data(pin.utf8).write(to: bundle.appending(path: "pin.json"))

            let engine = try T3EngineExecutable.resolve(
                override: "", resources: resources, searchDirectories: [path.path]
            )
            #expect(engine.url == bundle.appending(path: "t3"))
            #expect(engine.source == .bundled)
            #expect(engine.pin?.version == "1.2.3")
            #expect(engine.pin?.commit == "abcdef0123456789")
            #expect(engine.pin?.runtime.version == "26.1.0")
        }
    }

    @Test func fallsBackToPATHWhenTheBundledExecutableIsMissing() throws {
        try withEngineFiles { resources, path, _ in
            try FileManager.default.removeItem(at: resources.appending(path: "T3Engine/t3"))
            let engine = try T3EngineExecutable.resolve(
                override: "", resources: resources, searchDirectories: [path.path]
            )
            #expect(engine.url == path.appending(path: "t3"))
            #expect(engine.source == .path)
            #expect(engine.pin == nil)
        }
    }

    @Test func invalidExplicitOverrideStopsResolution() throws {
        try withEngineFiles { resources, path, _ in
            #expect(throws: T3LocalError.invalidExecutable) {
                try T3EngineExecutable.resolve(
                    override: resources.path, resources: resources, searchDirectories: [path.path]
                )
            }
        }
    }

    private func withEngineFiles(
        _ test: (_ resources: URL, _ path: URL, _ override: URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appending(path: "Resources")
        let bundle = resources.appending(path: "T3Engine")
        let path = root.appending(path: "bin")
        let override = root.appending(path: "custom-t3")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        for file in [bundle.appending(path: "t3"), path.appending(path: "t3"), override] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        try test(resources, path, override)
    }

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

@MainActor struct MacPairingRoutesTests {
    private let raw = "http://127.0.0.1:3774/pair#token=Ab%2bc"
    private let lan = URL(string: "http://192.168.1.10:3774")!
    private let tailscale = URL(string: "http://100.64.1.2:3774")!

    @Test func theCodeCarriesEveryAvailableRouteWithLANAsThePrimary() throws {
        let routes = MacPairingRoutes(lan: lan, tailscale: tailscale, tunnel: " https://Botto.example.com/ ")
        #expect(routes.routes.map(\.name) == ["LAN", "Tailscale", "HTTPS tunnel"])
        let link = try #require(routes.pairingURL(from: raw))
        #expect(link == "http://192.168.1.10:3774/pair#token=Ab%2bc"
            + "&route=http%3A%2F%2F100.64.1.2%3A3774&route=https%3A%2F%2Fbotto.example.com")
        let parsed = try T3PairingExchange.parse(link)
        // Older phones read only the link's own origin and token.
        #expect(parsed.origin == lan && parsed.credential == "Ab+c")
        #expect(parsed.routes.map(\.absoluteString) == ["http://192.168.1.10:3774", "http://100.64.1.2:3774",
                                                        "https://botto.example.com"])
    }

    @Test func routesThatAreUnavailableSayWhyAndStayOutOfTheCode() throws {
        let routes = MacPairingRoutes(lan: nil, tailscale: tailscale, tunnel: "http://botto.example.com")
        #expect(routes.routes.map { $0.origin == nil } == [true, false, true])
        #expect(routes.routes[0].unavailable == "No active LAN IPv4 address was found.")
        #expect(routes.routes[2].unavailable == "Enter the tunnel’s HTTPS origin, such as https://botto.example.com.")
        #expect(routes.pairingURL(from: raw) == "http://100.64.1.2:3774/pair#token=Ab%2bc")

        let none = MacPairingRoutes(lan: URL(string: "http://8.8.8.8:3774"), tailscale: nil, tunnel: "")
        #expect(none.routes.map(\.unavailable) == ["Not a local network address.",
                                                   "Tailscale is off, or this Mac has no Tailscale address.", "No tunnel saved."])
        #expect(none.inCode.isEmpty && none.pairingURL(from: raw) == nil)
        #expect(MacPairingRoutes(lan: lan, tailscale: nil, tunnel: "https://botto.example.com/prefix").inCode == [lan])
    }

    @Test func routesClaimToBeInTheCodeOnlyWhileACodeIsShown() {
        let routes = MacPairingRoutes(lan: lan, tailscale: nil, tunnel: "").routes
        #expect(routes.map { MacPairPhoneContent.mark(for: $0, showingCode: true) } == ["In the code", "Not available", "Not available"])
        // While a code is being made, or after it expired.
        #expect(routes.map { MacPairPhoneContent.mark(for: $0, showingCode: false) } == ["Available", "Not available", "Not available"])
    }

    /// Renders the sheet with fixture routes and no live server, for seeing what a person sees: with a
    /// code, and while one is being made.
    @Test(arguments: [true, false]) func sheetListsEachRouteAndWhichAreInTheCode(showingCode: Bool) async throws {
        let routes = MacPairingRoutes(lan: lan, tailscale: tailscale, tunnel: "")
        let content = MacPairPhoneContent(routes: routes, tunnel: .constant(""),
                                          pairingURL: showingCode ? routes.pairingURL(from: "http://127.0.0.1:3774/pair#token=FIXTURE-ONLY") : nil,
                                          status: showingCode ? "" : "Generating a pairing link…", isGenerating: !showingCode,
                                          error: nil, canRefresh: showingCode, refresh: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 760), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        // Phones try HTTPS first, so the sheet doesn't promise LAN at home.
        #expect(String(localized: MacPairPhoneContent.intro) == "Pair your phone once. It reaches this Mac through your tunnel "
            + "while the tunnel answers, and otherwise over LAN or Tailscale. No T3 account required.")
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let name = showingCode ? "mac-pair-sheet.png" : "mac-pair-sheet-generating.png"
        Attachment.record(png, named: name)
        if let directory = ProcessInfo.processInfo.environment["BOTTO_SCREENSHOT_DIRECTORY"] {
            try png.write(to: URL(fileURLWithPath: directory).appending(path: name))
        }
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
