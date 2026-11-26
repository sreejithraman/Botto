import Foundation
import CryptoKit
import BottoCore

private enum ArtifactCaptureFailure: Error, LocalizedError {
    case notRetained
    var errorDescription: String? { "The refreshed file couldn’t be saved on this device. Try again." }
}

private final class OriginalReadCancellation: @unchecked Sendable {
    // A response can reach the actor before its queued cancellation cleanup.
    private let lock = NSLock()
    private var cancelled = false
    private let onCancel: @Sendable () -> Void
    init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
    func cancel() { lock.withLock { cancelled = true }; onCancel() }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

/// Original bytes behind chat file cards, captured for offline reopening within one mounted workspace.
@MainActor final class ArtifactCaptures {
    private struct OriginalConsumer {
        let validate: @MainActor () throws -> Void
        let download: @MainActor () async throws -> DownloadedArtifact

        @MainActor func isCurrent() -> Bool {
            do { try validate(); return true } catch { return false }
        }
    }
    private struct OriginalFlight {
        let id: UUID
        let task: Task<DownloadedArtifact, Error>
        let admission: ArtifactCaptureAdmission
        var consumers: [UUID: OriginalConsumer]
    }
    private var flights: [ArtifactOriginalKey: OriginalFlight] = [:]
    private var originals: [ArtifactOriginalKey: DownloadedArtifact] = [:]
    private let cache: ArtifactCacheSession
    private(set) var isRetired = false
    private var online = false
    private var generation = UUID()

    init(cache: ArtifactCacheSession? = nil) {
        self.cache = cache ?? ArtifactCache(root: nil).session(scope: .init(configurationID: UUID(),
            serverURL: Data(), installationID: nil, username: Data(), provider: nil))
    }

    func setOnline(_ value: Bool) {
        guard !isRetired, online != value else { return }
        online = value
        if !value { cancelOperations() }
    }
    func retire() {
        guard !isRetired else { return }
        isRetired = true; online = false
        cache.retire(); originals = [:]
        cancelOperations()
    }
    private func cancelOperations() {
        generation = UUID()
        for flight in flights.values { flight.admission.revokeAll(); flight.task.cancel() }; flights = [:]
    }
    private func accepts(_ owner: UUID) -> Bool { !isRetired && online && generation == owner && !Task.isCancelled }

    /// Hashes the retained unprojected row representation; it cannot reconstruct upstream content shapes.
    /// Without separate canonical text, hash the encoded row.
    private nonisolated static func sourceRevision(_ message: ChatMessage) -> Data {
        var producer = message
        producer.text = message.canonicalText ?? message.text
        producer.canonicalText = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: (try? encoder.encode([producer])) ?? Data()))
    }

    static func originalKey(identity: SessionIdentity, attachment: ChatAttachment, messages: [ChatMessage],
                            producingMessage: ChatMessage? = nil) async -> ArtifactOriginalKey? {
        let matches = await Task.detached(priority: .utility) {
            (producingMessage.map { [$0] } ?? messages).filter { message in
                ArtifactDiscovery.artifacts(in: [message]).contains {
                    $0.attachment.map { Data($0.path.utf8) == Data(attachment.path.utf8) } == true
                }
            }
        }.value
        guard matches.count == 1, let message = matches.first else { return nil }
        guard message.hasStableIdentity(storedID: identity.stored.text) else { return nil }
        return ArtifactOriginalKey(identity: identity, messageID: Data(message.id.utf8), path: Data(attachment.path.utf8),
            sourceRevision: await Task.detached(priority: .utility) { sourceRevision(message) }.value)
    }

    func original(for key: ArtifactOriginalKey, force: Bool = false,
                  validateNetwork: @escaping @MainActor () throws -> Void = {},
                  download: @escaping @MainActor () async throws -> DownloadedArtifact) async throws -> DownloadedArtifact {
        try Task.checkCancellation()
        guard ChatMessage.isStableID(key.messageID, storedID: key.identity.stored.text) else { throw ConversationServiceError.staleConversation }
        guard !isRetired else { throw ConversationServiceError.staleConversation }
        if !force {
            if let value = originals[key] { return value }
            if let value = try? await cache.original(for: key) {
                try Task.checkCancellation()
                guard !isRetired else { throw ConversationServiceError.staleConversation }
                originals = [key: value.artifact]
                return value.artifact
            }
        }
        guard online else { throw ConversationServiceError.disconnected }
        try validateNetwork()
        let owner = generation
        if force {
            while let previous = flights[key] {
                _ = try? await previous.task.value
                try Task.checkCancellation()
                guard accepts(owner) else { throw ConversationServiceError.staleConversation }
                try validateNetwork()
            }
        }
        let waiter = UUID(), flightID: UUID
        let admission = flights[key]?.admission ?? ArtifactCaptureAdmission()
        admission.register(waiter)
        let cancellation = OriginalReadCancellation(onCancel: { admission.revoke(waiter) })
        let validateWaiter: @MainActor () throws -> Void = {
            try cancellation.check()
            try validateNetwork()
        }
        let consumer = OriginalConsumer(validate: validateWaiter, download: download)
        let task: Task<DownloadedArtifact, Error>
        if var existing = flights[key] {
            flightID = existing.id; task = existing.task
            existing.consumers[waiter] = consumer
            flights[key] = existing
        } else {
            flightID = UUID()
            task = Task { [weak self] in
                defer {
                    admission.revokeAll()
                    if let self, flights[key]?.id == flightID { flights[key] = nil }
                }
                var loader = (id: waiter, consumer: consumer), attempted = Set<UUID>()
                while true {
                    try Task.checkCancellation()
                    attempted.insert(loader.id)
                    let result: DownloadedArtifact
                    do { result = try await loader.consumer.download() }
                    catch {
                        guard let self, accepts(owner), let flight = flights[key], flight.id == flightID,
                              !loader.consumer.isCurrent(),
                              let next = flight.consumers.first(where: { !attempted.contains($0.key) && $0.value.isCurrent() }) else {
                            throw error
                        }
                        loader = (id: next.key, consumer: next.value)
                        continue
                    }
                    guard let self, accepts(owner), let flight = flights[key], flight.id == flightID,
                          flight.consumers.values.contains(where: { $0.isCurrent() }) else { throw ConversationServiceError.staleConversation }
                    do {
                        let retained = try await cache.retainOriginal(result, for: key, admission: admission)
                        if force, retained == nil { throw ArtifactCaptureFailure.notRetained }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // An unsaved ordinary capture still serves the bytes that were read.
                        if force { throw ArtifactCaptureFailure.notRetained }
                    }
                    try await admission.waitUntilReady()
                    guard accepts(owner), let current = flights[key], current.id == flightID,
                          current.consumers.values.contains(where: { $0.isCurrent() }) else { throw ConversationServiceError.staleConversation }
                    originals = [key: result]
                    return result
                }
            }
            flights[key] = OriginalFlight(id: flightID, task: task, admission: admission, consumers: [waiter: consumer])
        }
        return try await withTaskCancellationHandler {
            defer { releaseOriginalWaiter(waiter, key: key, flightID: flightID) }
            let result = try await task.value
            try Task.checkCancellation()
            guard accepts(owner) else { throw ConversationServiceError.staleConversation }
            try validateWaiter()
            return result
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.releaseOriginalWaiter(waiter, key: key, flightID: flightID) }
        }
    }

    private func releaseOriginalWaiter(_ waiter: UUID, key: ArtifactOriginalKey, flightID: UUID) {
        guard var flight = flights[key], flight.id == flightID else { return }
        flight.admission.revoke(waiter)
        flight.consumers[waiter] = nil
        if flight.consumers.isEmpty {
            flights[key] = nil
            flight.task.cancel()
        } else { flights[key] = flight }
    }

    func reconcileOriginalConsumers() {
        var retired: [ArtifactOriginalKey] = []
        for (key, flight) in flights {
            var valid = false
            for (id, consumer) in flight.consumers {
                if consumer.isCurrent() { valid = true } else { flight.admission.revoke(id) }
            }
            if !valid { retired.append(key) }
        }
        for key in retired {
            guard let flight = flights.removeValue(forKey: key) else { continue }
            flight.admission.revokeAll(); flight.task.cancel()
        }
    }
}
