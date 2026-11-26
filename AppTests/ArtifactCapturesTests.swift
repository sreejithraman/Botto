import CryptoKit
import Foundation
import Testing
import BottoCore
@testable import Botto

/// Chat file cards keep their original bytes for offline reopening, keyed by the exact producing row.
@MainActor struct ArtifactCapturesTests {
    nonisolated private static let downloadedBytes = Data("original bytes".utf8)
    nonisolated private static func source(_ root: String) -> SessionIdentity {
        .init(profile: try! ExactID("helper"), root: try! ExactID(root), stored: try! ExactID(root), aliases: [try! ExactID(root)])
    }
    private static func scope() -> ArtifactCacheScope {
        .init(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
    }
    private static func attachment(in message: ChatMessage) throws -> ChatAttachment {
        try #require(ArtifactDiscovery.artifacts(in: [message]).first?.attachment)
    }

    @Test(arguments: [false, true])
    func reloadWaitsForAnEarlierReadThenCapturesNewerBytes(aliasesChanged: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Self.source("main"), scope = Self.scope()
        let cache = ArtifactCache(root: root)
        let captures = ArtifactCaptures(cache: cache.session(scope: scope))
        defer { captures.retire() }
        captures.setOnline(true)
        let key = ArtifactOriginalKey(identity: source, messageID: Data("report".utf8),
            path: Data("/report.txt".utf8), sourceRevision: Data("revision".utf8))
        let aliasSource = SessionIdentity(profile: source.profile, root: source.root, stored: source.stored,
            aliases: aliasesChanged ? source.aliases.union([try ExactID("new-alias")]) : source.aliases)
        let reloadedKey = ArtifactOriginalKey(identity: aliasSource, messageID: key.messageID, path: key.path, sourceRevision: key.sourceRevision)
        let oldRead = StoreTestBarrier()
        var reloadStarted = false, events: [String] = []
        let first = Task {
            try await captures.original(for: key) {
                events.append("old read started")
                await oldRead.wait()
                events.append("old response received")
                return DownloadedArtifact(data: Data("older response".utf8), filename: "report.txt", mimeType: "text/plain")
            }
        }
        defer { first.cancel(); oldRead.release() }
        await oldRead.waitUntilEntered()
        let reload = Task {
            reloadStarted = true
            return try await captures.original(for: reloadedKey, force: true) {
                events.append("reload read started")
                return DownloadedArtifact(data: Data("newer response".utf8), filename: "report.txt", mimeType: "text/plain")
            }
        }
        defer { reload.cancel() }
        await waitWhile { !reloadStarted }
        oldRead.release()
        #expect(try await first.value.data == Data("older response".utf8))
        #expect(try await reload.value.data == Data("newer response".utf8))
        #expect(events == ["old read started", "old response received", "reload read started"])
        captures.setOnline(false)
        let retained = try await captures.original(for: key) { throw ConversationServiceError.disconnected }
        #expect(retained.data == Data("newer response".utf8))
        captures.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = ArtifactCaptures(cache: reopenedCache.session(scope: scope))
        #expect(try await reopened.original(for: key) { throw ConversationServiceError.disconnected }.data == Data("newer response".utf8))
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: [false, true])
    func cancelledOriginalReadCannotAdmitLateBytesButKeepsAValidPeer(validPeer: Bool) async throws {
        let service = CaptureTestService(), cache = ArtifactCache(root: nil)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        let captures = store.captures
        let key = ArtifactOriginalKey(identity: service.first, messageID: Data("row".utf8),
            path: Data("/late.txt".utf8), sourceRevision: Data("revision".utf8))
        let gate = StoreTestBarrier()
        var downloads = 0, transportCancelled = false
        let older = Task {
            try await captures.original(for: key, download: {
                downloads += 1
                await gate.wait()
                transportCancelled = Task.isCancelled
                return DownloadedArtifact(data: Data("late".utf8), filename: "late.txt", mimeType: "text/plain")
            })
        }
        await gate.waitUntilEntered()
        var joined = false
        let peer: Task<DownloadedArtifact, Error>? = validPeer ? Task {
            try await captures.original(for: key, validateNetwork: { joined = true }, download: {
                Issue.record("A valid peer must share the existing flight")
                throw ConversationServiceError.disconnected
            })
        } : nil
        if validPeer {
            await waitWhile { !joined }
            try #require(joined)
        }
        older.cancel()
        // Release immediately: cancellation admission must fence even a response
        // that races the MainActor's scheduled waiter cleanup.
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await older.value }
        if let peer { #expect(try await peer.value.data == Data("late".utf8)) }
        #expect(downloads == 1)
        let subsequent = try await captures.original(for: key, download: {
            downloads += 1
            return DownloadedArtifact(data: Data("fresh".utf8), filename: "late.txt", mimeType: "text/plain")
        })
        #expect(subsequent.data == Data((validPeer ? "late" : "fresh").utf8))
        #expect(downloads == (validPeer ? 1 : 2))
        if validPeer { #expect(!transportCancelled) }
    }

    @Test func anOfflineMissCanRetryUsingFreshSelectedAccess() async throws {
        let service = CaptureTestService()
        let message = try #require(service.messages[service.first]?.first)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        service.onEvent?(.disconnected("Uncached file fixture"))
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt", mimeType: "text/plain")
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        let presentation = WorkspacePresentation()
        presentation.openArtifact(destination, store: store)
        let reader = try #require(presentation.artifact)
        await waitWhile { reader.errorMessage == nil }
        #expect(reader.file == nil && reader.errorMessage != nil && service.downloadCount == 0)
        #expect(await store.connect(configuration))
        reader.retry()
        await waitWhile { reader.file == nil }
        #expect(reader.file?.data == Data("main".utf8))
        #expect(service.downloadCount == 1)
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination, force: true) }
        presentation.closeArtifact(id: reader.id)
    }

    @Test func historicalCardsKeepTheirOwnSamePathCaptureOffline() async throws {
        let service = CaptureTestService()
        let first = ChatMessage(id: "first", role: .assistant, text: "MEDIA:/report.txt")
        let second = ChatMessage(id: "second", role: .assistant, text: "MEDIA:/report.txt")
        service.messages[service.first] = [first, second]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt", mimeType: "text/plain")
        service.fileBytes = Data("first capture".utf8)
        let a = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: first))
        #expect(try await store.downloadArtifact(a).data == Data("first capture".utf8))
        store.finishArtifact(a)
        service.fileBytes = Data("second capture".utf8)
        let b = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: second))
        #expect(try await store.downloadArtifact(b).data == Data("second capture".utf8))
        store.finishArtifact(b)
        service.onEvent?(.disconnected("Historical file fixture"))
        for (message, expected) in [(first, "first capture"), (second, "second capture")] {
            let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
            #expect(try await store.downloadArtifact(destination).data == Data(expected.utf8))
            store.finishArtifact(destination)
        }
        #expect(service.downloadCount == 2)
    }


    @Test func offlineTranscriptGestureOpensItsCapturedFile() async throws {
        let service = CaptureTestService()
        let message = try #require(service.messages[service.first]?.first)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt", mimeType: "text/plain")
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        _ = try await store.downloadArtifact(destination)
        store.finishArtifact(destination)
        service.onEvent?(.disconnected("Offline gesture fixture"))
        let owner = try #require(store.chats.screen(profile: service.first.profile)?.owner)
        let presentation = WorkspacePresentation()
        let captured = transcriptArtifactAction(store: store, workspace: store.chats,
            botID: "helper", owner: owner, admittedBy: { true },
            onOpen: { presentation.openArtifact($0, store: store) })
        let action = try #require(captured)
        action(attachment)
        let reader = try #require(presentation.artifact)
        await waitWhile { reader.file == nil }
        #expect(reader.file?.data == Data("main".utf8))
        #expect(service.downloadCount == 1)
        presentation.closeArtifact(id: reader.id)
    }

    /// A chat file captured after the connection pins its installation reopens offline in a relaunched app.
    @Test func chatFileCapturedAfterTheInstallationPinReopensOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = CaptureTestService(), vault = MemoryConnectionStorage()
        service.pinOnConnect = "authenticated-installation"
        let message = try #require(service.messages[service.first]?.first)
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt", mimeType: "text/plain")
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        vault.saved = configuration
        let cache = ArtifactCache(root: root)
        let store = AppStore(service: service, persistence: vault.persistence, artifactCache: cache)
        let unpinned = store.captures
        #expect(await store.connect(configuration))
        #expect(store.configuration?.installID == "authenticated-installation")
        #expect(vault.saved?.installID == "authenticated-installation")
        #expect(store.captures !== unpinned, "The pin moves captures to the pinned installation's namespace")
        await store.open(service.profiles[0])
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        #expect(try await store.downloadArtifact(destination).data == Data("main".utf8))
        store.finishArtifact(destination)
        #expect(service.downloadCount == 1)
        #expect(store.flush())

        // A relaunch on the same device: saved setup, reopened cache, no connection.
        let reopenedCache = ArtifactCache(root: root)
        let reopened = AppStore(service: service, persistence: vault.persistence, artifactCache: reopenedCache)
        #expect(!reopened.isConnected)
        #expect(reopened.configuration?.installID == "authenticated-installation")
        await reopened.open(service.profiles[0])
        let offline = try #require(reopened.artifactDestination(for: attachment, botID: "helper", producingMessage: message),
            "The relaunched app shows the cached chat and its file card")
        #expect(try await reopened.downloadArtifact(offline).data == Data("main".utf8))
        reopened.finishArtifact(offline)
        #expect(service.downloadCount == 1, "The offline read uses the capture, not the network")

        reopened.forgetConnection(); try await reopenedCache.drainMaintenance()
        store.forgetConnection(); try await cache.drainMaintenance()
        await cache.close(); await reopenedCache.close()
        LocalHistory.remove(for: configuration.id)
    }

    @Test func disclosureChangesKeepTheArtifactKeyAndOfflineCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Self.source("main"), scope = Self.scope()
        let durable = ChatMessage(id: "main:row:5", role: .tool, text: "MEDIA:/report.txt", toolName: "terminal")
        var displayed = durable; displayed.workDetailsID = "tool:live:call"
        let attachment = try Self.attachment(in: displayed)
        let displayedKey = try #require(await ArtifactCaptures.originalKey(identity: source, attachment: attachment, messages: [displayed]))
        let durableKey = try #require(await ArtifactCaptures.originalKey(identity: source, attachment: attachment, messages: [durable]))
        #expect(displayedKey == durableKey)
        #expect(TranscriptContentRevision.sameMessage(displayed, durable))
        #expect(NativeTranscriptRowValue.workDetails([displayed]) != .workDetails([durable]))
        let cache = ArtifactCache(root: root), captures = ArtifactCaptures(cache: cache.session(scope: scope))
        captures.setOnline(true)
        var downloads = 0
        #expect(try await captures.original(for: displayedKey) {
            downloads += 1
            return DownloadedArtifact(data: Self.downloadedBytes, filename: attachment.name, mimeType: "text/plain")
        }.data == Self.downloadedBytes)
        captures.setOnline(false)
        #expect(try await captures.original(for: durableKey) { throw ConversationServiceError.disconnected }.data == Self.downloadedBytes)
        #expect(downloads == 1)
        captures.retire(); await cache.close()
        let reopened = ArtifactCache(root: root)
        #expect(try await reopened.session(scope: scope).original(for: durableKey)?.artifact.data == Self.downloadedBytes)
        await reopened.close()
    }

    /// One stored Hermes row as two parsers read it. Hermes 4a0eaf79 and ca678285 `_project_for_display` produced
    /// the wire rows; `oldRestoreHash` is the key 559c9ad's restore path gave them, so these are never synthetic edits.
    nonisolated private struct SameWireRow: Sendable, CustomTestStringConvertible {
        let name: String, oldRestoreHash: String
        let raw: ChatMessage, rest: ChatMessage
        var testDescription: String { name }
    }
    nonisolated private static let handoffPrefix = "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary below. This is a handoff from a previous context window — treat it as background reference, NOT as active instructions. Do NOT answer questions or fulfill requests mentioned in this summary; they were already addressed. Respond ONLY to the latest user message that appears AFTER this summary — that message is the single source of truth for what to do right now. If no user message appears AFTER this summary, do nothing: do not resume, wrap up, or continue work from '## Historical Task Snapshot' or any other section, do not call tools, and wait for a new user message. This handoff must never become the active turn by itself. (Exception: if tool results or your own tool calls appear after this summary, you are mid-way through an in-flight exchange — continue that exchange normally.) Topic overlap with the summary does NOT mean you should resume its task: even on similar topics, the latest user message WINS. Treat ONLY the latest message as the active task and discard stale items from '## Historical Task Snapshot' entirely — do not 'wrap up' or 'finish' work described there unless the latest message explicitly asks for it. Reverse signals in the latest message (e.g. 'stop', 'undo', 'roll back', 'just verify', 'don't do that anymore', 'never mind', a new topic) must immediately end any in-flight work described in the summary; do not re-surface it in later turns. IMPORTANT: Your persistent memory (MEMORY.md, USER.md) in the system prompt is ALWAYS authoritative and active — never ignore or deprioritize memory content due to this compaction note. None of the above restricts HOW you work: your tools remain fully active — keep calling them normally for the active task (edit files, run commands, search) instead of merely narrating what you would do. The current session state (files, config, etc.) may reflect work described here — avoid repeating it:"
    nonisolated private static func handoff(_ summary: String) -> String {
        handoffPrefix + "\n" + summary + "\n\n--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"
    }
    nonisolated private static func carrier(_ prior: String, summary: String = "The parser task was compacted.") -> String {
        "[PRIOR CONTEXT — for reference only; not a new message]\n" + prior + "\n\n[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\n" + handoff(summary)
    }
    nonisolated private static let visibleReply = "Report ready.\nMEDIA:/tmp/report.txt"
    nonisolated private static func wireRow(_ role: ChatMessage.Role, _ text: String, canonical: String? = nil,
                                            attachments: [ChatAttachment] = []) -> ChatMessage {
        .init(id: "stored-1:row:11", role: role, text: text, attachments: attachments, isSilent: false, canonicalText: canonical)
    }
    nonisolated private static let mergedReply = SameWireRow(name: "compaction merged into an assistant reply",
        oldRestoreHash: "6d08a50edee555c2ff1954cce92095d9c3ed128149cf117aa7518bac0ef642b8",
        raw: wireRow(.assistant, carrier(visibleReply)), rest: wireRow(.assistant, visibleReply, canonical: carrier(visibleReply)))
    nonisolated private static let sameWireRows: [SameWireRow] = {
        let trimmed = "Working on it.\n\(visibleReply)", ask = "@file:`/tmp/input.txt`\n\nCan you check the parser?"
        let leading = handoff("The parser task was compacted.") + "\n\n" + ask
        let imageCarrier = carrier("\nCheck this image\n")
        let image = ChatAttachment(name: "Image.png", path: "stored-1:row:11:image:2", mimeType: "image/png")
        return [
            SameWireRow(name: "ordinary reply", oldRestoreHash: "b06465ba05d33209da1b5039a581daf4a6d35be2f0329d0cad615bb20b23cbb7",
                raw: wireRow(.assistant, visibleReply), rest: wireRow(.assistant, visibleReply)),
            mergedReply,
            SameWireRow(name: "trimmed commentary", oldRestoreHash: "db90e9deebb6a8cfcd7b1bf00cd3692d5eaaae8972be78a69821cd8af6a2784c",
                raw: wireRow(.assistant, trimmed + "\n"), rest: wireRow(.assistant, trimmed, canonical: trimmed + "\n")),
            SameWireRow(name: "handoff prepended to a user ask", oldRestoreHash: "a3e737710c3ecc769f1d5c2493a10ddf853b54405ec221774fe520128fc0019f",
                raw: wireRow(.user, leading), rest: wireRow(.user, ask, canonical: leading)),
            SameWireRow(name: "sidecar image row", oldRestoreHash: "556b184e9518725b221de8a1b8cfadeaa7e6f4ea9a3f14df56dcc73a7f44736f",
                raw: wireRow(.user, imageCarrier, attachments: [image]),
                rest: wireRow(.user, "Check this image", canonical: imageCarrier, attachments: [image]))
        ]
    }()


    private struct OfflineRead {
        let capturedKey: ArtifactOriginalKey, currentKey: ArtifactOriginalKey
        let viaKey: Result<Data, ConversationServiceError>
        let capturedBytes: Data?, downloads: Int
    }

    /// Captures `captured`'s file online, then asks for `current`'s file offline, optionally from a reopened cache.
    private func offlineRead(capturing captured: ChatMessage, thenReading current: ChatMessage,
                             coldCache: Bool = false) async throws -> OfflineRead {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Self.source("stored-1"), scope = Self.scope()
        var cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        var captures = ArtifactCaptures(cache: session)
        captures.setOnline(true)
        let attachment = try Self.attachment(in: captured)
        let capturedKey = try #require(await ArtifactCaptures.originalKey(identity: source, attachment: attachment, messages: [captured]))
        var downloads = 0
        #expect(try await captures.original(for: capturedKey) {
            downloads += 1
            return DownloadedArtifact(data: Self.downloadedBytes, filename: attachment.name, mimeType: "text/plain")
        }.data == Self.downloadedBytes)
        if coldCache {
            captures.retire(); await cache.close()
            cache = ArtifactCache(root: root); session = cache.session(scope: scope)
            captures = ArtifactCaptures(cache: session)
        }
        captures.setOnline(false)
        let currentKey = try #require(await ArtifactCaptures.originalKey(identity: source, attachment: try Self.attachment(in: current), messages: [current]))
        let viaKey: Result<Data, ConversationServiceError>
        do { viaKey = .success(try await captures.original(for: currentKey) { throw ConversationServiceError.rejected(500) }.data) }
        catch let error as ConversationServiceError { viaKey = .failure(error) }
        catch { viaKey = .failure(.incompatible) }
        let capturedBytes = try await session.original(for: capturedKey)?.artifact.data
        captures.retire(); await cache.close()
        return .init(capturedKey: capturedKey, currentKey: currentKey, viaKey: viaKey, capturedBytes: capturedBytes, downloads: downloads)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test(arguments: sameWireRows, [false, true])
    private func restoreCaptureStaysAvailableAcrossTheRowsRestProjection(row: SameWireRow, coldCache: Bool) async throws {
        let read = try await offlineRead(capturing: row.raw, thenReading: row.rest, coldCache: coldCache)
        #expect(hex(read.capturedKey.sourceRevision) == row.oldRestoreHash)
        #expect(read.currentKey == read.capturedKey)
        #expect(read.viaKey == .success(Self.downloadedBytes))
        #expect(read.downloads == 1)
    }

    @Test(arguments: [false, true])
    func canonicalEditCannotReuseBytesBehindTheSameVisibleRow(fromRawRow: Bool) async throws {
        let edited = Self.carrier(Self.visibleReply, summary: "The parser task was compacted again.")
        let current = Self.wireRow(.assistant, Self.visibleReply, canonical: edited)
        let captured = fromRawRow ? Self.mergedReply.raw : Self.mergedReply.rest
        let read = try await offlineRead(capturing: captured, thenReading: current)
        #expect(current.text == Self.mergedReply.rest.text)
        #expect(read.capturedKey.path == read.currentKey.path && read.capturedKey.messageID == read.currentKey.messageID)
        #expect(read.currentKey != read.capturedKey)
        #expect(read.viaKey == .failure(.disconnected))
        #expect(read.capturedBytes == Self.downloadedBytes)
        #expect(read.downloads == 1)
    }

    @Test func displayOnlyChangeKeepsTheCaptureOfItsUnchangedRow() async throws {
        let captured = Self.mergedReply.rest
        var current = captured; current.text = "Report finished.\nMEDIA:/tmp/report.txt"
        let read = try await offlineRead(capturing: captured, thenReading: current)
        #expect(read.currentKey == read.capturedKey)
        #expect(read.viaKey == .success(Self.downloadedBytes))
        #expect(read.downloads == 1)
    }

    /// Page reads before canonical retention kept only display text. That capture cannot be tied to a stored row,
    /// so it stays under its own key and the current row needs one online read. This is the accepted missing-provenance
    /// boundary, not a repaired upgrade path.
    @Test(arguments: [false, true])
    func legacyPageCaptureHasNoCanonicalProvenanceToAttach(edited: Bool) async throws {
        let oldPage = Self.wireRow(.assistant, Self.visibleReply)
        let stored = Self.carrier(Self.visibleReply, summary: edited ? "The parser task was compacted again." : "The parser task was compacted.")
        let read = try await offlineRead(capturing: oldPage, thenReading: Self.wireRow(.assistant, Self.visibleReply, canonical: stored))
        #expect(hex(read.capturedKey.sourceRevision) == "b06465ba05d33209da1b5039a581daf4a6d35be2f0329d0cad615bb20b23cbb7")
        #expect(read.currentKey != read.capturedKey)
        #expect(read.viaKey == .failure(.disconnected))
        #expect(read.capturedBytes == Self.downloadedBytes)
        #expect(read.downloads == 1)
    }

    @Test func sidecarImagePagePathStaysASeparateCapture() async throws {
        let row = try #require(Self.sameWireRows.first { !$0.rest.attachments.isEmpty })
        var oldPage = Self.wireRow(.user, "Check this image", attachments: row.rest.attachments)
        oldPage.attachments[0].path = "stored-1:row:11:image:1"
        let read = try await offlineRead(capturing: oldPage, thenReading: row.rest)
        #expect(hex(read.capturedKey.sourceRevision) == "720e39f7b28efd373bb94f4423b7bf94372996f309cd486e9af565ac4ca56e92")
        #expect(read.capturedKey.path != read.currentKey.path)
        #expect(read.viaKey == .failure(.disconnected))
        #expect(read.capturedBytes == Self.downloadedBytes)
        #expect(read.downloads == 1)
    }

    nonisolated private static let producerChanges: [(name: String, change: @Sendable (inout ChatMessage) -> Void)] = [
        ("id", { $0.id = "stored-1:row:12" }),
        ("role", { $0.role = .user }),
        ("timestamp", { $0.timestamp = Date(timeIntervalSince1970: 10) }),
        ("tool name", { $0.toolName = "write_file" }),
        ("display kind", { $0.displayKind = "steer" }),
        ("display title", { $0.displayText = "Finished" }),
        ("silence flag", { $0.isSilent = nil }),
        ("extra attachment", { $0.attachments.append(.init(name: "b.txt", path: "/tmp/b.txt", mimeType: "text/plain")) }),
        ("attachment name", { $0.attachments[0].name = "renamed.txt" }),
        ("attachment type", { $0.attachments[0].mimeType = "text/markdown" })
    ]

    @Test(arguments: producerChanges, [nil, "stored row"] as [String?])
    func producerIdentityKeepsEveryOtherFieldExact(change: (name: String, change: @Sendable (inout ChatMessage) -> Void), canonical: String?) async throws {
        let source = Self.source("stored-1")
        let attachment = ChatAttachment(name: "a.txt", path: "/tmp/a.txt", mimeType: "text/plain")
        let base = Self.wireRow(.assistant, "Visible", canonical: canonical, attachments: [attachment])
        var changed = base; change.change(&changed)
        let found = try #require(await ArtifactCaptures.originalKey(identity: source, attachment: attachment, messages: [changed]))
        let original = try #require(await ArtifactCaptures.originalKey(identity: source, attachment: attachment, messages: [base]))
        #expect(found != original)
    }

    @Test func producerIdentityComparesExactUTF8AndPath() async throws {
        let source = Self.source("stored-1")
        let attachment = ChatAttachment(name: "a.txt", path: "/tmp/a.txt", mimeType: "text/plain")
        func key(_ text: String, canonical: String? = nil, attachment: ChatAttachment? = nil) async throws -> ArtifactOriginalKey {
            let file = attachment ?? ChatAttachment(name: "a.txt", path: "/tmp/a.txt", mimeType: "text/plain")
            let row = Self.wireRow(.assistant, text, canonical: canonical, attachments: [file])
            return try #require(await ArtifactCaptures.originalKey(identity: source, attachment: file, messages: [row]))
        }
        let composed = "caf\u{00E9}", decomposed = "cafe\u{0301}"
        #expect(composed == decomposed)
        #expect(try await key(composed) != key(decomposed))
        #expect(try await key("Visible", canonical: composed) != key("Visible", canonical: decomposed))
        #expect(try await key("Visible", canonical: "") != key("Visible"))
        #expect(try await key("Visible", canonical: "") == key("", canonical: ""))
        #expect(try await key("Visible", canonical: "stored") == key("stored"))
        let moved = ChatAttachment(name: "a.txt", path: "/tmp/caf\u{00E9}.txt", mimeType: "text/plain")
        let movedDecomposed = ChatAttachment(name: "a.txt", path: "/tmp/cafe\u{0301}.txt", mimeType: "text/plain")
        #expect(try await key("Visible", attachment: attachment) != key("Visible", attachment: moved))
        #expect(try await key("Visible", attachment: moved) != key("Visible", attachment: movedDecomposed))
    }

    @Test func legacyRowsKeepCapturesUntilACanonicalRevisionChangesTheirKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The exact sorted encoding builds before canonicalText wrote for this row.
        let legacyJSON = #"{"attachments":[],"id":"main:row:5","isSilent":false,"role":"assistant","text":"MEDIA:\/report.txt"}"#
        let legacy = try JSONDecoder().decode(ChatMessage.self, from: Data(legacyJSON.utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(legacy) == Data(legacyJSON.utf8))

        let source = Self.source("main"), attachment = try Self.attachment(in: legacy)
        let legacyKey = try #require(await ArtifactCaptures.originalKey(identity: source, attachment: attachment, messages: [legacy]))
        #expect(legacyKey.sourceRevision == Data(SHA256.hash(data: Data("[\(legacyJSON)]".utf8))))
        let cache = ArtifactCache(root: root), captures = ArtifactCaptures(cache: cache.session(scope: Self.scope()))
        captures.setOnline(true)
        var downloads = 0
        #expect(try await captures.original(for: legacyKey) {
            downloads += 1
            return DownloadedArtifact(data: Self.downloadedBytes, filename: attachment.name, mimeType: "text/plain")
        }.data == Self.downloadedBytes)

        // Upgrading alone changes nothing for a row no read has revised, including offline.
        captures.setOnline(false)
        #expect(try await captures.original(for: legacyKey) { throw ConversationServiceError.disconnected }.data == Self.downloadedBytes)
        #expect(downloads == 1)

        // This legacy row holds no canonical bytes to prove it is the stored row, so it is a new producer.
        var projected = legacy; projected.canonicalText = "[CONTEXT COMPACTION] first handoff"
        let projectedKey = try #require(await ArtifactCaptures.originalKey(identity: source, attachment: attachment, messages: [projected]))
        #expect(projectedKey != legacyKey)
        await #expect(throws: ConversationServiceError.self) {
            _ = try await captures.original(for: projectedKey) { throw ConversationServiceError.rejected(500) }
        }

        // A canonical-only revision changes the key again rather than matching the old row.
        var revised = projected; revised.canonicalText = "[CONTEXT COMPACTION] second handoff"
        let revisedKey = try #require(await ArtifactCaptures.originalKey(identity: source, attachment: attachment, messages: [revised]))
        #expect(revisedKey != projectedKey && revisedKey != legacyKey)
        captures.retire(); await cache.close()
    }

    @Test func forgettingUnreadableSetupPurgesCapturesWithoutKnowingItsConfigurationID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try WorkspaceTestService(), source = try #require(service.summaries.first?.identity)
        let scope = Self.scope()
        let key = ArtifactOriginalKey(identity: source, messageID: Data("private".utf8), path: Data("/private.txt".utf8), sourceRevision: Data("revision".utf8))
        let cache = ArtifactCache(root: root), saved = cache.session(scope: scope)
        try await saved.retainOriginal(.init(data: Data("private capture".utf8), filename: "private.txt", mimeType: "text/plain"), for: key)
        var unreadable = true
        let store = AppStore(service: service, persistence: .init(load: {
            if unreadable { throw ConversationServiceError.invalidResponse }
            return nil
        }, save: { _ in }, remove: { unreadable = false }), artifactCache: cache)
        #expect(store.savedSetupLoadFailed && store.configuration == nil)
        #expect(try await saved.original(for: key)?.artifact.data == Data("private capture".utf8))
        store.forgetConnection()
        try await cache.drainMaintenance()
        await cache.close()
        let reopenedCache = ArtifactCache(root: root), reopened = reopenedCache.session(scope: scope)
        #expect(!unreadable && !store.savedSetupLoadFailed)
        #expect(try await reopened.original(for: key) == nil)
        await reopenedCache.close()
    }

    @Test func retirementCancelsAnInFlightCaptureAndRejectsItsLateBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Self.source("main"), scope = Self.scope()
        let message = ChatMessage(id: "main:row:3", role: .assistant, text: "MEDIA:/report.txt")
        let attachment = try Self.attachment(in: message)
        let key = try #require(await ArtifactCaptures.originalKey(identity: source, attachment: attachment, messages: [message]))
        let cache = ArtifactCache(root: root), captures = ArtifactCaptures(cache: cache.session(scope: scope))
        captures.setOnline(true)
        let network = StoreTestBarrier()
        var readCancelled = false
        let loading = Task {
            try await captures.original(for: key) {
                await network.wait()
                readCancelled = Task.isCancelled
                return DownloadedArtifact(data: Self.downloadedBytes, filename: attachment.name, mimeType: "text/plain")
            }
        }
        defer { loading.cancel(); network.release() }
        await network.waitUntilEntered()
        captures.retire()
        network.release()
        await #expect(throws: (any Error).self) { _ = try await loading.value }
        #expect(readCancelled, "Retirement cancels the read it started")
        var restarted = false
        await #expect(throws: (any Error).self) {
            _ = try await captures.original(for: key) {
                restarted = true
                return DownloadedArtifact(data: Self.downloadedBytes, filename: attachment.name, mimeType: "text/plain")
            }
        }
        #expect(!restarted)
        await cache.close()
        let reopened = ArtifactCache(root: root)
        #expect(try await reopened.session(scope: scope).original(for: key) == nil, "Late bytes were never saved")
        await reopened.close()
    }

    /// A save paused just before COMMIT publishes only if a file card still wants it when it resumes.
    @Test(arguments: ["close", "connection"])
    func captureCommitRequiresASurvivingConsumer(retirement: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CaptureCommitGate()
        defer { gate.release() }
        let cache = ArtifactCache(root: root, beforeCaptureCommit: { gate.pause() })
        let service = CaptureTestService()
        let message = try #require(service.messages[service.first]?.first)
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt", mimeType: "text/plain")
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://capture-admission.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        try #require(await store.connect(configuration)); await store.open(service.profiles[0])
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        let key = try #require(await ArtifactCaptures.originalKey(identity: service.first, attachment: attachment,
            messages: [message], producingMessage: message))
        gate.arm()
        let presentation = WorkspacePresentation()
        var reader: ArtifactPreviewSession?
        var loading: Task<DownloadedArtifact, Error>?
        if retirement == "close" {
            presentation.openArtifact(destination, store: store)
            reader = try #require(presentation.artifact)
        } else {
            loading = Task { try await store.downloadArtifact(destination) }
        }
        defer { loading?.cancel(); if let reader { presentation.closeArtifact(id: reader.id) } }
        await waitWhile { !gate.isEntered }
        try #require(gate.isEntered)
        if let reader {
            presentation.closeArtifact(id: reader.id)
            #expect(presentation.artifact == nil && !reader.isCurrent)
        } else {
            store.showsConnection = true
        }
        gate.release()
        if let loading { await #expect(throws: (any Error).self) { _ = try await loading.value } }
        #expect(service.downloadCount == 1)
        // This queued read observes the held transaction after it settles.
        let scope = AppStore.artifactScope(configuration)
        #expect(try await cache.session(scope: scope).original(for: key) == nil, "No file card remained to publish the capture")
        if let reader { #expect(reader.file == nil) }
        store.captures.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        #expect(try await reopenedCache.session(scope: scope).original(for: key) == nil)
        await reopenedCache.close()
        store.forgetConnection()
    }

    @Test func forcedReloadReportsBytesTheCacheRefusesWhileOrdinaryReadStillReturnsThem() async throws {
        var limits = ArtifactCache.Limits()
        limits.singleOriginalBytes = 4
        let captures = ArtifactCaptures(cache: ArtifactCache(root: nil, limits: limits).session(scope: Self.scope()))
        defer { captures.retire() }
        captures.setOnline(true)
        let message = ChatMessage(id: "report", role: .assistant, text: "MEDIA:/report.txt")
        let attachment = try Self.attachment(in: message)
        let key = try #require(await ArtifactCaptures.originalKey(identity: Self.source("main"), attachment: attachment, messages: [message]))
        let larger = Data("larger than the single original limit".utf8)
        var downloads = 0
        let download: @MainActor () async throws -> DownloadedArtifact = {
            downloads += 1
            return DownloadedArtifact(data: larger, filename: attachment.name, mimeType: "text/plain")
        }
        let failure = await #expect(throws: (any Error).self) { _ = try await captures.original(for: key, force: true, download: download) }
        #expect(failure?.localizedDescription == "The refreshed file couldn’t be saved on this device. Try again.")
        #expect(try await captures.original(for: key, download: download).data == larger)
        #expect(downloads == 2, "The refused bytes were never cached")
    }

    /// Positional and legacy rows can be reused by a different message, so they never reach durable captures,
    /// even when their row looks identical to the one that was captured.
    @Test func legacyPositionalRowsCannotReuseDurableCapturesAfterIdenticalReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Self.source("main"), scope = Self.scope()
        let message = ChatMessage(id: "main:index:0", role: .assistant, text: "MEDIA:/mutable.html")
        let attachment = try Self.attachment(in: message)
        #expect(await ArtifactCaptures.originalKey(identity: source, attachment: attachment, messages: [message]) == nil)
        let key = ArtifactOriginalKey(identity: source, messageID: Data(message.id.utf8), path: Data(attachment.path.utf8),
            sourceRevision: Data("an older build's revision".utf8))
        let cache = ArtifactCache(root: root)
        try await cache.session(scope: scope).retainOriginal(.init(data: Data("old bytes".utf8), filename: attachment.name, mimeType: "text/html"), for: key)
        await cache.close()
        let reopenedCache = ArtifactCache(root: root), session = reopenedCache.session(scope: scope)
        let captures = ArtifactCaptures(cache: session)
        await #expect(throws: (any Error).self) {
            _ = try await captures.original(for: key) { throw ConversationServiceError.disconnected }
        }
        #expect(try await session.original(for: key)?.artifact.data == Data("old bytes".utf8), "The old row stays, unreachable")
        captures.retire(); await reopenedCache.close()
    }

    @Test func failedSecureForgetPreservesCaptureAndSuccessfulForgetPurgesColdReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = MemoryConnectionStorage()
        var removalFails = true
        let persistence = ConnectionPersistence(load: { vault.saved }, save: { vault.saved = $0 }, remove: {
            if removalFails { throw ConversationServiceError.disconnected }
            vault.saved = nil
        })
        let cache = ArtifactCache(root: root), service = CaptureTestService()
        let message = try #require(service.messages[service.first]?.first)
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt", mimeType: "text/plain")
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://forget.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let store = AppStore(service: service, persistence: persistence, artifactCache: cache)
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        #expect(try await store.downloadArtifact(destination).data == Data("main".utf8))
        store.finishArtifact(destination)
        let captures = store.captures
        let key = try #require(await ArtifactCaptures.originalKey(identity: service.first, attachment: attachment, messages: [message]))

        #expect(!store.forgetConnection())
        #expect(store.configuration?.id == configuration.id)
        #expect(store.captures === captures && !captures.isRetired)
        service.onEvent?(.disconnected("Forget failure fixture"))
        let offline = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        #expect(try await store.downloadArtifact(offline).data == Data("main".utf8))
        store.finishArtifact(offline)
        #expect(service.downloadCount == 1, "The capture survived the failed forget")

        removalFails = false
        #expect(store.forgetConnection())
        #expect(captures.isRetired)
        try await cache.drainMaintenance()
        vault.saved = configuration
        let reopenedCache = ArtifactCache(root: root)
        let reopened = AppStore(service: service, persistence: vault.persistence, artifactCache: reopenedCache)
        await #expect(throws: (any Error).self) {
            _ = try await reopened.captures.original(for: key) { throw ConversationServiceError.disconnected }
        }
        #expect(try await reopenedCache.session(scope: AppStore.artifactScope(configuration)).original(for: key) == nil)
        reopened.forgetConnection(); try await reopenedCache.drainMaintenance()
        await cache.close(); await reopenedCache.close()
    }

    @Test func retirementEndsItsCacheSession() {
        let session = ArtifactCache(root: nil).session(scope: Self.scope())
        let captures = ArtifactCaptures(cache: session)
        #expect(!session.isRetired)
        captures.retire()
        #expect(session.isRetired)
    }
}

@MainActor private final class CaptureTestService: BotService {
    var onEvent: ((BotServiceEvent) -> Void)?
    let profiles = [BotProfile(id: "helper", name: "Helper")]
    let first = SessionIdentity(profile: try! ExactID("helper"), root: try! ExactID("main"),
        stored: try! ExactID("main"), aliases: [try! ExactID("main")])
    var messages: [SessionIdentity: [ChatMessage]] = [:]
    var fileBytes: Data?
    var downloadCount = 0
    var pinOnConnect: String?
    private var issuer = ConversationIssuer<SessionIdentity>()

    init() {
        messages[first] = [ChatMessage(id: "main-file", role: .assistant, text: "MEDIA:/report.txt")]
    }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        if let pinOnConnect {
            var pinned = configuration; pinned.installID = pinOnConnect
            onEvent?(.configuration(pinned))
        }
        return .init(version: "test", installID: pinOnConnect)
    }
    func disconnect() {}
    func bots() async throws -> [BotProfile] { profiles }
    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        .init(summaries: profile == first.profile ? [.init(identity: first, title: "Main", isCanonical: true, persistence: .durable)] : [],
            activity: [:], isComplete: true)
    }
    func conversationHistory(_ identity: SessionIdentity, offset: Int) async throws -> ConversationHistoryPage {
        let rows = messages[identity] ?? []
        let ids = Set(rows.map { Data($0.id.utf8) })
        return .init(messages: rows, nextOffset: nil, isComplete: true, sourceIDs: ids,
            identityRead: ConversationIdentityRead(identity: identity, messageIDs: ids))
    }
    func downloadArtifact(_ attachment: ChatAttachment, in identity: SessionIdentity) async throws -> DownloadedArtifact {
        downloadCount += 1
        return .init(data: fileBytes ?? Data(identity.root.text.utf8), filename: attachment.name, mimeType: "text/plain")
    }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw ConversationServiceError.rejected(-32601) }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let readStartedAt = ContinuousClock.now
        issuer.retireAttachment()
        let identity: SessionIdentity
        switch target {
        case .canonical: identity = first
        case .stored(let source): identity = source
        }
        let access = try issuer.issue(identity)
        let snapshot = Conversation(id: identity.root.text, storedID: identity.stored.text,
            profileID: identity.profile.text, messages: messages[identity] ?? [])
        return .init(identity: identity, snapshot: snapshot, access: access,
            historyReadStartedAt: readStartedAt, observedSource: identity)
    }
    func source(for access: ConversationAccess) throws -> SessionIdentity { try issuer.resolve(access) }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw ConversationServiceError.rejected(-32601) }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw ConversationServiceError.rejected(-32601) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw ConversationServiceError.rejected(-32601) }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment { throw ConversationServiceError.rejected(-32601) }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        let identity = try issuer.resolve(access)
        let result = try await downloadArtifact(attachment, in: identity)
        guard try issuer.resolve(access) == identity else { throw ConversationServiceError.staleConversation }
        return result
    }
}
