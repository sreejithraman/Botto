import Foundation

/// Admission identity survives process death, without storing prompt text or credentials.
/// This is an audit of uncertain sends, never an outbox and never an automatic resend.
@MainActor final class HermesSubmissionJournal {
    private struct Entry: Codable {
        var submission: String
        var connection: UUID
        var profile: String
        var stored: String
        var admission: String?
        var created: Date
    }
    private let directory: URL?
    private var entries: [Entry] = []
    init(directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Botto/AdmissionIdentities", isDirectory: true)) {
        self.directory = directory
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("identities.json")),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
    }
    func record(_ submission: String, connection: UUID, profile: String, stored: String) throws {
        entries.append(Entry(submission: submission, connection: connection, profile: profile, stored: stored, created: Date()))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        try save()
    }
    func acknowledge(_ submission: String, admission: String) throws {
        guard let index = entries.firstIndex(where: { $0.submission == submission }) else { return }
        entries[index].admission = admission
        // The caller already has a positive host ACK and reports local repair separately.
        try save()
    }
    private func save() throws {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent("identities.json")
            try JSONEncoder().encode(entries).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch { throw HermesServiceError.submissionStorage }
    }
}
