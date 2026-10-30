import Foundation
import Testing
import UIKit
import BottoCore
@testable import Botto

@MainActor struct WorkspaceLibraryRetentionTests {
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
        let scan = Task { await library.refresh(bots: service.profiles) }
        await gate.waitUntilEntered()
        #expect(library.isLoading)
        #expect(library.artifacts.map(\.artifact.title) == ["recent.txt"])
        #expect(library.warning == nil)
        gate.release(); await scan.value
        #expect(!library.isLoading)
        #expect(Set(library.artifacts.map(\.artifact.title)) == ["recent.txt", "older.txt"])
        #expect((library.warning == nil) == complete)
        if !complete { #expect(library.warning?.contains("Older results may be missing") == true) }
        library.retire()
    }

    @Test func aRejectedProjectionCannotAdvanceItsWeakHeadFingerprint() async throws {
        let service = RetainedLibraryService(), gate = StoreTestBarrier(), pause = FirstProjectionPause()
        let source = service.source("main")
        service.summaries = [service.summary(source, at: 10)]
        service.pages[source] = [0: .init(messages: [service.message("old", text: "MEDIA:/old.txt", at: 10)], nextOffset: nil, isComplete: true)]
        let library = WorkspaceLibrary(service: service, projector: { messages, tail in
            if messages.contains(where: { $0.id == "new-head" }), await pause.take() { await gate.wait() }
            return await WorkspaceLibrary.project(messages, streamingMessage: tail)
        })
        library.setOnline(true); await library.refresh(bots: service.profiles)
        service.pages[source] = [0: .init(messages: [service.message("new-head", text: "MEDIA:/new.txt", at: 20)], nextOffset: nil, isComplete: true)]
        let scan = Task { await library.refresh(bots: service.profiles) }
        await gate.waitUntilEntered()
        library.setOnline(false)
        gate.release(); await scan.value
        #expect(library.artifacts.map(\.artifact.title) == ["old.txt"])
        library.setOnline(true); await library.refresh(bots: service.profiles)
        #expect(library.artifacts.map(\.artifact.title) == ["new.txt"])
        library.retire()
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
        let scan = Task { await library.refresh(bots: service.profiles) }
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
                messages: [service.message("image", text: text, at: 20)]), title: "Main")
            let deadline = ContinuousClock.now + .seconds(5)
            while library.chats.first?.messages.first?.text != text, ContinuousClock.now < deadline { await Task.yield() }
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
        let scan = Task { await library.refresh(bots: service.profiles) }
        await gate.waitUntilEntered()
        let current = changesTip ? SessionIdentity(profile: source.profile, root: source.root,
            stored: try ExactID("new-tip"), aliases: [source.root]) : source
        let latest = service.message("output", text: "MEDIA:/new.txt", at: 30)
        library.accept(identity: current, snapshot: .init(id: "main", storedID: current.stored.text,
            profileID: "helper", messages: [latest]), title: "Main")
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
        await library.refresh(bots: service.profiles)
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
        await library.refresh(bots: service.profiles)
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
        library.accept(identity: source, snapshot: snapshot, title: "Main")
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 20)); book.cache(snapshot, for: id)
        library.seed(book: book, bots: service.profiles)
        library.setOnline(true); service.failAtOffset = 0
        await library.refresh(bots: service.profiles)
        #expect(try await session.loadChats().first?.messages.map(\.id) == ["older"])
        #expect(library.artifacts.allSatisfy { $0.artifact.block == nil })
        service.failAtOffset = nil
        let extra = service.message("extra", text: "MEDIA:/extra.txt", at: 5)
        let staleTail = service.message("tail", text: "```html\n<h1>Older server response</h1>\n```", at: 20)
        service.pages[source] = [0: .init(messages: [extra, staleTail], nextOffset: nil, isComplete: true)]
        await library.refresh(bots: service.profiles, force: true)
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
        library.setOnline(true); await library.refresh(bots: service.profiles)
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
        await library.refresh(bots: service.profiles)
        let item = try #require(library.artifacts.first { $0.artifact.messageID == "older" })
        let reader = LibraryArtifactPreviewSession(item: item, library: library)
        defer { reader.finish() }
        reader.retry()
        let deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil && ContinuousClock.now < deadline { await Task.yield() }
        let file = try #require(reader.file)
        service.pages[source] = [0: .init(messages: [recent], nextOffset: nil, isComplete: false)]

        await library.refresh(bots: service.profiles)

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
        await library.refresh(bots: service.profiles)
        let oldItem = try #require(library.artifacts.first { $0.artifact.messageID == "current" })
        _ = try await library.download(oldItem)
        let edited = service.message("current", text: "Version B\nMEDIA:/same.txt", at: 20)
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [edited]), title: "Main")
        let deadline = ContinuousClock.now + .seconds(5)
        while library.chats.first?.messages.last?.text != edited.text && ContinuousClock.now < deadline { await Task.yield() }
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
        await library.refresh(bots: service.profiles)
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
            updatedAt: Date(timeIntervalSince1970: 20), messageCount: 2)
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
        library.setOnline(true); await library.refresh(bots: service.profiles)
        #expect(service.historyReads == 0)
        #expect(Set(library.artifacts.map(\.artifact.title)) == ["older.txt", "newest.txt"])
        #expect(try await session.loadChats().first?.messages.map(\.id) == ["older", "newest"])
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(Set(reopened.artifacts.map(\.artifact.title)) == ["older.txt", "newest.txt"])
        let readsBeforeRevalidation = service.historyReads
        reopened.setOnline(true); await reopened.refresh(bots: service.profiles)
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
        first.accept(identity: source, snapshot: snapshot, title: "Main")
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
        second.accept(identity: source, snapshot: snapshot, title: "Main")
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

        await library.refresh(bots: service.profiles)

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
        let reading = Task { await library.refresh(bots: service.profiles) }
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

        await library.refresh(bots: service.profiles)

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
        await library.refresh(bots: service.profiles)
        let original = try #require(library.artifacts.first)
        service.pages[source] = [0: .init(messages: [service.message("file", text: "MEDIA:/cafe\u{301}.txt", at: 20)],
            nextOffset: nil, isComplete: true)]

        await library.refresh(bots: service.profiles)

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
            await library.refresh(bots: service.profiles)
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
        return pages[identity]?[offset] ?? .init(messages: [], nextOffset: nil, isComplete: true)
    }
    func downloadArtifact(_ attachment: ChatAttachment, in identity: SessionIdentity) async throws -> DownloadedArtifact {
        downloadCount += 1
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

private actor FirstProjectionPause {
    private var pending = true
    func take() -> Bool {
        defer { pending = false }
        return pending
    }
}
