import Foundation
import CoreGraphics
import Testing
import BottoCore
@testable import Botto

@Suite(.serialized) @MainActor struct WorkspacePresentationTests {
    private func fixture() async throws -> (AppStore, WorkspaceTestService, ConnectionConfiguration) {
        let service = try WorkspaceTestService()
        let main = service.summaries[0].identity
        service.summaries[0] = .init(identity: main, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 4)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://duo-workspace.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        await store.open(try #require(store.bots.first))
        return (store, service, configuration)
    }

    @Test func browsingAndExpansionRetainCapturedLoadAndDraft() async throws {
        let (store, service, configuration) = try await fixture()
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let owner = try #require(store.chats.screen(profile: service.profile)?.owner)
        store.chats.editDraft("  Keep this thought\n", owner: owner)
        let gate = WorkspaceGate(); service.downloadGate = gate
        let presentation = WorkspacePresentation()
        presentation.openArtifact(try #require(store.artifactDestination(for: .init(name: "notes.txt", path: "/notes.txt"), botID: service.profile.text)), store: store)
        let session = try #require(presentation.artifact)
        await gate.entered()
        presentation.setArtifactExpanded(true, id: session.id)
        presentation.browseBots()
        #expect(presentation.isBrowsingBots)
        #expect(presentation.artifact === session && presentation.isArtifactExpanded)
        presentation.resumeTask()
        presentation.setArtifactExpanded(false, id: session.id)
        #expect(presentation.artifact === session && session.isCurrent)
        #expect(service.downloads == 1 && service.opens.count == 1)
        #expect(store.chats.draft(owner) == "  Keep this thought\n")
        gate.release()
        try await loaded(session)
        #expect(session.file?.data == Data("artifact".utf8))
        presentation.closeArtifact(id: session.id)
        #expect(presentation.artifact == nil && session.file == nil && !session.isCurrent)
    }
    private func loaded(_ session: ArtifactPreviewSession) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while session.file == nil && ContinuousClock.now < deadline { await Task.yield() }
        _ = try #require(session.file)
    }

    private func openFile(_ name: String = "notes.txt", presentation: WorkspacePresentation, store: AppStore,
                          service: WorkspaceTestService) throws -> ArtifactPreviewSession {
        let destination = try #require(store.artifactDestination(for: .init(name: name, path: "/" + name), botID: service.profile.text))
        presentation.openArtifact(destination, store: store)
        return try #require(presentation.artifact)
    }

    @Test func loadedBytesAndReservationSurviveGeometryBrowseAndExpansionUntilExplicitClose() async throws {
        let (store, service, configuration) = try await fixture()
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let session = try openFile(presentation: presentation, store: store, service: service)
        try await loaded(session)
        let file = try #require(session.file)
        let owner = try #require(store.chats.screen(profile: service.profile)?.owner)
        let generation = store.artifactGeneration
        store.chats.setTranscriptVisible(true, owner: owner)
        let main = service.summaries[0].identity
        service.summaries[0] = .init(identity: main, title: "Bot Chat", isCanonical: true, persistence: .durable, messageCount: 6)
        await store.chats.refreshDirectory(owner)
        let revision = presentation.revision
        for width: CGFloat in [951, 466, 669, 951] {
            let layout = WorkspaceLayout(compact: width == 466, accessibilityText: false, workspaceWidth: width)
            store.chats.setTranscriptVisible(layout.pairsChatAndFile, owner: owner)
            presentation.reconcile(store: store)
            #expect(presentation.revision == revision)
            #expect(session.file === file && session.isCurrent)
        }
        presentation.setArtifactExpanded(true, id: session.id)
        presentation.browseBots(); presentation.resumeTask()
        presentation.setArtifactExpanded(false, id: session.id)
        session.retry()
        #expect(session.file === file && service.downloads == 1 && service.opens.count == 1)
        #expect(store.artifactGeneration == generation && store.chats.isCurrent(owner))
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        store.chats.setTranscriptVisible(true, owner: owner)
        let readGate = WorkspaceGate(); service.openGate = readGate
        presentation.closeArtifact(id: session.id)
        presentation.closeArtifact(id: session.id)
        presentation.reconcile(store: store)
        await readGate.entered()
        #expect(service.opens.count == 2, "Close releases one reservation and admits exactly one waiting reread")
        #expect(!session.isCurrent && session.file == nil && presentation.artifact == nil)
        readGate.release()
    }

    @Test(arguments: ["background", "foreground", "disconnect", "recovery", "reconnect", "reopen", "secret rotation"])
    func completedReaderAndOutputsSurviveSameOwnerConnectionWork(_ transition: String) async throws {
        let (store, service, configuration) = try await fixture()
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        // Start before capturing the reader so foregrounding uses the app's
        // automatic connection lifecycle rather than a test-only reconnect.
        await store.start()
        let presentation = WorkspacePresentation()
        let destination = try #require(store.artifactDestination(for: .init(name: "notes.txt", path: "/notes.txt"), botID: service.profile.text))
        presentation.openArtifact(destination, store: store)
        let session = try #require(presentation.artifact)
        try await loaded(session)
        let file = try #require(session.file)
        let revision = presentation.revision
        session.beginOutput(.share)
        let sharing = try #require(session.output)

        switch transition {
        case "background", "foreground":
            await store.setActive(false)
            presentation.reconcile(store: store)
            #expect(presentation.artifact === session && session.file === file)
            if transition == "foreground" { await store.setActive(true) }
        case "disconnect", "recovery":
            service.onEvent?(.disconnected("Recovering"))
            presentation.reconcile(store: store)
            #expect(presentation.artifact === session && session.file === file)
            if transition == "recovery" {
                service.onEvent?(.conversation(try service.publication(service.summaries[0].identity)))
                service.onEvent?(.connected(.init(version: "recovered")))
            }
        case "reconnect": #expect(await store.connect(configuration))
        case "reopen": await store.open(try #require(store.bots.first))
        default:
            var rotated = configuration
            rotated.password = "replacement-secret"
            service.onEvent?(.configuration(rotated))
        }

        presentation.reconcile(store: store)
        #expect(store.isAuthorizedArtifactPresentation(destination))
        #expect(presentation.artifact === session && session.file === file && session.isCurrent)
        #expect(presentation.revision == revision)
        #expect(session.output?.id == sharing.id && session.output?.file === file)
        session.endOutput(id: sharing.id)
        session.beginOutput(.save)
        let saving = try #require(session.output)
        #expect(saving.file === file && saving.file.data == Data("artifact".utf8))
        #expect(try Data(contentsOf: saving.file.url) == saving.file.data)
        session.endOutput(id: saving.id)
        presentation.setArtifactExpanded(true, id: session.id)
        presentation.browseBots(); presentation.resumeTask()
        #expect(presentation.artifact === session && presentation.isArtifactExpanded)
        #expect(presentation.acceptsArtifactCallback(id: session.id, revision: presentation.revision))
        session.retry()
        if transition != "secret rotation" {
            #expect(!store.isCurrentArtifactDestination(destination))
            await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination) }
        }
        #expect(service.downloads == 1, "Local reader actions never replay the retired network read")
        presentation.closeArtifact(id: session.id)
        #expect(presentation.artifact == nil && !session.isCurrent && session.file == nil)
    }

    @Test(arguments: ["account", "account bytes", "install", "provider", "runtime", "stored", "selection", "review", "sibling", "workspace", "forget"])
    func completedReaderRevokesOnSemanticReplacementAndFencesOldOutputs(_ change: String) async throws {
        let (store, service, configuration) = try await fixture()
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.invalid")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id); LocalHistory.remove(for: replacement.id) }
        var capturedConfiguration = configuration
        if change == "account bytes" {
            capturedConfiguration.username = "Café"
            #expect(await store.connect(capturedConfiguration))
        }
        let presentation = WorkspacePresentation()
        let session = try openFile(presentation: presentation, store: store, service: service)
        try await loaded(session)
        let file = try #require(session.file)
        session.beginOutput(.save)
        let saving = try #require(session.output)
        switch change {
        case "account", "account bytes", "install", "provider":
            var changed = capturedConfiguration
            if change == "account" { changed.username = "another-account" }
            if change == "account bytes" { changed.username = "Cafe\u{301}" }
            if change == "install" { changed.installID = "another-install" }
            if change == "provider" { changed.nativeCredential = .init(refreshToken: "test-token", provider: "another-provider") }
            service.onEvent?(.configuration(changed))
            #expect(!session.isCurrent && session.file == nil && session.output == nil)
            service.onEvent?(.configuration(capturedConfiguration))
        case "runtime", "stored":
            let identity = service.summaries[0].identity
            let original = try #require(service.snapshots[identity.root])
            var changed = original
            if change == "runtime" { changed.id = "another-runtime" }
            if change == "stored" { changed.storedID = "another-stored" }
            let updatedIdentity = SessionIdentity(profile: identity.profile, root: identity.root,
                stored: try ExactID(changed.storedID), aliases: identity.aliases)
            service.snapshots[identity.root] = changed
            service.onEvent?(.conversation(try service.publication(updatedIdentity)))
            #expect(!session.isCurrent && session.file == nil && session.output == nil)
            service.snapshots[identity.root] = original
            service.onEvent?(.conversation(try service.publication(identity)))
        case "selection":
            store.selectedBotID = "another-bot"
            #expect(!session.isCurrent && session.file == nil)
            store.selectedBotID = service.profile.text
        case "review":
            store.showsConnection = true
            #expect(!session.isCurrent && session.file == nil)
            store.showsConnection = false
        case "sibling":
            let owner = try #require(store.chats.screen(profile: service.profile)?.owner)
            await store.chats.refreshDirectory(owner)
            let other = try #require(store.chats.cards(profile: service.profile).first { !$0.isMain })
            await store.chats.select(try #require(store.chats.captureSelection(other.id, owner: owner)))
        case "workspace":
            #expect(await store.connect(replacement))
            await store.open(try #require(store.bots.first))
        default: store.forgetConnection()
        }
        #expect(!session.isCurrent && session.file == nil && session.output == nil)
        presentation.reconcile(store: store)
        #expect(presentation.artifact == nil)
        session.endOutput(id: saving.id, error: HermesServiceError.timeout)
        session.beginOutput(.share); session.retry()
        #expect(session.output == nil && session.exportError == nil)
        #expect(service.downloads == 1)
        #expect(try Data(contentsOf: file.url) == saving.file.data, "The captured native output retains its bytes until it finishes")
    }

    @Test func oldNativeCallbacksCannotCloseParkedResumedOrReplacementSessions() async throws {
        let (store, service, configuration) = try await fixture()
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let first = try openFile(presentation: presentation, store: store, service: service)
        try await loaded(first)
        let contextualRevision = presentation.revision
        #expect(presentation.acceptsArtifactCallback(id: first.id, revision: contextualRevision))
        presentation.setArtifactExpanded(true, id: first.id)
        let expandedRevision = presentation.revision
        #expect(!presentation.acceptsArtifactCallback(id: first.id, revision: contextualRevision))
        presentation.browseBots()
        #expect(!presentation.acceptsArtifactCallback(id: first.id, revision: expandedRevision))
        presentation.resumeTask()
        #expect(!presentation.acceptsArtifactCallback(id: first.id, revision: expandedRevision))
        #expect(presentation.isArtifactExpanded && first.isCurrent)
        let second = try openFile("second.txt", presentation: presentation, store: store, service: service)
        presentation.closeArtifact(id: first.id)
        presentation.setArtifactExpanded(false, id: first.id)
        first.retry(); first.beginOutput(.save)
        try await loaded(second)
        #expect(presentation.artifact === second && !first.isCurrent && first.file == nil)
        #expect(first.output == nil && service.downloads == 2)
        presentation.closeArtifact(id: second.id)
    }

    @Test func failedReaderRetryRequiresItsCurrentUncoveredSurface() async throws {
        let (store, service, configuration) = try await fixture()
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        service.downloadError = HermesServiceError.timeout
        let presentation = WorkspacePresentation()
        let session = try openFile(presentation: presentation, store: store, service: service)
        func failed(after count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while (service.downloads != count || session.isLoading || session.errorMessage == nil) && ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(service.downloads == count && !session.isLoading && session.errorMessage != nil)
        }
        try await failed(after: 1)
        let revision = presentation.revision
        var uncovered = true
        let capturedRetry = {
            presentation.retryArtifact(id: session.id, revision: revision, canPresent: { uncovered })
        }
        uncovered = false
        capturedRetry()
        await Task.yield()
        #expect(service.downloads == 1, "A covered failed reader cannot admit a new download")
        uncovered = true
        presentation.browseBots()
        capturedRetry()
        await Task.yield()
        #expect(service.downloads == 1, "Parking retains the session, not old retry admission")
        presentation.resumeTask()
        capturedRetry()
        await Task.yield()
        #expect(service.downloads == 1, "Return cannot revive the old surface callback")
        let visibleRevision = presentation.revision
        presentation.retryArtifact(id: session.id, revision: visibleRevision, canPresent: { uncovered })
        try await failed(after: 2)
        service.downloadError = nil
        presentation.retryArtifact(id: session.id, revision: presentation.revision, canPresent: { uncovered })
        try await loaded(session)
        #expect(service.downloads == 3 && session.file?.data == service.downloadData)
    }

    @Test(arguments: ["selection", "reopen", "sibling", "review", "background", "reconnect", "workspace", "forget"])
    func actualInvalidationRetiresParkedSessionAndRejectsCancellationIgnoringLateBytes(_ reason: String) async throws {
        let (store, service, configuration) = try await fixture()
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.invalid")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id); LocalHistory.remove(for: replacement.id) }
        let gate = WorkspaceGate(); service.downloadGate = gate
        let presentation = WorkspacePresentation()
        let session = try openFile(presentation: presentation, store: store, service: service)
        await gate.entered()
        presentation.setArtifactExpanded(true, id: session.id); presentation.browseBots()
        switch reason {
        case "selection": store.selectedBotID = "another-bot"
        case "reopen": await store.open(try #require(store.bots.first))
        case "sibling":
            let owner = try #require(store.chats.screen(profile: service.profile)?.owner)
            await store.chats.refreshDirectory(owner)
            let other = try #require(store.chats.cards(profile: service.profile).first { !$0.isMain })
            await store.chats.select(try #require(store.chats.captureSelection(other.id, owner: owner)))
        case "review": store.showsConnection = true
        case "background": await store.setActive(false)
        case "reconnect": #expect(await store.connect(configuration))
        case "workspace": #expect(await store.connect(replacement))
        default: store.forgetConnection()
        }
        #expect(!session.isCurrent && session.file == nil && !session.isPresentingOutput)
        presentation.reconcile(store: store)
        #expect(presentation.artifact == nil && !presentation.isArtifactExpanded)
        gate.release()
        session.retry()
        for _ in 0..<100 { await Task.yield() }
        #expect(session.file == nil && session.errorMessage == nil && !session.isLoading)
        #expect(service.downloads == 1)
        presentation.resumeTask(); presentation.closeArtifact(id: session.id)
        #expect(presentation.artifact == nil)
    }

    @Test(arguments: ["background", "recovery", "account"])
    func lateReadCannotBecomeACompletedReaderAfterOriginalReadAuthorityRetires(_ transition: String) async throws {
        let (store, service, configuration) = try await fixture()
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let gate = WorkspaceGate(); service.downloadGate = gate
        let destination = try #require(store.artifactDestination(for: .init(name: "late.txt", path: "/late.txt"), botID: service.profile.text))
        let presentation = WorkspacePresentation()
        presentation.openArtifact(destination, store: store)
        let session = try #require(presentation.artifact)
        await gate.entered()
        switch transition {
        case "background":
            await store.setActive(false)
            await store.setActive(true)
            #expect(await store.connect(configuration))
        case "recovery":
            service.onEvent?(.disconnected("Recovering"))
            service.onEvent?(.conversation(try service.publication(service.summaries[0].identity)))
            service.onEvent?(.connected(.init(version: "recovered")))
        default:
            var changed = configuration
            changed.username = "another-account"
            service.onEvent?(.configuration(changed))
        }
        #expect(store.isAuthorizedArtifactPresentation(destination) == (transition != "account"))
        #expect(!store.isCurrentArtifactDestination(destination))
        // Let the cancellation-ignoring service return before reconciliation.
        // Semantic authorization alone must never admit these uncached bytes.
        gate.release()
        for _ in 0..<100 { await Task.yield() }
        #expect(!session.isCurrent && session.file == nil && session.errorMessage == nil && !session.isLoading)
        session.retry(); session.beginOutput(.save)
        #expect(session.output == nil && service.downloads == 1)
        presentation.reconcile(store: store)
        #expect(presentation.artifact == nil)
    }

    @Test func capturedUncachedDestinationCannotStartOrReplayAfterRecovery() async throws {
        let (store, service, configuration) = try await fixture()
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let destination = try #require(store.artifactDestination(for: .init(name: "uncached.txt", path: "/uncached.txt"), botID: service.profile.text))
        let presentation = WorkspacePresentation()
        service.onEvent?(.disconnected("Recovering"))
        #expect(store.isAuthorizedArtifactPresentation(destination))
        presentation.openArtifact(destination, store: store)
        #expect(presentation.artifact == nil && service.downloads == 0)
        service.onEvent?(.conversation(try service.publication(service.summaries[0].identity)))
        service.onEvent?(.connected(.init(version: "recovered")))
        presentation.reconcile(store: store)
        #expect(presentation.artifact == nil && service.downloads == 0)
        presentation.openArtifact(destination, store: store)
        #expect(presentation.artifact == nil && service.downloads == 0)
        // Recovery admits a deliberate new capture, never a replay of the old one.
        let fresh = try openFile(presentation: presentation, store: store, service: service)
        try await loaded(fresh)
        #expect(fresh.id != destination.id && service.downloads == 1)
        presentation.closeArtifact(id: fresh.id)
    }

    @Test func outputsFenceLateCompletionsAndHoldOriginalReaderThroughInvalidation() async throws {
        let (store, service, configuration) = try await fixture()
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let first = try openFile(presentation: presentation, store: store, service: service)
        try await loaded(first)
        first.beginOutput(.share)
        let oldOutput = try #require(first.output)
        presentation.browseBots(); presentation.setArtifactExpanded(true, id: first.id)
        #expect(!presentation.isBrowsingBots && !presentation.isArtifactExpanded, "User host moves wait for native output")
        first.endOutput(id: oldOutput.id)
        first.beginOutput(.save)
        let saving = try #require(first.output)
        first.endOutput(id: oldOutput.id, error: HermesServiceError.timeout)
        #expect(first.output?.id == saving.id && first.exportError == nil)
        store.showsConnection = true
        presentation.reconcile(store: store)
        #expect(first.file == nil && first.output == nil && first.exportError == nil && !first.isCurrent)
        #expect(try Data(contentsOf: oldOutput.file.url) == Data("artifact".utf8))
        store.showsConnection = false
        let second = try openFile("fresh.txt", presentation: presentation, store: store, service: service)
        try await loaded(second)
        second.beginOutput(.share)
        let fresh = try #require(second.output)
        first.endOutput(id: saving.id, error: HermesServiceError.timeout)
        presentation.closeArtifact(id: first.id)
        #expect(presentation.artifact === second && second.output?.id == fresh.id)
        second.endOutput(id: fresh.id)
        presentation.closeArtifact(id: second.id)
    }

    @Test func oldExportAlertCannotClearANewerFailure() async throws {
        let (store, service, configuration) = try await fixture()
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let session = try openFile(presentation: presentation, store: store, service: service)
        try await loaded(session)
        session.beginOutput(.save)
        let first = try #require(session.output)
        session.endOutput(id: first.id, error: HermesServiceError.timeout)
        let oldError = try #require(session.exportErrorID)
        session.clearExportError(id: oldError)
        session.beginOutput(.save)
        let second = try #require(session.output)
        session.endOutput(id: second.id, error: HermesServiceError.staleConversation)
        session.clearExportError(id: oldError)
        #expect(session.exportErrorID == second.id && session.exportError != nil)
        session.clearExportError(id: second.id)
        presentation.closeArtifact(id: session.id)
    }

    @Test func heldUploadInstallsIntoSameDraftAcrossGeometricCoverageAndStaysStagedWhileBrowsing() async throws {
        let (store, service, configuration) = try await fixture()
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let presentation = WorkspacePresentation()
        let session = try openFile(presentation: presentation, store: store, service: service)
        try await loaded(session)
        let owner = try #require(store.chats.screen(profile: service.profile)?.owner)
        store.chats.editDraft("  Draft with staged bytes\n", owner: owner)
        let intent = try #require(store.chats.captureImport(owner))
        let gate = WorkspaceGate(); service.uploadGate = gate
        let uploading = Task { await store.chats.upload(Data([1, 2, 3]), filename: "kept.txt", mimeType: "text/plain", to: intent) }
        await gate.entered()
        let revision = presentation.revision
        for width: CGFloat in [951, 466, 669, 951] {
            let layout = WorkspaceLayout(compact: width == 466, accessibilityText: false, workspaceWidth: width)
            store.chats.setTranscriptVisible(layout.pairsChatAndFile, owner: owner)
            presentation.reconcile(store: store)
            #expect(presentation.revision == revision && store.chats.isCurrent(owner))
        }
        gate.release(); await uploading.value
        presentation.browseBots(); presentation.resumeTask()
        let current = try #require(store.chats.screen(profile: service.profile))
        #expect(current.attachments.map(\.name) == ["kept.txt"])
        #expect(!current.needsReattachment && service.uploads.count == 1)
        #expect(store.chats.draft(owner) == "  Draft with staged bytes\n")
        #expect(service.downloads == 1 && service.opens.count == 1)
        presentation.closeArtifact(id: session.id)
    }

}
