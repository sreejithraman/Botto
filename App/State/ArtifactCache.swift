import Foundation
import BottoCore
import SQLite3
import CryptoKit

nonisolated private func artifactCacheFields(_ fields: [Data]) -> Data {
    var result = Data()
    for field in fields {
        var length = UInt64(field.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(field)
    }
    return result
}

/// The consumers still waiting on one original read. Its bytes are published only while one remains.
nonisolated final class ArtifactCaptureAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var consumers = Set<UUID>()
    func register(_ id: UUID) { lock.withLock { _ = consumers.insert(id) } }
    func revoke(_ id: UUID) { lock.withLock { _ = consumers.remove(id) } }
    func revokeAll() { lock.withLock { consumers.removeAll() } }
    func claimPublication() throws {
        try lock.withLock { guard !consumers.isEmpty else { throw CancellationError() } }
    }
}

nonisolated fileprivate final class ArtifactCacheLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func retire() { lock.withLock { active = false } }
}

nonisolated struct ArtifactCacheScope: Hashable, Codable, Sendable {
    let configurationID: UUID
    let serverURL: Data
    let installationID: Data?
    let username: Data
    let provider: Data?
    var backend: [Data?]? = nil

    // Existing rows and blobs are addressed by these exact bytes.
    fileprivate var namespace: Data {
        let fields = [Data(configurationID.uuidString.utf8), serverURL,
            installationID.map { Data([1]) + $0 } ?? Data([0]), username,
            provider.map { Data([1]) + $0 } ?? Data([0])]
        // A nil backend is the older cache namespace.
        return artifactCacheFields(fields + (backend ?? []).map { $0.map { Data([1]) + $0 } ?? Data([0]) })
    }
}
nonisolated struct ArtifactOriginalKey: Hashable, Codable, Sendable {
    let identity: SessionIdentity
    let messageID: Data
    let path: Data
    let sourceRevision: Data

    // Alias discovery does not create a new captured occurrence.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.persistenceKey == rhs.persistenceKey
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(persistenceKey)
    }
    var persistenceKey: Data {
        artifactCacheFields([identity.profile.bytes, identity.root.bytes, identity.stored.bytes, messageID, path, sourceRevision])
    }
}
nonisolated struct CachedArtifactOriginal: Sendable {
    let artifact: DownloadedArtifact
    let digest: Data
}

@MainActor fileprivate final class ArtifactCacheMaintenance {
    private let operation: @MainActor () async throws -> Void
    /// A failed purge of a forgotten setup stays failed, so its namespace stays fenced until an explicit discard.
    private let retryable: Bool
    private var attempt = UUID()
    private var task: Task<Void, Error>
    init(retryable: Bool, operation: @escaping @MainActor () async throws -> Void) {
        self.operation = operation; self.retryable = retryable
        task = Task { try await operation() }
    }
    func wait() async throws { try await task.value }
    /// Waits for the latest attempt and, if it failed, starts one more; concurrent callers share that attempt.
    func retry() async throws {
        guard retryable else { return try await wait() }
        let previous = attempt
        do { try await task.value; return } catch {}
        if attempt == previous {
            attempt = UUID()
            task = Task { try await operation() }
        }
        try await task.value
    }
}

@MainActor final class ArtifactCache {
    struct Limits: Sendable {
        var originalBytes = 256 * 1024 * 1024
        var singleOriginalBytes = 25 * 1024 * 1024
        var indexBytes = 40 * 1024 * 1024
    }
    static let shared = ArtifactCache(root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BottoArtifacts", isDirectory: true))
    private let backend: ArtifactCacheBackend
    private var maintenance: ArtifactCacheMaintenance?
    private struct WeakSession { weak var value: ArtifactCacheSession?; let configurationID: UUID }
    private var sessions: [WeakSession] = []
    init(root: URL?, limits: Limits = .init(), beforeCaptureCommit: (@Sendable () -> Void)? = nil) {
        let resolvedRoot = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("BottoArtifactEphemeral-\(UUID().uuidString)")
        backend = ArtifactCacheBackend(root: resolvedRoot, ephemeral: root == nil, limits: limits, beforeCaptureCommit: beforeCaptureCommit)
    }
    func session(scope: ArtifactCacheScope) -> ArtifactCacheSession {
        let session = ArtifactCacheSession(backend: backend, scope: scope, barrier: maintenance)
        sessions.removeAll { $0.value == nil }
        sessions.append(WeakSession(value: session, configurationID: scope.configurationID))
        return session
    }
    func discard(configurationID: UUID) {
        for item in sessions where item.configurationID == configurationID { item.value?.retire() }
        let previous = maintenance, backend = backend
        maintenance = ArtifactCacheMaintenance(retryable: false) {
            _ = try? await previous?.wait()
            try await backend.discard(configurationID)
        }
    }
    func prune(reachableConfigurationIDs: Set<UUID>) {
        for item in sessions where !reachableConfigurationIDs.contains(item.configurationID) { item.value?.retire() }
        let previous = maintenance, backend = backend
        // Startup pruning also opens and upgrades the database. A new session retries it once if it failed.
        maintenance = ArtifactCacheMaintenance(retryable: true) {
            _ = try? await previous?.wait()
            try await backend.prune(reachableConfigurationIDs)
        }
    }
    func drainMaintenance() async throws { try await maintenance?.wait() }
    func close() async {
        for item in sessions { item.value?.retire() }
        _ = try? await maintenance?.wait()
        await backend.close()
    }
}
@MainActor final class ArtifactCacheSession {
    private(set) var isRetired = false
    private let backend: ArtifactCacheBackend
    private let lease = UUID()
    private let leaseState = ArtifactCacheLeaseState()
    private let acquisition: Task<Void, Error>
    fileprivate init(backend: ArtifactCacheBackend, scope: ArtifactCacheScope, barrier: ArtifactCacheMaintenance?) {
        self.backend = backend
        let lease = lease, state = leaseState
        acquisition = Task {
            try await barrier?.retry()
            try await backend.acquire(lease, scope: scope, state: state)
        }
    }
    deinit {
        leaseState.retire()
        let backend = backend, lease = lease, acquisition = acquisition
        Task { _ = try? await acquisition.value; await backend.revoke(lease) }
    }
    func retire() {
        guard !isRetired else { return }
        isRetired = true
        leaseState.retire()
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
    func original(for key: ArtifactOriginalKey) async throws -> CachedArtifactOriginal? {
        try await ready()
        return try accepted(try await backend.original(for: key, lease: lease))
    }
    func originalDigest(for key: ArtifactOriginalKey) async throws -> Data? {
        try await ready()
        return try accepted(try await backend.originalDigest(for: key, lease: lease))
    }
    @discardableResult func retainOriginal(_ artifact: DownloadedArtifact, for key: ArtifactOriginalKey,
                                         admission: ArtifactCaptureAdmission? = nil) async throws -> Data? {
        try admission?.claimPublication()
        try await ready()
        return try accepted(try await backend.retainOriginal(artifact, for: key, lease: lease, admission: admission))
    }
}
enum ArtifactCacheError: Error { case unavailable, retired, unsupportedSchema, quota }

fileprivate actor ArtifactCacheBackend {
    private let root: URL
    private let ephemeral: Bool
    private let limits: ArtifactCache.Limits
    private var database: SQLiteConnection?
    private var closed = false
    private var leases: [UUID: (scope: ArtifactCacheScope, state: ArtifactCacheLeaseState)] = [:]
    private let beforeCaptureCommit: (@Sendable () -> Void)?
    private var denied = Set<UUID>()
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(root: URL, ephemeral: Bool, limits: ArtifactCache.Limits, beforeCaptureCommit: (@Sendable () -> Void)?) {
        self.ephemeral = ephemeral; self.root = root; self.limits = limits
        self.beforeCaptureCommit = beforeCaptureCommit
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
    func acquire(_ id: UUID, scope: ArtifactCacheScope, state: ArtifactCacheLeaseState) throws {
        guard state.isActive else { throw ArtifactCacheError.retired }
        guard !denied.contains(scope.configurationID) else { throw ArtifactCacheError.unavailable }
        try open()
        leases[id] = (scope, state)
    }
    func revoke(_ id: UUID) { leases[id] = nil }
    private func scope(_ id: UUID) throws -> ArtifactCacheScope {
        guard let value = leases[id], value.state.isActive, !denied.contains(value.scope.configurationID) else { throw ArtifactCacheError.retired }
        return value.scope
    }
    private func open() throws {
        guard !closed else { throw ArtifactCacheError.unavailable }
        if database != nil { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let connection = try SQLiteConnection(path: root.appendingPathComponent("index.sqlite").path)
        // Deleted rows are overwritten in place, so removed content does not linger in free pages.
        try connection.execute("PRAGMA secure_delete=ON")
        let version = try connection.rows("PRAGMA user_version").first?.first?.integer ?? 0
        switch version {
        case 0:
            // An unrecognized existing database is preserved, never reset.
            guard try connection.rows("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else { throw ArtifactCacheError.unsupportedSchema }
            try connection.transaction {
                try connection.execute("CREATE TABLE entries(scope BLOB NOT NULL, configuration BLOB NOT NULL, kind INTEGER NOT NULL, key BLOB NOT NULL, payload BLOB NOT NULL, blob TEXT, size INTEGER NOT NULL, accessed REAL NOT NULL, PRIMARY KEY(scope,kind,key))")
                try connection.execute("PRAGMA user_version=2")
            }
        case 1:
            // Version 1 also held the retired Library index: chat copies with
            // message text (kind 0) and gallery thumbnails (kind 2). Remove both
            // once; the version bump commits with the deletion. Their blob files
            // and the old metadata-recovery.plist are swept by cleanup below.
            try connection.transaction {
                try connection.execute("DELETE FROM entries WHERE kind IN (0,2)")
                try connection.execute("PRAGMA user_version=2")
            }
            try? connection.execute("VACUUM")
        case 2: break
        default: throw ArtifactCacheError.unsupportedSchema
        }
        database = connection
        do { try cleanup() }
        catch { database = nil; throw error }
    }
    private func originalKey(_ key: ArtifactOriginalKey) -> Data {
        key.persistenceKey
    }
    private func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private func filename(scope: ArtifactCacheScope, digest: Data, kind: Int) -> String {
        "\(kind)-" + hash(scope.namespace).map { String(format: "%02x", $0) }.joined() + "-" + digest.map { String(format: "%02x", $0) }.joined()
    }
    private func row(scope: ArtifactCacheScope, kind: Int, key: Data) throws -> [SQLiteValue]? {
        guard let database else { throw ArtifactCacheError.unavailable }
        let bindings: [SQLiteValue] = [.data(scope.namespace), .integer(kind), .data(key)]
        let row = try database.rows("SELECT payload,blob,size FROM entries WHERE scope=? AND kind=? AND key=?", bindings).first
        if row != nil { try database.execute("UPDATE entries SET accessed=? WHERE scope=? AND kind=? AND key=?", [.real(Date().timeIntervalSince1970)] + bindings) }
        return row
    }
    private func insert(scope: ArtifactCacheScope, kind: Int, key: Data, payload: Data, blob: String? = nil, size: Int) throws {
        guard let database else { throw ArtifactCacheError.unavailable }
        try database.execute("INSERT OR REPLACE INTO entries VALUES(?,?,?,?,?,?,?,?)", [.data(scope.namespace), .data(Data(scope.configurationID.uuidString.utf8)), .integer(kind), .data(key), .data(payload), blob.map(SQLiteValue.text) ?? .null, .integer(size), .real(Date().timeIntervalSince1970)])
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
    func originalDigest(for key: ArtifactOriginalKey, lease: UUID) throws -> Data? {
        let scope = try scope(lease)
        return try row(scope: scope, kind: 3, key: originalKey(key))?.first?.data
    }
    func retainOriginal(_ artifact: DownloadedArtifact, for key: ArtifactOriginalKey, lease: UUID,
                        admission: ArtifactCaptureAdmission? = nil) throws -> Data? {
        let scope = try scope(lease)
        guard let database else { throw ArtifactCacheError.unavailable }
        defer { try? cleanup() }
        let digest = hash(artifact.data)
        guard artifact.data.count <= limits.singleOriginalBytes, artifact.data.count <= limits.originalBytes else { return nil }
        let name = filename(scope: scope, digest: digest, kind: 1)
        let payload = try encoder.encode(OriginalMetadata(filename: artifact.filename, mimeType: artifact.mimeType, digest: digest))
        // Digest-named, so a replacement with other bytes never overwrites the file its previous row names.
        // Files no committed row names are swept on return (the defer above), whichever way the transaction ends.
        try writeBlob(artifact.data, name: name)
        let target = (scope: scope, key: originalKey(key))
        // Every eviction happens inside this transaction, so a refused, revoked or retired capture deletes nothing.
        try database.transaction {
            try insert(scope: scope, kind: 1, key: target.key, payload: payload, blob: name, size: artifact.data.count)
            try insert(scope: scope, kind: 3, key: target.key, payload: digest, size: digest.count)
            try enforceLimits(keeping: target)
            beforeCaptureCommit?()
            try Task.checkCancellation()
            // Claim publication immediately before COMMIT; later presentation
            // retirement cannot undo bytes admitted while a consumer was valid.
            try admission?.claimPublication()
            _ = try self.scope(lease)
        }
        try? compactFreePages()
        return digest
    }
    /// Evicted rows leave free pages behind. Give them back once they would hold the file over its budget,
    /// or make up a quarter of it. This only compacts; it never removes a row.
    private func compactFreePages() throws {
        guard let database else { return }
        let pages = try integer("PRAGMA page_count"), free = try integer("PRAGMA freelist_count"), pageBytes = try integer("PRAGMA page_size")
        guard free > 0, pages * pageBytes > physicalBudget || free * 4 >= pages else { return }
        try database.execute("VACUUM")
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
        leases = leases.filter { $0.value.scope.configurationID != configurationID }
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
    /// Removes every file in the cache folder that no row references, including
    /// blobs whose rows were deleted before an interruption.
    private func cleanup() throws {
        guard let database else { return }
        let names = Set(try database.rows("SELECT DISTINCT blob FROM entries WHERE blob IS NOT NULL").compactMap { $0[0].text })
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            if name == "index.sqlite" || name == "index.sqlite-journal" || name == "index.sqlite-wal" || name == "index.sqlite-shm" { continue }
            if !names.contains(name) { try FileManager.default.removeItem(at: url) }
        }
    }
    private func rowBytes() throws -> Int {
        // Include mapping keys, scope bytes and response metadata in admission.
        try database?.rows("SELECT COALESCE(SUM(length(payload)+length(key)+length(scope)+length(configuration)+128),0) FROM entries").first?[0].integer ?? 0
    }
    private func integer(_ pragma: String) throws -> Int {
        guard let database else { throw ArtifactCacheError.unavailable }
        return try database.rows(pragma).first?.first?.integer ?? 0
    }
    /// SQLite pages and indexes also consume the index allowance. Small
    /// injected budgets retain the minimum schema pages (64 KiB).
    private var physicalBudget: Int { max(64 * 1024, limits.indexBytes) }
    /// Deleted rows return whole pages to the freelist, so evictions in an open transaction lower this.
    private func pageBytesInUse() throws -> Int {
        try (integer("PRAGMA page_count") - integer("PRAGMA freelist_count")) * integer("PRAGMA page_size")
    }
    /// Deletes the least recently used row other than the capture being written; `.quota` when none is left.
    private func evictOldest(kind: Int? = nil, keeping target: (scope: ArtifactCacheScope, key: Data)) throws {
        guard let database else { throw ArtifactCacheError.unavailable }
        let rows = try database.rows("SELECT rowid FROM entries WHERE NOT (scope=? AND key=?)" +
            (kind == nil ? "" : " AND kind=?") + " ORDER BY accessed ASC LIMIT 1",
            [.data(target.scope.namespace), .data(target.key)] + (kind.map { [.integer($0)] } ?? []))
        guard let id = rows.first?.first?.integer else { throw ArtifactCacheError.quota }
        try database.execute("DELETE FROM entries WHERE rowid=?", [.integer(id)])
    }
    /// Runs inside the capture's transaction, after its rows are inserted.
    private func enforceLimits(keeping target: (scope: ArtifactCacheScope, key: Data)) throws {
        guard let database else { return }
        while (try database.rows("SELECT COALESCE(SUM(size),0) FROM (SELECT blob,MAX(size) AS size FROM entries WHERE kind=1 GROUP BY blob)").first?[0].integer ?? 0) > max(0, limits.originalBytes) {
            try evictOldest(kind: 1, keeping: target)
        }
        while try rowBytes() > max(0, limits.indexBytes) { try evictOldest(keeping: target) }
        while try pageBytesInUse() > physicalBudget { try evictOldest(keeping: target) }
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
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch {
            // An uncertain rollback leaves the transaction to SQLite's own recovery.
            try? execute("ROLLBACK")
            throw error
        }
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
