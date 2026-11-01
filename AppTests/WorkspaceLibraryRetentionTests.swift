import Foundation
import Testing
import UIKit
import SQLite3
import BottoCore
@testable import Botto

@MainActor struct WorkspaceLibraryRetentionTests {
    @Test func disclosureChangesRetainArtifactKeysReadersAndOfflineCaptures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let durable = ChatMessage(id: "main:row:5", role: .tool, text: "MEDIA:/report.txt", toolName: "terminal")
        var displayed = durable; displayed.workDetailsID = "tool:live:call"
        service.summaries = [service.summary(source, at: 10)]
        service.pages[source] = [0: .init(messages: [displayed], nextOffset: nil, isComplete: true)]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first), attachment = try #require(item.artifact.attachment)
        let displayedKey = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: [displayed]))
        let durableKey = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: [durable]))
        #expect(displayedKey == durableKey)
        #expect(TranscriptContentRevision.sameMessage(displayed, durable))
        #expect(NativeTranscriptRowValue.workDetails([displayed]) != .workDetails([durable]))
        #expect(try await library.download(item).data == service.downloadedBytes)
        service.pages[source] = [0: .init(messages: [durable], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.isCurrent(item))
        library.setOnline(false)
        #expect(try await library.original(for: durableKey) { throw HermesServiceError.disconnected }.data == service.downloadedBytes)
        #expect(service.downloadCount == 1)
        library.retire(); await cache.close()
        let reopened = ArtifactCache(root: root)
        #expect(try await reopened.session(scope: scope).original(for: durableKey)?.artifact.data == service.downloadedBytes)
        await reopened.close()
    }

    @Test func sharedBudgetTrimmingSchedulesTheSurvivingChatBeforeCapturePublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), transport = StoreTestBarrier(), projection = StoreTestBarrier()
        let pause = BudgetProjectionPause()
        defer { transport.release(); projection.release() }
        let source = service.source("background"), active = service.source("active")
        let kept = service.message("kept", text: "MEDIA:/kept.txt", at: 20)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("older", text: "Ordinary older row", at: 10), kept],
            nextOffset: nil, isComplete: true)]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, limits: .init(messageCount: 3), cache: session, projector: { messages, tail in
            if messages.contains(where: { $0.id == kept.id }), await pause.take() { await projection.wait() }
            return await WorkspaceLibrary.project(messages, streamingMessage: tail)
        })
        defer { library.retire() }
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first)
        let key = ArtifactOriginalKey(identity: source, messageID: Data(kept.id.utf8), path: Data("/kept.txt".utf8),
            sourceRevision: try #require(item.chat.sourceRevisions[Data(kept.id.utf8)]))
        service.downloadGate = transport
        var completions = 0
        let first = Task { let result = try await library.download(item); completions += 1; return result }
        defer { first.cancel() }
        await transport.waitUntilEntered(); await pause.arm()
        library.accept(identity: active,
            snapshot: .init(id: "active", storedID: "active", profileID: "helper", messages: [
                service.message("active-1", text: "First new row", at: 30),
                service.message("active-2", text: "Working new row", at: 40)], isWorking: true),
            title: "Active", evidence: .read(startedAt: .now, observedSource: active))
        #expect(library.isCurrent(item))
        #expect(library.chats.first { $0.identity == source }?.messages.map(\.id) == [kept.id])
        var deadline = ContinuousClock.now + .seconds(5)
        while !(await pause.wasTaken), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await pause.wasTaken, "The trimmed non-target chat needs its own scheduled projection.")
        await projection.waitUntilEntered()
        let registered = library.indexingMetrics.galleryConsumersRegistered
        let second = Task { let result = try await library.download(item); completions += 1; return result }
        defer { second.cancel() }
        deadline = .now + .seconds(5)
        while library.indexingMetrics.galleryConsumersRegistered == registered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(library.indexingMetrics.galleryConsumersRegistered == registered + 1)
        #expect(service.downloadCount == 1, "The second gallery consumer joined the held original flight.")
        service.downloadGate = nil; transport.release()
        _ = try await session.loadChats()
        #expect(completions == 0, "Both gallery readers wait for current provenance without blocking the cache actor.")
        projection.release()
        deadline = .now + .seconds(5)
        while completions < 2, ContinuousClock.now < deadline { await Task.yield() }
        try #require(completions == 2)
        #expect(try await first.value.data == service.downloadedBytes)
        #expect(try await second.value.data == service.downloadedBytes)
        library.retire(); await cache.close()
        let reopened = ArtifactCache(root: root)
        #expect(try await reopened.session(scope: scope).original(for: key)?.artifact.data == service.downloadedBytes)
        await reopened.close()
    }

    @Test func anotherChatCannotRestartAGatedProjectionOrDelayItsNextPage() async throws {
        let service = RetainedLibraryService(), gate = StoreTestBarrier(), attempts = LibraryProjectionAttempts()
        defer { gate.release() }
        let source = service.source("background"), active = service.source("active")
        let head = service.message("background-head", text: "MEDIA:/head.txt", at: 20)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [
            0: .init(messages: [head], nextOffset: 100, isComplete: true),
            100: .init(messages: [service.message("older", text: "MEDIA:/older.txt", at: 10)], nextOffset: nil, isComplete: true)
        ]
        let library = WorkspaceLibrary(service: service, projector: { messages, tail in
            if messages.contains(where: { $0.id == head.id }), await attempts.begin() == 1 { await gate.wait() }
            return await WorkspaceLibrary.project(messages, streamingMessage: tail)
        })
        defer { library.retire() }
        library.setOnline(true)
        let scan = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        defer { scan.cancel() }
        await gate.waitUntilEntered()
        for index in 0..<20 {
            library.accept(identity: active,
                snapshot: .init(id: "active", storedID: "active", profileID: "helper",
                    messages: [.init(id: "stream", role: .assistant, text: "Working \(index)")], isWorking: true),
                title: "Active", evidence: .read(startedAt: .now, observedSource: active))
        }
        gate.release(); await scan.value
        #expect(await attempts.count == 2, "Only the head and final merged page require projection; another chat must not restart either.")
        #expect(service.historyReads == 2)
        #expect(Set(library.artifacts.filter { $0.chat.identity == source }.map(\.artifact.title)) == ["head.txt", "older.txt"])
    }

    @Test(arguments: [true, false])
    func aSecondPageQuarantinesItsOccurrenceBeforeTheThirdPageOrCaptureCanFinish(hidden: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let gate = CaptureCommitGate(), pageGate = StoreTestBarrier()
        defer { gate.release(); pageGate.release() }
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root, beforeCaptureCommit: { gate.pause() }), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        let unsafe = service.message("boundary", text: "Unsafe needle\nMEDIA:/disputed.html", at: 20)
        let kept = service.message("kept", text: "MEDIA:/kept.txt", at: 10)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [kept, unsafe], nextOffset: nil, isComplete: true)]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let old = try #require(library.artifacts.first { $0.artifact.messageID == unsafe.id })
        let retained = try #require(library.artifacts.first { $0.artifact.messageID == kept.id })
        let key = ArtifactOriginalKey(identity: source, messageID: Data(unsafe.id.utf8), path: Data("/disputed.html".utf8),
            sourceRevision: try #require(old.chat.sourceRevisions[Data(unsafe.id.utf8)]))
        gate.arm()
        let download = Task { try await library.download(old) }
        defer { download.cancel() }
        var deadline = ContinuousClock.now + .seconds(5)
        while !gate.isEntered, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.isEntered)
        let another = service.message("another", text: "Another page", at: 5)
        service.pages[source] = [
            0: .init(messages: [unsafe], nextOffset: 100, isComplete: true, sourceIDs: [Data(unsafe.id.utf8)]),
            100: .init(messages: hidden ? [another] : [another, service.message(unsafe.id, text: "Conflicting occurrence", at: 20)],
                nextOffset: 200, isComplete: true, sourceIDs: [Data(unsafe.id.utf8), Data(another.id.utf8)]),
            200: .init(messages: [], nextOffset: nil, isComplete: true)
        ]
        let reads = service.historyReads
        service.gatedOffset = 200; service.gate = pageGate
        let scan = Task { await library.refresh(evidence: .observed, bots: service.profiles, force: true) }
        defer { scan.cancel(); pageGate.release() }
        deadline = .now + .seconds(5)
        while service.historyReads < reads + 3, ContinuousClock.now < deadline { await Task.yield() }
        try #require(service.historyReads == reads + 3)
        #expect(!library.isCurrent(old) && library.isCurrent(retained))
        #expect(LibrarySearchResults(query: "Unsafe needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        var rendered = false
        let cover = await library.thumbnail(for: old) { _ in rendered = true; return Data("unsafe".utf8) }
        #expect(cover == nil && !rendered)
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await download.value }
        var peerCompleted = false
        let peer = Task { let result = try await library.download(retained); peerCompleted = true; return result }
        defer { peer.cancel() }
        deadline = .now + .seconds(5)
        while !peerCompleted, ContinuousClock.now < deadline { await Task.yield() }
        try #require(peerCompleted, "Quarantine must project its unaffected current rows before the next history page returns.")
        #expect(try await peer.value.data == service.downloadedBytes)
        pageGate.release(); await scan.value
        #expect(try await session.original(for: key) == nil)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(!reopened.artifacts.contains { $0.artifact.messageID == unsafe.id })
        #expect(LibrarySearchResults(query: "Unsafe needle", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        reopened.retire(); await reopenedCache.close()
    }

    @Test func legacyPositionalRowsCannotReuseDurableCapturesAfterIdenticalReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let message = service.message("main:index:0", text: "MEDIA:/mutable.html", at: 10)
        let attachment = ChatAttachment(name: "mutable.html", path: "/mutable.html")
        let projection = await WorkspaceLibrary.project([message], streamingMessage: nil)
        let key = ArtifactOriginalKey(identity: source, messageID: Data(message.id.utf8), path: Data(attachment.path.utf8),
            sourceRevision: try #require(projection.revisions[Data(message.id.utf8)]))
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        try await session.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [message],
            updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
        try await session.retainOriginal(.init(data: Data("old bytes".utf8), filename: attachment.name, mimeType: "text/html"), for: key)
        await cache.close()
        let reopenedCache = ArtifactCache(root: root), reopenedSession = reopenedCache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: reopenedSession)
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 10))
        let identical = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [message])
        book.cache(identical, for: id)
        library.seed(book: book, bots: service.profiles); await library.restore()
        library.accept(identity: source, snapshot: identical, title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        #expect(library.artifacts.isEmpty)
        #expect(!TranscriptMessageIndex(identical).matches(message))
        #expect(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: [message]) == nil)
        await #expect(throws: (any Error).self) { _ = try await library.original(for: key) { throw HermesServiceError.disconnected } }
        #expect(try await reopenedSession.original(for: key)?.artifact.data == Data("old bytes".utf8))
        #expect(service.downloadCount == 0)
        library.retire(); await reopenedCache.close()
    }

    @Test(arguments: [false, true])
    func coldSeedPreservesProjectedAmbiguityWhenTheArtifactIndexHasNoEvidence(legacyIndex: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let disputed = service.message("duplicate", text: "Disputed needle\n```html\n<h1>Disputed cover</h1>\n```", at: 20)
        let retained = service.message("retained", text: "MEDIA:/retained.txt", at: 10)
        let repeated = Data(disputed.id.utf8)
        var snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [retained, disputed])
        snapshot.unavailableMessageIDs = [repeated]
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 20)); book.cache(snapshot, for: id)
        let savedBook = try JSONDecoder().decode(ConversationBook.self, from: JSONEncoder().encode(book))
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        if legacyIndex {
            try await session.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: snapshot.messages,
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
        }
        let library = WorkspaceLibrary(service: service, cache: session)
        library.seed(book: savedBook, bots: service.profiles); await library.restore()
        #expect(library.artifacts.map(\.artifact.title) == ["retained.txt"])
        #expect(library.chats.first?.unavailableMessageIDs.contains(repeated) == true)
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().first?.unavailableMessageIDs?.contains(repeated) != true,
              ContinuousClock.now < deadline { await Task.yield() }
        try #require(try await session.loadChats().first?.unavailableMessageIDs?.contains(repeated) == true)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        reopened.seed(book: savedBook, bots: service.profiles); await reopened.restore()
        #expect(reopened.artifacts.map(\.artifact.title) == ["retained.txt"])
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        #expect(service.historyReads == 0 && service.downloadCount == 0)
        snapshot.unavailableMessageIDs = nil
        reopened.accept(identity: source, snapshot: snapshot, title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        let recoveryDeadline = ContinuousClock.now + .seconds(5)
        while !reopened.artifacts.contains(where: { $0.artifact.messageID == disputed.id }),
              ContinuousClock.now < recoveryDeadline { await Task.yield() }
        #expect(reopened.artifacts.contains { $0.artifact.messageID == disputed.id })
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: [false, true])
    func completeHistoryAbsenceSurvivesStaleBookReseedAcrossIndependentReopen(legacyIndex: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let removed = service.message("removed", text: "Deleted needle\nMEDIA:/removed.txt", at: 10)
        let retained = service.message("retained", text: "MEDIA:/retained.txt", at: 20)
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 20))
        book.cache(.init(id: "main", storedID: "main", profileID: "helper", messages: [removed, retained]), for: id)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.seed(book: book, bots: service.profiles); await library.restore()
        let old = try #require(library.artifacts.first { $0.artifact.messageID == removed.id })
        service.summaries = [service.summary(source, at: 30)]
        service.pages[source] = [0: .init(messages: [retained], nextOffset: nil, isComplete: true)]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(!library.isCurrent(old))
        #expect(try await session.loadChats().first?.coverage == .complete)
        #expect(try await session.loadChats().first?.removedMessageIDs == [Data(removed.id.utf8)])
        service.pages[source] = [0: .init(messages: [retained], nextOffset: nil, isComplete: false)]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(try await session.loadChats().first?.removedMessageIDs == [Data(removed.id.utf8)])
        library.setOnline(false); library.seed(book: book, bots: service.profiles)
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.artifacts.map(\.artifact.title) == ["retained.txt"])
        #expect(LibrarySearchResults(query: "Deleted needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        library.retire()
        if legacyIndex {
            let legacySession = cache.session(scope: scope)
            try await legacySession.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [retained],
                updatedAt: nil, coverage: .complete, summary: nil, headFingerprint: nil))
        }
        await cache.close()

        for _ in 0..<2 {
            let reopenedCache = ArtifactCache(root: root), reopenedSession = reopenedCache.session(scope: scope)
            let reopened = WorkspaceLibrary(service: service, cache: reopenedSession)
            reopened.seed(book: book, bots: service.profiles); await reopened.restore()
            #expect(reopened.artifacts.map(\.artifact.title) == ["retained.txt"])
            #expect(LibrarySearchResults(query: "Deleted needle", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
            let deadline = ContinuousClock.now + .seconds(5)
            while try await reopenedSession.loadChats().first?.excludedMessageIDs.contains(Data(removed.id.utf8)) != true,
                  ContinuousClock.now < deadline { await Task.yield() }
            try #require(try await reopenedSession.loadChats().first?.excludedMessageIDs.contains(Data(removed.id.utf8)) == true)
            reopened.retire(); await reopenedCache.close()
        }
        let recoveredCache = ArtifactCache(root: root)
        let recovered = WorkspaceLibrary(service: service, cache: recoveredCache.session(scope: scope))
        recovered.seed(book: book, bots: service.profiles); await recovered.restore()
        service.pages[source] = [0: .init(messages: [removed, retained], nextOffset: nil, isComplete: true)]
        recovered.setOnline(true); await recovered.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(Set(recovered.artifacts.map(\.artifact.title)) == ["removed.txt", "retained.txt"])
        recovered.retire(); await recoveredCache.close()
    }

    @Test(arguments: [true, false])
    func projectedDuplicatePageWithdrawsTheOldOccurrenceAndCannotRegainCompleteCoverage(hidden: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        let output = service.message("boundary", text: "Disputed needle MEDIA:/disputed.html", at: 20)
        let retained = service.message("retained", text: "MEDIA:/retained.txt", at: 10)
        service.summaries = [.init(identity: source, title: "Main", isCanonical: true, persistence: .durable,
            preview: "unchanged", updatedAt: Date(timeIntervalSince1970: 20), messageCount: 2)]
        service.pages[source] = [0: .init(messages: [retained, output], nextOffset: nil, isComplete: true)]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let old = try #require(library.artifacts.first { $0.artifact.messageID == output.id })
        let rows = hidden ? [retained, output] : [retained, output, service.message(output.id, text: "Second occurrence", at: 20)]
        service.pages[source] = [0: .init(messages: rows, nextOffset: nil, isComplete: false,
            sourceIDs: [Data(output.id.utf8), Data(retained.id.utf8)], unavailableMessageIDs: [Data(output.id.utf8)])]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(!library.isCurrent(old))
        #expect(library.artifacts.map(\.artifact.title) == ["retained.txt"])
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        let reads = service.historyReads
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyReads > reads)
        #expect(try await session.loadChats().first?.coverage == .partial)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(reopened.artifacts.map(\.artifact.title) == ["retained.txt"])
        reopened.retire(); await reopenedCache.close()
    }

    @Test func weakHeadRevalidationDetectsAChangedHiddenIdentityBeforeReusingOlderResults() async throws {
        let service = RetainedLibraryService(), source = service.source("main")
        let unsafe = service.message("boundary", text: "MEDIA:/disputed.html", at: 10)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [
            0: .init(messages: [], nextOffset: 100, isComplete: true, sourceIDs: [Data("hidden-before".utf8)]),
            100: .init(messages: [unsafe], nextOffset: nil, isComplete: true, sourceIDs: [Data(unsafe.id.utf8)])
        ]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first)
        let reads = service.historyReads, gate = StoreTestBarrier()
        service.pages[source]?[0] = .init(messages: [], nextOffset: 100, isComplete: true, sourceIDs: [Data(unsafe.id.utf8)])
        service.gate = gate; service.gatedOffset = 100
        let scan = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        defer { scan.cancel(); gate.release() }
        let deadline = ContinuousClock.now + .seconds(5)
        while service.historyReads < reads + 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!library.isCurrent(item), "Hidden head evidence withdraws the prior visible occurrence before the older read finishes")
        gate.release(); await scan.value
        #expect(service.historyReads == reads + 2)
        #expect(library.artifacts.isEmpty)
        #expect(library.warning != nil)
        library.retire()
    }

    @Test func hiddenRawOverlapQuarantinesAnEarlierVisibleOutputAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        let repeated = Data("boundary".utf8), retained = Data("retained".utf8)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [
            0: .init(messages: [service.message("boundary", text: "MEDIA:/unsafe.html", at: 20)], nextOffset: 100, isComplete: true, sourceIDs: [repeated]),
            100: .init(messages: [service.message("retained", text: "MEDIA:/retained.txt", at: 10)], nextOffset: nil, isComplete: true, sourceIDs: [retained, repeated])
        ]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.artifacts.map(\.artifact.title) == ["retained.txt"])
        #expect(library.warning != nil)
        #expect(try await session.loadChats().first?.unavailableMessageIDs?.contains(repeated) == true)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(reopened.artifacts.map(\.artifact.title) == ["retained.txt"])
        reopened.retire(); await reopenedCache.close()
    }

    @Test func reloadingOneCoverKeepsOtherContentIdentitiesAndItsPriorImageUsable() async throws {
        let service = RetainedLibraryService(), source = service.source("main")
        let library = WorkspaceLibrary(service: service)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("first", text: "MEDIA:/first.png", at: 10),
            service.message("second", text: "MEDIA:/second.png", at: 20)], nextOffset: nil, isComplete: true)]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let first = try #require(library.artifacts.first { $0.artifact.messageID == "first" })
        let second = try #require(library.artifacts.first { $0.artifact.messageID == "second" })
        let beforeFirst = LibraryThumbnails.request(for: first, library: library).content
        let beforeSecond = LibraryThumbnails.request(for: second, library: library).content
        _ = try await library.download(first, force: true)
        let afterFirst = LibraryThumbnails.request(for: first, library: library).content
        #expect(afterFirst != beforeFirst)
        #expect(LibraryThumbnails.request(for: second, library: library).content == beforeSecond)
        #expect(beforeFirst.representsSameSource(as: afterFirst))
        #expect(!beforeSecond.representsSameSource(as: afterFirst))
        library.retire()
    }

    @Test func failedReloadSaveKeepsThePreviousCaptureAndReportsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root)
        let library = WorkspaceLibrary(service: service, cache: cache.session(scope: scope))
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("report", text: "MEDIA:/report.txt", at: 20)], nextOffset: nil, isComplete: true)]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first), reader = LibraryArtifactPreviewSession(item: item, library: library)
        defer { reader.finish() }
        reader.retry()
        var deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil || reader.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        let captured = try #require(reader.file)
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        service.downloadedBytes = Data("new host bytes".utf8)
        reader.reload()
        deadline = .now + .seconds(5)
        while reader.errorMessage == nil || reader.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(reader.errorMessage != nil)
        #expect(reader.file === captured)
        #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        library.setOnline(false)
        #expect(try await library.download(item).data == Data("original bytes".utf8))
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        let restored = try #require(reopened.artifacts.first)
        #expect(try await reopened.download(restored).data == Data("original bytes".utf8))
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: [false, true])
    func overlappingPagesPreserveHistoryAndQuarantineConflictingOccurrences(conflicting: Bool) async throws {
        let service = RetainedLibraryService(), source = service.source("main")
        let library = WorkspaceLibrary(service: service)
        let output = service.message("boundary", text: "Boundary needle\nMEDIA:/boundary.html", at: 20)
        let retained = service.message("retained", text: "MEDIA:/retained.txt", at: 10)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [retained, output], nextOffset: nil, isComplete: true)]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let oldItem = try #require(library.artifacts.first { $0.artifact.messageID == output.id })
        service.pages[source] = [
            0: .init(messages: [output], nextOffset: 100, isComplete: true),
            100: .init(messages: [service.message("older", text: "Older row", at: 5),
                conflicting ? service.message("boundary", text: "Changed boundary", at: 20) : output], nextOffset: nil, isComplete: true)
        ]
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.warning != nil)
        #expect(library.artifacts.contains { $0.artifact.title == "retained.txt" })
        #expect(library.isCurrent(oldItem) == !conflicting)
        #expect(LibrarySearchResults(query: "Boundary needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty == conflicting)
        let reads = service.historyReads
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyReads > reads, "Overlapping pages cannot certify a reusable complete summary")
        service.pages[source] = [0: .init(messages: [service.message("boundary", text: "Resolved boundary", at: 20)], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.chats.first?.messages.first?.text == "Resolved boundary")
        #expect(library.warning == nil)
        library.retire()
    }

    @Test(arguments: [false, true], [false, true])
    func acceptedDuplicateIDsQuarantineCoversAndSearchAcrossReopen(hidden: Bool, projected: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true)
        let output = service.message("duplicate", text: "Cover needle\n```html\n<h1>Unsafe cover</h1>\n```", at: 20)
        func accept(_ messages: [ChatMessage]) {
            var snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: messages)
            if projected, messages.count > 1 {
                snapshot.unavailableMessageIDs = [Data(output.id.utf8)]
                if hidden { snapshot.messages = [output] }
            }
            library.accept(identity: source, snapshot: snapshot, title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        }
        accept([output])
        var deadline = ContinuousClock.now + .seconds(5)
        while library.artifacts.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        let item = try #require(library.artifacts.first)
        let duplicate = ChatMessage(id: output.id, role: .assistant, text: "Second occurrence", isSilent: hidden)
        accept([duplicate, output])
        deadline = .now + .seconds(5)
        while library.chats.first?.unavailableMessageIDs.contains(Data(output.id.utf8)) != true,
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(library.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "Cover needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        var rendered = false
        #expect(await library.thumbnail(for: item) { _ in rendered = true; return Data("cover".utf8) } == nil)
        #expect(!rendered && service.downloadCount == 0)
        deadline = .now + .seconds(5)
        while try await session.loadChats().first?.unavailableMessageIDs?.contains(Data(output.id.utf8)) != true,
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await session.loadChats().first?.unavailableMessageIDs?.contains(Data(output.id.utf8)) == true)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(reopened.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "Cover needle", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        reopened.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [output]), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        deadline = .now + .seconds(5)
        while reopened.artifacts.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(reopened.artifacts.count == 1)
        reopened.retire(); await reopenedCache.close()
    }

    @Test func stalePartialHistoryCannotRestoreAnAcceptedDeletedOutputOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        let old = service.message("report", text: "Report ready with deleted appendix\nMEDIA:/deleted.txt", at: 20)
        let edited = service.message("report", text: "Report ready", at: 20)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [old], nextOffset: nil, isComplete: true)]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.artifacts.count == 1)
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [edited]), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        let deadline = ContinuousClock.now + .seconds(5)
        while library.chats.first?.messages.first?.text != edited.text, ContinuousClock.now < deadline { await Task.yield() }
        #expect(library.chats.first?.messages.first?.text == "Report ready")
        service.pages[source] = [0: .init(messages: [old], nextOffset: nil, isComplete: false)]
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.chats.first?.messages.first?.text == "Report ready")
        #expect(library.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(try await session.loadChats().first?.messages.first?.text == "Report ready")
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(reopened.chats.first?.messages.first?.text == "Report ready")
        #expect(reopened.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        reopened.retire(); await reopenedCache.close()
    }

    @Test func rejectedLibrarySaveWarnsWithoutLeavingTheDeletedOutputOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var limits = ArtifactCache.Limits(); limits.metadataBytes = 4_000
        let service = RetainedLibraryService(), source = service.source("main")
        let cache = ArtifactCache(root: root, limits: limits)
        let session = cache.session(scope: .init(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil))
        let library = WorkspaceLibrary(service: service, cache: session)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("report", text: "MEDIA:/deleted.txt", at: 20)], nextOffset: nil, isComplete: true)]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(try await session.loadChats().count == 1)
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [service.message("report", text: "Report ready", at: 20)]), title: String(repeating: "metadata", count: 1_000), evidence: .read(startedAt: .now, observedSource: source))
        let deadline = ContinuousClock.now + .seconds(5)
        while library.warning?.contains("couldn’t be saved") != true, ContinuousClock.now < deadline { await Task.yield() }
        #expect(library.warning?.contains("couldn’t be saved") == true)
        #expect(library.artifacts.isEmpty)
        #expect(try await session.loadChats().isEmpty)
        library.retire(); await cache.close()
    }

    @Test(arguments: [false, true])
    func missingPreviewRechecksHistoryInsteadOfCertifyingAnUnchangedSummary(provided: Bool) async throws {
        let service = RetainedLibraryService(), source = service.source("main")
        let summary = SessionSummary(identity: source, title: "Main", isCanonical: true, persistence: .durable,
            preview: provided ? "" : nil, updatedAt: Date(timeIntervalSince1970: 20), messageCount: 1)
        service.summaries = [summary]
        service.pages[source] = [0: .init(messages: [service.message("report", text: "MEDIA:/deleted.txt", at: 20)], nextOffset: nil, isComplete: true)]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let reads = service.historyReads
        service.pages[source] = [0: .init(messages: [service.message("report", text: "Report ready", at: 20)], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles)
        if provided {
            #expect(service.historyReads == reads)
            #expect(library.artifacts.count == 1)
        } else {
            #expect(service.historyReads > reads)
            #expect(library.artifacts.isEmpty)
            #expect(library.chats.first?.messages.first?.text == "Report ready")
        }
        library.retire()
    }

    @Test func retainedCoverSurvivesOriginalEvictionAndReloadAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var limits = ArtifactCache.Limits(); limits.originalBytes = 6
        let service = RetainedLibraryService(), source = service.source("main")
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root, limits: limits), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("first", text: "MEDIA:/first.png", at: 10),
            service.message("second", text: "MEDIA:/second.png", at: 20)], nextOffset: nil, isComplete: true)]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let first = try #require(library.artifacts.first { $0.artifact.messageID == "first" })
        let second = try #require(library.artifacts.first { $0.artifact.messageID == "second" })
        service.downloadedBytes = Data("first".utf8)
        #expect(await library.thumbnail(for: first) { _ in Data("first cover".utf8) } == Data("first cover".utf8))
        service.downloadedBytes = Data("second".utf8)
        _ = try await library.download(second)
        library.retire(); await cache.close()

        let reopenedCache = ArtifactCache(root: root, limits: limits)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        let restored = try #require(reopened.artifacts.first { $0.artifact.messageID == "first" })
        let reads = service.downloadCount
        var rendered = false
        #expect(await reopened.thumbnail(for: restored) { _ in rendered = true; return nil } == Data("first cover".utf8))
        #expect(!rendered && service.downloadCount == reads)
        await #expect(throws: (any Error).self) { _ = try await reopened.download(restored) }
        reopened.setOnline(true); service.downloadedBytes = Data("new".utf8)
        _ = try await reopened.download(restored, force: true)
        let refreshedCover = await reopened.thumbnail(for: restored) { bytes in
            #expect(bytes == Data("new".utf8)); return Data("new cover".utf8)
        }
        #expect(refreshedCover == Data("new cover".utf8))
        let other = try #require(reopened.artifacts.first { $0.artifact.messageID == "second" })
        service.downloadedBytes = Data("second".utf8)
        _ = try await reopened.download(other, force: true)
        reopened.retire(); await reopenedCache.close()
        let finalCache = ArtifactCache(root: root, limits: limits)
        let final = WorkspaceLibrary(service: service, cache: finalCache.session(scope: scope))
        await final.restore()
        let finalItem = try #require(final.artifacts.first { $0.artifact.messageID == "first" })
        #expect(await final.thumbnail(for: finalItem) { _ in nil } == Data("new cover".utf8))
        final.retire(); await finalCache.close()
    }

    @Test(arguments: [false, true])
    func reloadWaitsForAnEarlierReadThenCapturesNewerBytes(aliasesChanged: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root)
        let library = WorkspaceLibrary(service: service, cache: cache.session(scope: scope))
        library.setOnline(true)
        let key = ArtifactOriginalKey(identity: source, messageID: Data("report".utf8),
            path: Data("/report.txt".utf8), sourceRevision: Data("revision".utf8))
        let aliasSource = SessionIdentity(profile: source.profile, root: source.root, stored: source.stored,
            aliases: aliasesChanged ? source.aliases.union([try ExactID("new-alias")]) : source.aliases)
        let reloadedKey = ArtifactOriginalKey(identity: aliasSource, messageID: key.messageID, path: key.path, sourceRevision: key.sourceRevision)
        let oldRead = StoreTestBarrier()
        var reloadStarted = false, events: [String] = []
        let first = Task {
            try await library.original(for: key) {
                events.append("old read started")
                await oldRead.wait()
                events.append("old response received")
                return DownloadedArtifact(data: Data("older response".utf8), filename: "report.txt", mimeType: "text/plain")
            }
        }
        await oldRead.waitUntilEntered()
        let reload = Task {
            reloadStarted = true
            return try await library.original(for: reloadedKey, force: true) {
                events.append("reload read started")
                return DownloadedArtifact(data: Data("newer response".utf8), filename: "report.txt", mimeType: "text/plain")
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !reloadStarted, ContinuousClock.now < deadline { await Task.yield() }
        oldRead.release()
        #expect(try await first.value.data == Data("older response".utf8))
        #expect(try await reload.value.data == Data("newer response".utf8))
        #expect(events == ["old read started", "old response received", "reload read started"])
        library.setOnline(false)
        let retained = try await library.original(for: key) { throw HermesServiceError.disconnected }
        #expect(retained.data == Data("newer response".utf8))
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        #expect(try await reopened.original(for: key) { throw HermesServiceError.disconnected }.data == Data("newer response".utf8))
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: [false, true])
    func readerOffersHostReloadOnlyForFileCaptures(fileBacked: Bool) async throws {
        let service = RetainedLibraryService(), source = service.source("main")
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [service.message("output", text: fileBacked ? "MEDIA:/report.html" : "```html\n<h1>Captured source</h1>\n```", at: 20)]), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        var deadline = ContinuousClock.now + .seconds(5)
        while library.artifacts.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        let reader = LibraryArtifactPreviewSession(item: try #require(library.artifacts.first), library: library)
        defer { reader.finish(); library.retire() }
        reader.retry()
        deadline = .now + .seconds(5)
        while reader.file == nil || reader.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        let captured = try #require(reader.file)
        #expect(reader.canReload == fileBacked)
        let downloads = service.downloadCount, histories = service.historyReads
        service.downloadedBytes = Data("new host file".utf8)
        reader.reload()
        deadline = .now + .seconds(5)
        while (reader.isLoading || (fileBacked && service.downloadCount == downloads)), ContinuousClock.now < deadline { await Task.yield() }
        if fileBacked {
            #expect(service.downloadCount == downloads + 1)
            #expect(reader.file?.data == Data("new host file".utf8))
        } else {
            #expect(reader.file === captured)
            #expect(service.downloadCount == downloads && service.historyReads == histories)
        }
        reader.beginOutput(.share)
        #expect(reader.output?.file.data == reader.file?.data)
    }

    @Test(arguments: [true, false])
    func pendingPagesKeepUsefulArtifactsQuietUntilCoverageSettles(complete: Bool) async throws {
        let service = RetainedLibraryService(), gate = StoreTestBarrier()
        let source = service.source("main")
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [
            0: .init(messages: [service.message("recent", text: "MEDIA:/recent.txt", at: 20)], nextOffset: 100, isComplete: true),
            100: .init(messages: [service.message("older", text: "MEDIA:/older.txt", at: 10)], nextOffset: nil, isComplete: complete)
        ]
        service.gate = gate; service.gatedOffset = 100
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        let scan = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        await gate.waitUntilEntered()
        #expect(library.isLoading)
        #expect(library.artifacts.map(\.artifact.title) == ["recent.txt"])
        #expect(library.warning == nil)
        gate.release(); await scan.value
        #expect(!library.isLoading)
        #expect(Set(library.artifacts.map(\.artifact.title)) == ["recent.txt", "older.txt"])
        #expect((library.warning == nil) == complete)
        if !complete {
            #expect(library.warning?.contains("Older results may be missing") == true)
            #expect(library.statusAction == nil)
        }
        library.retire()
    }

    @Test func aCancelledReadCannotCertifyItsWeakHeadAfterCanonicalAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), gate = StoreTestBarrier(), pause = FirstProjectionPause()
        defer { gate.release() }
        let source = service.source("main")
        let older = service.message("older", text: "MEDIA:/retained.txt", at: 5)
        service.summaries = [service.summary(source, at: 10)]
        service.pages[source] = [
            0: .init(messages: [service.message("old", text: "MEDIA:/old.txt", at: 10)], nextOffset: 100, isComplete: true),
            100: .init(messages: [older], nextOffset: nil, isComplete: true)
        ]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session, projector: { messages, tail in
            if messages.contains(where: { $0.id == "new-head" }), !messages.contains(where: { $0.id == "old" }),
               await pause.take() { await gate.wait() }
            return await WorkspaceLibrary.project(messages, streamingMessage: tail)
        })
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let old = try #require(library.artifacts.first { $0.artifact.messageID == "old" })
        service.pages[source]?[0] = .init(messages: [service.message("new-head", text: "MEDIA:/new.txt", at: 20)], nextOffset: 100, isComplete: true)
        let scan = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        defer { scan.cancel() }
        await gate.waitUntilEntered()
        #expect(!library.isCurrent(old))
        library.setOnline(false)
        gate.release(); await scan.value
        #expect(Set(library.artifacts.map(\.artifact.title)) == ["new.txt", "retained.txt"])
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().first?.coverage != .complete, ContinuousClock.now < deadline { await Task.yield() }
        let row = try #require(try await session.loadChats().first)
        #expect(row.headFingerprint == nil && row.summary == nil)
        #expect(Set(row.messages.map(\.id)) == ["older", "new-head"])
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(Set(reopened.artifacts.map(\.artifact.title)) == ["new.txt", "retained.txt"])
        let reads = service.historyReads
        reopened.setOnline(true); await reopened.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyReads == reads + 2, "A wrongly certified weak head would skip the older page")
        #expect(Set(reopened.artifacts.map(\.artifact.title)) == ["new.txt", "retained.txt"])
        reopened.retire(); await reopenedCache.close()
    }

    @Test func cancelledLibraryPagesAndCompletedChatsSurviveOfflineReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), cache = ArtifactCache(root: root)
        let source = service.source("main"), completed = service.source("completed")
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let session = cache.session(scope: scope)
        service.summaries = [service.summary(completed, at: 30), service.summary(source, at: 20)]
        service.pages[completed] = [0: .init(messages: [service.message("done", text: "MEDIA:/done.txt", at: 30)], nextOffset: nil, isComplete: true)]
        service.pages[source] = [0: .init(messages: [service.message("recent", text: "MEDIA:/recent.txt", at: 20)], nextOffset: 100, isComplete: true)]
        let gate = StoreTestBarrier(); service.gate = gate; service.gatedOffset = 100
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true)
        let scan = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        await gate.waitUntilEntered()
        scan.cancel(); gate.release(); await scan.value
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().count != 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await session.loadChats().count == 2)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(Set(reopened.artifacts.map(\.artifact.title)) == ["done.txt", "recent.txt"])
        #expect(reopened.warning?.contains("offline") == true)
        reopened.retire(); await reopenedCache.close()
    }

    @Test func galleryCoversFollowProducingEditsAndExplicitReload() async throws {
        let service = RetainedLibraryService()
        let source = service.source("main")
        let library = WorkspaceLibrary(service: service), covers = LibraryThumbnails()
        library.setOnline(true)
        func image(_ color: UIColor) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        }
        func accept(_ text: String) async {
            library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
                messages: [service.message("image", text: text, at: 20)]), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
            let deadline = ContinuousClock.now + .seconds(5)
            while !library.artifacts.contains(where: {
                $0.artifact.messageID == "image" && $0.chat.messages.first(where: { $0.id == "image" })?.text == text
                    && $0.chat.sourceRevisions[Data("image".utf8)] != nil
            }), ContinuousClock.now < deadline { await Task.yield() }
        }
        service.downloadedBytes = image(.red)
        await accept("First image MEDIA:/chart.png")
        let first = try #require(library.artifacts.first)
        let initialRequest = LibraryThumbnails.request(for: first, library: library)
        let red = try #require(await covers.image(for: first, library: library))
        service.downloadedBytes = image(.green)
        await accept("Revised image MEDIA:/chart.png")
        let revised = try #require(library.artifacts.first)
        #expect(first.id == revised.id)
        let revisedRequest = LibraryThumbnails.request(for: revised, library: library)
        #expect(initialRequest != revisedRequest)
        let green = try #require(await covers.image(for: revised, library: library))
        #expect(red.pngData() != green.pngData())
        service.downloadedBytes = image(.blue)
        _ = try await library.download(revised, force: true)
        #expect(LibraryThumbnails.request(for: revised, library: library) != revisedRequest)
        let blue = try #require(await covers.image(for: revised, library: library))
        #expect(green.pngData() != blue.pngData())
        #expect(service.downloadCount == 3)
        library.retire()
    }

    @Test(arguments: [true, false])
    func failedCoversRetryAfterReconnectOrReaderCapture(reconnecting: Bool) async throws {
        let service = RetainedLibraryService()
        let source = service.source("main")
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("image", text: "MEDIA:/chart.png", at: 20)],
            nextOffset: nil, isComplete: true)]
        service.downloadedBytes = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let library = WorkspaceLibrary(service: service), covers = LibraryThumbnails()
        defer { library.retire() }
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first)
        if reconnecting { library.setOnline(false) }
        else { service.downloadFails = true }
        let failedRequest = LibraryThumbnails.request(for: item, library: library)
        #expect(await covers.image(for: item, library: library) == nil)

        if reconnecting { library.setOnline(true) }
        else {
            service.downloadFails = false
            _ = try await library.download(item)
        }

        #expect(LibraryThumbnails.request(for: item, library: library) != failedRequest,
                "The visible card's task must retry after recovery without reopening the gallery.")
        #expect(await covers.image(for: item, library: library) != nil)
        #expect(service.downloadCount == (reconnecting ? 1 : 2), "The cover reuses the reader's captured original.")
    }

    @Test(arguments: [false, true])
    func olderScanCannotReplaceANewerAcceptedSnapshot(changesTip: Bool) async throws {
        let service = RetainedLibraryService(), cache = ArtifactCache(root: nil)
        let source = service.source("main")
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let session = cache.session(scope: scope)
        let old = service.message("output", text: "MEDIA:/old.txt", at: 20)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [old], nextOffset: 100, isComplete: true),
                                 100: .init(messages: [], nextOffset: nil, isComplete: true)]
        let gate = StoreTestBarrier()
        service.gate = gate; service.gatedOffset = 100
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true)
        let scan = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        await gate.waitUntilEntered()
        let current = changesTip ? SessionIdentity(profile: source.profile, root: source.root,
            stored: try ExactID("new-tip"), aliases: [source.root]) : source
        let latest = service.message("output", text: "MEDIA:/new.txt", at: 30)
        library.accept(identity: current, snapshot: .init(id: "main", storedID: current.stored.text,
            profileID: "helper", messages: [latest]), title: "Main", evidence: .read(startedAt: .now, observedSource: current))
        let deadline = ContinuousClock.now + .seconds(5)
        while !library.artifacts.contains(where: { $0.artifact.title == "new.txt" }), ContinuousClock.now < deadline { await Task.yield() }
        gate.release()
        await scan.value
        #expect(library.chats.first?.identity.stored == current.stored)
        #expect(library.artifacts.map(\.artifact.title) == ["new.txt"])
        let saved = try await session.loadChats()
        #expect(saved.first?.identity.stored == current.stored)
        #expect(saved.first?.messages.first?.text == "MEDIA:/new.txt")
        await cache.close()
    }

    @Test func partialNewHeadKeepsOlderCardsAndTheirCompletedReader() async throws {
        let service = RetainedLibraryService()
        let source = service.source("main")
        let old = service.message("old", text: "MEDIA:/old.txt", at: 10)
        service.summaries = [service.summary(source, at: 10)]
        service.pages[source] = [0: .init(messages: [old], nextOffset: nil, isComplete: true)]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first)
        let reader = LibraryArtifactPreviewSession(item: item, library: library)
        defer { reader.finish() }
        reader.retry()
        let deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil, ContinuousClock.now < deadline { await Task.yield() }
        let file = try #require(reader.file)
        service.pages[source] = [0: .init(messages: [service.message("new", text: "MEDIA:/new.txt", at: 20)],
            nextOffset: 100, isComplete: true)]
        service.failAtOffset = 100
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(Set(library.artifacts.map(\.artifact.title)) == ["old.txt", "new.txt"])
        #expect(library.isCurrent(item))
        #expect(reader.file === file)
        reader.beginOutput(.save)
        #expect(reader.output?.file === file)
    }

    @Test func inertReseedingCannotClearKnownUnsettledTail() async throws {
        let service = RetainedLibraryService(), cache = ArtifactCache(root: nil)
        let source = service.source("main")
        service.summaries = [service.summary(source, at: 20)]
        let session = cache.session(scope: .init(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil))
        let library = WorkspaceLibrary(service: service, cache: session)
        let older = service.message("older", text: "MEDIA:/older.txt", at: 10)
        let tail = service.message("tail", text: "```html\n<h1>Working</h1>\n```", at: 20)
        let snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [older, tail], isWorking: true)
        library.accept(identity: source, snapshot: snapshot, title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 20)); book.cache(snapshot, for: id)
        library.seed(book: book, bots: service.profiles)
        library.setOnline(true); service.failAtOffset = 0
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(try await session.loadChats().first?.messages.map(\.id) == ["older"])
        #expect(library.artifacts.allSatisfy { $0.artifact.block == nil })
        service.failAtOffset = nil
        let extra = service.message("extra", text: "MEDIA:/extra.txt", at: 5)
        let staleTail = service.message("tail", text: "```html\n<h1>Older server response</h1>\n```", at: 20)
        service.pages[source] = [0: .init(messages: [extra, staleTail], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.chats.first?.messages.last?.text == tail.text)
        #expect(Set(library.artifacts.map(\.artifact.title)) == ["extra.txt", "older.txt"])
        #expect(try await session.loadChats().first?.messages.map(\.id) == ["extra", "older"])
        await cache.close()
    }

    @Test func reloadAndExportCannotReplaceEachOthersFile() async throws {
        let service = RetainedLibraryService()
        let source = service.source("main")
        service.summaries = [service.summary(source, at: 10)]
        service.pages[source] = [0: .init(messages: [service.message("file", text: "MEDIA:/file.txt", at: 10)], nextOffset: nil, isComplete: true)]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let reader = LibraryArtifactPreviewSession(item: try #require(library.artifacts.first), library: library)
        defer { reader.finish() }
        reader.retry()
        var deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil, ContinuousClock.now < deadline { await Task.yield() }
        let original = try #require(reader.file)
        let gate = StoreTestBarrier(); service.downloadGate = gate
        reader.reload(); await gate.waitUntilEntered()
        reader.beginOutput(.save)
        #expect(reader.output == nil)
        #expect(reader.file === original)
        gate.release()
        deadline = .now + .seconds(5)
        while reader.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        reader.beginOutput(.share)
        let output = try #require(reader.output)
        reader.reload()
        #expect(!reader.isLoading && reader.file === output.file)
    }

    @Test func incompleteSameTipRefreshKeepsOlderOutputAndItsCompletedReader() async throws {
        let service = RetainedLibraryService()
        let source = service.source("main")
        let older = service.message("older", text: "MEDIA:/older.txt", at: 10)
        let recent = service.message("recent", text: "MEDIA:/recent.txt", at: 20)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [older, recent], nextOffset: nil, isComplete: true)]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first { $0.artifact.messageID == "older" })
        let reader = LibraryArtifactPreviewSession(item: item, library: library)
        defer { reader.finish() }
        reader.retry()
        let deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil && ContinuousClock.now < deadline { await Task.yield() }
        let file = try #require(reader.file)
        service.pages[source] = [0: .init(messages: [recent], nextOffset: nil, isComplete: false)]

        await library.refresh(evidence: .observed, bots: service.profiles)

        #expect(library.chats.first?.messages.map(\.id) == ["older", "recent"])
        #expect(library.isCurrent(item))
        #expect(reader.file === file)
        #expect(library.warning != nil)
    }

    @Test func acceptedPartialTailKeepsOlderOutputsAndReplacesAnEditedProducingMessage() async throws {
        let service = RetainedLibraryService()
        let source = service.source("main")
        let older = service.message("older", text: "MEDIA:/older.txt", at: 10)
        let original = service.message("current", text: "Version A\nMEDIA:/same.txt", at: 20)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [older, original], nextOffset: nil, isComplete: true)]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let oldItem = try #require(library.artifacts.first { $0.artifact.messageID == "current" })
        _ = try await library.download(oldItem)
        let edited = service.message("current", text: "Version B\nMEDIA:/same.txt", at: 20)
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [edited]), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        #expect(!library.isCurrent(oldItem))
        let deadline = ContinuousClock.now + .seconds(5)
        while !library.artifacts.contains(where: {
            $0.artifact.messageID == edited.id && $0.chat.messages.first(where: { $0.id == edited.id })?.text == edited.text
                && $0.chat.sourceRevisions[Data(edited.id.utf8)] != oldItem.chat.sourceRevisions[Data(edited.id.utf8)]
        }), ContinuousClock.now < deadline { await Task.yield() }
        #expect(library.chats.first?.messages.map(\.id) == ["older", "current"])
        #expect(library.chats.first?.messages.last?.text == "Version B\nMEDIA:/same.txt")
        #expect(!library.isCurrent(oldItem))
        let updated = try #require(library.artifacts.first { $0.artifact.messageID == "current" })
        library.setOnline(false)
        await #expect(throws: (any Error).self) { _ = try await library.download(updated) }
        #expect(library.artifacts.contains { $0.artifact.messageID == "older" })
    }

    @Test func failedReloadKeepsTheCapturedFileAvailableForExport() async throws {
        let service = RetainedLibraryService()
        let source = service.source("main")
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("file", text: "MEDIA:/report.txt", at: 20)], nextOffset: nil, isComplete: true)]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first)
        let reader = LibraryArtifactPreviewSession(item: item, library: library)
        defer { reader.finish() }
        reader.retry()
        let deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil && ContinuousClock.now < deadline { await Task.yield() }
        let captured = try #require(reader.file)
        library.setOnline(false)
        reader.reload()
        while (reader.errorMessage == nil || reader.isLoading) && ContinuousClock.now < deadline { await Task.yield() }
        #expect(reader.errorMessage != nil)
        #expect(reader.file === captured)
        #expect(reader.file?.data == Data("original bytes".utf8))
        reader.beginOutput(.save)
        let output = try #require(reader.output)
        #expect(output.file === captured)
        reader.endOutput(id: output.id)
        reader.beginOutput(.share)
        #expect(reader.output?.file === captured)
    }

    @Test func restoringAnOlderDiskTipCannotReplaceTheLocalHistorySeed() async throws {
        let service = RetainedLibraryService()
        let old = service.source("main")
        let newer = SessionIdentity(profile: old.profile, root: old.root, stored: try ExactID("new-tip"), aliases: old.aliases)
        let cache = ArtifactCache(root: nil)
        let session = cache.session(scope: .init(configurationID: UUID(), serverURL: Data("https://library.example".utf8),
            installationID: nil, username: Data(), provider: nil))
        try await session.upsert(.init(identity: old, botName: "Helper", title: "Main",
            messages: [service.message("old", text: "MEDIA:/old.txt", at: 10)], updatedAt: Date(timeIntervalSince1970: 10),
            coverage: .complete, summary: service.summary(old, at: 10), headFingerprint: nil))
        var book = ConversationBook()
        let chat = book.merge(service.summary(newer, at: 20))
        book.cache(.init(id: "main", storedID: "new-tip", profileID: "helper",
            messages: [service.message("new", text: "MEDIA:/new.txt", at: 20)]), for: chat)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.seed(book: book, bots: service.profiles)
        await library.restore()
        #expect(library.chats.first?.identity.stored == newer.stored)
        #expect(library.artifacts.map(\.artifact.title) == ["new.txt"])
        await cache.close()
    }

    @Test func coldShorterHistorySeedPreservesCompleteSavedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let older = service.message("older", text: "MEDIA:/older.txt", at: 10)
        let newest = service.message("newest", text: "MEDIA:/newest.txt", at: 20)
        let summary = SessionSummary(identity: source, title: "Main", isCanonical: false, persistence: .durable,
            preview: "", updatedAt: Date(timeIntervalSince1970: 20), messageCount: 2)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        try await session.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [older, newest],
            updatedAt: summary.updatedAt, coverage: .complete, summary: summary, headFingerprint: nil))
        var book = ConversationBook()
        let chat = book.merge(summary)
        book.cache(.init(id: "main", storedID: "main", profileID: "helper", messages: [newest]), for: chat)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.seed(book: book, bots: service.profiles)
        await library.restore()
        service.summaries = [summary]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyReads == 0)
        #expect(Set(library.artifacts.map(\.artifact.title)) == ["older.txt", "newest.txt"])
        #expect(try await session.loadChats().first?.messages.map(\.id) == ["older", "newest"])
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(Set(reopened.artifacts.map(\.artifact.title)) == ["older.txt", "newest.txt"])
        let readsBeforeRevalidation = service.historyReads
        reopened.setOnline(true); await reopened.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyReads == readsBeforeRevalidation)
        reopened.retire(); await reopenedCache.close()
    }

    @Test func workingAssistantTailIsOmittedOnDiskUntilItsSettledSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), configurationID = UUID()
        let source = service.source("main")
        let scope = ArtifactCacheScope(configurationID: configurationID, serverURL: Data("https://library.example".utf8),
            installationID: nil, username: Data(), provider: nil)
        let older = service.message("older", text: "MEDIA:/older.txt", at: 10)
        let tail = service.message("tail", text: "```html\n<h1>Working</h1>\n```", at: 20)
        var snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [older, tail], isWorking: true)
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 20))
        book.cache(snapshot, for: id)
        let firstCache = ArtifactCache(root: root), firstSession = firstCache.session(scope: scope)
        let first = WorkspaceLibrary(service: service, cache: firstSession)
        first.seed(book: book, bots: service.profiles)
        first.accept(identity: source, snapshot: snapshot, title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        var deadline = ContinuousClock.now + .seconds(5)
        while try await firstSession.loadChats().isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        let working = try #require(try await firstSession.loadChats().first)
        #expect(working.messages.map(\.id) == ["older"])
        #expect(working.coverage == .partial)
        #expect(first.artifacts.allSatisfy { $0.artifact.block == nil })
        await firstCache.close()

        let secondCache = ArtifactCache(root: root), secondSession = secondCache.session(scope: scope)
        let second = WorkspaceLibrary(service: service, cache: secondSession)
        await second.restore()
        #expect(second.artifacts.map(\.artifact.title) == ["older.txt"])
        snapshot.isWorking = false
        second.accept(identity: source, snapshot: snapshot, title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        deadline = .now + .seconds(5)
        while try await secondSession.loadChats().first?.messages.count != 2, ContinuousClock.now < deadline { await Task.yield() }
        await secondCache.close()

        let thirdCache = ArtifactCache(root: root)
        let third = WorkspaceLibrary(service: service, cache: thirdCache.session(scope: scope))
        await third.restore()
        #expect(third.artifacts.contains { $0.artifact.block?.source == "<h1>Working</h1>\n" })
        #expect(third.artifacts.contains { $0.artifact.title == "older.txt" })
        await thirdCache.close()
    }

    @Test func aFailedOlderPageKeepsTheSuccessfullyFetchedRecentMessages() async throws {
        let service = RetainedLibraryService()
        let source = service.source("main")
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("recent", text: "MEDIA:/recent.txt", at: 20)],
            nextOffset: 100, isComplete: true)]
        service.failAtOffset = 100
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)

        await library.refresh(evidence: .observed, bots: service.profiles)

        #expect(library.artifacts.map(\.artifact.messageID) == ["recent"])
        #expect(library.warning != nil)
        #expect(!library.isLoading)
    }

    @Test func cancellationKeepsTheFirstPublishedPage() async throws {
        let service = RetainedLibraryService()
        let source = service.source("main")
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("recent", text: "MEDIA:/recent.txt", at: 20)],
            nextOffset: 100, isComplete: true)]
        let gate = StoreTestBarrier()
        service.gate = gate; service.gatedOffset = 100
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        let reading = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        await gate.waitUntilEntered()
        let availableBeforeCancellation = library.artifacts.map(\.artifact.messageID)
        reading.cancel()
        gate.release()
        await reading.value

        #expect(availableBeforeCancellation == ["recent"])
        #expect(library.artifacts.map(\.artifact.messageID) == ["recent"])
        #expect(library.warning != nil)
    }

    @Test func anOversizedFinalPageNeverEntersTheIndex() async {
        let service = RetainedLibraryService()
        let source = service.source("main")
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("too-large", text: String(repeating: "x", count: 100), at: 20)],
            nextOffset: nil, isComplete: true)]
        let library = WorkspaceLibrary(service: service, limits: .init(messageCount: 10, textBytes: 16, chatCount: 10))
        library.setOnline(true)

        await library.refresh(evidence: .observed, bots: service.profiles)

        #expect(library.chats.flatMap(\.messages).isEmpty)
        #expect(library.warning != nil)
    }

    @Test func completeRefreshDoesNotReuseACanonicallyEqualButDifferentHostPath() async throws {
        let service = RetainedLibraryService()
        let source = service.source("main")
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("file", text: "MEDIA:/caf\u{e9}.txt", at: 20)],
            nextOffset: nil, isComplete: true)]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let original = try #require(library.artifacts.first)
        service.pages[source] = [0: .init(messages: [service.message("file", text: "MEDIA:/cafe\u{301}.txt", at: 20)],
            nextOffset: nil, isComplete: true)]

        await library.refresh(evidence: .observed, bots: service.profiles)

        #expect(!library.isCurrent(original))
        #expect(library.artifacts.first?.artifact.attachment?.path.utf8.elementsEqual("/cafe\u{301}.txt".utf8) == true)
    }

    @Test func cachedSeedingUsesTheSameRetainedBudgetAndPrefersNewestChat() async {
        let service = RetainedLibraryService()
        var book = ConversationBook()
        for number in 1...3 {
            let source = service.source("chat-\(number)")
            let id = book.merge(service.summary(source, at: Double(number)))
            book.cache(.init(id: source.root.text, storedID: source.stored.text, profileID: source.profile.text,
                messages: [service.message("\(number)-a", text: "MEDIA:/a.txt", at: Double(number)),
                           service.message("\(number)-b", text: "MEDIA:/b.txt", at: Double(number))]), for: id)
        }
        let library = WorkspaceLibrary(service: service, limits: .init(messageCount: 2, textBytes: 256, chatCount: 1))

        library.seed(book: book, bots: service.profiles)
        await library.restore()

        #expect(library.chats.count == 1)
        #expect(library.chats.first?.identity.root.text == "chat-3")
        #expect(library.chats.flatMap(\.messages).count == 2)
        #expect(library.chats.flatMap(\.messages).reduce(0) { $0 + $1.text.utf8.count } <= 256)
        #expect(library.warning != nil)
    }

    @Test func repeatedScansCannotAccumulateMoreThanTheGlobalRetainedBudget() async {
        let service = RetainedLibraryService()
        let sources = (1...3).map { service.source("chat-\($0)") }
        for (index, source) in sources.enumerated() {
            service.pages[source] = [0: .init(messages: [
                service.message("\(index)-a", text: "MEDIA:/a.txt", at: Double(index)),
                service.message("\(index)-b", text: "MEDIA:/b.txt", at: Double(index))
            ], nextOffset: nil, isComplete: true)]
        }
        let library = WorkspaceLibrary(service: service, limits: .init(messageCount: 2, textBytes: 256, chatCount: 10))
        library.setOnline(true)
        for newest in sources {
            service.summaries = sources.map { service.summary($0, at: $0 == newest ? 100 : 10) }
            await library.refresh(evidence: .observed, bots: service.profiles)
            #expect(library.chats.flatMap(\.messages).count <= 2)
            #expect(library.chats.flatMap(\.messages).reduce(0) { $0 + $1.text.utf8.count } <= 256)
            #expect(library.chats.first { !$0.messages.isEmpty }?.identity == newest)
            #expect(library.warning != nil)
        }
    }

    @Test(arguments: [false, true])
    func initiallyOfflineLibrariesExplainTheirCoverage(seed: Bool) {
        let service = RetainedLibraryService()
        let library = WorkspaceLibrary(service: service)
        if seed {
            let source = service.source("main")
            var book = ConversationBook()
            let id = book.merge(service.summary(source, at: 20))
            book.cache(.init(id: "main", storedID: "main", profileID: "helper",
                messages: [service.message("cached", text: "MEDIA:/cached.txt", at: 20)]), for: id)
            library.seed(book: book, bots: service.profiles)
        }

        library.setOnline(false)

        #expect(library.warning?.localizedCaseInsensitiveContains("offline") == true)
    }
}

@MainActor private final class RetainedLibraryService: BotService {
    var onEvent: ((BotServiceEvent) -> Void)?
    let profiles = [BotProfile(id: "helper", name: "Helper")]
    var summaries: [SessionSummary] = []
    var pages: [SessionIdentity: [Int: ConversationHistoryPage]] = [:]
    var failAtOffset: Int?
    var gatedOffset: Int?
    var gate: StoreTestBarrier?
    var downloadGate: StoreTestBarrier?
    var downloadedBytes = Data("original bytes".utf8)
    var downloadFails = false
    var downloadCount = 0
    var historyReads = 0
    func source(_ root: String) -> SessionIdentity {
        .init(profile: try! ExactID("helper"), root: try! ExactID(root), stored: try! ExactID(root), aliases: [try! ExactID(root)])
    }
    func summary(_ source: SessionIdentity, at time: Double) -> SessionSummary {
        .init(identity: source, title: source.root.text, isCanonical: false, persistence: .durable,
            updatedAt: Date(timeIntervalSince1970: time))
    }
    func message(_ id: String, text: String, at time: Double) -> ChatMessage {
        .init(id: id, role: .assistant, text: text, timestamp: Date(timeIntervalSince1970: time))
    }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo { .init(version: "test") }
    func disconnect() {}
    func bots() async throws -> [BotProfile] { profiles }
    func createBot(_ draft: BotDraft) async throws -> BotProfile { throw HermesServiceError.rejected(-32601) }
    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        .init(summaries: summaries, activity: [:], isComplete: true)
    }
    func conversationHistory(_ identity: SessionIdentity, offset: Int) async throws -> ConversationHistoryPage {
        historyReads += 1
        if gatedOffset == offset { await gate?.wait() }
        if failAtOffset == offset { throw HermesServiceError.disconnected }
        let page = pages[identity]?[offset] ?? .init(messages: [], nextOffset: nil, isComplete: true)
        return .init(messages: page.messages, nextOffset: page.nextOffset, isComplete: page.isComplete,
            sourceIDs: page.sourceIDs ?? Set(page.messages.map { Data($0.id.utf8) }),
            unavailableMessageIDs: page.unavailableMessageIDs)
    }
    func downloadArtifact(_ attachment: ChatAttachment, in identity: SessionIdentity) async throws -> DownloadedArtifact {
        downloadCount += 1
        if downloadFails { throw HermesServiceError.disconnected }
        await downloadGate?.wait()
        return .init(data: downloadedBytes, filename: attachment.name,
            mimeType: attachment.path.hasSuffix(".png") ? "image/png" : "text/plain")
    }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw HermesServiceError.rejected(-32601) }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation { throw HermesServiceError.rejected(-32601) }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw HermesServiceError.rejected(-32601) }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw HermesServiceError.rejected(-32601) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw HermesServiceError.rejected(-32601) }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment { throw HermesServiceError.rejected(-32601) }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact { throw HermesServiceError.rejected(-32601) }
}

private actor BudgetProjectionPause {
    private var armed = false
    private(set) var wasTaken = false
    func arm() { armed = true }
    func take() -> Bool {
        guard armed else { return false }
        armed = false; wasTaken = true; return true
    }
}

private actor LibraryProjectionAttempts {
    private(set) var count = 0
    func begin() -> Int { count += 1; return count }
}

private actor FirstProjectionPause {
    private var pending = true
    func take() -> Bool {
        defer { pending = false }
        return pending
    }
}
