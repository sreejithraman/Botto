import Foundation
import Testing
@testable import BottoCore

@MainActor struct ProfileEditingTests {
    private func row() -> HermesJSON {
        .object(["name": .string("inbox-triage"), "description": .string("Original role"), "has_avatar": .bool(true),
            "ui_meta_revisions": .object(["hermes-bots": .number(2)]),
            "ui_meta": .object(["hermes-bots": .object(["title": .string("Before"), "future": .bool(true)])])])
    }

    @Test(arguments: ["name", "description"])
    func changedEditedFieldCannotBeOverwritten(field: String) async throws {
        let host = try HermesTestHost()
        var row = row()
        host.profiles = .object(["profiles": .array([row])])
        let service = host.service(); defer { service.disconnect() }
        _ = try await service.connect(configuration: host.configuration)
        let original = try #require(try await service.bots().first)
        if field == "name" { row["ui_meta"]["hermes-bots"]["title"] = .string("Another client's name") }
        else { row["description"] = .string("Another client's description") }
        host.profiles = .object(["profiles": .array([row])])
        await #expect(throws: HermesServiceError.profileConflict) {
            _ = try await service.updateProfile(.init(name: "New name", description: "New description"), for: original)
        }
        #expect(!host.sockets[0].sent.contains { $0["method"].text == "profiles.configure" })
    }

    @Test(arguments: ["partial", "uncertain", "conflict"])
    func unconfirmedSaveIsNotRepeated(outcome: String) async throws {
        let host = try HermesTestHost()
        host.profiles = .object(["profiles": .array([row()])])
        host.methodOverride = { frame, socket in
            guard frame["method"].text == "profiles.configure" else { return host.defaultReply(frame, socket: socket) }
            if outcome == "uncertain" { return nil }
            if outcome == "conflict" {
                return .object(["applied": .object(["ui_meta": .bool(false),
                    "ui_meta_conflicts": .object(["hermes-bots": .object(["actual": .number(3)])])])])
            }
            return .object(["applied": .object(["ui_meta": .bool(true), "description": .bool(false)])])
        }
        let service = host.service(requestTimeout: .milliseconds(50)); defer { service.disconnect() }
        _ = try await service.connect(configuration: host.configuration)
        let original = try #require(try await service.bots().first)
        let expected: HermesServiceError = outcome == "uncertain" ? .uncertainProfile : outcome == "conflict" ? .profileConflict : .partialProfile
        await #expect(throws: expected) {
            _ = try await service.updateProfile(.init(name: "New name", description: outcome == "conflict" ? nil : "New description"), for: original)
        }
        #expect(host.sockets[0].sent.filter { $0["method"].text == "profiles.configure" }.count == 1)
    }

    @Test func descriptionOnlyDoesNotWriteAppearanceOrTitle() async throws {
        let host = try HermesTestHost()
        host.profiles = .object(["profiles": .array([row()])])
        host.methodOverride = { frame, socket in
            guard frame["method"].text == "profiles.configure" else { return host.defaultReply(frame, socket: socket) }
            #expect(frame["params"].fields?.count == 2)
            #expect(frame["params"]["description"].text == "")
            return .object(["applied": .object(["description": .bool(true)])])
        }
        let service = host.service(); defer { service.disconnect() }
        _ = try await service.connect(configuration: host.configuration)
        let original = try #require(try await service.bots().first)
        let saved = try await service.updateProfile(.init(description: ""), for: original)
        #expect(saved.id == original.id && saved.name == original.name && saved.description.isEmpty)
        #expect(saved.appearance == original.appearance && saved.hasAvatar == true)
    }

    @Test(arguments: [true, false])
    func editKeepsIdentityAndFreshUneditedAppearance(authority: Bool) async throws {
        let host = try HermesTestHost(authority: authority)
        var row: HermesJSON = .object([
            "name": .string("inbox-triage"), "description": .string("Original role"), "has_avatar": .bool(true),
            "ui_meta_revisions": .object(["hermes-bots": .number(2)]),
            "ui_meta": .object(["hermes-bots": .object(["title": .string("Before"), "shape": .string("cloud"),
                "color": .string("#123456"), "pinned": .bool(true), "future": .bool(true)])])])
        host.profiles = .object(["profiles": .array([row])])
        var writes = 0
        host.methodOverride = { frame, socket in
            guard frame["method"].text == "profiles.configure" else { return host.defaultReply(frame, socket: socket) }
            writes += 1
            let params = frame["params"]
            #expect(params["name"].text == "inbox-triage")
            #expect(params["description"].text == "A clearer role")
            #expect(params["ui_meta_expected_revisions"]["hermes-bots"].integer == 3)
            let look = params["ui_meta"]["hermes-bots"]
            #expect(look["title"].text == "Renamed")
            #expect(look["shape"].text == "hexagon" && look["color"].text == "#123456")
            #expect(look["pinned"].flag == true && look["future"].flag == true)
            return .object(["applied": .object(["ui_meta": .bool(true), "description": .bool(true),
                "ui_meta_revisions": .object(["hermes-bots": .number(4)])])])
        }
        let service = host.service(); defer { service.disconnect() }
        _ = try await service.connect(configuration: host.configuration)
        let original = try #require(try await service.bots().first)
        row["ui_meta"]["hermes-bots"]["shape"] = .string("hexagon")
        row["ui_meta_revisions"]["hermes-bots"] = .number(3)
        host.profiles = .object(["profiles": .array([row])])
        let saved = try await service.updateProfile(.init(name: "Renamed", description: "A clearer role"), for: original)
        #expect(writes == 1 && saved.id == original.id)
        #expect(saved.name == "Renamed" && saved.description == "A clearer role")
        #expect(saved.appearance?.shape == .hexagon && saved.hasAvatar == true)
        #expect(!host.sockets[0].sent.contains { $0["method"].text == "profiles.set_asset" })
    }
}
