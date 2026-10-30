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
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
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
        try #require(service.completedOpens.last?.readEvidence?.summaryObservedBeforeRead.messageCount == 4)
        log.add("visible-current complete-html initial-witness=4 opens=1")
        return .init(service: service, store: store, block: block, context: context, log: log, cacheID: configuration.id)
    }
    private func clean(_ f: Fixture) {
        f.service.onOpen = nil; f.service.onDownload = nil
        LocalHistory.remove(for: f.cacheID)
    }

    private func newerHint(_ f: Fixture) async throws {
        let id = f.service.summaries[0].identity
        f.service.summaries[0] = .init(identity: id, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 6)
        let screen = try #require(f.store.chats.screen(profile: f.service.profile))
        await f.store.chats.refreshDirectory(screen.owner)
        f.store.chats.setTranscriptVisible(true, owner: screen.owner)
        f.log.add("returned-directory=6 visible-current while-download-held opens=\(f.service.opens.count)")
        #expect(f.service.opens.count == 1)
        #expect(f.context.permits(f.block), "Held download must defer optional read and authority retirement")
    }
    @Test(arguments: [false, true]) func modelInstallsBeforeOptionalRead(pendingHint: Bool) async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel()
        defer { clean(f) }
        let downloadGate = WorkspaceGate(), readGate = WorkspaceGate()
        f.service.downloadGate = downloadGate; f.service.openGate = readGate
        f.service.onDownload = { f.log.add("service.download.enter") }
        f.service.onOpen = {
            f.log.add("service.open.enter installed=\(model.resolved != nil) old-context-current=\(f.context.permits(f.block))")
        }
        let loading = Task { await model.load(f.block, context: f.context); f.log.add("model.load.return resolved=\(model.resolved != nil) error=\(model.errorMessage != nil)") }
        try await wait("actual service download entry") { f.service.downloads == 1 }
        // Register after load's initial cancel()/resolved=nil. This observes the actual
        // @Observable model's willSet, synchronously before result installation.
        withObservationTracking { _ = model.resolved } onChange: {
            MainActor.assumeIsolated { f.log.add("model.resolved.will-install") }
        }
        if pendingHint { try await newerHint(f) }
        f.log.add("release-download-bytes")
        downloadGate.release()
        await loading.value
        if pendingHint {
            try await wait("automatic service open") { f.service.opens.count == 2 }
            let installed = f.log.events.firstIndex(of: "model.resolved.will-install")
            let opened = f.log.events.firstIndex(where: { $0.hasPrefix("service.open.enter") })
            #expect(installed != nil, "REQUIRED: actual model installs downloaded HTML before optional read can retire its scope")
            if let installed, let opened { #expect(installed < opened, "Installation must precede automatic open/retirement") }
            #expect(f.log.events.contains("service.open.enter installed=true old-context-current=false"))
            #expect(!f.context.permits(f.block), "New read must still retire old authority")
            #expect(model.resolved(for: f.block, context: f.context) == nil,
                    "Installed bytes cannot render through retired authority")
            readGate.release()
            try await wait("read settlement") { f.store.openingID == nil }
        } else {
            #expect(model.resolved?.block.source == String(decoding: f.service.downloadData, as: UTF8.self))
            #expect(model.errorMessage == nil)
            #expect(f.service.opens.count == 1)
            #expect(f.context.permits(f.block))
            if let resolved = model.resolved { #expect(resolved.context.permits(resolved.block)) }
            #expect(f.log.events.contains("model.resolved.will-install"))
        }
        f.log.add("case.done pendingHint=\(pendingHint)")
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

    @Test func publicArtifactCaptureHeldThroughModelInstallDefersThenRetires() async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel(), gate = WorkspaceGate(), readGate = WorkspaceGate()
        defer { clean(f) }
        let reference = try #require(f.block.filePreview)
        // Causal control using the existing public caller seam. This extra capture
        // holds a real operation reservation, never preserves authority across open.
        let consumerCapture = try #require(f.store.artifactDestination(for: reference.attachment, botID: f.service.profile.text))
        f.service.downloadGate = gate; f.service.openGate = readGate
        f.service.onDownload = { f.log.add("service.download.enter") }
        f.service.onOpen = {
            f.log.add("service.open.enter held-capture installed=\(model.resolved != nil) old-context-current=\(f.context.permits(f.block))")
        }
        let loading = Task { await model.load(f.block, context: f.context) }
        try await wait("actual service download entry") { f.service.downloads == 1 }
        withObservationTracking { _ = model.resolved } onChange: {
            MainActor.assumeIsolated { f.log.add("model.resolved.will-install") }
        }
        try await newerHint(f)
        f.log.add("release-download-bytes")
        gate.release(); await loading.value
        #expect(model.resolved?.block.source == String(decoding: f.service.downloadData, as: UTF8.self))
        #expect(model.errorMessage == nil && f.service.opens.count == 1)
        #expect(f.context.permits(f.block))
        f.log.add("consumer.finishArtifact after-install")
        f.store.finishArtifact(consumerCapture)
        try await wait("automatic read after install/release") { f.service.opens.count == 2 }
        #expect(!f.context.permits(f.block), "Holding a reservation must never retain old authority across read")
        let installed = try #require(f.log.events.firstIndex(of: "model.resolved.will-install"))
        let opened = try #require(f.log.events.firstIndex(where: { $0.hasPrefix("service.open.enter") }))
        #expect(installed < opened)
        #expect(f.log.events.contains("service.open.enter held-capture installed=true old-context-current=false"))
        #expect(model.resolved(for: f.block, context: f.context) == nil,
                "Releasing the capture must not preserve rendering authority")
        readGate.release(); try await wait("read settlement") { f.store.openingID == nil }
        f.log.add("held-capture-control.done")
        await f.store.setActive(false)
        withExtendedLifetime(consumerCapture) {}
    }

    @Test func coveredTranscriptWithNewHintInstallsWithoutOptionalRead() async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel(), gate = WorkspaceGate()
        defer { clean(f) }
        f.service.downloadGate = gate
        let loading = Task { await model.load(f.block, context: f.context) }
        try await wait("actual service download entry") { f.service.downloads == 1 }
        try await newerHint(f)
        let screen = try #require(f.store.chats.screen(profile: f.service.profile))
        f.store.chats.setTranscriptVisible(false, owner: screen.owner)
        f.log.add("transcript.covered")
        gate.release(); await loading.value
        #expect(model.resolved?.block.source == String(decoding: f.service.downloadData, as: UTF8.self))
        #expect(model.errorMessage == nil && f.service.opens.count == 1 && f.context.permits(f.block))
        f.log.add("covered-control.done")
        await f.store.setActive(false)
    }

    @Test func installedPreviewDoesNotKeepTheNextDirectoryReadBlocked() async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel(), readGate = WorkspaceGate()
        defer { clean(f) }
        await model.load(f.block, context: f.context)
        #expect(model.resolved != nil)
        let installed = try #require(model.resolved(for: f.block, context: f.context))
        #expect(f.service.downloads == 1 && f.service.opens.count == 1)
        f.service.openGate = readGate
        let identity = f.service.summaries[0].identity
        f.service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true,
                                     persistence: .durable, messageCount: 6)
        let screen = try #require(f.store.chats.screen(profile: f.service.profile))
        await f.store.chats.refreshDirectory(screen.owner)
        f.store.chats.setTranscriptVisible(true, owner: screen.owner)
        try await wait("next observation after completed installation") { f.service.opens.count == 2 }
        #expect(model.resolved != nil, "Keeping passive content must not retain the operation barrier")
        #expect(!f.context.permits(f.block), "The subsequent read still retires old authority")
        #expect(model.resolved?.block.source == installed.block.source)
        #expect(model.resolved(for: f.block, context: f.context) == nil)
        #expect(!installed.context.permits(installed.block))
        let ticket = installed.context.begin(installed.block, layout: nil, onRevoke: {}).ticket
        defer { ticket?.cancel() }
        #expect(ticket == nil, "Cached HTML must not admit executable rendering after revocation")
        readGate.release()
        try await wait("read settlement") { f.store.openingID == nil }
        await f.store.setActive(false)
    }

    @Test func invalidDownloadedHTMLReleasesThePendingRead() async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel(), gate = WorkspaceGate(), readGate = WorkspaceGate()
        defer { clean(f) }
        f.service.downloadData = Data([0xff])
        f.service.downloadGate = gate; f.service.openGate = readGate
        let loading = Task { await model.load(f.block, context: f.context) }
        try await wait("actual service download entry") { f.service.downloads == 1 }
        try await newerHint(f)
        gate.release(); await loading.value
        try await wait("read after invalid HTML") { f.service.opens.count == 2 }
        #expect(model.resolved == nil && f.service.downloads == 1)
        #expect(!f.context.permits(f.block))
        readGate.release()
        try await wait("read settlement") { f.store.openingID == nil }
        await f.store.setActive(false)
    }

    @Test func cancellationDropsLateBytesAndReleasesPendingRead() async throws {
        let f = try await fixture(), model = ReplyFilePreviewModel(), gate = WorkspaceGate(), readGate = WorkspaceGate()
        defer { clean(f) }
        f.service.downloadGate = gate; f.service.openGate = readGate
        f.service.onDownload = { f.log.add("service.download.enter") }
        f.service.onOpen = { f.log.add("service.open.enter canceled-consumer") }
        let loading = Task { await model.load(f.block, context: f.context) }
        try await wait("actual service download entry") { f.service.downloads == 1 }
        try await newerHint(f)
        loading.cancel(); f.log.add("consumer.cancel")
        gate.release(); await loading.value
        try await wait("optional read after canceled download drains") { f.service.opens.count == 2 }
        #expect(model.resolved == nil && model.errorMessage == nil)
        #expect(!f.context.permits(f.block))
        #expect(f.service.downloads == 1)
        readGate.release(); try await wait("read settlement") { f.store.openingID == nil }
        f.log.add("cancel-control.done late-bytes-not-installed")
        await f.store.setActive(false)
    }
}
