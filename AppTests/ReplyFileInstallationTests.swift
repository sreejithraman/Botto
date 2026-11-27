import Foundation
import Observation
import Testing
import BottoCore
@testable import Botto

@MainActor final class ReplyFileInstallEvents {
    private(set) var events: [String] = []
    func add(_ value: String) { events.append(value) }
}

@MainActor @Suite(.serialized) struct ReplyFileInstallationTests {
    struct Fixture {
        let service: WorkspaceTestService
        let store: AppStore
        let block: ReplyContent.Block
        let context: RichReplyContext
        let log: ReplyFileInstallEvents
        let cacheID: UUID
    }
    private func wait(_ label: String, until condition: () -> Bool) async throws {
        await waitWhile(label) { !condition() }
        try #require(condition(), "Timed out waiting for \(label)")
    }
    private func fixture() async throws -> Fixture {
        let log = ReplyFileInstallEvents(), service = try WorkspaceTestService()
        service.downloadData = Data("<!doctype html><html><body>Installed preview</body></html>".utf8)
        service.summaries = [service.summaries[0]]
        let id = service.summaries[0].identity
        service.summaries[0] = .init(identity: id, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 4)
        service.snapshots = [:]
        service.snapshots[id.root] = .init(id: id.root.text, storedID: id.stored.text, profileID: id.profile.text,
            messages: [.init(id: "preview-message", role: .assistant, text: "::preview{file=\"report.html\"}\n")])
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://reservation-r3.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration))
        await store.open(.init(id: service.profile.text, name: "Milo"))
        let screen = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(screen.owner)
        store.chats.setTranscriptVisible(true, owner: screen.owner)
        let snapshot = try #require(store.conversation(for: service.profile.text))
        let block = try #require(ReplyContent(message: snapshot.messages[0]).blocks.first(where: { $0.filePreview != nil }))
        let context = store.richReplyContext(for: service.profile.text, messageID: "preview-message")
        try #require(block.isComplete && block.filePreview?.isHTML == true && context.permits(block))
        try #require(service.opens.count == 1)
        return .init(service: service, store: store, block: block, context: context, log: log, cacheID: configuration.id)
    }
    private func clean(_ f: Fixture) {
        LocalHistory.remove(for: f.cacheID)
    }

    @Test func modelInstallsDownloadedHTMLUnderCurrentAuthority() async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel()
        defer { clean(f) }
        let downloadGate = WorkspaceGate()
        f.service.downloadGate = downloadGate
        let loading = Task { await model.load(f.block, context: f.context) }
        try await wait("actual service download entry") { f.service.downloads == 1 }
        // Register after load's initial cancel()/resolved=nil. This observes the actual
        // @Observable model's willSet, synchronously before result installation.
        withObservationTracking { _ = model.resolved } onChange: {
            MainActor.assumeIsolated { f.log.add("model.resolved.will-install") }
        }
        downloadGate.release()
        await loading.value
        #expect(model.resolved?.block.source == String(decoding: f.service.downloadData, as: UTF8.self))
        #expect(model.errorMessage == nil)
        #expect(f.service.opens.count == 1)
        #expect(f.context.permits(f.block))
        if let resolved = model.resolved { #expect(resolved.context.permits(resolved.block)) }
        #expect(f.log.events.contains("model.resolved.will-install"))
        await f.store.setActive(false)
    }

    @Test func returningToTheSameLoadedFileDoesNotRecaptureAndAuthorityRetirementStillClearsIt() async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel()
        defer { clean(f) }
        await model.load(f.block, context: f.context)
        try #require(model.resolved != nil && f.service.downloads == 1)
        model.suspend()
        await model.load(f.block, context: f.context)
        #expect(f.service.downloads == 1, "temporary block exposure must not redownload already installed bytes")
        let retained = try #require(model.resolved)
        #expect(retained.context.permits(retained.block))
        await f.store.setActive(false)
        await model.load(f.block, context: f.context)
        #expect(model.resolved == nil, "an inert loaded result never bypasses current authority")
        #expect(f.service.downloads == 1)
    }

    @Test func retiredAuthorityRefusesInstalledPreviewRendering() async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel()
        defer { clean(f) }
        await model.load(f.block, context: f.context)
        let installed = try #require(model.resolved(for: f.block, context: f.context))
        await f.store.setActive(false)
        #expect(!f.context.permits(f.block))
        #expect(model.resolved(for: f.block, context: f.context) == nil)
        #expect(!installed.context.permits(installed.block))
        let ticket = installed.context.begin(installed.block, layout: nil, onRevoke: {}).ticket
        defer { ticket?.cancel() }
        #expect(ticket == nil, "Cached HTML must not admit executable rendering after revocation")
    }

    @Test func invalidDownloadedHTMLInstallsNothing() async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel()
        defer { clean(f) }
        f.service.downloadData = Data([0xff])
        await model.load(f.block, context: f.context)
        #expect(model.resolved == nil && f.service.downloads == 1)
        await f.store.setActive(false)
    }

    @Test func cancellationDropsLateBytes() async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel(), gate = WorkspaceGate()
        defer { clean(f) }
        f.service.downloadGate = gate
        let loading = Task { await model.load(f.block, context: f.context) }
        try await wait("actual service download entry") { f.service.downloads == 1 }
        loading.cancel()
        gate.release(); await loading.value
        #expect(model.resolved == nil && model.errorMessage == nil)
        #expect(f.service.downloads == 1)
        await f.store.setActive(false)
    }
}
