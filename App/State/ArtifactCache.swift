import Foundation
import BottoCore
import SQLite3
import CryptoKit

nonisolated struct ArtifactCacheScope: Hashable, Codable, Sendable {
    let configurationID: UUID
    let serverURL: Data
    let installationID: Data?
    let username: Data
    let provider: Data?
}
nonisolated enum ArtifactCacheCoverage: String, Codable, Sendable { case complete, partial }
nonisolated struct CachedArtifactChat: Codable, Sendable {
    let identity: SessionIdentity
    let botName: String
    let title: String
    let messages: [ChatMessage]
    let updatedAt: Date?
    let coverage: ArtifactCacheCoverage
    let summary: SessionSummary?
    let headFingerprint: Data?
    var unavailableMessageIDs: Set<Data>? = nil
}
nonisolated struct ArtifactOriginalKey: Hashable, Codable, Sendable {
    let identity: SessionIdentity
    let messageID: Data
    let path: Data
    let sourceRevision: Data
}
nonisolated struct CachedArtifactOriginal: Sendable {
    let artifact: DownloadedArtifact
    let digest: Data
}
nonisolated struct ArtifactThumbnailKey: Hashable, Codable, Sendable {
    let originalDigest: Data
    let maximumPixels: Int
    let decoderVersion: Int
}

@MainActor final class ArtifactCache {
    struct Limits: Sendable {
        var originalBytes = 256 * 1024 * 1024
        var thumbnailBytes = 32 * 1024 * 1024
        var singleOriginalBytes = 25 * 1024 * 1024
        var metadataBytes = 40 * 1024 * 1024
        var chatCount = 1_000
        var messageCount = 25_000
        var textBytes = 32 * 1024 * 1024
    }
    static let shared = ArtifactCache(root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BottoArtifacts", isDirectory: true))
    private let backend: ArtifactCacheBackend
    private var maintenance: Task<Void, Error>?
    private struct WeakSession { weak var value: ArtifactCacheSession?; let configurationID: UUID }
    private var sessions: [WeakSession] = []
    init(root: URL?, limits: Limits = .init()) { backend = ArtifactCacheBackend(root: root, limits: limits) }
    func session(scope: ArtifactCacheScope) -> ArtifactCacheSession {
        let session = ArtifactCacheSession(backend: backend, scope: scope, barrier: maintenance)
        sessions.removeAll { $0.value == nil }
        sessions.append(WeakSession(value: session, configurationID: scope.configurationID))
        return session
    }
    func discard(configurationID: UUID) {
        for item in sessions where item.configurationID == configurationID { item.value?.retire() }
        let previous = maintenance, backend = backend
        maintenance = Task {
            _ = try? await previous?.value
            try await backend.discard(configurationID)
        }
    }
    func prune(reachableConfigurationIDs: Set<UUID>) {
        for item in sessions where !reachableConfigurationIDs.contains(item.configurationID) { item.value?.retire() }
        let previous = maintenance, backend = backend
        maintenance = Task {
            _ = try? await previous?.value
            try await backend.prune(reachableConfigurationIDs)
        }
    }
    func drainMaintenance() async throws { try await maintenance?.value }
    func close() async {
        for item in sessions { item.value?.retire() }
        _ = try? await maintenance?.value
        await backend.close()
    }
}
@MainActor final class ArtifactCacheSession {
    private(set) var isRetired = false
    private let backend: ArtifactCacheBackend
    private let lease = UUID()
    private let acquisition: Task<Void, Error>
    fileprivate init(backend: ArtifactCacheBackend, scope: ArtifactCacheScope, barrier: Task<Void, Error>?) {
        self.backend = backend
        let lease = lease
        acquisition = Task {
            try await barrier?.value
            try await backend.acquire(lease, scope: scope)
        }
    }
    deinit {
        let backend = backend, lease = lease, acquisition = acquisition
        Task { _ = try? await acquisition.value; await backend.revoke(lease) }
    }
    func retire() {
        guard !isRetired else { return }
        isRetired = true
        let backend = backend, lease = lease, acquisition = acquisition
        Task { _ = try? await acquisition.value; await backend.revoke(lease) }
    }
    private func ready() async throws {
        guard !isRetired else { throw ArtifactCacheError.retired }
        try await acquisition.value
        try Task.checkCancellation()
        guard !isRetired else { throw ArtifactCacheError.retired }
    }
    private func accepted<T>(_ value: T) throws -> T {
        guard !isRetired else { throw ArtifactCacheError.retired }
        return value
    }
    func loadChats() async throws -> [CachedArtifactChat] {
        try await ready()
        return try accepted(try await backend.loadChats(lease))
    }
    func upsert(_ record: CachedArtifactChat) async throws {
        try await ready()
        try await backend.upsert(record, lease: lease)
        try accepted(())
    }
    func deleteChat(profile: ExactID, root: ExactID) async throws {
        try await ready()
        try await backend.deleteChat(profile: profile, root: root, lease: lease)
        try accepted(())
    }
    func original(for key: ArtifactOriginalKey) async throws -> CachedArtifactOriginal? {
        try await ready()
        return try accepted(try await backend.original(for: key, lease: lease))
    }
    @discardableResult func retainOriginal(_ artifact: DownloadedArtifact, for key: ArtifactOriginalKey) async throws -> Data? {
        try await ready()
        return try accepted(try await backend.retainOriginal(artifact, for: key, lease: lease))
    }
    func thumbnail(for key: ArtifactThumbnailKey) async throws -> Data? {
        try await ready()
        return try accepted(try await backend.thumbnail(for: key, lease: lease))
    }
    func retainThumbnail(_ data: Data, for key: ArtifactThumbnailKey) async throws {
        try await ready()
        try await backend.retainThumbnail(data, for: key, lease: lease)
        try accepted(())
    }
}
private enum ArtifactCacheError: Error { case unavailable, retired, unsupportedSchema, quota }

fileprivate actor ArtifactCacheBackend {
    private let root: URL
    private let ephemeral: Bool
    private let limits: ArtifactCache.Limits
    private var database: SQLiteConnection?
    private var closed = false
    private var leases: [UUID: ArtifactCacheScope] = [:]
    private var denied = Set<UUID>()
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(root: URL?, limits: ArtifactCache.Limits) {
        ephemeral = root == nil
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("BottoArtifactEphemeral-\(UUID().uuidString)")
        self.limits = limits
        encoder.outputFormat = .binary
    }
    deinit {
        database = nil
        if ephemeral { try? FileManager.default.removeItem(at: root) }
    }
    func close() {
        closed = true
        leases = [:]
        database = nil
    }
    func acquire(_ id: UUID, scope: ArtifactCacheScope) throws {
        guard !denied.contains(scope.configurationID) else { throw ArtifactCacheError.unavailable }
        try open()
        leases[id] = scope
    }
    func revoke(_ id: UUID) { leases[id] = nil }
    private func scope(_ id: UUID) throws -> ArtifactCacheScope {
        guard let scope = leases[id], !denied.contains(scope.configurationID) else { throw ArtifactCacheError.retired }
        return scope
    }
    private func open() throws {
        guard !closed else { throw ArtifactCacheError.unavailable }
        if database != nil { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let connection = try SQLiteConnection(path: root.appendingPathComponent("index.sqlite").path)
        let version = try connection.rows("PRAGMA user_version").first?.first?.integer ?? 0
        guard version == 0 || version == 1 else { throw ArtifactCacheError.unsupportedSchema }
        if version == 0 {
            // An unrecognized existing database is preserved, never reset.
            guard try connection.rows("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else { throw ArtifactCacheError.unsupportedSchema }
            try connection.execute("CREATE TABLE entries(scope BLOB NOT NULL, configuration BLOB NOT NULL, kind INTEGER NOT NULL, key BLOB NOT NULL, payload BLOB NOT NULL, blob TEXT, size INTEGER NOT NULL, accessed REAL NOT NULL, PRIMARY KEY(scope,kind,key)); PRAGMA user_version=1")
        }
        database = connection
        do { try cleanup() }
        catch { database = nil; throw error }
    }
    private func pack(_ fields: [Data]) -> Data {
        var result = Data()
        for field in fields {
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(field)
        }
        return result
    }
    private func namespace(_ scope: ArtifactCacheScope) -> Data {
        pack([Data(scope.configurationID.uuidString.utf8), scope.serverURL,
              scope.installationID.map { Data([1]) + $0 } ?? Data([0]), scope.username,
              scope.provider.map { Data([1]) + $0 } ?? Data([0])])
    }
    private func chatKey(_ profile: ExactID, _ root: ExactID) -> Data { pack([profile.bytes, root.bytes]) }
    private func originalKey(_ key: ArtifactOriginalKey) -> Data {
        pack([key.identity.profile.bytes, key.identity.root.bytes, key.identity.stored.bytes, key.messageID, key.path, key.sourceRevision])
    }
    private func thumbnailKey(_ key: ArtifactThumbnailKey) -> Data {
        pack([key.originalDigest, Data(String(key.maximumPixels).utf8), Data(String(key.decoderVersion).utf8)])
    }
    private func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private func filename(scope: ArtifactCacheScope, digest: Data, kind: Int) -> String {
        "\(kind)-" + hash(namespace(scope)).map { String(format: "%02x", $0) }.joined() + "-" + digest.map { String(format: "%02x", $0) }.joined()
    }
    private func row(scope: ArtifactCacheScope, kind: Int, key: Data) throws -> [SQLiteValue]? {
        guard let database else { throw ArtifactCacheError.unavailable }
        let bindings: [SQLiteValue] = [.data(namespace(scope)), .integer(kind), .data(key)]
        let row = try database.rows("SELECT payload,blob,size FROM entries WHERE scope=? AND kind=? AND key=?", bindings).first
        if row != nil { try database.execute("UPDATE entries SET accessed=? WHERE scope=? AND kind=? AND key=?", [.real(Date().timeIntervalSince1970)] + bindings) }
        return row
    }
    private func put(scope: ArtifactCacheScope, kind: Int, key: Data, payload: Data, blob: String? = nil, size: Int) throws {
        guard let database else { throw ArtifactCacheError.unavailable }
        try database.execute("INSERT OR REPLACE INTO entries VALUES(?,?,?,?,?,?,?,?)", [.data(namespace(scope)), .data(Data(scope.configurationID.uuidString.utf8)), .integer(kind), .data(key), .data(payload), blob.map(SQLiteValue.text) ?? .null, .integer(size), .real(Date().timeIntervalSince1970)])
        try enforceLimits()
    }
    func loadChats(_ lease: UUID) throws -> [CachedArtifactChat] {
        let scope = try scope(lease)
        guard let database else { throw ArtifactCacheError.unavailable }
        return try database.rows("SELECT payload FROM entries WHERE scope=? AND kind=0 ORDER BY accessed DESC", [.data(namespace(scope))]).compactMap { row in
            guard let data = row.first?.data, let record = try? decoder.decode(CachedArtifactChat.self, from: data) else { return nil }
            return record
        }
    }
    func upsert(_ record: CachedArtifactChat, lease: UUID) throws {
        let scope = try scope(lease)
        let payload = try encoder.encode(record)
        guard record.messages.count + (record.unavailableMessageIDs?.count ?? 0) <= limits.messageCount,
              record.messages.reduce(0, { $0 + $1.text.utf8.count }) + (record.unavailableMessageIDs?.reduce(0) { $0 + $1.count } ?? 0) <= limits.textBytes,
              payload.count <= limits.metadataBytes else { return }
        try put(scope: scope, kind: 0, key: chatKey(record.identity.profile, record.identity.root), payload: payload, size: payload.count)
    }
    func deleteChat(profile: ExactID, root: ExactID, lease: UUID) throws {
        let scope = try scope(lease)
        try database?.execute("DELETE FROM entries WHERE scope=? AND kind=0 AND key=?", [.data(namespace(scope)), .data(chatKey(profile, root))])
    }
    nonisolated private struct OriginalMetadata: Codable {
        let filename: String
        let mimeType: String
        let digest: Data
    }
    func original(for key: ArtifactOriginalKey, lease: UUID) throws -> CachedArtifactOriginal? {
        let scope = try scope(lease)
        guard let row = try row(scope: scope, kind: 1, key: originalKey(key)), let payload = row[0].data,
              let metadata = try? decoder.decode(OriginalMetadata.self, from: payload), let name = row[1].text,
              let data = readBlob(name, maximumBytes: limits.singleOriginalBytes), hash(data) == metadata.digest else { return nil }
        return CachedArtifactOriginal(artifact: DownloadedArtifact(data: data, filename: metadata.filename, mimeType: metadata.mimeType), digest: metadata.digest)
    }
    func retainOriginal(_ artifact: DownloadedArtifact, for key: ArtifactOriginalKey, lease: UUID) throws -> Data? {
        let scope = try scope(lease)
        guard artifact.data.count <= limits.singleOriginalBytes, artifact.data.count <= limits.originalBytes else { return nil }
        defer { try? cleanup() }
        let digest = hash(artifact.data), name = filename(scope: scope, digest: digest, kind: 1)
        try writeBlob(artifact.data, name: name)
        let payload = try encoder.encode(OriginalMetadata(filename: artifact.filename, mimeType: artifact.mimeType, digest: digest))
        try put(scope: scope, kind: 1, key: originalKey(key), payload: payload, blob: name, size: artifact.data.count)
        return digest
    }
    func thumbnail(for key: ArtifactThumbnailKey, lease: UUID) throws -> Data? {
        let scope = try scope(lease)
        guard let row = try row(scope: scope, kind: 2, key: thumbnailKey(key)), let name = row[1].text,
              let expected = row[0].data, let data = readBlob(name, maximumBytes: limits.thumbnailBytes), hash(data) == expected else { return nil }
        return data
    }
    func retainThumbnail(_ data: Data, for key: ArtifactThumbnailKey, lease: UUID) throws {
        let scope = try scope(lease)
        guard key.maximumPixels > 0, data.count <= limits.thumbnailBytes else { return }
        defer { try? cleanup() }
        let digest = hash(data), name = filename(scope: scope, digest: digest, kind: 2)
        try writeBlob(data, name: name)
        try put(scope: scope, kind: 2, key: thumbnailKey(key), payload: digest, blob: name, size: data.count)
    }
    private func readBlob(_ name: String, maximumBytes: Int) -> Data? {
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let url = root.appendingPathComponent(name)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else { return nil }
        return try? Data(contentsOf: url)
    }
    private func writeBlob(_ data: Data, name: String) throws {
        let url = root.appendingPathComponent(name)
        // Atomic replacement completes before the transactional mapping becomes visible.
        try data.write(to: url, options: .atomic)
    }
    func discard(_ configurationID: UUID) throws {
        denied.insert(configurationID)
        leases = leases.filter { $0.value.configurationID != configurationID }
        try open()
        try database?.execute("DELETE FROM entries WHERE configuration=?", [.data(Data(configurationID.uuidString.utf8))])
        try cleanup()
        try database?.execute("VACUUM")
        denied.remove(configurationID)
    }
    func prune(_ reachable: Set<UUID>) throws {
        try open()
        let ids = try database?.rows("SELECT DISTINCT configuration FROM entries") ?? []
        for row in ids {
            if let data = row[0].data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)), !reachable.contains(id) { try discard(id) }
        }
    }
    private func cleanup() throws {
        guard let database else { return }
        let names = Set(try database.rows("SELECT DISTINCT blob FROM entries WHERE blob IS NOT NULL").compactMap { $0[0].text })
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            if name == "index.sqlite" || name == "index.sqlite-journal" || name == "index.sqlite-wal" || name == "index.sqlite-shm" { continue }
            if !names.contains(name) { try FileManager.default.removeItem(at: url) }
        }
    }
    private func databaseBytes() throws -> Int {
        try ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "index.sqlite-journal"].reduce(0) { total, name in
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return total }
            return total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }
    private func enforceLimits() throws {
        guard let database else { return }
        var removed = false
        for (kind, budget) in [(0, limits.metadataBytes), (1, limits.originalBytes), (2, limits.thumbnailBytes)] {
            while true {
                let sizes = try database.rows(kind == 0 ? "SELECT COALESCE(SUM(length(payload)),0),COUNT(*) FROM entries WHERE kind=0" : "SELECT COALESCE(SUM(size),0),COUNT(*) FROM (SELECT blob,MAX(size) AS size FROM entries WHERE kind=\(kind) GROUP BY blob)")
                let size = sizes.first?[0].integer ?? 0, count = sizes.first?[1].integer ?? 0
                if size <= max(0, budget) && (kind != 0 || count <= max(0, limits.chatCount)) { break }
                try database.execute("DELETE FROM entries WHERE rowid=(SELECT rowid FROM entries WHERE kind=? ORDER BY accessed ASC LIMIT 1)", [.integer(kind)])
                removed = true
            }
        }
        // Include mapping keys, scope bytes and response metadata in admission.
        while (try database.rows("SELECT COALESCE(SUM(length(payload)+length(key)+length(scope)+length(configuration)+128),0) FROM entries").first?[0].integer ?? 0) > max(0, limits.metadataBytes) {
            try database.execute("DELETE FROM entries WHERE rowid=(SELECT rowid FROM entries ORDER BY accessed ASC LIMIT 1)")
            removed = true
        }
        var messages = 0, textBytes = 0
        for row in try database.rows("SELECT rowid,payload FROM entries WHERE kind=0 ORDER BY accessed DESC") {
            guard let payload = row[1].data, let record = try? decoder.decode(CachedArtifactChat.self, from: payload) else { continue }
            messages += record.messages.count + (record.unavailableMessageIDs?.count ?? 0)
            textBytes += record.messages.reduce(0) { $0 + $1.text.utf8.count } + (record.unavailableMessageIDs?.reduce(0) { $0 + $1.count } ?? 0)
            if messages > limits.messageCount || textBytes > limits.textBytes, let id = row[0].integer {
                try database.execute("DELETE FROM entries WHERE rowid=?", [.integer(id)])
                removed = true
            }
        }
        try cleanup()
        if removed { try database.execute("VACUUM") }
        // SQLite pages and indexes also consume the metadata allowance. Small
        // injected budgets retain the minimum schema pages (64 KiB).
        let physicalBudget = max(64 * 1024, limits.metadataBytes)
        while try databaseBytes() > physicalBudget {
            guard !(try database.rows("SELECT rowid FROM entries LIMIT 1")).isEmpty else { break }
            try database.execute("DELETE FROM entries WHERE rowid=(SELECT rowid FROM entries ORDER BY accessed ASC LIMIT 1)")
            try cleanup()
            try database.execute("VACUUM")
        }
    }
}

nonisolated private enum SQLiteValue {
    case data(Data), text(String), integer(Int), real(Double), null
    var data: Data? { if case .data(let value) = self { value } else { nil } }
    var text: String? { if case .text(let value) = self { value } else { nil } }
    var integer: Int? { if case .integer(let value) = self { value } else { nil } }
}
/// The actor exclusively owns the connection; this wrapper closes it at teardown.
nonisolated private final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer
    init(path: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw ArtifactCacheError.unavailable
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 1_000)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        if bindings.isEmpty {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw ArtifactCacheError.unavailable }
        } else { _ = try rows(sql, bindings) }
    }
    func rows(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ArtifactCacheError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case .data(let data): result = data.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : data.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient) }
            case .text(let text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .integer(let value): result = sqlite3_bind_int64(statement, index, Int64(value))
            case .real(let value): result = sqlite3_bind_double(statement, index, value)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw ArtifactCacheError.unavailable }
        }
        var output: [[SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw ArtifactCacheError.unavailable }
            var row: [SQLiteValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    row.append(.data(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, index)!, count: count)))
                case SQLITE_INTEGER: row.append(.integer(Int(sqlite3_column_int64(statement, index))))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, index))))
                default: row.append(.null)
                }
            }
            output.append(row)
        }
    }
}
