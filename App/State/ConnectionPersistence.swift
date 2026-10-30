import BottoCore

/// The app's secure-storage boundary; tests use an isolated in-memory implementation.
@MainActor struct ConnectionPersistence {
    var load: () throws -> ConnectionConfiguration?
    var save: (ConnectionConfiguration) throws -> Void
    var remove: () throws -> Void

    static let keychain = Self(load: ConnectionVault.load, save: ConnectionVault.save, remove: ConnectionVault.remove)
}
