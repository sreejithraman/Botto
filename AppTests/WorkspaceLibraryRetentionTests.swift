import CryptoKit
import Foundation
import Testing
import UIKit
import SQLite3
import BottoCore
@testable import Botto

@MainActor struct WorkspaceLibraryRetentionTests {
    private func waitForInitialLibraryArtifacts(_ library: WorkspaceLibrary) async throws {
        let started = ContinuousClock.now, deadline = ContinuousClock.now + .seconds(5)
        var polls = 0
        while library.artifacts.isEmpty, ContinuousClock.now < deadline {
            polls += 1
            try await Task.sleep(for: .milliseconds(5))
        }
        guard library.artifacts.isEmpty else { return }
        let metrics = library.indexingMetrics
        let state = "elapsed=\(started.duration(to: .now)) polls=\(polls) artifacts=\(library.artifacts.count) chats=\(library.chats.count) loading=\(library.isLoading) accepted=\(metrics.acceptedSnapshots) batches=\(metrics.batches) parsed=\(metrics.parsedMessages) processing=\(metrics.processingDuration) warning=\(library.warning ?? "<none>")"
        Attachment.record(state, named: "library-publication-readiness.txt")
    }

    @Test func retirementEndsItsCacheSession() {
        let session = ArtifactCache(root: nil).session(scope: .init(
            configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil))
        let library = WorkspaceLibrary(service: RetainedLibraryService(), cache: session)
        #expect(!session.isRetired)
        library.retire()
        #expect(session.isRetired)
    }

    @Test func retirementEndsAJoinedRestorationBeforeItsReadCompletes() async throws {
        let gate = StoreTestBarrier(), control = SavedIndexReadControl()
        control.fails = false; control.gate = gate
        defer { gate.release() }
        let cache = ArtifactCache(root: nil, afterChatLoad: { try await control.load() })
        let library = WorkspaceLibrary(service: RetainedLibraryService(), cache: cache.session(scope: .init(
            configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)))
        let first = Task { await library.restore() }
        defer { first.cancel() }
        try #require(await gate.waitUntilEntered(timeout: .seconds(5)))
        #expect(library.isLoading)
        var secondEntered = false, secondCompleted = false
        let second = Task {
            secondEntered = true
            await library.restore()
            secondCompleted = true
        }
        defer { second.cancel() }
        while !secondEntered { await Task.yield() }
        #expect(control.loads == 1)
        #expect(!secondCompleted)
        library.retire()
        #expect(!library.isLoading)
        gate.release(); await first.value; await second.value
        #expect(secondCompleted)
        await library.restore()
        #expect(library.isRetired && !library.isLoading)
        #expect(control.loads == 1)
        #expect(library.chats.isEmpty && library.artifacts.isEmpty)
        await cache.close()
    }

    @Test(arguments: ["failed-page", "incomplete-page", "repeat-refresh"], [false, true])
    func repeatedPartialPagesCannotResolveRevisionConflicts(sequence: String, working: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let current = service.message("reply", text: "Current reply without the deleted file", at: 20)
        let stale = service.message("reply", text: "Deleted appendix needle\nMEDIA:/deleted.txt", at: 20)
        let resolved = service.message("reply", text: "Approved current reply\nMEDIA:/approved.txt", at: 20)
        let rowID = Data(current.id.utf8), absentDispute = Data("absent-dispute".utf8)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = warmCache.session(scope: scope)
        try await warm.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [current],
            updatedAt: current.timestamp, coverage: .partial, summary: nil, headFingerprint: nil,
            unavailableMessageIDs: [absentDispute]))
        await warmCache.close()
        let control = SavedIndexReadControl(), cache = ArtifactCache(root: root, afterChatLoad: { try await control.load() })
        let session = cache.session(scope: scope), library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); library.observeBots(service.profiles, evidence: .observed); await library.restore()
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [current], isWorking: working), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [stale], nextOffset: sequence == "repeat-refresh" ? nil : 100,
            isComplete: sequence != "repeat-refresh")]
        if sequence == "failed-page" { service.failAtOffset = 100 }
        if sequence == "incomplete-page" { service.pages[source]?[100] = .init(messages: [], nextOffset: nil, isComplete: false) }
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        if sequence == "repeat-refresh" { await library.refresh(evidence: .observed, bots: service.profiles, force: true) }
        #expect(library.chats.isEmpty)
        control.fails = false; await library.restore()
        #expect(library.chats.first?.unverifiedMessageIDs.contains(rowID) == true)
        #expect(library.chats.first?.messages.contains { $0.id == stale.id } == false)
        #expect(LibrarySearchResults(query: "Deleted appendix needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(library.artifacts.isEmpty)
        let savedDeadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().first?.unverifiedMessageIDs?.contains(rowID) != true,
              ContinuousClock.now < savedDeadline { await Task.yield() }
        let saved = try #require(try await session.loadChats().first)
        #expect(saved.unverifiedMessageIDs?.contains(rowID) == true)
        #expect(!saved.messages.contains { $0.id == stale.id })
        #expect(saved.unavailableMessageIDs?.contains(absentDispute) == true)
        library.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root), coldSession = coldCache.session(scope: scope)
        let cold = WorkspaceLibrary(service: service, cache: coldSession)
        await cold.restore(); cold.setOnline(true)
        service.failAtOffset = nil
        service.pages[source] = [0: .init(messages: [stale], nextOffset: nil, isComplete: false)]
        await cold.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(cold.chats.first?.unverifiedMessageIDs.contains(rowID) == true)
        #expect(cold.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "Deleted appendix needle", bots: [], chats: cold.chats, artifacts: []).messages.isEmpty)
        cold.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [resolved]),
            title: "Main", evidence: service.coherentRead(source, messages: [resolved]))
        let resolvedDeadline = ContinuousClock.now + .seconds(5)
        while cold.artifacts.isEmpty, ContinuousClock.now < resolvedDeadline { await Task.yield() }
        #expect(cold.artifacts.contains { $0.artifact.title == "approved.txt" })
        let finalDeadline = ContinuousClock.now + .seconds(5)
        while try await coldSession.loadChats().first?.messages.first?.text != resolved.text,
              ContinuousClock.now < finalDeadline { await Task.yield() }
        let final = try #require(try await coldSession.loadChats().first)
        #expect(final.messages.first?.text == resolved.text)
        #expect(final.unverifiedMessageIDs?.contains(rowID) != true)
        #expect(final.unavailableMessageIDs?.contains(absentDispute) == true)
        cold.retire(); await coldCache.close()
        let reopenedCache = ArtifactCache(root: root), reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(reopened.artifacts.contains { $0.artifact.title == "approved.txt" })
        #expect(reopened.chats.first?.unavailableMessageIDs.contains(absentDispute) == true)
        #expect(LibrarySearchResults(query: "Deleted appendix needle", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: ["rejected", "hidden", "oversized"], [false, true])
    func recoveryHintOnlyIdentitiesRetainNewDisputes(kind: String, removed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let row = service.message("duplicate", text: "Disputed needle\nMEDIA:/disputed.txt", at: 20)
        let rowID = Data(row.id.utf8)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = warmCache.session(scope: scope)
        try await warm.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: removed ? [] : [row],
            updatedAt: row.timestamp, coverage: .partial, summary: nil, headFingerprint: nil,
            removedMessageIDs: removed ? [rowID] : nil))
        try warm.invalidateMetadata([(profile: source.profile, root: source.root, revision: UUID())])
        await warmCache.close()
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.observeBots(service.profiles, evidence: .observed); await library.restore(); library.setOnline(true)
        #expect(library.chats.isEmpty)
        service.summaries = [service.summary(source, at: 20)]
        if kind == "hidden" {
            service.pages[source] = [0: .init(messages: [], nextOffset: nil, isComplete: false, sourceIDs: [rowID])]
        } else {
            service.historyFailure = .init(identity: source, unavailableMessageIDs: kind == "rejected" ? [rowID] : [],
                sourceIDs: kind == "oversized" ? [Data("outside-window".utf8)] : [rowID], exceedsRowLimit: kind == "oversized")
        }
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        service.historyFailure = nil
        let partial = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [row], hasEarlierMessages: true)
        library.accept(identity: source, snapshot: partial, title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        let drained = ContinuousClock.now + .seconds(5)
        while library.indexingMetrics.processingDuration == .zero, ContinuousClock.now < drained { await Task.yield() }
        #expect(library.chats.first?.unavailableMessageIDs.contains(rowID) == true)
        #expect(library.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().first?.unavailableMessageIDs?.contains(rowID) != true,
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await session.loadChats().first?.unavailableMessageIDs?.contains(rowID) == true)
        library.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root), coldSession = coldCache.session(scope: scope)
        let cold = WorkspaceLibrary(service: service, cache: coldSession)
        await cold.restore()
        #expect(cold.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: cold.chats, artifacts: []).messages.isEmpty)
        #expect(cold.chats.first?.unavailableMessageIDs.contains(rowID) == true)
        let full = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [row])
        cold.accept(identity: source, snapshot: full, title: "Main", evidence: service.coherentRead(source, messages: [row]))
        let resolved = ContinuousClock.now + .seconds(5)
        while cold.artifacts.isEmpty, ContinuousClock.now < resolved { await Task.yield() }
        #expect(cold.artifacts.contains { $0.artifact.messageID == row.id })
        let saved = ContinuousClock.now + .seconds(5)
        while try await coldSession.loadChats().first?.messages.first?.text != row.text,
              ContinuousClock.now < saved { await Task.yield() }
        #expect(try await coldSession.loadChats().first?.unavailableMessageIDs?.contains(rowID) != true)
        #expect(try await coldSession.loadChats().first?.messages.first?.text == row.text)
        cold.retire(); await coldCache.close()
    }

    @Test(arguments: [false, true], [false, true])
    func hintFirstRecoveryKeepsRevisionUncertaintySeparate(disputed: Bool, hasEarlier: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let original = service.message("row", text: "Version A\nMEDIA:/same.txt", at: 20)
        let edited = service.message("row", text: "Version B\nMEDIA:/same.txt", at: 20)
        let rowID = Data(original.id.utf8)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = warmCache.session(scope: scope)
        try await warm.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [original],
            updatedAt: original.timestamp, coverage: .partial, summary: nil, headFingerprint: nil,
            unavailableMessageIDs: disputed ? [rowID] : nil))
        try warm.invalidateMetadata([(profile: source.profile, root: source.root, revision: UUID())])
        await warmCache.close()
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.observeBots(service.profiles, evidence: .observed); await library.restore()
        #expect(library.artifacts.isEmpty)
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [edited], hasEarlierMessages: hasEarlier), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        let deadline = ContinuousClock.now + .seconds(5)
        while library.indexingMetrics.processingDuration == .zero, ContinuousClock.now < deadline { await Task.yield() }
        #expect(library.artifacts.contains { $0.artifact.messageID == edited.id } == !disputed)
        #expect(LibrarySearchResults(query: "Version B", bots: [], chats: library.chats, artifacts: []).messages.isEmpty == disputed)
        #expect(library.chats.first?.unavailableMessageIDs.contains(rowID) == disputed)
        let savedDeadline = ContinuousClock.now + .seconds(5)
        while try await session.metadataRecovery().contains(source), ContinuousClock.now < savedDeadline { await Task.yield() }
        #expect(try await !session.metadataRecovery().contains(source))
        let saved = try #require(try await session.loadChats().first)
        #expect(saved.messages.contains { $0.text == edited.text } == !disputed)
        #expect((saved.unavailableMessageIDs?.contains(rowID) == true) == disputed)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root), reopenedSession = reopenedCache.session(scope: scope)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedSession)
        await reopened.restore()
        #expect(reopened.artifacts.contains { $0.artifact.messageID == edited.id } == !disputed)
        #expect(LibrarySearchResults(query: "Version B", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty == disputed)
        reopened.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [edited]),
            title: "Main", evidence: service.coherentRead(source, messages: [edited]))
        let resolved = ContinuousClock.now + .seconds(5)
        while !reopened.artifacts.contains(where: { $0.artifact.messageID == edited.id }), ContinuousClock.now < resolved { await Task.yield() }
        #expect(reopened.artifacts.contains { $0.artifact.messageID == edited.id })
        reopened.retire(); await reopenedCache.close()
    }

    @Test func liveAppendKeepsPreviouslyVerifiedRowsVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let verified = service.message("verified", text: "Verified needle\nMEDIA:/verified.txt", at: 20)
        let appended = service.message("appended", text: "Unverified needle\nMEDIA:/new.txt", at: 30)
        let control = SavedIndexReadControl(), cache = ArtifactCache(root: root, afterChatLoad: { try await control.load() })
        let library = WorkspaceLibrary(service: service, cache: cache.session(scope: .init(configurationID: UUID(),
            serverURL: Data(), installationID: nil, username: Data(), provider: nil)))
        library.setOnline(true); library.observeBots(service.profiles, evidence: .observed); await library.restore()
        let initial = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [verified])
        library.accept(identity: source, snapshot: initial, title: "Main", evidence: service.coherentRead(source, messages: [verified]))
        let deadline = ContinuousClock.now + .seconds(5)
        while library.artifacts.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        let item = try #require(library.artifacts.first)
        let captured = try await library.download(item), downloads = service.downloadCount
        let later = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [verified, appended])
        library.accept(identity: source, snapshot: later, title: "Main", evidence: .incremental(previous: initial))
        #expect(library.artifacts.contains { $0.artifact.messageID == verified.id })
        #expect(!library.artifacts.contains { $0.artifact.messageID == appended.id })
        #expect(!LibrarySearchResults(query: "Verified needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(LibrarySearchResults(query: "Unverified needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(library.isCurrent(item))
        #expect(try await library.download(item).data == captured.data)
        #expect(service.downloadCount == downloads)
        service.summaries = [service.summary(source, at: 30)]
        service.pages[source] = [0: .init(messages: [verified, appended], nextOffset: 100, isComplete: true),
            100: .init(messages: [], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.artifacts.contains { $0.artifact.messageID == verified.id })
        #expect(!library.artifacts.contains { $0.artifact.messageID == appended.id })
        #expect(library.isCurrent(item))
        library.accept(identity: source, snapshot: later, title: "Main", evidence: service.coherentRead(source, messages: later.messages))
        let resolved = ContinuousClock.now + .seconds(5)
        while !library.artifacts.contains(where: { $0.artifact.messageID == appended.id }), ContinuousClock.now < resolved { await Task.yield() }
        #expect(library.artifacts.contains { $0.artifact.messageID == appended.id })
        library.retire(); await cache.close()
    }

    @Test func aCompletePageWithoutIdentityEvidenceCannotResolveADispute() async throws {
        let service = RetainedLibraryService(), source = service.source("main")
        let message = service.message("duplicate", text: "Disputed needle\nMEDIA:/same.txt", at: 20)
        let id = Data(message.id.utf8)
        var snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [message])
        snapshot.unavailableMessageIDs = [id]
        var book = ConversationBook()
        let chat = book.merge(service.summary(source, at: 20)); book.cache(snapshot, for: chat)
        let library = WorkspaceLibrary(service: service)
        library.seed(book: book, bots: service.profiles); await library.restore(); library.setOnline(true)
        service.providesIdentityReads = false
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [message], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.artifacts.isEmpty)
        #expect(library.chats.first?.unavailableMessageIDs.contains(id) == true)
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        service.providesIdentityReads = true
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.artifacts.contains { $0.artifact.messageID == message.id })
        library.retire()
    }

    @Test(arguments: [false, true])
    func anUnprovenHistoryPagePreservesSafeRevisionsDuringRecovery(partial: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let old = service.message("safe", text: "Old version\nMEDIA:/safe.txt", at: 20)
        let fresh = service.message("safe", text: "Fresh version\nMEDIA:/safe.txt", at: 20)
        let disputed = service.message("duplicate", text: "Disputed needle\nMEDIA:/disputed.txt", at: 30)
        let disputedID = Data(disputed.id.utf8)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = warmCache.session(scope: scope)
        try await warm.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [old],
            updatedAt: old.timestamp, coverage: .partial, summary: nil, headFingerprint: nil,
            unavailableMessageIDs: [disputedID]))
        await warmCache.close()
        let control = SavedIndexReadControl(), cache = ArtifactCache(root: root, afterChatLoad: { try await control.load() })
        let session = cache.session(scope: scope), library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); library.observeBots(service.profiles, evidence: .observed); await library.restore()
        service.providesIdentityReads = false
        service.summaries = [service.summary(source, at: 30)]
        if partial {
            service.pages[source] = [0: .init(messages: [old], nextOffset: nil, isComplete: false)]
            await library.refresh(evidence: .observed, bots: service.profiles, force: true)
            #expect(library.chats.isEmpty)
        }
        service.pages[source] = [0: .init(messages: partial ? [fresh] : [fresh, disputed], nextOffset: nil, isComplete: !partial)]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.chats.isEmpty)
        control.fails = false; await library.restore()
        #expect(library.chats.first?.messages.contains { $0.text == fresh.text } == !partial)
        #expect(library.chats.first?.messages.contains { $0.text == old.text } == false)
        #expect(library.chats.first?.unverifiedMessageIDs.contains(Data(old.id.utf8)) == partial)
        #expect(library.chats.first?.unavailableMessageIDs.contains(disputedID) == true)
        #expect(!library.artifacts.contains { $0.artifact.messageID == disputed.id })
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().first.map({ row in
            partial ? row.unverifiedMessageIDs?.contains(Data(old.id.utf8)) == true : row.messages.contains { $0.text == fresh.text }
        }) != true, ContinuousClock.now < deadline { await Task.yield() }
        let saved = try #require(try await session.loadChats().first)
        #expect(saved.messages.contains { $0.text == fresh.text } == !partial)
        #expect(saved.messages.contains { $0.text == old.text } == false)
        #expect((saved.unverifiedMessageIDs?.contains(Data(old.id.utf8)) == true) == partial)
        #expect(saved.unavailableMessageIDs?.contains(disputedID) == true)
        library.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root), coldSession = coldCache.session(scope: scope)
        let cold = WorkspaceLibrary(service: service, cache: coldSession)
        await cold.restore()
        #expect(cold.chats.first?.messages.contains { $0.text == fresh.text } == !partial)
        #expect(cold.chats.first?.messages.contains { $0.text == old.text } == false)
        #expect(cold.chats.first?.unverifiedMessageIDs.contains(Data(old.id.utf8)) == partial)
        #expect(cold.chats.first?.unavailableMessageIDs.contains(disputedID) == true)
        if partial {
            cold.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [fresh]),
                title: "Main", evidence: service.coherentRead(source, messages: [fresh]))
            let resolved = ContinuousClock.now + .seconds(5)
            while try await coldSession.loadChats().first?.messages.first?.text != fresh.text,
                  ContinuousClock.now < resolved { await Task.yield() }
            #expect(cold.chats.first?.messages.first?.text == fresh.text)
            #expect(try await coldSession.loadChats().first?.messages.first?.text == fresh.text)
            #expect(try await coldSession.loadChats().first?.unavailableMessageIDs?.contains(disputedID) == true)
        }
        cold.retire(); await coldCache.close()
    }

    @Test func coherentReadsResolveOnlyTheirObservedMessageIDs() throws {
        let service = RetainedLibraryService(), source = service.source("main")
        let disputed = service.message("duplicate", text: "Disputed needle", at: 20)
        let safe = service.message("safe", text: "Safe content", at: 30)
        let disputedID = Data(disputed.id.utf8)
        var snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [disputed, safe])
        snapshot.unavailableMessageIDs = [disputedID]
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 30)); book.cache(snapshot, for: id)
        book.cache(.init(messages: [safe], hasEarlierMessages: false), for: id)
        #expect(book.record(id)?.transcript?.unavailableMessageIDs?.contains(disputedID) == true)
        book.cache(snapshot, for: id)
        snapshot.unavailableMessageIDs = nil
        let issuer = ConversationIssuer<SessionIdentity>(), access = try issuer.issue(source)
        let incompleteProof = OpenedConversation(identity: source, snapshot: snapshot, access: access,
            historyReadStartedAt: .now, observedSource: source,
            identityRead: .init(identity: source, messageIDs: [Data(safe.id.utf8)]))
        let retained = book.cache(incompleteProof, for: id)
        #expect(!TranscriptMessageIndex(retained.snapshot).matches(disputed))
        let foreign = SessionIdentity(profile: source.profile, root: try ExactID("other-root"), stored: source.stored, aliases: [])
        let wrongScope = OpenedConversation(identity: source, snapshot: snapshot, access: access,
            historyReadStartedAt: .now, observedSource: source,
            identityRead: .init(identity: foreign, messageIDs: [disputedID]))
        #expect(!TranscriptMessageIndex(book.cache(wrongScope, for: id).snapshot).matches(disputed))
        let resolving = OpenedConversation(identity: source, snapshot: snapshot, access: access,
            historyReadStartedAt: .now, observedSource: source,
            identityRead: .init(identity: source, messageIDs: [disputedID, Data(safe.id.utf8)]))
        #expect(TranscriptMessageIndex(book.cache(resolving, for: id).snapshot).matches(disputed))
    }

    @Test(arguments: [true, false])
    func coherentDisplayCannotOverwriteAnUnreadAbsentDispute(guarded: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let disputed = service.message("duplicate", text: "Disputed needle\nMEDIA:/disputed.txt", at: 20)
        let safe = service.message("safe", text: "Safe content\nMEDIA:/safe.txt", at: 30)
        let disputedID = Data(disputed.id.utf8)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil,
            username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = warmCache.session(scope: scope)
        try await warm.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [safe],
            updatedAt: safe.timestamp, coverage: .partial, summary: nil, headFingerprint: nil,
            unavailableMessageIDs: [disputedID]))
        await warmCache.close()
        let control = SavedIndexReadControl(), cache = ArtifactCache(root: root, afterChatLoad: { try await control.load() })
        let session = cache.session(scope: scope), library = WorkspaceLibrary(service: service, cache: session)
        let inspectorCache = ArtifactCache(root: root), inspector = inspectorCache.session(scope: scope)
        library.setOnline(true); library.observeBots(service.profiles, evidence: .observed); await library.restore()
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [safe], hasEarlierMessages: true), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        let prepared = ContinuousClock.now + .seconds(5)
        while library.indexingMetrics.processingDuration == .zero, ContinuousClock.now < prepared { await Task.yield() }
        if guarded { try inspector.invalidateMetadata([(profile: source.profile, root: source.root, revision: UUID())]) }
        service.summaries = [service.summary(source, at: 30)]
        service.pages[source] = [0: .init(messages: [safe], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.artifacts.contains { $0.artifact.messageID == safe.id })
        if guarded { #expect(try await inspector.metadataRecovery().contains(source)) }
        else { #expect(try await service.savedUnavailableIDs(inspector, for: source).contains(disputedID)) }
        let partial = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [disputed, safe], hasEarlierMessages: true)
        library.accept(identity: source, snapshot: partial, title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        #expect(!library.artifacts.contains { $0.artifact.messageID == disputed.id })
        control.fails = false; await library.restore()
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().first?.unavailableMessageIDs?.contains(disputedID) != true,
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(!library.artifacts.contains { $0.artifact.messageID == disputed.id })
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        library.retire(); await cache.close(); await inspectorCache.close()
        let reopenedCache = ArtifactCache(root: root), reopenedSession = reopenedCache.session(scope: scope)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedSession)
        await reopened.restore()
        #expect(try await reopenedSession.loadChats().first?.unavailableMessageIDs?.contains(disputedID) == true)
        #expect(!reopened.artifacts.contains { $0.artifact.messageID == disputed.id })
        let full = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [disputed, safe])
        reopened.accept(identity: source, snapshot: full, title: "Main", evidence: .read(startedAt: .now, observedSource: source,
            identityRead: .init(identity: source, messageIDs: Set(full.messages.map { Data($0.id.utf8) }))))
        let resolvedDeadline = ContinuousClock.now + .seconds(5)
        while !reopened.artifacts.contains(where: { $0.artifact.messageID == disputed.id }),
              ContinuousClock.now < resolvedDeadline { await Task.yield() }
        #expect(reopened.artifacts.contains { $0.artifact.messageID == disputed.id })
        reopened.retire(); await reopenedCache.close()
    }

    @Test func movingOffsetPagesCannotResolveAnUnreadSavedDispute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let disputed = service.message("duplicate", text: "Disputed needle\nMEDIA:/disputed.txt", at: 900)
        var newest = (0..<201).map { service.message("row-" + String($0), text: "Content " + String($0), at: Double(1000 - $0)) }
        newest[99] = disputed; newest[100] = disputed
        let moved = Array(newest.dropFirst())
        let first = Array(newest.prefix(100).reversed()), second = Array(moved.dropFirst(100).prefix(100).reversed())
        #expect(moved.filter { $0.id == disputed.id }.count == 2)
        #expect((first + second).filter { $0.id == disputed.id }.count == 1)
        #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = warmCache.session(scope: scope)
        try await warm.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [], updatedAt: nil,
            coverage: .partial, summary: nil, headFingerprint: nil, unavailableMessageIDs: [Data(disputed.id.utf8)]))
        await warmCache.close()
        let control = SavedIndexReadControl(), cache = ArtifactCache(root: root, afterChatLoad: { try await control.load() })
        let library = WorkspaceLibrary(service: service, cache: cache.session(scope: scope))
        library.setOnline(true); library.observeBots(service.profiles, evidence: .observed); await library.restore()
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [disputed], hasEarlierMessages: true), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        let drainDeadline = ContinuousClock.now + .seconds(5)
        while library.indexingMetrics.processingDuration == .zero, ContinuousClock.now < drainDeadline { await Task.yield() }
        service.summaries = [service.summary(source, at: 1000)]
        service.pages[source] = [0: .init(messages: first, nextOffset: 100, isComplete: true),
            100: .init(messages: second, nextOffset: 200, isComplete: true),
            200: .init(messages: [], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(!library.artifacts.contains { $0.artifact.messageID == disputed.id })
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        let inspectorCache = ArtifactCache(root: root), inspector = inspectorCache.session(scope: scope)
        #expect(try await service.savedUnavailableIDs(inspector, for: source).contains(Data(disputed.id.utf8)))
        control.fails = false; await library.restore()
        #expect(!library.artifacts.contains { $0.artifact.messageID == disputed.id })
        library.retire(); await cache.close(); await inspectorCache.close()
    }

    @Test func unchangedReseedingKeepsCoherentResultsVisibleDuringStorageFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let message = service.message("safe", text: "Safe content\nMEDIA:/safe.txt", at: 30)
        let summary = SessionSummary(identity: source, title: "Main", isCanonical: false, persistence: .durable,
            preview: message.text, updatedAt: message.timestamp, messageCount: 1)
        service.summaries = [summary]
        service.pages[source] = [0: .init(messages: [message], nextOffset: nil, isComplete: true)]
        let control = SavedIndexReadControl(), cache = ArtifactCache(root: root, afterChatLoad: { try await control.load() })
        var clock = ContinuousClock.now
        let library = WorkspaceLibrary(service: service, cache: cache.session(scope: .init(configurationID: UUID(),
            serverURL: Data(), installationID: nil, username: Data(), provider: nil)), now: { clock })
        library.setOnline(true); library.observeBots(service.profiles, evidence: .observed); await library.restore()
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [message], hasEarlierMessages: true), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        let prepared = ContinuousClock.now + .seconds(5)
        while library.indexingMetrics.processingDuration == .zero, ContinuousClock.now < prepared { await Task.yield() }
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.artifacts.contains { $0.artifact.messageID == message.id })
        var book = ConversationBook()
        let id = book.merge(summary)
        book.cache(Conversation(id: "main", storedID: "main", profileID: "helper", messages: [message]), for: id)
        for advance in [false, true] {
            if advance { clock = clock.advanced(by: .seconds(61)) }
            library.seed(book: book, bots: service.profiles)
            await library.refreshIfNeeded(evidence: .observed, bots: service.profiles)
            #expect(library.artifacts.contains { $0.artifact.messageID == message.id })
            #expect(!LibrarySearchResults(query: "Safe content", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        }
        #expect(service.historyReads == 1)
        library.retire(); await cache.close()
    }

    @Test(arguments: [true, false])
    func failedRestorationKeepsSeedsAndDirectoryObservationsGated(seed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let disputed = service.message("duplicate", text: "Disputed needle\nMEDIA:/disputed.txt", at: 20)
        let safe = service.message("safe", text: "Safe content\nMEDIA:/safe.txt", at: 30)
        let disputedID = Data(disputed.id.utf8)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil,
            username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = warmCache.session(scope: scope)
        try await warm.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [safe],
            updatedAt: safe.timestamp, coverage: .partial, summary: nil, headFingerprint: nil,
            unavailableMessageIDs: [disputedID]))
        await warmCache.close()
        let control = SavedIndexReadControl(), restoreGate = StoreTestBarrier(), historyGate = StoreTestBarrier()
        defer { restoreGate.release(); historyGate.release() }
        let cache = ArtifactCache(root: root, afterChatLoad: { try await control.load() })
        let library = WorkspaceLibrary(service: service, cache: cache.session(scope: scope))
        library.observeBots(service.profiles, evidence: .observed)
        await library.restore()
        #expect(library.chats.isEmpty)
        control.gate = restoreGate
        let snapshot = Conversation(id: "main", storedID: "main", profileID: "helper",
            messages: [disputed, safe], hasEarlierMessages: true)
        if seed {
            var book = ConversationBook()
            let id = book.merge(service.summary(source, at: 30)); book.cache(snapshot, for: id)
            library.seed(book: book, bots: service.profiles)
        } else {
            library.accept(identity: source, snapshot: snapshot, title: "Main",
                evidence: .read(startedAt: .now, observedSource: source))
        }
        service.summaries = [service.summary(source, at: 30)]
        service.gatedOffset = 0; service.gate = historyGate; service.failAtOffset = 0
        library.setOnline(true)
        let retry = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        defer { retry.cancel() }
        try #require(await restoreGate.waitUntilEntered(timeout: .seconds(5)))
        #expect(library.chats.isEmpty && library.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        restoreGate.release()
        try #require(await historyGate.waitUntilEntered(timeout: .seconds(5)))
        #expect(library.chats.isEmpty && library.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        historyGate.release(); await retry.value
        #expect(library.chats.isEmpty && library.artifacts.isEmpty)
        let inspectorCache = ArtifactCache(root: root), inspector = inspectorCache.session(scope: scope)
        #expect(try await service.savedUnavailableIDs(inspector, for: source).contains(disputedID))
        service.gatedOffset = nil; service.failAtOffset = nil
        service.pages[source] = [0: .init(messages: [disputed, safe], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.artifacts.contains { $0.artifact.messageID == disputed.id })
        #expect(!LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(try await service.savedUnavailableIDs(inspector, for: source).contains(disputedID))
        control.fails = false; await library.restore()
        #expect(library.artifacts.contains { $0.artifact.messageID == disputed.id })
        let savedDeadline = ContinuousClock.now + .seconds(5)
        while try await service.savedUnavailableIDs(inspector, for: source).contains(disputedID),
              ContinuousClock.now < savedDeadline { await Task.yield() }
        #expect(try await !service.savedUnavailableIDs(inspector, for: source).contains(disputedID))
        library.retire(); await cache.close(); await inspectorCache.close()
    }

    @Test func failedRestorationDefersSafeRevisionUntilItCanBeSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let original = service.message("safe", text: "Version A\nMEDIA:/same.txt", at: 20)
        let edited = service.message("safe", text: "Version B\nMEDIA:/same.txt", at: 20)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil,
            username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = warmCache.session(scope: scope)
        try await warm.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [original],
            updatedAt: original.timestamp, coverage: .partial, summary: nil, headFingerprint: nil))
        await warmCache.close()
        let control = SavedIndexReadControl()
        let cache = ArtifactCache(root: root, afterChatLoad: { try await control.load() })
        let session = cache.session(scope: scope), library = WorkspaceLibrary(service: service, cache: session)
        library.observeBots(service.profiles, evidence: .observed)
        await library.restore()
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [edited], hasEarlierMessages: true), title: "Main",
            evidence: .read(startedAt: .now, observedSource: source))
        let drainDeadline = ContinuousClock.now + .seconds(5)
        while library.indexingMetrics.processingDuration == .zero, ContinuousClock.now < drainDeadline { await Task.yield() }
        try #require(library.indexingMetrics.processingDuration != .zero)
        await library.restore()
        #expect(library.chats.isEmpty)
        #expect(library.indexingMetrics.pendingMetadataIdentities > 0)
        control.fails = false
        await library.restore()
        let savedDeadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().first?.messages.first?.text != edited.text,
              ContinuousClock.now < savedDeadline { await Task.yield() }
        #expect(try await session.loadChats().first?.messages.first?.text == edited.text)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(reopened.chats.first?.messages.first?.text == edited.text)
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: [true, false])
    func partialStartupReadsCannotOverrideSavedDisputes(incremental: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let disputed = service.message("duplicate", text: "Disputed needle\nMEDIA:/disputed.txt", at: 20)
        let safe = service.message("safe", text: "Old safe revision\nMEDIA:/safe.txt", at: 30)
        let disputedID = Data(disputed.id.utf8)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil,
            username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warmSession = warmCache.session(scope: scope)
        try await warmSession.upsert(.init(identity: source, botName: "Helper", title: "Main",
            messages: [safe], updatedAt: safe.timestamp, coverage: .partial, summary: nil, headFingerprint: nil,
            unavailableMessageIDs: [disputedID]))
        await warmCache.close()
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 30))
        book.cache(Conversation(id: "main", storedID: "main", profileID: "helper", messages: [disputed, safe]), for: id)
        let gate = StoreTestBarrier(), pause = FirstProjectionPause()
        defer { gate.release() }
        let cache = ArtifactCache(root: root, afterChatLoad: { if await pause.take() { await gate.wait() } })
        let session = cache.session(scope: scope), library = WorkspaceLibrary(service: service, cache: session)
        library.seed(book: book, bots: service.profiles)
        let restoring = Task { await library.restore() }
        defer { restoring.cancel() }
        try #require(await gate.waitUntilEntered(timeout: .seconds(5)))
        let edited = service.message("safe", text: "Fresh safe revision\nMEDIA:/safe.txt", at: 30)
        var partial = Conversation(id: "main", storedID: "main", profileID: "helper",
            messages: [disputed, edited], hasEarlierMessages: true)
        library.accept(identity: source, snapshot: partial, title: "Main",
            evidence: .read(startedAt: .now, observedSource: source))
        if incremental {
            let baseline = partial
            partial.messages[1] = service.message("safe", text: "Latest safe revision\nMEDIA:/safe.txt", at: 30)
            library.accept(identity: source, snapshot: partial, title: "Main", evidence: .incremental(previous: baseline))
        }
        #expect(library.chats.isEmpty)
        #expect(library.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        gate.release(); await restoring.value
        let expected = partial.messages[1].text
        let query = String(expected.prefix { $0 != "\n" })
        let deadline = ContinuousClock.now + .seconds(5)
        while LibrarySearchResults(query: query, bots: [], chats: library.chats, artifacts: []).messages.isEmpty,
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(!LibrarySearchResults(query: query, bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(!library.artifacts.contains { $0.artifact.messageID == disputed.id })
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        let savedDeadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().first?.messages.first(where: { $0.id == "safe" })?.text != expected,
              ContinuousClock.now < savedDeadline { await Task.yield() }
        #expect(try await session.loadChats().first?.unavailableMessageIDs?.contains(disputedID) == true)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root), reopenedSession = reopenedCache.session(scope: scope)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedSession)
        await reopened.restore()
        #expect(!reopened.artifacts.contains { $0.artifact.messageID == disputed.id })
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        #expect(reopened.chats.first?.messages.first(where: { $0.id == "safe" })?.text == expected)
        partial.hasEarlierMessages = false
        reopened.accept(identity: source, snapshot: partial, title: "Main",
            evidence: service.coherentRead(source, messages: partial.messages))
        let resolvedDeadline = ContinuousClock.now + .seconds(5)
        while !reopened.artifacts.contains(where: { $0.artifact.messageID == disputed.id }),
              ContinuousClock.now < resolvedDeadline { await Task.yield() }
        #expect(reopened.artifacts.contains { $0.artifact.messageID == disputed.id })
        #expect(!LibrarySearchResults(query: "Disputed needle", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        let persistedResolution = ContinuousClock.now + .seconds(5)
        while try await reopenedSession.loadChats().first?.messages.contains(where: { $0.id == disputed.id }) != true,
              ContinuousClock.now < persistedResolution { await Task.yield() }
        #expect(try await reopenedSession.loadChats().first?.unavailableMessageIDs?.contains(disputedID) != true)
        #expect(try await reopenedSession.loadChats().first?.messages.contains(where: { $0.id == disputed.id }) == true)
        reopened.retire(); await reopenedCache.close()
    }

    @Test(arguments: [true, false])
    func incompletePublicationsReplaceSafeRevisions(read: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let original = service.message("current", text: "Version A\nMEDIA:/same.txt", at: 20)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [original], nextOffset: nil, isComplete: true)]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil,
            username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        var prior = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [original])
        var item = try #require(library.artifacts.first)
        _ = try await library.download(item)
        for version in ["B", "C"] {
            let edited = service.message("current", text: "Version " + version + "\nMEDIA:/same.txt", at: 20)
            let snapshot = Conversation(id: "main", storedID: "main", profileID: "helper",
                messages: [edited], hasEarlierMessages: read)
            let old = item
            library.accept(identity: source, snapshot: snapshot, title: "Main",
                evidence: read ? .read(startedAt: .now, observedSource: source) : .incremental(previous: prior))
            #expect(!library.isCurrent(old))
            let deadline = ContinuousClock.now + .seconds(5)
            while LibrarySearchResults(query: "Version " + version, bots: [], chats: library.chats, artifacts: []).messages.isEmpty,
                  ContinuousClock.now < deadline { await Task.yield() }
            #expect(!LibrarySearchResults(query: "Version " + version, bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
            #expect(LibrarySearchResults(query: prior.messages[0].text, bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
            item = try #require(library.artifacts.first)
            #expect(item.chat.messages.first?.text == edited.text)
            #expect(item.chat.sourceRevisions[Data(edited.id.utf8)] != old.chat.sourceRevisions[Data(edited.id.utf8)])
            library.setOnline(false)
            await #expect(throws: (any Error).self) { _ = try await library.download(item) }
            library.setOnline(true)
            let savedDeadline = ContinuousClock.now + .seconds(5)
            while try await session.loadChats().first?.messages.first?.text != edited.text,
                  ContinuousClock.now < savedDeadline { await Task.yield() }
            #expect(try await session.loadChats().first?.messages.first?.text == edited.text)
            prior = snapshot
        }
        library.retire(); await cache.close()
    }

    @Test func unchangedLivePublicationPreservesCompleteLibraryCoverage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let message = service.message("current", text: "MEDIA:/same.txt", at: 20)
        service.summaries = [.init(identity: source, title: "Main", isCanonical: false, persistence: .durable,
            preview: message.text, updatedAt: Date(timeIntervalSince1970: 20), messageCount: 1)]
        service.pages[source] = [0: .init(messages: [message], nextOffset: nil, isComplete: true)]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil,
            username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(try await session.loadChats().first?.coverage == .complete)
        let snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [message])
        library.accept(identity: source, snapshot: snapshot, title: "Changed title",
            evidence: .incremental(previous: snapshot))
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().first?.title != "Changed title",
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(library.warning == nil)
        #expect(try await session.loadChats().first?.coverage == .complete)
        let reads = service.historyReads
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyReads == reads)
        library.retire(); await cache.close()
    }

    @Test(arguments: [true, false])
    func libraryKeepsItsOwnDisputesAcrossIncompletePublications(read: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let disputed = service.message("duplicate", text: "Disputed needle\n```html\n<h1>Disputed cover</h1>\n```", at: 20)
        let retained = service.message("retained", text: "MEDIA:/retained.txt", at: 30)
        let disputedID = Data(disputed.id.utf8)
        var snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [disputed, retained])
        snapshot.unavailableMessageIDs = [disputedID]
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 30)); book.cache(snapshot, for: id)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil,
            username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.seed(book: book, bots: service.profiles); await library.restore()
        let marker = service.message("partial-marker", text: "Incomplete publication marker", at: 40)
        let partial = Conversation(id: "main", storedID: "main", profileID: "helper",
            messages: [disputed, retained, marker], hasEarlierMessages: read)
        library.accept(identity: source, snapshot: partial, title: "Main",
            evidence: read ? .read(startedAt: .now, observedSource: source) : .incremental(previous: snapshot))
        let deadline = ContinuousClock.now + .seconds(5)
        while LibrarySearchResults(query: marker.text, bots: [], chats: library.chats, artifacts: []).messages.isEmpty,
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(!LibrarySearchResults(query: marker.text, bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(library.chats.first?.unavailableMessageIDs.contains(disputedID) == true)
        #expect(!library.artifacts.contains { $0.artifact.messageID == disputed.id })
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        let savedDeadline = ContinuousClock.now + .seconds(5)
        var persisted = false
        while ContinuousClock.now < savedDeadline {
            if let saved = try await session.loadChats().first,
               saved.messages.contains(where: { $0.id == marker.id }),
               saved.unavailableMessageIDs?.contains(disputedID) == true {
                persisted = true; break
            }
            await Task.yield()
        }
        #expect(persisted)
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [disputed, retained]), title: "Main", evidence: service.coherentRead(source, messages: [disputed, retained]))
        let resolvedDeadline = ContinuousClock.now + .seconds(5)
        while !library.artifacts.contains(where: { $0.artifact.messageID == disputed.id }),
              ContinuousClock.now < resolvedDeadline { await Task.yield() }
        #expect(library.artifacts.contains { $0.artifact.messageID == disputed.id })
        #expect(!LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        library.retire(); await cache.close()
    }

    @Test func incompleteLiveReadsPreserveDisputesUntilAnExhaustiveReadResolvesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://incomplete-history.invalid")!)
        let service = try WorkspaceTestService(), source = service.summaries[0].identity
        let bot = BotProfile(id: service.profile.text, name: "Milo")
        let disputed = ChatMessage(id: "duplicate", role: .assistant,
            text: "Disputed needle\n```html\n<h1>Disputed cover</h1>\n```", timestamp: .init(timeIntervalSince1970: 20))
        let retained = ChatMessage(id: "retained", role: .assistant, text: "MEDIA:/retained.txt")
        let disputedID = Data(disputed.id.utf8)
        var snapshot = Conversation(id: "cached", storedID: source.stored.text, profileID: service.profile.text,
            messages: [disputed, retained])
        snapshot.unavailableMessageIDs = [disputedID]
        var history = LocalHistory(bots: [bot])
        let id = history.book.merge(service.summaries[0]); history.book.cache(snapshot, for: id)
        history.book.cache(.init(messages: [disputed, retained], hasEarlierMessages: true), for: id)
        history.book.update(id) { $0.draft = .init(text: "Keep my draft", revision: UUID()) }
        try history.save(for: configuration.id)
        let cache = ArtifactCache(root: root)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence,
            artifactCache: cache)
        defer {
            store.forgetConnection(); LocalHistory.remove(for: configuration.id)
            try? FileManager.default.removeItem(at: root)
        }
        var readStartedAt = ContinuousClock.now
        service.onOpen = { readStartedAt = .now }
        service.openResult = { publication in
            .init(identity: publication.identity, snapshot: publication.snapshot, access: publication.access,
                readEvidence: publication.snapshot.hasEarlierMessages ? nil : publication.readEvidence,
                activity: publication.activity, historyReadStartedAt: readStartedAt, observedSource: publication.identity,
                identityRead: publication.snapshot.hasEarlierMessages ? nil : .init(identity: publication.identity,
                    messageIDs: Set(publication.snapshot.messages.map { Data($0.id.utf8) })))
        }
        service.previewUnavailable = true
        #expect(await store.connect(configuration))
        await store.library.restore()

        for stage in ["attachment", "incremental", "foreground", "complete"] {
            let marker = ChatMessage(id: stage, role: .assistant, text: "History stage " + stage)
            service.snapshots[source.root]?.messages = [disputed, retained, marker]
            service.snapshots[source.root]?.hasEarlierMessages = stage != "complete" && stage != "incremental"
            if stage == "incremental" {
                service.onEvent?(.conversation(try service.publication(source)))
            } else if stage == "foreground" {
                service.summaries[0] = .init(identity: source, title: "Main", isCanonical: true, persistence: .durable,
                    preview: "A newer observation", messageCount: 8)
                let before = try #require(store.chats.screen(profile: service.profile))
                await store.chats.refreshDirectory(before.owner)
                let gate = WorkspaceGate(); service.openGate = gate
                store.chats.setTranscriptVisible(true, owner: try #require(store.chats.screen(profile: service.profile)?.owner))
                await gate.entered(); gate.release()
                let deadline = ContinuousClock.now + .seconds(5)
                while store.chats.screen(profile: service.profile)?.isOpening == true, ContinuousClock.now < deadline {
                    await Task.yield()
                }
                service.openGate = nil
            } else { await store.open(bot) }
            let deadline = ContinuousClock.now + .seconds(5)
            while LibrarySearchResults(query: marker.text, bots: [], chats: store.library.chats, artifacts: []).messages.isEmpty,
                  ContinuousClock.now < deadline { await Task.yield() }
            #expect(!LibrarySearchResults(query: marker.text, bots: [], chats: store.library.chats, artifacts: []).messages.isEmpty)
            let screen = try #require(store.chats.screen(profile: service.profile))
            let index = TranscriptMessageIndex(screen.snapshot)
            let complete = stage == "complete"
            #expect(index.matches(disputed) == complete)
            #expect(screen.hasEarlierMessages == !complete)
            #expect(screen.canAct && store.chats.draft(screen.owner) == "Keep my draft")
            #expect(store.library.artifacts.contains(where: { $0.artifact.messageID == disputed.id }) == complete)
            #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: store.library.chats,
                artifacts: []).messages.isEmpty == !complete)
            #expect(store.flush())
            let saved = try LocalHistory.load(for: configuration.id)
            let savedIndex = TranscriptMessageIndex(saved.book.record(id)?.transcript)
            #expect(savedIndex.matches(disputed) == complete)
        }
        #expect(service.opens.count == 3 && service.sends.isEmpty)
        store.forgetConnection(); await cache.close()
    }

    @Test(arguments: [true, false])
    func partialWindowsCannotResolveADuplicateOutsideTheirFetchedRows(joined: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let older = service.message("older", text: "Earlier history", at: 5)
        let anchor = service.message("anchor", text: "A unique anchor", at: 10)
        let disputed = service.message("duplicate", text: "Disputed needle\n```html\n<h1>Disputed cover</h1>\n```", at: 20)
        let retained = service.message("retained", text: "MEDIA:/retained.txt", at: 30)
        let disputedID = Data(disputed.id.utf8)
        var snapshot = Conversation(id: "main", storedID: "main", profileID: "helper",
            messages: [older, anchor, disputed, retained])
        snapshot.unavailableMessageIDs = [disputedID]
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 30)); book.cache(snapshot, for: id)
        book.cache(.init(messages: joined ? [anchor, disputed, retained] : [disputed, retained],
            hasEarlierMessages: true), for: id)
        let saved = try JSONDecoder().decode(ConversationBook.self, from: JSONEncoder().encode(book))
        let index = TranscriptMessageIndex(saved.record(id)?.transcript)
        #expect(!index.matches(disputed))
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil,
            username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), library = WorkspaceLibrary(service: service, cache: cache.session(scope: scope))
        library.seed(book: saved, bots: service.profiles); await library.restore()
        #expect(library.artifacts.map(\.artifact.title) == ["retained.txt"])
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(library.chats.first?.unavailableMessageIDs.contains(disputedID) == true)
        book.cache(.init(messages: [disputed, retained], hasEarlierMessages: false,
            identityRead: .init(identity: source, messageIDs: [disputedID, Data(retained.id.utf8)])), for: id)
        let resolved = try #require(book.record(id)?.transcript)
        #expect(TranscriptMessageIndex(resolved).matches(disputed))
        library.accept(identity: source, snapshot: resolved, title: "Main",
            evidence: service.coherentRead(source, messages: resolved.messages))
        let deadline = ContinuousClock.now + .seconds(5)
        while (LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty
               || !library.artifacts.contains(where: { $0.artifact.messageID == disputed.id })),
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(!LibrarySearchResults(query: "Disputed needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        #expect(library.artifacts.contains { $0.artifact.messageID == disputed.id })
        library.retire(); await cache.close()
    }

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
        let service = RetainedLibraryService(), transport = StoreTestBarrier()
        let pause = BudgetProjectionPause()
        defer { transport.release(); pause.release() }
        let source = service.source("background"), active = service.source("active")
        let kept = service.message("kept", text: "MEDIA:/kept.txt", at: 20)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("older", text: "Ordinary older row", at: 10), kept],
            nextOffset: nil, isComplete: true)]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, limits: .init(messageCount: 3), cache: session, projector: { messages, tail in
            if messages.contains(where: { $0.id == kept.id }) { await pause.waitIfArmed() }
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
        await transport.waitUntilEntered(); pause.arm()
        library.accept(identity: active,
            snapshot: .init(id: "active", storedID: "active", profileID: "helper", messages: [
                service.message("active-1", text: "First new row", at: 30),
                service.message("active-2", text: "Working new row", at: 40)], isWorking: true),
            title: "Active", evidence: .read(startedAt: .now, observedSource: active))
        #expect(library.isCurrent(item))
        #expect(library.chats.first { $0.identity == source }?.messages.map(\.id) == [kept.id])
        var deadline = ContinuousClock.now + .seconds(5)
        while !pause.wasTaken, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(pause.wasTaken, "The trimmed non-target chat needs its own scheduled projection.")
        let registered = library.indexingMetrics.galleryConsumersRegistered
        let second = Task { let result = try await library.download(item); completions += 1; return result }
        defer { second.cancel() }
        deadline = .now + .seconds(5)
        while library.indexingMetrics.galleryConsumersRegistered == registered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(library.indexingMetrics.galleryConsumersRegistered == registered + 1)
        #expect(service.downloadCount == 1, "The second gallery consumer joined the held original flight.")
        service.downloadGate = nil; transport.release()
        _ = try await session.loadChats()
        #expect(completions == 0, "Both gallery readers wait for current provenance without blocking the cache actor.")
        pause.release()
        deadline = .now + .seconds(5)
        while completions < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(completions == 2)
        #expect(try await first.value.data == service.downloadedBytes)
        #expect(try await second.value.data == service.downloadedBytes)
        library.retire(); await cache.close()
        let reopened = ArtifactCache(root: root)
        #expect(try await reopened.session(scope: scope).original(for: key)?.artifact.data == service.downloadedBytes)
        await reopened.close()
    }

    @Test(arguments: [false, true])
    func projectionTeardownReleasesCancelledWorkersBeforeOrAfterEntry(lateEntry: Bool) async throws {
        let pause = BudgetProjectionPause()
        pause.arm()
        var completed = false
        let worker = Task {
            await pause.waitIfArmed()
            #expect(Task.isCancelled, "The control must exercise a cancelled projection worker.")
            completed = true
        }
        defer { worker.cancel(); pause.release() }
        if lateEntry {
            #expect(!pause.wasTaken, "The cancelled worker must enter only after teardown releases the pause.")
        } else {
            let deadline = ContinuousClock.now + .seconds(3)
            while !pause.wasTaken, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(pause.wasTaken)
        }
        worker.cancel()
        pause.release()
        let deadline = ContinuousClock.now + .seconds(3)
        while !completed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(completed, "Teardown must release an entered or late cancelled projection worker.")
        if completed { await worker.value }
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
        while !gate.isEntered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while service.historyReads < reads + 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while !peerCompleted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        let anchor = service.message("anchor", text: "Current suffix", at: 30)
        var snapshot = Conversation(id: "main", storedID: "main", profileID: "helper", messages: [retained, disputed, anchor])
        snapshot.unavailableMessageIDs = [repeated]
        var book = ConversationBook()
        let id = book.merge(service.summary(source, at: 20)); book.cache(snapshot, for: id)
        book.cache(.init(messages: [anchor], hasEarlierMessages: true), for: id)
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
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try await session.loadChats().first?.unavailableMessageIDs?.contains(repeated) == true)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        reopened.seed(book: savedBook, bots: service.profiles); await reopened.restore()
        #expect(reopened.artifacts.map(\.artifact.title) == ["retained.txt"])
        #expect(LibrarySearchResults(query: "Disputed needle", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        #expect(service.historyReads == 0 && service.downloadCount == 0)
        snapshot.unavailableMessageIDs = nil
        reopened.accept(identity: source, snapshot: snapshot, title: "Main", evidence: service.coherentRead(source, messages: snapshot.messages))
        let recoveryDeadline = ContinuousClock.now + .seconds(5)
        while !reopened.artifacts.contains(where: { $0.artifact.messageID == disputed.id }),
              ContinuousClock.now < recoveryDeadline { try await Task.sleep(for: .milliseconds(5)) }
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
                  ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while service.historyReads < reads + 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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

    @Test func forcedReloadReportsBytesTheCacheRefusesWhileOrdinaryReadStillReturnsThem() async throws {
        let service = RetainedLibraryService(), source = service.source("main")
        var limits = ArtifactCache.Limits()
        limits.singleOriginalBytes = 4
        let library = WorkspaceLibrary(service: service, cache: ArtifactCache(root: nil, limits: limits).session(scope: .init(
            configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)))
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [service.message("report", text: "MEDIA:/report.txt", at: 20)], nextOffset: nil, isComplete: true)]
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let item = try #require(library.artifacts.first)
        service.downloadedBytes = Data("larger than the single original limit".utf8)

        let failure = await #expect(throws: (any Error).self) { try await library.download(item, force: true) }
        #expect(failure?.localizedDescription == "The refreshed file couldn’t be saved on this device. Try again.")
        #expect(try await library.download(item).data == service.downloadedBytes)
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
        while reader.file == nil || reader.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let captured = try #require(reader.file)
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        service.downloadedBytes = Data("new host bytes".utf8)
        reader.reload()
        deadline = .now + .seconds(5)
        while reader.errorMessage == nil || reader.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        defer { library.retire() }
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
        try await waitForInitialLibraryArtifacts(library)
        let item = try #require(library.artifacts.first)
        let duplicate = ChatMessage(id: output.id, role: .assistant, text: "Second occurrence", isSilent: hidden)
        accept([duplicate, output])
        var deadline = ContinuousClock.now + .seconds(5)
        while library.chats.first?.unavailableMessageIDs.contains(Data(output.id.utf8)) != true,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(library.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "Cover needle", bots: [], chats: library.chats, artifacts: []).messages.isEmpty)
        var rendered = false
        #expect(await library.thumbnail(for: item) { _ in rendered = true; return Data("cover".utf8) } == nil)
        #expect(!rendered && service.downloadCount == 0)
        deadline = .now + .seconds(5)
        while try await session.loadChats().first?.unavailableMessageIDs?.contains(Data(output.id.utf8)) != true,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try await session.loadChats().first?.unavailableMessageIDs?.contains(Data(output.id.utf8)) == true)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        await reopened.restore()
        #expect(reopened.artifacts.isEmpty)
        #expect(LibrarySearchResults(query: "Cover needle", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        reopened.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [output]), title: "Main", evidence: service.coherentRead(source, messages: [output]))
        deadline = .now + .seconds(5)
        while reopened.artifacts.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while library.chats.first?.messages.first?.text != edited.text, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while library.warning?.contains("couldn’t be saved") != true, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        defer { library.retire() }
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
        defer { first.cancel(); oldRead.release() }
        await oldRead.waitUntilEntered()
        let reload = Task {
            reloadStarted = true
            return try await library.original(for: reloadedKey, force: true) {
                events.append("reload read started")
                return DownloadedArtifact(data: Data("newer response".utf8), filename: "report.txt", mimeType: "text/plain")
            }
        }
        defer { reload.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !reloadStarted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        defer { library.retire() }
        library.setOnline(true)
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [service.message("output", text: fileBacked ? "MEDIA:/report.html" : "```html\n<h1>Captured source</h1>\n```", at: 20)]), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        try await waitForInitialLibraryArtifacts(library)
        let reader = LibraryArtifactPreviewSession(item: try #require(library.artifacts.first), library: library)
        defer { reader.finish() }
        reader.retry()
        var deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil || reader.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let captured = try #require(reader.file)
        #expect(reader.canReload == fileBacked)
        let downloads = service.downloadCount, histories = service.historyReads
        service.downloadedBytes = Data("new host file".utf8)
        reader.reload()
        deadline = .now + .seconds(5)
        while (reader.isLoading || (fileBacked && service.downloadCount == downloads)), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while try await session.loadChats().first?.coverage != .complete, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while try await session.loadChats().count != 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        func accept(_ text: String) async throws {
            library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
                messages: [service.message("image", text: text, at: 20)]), title: "Main", evidence: .read(startedAt: .now, observedSource: source))
            let deadline = ContinuousClock.now + .seconds(5)
            while !library.artifacts.contains(where: {
                $0.artifact.messageID == "image" && $0.chat.messages.first(where: { $0.id == "image" })?.text == text
                    && $0.chat.sourceRevisions[Data("image".utf8)] != nil
            }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        }
        service.downloadedBytes = image(.red)
        try await accept("First image MEDIA:/chart.png")
        let first = try #require(library.artifacts.first)
        let initialRequest = LibraryThumbnails.request(for: first, library: library)
        let red = try #require(await covers.image(for: first, library: library))
        service.downloadedBytes = image(.green)
        try await accept("Revised image MEDIA:/chart.png")
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
        defer { library.retire() }
        library.setOnline(true)
        let scan = Task { await library.refresh(evidence: .observed, bots: service.profiles) }
        defer { scan.cancel(); gate.release() }
        await gate.waitUntilEntered()
        let current = changesTip ? SessionIdentity(profile: source.profile, root: source.root,
            stored: try ExactID("new-tip"), aliases: [source.root]) : source
        let latest = service.message("output", text: "MEDIA:/new.txt", at: 30)
        library.accept(identity: current, snapshot: .init(id: "main", storedID: current.stored.text,
            profileID: "helper", messages: [latest]), title: "Main", evidence: .read(startedAt: .now, observedSource: current))
        let deadline = ContinuousClock.now + .seconds(5)
        while !library.artifacts.contains(where: { $0.artifact.title == "new.txt" }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while reader.file == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while try await session.loadChats().isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while reader.file == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let original = try #require(reader.file)
        let gate = StoreTestBarrier(); service.downloadGate = gate
        reader.reload(); await gate.waitUntilEntered()
        reader.beginOutput(.save)
        #expect(reader.output == nil)
        #expect(reader.file === original)
        gate.release()
        deadline = .now + .seconds(5)
        while reader.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while reader.file == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while reader.file == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let captured = try #require(reader.file)
        library.setOnline(false)
        reader.reload()
        while (reader.errorMessage == nil || reader.isLoading) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while try await firstSession.loadChats().isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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
        while try await secondSession.loadChats().first?.messages.count != 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
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

    @Test(arguments: zip([15, 16], [false, true]))
    func admissionChargesProjectedRowsTheirCanonicalBytes(limit: Int, retained: Bool) async {
        // Ten characters, sixteen UTF-8 bytes: four shown plus six two-byte canonical characters.
        let projected = ChatMessage(id: "row", role: .assistant, text: "four", timestamp: Date(timeIntervalSince1970: 20),
            canonicalText: String(repeating: "\u{E9}", count: 6))
        let ordinary = ChatMessage(id: "row", role: .assistant, text: String(repeating: "x", count: 16),
            timestamp: Date(timeIntervalSince1970: 20))
        for message in [projected, ordinary] {
            let service = RetainedLibraryService(), source = service.source("main")
            service.summaries = [service.summary(source, at: 20)]
            service.pages[source] = [0: .init(messages: [message], nextOffset: nil, isComplete: true)]
            let library = WorkspaceLibrary(service: service, limits: .init(messageCount: 10, textBytes: limit, chatCount: 10))
            library.setOnline(true)
            await library.refresh(evidence: .observed, bots: service.profiles)
            #expect(!library.chats.flatMap(\.messages).isEmpty == retained)
            if retained { #expect(library.chats.first?.messages == [message]) }
        }
    }

    nonisolated private static let sharedBudgetCases: [(Int, [String])] = [(8, ["newer", "older"]), (12, ["newer"])]

    @Test(arguments: sharedBudgetCases)
    func sharedBudgetChargesCanonicalBytesBeforeTheNextChat(olderBytes: Int, expected: [String]) async {
        let service = RetainedLibraryService()
        let newer = service.source("newer"), older = service.source("older")
        service.summaries = [service.summary(newer, at: 20), service.summary(older, at: 10)]
        service.pages[newer] = [0: .init(messages: [ChatMessage(id: "newer", role: .assistant, text: "four",
            timestamp: Date(timeIntervalSince1970: 20), canonicalText: "eight by")], nextOffset: nil, isComplete: true)]
        service.pages[older] = [0: .init(messages: [service.message("older", text: String(repeating: "x", count: olderBytes), at: 10)],
            nextOffset: nil, isComplete: true)]
        let library = WorkspaceLibrary(service: service, limits: .init(messageCount: 10, textBytes: 20, chatCount: 10))
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(library.chats.flatMap(\.messages).map(\.id).sorted() == expected)
    }

    nonisolated private static let readCapCases: [(Int, Int)] = [(32 * 1024 * 1024 - 1, 2), (32 * 1024 * 1024, 1)]

    @Test(arguments: readCapCases)
    func historyScanStopsAtTheReadCapByRetainedBytes(bytes: Int, reads: Int) async {
        let service = RetainedLibraryService(), source = service.source("main")
        service.summaries = [service.summary(source, at: 20)]
        let large = ChatMessage(id: "large", role: .assistant, text: "four", timestamp: Date(timeIntervalSince1970: 20),
            canonicalText: String(repeating: "x", count: bytes - 4))
        service.pages[source] = [
            0: .init(messages: [large], nextOffset: 100, isComplete: true),
            100: .init(messages: [service.message("older", text: "older", at: 10)], nextOffset: nil, isComplete: true)]
        // A larger retention budget keeps trimming from ending the scan before the read cap does.
        let library = WorkspaceLibrary(service: service, limits: .init(messageCount: 10, textBytes: 64 * 1024 * 1024, chatCount: 10))
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        #expect(service.historyReads == reads)
        #expect(library.chats.flatMap(\.messages).contains { $0.id == "large" })
    }

    @Test(arguments: zip([15, 16], [false, true]))
    func libraryAndCacheAgreeOnProjectedRowsAtTheExactBudget(limit: Int, retained: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let canonical = String(repeating: "\u{E9}", count: 6)
        let row = ChatMessage(id: "row", role: .assistant, text: "four", timestamp: Date(timeIntervalSince1970: 20), canonicalText: canonical)
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [row], nextOffset: nil, isComplete: true)]
        var cacheLimits = ArtifactCache.Limits(); cacheLimits.textBytes = limit
        let libraryLimits = WorkspaceLibrary.Limits(messageCount: 10, textBytes: limit, chatCount: 10)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root, limits: cacheLimits), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, limits: libraryLimits, cache: session)
        library.setOnline(true)
        await library.refresh(evidence: .observed, bots: service.profiles)
        let deadline = ContinuousClock.now + .seconds(5)
        while retained, try await session.loadChats().first?.messages.isEmpty != false, ContinuousClock.now < deadline { await Task.yield() }
        let saved = try await session.loadChats().flatMap(\.messages)
        #expect(saved.isEmpty == !retained)
        if retained { #expect(saved.first?.canonicalText?.utf8.elementsEqual(canonical.utf8) == true) }
        library.retire(); await cache.close()
        let reopened = ArtifactCache(root: root, limits: cacheLimits)
        let cold = WorkspaceLibrary(service: service, limits: libraryLimits, cache: reopened.session(scope: scope))
        await cold.restore()
        #expect(cold.chats.flatMap(\.messages) == (retained ? [row] : []))
        cold.retire(); await reopened.close()
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
        let viaItem: Result<Data, HermesServiceError>, viaKey: Result<Data, HermesServiceError>
        let capturedBytes: Data?, downloads: Int
    }

    /// Captures `captured`'s file online, reads `current` from the host, then asks both readers for it offline.
    private func offlineRead(capturing captured: ChatMessage, thenReading current: ChatMessage,
                             coldCache: Bool = false) async throws -> OfflineRead {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("stored-1")
        service.summaries = [service.summary(source, at: 10)]
        service.pages[source] = [0: .init(messages: [captured], nextOffset: nil, isComplete: true)]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        var cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        var library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let capturedItem = try #require(library.artifacts.first), attachment = try #require(capturedItem.artifact.attachment)
        let capturedKey = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: [captured]))
        #expect(try await library.download(capturedItem).data == service.downloadedBytes)

        service.pages[source] = [0: .init(messages: [current], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.chats.first?.messages == [current])
        if coldCache {
            let deadline = ContinuousClock.now + .seconds(5)
            while try await session.loadChats().first?.messages != [current], ContinuousClock.now < deadline { await Task.yield() }
            library.retire(); await cache.close()
            cache = ArtifactCache(root: root); session = cache.session(scope: scope)
            library = WorkspaceLibrary(service: service, cache: session)
            library.setOnline(false); library.observeBots(service.profiles, evidence: .observed); await library.restore()
            let restored = ContinuousClock.now + .seconds(5)
            while library.artifacts.isEmpty, ContinuousClock.now < restored { await Task.yield() }
        }
        library.setOnline(false)
        let item = try #require(library.artifacts.first), currentAttachment = try #require(item.artifact.attachment)
        let currentKey = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: currentAttachment, messages: [current]))
        func read(_ body: () async throws -> DownloadedArtifact) async -> Result<Data, HermesServiceError> {
            do { return .success(try await body().data) }
            catch let error as HermesServiceError { return .failure(error) }
            catch { return .failure(.incompatible) }
        }
        let viaItem = await read { try await library.download(item) }
        let viaKey = await read { try await library.original(for: currentKey) { throw HermesServiceError.rejected(500) } }
        let capturedBytes = try await session.original(for: capturedKey)?.artifact.data
        let downloads = service.downloadCount
        library.retire(); await cache.close()
        return .init(capturedKey: capturedKey, currentKey: currentKey, viaItem: viaItem, viaKey: viaKey,
            capturedBytes: capturedBytes, downloads: downloads)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test(arguments: sameWireRows, [false, true])
    private func restoreCaptureStaysAvailableAcrossTheRowsRestProjection(row: SameWireRow, coldCache: Bool) async throws {
        let read = try await offlineRead(capturing: row.raw, thenReading: row.rest, coldCache: coldCache)
        #expect(hex(read.capturedKey.sourceRevision) == row.oldRestoreHash)
        #expect(read.currentKey == read.capturedKey)
        #expect(read.viaItem == .success(RetainedLibraryService().downloadedBytes))
        #expect(read.viaKey == .success(RetainedLibraryService().downloadedBytes))
        #expect(read.downloads == 1)
    }

    @Test(arguments: sameWireRows)
    private func rawResumeAndRestPageShareOneProducerKey(row: SameWireRow) async throws {
        // Authority display stays deferred: a resume row still shows the carrier its REST page projects away.
        #expect(row.raw.canonicalText == nil)
        if row.rest.canonicalText != nil { #expect(row.raw.text != row.rest.text) }
        let source = RetainedLibraryService().source("stored-1")
        guard case .file(let attachment)? = ArtifactDiscovery.artifacts(in: [row.rest]).first?.payload else {
            Issue.record("Every same-wire row produces a file"); return
        }
        let rawKey = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: [row.raw]))
        let restKey = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: [row.rest]))
        #expect(rawKey == restKey)
        #expect(hex(rawKey.sourceRevision) == row.oldRestoreHash)
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
        #expect(read.viaItem == .failure(.disconnected))
        #expect(read.viaKey == .failure(.disconnected))
        #expect(read.capturedBytes == RetainedLibraryService().downloadedBytes)
        #expect(read.downloads == 1)
    }

    @Test func displayOnlyChangeKeepsTheCaptureOfItsUnchangedRow() async throws {
        let captured = Self.mergedReply.rest
        var current = captured; current.text = "Report finished.\nMEDIA:/tmp/report.txt"
        let read = try await offlineRead(capturing: captured, thenReading: current)
        #expect(read.currentKey == read.capturedKey)
        #expect(read.viaItem == .success(RetainedLibraryService().downloadedBytes))
        #expect(read.downloads == 1)
    }

    /// Page reads before canonical retention kept only display text. That capture cannot be tied to a stored row,
    /// so it stays under its own key and the current row needs one online read. This is the accepted missing-provenance
    /// boundary, recorded red in U8-evidence/d4 as pageOriginUnchangedRow, not a repaired upgrade path.
    @Test(arguments: [false, true])
    func legacyPageCaptureHasNoCanonicalProvenanceToAttach(edited: Bool) async throws {
        let oldPage = Self.wireRow(.assistant, Self.visibleReply)
        let stored = Self.carrier(Self.visibleReply, summary: edited ? "The parser task was compacted again." : "The parser task was compacted.")
        let read = try await offlineRead(capturing: oldPage, thenReading: Self.wireRow(.assistant, Self.visibleReply, canonical: stored))
        #expect(hex(read.capturedKey.sourceRevision) == "b06465ba05d33209da1b5039a581daf4a6d35be2f0329d0cad615bb20b23cbb7")
        #expect(read.currentKey != read.capturedKey)
        #expect(read.viaItem == .failure(.disconnected))
        #expect(read.viaKey == .failure(.disconnected))
        #expect(read.capturedBytes == RetainedLibraryService().downloadedBytes)
        #expect(read.downloads == 1)
    }

    @Test func sidecarImagePagePathStaysASeparateCapture() async throws {
        let row = try #require(Self.sameWireRows.first { !$0.rest.attachments.isEmpty })
        var oldPage = Self.wireRow(.user, "Check this image", attachments: row.rest.attachments)
        oldPage.attachments[0].path = "stored-1:row:11:image:1"
        let read = try await offlineRead(capturing: oldPage, thenReading: row.rest)
        #expect(hex(read.capturedKey.sourceRevision) == "720e39f7b28efd373bb94f4423b7bf94372996f309cd486e9af565ac4ca56e92")
        #expect(read.capturedKey.path != read.currentKey.path)
        #expect(read.viaItem == .failure(.disconnected))
        #expect(read.capturedBytes == RetainedLibraryService().downloadedBytes)
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
        let source = RetainedLibraryService().source("stored-1")
        let attachment = ChatAttachment(name: "a.txt", path: "/tmp/a.txt", mimeType: "text/plain")
        let base = Self.wireRow(.assistant, "Visible", canonical: canonical, attachments: [attachment])
        var changed = base; change.change(&changed)
        let found = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: [changed]))
        let original = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: [base]))
        #expect(found != original)
    }

    @Test func producerIdentityComparesExactUTF8AndPath() async throws {
        let source = RetainedLibraryService().source("stored-1")
        let attachment = ChatAttachment(name: "a.txt", path: "/tmp/a.txt", mimeType: "text/plain")
        func key(_ text: String, canonical: String? = nil, attachment: ChatAttachment? = nil) async throws -> ArtifactOriginalKey {
            let file = attachment ?? ChatAttachment(name: "a.txt", path: "/tmp/a.txt", mimeType: "text/plain")
            let row = Self.wireRow(.assistant, text, canonical: canonical, attachments: [file])
            return try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: file, messages: [row]))
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

        let service = RetainedLibraryService(), source = service.source("main")
        service.summaries = [service.summary(source, at: 10)]
        service.pages[source] = [0: .init(messages: [legacy], nextOffset: nil, isComplete: true)]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let library = WorkspaceLibrary(service: service, cache: session)
        library.setOnline(true); await library.refresh(evidence: .observed, bots: service.profiles)
        let legacyItem = try #require(library.artifacts.first), attachment = try #require(legacyItem.artifact.attachment)
        let legacyKey = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: [legacy]))
        #expect(legacyKey.sourceRevision == Data(SHA256.hash(data: Data("[\(legacyJSON)]".utf8))))
        #expect(try await library.download(legacyItem).data == service.downloadedBytes)
        #expect(service.downloadCount == 1)

        // Upgrading alone changes nothing for a row no read has revised, including offline.
        library.setOnline(false)
        #expect(try await library.original(for: legacyKey) { throw HermesServiceError.disconnected }.data == service.downloadedBytes)
        #expect(service.downloadCount == 1)

        // This legacy row holds no canonical bytes to prove it is the stored row, so it is a new producer.
        library.setOnline(true)
        var projected = legacy; projected.canonicalText = "[CONTEXT COMPACTION] first handoff"
        service.pages[source] = [0: .init(messages: [projected], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.chats.first?.messages == [projected])
        #expect(!library.isCurrent(legacyItem))
        let projectedItem = try #require(library.artifacts.first)
        let projectedKey = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: [projected]))
        #expect(projectedKey != legacyKey)

        // Offline before that download, the current row has no capture; the old one survives under its own key.
        library.setOnline(false)
        await #expect(throws: HermesServiceError.disconnected) {
            try await library.original(for: projectedKey) { throw HermesServiceError.rejected(500) }
        }
        #expect(try await library.original(for: legacyKey) { throw HermesServiceError.rejected(500) }.data == service.downloadedBytes)
        #expect(service.downloadCount == 1)
        library.setOnline(true)

        #expect(try await library.download(projectedItem).data == service.downloadedBytes)
        #expect(service.downloadCount == 2)

        // A canonical-only revision replaces retained bytes rather than matching the old row.
        var revised = projected; revised.canonicalText = "[CONTEXT COMPACTION] second handoff"
        service.pages[source] = [0: .init(messages: [revised], nextOffset: nil, isComplete: true)]
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.chats.first?.messages == [revised])
        #expect(!library.isCurrent(projectedItem))
        let deadline = ContinuousClock.now + .seconds(5)
        while try await session.loadChats().first?.messages.first?.canonicalText != revised.canonicalText,
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await session.loadChats().first?.messages == [revised])
        library.retire(); await cache.close()
    }

    @Test func canonicalOnlyConflictStaysUnverifiedUntilACoherentRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RetainedLibraryService(), source = service.source("main")
        let legacy = service.message("reply", text: "Visible reply\nMEDIA:/report.txt", at: 20)
        var projected = legacy; projected.canonicalText = "[CONTEXT COMPACTION] handoff"
        let rowID = Data(legacy.id.utf8)
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let warmCache = ArtifactCache(root: root), warm = warmCache.session(scope: scope)
        try await warm.upsert(.init(identity: source, botName: "Helper", title: "Main", messages: [legacy],
            updatedAt: legacy.timestamp, coverage: .partial, summary: nil, headFingerprint: nil))
        await warmCache.close()
        let control = SavedIndexReadControl(), cache = ArtifactCache(root: root, afterChatLoad: { try await control.load() })
        let library = WorkspaceLibrary(service: service, cache: cache.session(scope: scope))
        library.setOnline(true); library.observeBots(service.profiles, evidence: .observed); await library.restore()
        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [legacy]),
            title: "Main", evidence: .read(startedAt: .now, observedSource: source))
        service.summaries = [service.summary(source, at: 20)]
        service.pages[source] = [0: .init(messages: [projected], nextOffset: 100, isComplete: true)]
        service.failAtOffset = 100
        await library.refresh(evidence: .observed, bots: service.profiles, force: true)
        #expect(library.chats.isEmpty)
        control.fails = false; await library.restore()
        #expect(library.chats.first?.unverifiedMessageIDs.contains(rowID) == true)
        #expect(library.artifacts.isEmpty)

        library.accept(identity: source, snapshot: .init(id: "main", storedID: "main", profileID: "helper", messages: [projected]),
            title: "Main", evidence: service.coherentRead(source, messages: [projected]))
        let deadline = ContinuousClock.now + .seconds(5)
        while library.artifacts.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(library.chats.first?.unverifiedMessageIDs.contains(rowID) == false)
        #expect(library.chats.first?.messages == [projected])
        library.retire(); await cache.close()
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
    var providesIdentityReads = true
    var historyFailure: ConversationHistoryPage.Failure?
    func source(_ root: String) -> SessionIdentity {
        .init(profile: try! ExactID("helper"), root: try! ExactID(root), stored: try! ExactID(root), aliases: [try! ExactID(root)])
    }
    func summary(_ source: SessionIdentity, at time: Double) -> SessionSummary {
        .init(identity: source, title: source.root.text, isCanonical: false, persistence: .durable,
            updatedAt: Date(timeIntervalSince1970: time))
    }
    func savedUnavailableIDs(_ session: ArtifactCacheSession, for source: SessionIdentity) async throws -> Set<Data> {
        let rows = try await session.loadChats().filter { $0.identity == source }
        let hints = try await session.metadataRecoveryHints().filter { $0.identity == source }
        return Set(rows.flatMap { $0.unavailableMessageIDs ?? [] }).union(hints.flatMap(\.unavailableMessageIDs))
    }
    func coherentRead(_ source: SessionIdentity, messages: [ChatMessage]) -> ChatTranscriptPublication.Evidence {
        .read(startedAt: .now, observedSource: source,
            identityRead: .init(identity: source, messageIDs: Set(messages.map { Data($0.id.utf8) })))
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
        if let historyFailure { throw historyFailure }
        let page = pages[identity]?[offset] ?? .init(messages: [], nextOffset: nil, isComplete: true)
        let ids = Set(page.messages.map { Data($0.id.utf8) })
        let proof = page.identityRead ?? (providesIdentityReads && offset == 0 && page.nextOffset == nil
            && page.isComplete && page.unavailableMessageIDs.isEmpty && ids.count == page.messages.count
            && page.sourceIDs.map({ $0 == ids }) != false
            ? ConversationIdentityRead(identity: identity, messageIDs: ids) : nil)
        return .init(messages: page.messages, nextOffset: page.nextOffset, isComplete: page.isComplete,
            sourceIDs: page.sourceIDs ?? ids, unavailableMessageIDs: page.unavailableMessageIDs, identityRead: proof)
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

@MainActor private final class BudgetProjectionPause {
    private var armed = false
    private(set) var wasTaken = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm() { armed = true }

    func waitIfArmed() async {
        guard armed else { return }
        armed = false
        wasTaken = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
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

@MainActor private final class SavedIndexReadControl {
    private enum Failure: Error { case unavailable }
    var fails = true
    var loads = 0
    var gate: StoreTestBarrier?
    func load() async throws {
        loads += 1
        let pause = gate; gate = nil
        await pause?.wait()
        if fails { throw Failure.unavailable }
    }
}
