import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Botto
@testable import BottoCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct T3WorkspaceTests {
    @Test func mountsTheBotAndOpensTheExactStoredChannel() async throws {
        let service = T3WorkspaceService()
        let configuration = t3Configuration()
        let storage = MemoryConnectionStorage(saved: configuration)
        defer { LocalHistory.remove(for: configuration.id) }
        let store = AppStore(service: service, persistence: storage.persistence)

        await store.start()

        #expect(store.isT3Workspace)
        #expect(store.serverName == "Studio")
        #expect(store.primaryT3Bot?.id == "bot-project")
        #expect(store.t3Channels.map(\.title) == ["#general", "Release"])
        // Spaces never show a "#", and the main space is the anchor.
        #expect(store.t3Channels.map(\.displayTitle) == ["general", "Release"])
        #expect(T3ChatShelf.spaces(store.t3Channels).main?.id == "general")
        #expect(T3ChatShelf.spaces(store.t3Channels).spaces.map(\.id) == ["release"])
        // Release is waiting, so launch goes there before the main space.
        #expect(T3ChatShelf.initialSpace(store.t3Channels)?.id == "release")
        let release = try #require(store.t3Channels.last)
        #expect(await store.openT3Channel(release))
        #expect(store.selectedBotID == "bot-project")
        #expect(store.selectedT3ChannelTitle == "Release")
        #expect(store.selectedT3Channel?.id == "release")
        #expect(store.conversation(for: "bot-project")?.messages.map(\.text) == ["Chat in release"])

        let general = try #require(store.t3Channels.first)
        #expect(await store.openT3Channel(general))
        #expect(store.selectedT3ChannelTitle == "general")
        #expect(service.openedStoredThreads == ["release", "general"])

        try #require(store.flush())
        let restored = AppStore(service: T3WorkspaceService(), persistence: storage.persistence)
        #expect(restored.link == .connecting)
        #expect(restored.t3Channels.map(\.title) == ["#general", "Release"])
        #expect(restored.t3Channels.map(\.isMain) == [true, false])
        #expect(await restored.openT3Channel(release))
        #expect(restored.conversation(for: "bot-project")?.messages.map(\.text) == ["Chat in release"])
    }

    @Test(arguments: [false, true])
    func notificationTapOpensOnlyTheAuthenticatedSpace(cold: Bool) async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let scope = T3PushScope(environmentID: "studio-id", projectID: "bot-project")
        let invite = T3PushInvitation(host: "127.0.0.1", port: 3775, scope: scope,
                                      deviceID: String(repeating: "a", count: 32),
                                      expiresAt: Int(Date.now.timeIntervalSince1970) + 300,
                                      secret: Data(repeating: 2, count: 32))
        let installation = String(repeating: "a", count: 64)
        let target = T3PushRegistration.Target(token: String(repeating: "12", count: 32),
                                               bundleID: "com.sree.botto", environment: .sandbox)
        var saved: [T3PushPairing] = []
        let push = T3PushCoordinator(load: { saved }, save: { saved = $0 },
            authorization: .init(requestPermission: { true }, deviceToken: { target.token }),
            send: { request, code in
                #expect(code == invite)
                #expect(request.scope == scope)
                #expect(request.target?.token == target.token)
                return .init(request.target == nil ? .removed : .registered, installationID: installation)
            })
        await push.enable(code: try invite.code(), scope: scope)
        #expect(saved.first?.confirmed == true)

        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence, t3Push: push)
        if !cold {
            await store.start()
            let general = try #require(store.t3Channels.first)
            #expect(await store.openT3Channel(general))
        }
        let initialOpens = cold ? [] : ["general"]
        let revision = store.notificationNavigationRevision
        let expiry = Int(Date.now.timeIntervalSince1970) + 300
        let base = PushEnvelope(installationID: installation, deviceID: invite.deviceID, generation: 1,
                                eventID: String(repeating: "b", count: 64), kind: .question, expiresAt: expiry, sealed: "")
        let missing = try base.encrypting(.init(title: "", body: "", destination: scope.destination(spaceID: "deleted-space")),
                                          key: invite.previewKey)
        if !cold { await store.openPushNotification(missing) }
        #expect(service.openedStoredThreads == initialOpens)

        let destination = scope.destination(spaceID: "release")
        let envelope = try base.encrypting(.init(title: "Release", body: "Question for you", destination: destination),
                                           key: invite.previewKey)
        var tampered = envelope
        tampered.eventID = String(repeating: "c", count: 64)
        await store.openPushNotification(tampered)
        #expect(store.notificationNavigationRevision == revision)

        push.visible = scope.destination(spaceID: "general")
        #expect(store.shouldPresentPush(envelope))
        push.visible = destination
        #expect(!store.shouldPresentPush(envelope))
        await store.openPushNotification(envelope)
        #expect(service.openedStoredThreads == initialOpens + ["release"])
        #expect(store.selectedT3ChannelID == "release")
        #expect(store.notificationNavigationRevision != revision)
        #expect(store.conversation(for: "bot-project")?.messages.map(\.text) == ["Chat in release"])
    }

    @Test func failedT3ReplacementKeepsTheSavedWorkspaceAndLiveService() async throws {
        let original = ConnectionConfiguration(serverURL: URL(string: "https://studio.example")!, username: "original")
        let candidate = t3Configuration()
        defer {
            LocalHistory.remove(for: original.id)
            LocalHistory.remove(for: candidate.id)
        }
        let storage = MemoryConnectionStorage(saved: original)
        let originalService = try WorkspaceTestService()
        let candidateService = T3WorkspaceService()
        candidateService.connectError = T3ServiceError.differentEnvironment
        let store = AppStore(persistence: storage.persistence, makeService: { configuration in
            if configuration?.t3 != nil { return candidateService }
            return originalService
        })
        await store.start()
        await store.testEdit("Keep this draft", for: "milo")
        let workspace = store.chats

        #expect(!(await store.connect(candidate)))

        #expect(candidateService.disconnects == 1)
        #expect(store.configuration == original)
        #expect(storage.saved == original)
        #expect(store.chats === workspace)
        #expect(store.isConnected)
        #expect(!store.isT3Workspace)
        #expect(store.draft(for: "milo") == "Keep this draft")
        await store.open(try #require(store.bot(withID: "milo")))
        #expect(originalService.opens.last?.profile.text == "milo")
        #expect(store.chats.screen(profile: originalService.profile)?.canAct == true)
    }

    @Test func foregroundReconnectKeepsDraftAndReattachmentWarning() async throws {
        var configuration = t3Configuration()
        configuration.t3?.workspaceRoot = "/host/.botto/bots/main"
        defer { LocalHistory.remove(for: configuration.id) }
        let storage = MemoryConnectionStorage(saved: configuration)
        let store = AppStore(persistence: storage.persistence, makeService: { _ in T3WorkspaceService() })
        await store.start()
        let channel = try #require(store.t3Channels.first)
        #expect(await store.openT3Channel(channel))
        let workspace = store.chats
        let profile = try ExactID("bot-project")
        let original = try #require(workspace.screen(profile: profile))
        workspace.editDraft("Keep this with its file", owner: original.owner)
        let target = try #require(workspace.captureImport(original.owner))
        await workspace.upload(Data([1]), filename: "plan.txt", mimeType: "text/plain", to: target)
        #expect(workspace.screen(profile: profile)?.attachments.map(\.name) == ["plan.txt"])

        await store.setActive(false)
        await store.setActive(true)

        #expect(store.chats === workspace)
        let recovered = try #require(store.chats.screen(profile: profile))
        #expect(recovered.needsReattachment)
        #expect(recovered.attachments.map(\.name) == ["plan.txt"])
        #expect(workspace.draft(recovered.owner) == "Keep this with its file")
        #expect(workspace.captureSend(recovered.owner) == nil)
    }

    @Test func explicitPairingOfTheSameVerifiedProjectPreservesCachedConversationAndDraft() async throws {
        var previous = t3Configuration()
        previous.t3?.workspaceRoot = "/host/.botto/bots/main"
        let previousID = previous.id
        let resolved = try #require(previous.t3)
        let next = ConnectionConfiguration(serverURL: previous.serverURL,
            t3: .init(environmentID: resolved.environmentID, accessToken: "new-fixture-token"))
        defer { LocalHistory.remove(for: previousID); LocalHistory.remove(for: next.id) }
        let original = T3WorkspaceService()
        let replacement = T3WorkspaceService()
        replacement.resolvedPairing = next.t3.map {
            var bound = $0
            bound.projectID = resolved.projectID
            bound.workspaceRoot = resolved.workspaceRoot
            return bound
        }
        let storage = MemoryConnectionStorage(saved: previous)
        let store = AppStore(persistence: storage.persistence, makeService: {
            $0?.id == next.id ? replacement : original
        })
        await store.start()
        let bot = try #require(store.primaryT3Bot)
        await store.open(bot)
        #expect(store.selectedT3ChannelID == "release")
        await store.testEdit("Keep the typed draft", for: bot.id)
        try #require(store.flush())
        let workspace = store.chats

        #expect(await store.connect(next))
        #expect(store.chats !== workspace)
        #expect(storage.saved?.id == next.id)
        #expect(storage.saved?.t3?.projectID == resolved.projectID)
        #expect(storage.saved?.t3?.accessToken == "new-fixture-token")
        #expect(store.draft(for: bot.id) == "Keep the typed draft")
        #expect(store.conversation(for: bot.id)?.messages.map(\.text) == ["Chat in release"])
    }

    @Test func loadsAndSavesBotBrainThroughTheMountedService() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()

        let original = try await store.loadT3BotBrain()
        #expect(original.soulMarkdown == "# Soul")
        #expect(original.memoryMarkdown == "# Memory")
        #expect(original.workspaceRoot == "/host/.botto/bots/main")
        #expect(original.skills == ["skills/check"])
        let model = try #require(try await store.availableT3Models().first)
        #expect(model.modelID == "claude-test")
        #expect(try await store.readT3ProjectFile(relativePath: "skills/check/SKILL.md") == "# Check")

        var manifest = original.manifest
        manifest.displayName = "Builder"
        manifest.description = "Tracks releases."
        manifest.providerInstanceID = model.providerInstanceID
        manifest.model = model.modelID
        try await store.saveT3Soul("# Be curious", replacing: original.soulMarkdown)
        try await store.saveT3Memory("# Release checklist", replacing: original.memoryMarkdown)
        try await store.saveT3Manifest(manifest)

        let saved = try await store.loadT3BotBrain()
        #expect(saved.soulMarkdown == "# Be curious")
        #expect(saved.memoryMarkdown == "# Release checklist")
        #expect(saved.manifest == manifest)
        #expect(store.primaryT3Bot?.name == "Builder")
    }

    @Test func cacheScopesDistinguishBackendsEnvironmentsAndProjectsOnTheSameAddress() {
        let t3 = t3Configuration()
        var hermes = t3
        hermes.t3 = nil
        var otherEnvironment = t3
        otherEnvironment.t3?.environmentID = "other-environment"
        var otherProject = t3
        otherProject.t3?.projectID = "other-project"
        var rotatedToken = t3
        rotatedToken.t3?.accessToken = "replacement"

        #expect(Set([hermes, t3, otherEnvironment, otherProject].map(AppStore.artifactScope)).count == 4)
        #expect(Set([hermes, t3, otherEnvironment, otherProject].map(AppStore.richReplyAccount)).count == 4)
        #expect(AppStore.artifactScope(rotatedToken) == AppStore.artifactScope(t3))
        #expect(AppStore.richReplyAccount(rotatedToken) == AppStore.richReplyAccount(t3))
    }

    @Test func loadsTheBackendForSavedSetupWithoutAnInjectedService() {
        let t3 = t3Configuration()
        let store = AppStore(persistence: MemoryConnectionStorage(saved: t3).persistence)
        #expect(store.t3BrainService is T3BotService)
        var hermes = t3
        hermes.t3 = nil
        let prior = AppStore(persistence: MemoryConnectionStorage(saved: hermes).persistence)
        #expect(!prior.isT3Workspace)
        #expect(prior.t3BrainService == nil)
    }

    @Test func passesOutputsThroughTheMountedService() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()

        let outputs = try await store.listT3Outputs()
        #expect(outputs.map(\.relativePath) == ["outputs/report.md", "outputs/charts/plot.png"])
        let report = try #require(outputs.first)
        let downloaded = try await store.downloadT3Output(report)
        #expect(downloaded == DownloadedArtifact(data: Data("# Report".utf8), filename: "report.md", mimeType: "text/markdown"))
        #expect(service.downloadedOutputs == ["outputs/report.md"])
        await #expect(throws: T3ServiceError.invalidPath) {
            try await store.downloadT3Output(T3OutputFile(name: "secret", relativePath: "SOUL.md", mimeType: "text/plain"))
        }
    }

    @Test func managesRoutinesThroughTheMountedService() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()

        #expect(try await store.listT3Routines().isEmpty)
        let created = try await store.createT3Routine(name: "Standup", prompt: "Summarize yesterday.",
                                                      cron: "30 8 * * 1-5", threadID: "release")
        #expect(created.cron == "30 8 * * 1-5")
        #expect(created.threadID == "release")
        #expect(created.enabled)
        // Without a space, the routine gets its own.
        let general = try await store.createT3Routine(name: "Digest", prompt: "Daily digest.", cron: "0 9 * * *", threadID: nil)
        #expect(general.threadID == "routine-Digest")
        #expect(try await store.listT3Routines().map(\.name) == ["Standup", "Digest"])

        try await store.setT3RoutineEnabled(id: created.id, enabled: false)
        #expect(try await store.listT3Routines().first { $0.id == created.id }?.enabled == false)
        try await store.deleteT3Routine(id: general.id)
        #expect(try await store.listT3Routines().map(\.id) == [created.id])
        await #expect(throws: T3ServiceError.unsupportedRoutineSchedule) {
            try await store.createT3Routine(name: "Bad", prompt: "Nope", cron: "*/5 * * * *", threadID: nil)
        }
    }

    @Test func switchesChannelModelsAndMarksChannelsVisited() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()

        let model = try #require(try await store.availableT3Models().first)
        try await store.setT3ChannelModel(threadID: "release", providerInstanceID: model.providerInstanceID, model: model.modelID)
        #expect(service.channelModels == ["release": "claude/claude-test"])
        try await store.markT3ChannelVisited(threadID: "release")
        #expect(service.visitedThreads == ["release"])

        let release = try #require(store.t3Channels.last)
        #expect(await store.openT3Channel(release))
        #expect(store.selectedT3ChannelID == "release")
    }

    @Test func t3PassthroughsRefuseHermesAndDisconnectedWorkspaces() async throws {
        let hermes = ConnectionConfiguration(serverURL: URL(string: "https://studio.example")!, username: "hermes")
        defer { LocalHistory.remove(for: hermes.id) }
        let store = AppStore(service: try WorkspaceTestService(), persistence: MemoryConnectionStorage(saved: hermes).persistence)
        await store.start()
        #expect(!store.isT3Workspace)
        await #expect(throws: T3ServiceError.unsupported) { try await store.listT3Outputs() }
        await #expect(throws: T3ServiceError.unsupported) { try await store.listT3Routines() }
        await #expect(throws: T3ServiceError.unsupported) {
            try await store.setT3ChannelModel(threadID: "general", providerInstanceID: "claude", model: "claude-test")
        }
        await #expect(throws: T3ServiceError.unsupported) { try await store.markT3ChannelVisited(threadID: "general") }

        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let offline = AppStore(service: T3WorkspaceService(), persistence: MemoryConnectionStorage(saved: configuration).persistence)
        #expect(!offline.isConnected)
        await #expect(throws: T3ServiceError.disconnected) { try await offline.listT3Outputs() }
        await #expect(throws: T3ServiceError.disconnected) { try await offline.deleteT3Routine(id: "any") }
    }

    @Test func newSpacePageStartsAnAutoNamedSpaceAndSendsTheFirstMessage() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        let model = try #require(try await store.availableT3Models().first)

        try await store.startT3Space(with: "Plan the Kyoto days", model: model)

        #expect(service.createdTitles == [nil])
        let created = try #require(service.createdThreads.first)
        #expect(service.channelModels == [created: "claude/claude-test"])
        #expect(store.selectedT3ChannelID == created)
        #expect(store.selectedT3ChannelTitle == "New space")
        #expect(service.sent == [created: ["Plan the Kyoto days"]])
        #expect(store.draft(for: "bot-project").isEmpty)

        // Attaching first opens a new space and keeps the typed words as its draft, unsent.
        try await store.startT3Space(with: "Here is the itinerary", send: false)
        let second = try #require(service.createdThreads.last)
        #expect(store.selectedT3ChannelID == second)
        #expect(service.sent[second] == nil)
        #expect(store.draft(for: "bot-project") == "Here is the itinerary")
    }

    @Test func launchOpensASpaceWhoseHeaderSharesTheBarsCenterLine() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let presentation = WorkspacePresentation()
        let host = UIHostingController(rootView: T3Workspace(
            store: store, presentation: presentation, rootCovered: true, onSettings: {}))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(service.openedStoredThreads.isEmpty)
        host.rootView = T3Workspace(store: store, presentation: presentation, rootCovered: false, onSettings: {})

        // Release is waiting, so it opens first instead of a blank page.
        let (bar, title) = try await header(in: window)
        #expect(store.selectedT3ChannelID == "release")
        try checkHeader(title, in: bar)

        // A long name truncates in place without pushing the buttons away or leaving the center.
        try await store.startT3Space(named: String(repeating: "A very long space name ", count: 8), with: "", send: false)
        try await Task.sleep(for: .milliseconds(800))
        let (longBar, longTitle) = try await header(in: window)
        #expect(store.selectedT3ChannelTitle?.hasPrefix("A very long") == true)
        try checkHeader(longTitle, in: longBar)
    }

    private func header(in window: UIWindow) async throws -> (UINavigationBar, UIView) {
        func find(_ view: UIView) -> UINavigationBar? {
            if let bar = view as? UINavigationBar, !bar.isHidden { return bar }
            return view.subviews.lazy.compactMap(find).first
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            if let bar = find(window), let title = bar.topItem?.titleView, title.window === window, title.bounds.width > 60 {
                try await Task.sleep(for: .milliseconds(500))
                return (bar, title)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw T3ServiceError.missingChannel
    }

    private func checkHeader(_ title: UIView, in bar: UINavigationBar) throws {
        let frame = title.convert(title.bounds, to: bar)
        #expect(bar.bounds.insetBy(dx: 0, dy: -1).contains(frame), "\(frame) in \(bar.bounds)")
        #expect(abs(frame.midX - bar.bounds.midX) < 2, "\(frame) in \(bar.bounds)")
        let item = try #require(bar.topItem)
        for button in [item.leftBarButtonItems?.first ?? item.leadingItemGroups.first?.barButtonItems.first,
                       item.rightBarButtonItems?.first ?? item.trailingItemGroups.first?.barButtonItems.first] {
            let barButton = try #require(button)
            let view = try #require(barButton.value(forKey: "view") as? UIView)
            let other = view.convert(view.bounds, to: bar)
            #expect(abs(other.midY - frame.midY) < 2, "\(other) beside \(frame)")
            #expect(!other.intersects(frame), "\(other) over \(frame)")
        }
    }

    @Test func newSpacePageKeepsTheNameTheUserChose() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()

        try await store.startT3Space(named: "  Kyoto trip ", with: "Five slow days")
        #expect(service.createdTitles == ["Kyoto trip"])
        #expect(store.selectedT3ChannelTitle == "Kyoto trip")
        let kyoto = try #require(service.createdThreads.last)
        #expect(service.sent[kyoto] == ["Five slow days"])

        // A name alone makes a space, ready and silent.
        try await store.startT3Space(named: "Garden", with: "", send: false)
        #expect(service.createdTitles == ["Kyoto trip", "Garden"])
        #expect(store.selectedT3ChannelTitle == "Garden")
        #expect(service.sent.count == 1)
    }

    @Test func newSpaceStartFailsBeforeASpaceOpensWhenOffline() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let offline = AppStore(service: T3WorkspaceService(), persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await #expect(throws: T3ServiceError.disconnected) { try await offline.startT3Space(with: "Hello") }
        #expect(offline.selectedT3ChannelID == nil)
    }

    @Test func newSpaceDoesNotReportSuccessAfterAFailedAttachment() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        let release = try #require(store.t3Channels.first { $0.id == "release" })
        #expect(await store.openT3Channel(release))
        service.openError = .missingChannel
        var created: SessionIdentity?

        await #expect(throws: T3ServiceError.missingChannel) {
            try await store.startT3Space(with: "Keep the draft", onCreated: { created = $0 })
        }
        #expect(service.createdThreads.count == 1)
        #expect(service.sent.isEmpty)
        #expect(store.selectedT3ChannelID == release.id)

        let identity = try #require(created)
        #expect(service.createdThreads == [identity.stored.text])
    }

    @Test func emptyT3InventoryStillAllowsARetryOfCanonicalMain() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        service.currentT3Channels = []
        service.openError = .missingChannel
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        let bot = try #require(store.primaryT3Bot)
        let profile = try ExactID(bot.id)
        let first = try #require(store.prepareBotOpening(bot))
        await store.openBot(first)
        let provisional = try #require(store.chats.screen(profile: profile))
        await store.chats.refreshDirectory(provisional.owner)

        service.openError = nil
        service.canonicalThread = "recovered-main"
        let retry = try #require(store.prepareBotOpening(bot))
        await store.openBot(retry)
        #expect(store.chats.selection(profile: profile)?.identity?.stored.text == "recovered-main")
    }

    @Test func newSpaceDoesNotSendWhenTheChosenModelIsRejected() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        let model = try #require(try await store.availableT3Models().first)
        service.modelError = .missingModel

        await #expect(throws: T3ServiceError.missingModel) {
            try await store.startT3Space(with: "Use the chosen provider", model: model)
        }
        #expect(service.createdThreads.count == 1)
        #expect(service.sent.isEmpty)
    }

    @Test func failedFreshStartWithACreatedSpaceDoesNotRetryIntoItsDraft() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        let form = T3FreshDraft()
        form.message = "Only in Fresh"
        await store.start()
        service.openError = .missingChannel
        #expect(form.beginStart())
        await #expect(throws: T3ServiceError.missingChannel) {
            try await store.startT3Space(with: form.message) { form.created = $0 }
        }
        form.isStarting = false
        let created = try #require(form.created)
        service.openError = nil
        let space = try #require(store.t3Channels.first { $0.id == created.stored.text })
        #expect(await store.openT3Channel(space))
        let screen = try #require(store.chats.screen(profile: created.profile))
        store.chats.editDraft("Only in the Space", owner: screen.owner)
        let target = try #require(store.chats.captureImport(screen.owner))
        await store.chats.upload(Data([1]), filename: "keep.txt", mimeType: "text/plain", to: target)
        try await store.setT3ChannelModel(threadID: space.id, providerInstanceID: "other", model: "explicit")
        let writes = service.channelModels

        #expect(!form.beginStart())
        #expect(form.message == "Only in Fresh")
        #expect(form.created == created)
        let preserved = try #require(store.chats.screen(profile: created.profile))
        #expect(store.chats.draft(preserved.owner) == "Only in the Space")
        #expect(preserved.attachments.map(\.name) == ["keep.txt"])
        #expect(service.createdThreads == [space.id])
        #expect(service.channelModels == writes)
        #expect(service.sent.isEmpty)
    }

    @Test func lateNewSpaceDoesNotTakeOverANewerSelection() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        let gate = WorkspaceGate()
        service.createGate = gate
        let starting = Task { try await store.startT3Space(with: "Leave this unsent") }
        await gate.entered()
        defer { gate.release() }
        let release = try #require(store.t3Channels.first { $0.id == "release" })
        #expect(await store.openT3Channel(release))
        gate.release()

        await #expect(throws: HermesServiceError.staleConversation) { try await starting.value }
        #expect(store.selectedT3ChannelID == release.id)
        #expect(service.createdThreads.count == 1)
        #expect(service.sent.isEmpty)
    }

    @Test func modelChipNamesEachSpacesModel() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        #expect(store.t3ModelLabel(provider: "claude", model: "claude-test") == "claude-test")
        await store.loadT3ModelsIfNeeded()
        #expect(store.t3Models.map(\.modelID) == ["claude-test"])
        #expect(store.t3ModelLabel(provider: "claude", model: "claude-test") == "Claude Test")
        #expect(store.t3ModelLabel(provider: "other", model: "gpt-x") == "gpt-x")
        #expect(store.t3ModelLabel(provider: nil, model: nil) == nil)
        let release = try #require(store.t3Channels.first { $0.id == "release" })
        #expect(release.model == "claude-test")

        try await store.setT3DefaultModel(store.t3Models.first)
        #expect(try await store.loadT3BotBrain().manifest.model == "claude-test")
        try await store.setT3DefaultModel(nil)
        #expect(try await store.loadT3BotBrain().manifest.model == nil)
        try await store.renameT3Bot("Kit")
        #expect(store.primaryT3Bot?.name == "Kit")
    }

    @Test func brainTextReadsAsProse() {
        let memory = "# Memory\n\n- You're vegetarian on weekdays\n* Prefers **slow** mornings\n1. Lives in Tokyo\n\n"
        #expect(T3BrainText.memoryItems(memory) == ["You're vegetarian on weekdays", "Prefers slow mornings", "Lives in Tokyo"])
        #expect(T3BrainText.memorySummary(memory) == "3 things · last: “Lives in Tokyo”")
        #expect(T3BrainText.memorySummary("# Memory\n") == "Nothing yet")
        let forgotten = T3BrainText.forgetting("Prefers slow mornings", in: memory)
        #expect(forgotten == "# Memory\n\n- You're vegetarian on weekdays\n1. Lives in Tokyo\n\n")
        #expect(T3BrainText.personalitySummary("# Soul\n\nCurious, a little dry.\nKeeps answers short.") == "Curious, a little dry.")
        #expect(T3BrainText.skillName("skills/trip-planning") == "Trip Planning")
        #expect(T3BrainText.fileTitle("kyoto_5-slow-days.md") == "kyoto 5 slow days")
    }

    @Test func autosaveCoalescesTypingAndKeepsFailuresForRetry() async throws {
        var writes: [String] = []
        var failing = false
        let autosave = T3Autosave(saved: "start", delay: .milliseconds(30)) { text, _ in
            if failing { throw T3ServiceError.disconnected }
            writes.append(text)
        }
        autosave.edited("s")
        autosave.edited("st")
        autosave.edited("start")
        try await Task.sleep(for: .milliseconds(90))
        #expect(writes.isEmpty)
        autosave.edited("one")
        autosave.edited("one two")
        try await Task.sleep(for: .milliseconds(120))
        #expect(writes == ["one two"])
        #expect(autosave.state == .saved)

        failing = true
        autosave.flush("one two three")
        try await Task.sleep(for: .milliseconds(30))
        #expect(writes == ["one two"])
        guard case .failed = autosave.state else { Issue.record("Expected a failed save"); return }
        failing = false
        autosave.retry("one two three")
        try await Task.sleep(for: .milliseconds(30))
        #expect(writes == ["one two", "one two three"])
        #expect(autosave.state == .saved)
    }

    @Test func autosaveWritesTheRevertAfterAnEarlierWriteFinishes() async throws {
        let gate = WorkspaceGate()
        var hostText = "original"
        var writes: [String] = []
        let autosave = T3Autosave(saved: hostText) { text, expected in
            if text == "intermediate" { await gate.wait() }
            #expect(expected == hostText)
            hostText = text
            writes.append(text)
        }
        autosave.flush("intermediate")
        await gate.entered()
        defer { gate.release() }
        autosave.edited("original")
        autosave.flush("original")
        #expect(hostText == "original" && writes.isEmpty)
        gate.release()

        let deadline = ContinuousClock.now + .seconds(2)
        while writes.count < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(writes == ["intermediate", "original"])
        #expect(hostText == "original")
        #expect(autosave.state == .saved)
    }

    @Test func staleBrainReloadDoesNotReplaceADraftEditedDuringRead() throws {
        let autosave = T3Autosave(saved: "original", delay: .seconds(60)) { _, _ in }
        let workspaceDrafts = T3BrainDrafts()
        workspaceDrafts.memoryAutosave = autosave
        let observed = autosave.refreshRevision
        autosave.edited("my draft")
        let mounted = try #require(workspaceDrafts.memoryAutosave)
        #expect(!mounted.refresh("older host text", revision: observed))
        autosave.edited("original") // Cancels the test's debounce without dispatching a write.
    }

    @Test func routineScheduleBuilderProducesCronTheServiceAccepts() throws {
        #expect(T3RoutineSchedule.daily.cron(hour: 9, minute: 0) == "0 9 * * *")
        #expect(T3RoutineSchedule.weekdays.cron(hour: 8, minute: 30) == "30 8 * * 1-5")
        #expect(T3RoutineSchedule.days([5, 1, 3]).cron(hour: 18, minute: 5) == "5 18 * * 1,3,5")
        #expect(T3RoutineSchedule.days(Set(0...6)).cron(hour: 7, minute: 15) == "15 7 * * *")
        #expect(!T3RoutineSchedule.days([]).isValid)

        #expect(T3RoutineSchedule.parse("30 8 * * 1-5")?.schedule == .weekdays)
        #expect(T3RoutineSchedule.parse("0 9 * * 0,1,2,3,4,5,6")?.schedule == .daily)
        #expect(T3RoutineSchedule.parse("0 9 * * MON,WED")?.schedule == .days([1, 3]))
        #expect(T3RoutineSchedule.parse("0 9 * * 7")?.schedule == .days([0]))
        #expect(T3RoutineSchedule.parse("*/5 * * * *") == nil)
        #expect(T3RoutineSchedule.parse("0 9 1 * *") == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_GB")
        let locale = Locale(identifier: "en_GB")
        func time(_ hour: Int, _ minute: Int) throws -> String {
            let date = try #require(calendar.date(from: DateComponents(hour: hour, minute: minute)))
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone))
        }
        #expect(T3RoutineSchedule.summary("0 9 * * *", calendar: calendar, locale: locale) == "Daily · \(try time(9, 0))")
        #expect(T3RoutineSchedule.summary("30 8 * * 1-5", calendar: calendar, locale: locale) == "Weekdays · \(try time(8, 30))")
        #expect(T3RoutineSchedule.summary("0 10 * * 0,6", calendar: calendar, locale: locale) == "Weekends · \(try time(10, 0))")
        #expect(T3RoutineSchedule.summary("15 7 * * 1,3", calendar: calendar, locale: locale) == "Mon, Wed · \(try time(7, 15))")
        #expect(T3RoutineSchedule.summary("", calendar: calendar, locale: locale) == "Custom schedule")
        #expect(T3RoutineSchedule.summary("*/5 * * * *", calendar: calendar, locale: locale) == "Cron · */5 * * * *")
    }

    // MARK: First run

    @Test func everyNewConnectionStartsWithPairingAMac() throws {
        let t3 = t3Configuration()
        var hermes = t3
        hermes.t3 = nil
        // A fresh install, a paired workspace and the demo all pair with a Mac.
        #expect(ConnectionBackend.initial(input: "", saved: nil, isDemo: false) == .t3)
        #expect(ConnectionBackend.initial(input: "", saved: t3, isDemo: false) == .t3)
        #expect(ConnectionBackend.initial(input: "", saved: hermes, isDemo: true) == .t3)
        #expect(ConnectionBackend.initial(input: "http://192.168.1.10:3774/pair#token=A", saved: hermes, isDemo: false) == .t3)
        // Someone already on Hermes, or opening a Hermes link, still gets that page.
        #expect(ConnectionBackend.initial(input: "", saved: hermes, isDemo: false) == .hermes)
        #expect(ConnectionBackend.initial(input: "botto://hermes/connect?url=https%3A%2F%2Fhost.example", saved: nil, isDemo: false) == .hermes)
        #expect(ConnectionBackend.named(by: "https://host.example") == nil)
        #expect(ConnectionBackend.named(by: "hermes://connect?url=https%3A%2F%2Fhost.example") == .hermes)
    }

    @Test func freshInstallOpensOnBottoAndPairsWithoutNamingHermes() async throws {
        try NativeAccessibilityRuntime.enable()
        let store = AppStore(persistence: MemoryConnectionStorage().persistence)
        await store.start()
        #expect(store.configuration == nil)
        try await withHosted(RootView(store: store)) { window in
            let welcome = try await labels(in: window) { $0.contains("Pair with your Mac") }
            #expect(welcome.contains("Explore the demo"))
            #expect(!welcome.contains { $0.localizedCaseInsensitiveContains("Hermes") || $0.contains("T3") })
        }
        try await withHosted(ConnectionView(store: store)) { window in
            let pairing = try await labels(in: window) { $0.contains("Scan the code") }
            #expect(pairing.contains("Find Botto on your Mac"))
            #expect(!pairing.contains { $0.contains("T3 Code") || $0.localizedCaseInsensitiveContains("connect your hermes") })
        }
    }

    @Test func pairingStopsAtTheAddressAndAsksBeforeUnencryptedLinks() throws {
        for (link, origin) in [("http://192.168.1.10:3774/pair#token=Ab%2B", "http://192.168.1.10:3774"),
                               ("http://100.64.1.2:3774/pair#token=A", "http://100.64.1.2:3774"),
                               ("t3code://pair?pairingUrl=http%3A%2F%2F10.0.0.4%3A3774%2Fpair%23token%3DA", "http://10.0.0.4:3774")] {
            let review = try T3PairingReview(link)
            #expect(review.origin.absoluteString == origin)
            #expect(!review.isEncrypted)
            #expect(throws: PairingAddress.Failure.insecureHTTP) { try review.destination(allowingHTTP: false) }
            #expect(try review.destination(allowingHTTP: true) == review.origin)
        }
        #expect(try T3PairingReview("http://192.168.1.10:3774/pair#token=Ab%2B").credential == "Ab+")
        let tunnel = try T3PairingReview("https://botto.example.com/pair#token=A")
        #expect(tunnel.isEncrypted)
        #expect(try tunnel.destination(allowingHTTP: false).absoluteString == "https://botto.example.com")
        // HTTP outside the local network is refused before there is anything to allow.
        #expect(throws: PairingAddress.Failure.insecureHTTP) { try T3PairingReview("http://botto.example.com/pair#token=A") }
        #expect(throws: PairingAddress.Failure.insecureHTTP) { try T3PairingReview("http://8.8.8.8:3774/pair#token=A") }
        #expect(throws: T3PairingError.missingCredential) { try T3PairingReview("https://botto.example.com") }
        #expect(try T3PairingReview("https://botto.example.com", code: "typed").credential == "typed")
        #expect(T3PairingReview.message(for: T3PairingError.httpStatus(401)).contains("expired"))
        #expect(!T3PairingReview.message(for: T3PairingError.missingCredential).contains("T3"))
    }

    @Test func firstRunNamesTheBotAndItsMainSpaceAndSavesTheFace() async throws {
        try NativeAccessibilityRuntime.enable()
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService(fresh: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        #expect(store.needsT3BotSetup)

        try await withHosted(T3Workspace(store: store, presentation: WorkspacePresentation(), rootCovered: false, onSettings: {})) { window in
            let page = try await labels(in: window) { $0.contains("Meet your new bot") }
            #expect(page.contains("Say hello to Botto"))
            #expect(page.contains("Its main space gets this name too."))

            // A failed rename keeps the page, so it can simply be tried again. The choices are already safe.
            service.failsRename = true
            await #expect(throws: HermesServiceError.uncertain) {
                try await store.setUpT3Bot(name: "Miso", face: BotFace(shape: .cloud, color: "#f97316"))
            }
            #expect(service.manifest.displayName == "Miso")
            #expect(store.needsT3BotSetup)
            _ = try await labels(in: window) { $0.contains("Meet your new bot") }

            service.failsRename = false
            try await store.setUpT3Bot(name: " Miso ", face: BotFace(shape: .cloud, color: "#f97316"))
            #expect(!store.needsT3BotSetup)
            _ = try await labels(in: window) { !$0.contains("Meet your new bot") }
        }
        #expect(service.renames == ["general": "Miso"])
        #expect(store.primaryT3Bot?.name == "Miso")
        #expect(store.primaryT3Bot?.appearance?.shape == .cloud)
        #expect(store.t3Channels.first(where: \.isMain)?.displayTitle == "Miso")
        // What bot.json holds.
        let saved = try JSONDecoder().decode(T3BotManifest.self, from: Data(T3BotBootstrap.manifestJSON(service.manifest).utf8))
        #expect(saved.displayName == "Miso")
        #expect(saved.avatar?.shape == .cloud)
        #expect(saved.avatar?.color == BotAvatarColors.preset(for: "#f97316")?.shared)
    }

    /// The main space can beat the bot list, or wait for a host that is still looking for its providers.
    @Test(arguments: [true, false]) func firstRunEndsInTheMainSpace(whenItArrivesFirst early: Bool) async throws {
        try NativeAccessibilityRuntime.enable()
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService(fresh: true, mainSpace: early)
        // Real answers are slow enough for launch to see each half-loaded step.
        service.latency = .milliseconds(150)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)

        try await withHosted(T3Workspace(store: store, presentation: WorkspacePresentation(), rootCovered: false, onSettings: {})) { window in
            await store.start()
            _ = try await labels(in: window) { $0.contains("Meet your new bot") }
            if !early {
                #expect(store.t3Channels.isEmpty)
                service.makeMainSpace()
                service.onEvent?(.botsChanged)
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while store.t3Channels.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try #require(!store.t3Channels.isEmpty, "The main space never reached the store")
            try await store.setUpT3Bot(name: "Miso", face: BotFace(shape: .cloud, color: "#f97316"))
            _ = try await labels(in: window) { $0.contains { $0.contains("Chat in general") } }
            #expect(store.selectedT3ChannelID == "general")
        }
    }

    @Test func aBotSomeoneAlreadyKnowsSkipsFirstRun() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let store = AppStore(service: T3WorkspaceService(), persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        #expect(store.isT3Workspace)
        #expect(!store.needsT3BotSetup)
    }

    private func withHosted(_ view: some View, _ body: (UIWindow) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await body(window)
    }

    /// Everything the hosted view reads out, once it satisfies `ready`.
    private func labels(in window: UIWindow, until ready: (Set<String>) -> Bool) async throws -> Set<String> {
        func walk(_ object: NSObject, into found: inout Set<String>, seen: inout Set<ObjectIdentifier>) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let label = object.accessibilityLabel, !label.isEmpty { found.insert(label) }
            var children: [NSObject] = (object as? UIView)?.subviews ?? []
            children += ((object.accessibilityElements ?? []) + (object.automationElements ?? [])).compactMap { $0 as? NSObject }
            let count = object.accessibilityElementCount()
            if count > 0, count < 4096 { children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject } }
            for child in children { walk(child, into: &found, seen: &seen) }
        }
        let deadline = ContinuousClock.now + .seconds(15)
        var found: Set<String> = []
        while ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            found = []
            var seen: Set<ObjectIdentifier> = []
            walk(window, into: &found, seen: &seen)
            if !found.isEmpty, ready(found) { return found }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("The hosted view never settled: \(found.sorted())")
        return found
    }

    private func t3Configuration() -> ConnectionConfiguration {
        .init(serverURL: URL(string: "https://studio.example")!, installID: "studio-id",
              t3: .init(environmentID: "studio-id", label: "Studio", accessToken: "fixture-only", projectID: "bot-project"))
    }
}

@MainActor private final class T3WorkspaceService: T3BotBrainControlling {
    var onEvent: ((BotServiceEvent) -> Void)?
    var connectError: T3ServiceError?
    var resolvedPairing: T3Connection?
    var openError: T3ServiceError?
    var canonicalThread: String?
    var modelError: T3ServiceError?
    var createGate: WorkspaceGate?
    private(set) var disconnects = 0
    private(set) var openedStoredThreads: [String] = []
    private(set) var downloadedOutputs: [String] = []
    private(set) var channelModels: [String: String] = [:]
    private(set) var visitedThreads: [String] = []
    private(set) var createdTitles: [String?] = []
    private(set) var createdThreads: [String] = []
    private(set) var sent: [String: [String]] = [:]
    private var routines: [T3ScheduledRoutine] = []
    private(set) var manifest = T3BotManifest(displayName: "Studio Bot")
    var failsRename = false
    var latency: Duration = .zero
    private(set) var renames: [String: String] = [:]
    private var soul = "# Soul"
    private var memory = "# Memory"
    private let issuer = ConversationIssuer<SessionIdentity>()
    private let profile = try! ExactID("bot-project")

    let currentBotWorkspaceRoot: String? = "/host/.botto/bots/main"
    var currentT3Channels: [T3ChannelSummary] = [
        .init(id: "general", title: "#general", isMain: true, isPinned: false, isArchived: false, isUnread: false,
              status: .idle, preview: "", updatedAt: nil),
        .init(id: "release", title: "Release", isPinned: false, isArchived: false, isUnread: true,
              status: .waiting, preview: "Release notes", updatedAt: nil, providerInstanceID: "claude", model: "claude-test"),
    ]

    /// A fresh workspace holds only the main space its first connection made.
    init(fresh: Bool = false, mainSpace: Bool = true) {
        guard fresh else { return }
        manifest = T3BotManifest(displayName: "Botto")
        currentT3Channels = []
        if mainSpace { makeMainSpace() }
    }

    func makeMainSpace() {
        manifest.mainThreadID = "general"
        currentT3Channels = [.init(id: "general", title: "Botto", isMain: true, isPinned: false, isArchived: false,
                                   isUnread: false, status: .idle, preview: "", updatedAt: nil)]
    }

    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        if let connectError { throw connectError }
        if let resolvedPairing {
            var connected = configuration
            connected.t3 = resolvedPairing
            onEvent?(.configuration(connected))
        }
        return .init(version: "fixture", installID: configuration.t3?.environmentID)
    }
    func disconnect() { disconnects += 1; issuer.retireAttachment() }
    func bots() async throws -> [BotProfile] {
        try await Task.sleep(for: latency)
        return [.init(id: profile.text, name: manifest.displayName, description: manifest.description, model: manifest.model,
               appearance: manifest.avatar)]
    }
    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        try await Task.sleep(for: latency)
        let summaries = try currentT3Channels.map { channel in
            let thread = try ExactID(channel.id)
            return SessionSummary(identity: .init(profile: profile, root: thread, stored: thread, aliases: []),
                                  title: channel.displayTitle, isCanonical: false, persistence: .durable)
        }
        return .init(summaries: summaries, activity: [:], isComplete: true)
    }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        if let openError { throw openError }
        let identity: SessionIdentity
        switch target {
        case .stored(let requested) where requested.profile == profile:
            identity = requested
            openedStoredThreads.append(identity.stored.text)
        case .canonical(let requested, nil) where requested == profile:
            guard let canonicalThread else { throw T3ServiceError.missingChannel }
            let id = try ExactID(canonicalThread)
            identity = .init(profile: profile, root: id, stored: id, aliases: [])
        default:
            throw T3ServiceError.missingChannel
        }
        try await Task.sleep(for: latency * 3)
        let thread = identity.stored.text
        let snapshot = Conversation(id: thread, storedID: thread, profileID: profile.text,
                                    messages: [.init(id: "reply", role: .assistant, text: "Chat in \(thread)")])
        return .init(identity: identity, snapshot: snapshot, access: try issuer.issue(identity))
    }
    func loadBotBrain() async throws -> T3BotBrainSnapshot {
        .init(manifest: manifest, soulMarkdown: soul, memoryMarkdown: memory, skills: ["skills/check"],
              workspaceRoot: "/host/.botto/bots/main")
    }
    func saveSoul(_ markdown: String, replacing expected: String?) async throws {
        if let expected, expected != soul { throw T3ServiceError.proseChanged }
        soul = markdown
    }
    func saveMemory(_ markdown: String, replacing expected: String?) async throws {
        if let expected, expected != memory { throw T3ServiceError.proseChanged }
        memory = markdown
    }
    func saveManifest(_ manifest: T3BotManifest) async throws { self.manifest = manifest }
    func setDefaultModel(_ option: T3ModelOption?) async throws -> T3BotManifest {
        manifest.providerInstanceID = option?.providerInstanceID
        manifest.model = option?.modelID
        return manifest
    }
    func availableModels() async throws -> [T3ModelOption] {
        [.init(id: "claude-test", providerInstanceID: "claude", providerName: "Claude", modelID: "claude-test", label: "Claude Test")]
    }
    func readProjectFile(relativePath: String) async throws -> String {
        guard relativePath == "skills/check/SKILL.md" else { throw T3ServiceError.invalidPath }
        return "# Check"
    }

    func listOutputs() async throws -> [T3OutputFile] {
        [.init(name: "report.md", relativePath: "outputs/report.md", mimeType: "text/markdown"),
         .init(name: "plot.png", relativePath: "outputs/charts/plot.png", mimeType: "image/png")]
    }
    func downloadOutput(_ output: T3OutputFile) async throws -> DownloadedArtifact {
        guard output.relativePath.hasPrefix("outputs/") else { throw T3ServiceError.invalidPath }
        downloadedOutputs.append(output.relativePath)
        return .init(data: Data("# Report".utf8), filename: output.name, mimeType: output.mimeType)
    }
    func listRoutines() async throws -> [T3ScheduledRoutine] { routines }
    func createRoutine(name: String, prompt: String, cron: String, threadID: String?) async throws -> T3ScheduledRoutine {
        guard T3RoutineSchedule.parse(cron) != nil else { throw T3ServiceError.unsupportedRoutineSchedule }
        let routine = T3ScheduledRoutine(id: "routine-\(routines.count + 1)", name: name, prompt: prompt, cron: cron,
                                         enabled: true, threadID: threadID ?? "routine-\(name)",
                                         nextRunAt: nil, lastRunAt: nil)
        routines.append(routine)
        return routine
    }
    func setRoutineEnabled(id: String, enabled: Bool) async throws {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { throw T3ServiceError.invalidResponse }
        let old = routines[index]
        routines[index] = .init(id: old.id, name: old.name, prompt: old.prompt, cron: old.cron, enabled: enabled,
                                threadID: old.threadID, nextRunAt: old.nextRunAt, lastRunAt: old.lastRunAt)
    }
    func deleteRoutine(id: String) async throws {
        guard routines.contains(where: { $0.id == id }) else { throw T3ServiceError.invalidResponse }
        routines.removeAll { $0.id == id }
    }
    func setChannelModel(threadID: String, providerInstanceID: String, model: String) async throws {
        if let modelError { throw modelError }
        channelModels[threadID] = "\(providerInstanceID)/\(model)"
    }
    func markChannelVisited(threadID: String) async throws { visitedThreads.append(threadID) }

    func createBot(_ draft: BotDraft) async throws -> BotProfile { throw T3ServiceError.unsupported }
    func createChat(title: String?) async throws -> CreatedSession {
        await createGate?.wait()
        let id = "chat-\(createdThreads.count + 1)"
        createdTitles.append(title)
        createdThreads.append(id)
        currentT3Channels.insert(.init(id: id, title: title ?? T3ChannelSummary.untitledWireTitle, isPinned: false,
                                       isArchived: false, isUnread: false, status: .idle, preview: "", updatedAt: .now), at: 0)
        let thread = try ExactID(id)
        return .init(operationID: UUID(), summary: .init(identity: .init(profile: profile, root: thread, stored: thread, aliases: []),
                                                         title: "New chat", isCanonical: false, persistence: .durable))
    }
    func updateProfile(_ edit: BotProfileEdit, for bot: BotProfile) async throws -> BotProfile {
        if let name = edit.name { manifest.displayName = name }
        return try await bots()[0]
    }
    func renameChannel(threadID: String, title: String) async throws {
        if failsRename { throw HermesServiceError.uncertain }
        renames[threadID] = title
        currentT3Channels = currentT3Channels.map { space in
            guard space.id == threadID else { return space }
            return .init(id: space.id, title: title, isMain: space.isMain, isPinned: space.isPinned, isArchived: space.isArchived,
                         isUnread: space.isUnread, status: space.status, preview: space.preview, updatedAt: space.updatedAt)
        }
    }
    func setChannelPinned(threadID: String, pinned: Bool) async throws { throw T3ServiceError.unsupported }
    func archiveChannel(threadID: String, archived: Bool) async throws { throw T3ServiceError.unsupported }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw T3ServiceError.unsupported }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess,
              operationID: UUID) async throws -> MutationReceipt {
        let identity = try issuer.resolve(access)
        sent[identity.stored.text, default: []].append(text)
        return .init(operationID: operationID, source: identity, admissionID: operationID.uuidString, journal: .saved)
    }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw T3ServiceError.unsupported }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess,
                 operationID: UUID) async throws -> MutationReceipt { throw T3ServiceError.unsupported }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        _ = try issuer.resolve(access)
        return .init(name: filename, path: "staged/" + filename, mimeType: mimeType)
    }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        throw T3ServiceError.unsupported
    }
}
