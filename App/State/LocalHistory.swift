import Foundation
import BottoCore
import OSLog

/// AppStore is the sole disk writer. Decoding never turns unreadable bytes into empty history.
struct LocalHistory: Codable {
    struct SaveFailure: Error, LocalizedError {
        enum Stage: String { case preparation, storage }
        let stage: Stage
        let underlying: any Error
        var errorDescription: String? {
            switch stage {
            case .preparation:
                "Botto couldn’t prepare your offline history for saving. Your current chat is still available."
            case .storage:
                "Your offline history couldn’t be saved on this device. Your current chat is still available."
            }
        }
    }
    private static let logger = Logger(subsystem: "com.sree.botto", category: "History")
    static let schemaVersion = 2
    var version = schemaVersion
    var bots: [BotProfile] = []
    var book = ConversationBook()
    var pinned: Set<ExactID> = []
    var unpinned: Set<ExactID> = []

    private struct Header: Decodable { let version: Int? }
    private struct Legacy: Decodable {
        var bots: [BotProfile]
        var conversations: [String: Conversation]
        var drafts: [String: String]
        var seen: [String: Date]
        var pinned: [String]
        var unpinned: [String]
    }
    private static func folder() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Botto", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutableFolder = folder; try mutableFolder.setResourceValues(values)
        return folder
    }
    static func file(for connectionID: UUID, directory: URL? = nil) throws -> URL {
        try (directory ?? folder()).appendingPathComponent(connectionID.uuidString + ".json")
    }
    var readOnly: Self {
        var copy = self; copy.book = book.readOnly
        // Roster status is sampled again; never recover action authority from cache.
        for index in copy.bots.indices { copy.bots[index].status = .idle }
        return copy
    }
    private static func decode(_ data: Data) throws -> (history: Self, migrated: Bool) {
        try HistoryJSONValidation.check(data)
        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) }
        catch { throw HistoryFailure.corrupt }
        if let version = header.version {
            guard version == schemaVersion else { throw HistoryFailure.unknownVersion(version) }
            let history: Self
            do { history = try decoder.decode(Self.self, from: data) }
            catch { throw HistoryFailure.corrupt }
            try history.book.validate()
            return (history.readOnly, false)
        }
        let legacy: Legacy
        do { legacy = try decoder.decode(Legacy.self, from: data) }
        catch { throw HistoryFailure.corrupt }
        var history = Self(); history.bots = legacy.bots
        history.pinned = try Set(legacy.pinned.map(ExactID.init)); history.unpinned = try Set(legacy.unpinned.map(ExactID.init))
        let keys = try Set((legacy.bots.map(\.id) + Array(legacy.conversations.keys) + Array(legacy.drafts.keys)
            + Array(legacy.seen.keys) + legacy.pinned + legacy.unpinned).map(ExactID.init))
        for profile in keys.sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) {
            // Dictionary String lookup folds Unicode. Match source bytes explicitly.
            let transcript = legacy.conversations.first { Data($0.key.utf8) == profile.bytes }?.value
            let draft = legacy.drafts.first { Data($0.key.utf8) == profile.bytes }?.value
            let seen = legacy.seen.first { Data($0.key.utf8) == profile.bytes }?.value
            let id = history.book.ensureProfile(profile)
            history.book.update(id) { record in
                record.binding = .provisionalMain(legacyStored: transcript.flatMap { try? ExactID($0.storedID) })
                record.transcript = transcript.map(ConversationBook.inert)
                record.draft = .init(text: draft ?? "", revision: UUID())
                record.seen = seen.map { .init(messageID: nil, observedAt: $0) }
                record.preview = legacy.bots.first { Data($0.id.utf8) == profile.bytes }?.preview ?? ""
                record.updatedAt = legacy.bots.first { Data($0.id.utf8) == profile.bytes }?.updatedAt
            }
        }
        try history.book.validate()
        return (history.readOnly, true)
    }
    /// Migration writes atomically and verifies a fresh independent read before releasing source bytes.
    static func load(for connectionID: UUID, directory: URL? = nil,
                     atomicWrite: (Data, URL) throws -> Void = write) throws -> LocalHistory {
        let url = try file(for: connectionID, directory: directory)
        let original: Data
        do { original = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .init() }
        let decoded = try decode(original)
        guard decoded.migrated else { return decoded.history }
        let replacement = try JSONEncoder().encode(decoded.history)
        do {
            try atomicWrite(replacement, url)
            let fresh = try Data(contentsOf: url)
            guard fresh == replacement else { throw HistoryFailure.migrationWrite }
            _ = try decode(fresh)
        } catch {
            // Even an injected/interrupted writer that replaced bytes is rolled back.
            if (try? Data(contentsOf: url)) != original { try write(original, url) }
            throw error
        }
        return decoded.history
    }
    private static func write(_ data: Data, _ url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
    func save(for connectionID: UUID, directory: URL? = nil) throws(SaveFailure) {
        let data: Data
        do {
            try book.validate()
            data = try JSONEncoder().encode(readOnly)
        } catch { throw Self.saveFailure(error, during: .preparation) }
        do { try Self.write(data, Self.file(for: connectionID, directory: directory)) }
        catch { throw Self.saveFailure(error, during: .storage) }
    }
    private static func saveFailure(_ error: any Error, during stage: SaveFailure.Stage) -> SaveFailure {
        let cause = error as NSError
        // Do not log descriptions or userInfo: they can include conversation text and paths.
        logger.error("History save failed during \(stage.rawValue, privacy: .public): \(cause.domain, privacy: .public) code \(cause.code)")
        return SaveFailure(stage: stage, underlying: error)
    }
    struct CacheReplacement {
        fileprivate let url: URL
        fileprivate let previous: Data?
        func rollback() throws {
            if let previous { try LocalHistory.write(previous, url) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    func prepareReplacement(for connectionID: UUID, directory: URL? = nil) throws -> CacheReplacement {
        let url = try Self.file(for: connectionID, directory: directory)
        let previous: Data?
        do { previous = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { previous = nil }
        // Never overwrite a corrupt, newer-schema or unmigrated source during reauth.
        if let previous { _ = try Self.decode(previous) }
        try save(for: connectionID, directory: directory)
        return CacheReplacement(url: url, previous: previous)
    }
    static func removeUnreachable(keeping connectionID: UUID?, directory: URL? = nil) throws {
        let directory = try directory ?? folder()
        for url in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.lastPathComponent == id.uuidString + ".json", id != connectionID else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url), let decoded = try? decode(data), !decoded.migrated else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
    static func remove(for connectionID: UUID) {
        guard let url = try? file(for: connectionID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
