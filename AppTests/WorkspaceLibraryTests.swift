import Foundation
import Testing
import SwiftUI
import UIKit
import Observation
import BottoCore
@testable import Botto

@MainActor struct WorkspaceLibraryTests {
    @Observable final class SearchLeadingGrowth {
        var height: CGFloat = 40
    }

    @Test func aChatLedOriginalCanHandOffToAValidGalleryReaderAfterNavigation() async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let library = store.library
        let item = try #require(library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        let message = try #require(item.chat.messages.first { $0.id == item.artifact.messageID })
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        defer { store.finishArtifact(destination) }
        let key = ArtifactOriginalKey(identity: item.chat.identity, messageID: Data(message.id.utf8),
            path: Data(attachment.path.utf8), sourceRevision: try #require(item.chat.sourceRevisions[Data(message.id.utf8)]))
        let barrier = StoreTestBarrier(); service.downloadBarrier = barrier
        let inChat = Task { try await store.downloadArtifact(destination) }
        await barrier.waitUntilEntered()
        var joined = false
        let peer = Task {
            try await library.original(for: key, validateNetwork: {
                guard library.isCurrent(item) else { throw HermesServiceError.staleConversation }
                joined = true
            }, download: { try await service.downloadArtifact(attachment, in: item.chat.identity) })
        }
        let gallery = Task { try await library.download(item) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !joined, ContinuousClock.now < deadline { await Task.yield() }
        try #require(joined)
        await store.open(service.profiles[1])
        #expect(!store.isCurrentArtifactDestination(destination))
        #expect(library.isCurrent(item))
        service.downloadBarrier = nil; barrier.release()
        await #expect(throws: (any Error).self) { _ = try await inChat.value }
        #expect(try await peer.value.data == Data("main".utf8))
        #expect(try await gallery.value.data == Data("main".utf8))
        #expect(store.selectedBotID == service.second.profile.text)
        #expect(store.chats.screen(profile: service.second.profile)?.canAct == true)
        #expect(service.downloadCount == 2, "Only the retired first transport should require a replacement read")
        #expect(try await library.download(item).data == Data("main".utf8))
        #expect(service.downloadCount == 2)
    }

    @Test(arguments: [false, true])
    func aShorterAcceptedRevisionRemovesItsDeletedOutputAndSearchText(timestampChanges: Bool) async throws {
        let service = LibraryTestService()
        let message = ChatMessage(id: "main:row:report", role: .assistant, text: "Report ready\nMEDIA:/report.txt", timestamp: Date(timeIntervalSince1970: 100))
        service.messages[service.first] = [message]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let library = store.library, item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let reader = LibraryArtifactPreviewSession(item: item, library: library)
        defer { reader.finish() }
        reader.retry()
        var deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(reader.file != nil)
        let parsed = library.indexingMetrics.parsedMessages
        library.accept(identity: service.first, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [.init(id: message.id, role: .assistant, text: "Report ready", timestamp: timestampChanges ? nil : message.timestamp)]), title: "Main")
        deadline = ContinuousClock.now + .seconds(5)
        while library.indexingMetrics.parsedMessages == parsed, ContinuousClock.now < deadline { await Task.yield() }
        try #require(library.indexingMetrics.parsedMessages > parsed)
        let current = try #require(library.chats.first { $0.identity == service.first })
        #expect(current.messages.first?.text == "Report ready")
        #expect(library.artifacts.allSatisfy { $0.chat.identity != service.first })
        #expect(!library.isCurrent(item) && !reader.isCurrent && reader.file == nil)
        let results = LibrarySearchResults(query: "report.txt", bots: [], chats: [current], artifacts: library.artifacts)
        #expect(results.messages.isEmpty && results.artifacts.allSatisfy { $0.chat.identity != service.first })
        #expect(library.artifacts.contains { $0.chat.identity == service.second }, "An edit must preserve another chat’s outputs")
    }

    @Test func offlineRefreshCannotReseedAnOutputRemovedByACompleteRead() async throws {
        let service = LibraryTestService()
        let old = ChatMessage(id: "report", role: .assistant, text: "Report ready with deleted appendix\nMEDIA:/deleted.txt")
        service.messages[service.first] = [old]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: store.library.chats, artifacts: []).messages.count == 1)
        #expect(try await store.library.download(item).data == Data("main".utf8))
        service.messages[service.first] = [.init(id: old.id, role: .assistant, text: "Report ready")]
        await store.refreshLibrary(force: true)
        #expect(!store.library.isCurrent(item))
        service.onEvent?(.disconnected("Offline reseed fixture"))
        let reads = service.historyOffsets.count
        await store.refreshLibrary()
        let current = try #require(store.library.chats.first { $0.identity == service.first })
        #expect(current.messages.first?.text == "Report ready")
        #expect(store.library.artifacts.allSatisfy { $0.chat.identity != service.first })
        #expect(!store.library.isCurrent(item))
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: [current], artifacts: []).messages.isEmpty)
        #expect(service.historyOffsets.count == reads)
    }

    @Test(arguments: [false, true])
    func conflictingSavedRevisionsCannotRestoreADeletedOutputOffline(cacheHasOldSuffix: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService()
        service.versionedSummaries = true
        let old = ChatMessage(id: "report", role: .assistant, text: "Report ready with deleted appendix\nMEDIA:/deleted.txt", timestamp: Date(timeIntervalSince1970: 100))
        let edited = ChatMessage(id: old.id, role: .assistant, text: "Report ready", timestamp: old.timestamp)
        let retained = ChatMessage(id: "other", role: .assistant, text: "MEDIA:/retained.txt", timestamp: Date(timeIntervalSince1970: 200))
        service.messages[service.first] = [old, retained]
        let scope = ArtifactCacheScope(configurationID: UUID(), serverURL: Data(), installationID: nil, username: Data(), provider: nil)
        let cache = ArtifactCache(root: root), session = cache.session(scope: scope)
        let original = WorkspaceLibrary(service: service, cache: session)
        original.setOnline(true); await original.refresh(bots: service.profiles)
        let deleted = try #require(original.artifacts.first { $0.artifact.title == "deleted.txt" })
        let kept = try #require(original.artifacts.first { $0.artifact.title == "retained.txt" })
        let oldKey = ArtifactOriginalKey(identity: service.first, messageID: Data(old.id.utf8), path: Data("/deleted.txt".utf8),
            sourceRevision: try #require(deleted.chat.sourceRevisions[Data(old.id.utf8)]))
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: original.chats, artifacts: []).messages.count == 1)
        #expect(try await original.download(deleted).data == Data("main".utf8))
        #expect(try await original.download(kept).data == Data("main".utf8))
        original.retire()
        let fixture = cache.session(scope: scope)
        let summary = SessionSummary(identity: service.first, title: "Main", isCanonical: true, persistence: .durable,
            updatedAt: Date(timeIntervalSince1970: 1_000), messageCount: 2)
        try await fixture.upsert(.init(identity: service.first, botName: "Helper", title: "Main",
            messages: [cacheHasOldSuffix ? old : edited, retained], updatedAt: summary.updatedAt,
            coverage: .complete, summary: summary, headFingerprint: nil))
        var book = ConversationBook()
        let id = book.merge(summary)
        book.cache(.init(id: "main", storedID: "main", profileID: "helper",
            messages: [cacheHasOldSuffix ? edited : old, retained]), for: id)
        let library = WorkspaceLibrary(service: service, cache: fixture)
        library.seed(book: book, bots: service.profiles); await library.restore()
        let reads = service.historyOffsets.count, downloads = service.downloadCount
        #expect(try await fixture.original(for: oldKey)?.artifact.data == Data("main".utf8))
        #expect(!library.artifacts.contains { $0.artifact.title == "deleted.txt" })
        #expect(library.artifacts.contains { $0.artifact.title == "retained.txt" })
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: library.chats, artifacts: library.artifacts).messages.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while try await fixture.loadChats().first(where: { $0.identity == service.first })?.messages.contains(where: { $0.id == old.id }) == true,
              ContinuousClock.now < deadline { await Task.yield() }
        try #require(try await fixture.loadChats().first { $0.identity == service.first }?.messages.contains { $0.id == old.id } == false)
        library.retire(); await cache.close()
        let reopenedCache = ArtifactCache(root: root)
        let reopened = WorkspaceLibrary(service: service, cache: reopenedCache.session(scope: scope))
        reopened.seed(book: book, bots: service.profiles); await reopened.restore()
        #expect(!reopened.artifacts.contains { $0.artifact.title == "deleted.txt" })
        #expect(reopened.artifacts.contains { $0.artifact.title == "retained.txt" })
        let offline = try #require(reopened.artifacts.first { $0.artifact.title == "retained.txt" })
        #expect(try await reopened.download(offline).data == Data("main".utf8))
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        #expect(service.historyOffsets.count == reads && service.downloadCount == downloads)
        service.failHistory = true
        reopened.setOnline(true); await reopened.refresh(bots: service.profiles)
        #expect(service.historyOffsets.count > reads, "The current directory cannot resolve a disputed message")
        reopened.setOnline(false)
        reopened.seed(book: book, bots: service.profiles)
        await reopened.refresh(bots: service.profiles)
        #expect(reopened.chats.first { $0.identity == service.first }?.messages.allSatisfy { $0.id != old.id } == true)
        #expect(!reopened.artifacts.contains { $0.artifact.title == "deleted.txt" })
        #expect(LibrarySearchResults(query: "deleted appendix", bots: [], chats: reopened.chats, artifacts: []).messages.isEmpty)
        reopened.retire(); await reopenedCache.close()
        let recoveredCache = ArtifactCache(root: root)
        let recovered = WorkspaceLibrary(service: service, cache: recoveredCache.session(scope: scope))
        recovered.seed(book: book, bots: service.profiles); await recovered.restore()
        #expect(recovered.chats.first { $0.identity == service.first }?.messages.allSatisfy { $0.id != old.id } == true)
        #expect(!recovered.artifacts.contains { $0.artifact.title == "deleted.txt" })
        let retainedAfterFailure = try #require(recovered.artifacts.first { $0.artifact.title == "retained.txt" })
        let downloadsBeforeRecovery = service.downloadCount
        #expect(try await recovered.download(retainedAfterFailure).data == Data("main".utf8))
        #expect(service.downloadCount == downloadsBeforeRecovery)
        service.failHistory = false
        service.messages[service.first] = [edited, retained]
        let readsBeforeRecovery = service.historyOffsets.count
        recovered.setOnline(true); await recovered.refresh(bots: service.profiles)
        #expect(service.historyOffsets.count > readsBeforeRecovery, "Conflicting local copies cannot certify a complete current index")
        #expect(recovered.chats.first { $0.identity == service.first }?.messages.first?.text == "Report ready")
        #expect(!recovered.artifacts.contains { $0.artifact.title == "deleted.txt" })
        recovered.retire(); await recoveredCache.close()
    }

    @Test(arguments: ["user", "assistant", "code"])
    func exactSearchFocusRevealsTheActualGlyphInsideAnOlderTallMessage(kind: String) async throws {
        let service = LibraryTestService()
        let query = "Native needle checkpoint"
        let prefix = (0..<75).map { "Ordinary native line \($0)" }.joined(separator: "\n")
        let body = kind == "code" ? "```swift\n" + prefix + "\n" + String(repeating: " ", count: 140) + query + "\n```" : String(repeating: "The older project discussion continues with practical details. ", count: 90) + query
        let target = ChatMessage(id: "main:row:older", role: kind == "user" ? .user : .assistant, text: body)
        service.messages[service.first] = (0..<18).map {
            ChatMessage(id: "main:row:before:\($0)", role: .assistant, text: "Earlier reply \($0)")
        } + [target] + (0..<220).map {
            ChatMessage(id: "main:row:\($0)", role: .assistant, text: "Later reply \($0)")
        }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.refreshLibrary()
        let chat = try #require(store.library.chats.first { $0.identity == service.first })
        guard case .opened(let focus) = await store.openSearchMessage(.init(chat: chat, message: target, query: query)) else {
            Issue.record("Expected exact older message focus"); return
        }
        let snapshot = try #require(store.chats.selection(profile: service.first.profile)?.snapshot)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let controller = NativeTranscriptController(), window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { controller.retire(); window.isHidden = true; previous?.makeKeyAndVisible() }
        let context = NativeTranscriptContext(workspace: ObjectIdentifier(store.chats), profile: focus.identity.profile.bytes,
            chat: focus.owner.chat, owner: focus.owner, generation: UUID(), reviewingConnection: false)
        let growth = SearchLeadingGrowth()
        var rows = snapshot.messages.map { message in
            NativeTranscriptRow(id: .message(Data(message.id.utf8)), value: .message(message, working: false)) { _, _ in
                AnyView(VStack(spacing: 0) {
                    if message.id == target.id { Color.clear.frame(height: growth.height) }
                    MessageView(message: message).padding(.horizontal, 12)
                })
            }
        }
        rows.append(.init(id: .terminal, value: .auxiliary("terminal")) { _, _ in AnyView(Color.clear.frame(height: 1)) })
        var revealed = false
        controller.apply(context, snapshot: snapshot, rows: rows, active: true, currentTaskSnapshot: { snapshot },
            searchFocus: focus, reportSearchFocus: { id, result in
                if id == focus.id, case .revealed = result { revealed = true }
            })
        controller.view.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(12)
        while !revealed, ContinuousClock.now < deadline { await Task.yield() }
        try #require(revealed, "The native glyph range must be visible before Search acknowledges success")
        let cell = try #require(controller.collection.cellForItem(at: IndexPath(item: 18, section: 0)) as? NativeTranscriptCell)
        let hit = try #require(cell.exposure?.firstSearchMarker(id: focus.id))
        let rect = hit.marker.convert(hit.marker.bounds, to: window)
        let visible = rect.intersection(controller.collection.convert(controller.collection.bounds, to: window))
        #expect(!visible.isNull && visible.height > 0 && visible.width > 0)
        #expect(hit.marker.convert(hit.marker.bounds, to: cell).minY > 1000)
        #expect(controller.collection.cellForItem(at: IndexPath(item: snapshot.messages.count, section: 0)) == nil)
        #expect(!controller.followsLatest)
        let originalHeight = cell.bounds.height
        growth.height = 400
        let growthDeadline = ContinuousClock.now + .seconds(8)
        while (cell.bounds.height < originalHeight + 300 || abs(hit.marker.convert(hit.marker.bounds, to: window).minY - rect.minY) > 1),
              ContinuousClock.now < growthDeadline { await Task.yield() }
        #expect(cell.bounds.height > originalHeight + 300, "The preceding native block must actually grow")
        #expect(abs(hit.marker.convert(hit.marker.bounds, to: window).minY - rect.minY) < 1,
            "A delayed rich-block measurement must preserve the revealed glyph landmark")
        let latest = try #require(controller.view.subviews.compactMap { $0 as? UIButton }.first)
        #expect(!latest.isHidden)
        latest.sendActions(for: .touchUpInside)
        #expect(controller.followsLatest)
        print("BOTTO_SEARCH_NATIVE_GLYPH kind=\(kind) rect=\(rect)")
        let replacement = SearchMessageFocus(workspace: focus.workspace, owner: focus.owner,
            identity: focus.identity, message: focus.message, query: focus.query)
        var edited = snapshot
        edited.messages[18] = .init(id: target.id, role: target.role, text: "The occurrence changed during positioning")
        var unavailable = false
        controller.apply(context, snapshot: edited, rows: rows, active: true, currentTaskSnapshot: { edited },
            searchFocus: replacement, reportSearchFocus: { id, result in
                if id == replacement.id, case .unavailable = result { unavailable = true }
            })
        let editDeadline = ContinuousClock.now + .seconds(5)
        while !unavailable, ContinuousClock.now < editDeadline { await Task.yield() }
        #expect(unavailable, "A stale render receipt cannot acknowledge a changed same-ID message")
    }

    @Test(arguments: ["unchanged", "edited", "missing", "removed-query", "duplicate", "hidden"])
    func messageSearchValidatesTheOccurrenceBeforeChangingSelection(change: String) async throws {
        let service = LibraryTestService(secondBot: true)
        let expected = ChatMessage(id: "main:row:older", role: .assistant, text: "Saved **Needle** summary")
        service.messages[service.first] = [expected] + (0..<240).map {
            ChatMessage(id: "main:row:\($0)", role: .assistant, text: "Later reply \($0)")
        }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[1]); await store.refreshLibrary()
        let prior = try #require(store.chats.screen(profile: service.second.profile))
        store.chats.editDraft("Keep this draft", owner: prior.owner)
        let chat = try #require(store.library.chats.first { $0.identity == service.first })
        switch change {
        case "edited": service.messages[service.first]?[0] = .init(id: expected.id, role: .assistant, text: "Current Needle summary")
        case "missing": service.messages[service.first]?.removeFirst()
        case "removed-query": service.messages[service.first]?[0] = .init(id: expected.id, role: .assistant, text: "A replacement summary")
        case "duplicate": service.messages[service.first]?.append(expected)
        case "hidden": service.messages[service.first]?[0] = .init(id: expected.id, role: .assistant, text: expected.text, isSilent: true)
        default: break
        }
        let result = await store.openSearchMessage(.init(chat: chat, message: expected, query: "needle"))
        if change == "unchanged" || change == "edited" {
            guard case .opened(let focus) = result else { Issue.record("Expected exact older occurrence"); return }
            #expect(focus.identity == service.first)
            #expect(focus.message.id == expected.id)
            #expect(focus.message.text == (change == "edited" ? "Current Needle summary" : expected.text))
            #expect(focus.matches(workspace: store.chats))
            #expect(store.selectedBotID == service.first.profile.text)
            #expect(store.chats.screen(profile: service.first.profile)?.canAct == true)
        } else {
            guard case .unavailable = result else { Issue.record("A missing or ambiguous match must fail honestly"); return }
            #expect(store.selectedBotID == service.second.profile.text)
            #expect(store.chats.selection(profile: service.second.profile)?.identity == service.second)
            #expect(store.chats.screen(profile: service.second.profile)?.canAct == true)
        }
        #expect(store.chats.persisted().record(prior.owner.chat)?.draft.text == "Keep this draft")
    }

    @Test(arguments: [false, true])
    func cancelledOriginalReadCannotAdmitLateBytesButKeepsAValidPeer(validPeer: Bool) async throws {
        let service = LibraryTestService(), cache = ArtifactCache(root: nil)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        let library = store.library
        let key = ArtifactOriginalKey(identity: service.first, messageID: Data("row".utf8),
            path: Data("/late.txt".utf8), sourceRevision: Data("revision".utf8))
        let gate = StoreTestBarrier()
        var downloads = 0, transportCancelled = false
        let older = Task {
            try await library.original(for: key, download: {
                downloads += 1
                await gate.wait()
                transportCancelled = Task.isCancelled
                return DownloadedArtifact(data: Data("late".utf8), filename: "late.txt", mimeType: "text/plain")
            })
        }
        await gate.waitUntilEntered()
        var joined = false
        let peer: Task<DownloadedArtifact, Error>? = validPeer ? Task {
            try await library.original(for: key, validateNetwork: { joined = true }, download: {
                Issue.record("A valid peer must share the existing flight")
                throw HermesServiceError.disconnected
            })
        } : nil
        if validPeer {
            let deadline = ContinuousClock.now + .seconds(5)
            while !joined, ContinuousClock.now < deadline { await Task.yield() }
            try #require(joined)
        }
        older.cancel()
        // Release immediately: cancellation admission must fence even a response
        // that races the MainActor's scheduled waiter cleanup.
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await older.value }
        if let peer { #expect(try await peer.value.data == Data("late".utf8)) }
        #expect(downloads == 1)
        let subsequent = try await library.original(for: key, download: {
            downloads += 1
            return DownloadedArtifact(data: Data("fresh".utf8), filename: "late.txt", mimeType: "text/plain")
        })
        #expect(subsequent.data == Data((validPeer ? "late" : "fresh").utf8))
        #expect(downloads == (validPeer ? 1 : 2))
        if validPeer { #expect(!transportCancelled) }
    }

    @Test func cancelledMessageOpeningCannotOverrideANewerSearchMatch() async throws {
        let service = LibraryTestService(secondBot: true)
        let message = ChatMessage(id: "side:row:needle", role: .assistant, text: "Exact Needle reply")
        service.messages[service.second] = [message]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.profiles[0]); await store.refreshLibrary()
        let prior = try #require(store.chats.screen(profile: service.first.profile))
        store.chats.editDraft("Keep the original draft", owner: prior.owner)
        let chat = try #require(store.library.chats.first { $0.identity == service.second })
        let target = SearchMessageTarget(chat: chat, message: message, query: "needle")
        let attachment = StoreTestBarrier(); service.gatedSource = service.second; service.openingBarrier = attachment
        let older = Task { await store.openSearchMessage(target) }
        await attachment.waitUntilEntered(); older.cancel(); service.openingBarrier = nil
        let directory = StoreTestBarrier(); service.directoryBarrier = directory
        let newer = Task { await store.openSearchMessage(target) }
        await directory.waitUntilEntered(); attachment.release()
        guard case .superseded = await older.value else { Issue.record("Cancelled opening must retire"); directory.release(); return }
        directory.release()
        guard case .opened(let focus) = await newer.value else { Issue.record("Newer exact lookup must survive old cleanup"); return }
        #expect(focus.identity == service.second && focus.message.id == message.id)
        #expect(focus.matches(workspace: store.chats))
        #expect(store.selectedBotID == service.second.profile.text)
        #expect(store.chats.persisted().record(prior.owner.chat)?.draft.text == "Keep the original draft")
    }

    @Test func messageSearchDoesNotConfuseProjectedContentWithOccurrenceIdentity() async throws {
        let service = LibraryTestService()
        let projected = ChatMessage(id: "main:row:1", role: .assistant, text: "Visible Needle projection")
        service.messages[service.first] = [projected]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: ArtifactCache(root: nil))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.refreshLibrary()
        let chat = try #require(store.library.chats.first { $0.identity == service.first })
        service.messages[service.first] = [.init(id: projected.id, role: .assistant, text: "Raw Needle presentation")]
        guard case .opened(let focus) = await store.openSearchMessage(.init(chat: chat, message: projected, query: "needle")) else {
            Issue.record("The stable occurrence has a supported visible match"); return
        }
        #expect(focus.message.text == "Raw Needle presentation")
        let presentation = WorkspacePresentation()
        presentation.didChooseConversation(focusing: focus)
        presentation.selectedBotChanged(store: store)
        #expect(presentation.searchFocus?.id == focus.id, "Selection observation must preserve an already committed exact-message intent")
        presentation.reportSearchFocus(focus.id, result: .revealed)
        #expect(presentation.searchFocus?.needsReveal == false)
        #expect(!TranscriptContentRevision.sameMessage(focus.message, projected))
        #expect(SearchMessageTarget(chat: chat, message: projected, query: "projection")
            .resolve(identity: service.first, snapshot: store.chats.selection(profile: service.first.profile)?.snapshot) == nil)
        let wrong = SessionIdentity(profile: service.first.profile, root: service.first.root,
                                    stored: try ExactID("successor"), aliases: [])
        #expect(SearchMessageTarget(chat: chat, message: projected, query: "needle")
            .resolve(identity: wrong, snapshot: store.chats.selection(profile: service.first.profile)?.snapshot) == nil)
    }

    @Test func authenticationPinCallbackUsesTheNamespaceReopenedOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService(), vault = MemoryConnectionStorage()
        service.pinOnConnect = "authenticated-installation"
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        vault.saved = configuration
        let cache = ArtifactCache(root: root)
        let store = AppStore(service: service, persistence: vault.persistence, artifactCache: cache)
        let unpinnedLibrary = store.library
        #expect(await store.connect(configuration))
        #expect(store.configuration?.installID == "authenticated-installation")
        #expect(store.library !== unpinnedLibrary)
        await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        #expect(try await store.library.download(item).data == Data("main".utf8))
        let downloads = service.downloadCount, histories = service.historyOffsets.count
        let reopenedCache = ArtifactCache(root: root)
        let reopened = AppStore(service: service, persistence: vault.persistence, artifactCache: reopenedCache)
        await reopened.library.restore()
        let restored = reopened.library.artifacts.first { $0.chat.identity == service.first }
        #expect(restored != nil)
        if let restored { #expect(try await reopened.library.download(restored).data == Data("main".utf8)) }
        #expect(service.downloadCount == downloads && service.historyOffsets.count == histories)
        reopened.forgetConnection(); try await reopenedCache.drainMaintenance()
        store.forgetConnection(); try await cache.drainMaintenance()
        await cache.close(); await reopenedCache.close()
        LocalHistory.remove(for: configuration.id)
    }

    @Test(arguments: [false, true])
    func retiredGalleryReadsNeedAValidPeerBeforeRetainingBytes(validHistoricalPeer: Bool) async throws {
        let service = LibraryTestService(), cache = ArtifactCache(root: nil)
        let message = try #require(service.messages[service.first]?.first)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence, artifactCache: cache)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0]); await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        let revision = try #require(item.chat.sourceRevisions[Data(message.id.utf8)])
        let key = ArtifactOriginalKey(identity: service.first, messageID: Data(message.id.utf8), path: Data(attachment.path.utf8), sourceRevision: revision)
        let destination = try #require(store.artifactDestination(for: attachment, botID: "helper", producingMessage: message))
        let gate = StoreTestBarrier(); service.downloadBarrier = gate
        let gallery = Task { try await store.library.download(item) }
        await gate.waitUntilEntered()
        var joined = false
        let peer: Task<DownloadedArtifact, Error>? = validHistoricalPeer ? Task {
            try await store.library.original(for: key, validateNetwork: {
                guard store.isCurrentArtifactDestination(destination) else { throw HermesServiceError.staleConversation }
                joined = true
            }, download: { throw HermesServiceError.rejected(-32601) })
        } : nil
        if validHistoricalPeer {
            let deadline = ContinuousClock.now + .seconds(5)
            while !joined, ContinuousClock.now < deadline { await Task.yield() }
            #expect(joined)
        }
        let newer = ChatMessage(id: "newer", role: .assistant, text: "MEDIA:/report.txt")
        store.library.accept(identity: service.first, snapshot: .init(id: "main", storedID: "main", profileID: "helper",
            messages: [message, newer]), title: "Main")
        let deadline = ContinuousClock.now + .seconds(5)
        while store.library.artifacts.first(where: { $0.chat.identity == service.first })?.artifact.messageID != "newer", ContinuousClock.now < deadline { await Task.yield() }
        service.fileBytes = Data("late mutable bytes".utf8)
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await gallery.value }
        if let peer { #expect(try await peer.value.data == Data("late mutable bytes".utf8)) }
        let session = cache.session(scope: .init(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(configuration.username.utf8), provider: nil))
        let retained = try await session.original(for: key)
        #expect((retained != nil) == validHistoricalPeer)
        service.onEvent?(.disconnected("Gallery retirement fixture"))
        if validHistoricalPeer { #expect(try await store.downloadArtifact(destination).data == Data("late mutable bytes".utf8)) }
        else { await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination) } }
        #expect(service.downloadCount == 1)
        store.finishArtifact(destination)
    }

    @Test func anOfflineMissCanRetryUsingFreshSelectedAccess() async throws {
        let service = LibraryTestService()
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
        var deadline = ContinuousClock.now + .seconds(5)
        while reader.errorMessage == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(reader.file == nil && reader.errorMessage != nil && service.downloadCount == 0)
        #expect(await store.connect(configuration))
        reader.retry()
        deadline = .now + .seconds(5)
        while reader.file == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(reader.file?.data == Data("main".utf8))
        #expect(service.downloadCount == 1)
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination, force: true) }
        presentation.closeArtifact(id: reader.id)
    }

    @Test func historicalCardsKeepTheirOwnSamePathCaptureOffline() async throws {
        let service = LibraryTestService()
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
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0]); await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        _ = try await store.library.download(item)
        service.onEvent?(.disconnected("Offline gesture fixture"))
        let owner = try #require(store.chats.screen(profile: service.first.profile)?.owner)
        let presentation = WorkspacePresentation()
        let captured = transcriptArtifactAction(store: store, workspace: store.chats,
            botID: "helper", owner: owner, admittedBy: { true },
            onOpen: { presentation.openArtifact($0, store: store) })
        let action = try #require(captured)
        action(attachment)
        let reader = try #require(presentation.artifact)
        let deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(reader.file?.data == Data("main".utf8))
        #expect(service.downloadCount == 1)
        presentation.closeArtifact(id: reader.id)
    }

    @Test func repeatedBrowsingReusesHistoryAndOriginalFileBytes() async throws {
        let service = LibraryTestService()
        service.versionedSummaries = true
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let firstHistory = service.historyOffsets.count
        let directories = service.directoryCount
        await store.refreshLibrary()
        let repeatedHistory = service.historyOffsets.count - firstHistory
        let repeatedDirectories = service.directoryCount - directories
        let first = try await store.library.download(item)
        let second = try await store.library.download(item)
        #expect(first.data == Data("main".utf8))
        #expect(second.data == first.data)
        print("BOTTO_ARTIFACT_FETCH_COUNTS initial_history=\(firstHistory) repeated_history=\(repeatedHistory) repeated_directories=\(repeatedDirectories) file_opens=2 file_requests=\(service.downloadCount)")
        #expect(repeatedHistory == 0)
        #expect(service.downloadCount == 1)
        store.library.setOnline(false)
        do {
            let cached = try await store.library.download(item)
            #expect(cached.data == first.data)
        } catch {
            Issue.record("A downloaded original must remain readable offline: \(error)")
        }
    }

    @Test func simultaneousReadersShareAnOriginalWithoutSharingCancellation() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        await store.open(service.profiles[0])
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        let destination = try #require(store.artifactDestination(for: attachment, botID: service.first.profile.text))
        defer { store.finishArtifact(destination) }
        let barrier = StoreTestBarrier()
        service.downloadBarrier = barrier
        let first = Task { try await store.library.download(item) }
        await barrier.waitUntilEntered()
        let second = Task { try await store.downloadArtifact(destination) }
        let thumbnail = Task { await store.library.thumbnail(for: item) { _ in Data("thumbnail".utf8) } }
        for _ in 0..<20 { await Task.yield() }
        first.cancel()
        barrier.release()
        _ = try? await first.value
        #expect(try await second.value.data == Data("main".utf8))
        #expect(await thumbnail.value == Data("thumbnail".utf8))
        #expect(service.downloadCount == 1)
    }

    @Test func relaunchRestoresInlineSourceAndCapturedOriginalWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryTestService()
        service.versionedSummaries = true
        service.messages[service.first]?.append(ChatMessage(id: "inline", role: .assistant,
            text: "```html\n<h1>Saved offline</h1>\n```"))
        let vault = MemoryConnectionStorage()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let firstCache = ArtifactCache(root: root), reopenedCache = ArtifactCache(root: root)
        let first = AppStore(service: service, persistence: vault.persistence, artifactCache: firstCache)
        #expect(await first.connect(configuration))
        await first.refreshLibrary()
        let file = try #require(first.library.artifacts.first { $0.chat.identity == service.first && $0.artifact.attachment != nil })
        #expect(try await first.library.download(file).data == Data("main".utf8))
        let histories = service.historyOffsets.count, downloads = service.downloadCount, directories = service.directoryCount
        let reopened = AppStore(service: service, persistence: vault.persistence, artifactCache: reopenedCache)
        await reopened.library.restore()
        let restored = try #require(reopened.library.artifacts.first { $0.chat.identity == service.first && $0.artifact.attachment != nil })
        #expect(try await reopened.library.download(restored).data == Data("main".utf8))
        let inline = try #require(reopened.library.artifacts.first { $0.artifact.block != nil })
        #expect(try await reopened.library.download(inline).data == Data("<h1>Saved offline</h1>\n".utf8))
        #expect(service.historyOffsets.count == histories)
        #expect(service.downloadCount == downloads)
        #expect(service.directoryCount == directories)
        #expect(reopened.chats.screen(profile: service.first.profile)?.canAct != true)
        reopened.forgetConnection()
        await firstCache.close(); await reopenedCache.close()
    }

    @Test func explicitRefreshChecksHistoryAndReloadCapturesChangedBytes() async throws {
        let service = LibraryTestService()
        service.versionedSummaries = true
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        #expect(try await store.library.download(item).data == Data("main".utf8))
        let history = service.historyOffsets.count
        await store.refreshLibrary(force: true)
        #expect(service.historyOffsets.count > history)
        service.fileBytes = Data("updated capture".utf8)
        #expect(try await store.library.download(item).data == Data("main".utf8))
        #expect(try await store.library.download(item, force: true).data == Data("updated capture".utf8))
        store.library.setOnline(false)
        #expect(try await store.library.download(item).data == Data("updated capture".utf8))
        #expect(service.downloadCount == 2)
    }

    @Test func acceptedOpenIndexesOutputsWithoutLibraryHistoryScan() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let deadline = ContinuousClock.now + .seconds(5)
        while store.library.artifacts.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(store.library.artifacts.first?.artifact.title == "report.txt")
        #expect(service.historyOffsets.isEmpty)
    }

    @Test func offlineChatPreviewSharesTheLibraryCaptureAndRejectsAnOldSemanticOwner() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let item = try #require(store.library.artifacts.first { $0.chat.identity == service.first })
        let attachment = try #require(item.artifact.attachment)
        #expect(try await store.library.download(item).data == Data("main".utf8))
        service.onEvent?(.disconnected("Offline fixture"))
        let destination = try #require(store.artifactDestination(for: attachment, botID: service.first.profile.text))
        #expect(!store.isCurrentArtifactDestination(destination))
        #expect(store.isAuthorizedArtifactPresentation(destination))
        #expect(try await store.downloadArtifact(destination).data == Data("main".utf8))
        let presentation = WorkspacePresentation()
        presentation.openArtifact(destination, store: store)
        let reader = try #require(presentation.artifact)
        let deadline = ContinuousClock.now + .seconds(5)
        while reader.file == nil && ContinuousClock.now < deadline { await Task.yield() }
        #expect(reader.file?.data == Data("main".utf8))
        #expect(reader.isCurrent)
        #expect(service.downloadCount == 1)
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination, force: true) }
        store.selectedBotID = nil
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination) }
        presentation.closeArtifact(id: reader.id)
        store.finishArtifact(destination)
    }

    @Test func failedSecureForgetPreservesCaptureAndSuccessfulForgetPurgesColdReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = MemoryConnectionStorage()
        var removalFails = true
        let persistence = ConnectionPersistence(load: { vault.saved }, save: { vault.saved = $0 }, remove: {
            if removalFails { throw HermesServiceError.disconnected }
            vault.saved = nil
        })
        let cache = ArtifactCache(root: root)
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: persistence, artifactCache: cache)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        let library = store.library
        let item = try #require(library.artifacts.first { $0.chat.identity == service.first })
        #expect(try await library.download(item).data == Data("main".utf8))
        store.forgetConnection()
        #expect(store.configuration?.id == configuration.id)
        #expect(store.library === library)
        #expect(!library.isRetired)
        library.setOnline(false)
        #expect(try await library.download(item).data == Data("main".utf8))
        removalFails = false
        store.forgetConnection()
        try await cache.drainMaintenance()
        vault.saved = configuration
        let reopenedCache = ArtifactCache(root: root)
        let reopened = AppStore(service: service, persistence: vault.persistence, artifactCache: reopenedCache)
        await reopened.library.restore()
        #expect(reopened.library.artifacts.isEmpty)
        #expect(library.isRetired)
        await cache.close(); await reopenedCache.close()
    }

    @Test func streamingSnapshotsCoalescePerChatAndSettleTheirLatestOutput() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        let older = (0..<500).map { ChatMessage(id: "old-\($0)", role: .assistant, text: "Earlier reply \($0)") }
        var hookDuration: Duration = .zero
        for number in 0..<1_000 {
            let source = number.isMultiple(of: 2) ? service.first : service.second
            let snapshot = Conversation(id: source.root.text, storedID: source.stored.text, profileID: source.profile.text,
                messages: older + [ChatMessage(id: "output", role: .assistant, text: "MEDIA:/draft-\(number).txt")], isWorking: true)
            let started = ContinuousClock.now
            library.accept(identity: source, snapshot: snapshot, title: source.root.text)
            hookDuration += started.duration(to: .now)
        }
        for source in [service.first, service.second] {
            library.accept(identity: source, snapshot: .init(id: source.root.text, storedID: source.stored.text,
                profileID: source.profile.text, messages: older + [ChatMessage(id: "output", role: .assistant,
                    text: "MEDIA:/settled-\(source.root.text).txt")]), title: source.root.text)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while library.artifacts.count < 2 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(Set(library.artifacts.map(\.artifact.title)) == ["settled-main.txt", "settled-side.txt"])
        let metrics = library.indexingMetrics
        #expect(metrics.acceptedSnapshots == 1_002)
        #expect(metrics.batches < 10)
        print("BOTTO_ARTIFACT_STREAMING snapshots=\(metrics.acceptedSnapshots) batches=\(metrics.batches) parsed_messages=\(metrics.parsedMessages) hook_total=\(hookDuration) worker_total=\(metrics.processingDuration)")
        library.retire()
    }

    @Test func weakSummaryUsesOneHeadProbeAndExplicitRefreshFindsAnOlderEdit() async throws {
        let service = LibraryTestService()
        service.hiddenFirstPage = true
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(bots: service.profiles)
        let initial = service.historyOffsets.count
        service.messages[service.first] = [ChatMessage(id: "main-file", role: .assistant, text: "MEDIA:/changed.txt")]
        await library.refresh(bots: service.profiles)
        #expect(service.historyOffsets.count - initial == 2)
        #expect(library.artifacts.contains { $0.chat.identity == service.first && $0.artifact.title == "report.txt" })
        #expect(library.warning?.contains("haven’t been checked") == true)
        await library.refresh(bots: service.profiles, force: true)
        #expect(library.artifacts.contains { $0.chat.identity == service.first && $0.artifact.title == "changed.txt" })
    }

    @Test func unchangedHistoryUpdatesRenamedChatAndBotWithoutHistoryReads() async throws {
        let service = LibraryTestService()
        service.versionedSummaries = true
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(bots: service.profiles)
        let initial = service.historyOffsets.count
        service.summaryTitle = "Renamed notes"
        await library.refresh(bots: [BotProfile(id: "helper", name: "Renamed Helper")])
        #expect(service.historyOffsets.count == initial)
        #expect(library.chats.first { $0.identity == service.second }?.title == "Renamed notes")
        #expect(library.chats.allSatisfy { $0.botName == "Renamed Helper" })
    }

    @Test func explicitRefreshDuringAnOrdinaryScanRunsAForcedFollowUp() async throws {
        let service = LibraryTestService()
        service.versionedSummaries = true
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        let barrier = StoreTestBarrier()
        service.historyBarrier = barrier
        let ordinary = Task { await library.refresh(bots: service.profiles) }
        await barrier.waitUntilEntered()
        let forced = Task { await library.refresh(bots: service.profiles, force: true) }
        for _ in 0..<20 { await Task.yield() }
        service.historyBarrier = nil
        barrier.release()
        await ordinary.value
        await forced.value
        #expect(service.historyOffsets.count == 4)
        #expect(service.directoryCount == 2)
    }

    @Test(arguments: ["success", "failure", "cancel", "failure-recovery", "cancel-recovery"])
    func foregroundRestorationCannotOverrideANewerLibraryLookup(_ outcome: String) async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let workspace = store.chats
        let original = try #require(workspace.screen(profile: service.first.profile))
        let oldAccess = try #require(service.lastAccess)
        workspace.editDraft("kept through foreground lookup", owner: original.owner)
        let choice = workspace.persisted().preference(service.first.profile)?.lastSelected
        let target = try #require(store.library.chats.first { $0.identity == service.second })

        let refreshGate = StoreTestBarrier(), otherRefreshGate = StoreTestBarrier()
        service.directoryBarriers = [service.first.profile: refreshGate, service.second.profile: otherRefreshGate]
        let reconnecting = Task { await store.connect(configuration) }
        await refreshGate.waitUntilEntered()
        await otherRefreshGate.waitUntilEntered()
        otherRefreshGate.release()
        let lookupGate = StoreTestBarrier()
        service.directoryBarriers[service.second.profile] = lookupGate
        let newer = Task { await store.openLibraryChat(target) }
        await lookupGate.waitUntilEntered()
        let opens = service.openCount
        refreshGate.release()
        #expect(await reconnecting.value)
        #expect(service.openCount == opens, "Automatic restoration cannot clear a newer lookup's claim")
        #expect(workspace.persisted().preference(service.first.profile)?.lastSelected == choice)
        #expect(workspace.persisted().record(original.owner.chat)?.draft.text == "kept through foreground lookup")

        let recoveryFails = outcome.hasSuffix("-recovery")
        if recoveryFails { service.failingSource = service.first }
        if outcome.hasPrefix("failure") { service.failDirectory = true }
        if outcome.hasPrefix("cancel") { newer.cancel() }
        lookupGate.release()
        let opened = await newer.value
        #expect(opened == (outcome == "success"))
        let expected = outcome == "success" ? service.second : service.first
        #expect(store.selectedBotID == expected.profile.text)
        #expect(workspace.selection(profile: expected.profile)?.identity?.root == expected.root)
        let current = try #require(workspace.screen(profile: expected.profile))
        #expect(current.canAct == !recoveryFails)
        #expect(current.canEditDraft)
        if recoveryFails {
            #expect(workspace.captureSend(current.owner) == nil)
            #expect(throws: (any Error).self) { try service.source(for: oldAccess) }
        } else {
            #expect(try service.source(for: #require(service.lastAccess)).root == expected.root)
        }
        #expect(workspace.persisted().preference(service.first.profile)?.lastSelected == choice)
        #expect(workspace.persisted().record(original.owner.chat)?.draft.text == "kept through foreground lookup")
        workspace.editDraft("edited after lookup", owner: current.owner)
        #expect(workspace.draft(current.owner) == "edited after lookup")
    }

    @Test(arguments: [false, true])
    func olderCreationCannotOverrideANewerLibraryLookup(dispatched: Bool) async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let workspace = store.chats
        let original = try #require(workspace.screen(profile: service.first.profile))
        let choice = workspace.persisted().preference(service.first.profile)?.lastSelected
        let intent = try #require(workspace.captureCreation(original.owner))
        let creationGate = StoreTestBarrier()
        var creating: Task<Void, Never>?
        if dispatched {
            service.creationBarrier = creationGate
            creating = Task { await workspace.create(intent) }
            await creationGate.waitUntilEntered()
        }
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let directory = StoreTestBarrier()
        service.directoryBarrier = directory
        let newer = Task { await store.openLibraryChat(target) }
        await directory.waitUntilEntered()
        let opens = service.openCount
        if let creating { creationGate.release(); await creating.value }
        else { await workspace.create(intent) }
        #expect(service.creationCount == 1)
        #expect(service.openCount == opens)
        #expect(workspace.screen(profile: service.first.profile)?.owner.chat == original.owner.chat)
        #expect(workspace.persisted().preference(service.first.profile)?.lastSelected == choice)
        let receipt = try #require(service.createdIdentity)
        let retained = try #require(workspace.persisted().records.first {
            $0.binding.identity?.profile == receipt.profile && $0.binding.identity?.root == receipt.root
        })
        #expect(retained.binding.identity?.stored == receipt.stored)
        directory.release()

        #expect(await newer.value)
        #expect(store.selectedBotID == service.second.profile.text)
        #expect(workspace.screen(profile: service.second.profile)?.canAct == true)
    }

    @Test func olderAttentionLookupCannotOverrideANewerLibraryLookup() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let workspace = store.chats
        let original = try #require(workspace.screen(profile: service.first.profile))
        let attentionGate = StoreTestBarrier()
        service.directoryBarrier = attentionGate
        let intent = try #require(workspace.captureOpening(profile: service.first.profile, attention: true))
        let attention = Task { await workspace.open(intent) }
        await attentionGate.waitUntilEntered()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let directory = StoreTestBarrier()
        service.directoryBarrier = directory
        let newer = Task { await store.openLibraryChat(target) }
        await directory.waitUntilEntered()
        service.directoryActivity[service.second] = .known(.waiting, .distantFuture)
        let opens = service.openCount
        attentionGate.release(); await attention.value
        #expect(service.openCount == opens)
        #expect(workspace.screen(profile: service.first.profile)?.owner.chat == original.owner.chat)
        directory.release()

        #expect(await newer.value)
        #expect(workspace.selection(profile: service.second.profile)?.identity == service.second)
        #expect(workspace.screen(profile: service.second.profile)?.canAct == true)
    }

    @Test(arguments: [false, true], [false, true])
    func unsuccessfulAttachmentPreservesTheOriginalEditableChat(cancel: Bool, otherBot: Bool) async throws {
        let service = LibraryTestService(secondBot: otherBot)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let before = try #require(store.chats.screen(profile: service.first.profile))
        let oldAccess = try #require(service.lastAccess)
        store.chats.editDraft("Keep my original draft", owner: before.owner)
        let originalChoice = store.chats.persisted().preference(service.first.profile)?.lastSelected
        let targetChoice = store.chats.persisted().preference(service.second.profile)?.lastSelected
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let gate = StoreTestBarrier()
        service.openingBarrier = gate
        service.gatedSource = service.second
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        if cancel { opening.cancel() }
        else { service.failingSource = service.second }
        gate.release()

        #expect(!(await opening.value))

        let returned = try #require(store.chats.screen(profile: service.first.profile))
        #expect(store.selectedBotID == service.first.profile.text)
        #expect(returned.owner.chat == before.owner.chat)
        #expect(returned.canEditDraft)
        #expect(returned.canAct)
        #expect(store.chats.draft(returned.owner) == "Keep my original draft")
        #expect(store.chats.persisted().preference(service.first.profile)?.lastSelected == originalChoice)
        #expect(store.chats.persisted().preference(service.second.profile)?.lastSelected == targetChoice)
        let restoredAccess = try #require(service.lastAccess)
        #expect(restoredAccess != oldAccess)
        #expect(try service.source(for: restoredAccess) == service.first)
        #expect(throws: (any Error).self) { try service.source(for: oldAccess) }
    }

    @Test func cancelledAttachmentCannotRestoreOverANewerBotChoice() async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let gate = StoreTestBarrier()
        service.openingBarrier = gate; service.gatedSource = service.second
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        opening.cancel()
        service.openingBarrier = nil
        await store.open(service.profiles[1])
        let newerAccess = try #require(service.lastAccess)
        let opens = service.openCount
        gate.release()

        #expect(!(await opening.value))

        #expect(store.selectedBotID == service.second.profile.text)
        #expect(store.chats.screen(profile: service.second.profile)?.canAct == true)
        #expect(service.openCount == opens)
        #expect(service.lastAccess == newerAccess)
        #expect(try service.source(for: newerAccess) == service.second)
    }

    @Test(arguments: [false, true], [false, true])
    func newerLibraryLookupOwnsNavigationWhileCancelledAttachmentDrains(directoryFails: Bool, cancelNewer: Bool) async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let original = try #require(store.chats.screen(profile: service.first.profile))
        store.chats.editDraft("Keep my first chat", owner: original.owner)
        await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let attachment = StoreTestBarrier()
        service.openingBarrier = attachment; service.gatedSource = service.second
        let cancelled = Task { await store.openLibraryChat(target) }
        await attachment.waitUntilEntered()
        cancelled.cancel()
        service.openingBarrier = nil
        let directory = StoreTestBarrier()
        service.directoryBarrier = directory
        let newer = Task { await store.openLibraryChat(target) }
        await directory.waitUntilEntered()
        attachment.release()
        #expect(!(await cancelled.value))
        service.failDirectory = directoryFails
        if cancelNewer { newer.cancel() }
        directory.release()

        #expect(await newer.value == (!directoryFails && !cancelNewer))

        let expected = directoryFails || cancelNewer ? service.first : service.second
        #expect(store.selectedBotID == expected.profile.text)
        #expect(store.chats.screen(profile: expected.profile)?.canAct == true)
        #expect(try service.source(for: #require(service.lastAccess)) == expected)
        #expect(store.chats.persisted().record(original.owner.chat)?.draft.text == "Keep my first chat")
    }

    @Test(arguments: [false, true])
    func queuedNavigationCannotSupersedeANewerLibraryLookup(picker: Bool) async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let workspace = store.chats
        let queued: @MainActor () async -> Void
        if picker {
            let screen = try #require(workspace.screen(profile: service.first.profile))
            let intent = try #require(workspace.captureSelection(screen.owner.chat, owner: screen.owner))
            queued = { await workspace.select(intent) }
        } else {
            let intent = try #require(workspace.captureOpening(profile: service.first.profile))
            queued = { await workspace.open(intent) }
        }
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let directory = StoreTestBarrier()
        service.directoryBarrier = directory
        let newer = Task { await store.openLibraryChat(target) }
        await directory.waitUntilEntered()
        let opens = service.openCount
        await queued()
        #expect(service.openCount == opens)
        directory.release()

        #expect(await newer.value)

        #expect(store.selectedBotID == service.second.profile.text)
        #expect(workspace.screen(profile: service.second.profile)?.canAct == true)
    }

    @Test func retiredLibraryCannotCommitAnOtherwiseSuccessfulAttachment() async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let gate = StoreTestBarrier()
        service.openingBarrier = gate; service.gatedSource = service.second
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        store.library.retire()
        gate.release()

        #expect(!(await opening.value))

        #expect(store.selectedBotID == service.first.profile.text)
        #expect(store.chats.screen(profile: service.first.profile)?.canAct == true)
        #expect(try service.source(for: #require(service.lastAccess)) == service.first)
    }

    @Test func failedRestorationKeepsTheOriginalDraftEditableWithoutRevivingAccess() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let before = try #require(store.chats.screen(profile: service.first.profile))
        let oldAccess = try #require(service.lastAccess)
        store.chats.editDraft("Keep editing locally", owner: before.owner)
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let gate = StoreTestBarrier()
        service.openingBarrier = gate; service.gatedSource = service.second
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        service.failingSource = service.first
        opening.cancel(); gate.release()

        #expect(!(await opening.value))

        let returned = try #require(store.chats.screen(profile: service.first.profile))
        #expect(returned.owner.chat == before.owner.chat)
        #expect(returned.canEditDraft)
        #expect(!returned.canAct)
        #expect(returned.error != nil)
        #expect(store.chats.draft(returned.owner) == "Keep editing locally")
        #expect(throws: (any Error).self) { try service.source(for: oldAccess) }
    }

    @Test func cachedLibraryChatOpensOfflineWithItsDraftAndNoNewAttachment() async throws {
        let service = LibraryTestService(secondBot: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let original = try #require(store.chats.screen(profile: service.first.profile))
        store.chats.editDraft("My saved offline draft", owner: original.owner)
        await store.refreshLibrary()
        let first = try #require(store.library.chats.first { $0.identity == service.first })
        let second = try #require(store.library.chats.first { $0.identity == service.second })
        #expect(await store.openLibraryChat(second))
        service.onEvent?(.disconnected("Offline"))
        let opens = service.openCount

        #expect(await store.openLibraryChat(first))

        let returned = try #require(store.chats.screen(profile: service.first.profile))
        #expect(store.selectedBotID == service.first.profile.text)
        #expect(returned.owner.chat == original.owner.chat)
        #expect(returned.canEditDraft && !returned.canAct)
        #expect(store.chats.draft(returned.owner) == "My saved offline draft")
        #expect(service.openCount == opens)
    }

    @Test func failedDirectoryCannotReportThePreviouslySelectedChatAsOpened() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.first })
        let opens = service.openCount
        service.failDirectory = true

        #expect(!(await store.openLibraryChat(target)))
        #expect(service.openCount == opens)
    }

    @Test func cancelledDirectoryOpenDoesNotSelectItsBot() async throws {
        let service = LibraryTestService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        let target = try #require(store.library.chats.first { $0.identity == service.second })
        let gate = StoreTestBarrier()
        service.directoryBarrier = gate
        let opening = Task { await store.openLibraryChat(target) }
        await gate.waitUntilEntered()
        opening.cancel()
        gate.release()
        #expect(!(await opening.value))
        #expect(store.selectedBotID == nil)
    }

    @Test func libraryReaderRetainsOriginalBytesOfflineAndRevokesOnRetirement() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(bots: service.profiles)
        let item = try #require(library.artifacts.first { $0.chat.identity == service.first })
        let session = LibraryArtifactPreviewSession(item: item, library: library)
        defer { session.finish() }
        session.retry()
        let deadline = ContinuousClock.now + .seconds(5)
        while session.file == nil && ContinuousClock.now < deadline { await Task.yield() }
        let original = try #require(session.file)
        #expect(original.data == Data("main".utf8))
        library.setOnline(false)
        session.beginOutput(.share)
        #expect(session.isCurrent)
        #expect(session.output?.file === original)
        library.retire()
        #expect(!session.isCurrent)
        #expect(session.file == nil)
        #expect(session.output == nil)
        #expect(original.data == Data("main".utf8))
    }

    @Test func searchLoadsOnlyNearbyArtifactCovers() async throws {
        let service = LibraryTestService()
        service.messages[service.first] = (0..<60).map {
            ChatMessage(id: "image-\($0)", role: .assistant, text: "MEDIA:/chart-\($0).png")
        }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        #expect(await store.connect(configuration))
        await store.refreshLibrary()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: WorkspaceSearchView(store: store, library: store.library,
            query: .constant("chart"), onBot: { _ in }, onChat: { _ in }, onArtifact: { _ in }, onMessage: { _ in }))
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            store.forgetConnection(); LocalHistory.remove(for: configuration.id)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while service.downloadCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(service.downloadCount > 0)
        try await Task.sleep(for: .seconds(1))
        print("BOTTO_SEARCH_COVERS total=60 requested=\(service.downloadCount)")
        #expect(service.downloadCount < 24)
    }

    @Test func searchHighlightsEveryReadableMatchWithoutChangingUnicode() {
        let text = "👩🏽‍💻 Café and CAFE, with café again."
        let highlighted = SearchHighlightedText.attributed(text, query: "cafe")
        #expect(Data(String(highlighted.characters).utf8) == Data(text.utf8))
        let hits = highlighted.runs.filter { $0.backgroundColor != nil }.map {
            String(highlighted[$0.range].characters)
        }
        #expect(hits == ["Café", "CAFE", "café"])
        #expect(SearchHighlightedText.attributed(text, query: "").runs.allSatisfy { $0.backgroundColor == nil })
    }

    @Test func hiddenLinkTargetsDoNotCreateFalseSearchOverflow() async throws {
        let service = LibraryTestService()
        service.messages[service.first] = [ChatMessage(id: "hidden-target", role: .assistant,
            text: "[Read the guide](https://example.test/needle)")] + (0..<50).map {
                ChatMessage(id: "visible-\($0)", role: .assistant, text: "Needle result \($0)")
            }
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true); await library.refresh(bots: service.profiles)
        let results = LibrarySearchResults(query: "needle", bots: service.profiles,
            chats: library.chats, artifacts: library.artifacts)
        #expect(results.messages.count == 50)
        #expect(!results.hasMoreMessages)
        library.retire()
    }

    @Test func searchSnippetsUseReadableTextAndVisibleMatches() async throws {
        let service = LibraryTestService()
        service.messages[service.first] = [ChatMessage(id: "readable", role: .assistant,
            text: "A **Café** update with [notes](https://example.test/hidden-token).")]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true); await library.refresh(bots: service.profiles)
        let visible = LibrarySearchResults(query: "cafe", bots: service.profiles,
            chats: library.chats, artifacts: library.artifacts)
        #expect(visible.messages.first?.snippet == "A Café update with notes.")
        let hidden = LibrarySearchResults(query: "hidden-token", bots: service.profiles,
            chats: library.chats, artifacts: library.artifacts)
        #expect(hidden.messages.isEmpty)
        library.retire()
    }

    @Test func searchGroupsVisibleContentAndKeepsSiblingOrigins() async throws {
        let service = LibraryTestService()
        service.messages[service.second] = [
            ChatMessage(id: "hidden", role: .assistant, text: "Needle internal", displayKind: "hidden"),
            ChatMessage(id: "tool", role: .tool, text: "Needle diagnostic"),
            ChatMessage(id: "answer", role: .assistant, text: "Here is the Needle you asked for.\nMEDIA:/Needle.pdf")
        ]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(bots: service.profiles)
        let result = LibrarySearchResults(query: "needle", bots: service.profiles,
            chats: library.chats, artifacts: library.artifacts)
        #expect(result.messages.count == 1)
        #expect(result.messages.first?.message.id == "answer")
        #expect(result.messages.first?.chat.identity == service.second)
        #expect(result.artifacts.first?.artifact.title == "Needle.pdf")
        #expect(result.artifacts.first?.chat.identity == service.second)
        #expect(!result.hasMoreMessages)
        let empty = LibrarySearchResults(query: "missing", bots: service.profiles,
            chats: library.chats, artifacts: library.artifacts)
        #expect(empty.isEmpty)
    }

    @Test func indexingKeepsTheSelectedChatDraftAndUnreadState() async throws {
        let service = LibraryTestService()
        let storage = MemoryConnectionStorage()
        let store = AppStore(service: service, persistence: storage.persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        let before = try #require(store.chats.screen(profile: service.first.profile))
        store.chats.editDraft("Keep this draft", owner: before.owner)
        let seen = store.chats.persisted().record(before.owner.chat)?.seen
        let openCount = service.openCount

        await store.refreshLibrary()

        #expect(store.chats.screen(profile: service.first.profile)?.owner == before.owner)
        #expect(store.chats.draft(before.owner) == "Keep this draft")
        #expect(store.chats.persisted().record(before.owner.chat)?.seen?.messageID == seen?.messageID)
        #expect(service.openCount == openCount)
        #expect(store.library.artifacts.count == 2)
        #expect(Set(store.library.artifacts.map(\.id)).count == 2)
    }

    @Test func failedRefreshKeepsLoadedResultsAndReportsIncompleteHistory() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(bots: service.profiles)
        let loaded = library.artifacts.map(\.id)
        service.failHistory = true

        await library.refresh(bots: service.profiles)

        #expect(library.artifacts.map(\.id) == loaded)
        #expect(library.warning != nil)
        #expect(!library.isLoading)
    }

    @Test func seedingAShorterCachedTranscriptCannotEraseIndexedOutputs() async throws {
        let service = LibraryTestService()
        service.messages[service.first] = [
            ChatMessage(id: "older", role: .assistant, text: "MEDIA:/older.pdf"),
            ChatMessage(id: "latest", role: .assistant, text: "MEDIA:/latest.pdf")
        ]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(bots: service.profiles)
        var cached = ConversationBook()
        let id = cached.merge(.init(identity: service.first, title: "Main", isCanonical: true, persistence: .durable))
        cached.cache(.init(id: "main", storedID: "main", profileID: "helper",
            messages: [service.messages[service.first]!.last!]), for: id)

        library.seed(book: cached, bots: service.profiles)
        await library.restore()

        #expect(library.chats.first { $0.identity == service.first }?.messages.count == 2)
        #expect(library.artifacts.contains { $0.artifact.attachment?.path == "/older.pdf" })
    }

    @Test func hiddenMessagePagesDoNotStopHistoryIndexing() async throws {
        let service = LibraryTestService()
        service.hiddenFirstPage = true
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)

        await library.refresh(bots: service.profiles)

        #expect(library.artifacts.count == 2)
        #expect(service.historyOffsets.contains(100))
        #expect(library.warning == nil)
    }

    @Test func cancelledScanLabelsItsPartialResults() async throws {
        let service = LibraryTestService()
        let gate = StoreTestBarrier()
        service.historyBarrier = gate
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        let reading = Task { await library.refresh(bots: service.profiles) }
        await gate.waitUntilEntered()
        reading.cancel()
        gate.release()
        await reading.value
        #expect(library.warning != nil)
        #expect(!library.isLoading)
    }

    @Test func observedTipChangesRetireOldFilesBeforeReplacementHistoryArrives() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(bots: service.profiles)
        let original = try #require(library.artifacts.first { $0.chat.identity == service.first })
        service.replacementFirst = SessionIdentity(profile: service.first.profile, root: service.first.root,
            stored: try ExactID("new-tip"), aliases: [service.first.stored])
        let gate = StoreTestBarrier()
        service.historyBarrier = gate
        let refreshing = Task { await library.refresh(bots: service.profiles) }
        await gate.waitUntilEntered()

        #expect(!library.isCurrent(original))

        service.historyBarrier = nil
        gate.release()
        await refreshing.value
    }

    @Test func retirementRejectsLateHistoryAndDownloadCompletions() async throws {
        let service = LibraryTestService()
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        let history = StoreTestBarrier()
        service.historyBarrier = history
        let reading = Task { await library.refresh(bots: service.profiles) }
        await history.waitUntilEntered()
        library.retire()
        history.release()
        await reading.value
        #expect(library.isRetired)
        #expect(library.artifacts.isEmpty)

        service.historyBarrier = nil
        let current = WorkspaceLibrary(service: service)
        current.setOnline(true)
        await current.refresh(bots: service.profiles)
        let artifact = try #require(current.artifacts.first)
        let download = StoreTestBarrier()
        service.downloadBarrier = download
        let loading = Task { try await current.download(artifact) }
        await download.waitUntilEntered()
        current.retire()
        download.release()
        await #expect(throws: (any Error).self) { _ = try await loading.value }
    }

    @Test func offlineFilesRequireAConnectionButInlineOutputsRemainReadable() async throws {
        let service = LibraryTestService()
        service.messages[service.first] = [
            ChatMessage(id: "file", role: .assistant, text: "MEDIA:/report.txt"),
            ChatMessage(id: "visual", role: .assistant, text: "```html\n<h1>Offline visual</h1>\n```\n")
        ]
        let library = WorkspaceLibrary(service: service)
        library.setOnline(true)
        await library.refresh(bots: service.profiles)
        let file = try #require(library.artifacts.first { $0.artifact.attachment != nil })
        let inline = try #require(library.artifacts.first { $0.artifact.block != nil })
        library.setOnline(false)
        let calls = service.downloadCount
        await #expect(throws: (any Error).self) { _ = try await library.download(file) }
        #expect(service.downloadCount == calls)
        let bytes = try await library.download(inline)
        #expect(String(data: bytes.data, encoding: .utf8)?.contains("Offline visual") == true)
    }

    @Test func searchDestinationOpensTheExactSiblingChat() async throws {
        let service = LibraryTestService()
        let storage = MemoryConnectionStorage()
        let store = AppStore(service: service, persistence: storage.persistence)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.refreshLibrary()
        let sibling = try #require(store.library.chats.first { $0.identity == service.second })

        #expect(await store.openLibraryChat(sibling))

        #expect(store.selectedBotID == sibling.botID)
        #expect(store.chats.selection(profile: service.second.profile)?.identity?.root == service.second.root)
        #expect(service.lastOpened?.root == service.second.root)
    }

    @Test func replacingTheMountedWorkspaceRetiresItsLibraryDestinations() async throws {
        let service = LibraryTestService()
        let storage = MemoryConnectionStorage()
        let store = AppStore(service: service, persistence: storage.persistence)
        let original = ConnectionConfiguration(serverURL: URL(string: "https://library.example")!)
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://other.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: original.id); LocalHistory.remove(for: replacement.id) }
        #expect(await store.connect(original))
        await store.refreshLibrary()
        let oldLibrary = store.library
        let oldArtifact = try #require(oldLibrary.artifacts.first)

        #expect(await store.connect(replacement))

        #expect(oldLibrary.isRetired)
        #expect(store.library !== oldLibrary)
        #expect(!store.library.isCurrent(oldArtifact))
        #expect(!(await store.openLibraryChat(oldArtifact.chat)))
        let downloads = service.downloadCount
        await #expect(throws: (any Error).self) { _ = try await oldLibrary.download(oldArtifact) }
        #expect(service.downloadCount == downloads)
    }
}

@MainActor private final class LibraryTestService: BotService {
    var onEvent: ((BotServiceEvent) -> Void)?
    let profiles: [BotProfile]
    let first = SessionIdentity(profile: try! ExactID("helper"), root: try! ExactID("main"),
        stored: try! ExactID("main"), aliases: [try! ExactID("main")])
    let second: SessionIdentity
    var messages: [SessionIdentity: [ChatMessage]] = [:]
    var failHistory = false
    var failDirectory = false
    var versionedSummaries = false
    var directoryCount = 0
    var directoryBarrier: StoreTestBarrier?
    var directoryBarriers: [ExactID: StoreTestBarrier] = [:]
    var directoryActivity: [SessionIdentity: ObservedActivity] = [:]
    var creationBarrier: StoreTestBarrier?
    var creationCount = 0
    var createdIdentity: SessionIdentity?
    var openingBarrier: StoreTestBarrier?
    var gatedSource: SessionIdentity?
    var failingSource: SessionIdentity?
    var replacementFirst: SessionIdentity?
    var hiddenFirstPage = false
    var historyOffsets: [Int] = []
    var historyBarrier: StoreTestBarrier?
    var downloadBarrier: StoreTestBarrier?
    var openCount = 0
    var summaryTitle = "Research notes"
    var fileBytes: Data?
    var pinOnConnect: String?
    var downloadCount = 0
    var lastOpened: SessionIdentity?
    private(set) var lastAccess: ConversationAccess?
    private var issuer = ConversationIssuer<SessionIdentity>()
    private var selectionGeneration = 0

    init(secondBot: Bool = false) {
        profiles = [BotProfile(id: "helper", name: "Helper")] + (secondBot ? [BotProfile(id: "other", name: "Other")] : [])
        second = SessionIdentity(profile: try! ExactID(secondBot ? "other" : "helper"), root: try! ExactID("side"),
            stored: try! ExactID("side"), aliases: [try! ExactID("side")])
        messages[first] = [ChatMessage(id: "main-file", role: .assistant, text: "MEDIA:/report.txt")]
        messages[second] = [ChatMessage(id: "side-file", role: .assistant, text: "MEDIA:/report.txt")]
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
    func createBot(_ draft: BotDraft) async throws -> BotProfile { throw HermesServiceError.rejected(-32601) }
    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        directoryCount += 1
        await (directoryBarriers[profile] ?? directoryBarrier)?.wait()
        if failDirectory { throw HermesServiceError.disconnected }
        var summaries: [SessionSummary] = [
            .init(identity: replacementFirst ?? first, title: "Main", isCanonical: true, persistence: .durable),
            .init(identity: second, title: summaryTitle, isCanonical: second.profile != first.profile, persistence: .durable)
        ]
        if let createdIdentity { summaries.append(.init(identity: createdIdentity, title: "Created", isCanonical: false, persistence: .durable)) }
        let scoped = summaries.filter { $0.identity.profile == profile }.map { summary in
            guard versionedSummaries else { return summary }
            return SessionSummary(identity: summary.identity, title: summary.title, isCanonical: summary.isCanonical,
                persistence: summary.persistence, updatedAt: Date(timeIntervalSince1970: 1_000),
                messageCount: messages[summary.identity]?.count)
        }
        return .init(summaries: scoped, activity: directoryActivity, isComplete: true)
    }
    func conversationHistory(_ identity: SessionIdentity, offset: Int) async throws -> ConversationHistoryPage {
        historyOffsets.append(offset)
        await historyBarrier?.wait()
        if failHistory { throw HermesServiceError.disconnected }
        if hiddenFirstPage, offset == 0 { return .init(messages: [], nextOffset: 100, isComplete: true) }
        return .init(messages: messages[identity] ?? [], nextOffset: nil, isComplete: true)
    }
    func downloadArtifact(_ attachment: ChatAttachment, in identity: SessionIdentity) async throws -> DownloadedArtifact {
        downloadCount += 1
        await downloadBarrier?.wait()
        return .init(data: fileBytes ?? Data(identity.root.text.utf8), filename: attachment.name, mimeType: "text/plain")
    }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession {
        creationCount += 1
        await creationBarrier?.wait()
        let identity = SessionIdentity(profile: profile, root: try ExactID("created"), stored: try ExactID("created"), aliases: [])
        createdIdentity = identity
        messages[identity] = []
        return .init(operationID: operationID,
            summary: .init(identity: identity, title: "Created", isCanonical: false, persistence: .durable))
    }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        openCount += 1
        selectionGeneration += 1
        let owner = selectionGeneration
        issuer.retireAttachment()
        let identity: SessionIdentity
        switch target {
        case .canonical(let profile, _): identity = profile == first.profile ? first : second
        case .stored(let source): identity = source
        }
        if identity == gatedSource { await openingBarrier?.wait() }
        guard selectionGeneration == owner else { throw HermesServiceError.staleConversation }
        if identity == failingSource { throw HermesServiceError.missingChat }
        lastOpened = identity
        let access = try issuer.issue(identity)
        lastAccess = access
        return .init(identity: identity, snapshot: .init(id: identity.root.text, storedID: identity.stored.text,
            profileID: identity.profile.text, messages: messages[identity] ?? []), access: access)
    }
    func source(for access: ConversationAccess) throws -> SessionIdentity { try issuer.resolve(access) }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw HermesServiceError.rejected(-32601) }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw HermesServiceError.rejected(-32601) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw HermesServiceError.rejected(-32601) }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment { throw HermesServiceError.rejected(-32601) }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        let identity = try issuer.resolve(access)
        let result = try await downloadArtifact(attachment, in: identity)
        guard try issuer.resolve(access) == identity else { throw HermesServiceError.staleConversation }
        return result
    }
}
