import Foundation
import Testing
import BottoCore
@testable import Botto

struct ConversationPersistenceTests {
    @Test func legacyBookWithoutLocalClosureKeysKeepsEveryChatVisible() throws {
        let profile = try ExactID("milo")
        var book = ConversationBook()
        let main = book.ensureProfile(profile)
        let identity = SessionIdentity(profile: profile, root: try ExactID("other-root"), stored: try ExactID("other-tip"), aliases: [])
        let other = book.merge(.init(identity: identity, title: "Other", isCanonical: false, persistence: .durable))
        book.update(other) { $0.isClosedLocally = true; $0.draft.text = "Keep" }
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        var records = try #require(encoded["records"] as? [[String: Any]])
        for index in records.indices { records[index].removeValue(forKey: "isClosedLocally") }
        encoded["records"] = records
        let decoded = try JSONDecoder().decode(ConversationBook.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded.visible(profile).map(\.id) == [main, other])
        #expect(decoded.record(other)?.draft.text == "Keep")
        #expect(decoded.opening(profile) == main)
    }

    @Test func identityMatchingRequiresOneProfileOwnedLineage() throws {
        let profile = try ExactID("milo"), foreign = try ExactID("scout"), alias = try ExactID("shared-tip")
        let source = SessionIdentity(profile: profile, root: try ExactID("source"), stored: alias, aliases: [alias])
        let other = SessionIdentity(profile: foreign, root: try ExactID("other"), stored: alias, aliases: [alias])
        let first = ChatRecord(id: ChatID(), profile: profile,
            binding: .identified(source, canonical: false, persistence: .durable), discoveryOrdinal: 0)
        let second = ChatRecord(id: ChatID(), profile: foreign,
            binding: .identified(other, canonical: false, persistence: .durable), discoveryOrdinal: 1)
        var book = ConversationBook(records: [first, second])
        let rotated = SessionIdentity(profile: profile, root: try ExactID("rotated"), stored: alias, aliases: [alias])
        #expect(book.matching(source) == first.id)
        #expect(book.matching(rotated) == first.id)
        #expect(book.matching(other) == second.id)
        let missing = SessionIdentity(profile: profile, root: try ExactID("missing"), stored: try ExactID("missing"), aliases: [])
        #expect(book.matching(missing) == nil)
        book.records.append(.init(id: ChatID(), profile: profile,
            binding: .identified(rotated, canonical: false, persistence: .durable), discoveryOrdinal: 2))
        #expect(book.matching(source) == nil)
        #expect(book.matching(rotated) == nil)
        #expect(book.matching(other) == second.id)
    }

    @Test func invalidHistoryIsReportedAsPreparationFailureWithoutReplacingTheCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        var history = LocalHistory()
        try history.fixtureDraft("Original draft", profile: "milo")
        try history.save(for: id, directory: directory)
        let url = try LocalHistory.file(for: id, directory: directory), original = try Data(contentsOf: url)
        history.book.records.append(try #require(history.book.records.first))

        do {
            try history.save(for: id, directory: directory)
            Issue.record("Invalid history must not replace the saved cache.")
        } catch {
            #expect(error.stage == .preparation)
            guard let cause = error.underlying as? HistoryFailure, case .invalidBook = cause else {
                Issue.record("The original validation failure must remain available for diagnosis.")
                return
            }
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try LocalHistory.load(for: id, directory: directory).fixtureRecord("milo")?.draft.text == "Original draft")
    }

    @Test func legacyUnionAndExactTextSurviveIndependentRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), url = directory.appendingPathComponent(id.uuidString + ".json")
        let text = "  e\u{301}\n\t "
        let old = LegacyHistoryFixture(bots: [.init(id: "roster", name: "Roster")],
            conversations: ["orphan": .init(id: "runtime", storedID: "old-tip", profileID: "orphan",
                messages: [.init(id: "m", role: .assistant, text: "Old answer")],
                pendingRequests: [.init(id: "approval", kind: .approval, title: "Old request")], isWorking: true)],
            drafts: ["draft-only": text], seen: ["seen-only": Date(timeIntervalSince1970: 42)],
            pinned: ["pin-only"], unpinned: ["unpin-only"])
        try JSONEncoder().encode(old).write(to: url)
        let migrated = try LocalHistory.load(for: id, directory: directory)
        #expect(Set(migrated.book.records.map { $0.profile.text }) == ["roster", "orphan", "draft-only", "seen-only", "pin-only", "unpin-only"])
        #expect(migrated.book.records.first { $0.profile.text == "draft-only" }?.draft.text == text)
        #expect(migrated.book.records.first { $0.profile.text == "orphan" }?.transcript?.pendingRequests.isEmpty == true)
        let fresh = try LocalHistory.load(for: id, directory: directory)
        #expect(fresh.book.records.map(\.id) == migrated.book.records.map(\.id))
        #expect(fresh.book.records.first { $0.profile.text == "orphan" }?.transcript?.messages.first?.text == "Old answer")
        #expect(Set(fresh.pinned.map(\.text)) == ["pin-only"] && Set(fresh.unpinned.map(\.text)) == ["unpin-only"])
    }
    @Test(arguments: ["corrupt", "future", "interrupted"])
    func failedMigrationPreservesOriginalBytesAndPruningSkipsSource(kind: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), url = directory.appendingPathComponent(id.uuidString + ".json")
        let source = kind == "corrupt" ? Data("{broken".utf8) : kind == "future"
            ? Data("{\"version\":999,\"privateData\":\"keep\"}".utf8)
            : try JSONEncoder().encode(LegacyHistoryFixture(drafts: ["orphan": " Keep exact "]))
        try source.write(to: url)
        #expect(throws: (any Error).self) {
            _ = try LocalHistory.load(for: id, directory: directory, atomicWrite: { data, target in
                try data.write(to: target, options: .atomic)
                throw HistoryFailure.migrationWrite
            })
        }
        #expect(try Data(contentsOf: url) == source)
        try LocalHistory.removeUnreachable(keeping: nil, directory: directory)
        #expect(try Data(contentsOf: url) == source)
    }

    @Test func unprovenLegacyMainIsPreservedBesideActualMain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), profile = try ExactID("milo")
        try JSONEncoder().encode(LegacyHistoryFixture(conversations: ["milo": .init(id: "runtime", storedID: "old", profileID: "milo")], drafts: ["milo": "legacy thought"]))
            .write(to: directory.appendingPathComponent(id.uuidString + ".json"))
        var history = try LocalHistory.load(for: id, directory: directory)
        let legacy = try #require(history.book.opening(profile))
        let identity = SessionIdentity(profile: profile, root: try ExactID("actual"), stored: try ExactID("tip"), aliases: [])
        let main = history.book.merge(.init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable))
        #expect(main != legacy)
        #expect(history.book.record(legacy)?.isUnverified == true)
        #expect(history.book.record(legacy)?.draft.text == "legacy thought")
        #expect(history.book.preference(profile)?.main == main)
        try history.save(for: id, directory: directory)
        let fresh = try LocalHistory.load(for: id, directory: directory)
        #expect(fresh.book.records.count == 2)
        #expect(fresh.book.record(legacy)?.draft.text == "legacy thought")
    }

    @Test func exactUnicodeProfilesSurviveMigrationAndIndependentV2Read() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), first = "é", second = "e\u{301}"
        let legacy = LegacyHistoryFixture(bots: [.init(id: first, name: "First"), .init(id: second, name: "Second")], drafts: [first: "first draft"])
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent(id.uuidString + ".json"))
        var migrated = try LocalHistory.load(for: id, directory: directory)
        #expect(migrated.book.records.count == 2)
        #expect(migrated.book.records.first { $0.profile.bytes == Data(first.utf8) }?.draft.text == "first draft")
        #expect(migrated.book.records.first { $0.profile.bytes == Data(second.utf8) }?.draft.text == "")
        let secondID = try #require(migrated.book.records.first { $0.profile.bytes == Data(second.utf8) }?.id)
        migrated.book.update(secondID) { $0.draft.text = "second draft" }
        try migrated.save(for: id, directory: directory)
        let fresh = try LocalHistory.load(for: id, directory: directory)
        #expect(fresh.book.records.count == 2)
        #expect(fresh.book.records.allSatisfy { $0.transcript == nil && $0.seen == nil })
        #expect(fresh.book.records.first { $0.profile.bytes == Data(first.utf8) }?.draft.text == "first draft")
        #expect(fresh.book.record(secondID)?.draft.text == "second draft")
    }
    @Test func ambiguousRawLegacyKeysArePreservedRatherThanCollapsedByDecoder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), url = directory.appendingPathComponent(id.uuidString + ".json")
        let raw = Data(#"{"bots":[],"conversations":{},"drafts":{"é":"first","e\u0301":"second"},"seen":{},"pinned":[],"unpinned":[]}"#.utf8)
        try raw.write(to: url)
        #expect(throws: (any Error).self) { _ = try LocalHistory.load(for: id, directory: directory) }
        #expect(try Data(contentsOf: url) == raw)
    }

    @Test func legacyDraftWithoutRemoteProofDoesNotBindToNewMain() throws {
        var history = LocalHistory()
        try history.fixtureDraft("no remote locator", profile: "milo")
        let profile = try ExactID("milo"), old = try #require(history.book.opening(profile))
        let identity = SessionIdentity(profile: profile, root: try ExactID("main-root"), stored: try ExactID("main-tip"), aliases: [])
        let main = history.book.merge(.init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable))
        #expect(main != old && history.book.record(old)?.isUnverified == true)
        #expect(history.book.record(main)?.draft.text == "")
        #expect(history.book.record(old)?.draft.text == "no remote locator")
    }

}

struct LegacyHistoryFixture: Codable {
    var bots: [BotProfile] = []
    var conversations: [String: Conversation] = [:]
    var drafts: [String: String] = [:]
    var seen: [String: Date] = [:]
    var pinned: Set<String> = []
    var unpinned: Set<String> = []
}
