import Foundation
import Testing
import BottoCore
import SwiftUI
import UIKit
import WebKit
@testable import Botto

@MainActor @Suite(.serialized, RichReplyRuntime()) struct AppStoreRichReplyTests {
    @Test func expiredRecognitionDoesNotStartWork() async {
        var started = false
        let result = await NativeRecognitionDeadline.run(until: .now - .seconds(1)) {
            started = true
            return ["unexpected"]
        }
        #expect(result == nil && !started)
    }

    @Test func recognitionExpiryReturnsBeforeUncooperativeWorkAndIgnoresItsLateResult() async {
        let work = RichReplyFileGate(), expiry = RichReplyFileGate()
        let worker = Task { await work.wait(); return ["late recognition"] }
        let waiter = Task {
            await NativeRecognitionDeadline.run(expiration: { await expiry.wait() }) { await worker.value }
        }
        await work.entered(); await expiry.entered()
        expiry.release()
        #expect(await waiter.value == nil)
        work.release()
        #expect(await worker.value == ["late recognition"])
        await Task.yield()
    }

    @Test func recognitionCancellationReturnsBeforeItsWorkerAndSuccessfulRecognitionKeepsItsWords() async {
        let work = RichReplyFileGate(), expiry = RichReplyFileGate()
        let worker = Task { await work.wait(); return ["cancelled recognition"] }
        let waiter = Task {
            await NativeRecognitionDeadline.run(expiration: { await expiry.wait() }) { await worker.value }
        }
        await work.entered(); await expiry.entered()
        waiter.cancel()
        #expect(await waiter.value == nil)
        work.release(); expiry.release()
        _ = await worker.value
        let current = await NativeRecognitionDeadline.run(until: .now + .seconds(5)) { ["current recognition"] }
        #expect(current == ["current recognition"])
    }

    @Test func transientAttachmentsReadCurrentBytesAndOnlyIdentifiedRowsRetainCaptures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RichReplyTestService(), cache = ArtifactCache(root: root)
        let attachment = ChatAttachment(name: "report.html", path: "/report.html", mimeType: "text/html")
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://transient-files.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}), artifactCache: cache)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        service.chat.messages = [.init(id: "inflight-user", role: .user, text: "@file:/report.html", attachments: [attachment], transientID: UUID())]
        try #require(await store.connect(configuration)); await store.open(service.bot)
        let source = try service.authority.identity(service.chat)
        let first = try #require(store.artifactDestination(for: attachment, botID: service.bot.id, producingMessage: service.chat.messages[0]))
        let firstBytes = try await store.downloadArtifact(first)
        store.finishArtifact(first)
        #expect(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: service.chat.messages) == nil)
        service.chat.messages[0].transientID = UUID()
        service.downloadData = Data("<p>Later turn at the same path</p>".utf8)
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(!store.isAuthorizedArtifactPresentation(first))
        let second = try #require(store.artifactDestination(for: attachment, botID: service.bot.id, producingMessage: service.chat.messages[0]))
        #expect(try await store.downloadArtifact(second).data != firstBytes.data)
        store.finishArtifact(second)
        #expect(service.downloads.count == 2)
        service.chat.messages[0].id = service.chat.storedID + ":row:7"
        service.chat.messages[0].transientID = nil
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        let durable = try #require(store.artifactDestination(for: attachment, botID: service.bot.id, producingMessage: service.chat.messages[0]))
        let captured = try await store.downloadArtifact(durable)
        store.finishArtifact(durable)
        let key = try #require(await WorkspaceLibrary.originalKey(identity: source, attachment: attachment, messages: service.chat.messages))
        #expect(service.downloads.count == 3)
        store.library.retire(); await cache.close()
        let coldCache = ArtifactCache(root: root)
        let scope = ArtifactCacheScope(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: nil, username: Data(), provider: nil)
        #expect(try await coldCache.session(scope: scope).original(for: key)?.artifact.data == captured.data)
        #expect(service.downloads.count == 3)
        await coldCache.close()
    }
    @Test func previewScopeCreatedDuringWorkRefreshesThePreviousCaptureWhenWorkSettles() async throws {
        let service = RichReplyTestService()
        service.chat.messages[0].text = "::preview{file='report.html'}"
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://already-working-preview.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let attachment = try #require(block.filePreview?.attachment)
        let destination = try #require(store.artifactDestination(for: attachment, botID: service.bot.id, producingMessage: service.chat.messages[0]))
        _ = try await store.downloadArtifact(destination)
        store.finishArtifact(destination)
        service.chat.isWorking = true
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        #expect(!context.permits(block))
        service.downloadData = Data("<button>Finished later work</button>".utf8)
        service.chat.isWorking = false
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        let loaded = try await context.loadFile(block)
        defer { loaded.finishInstallation() }
        #expect(loaded.resolved.block.source == "<button>Finished later work</button>")
        #expect(service.downloads.count == 2)
    }

    @Test(arguments: ["working", "canonical"])
    func mountedFilePreviewReauthorizationUsesCapturedBytesWithoutRevivingOldGrant(event: String) async throws {
        let service = RichReplyTestService()
        service.chat.messages[0].text = "::preview{file='report.html'}"
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://mounted-preview.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let first = try await context.loadFile(block)
        first.finishInstallation()
        let originalFile = first.resolved
        let view = ScrollView {
            AssistantReplyBody(message: service.chat.messages[0], isStreaming: false)
                .environment(\.richReplyContext, context)
                .environment(\.scenePhase, .active)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: view), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let mounted = try await MountedReplyFileDocument.waitForText("Native file preview", in: host.view)
        #expect(service.downloads.count == 1)
        // Coalesce both publications without giving SwiftUI an intermediate body.
        let original = service.chat.messages[0].text
        if event == "working" {
            service.chat.isWorking = true
            service.downloadData = Data("<button>Updated after work</button>".utf8)
        }
        else { service.chat.messages[0].text = "Replaced" }
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        service.chat.isWorking = false; service.chat.messages[0].text = original
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(!originalFile.context.permits(originalFile.block), "Restoring source must not revive the original file grant")
        let recovered = try await MountedReplyFileDocument.waitForText(event == "working" ? "Updated after work" : "Native file preview", in: host.view, excluding: mounted)
        #expect(recovered !== mounted && mounted.superview == nil,
                "The mounted preview must replace its revoked document, not just reauthorize a direct loader")
        let replacement = try await context.loadFile(block)
        defer { replacement.finishInstallation() }
        #expect(replacement.resolved.context.permits(replacement.resolved.block))
        #expect(replacement.resolved.block.source == (event == "working" ? "<button>Updated after work</button>" : originalFile.block.source))
        #expect(service.downloads.count == (event == "working" ? 2 : 1), "Settled work refreshes once; authority recovery and ordinary reopen reuse the capture")
    }
    @Test(arguments: [false, true])
    func mountedDocumentObservationRejectsPixelsRetiredDuringRecognition(activeResources: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIViewController(), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        let first = RichContentRenderer(), replacement = RichContentRenderer()
        defer {
            first.stop(); replacement.stop()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        let block = try #require(ReplyContent(assistantText: """
        ```html
        <p style='margin-top:50px;font-size:28px'>Mounted observation</p>
        <button>Update preview</button><p>Ready for review</p>
        <div style='height:30px;background:#6366f1'></div>
        ```
        """).blocks.first)
        await first.load(block)
        let original = try #require(first.webView)
        original.frame = CGRect(x: 0, y: 100, width: 390, height: 300)
        host.view.addSubview(original)
        var didRetire = false
        func replaceDocument() async throws {
            try Task.checkCancellation()
            didRetire = true
            first.stop()
            await replacement.load(block)
            try Task.checkCancellation()
            let current = try #require(replacement.webView)
            current.frame = original.frame
            host.view.addSubview(current)
        }
        // This recognizer deliberately creates a second document before returning old pixels.
        let observed = try await MountedReplyFileDocument.waitForText("Mounted observation", in: host.view,
            observationBudget: .seconds(45), recognize: { pixels in
            let words = try await NativeTextRecognition.recognize(pixels, languages: ["en-US"])
            if !didRetire && words.joined(separator: " ").localizedStandardContains("Mounted observation") {
                if activeResources {
                    let image = UIImage(cgImage: pixels)
                    var complete = false
                    let active = try await RenderedTranscriptFile.observeActive(image, in: CGRect(origin: .zero, size: image.size),
                        isCurrent: { first.webView === original && first.state == .ready && original.window === window },
                        observe: { image, region in
                            let captured = try await RenderedTranscriptFile.observe(image, in: region)
                            complete = captured.isComplete
                            if complete { try await replaceDocument() }
                            return captured
                        })
                    guard complete else { return [] }
                    #expect(active == nil, "Retired pixels must not admit a later active-resource sample")
                } else { try await replaceDocument() }
            }
            return words
        })
        let current = try #require(replacement.webView)
        #expect(didRetire)
        #expect(observed === current, "The same waiter must reject retired pixels and observe the replacement")
        #expect(current.window === window && original.superview == nil)
    }

    @Test func failedSettledWorkRefreshKeepsTheCapturedFileUsableWithoutRevivingInlineAuthority() async throws {
        let service = RichReplyTestService()
        service.chat.messages[0].text = "::preview{file='report.html'}"
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://work-refresh-failure.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        let first = try await context.loadFile(block); first.finishInstallation()
        service.chat.isWorking = true
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        service.chat.isWorking = false
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        service.downloadError = HermesServiceError.disconnected
        await #expect(throws: (any Error).self) { _ = try await context.loadFile(block) }
        #expect(!first.resolved.context.permits(first.resolved.block))
        let attachment = try #require(block.filePreview?.attachment)
        let destination = try #require(store.artifactDestination(for: attachment, botID: service.bot.id, producingMessage: service.chat.messages[0]))
        defer { store.finishArtifact(destination) }
        #expect(try await store.downloadArtifact(destination).data == Data("<button>Native file preview</button>".utf8))
    }

    @Test func previewDirectiveLoadsThroughItsOwningChatAndBindsDownloadedHTML() async throws {
        let service = RichReplyTestService()
        service.chat.messages[0].text = "::preview{file=\"report.html\"}"
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://preview.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let directive = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        let pending = try await context.loadFile(directive)
        let resolved = pending.resolved
        pending.finishInstallation()
        #expect(service.downloads.first?.0.path == "report.html")
        #expect(service.downloads.first?.1.storedID == "stored")
        #expect(service.downloads.first?.1.profileID == "cache-bot")
        #expect(resolved.block.source == "<button>Native file preview</button>")
        #expect(resolved.context.permits(resolved.block))
        let unrelated = try #require(ReplyContent(assistantText: "```html\n<script>unrelated()</script>\n```").blocks.first)
        #expect(!resolved.context.permits(unrelated))
        let ticket = try #require(resolved.context.begin(resolved.block, layout: nil, onRevoke: {}).ticket)
        DiagramMemory.shared.handlePressure()
        #expect(!ticket.isCurrent, "Pressure retires active rendering")
        #expect(resolved.context.permits(resolved.block), "Pressure must retain canonical file authority for a fresh renderer")
        let replacement = try #require(resolved.context.begin(resolved.block, layout: nil, onRevoke: {}).ticket)
        #expect(replacement.isCurrent)
        service.chat.messages[0].text = "Changed"
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(!ticket.isCurrent)
        #expect(!resolved.context.permits(resolved.block))
        service.chat.messages[0].text = "::preview{file=\"report.html\"}"
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(!resolved.context.permits(resolved.block), "A downloaded document's revoked grant must never revive")
    }

    @Test(arguments: ["canonical", "selection", "background", "stored"])
    func previewDirectiveCannotPublishLateBytesAfterRetirement(event: String) async throws {
        let service = RichReplyTestService()
        let text = "::preview{file=\"report.html\"}"
        service.chat.messages[0].text = text
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://preview-retire.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        let gate = RichReplyFileGate()
        service.downloadGate = gate
        let loading = Task { try await context.loadFile(block) }
        await gate.entered()
        switch event {
        case "canonical":
            service.chat.messages[0].text = "Replaced"
            service.onEvent?(.conversation(try service.authority.opened(service.chat)))
            service.chat.messages[0].text = text
            service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        case "selection": store.selectedBotID = nil
        case "background": await store.setActive(false)
        default:
            service.chat.storedID = "replacement"
            service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        }
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await loading.value }
        #expect(service.downloadWasCancelled)
    }

    @Test func automaticFilePreviewLoadsQuietlyAndReportsFailuresAndExplicitRetries() async throws {
        let service = RichReplyTestService()
        service.chat.messages[0].text = "::preview{file='report.html'}"
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://preview-feedback.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        let model = ReplyFilePreviewModel()
        let automaticGate = RichReplyFileGate()
        service.downloadGate = automaticGate
        service.downloadError = HermesServiceError.disconnected
        let automatic = Task { await model.load(block, context: context) }
        await automaticGate.entered()
        #expect(model.feedback == .quiet)
        #expect(!model.canRetry)
        automaticGate.release()
        await automatic.value
        #expect(model.feedback == .failed(HermesServiceError.disconnected.localizedDescription))
        #expect(model.canRetry)

        let retryGate = RichReplyFileGate()
        service.downloadGate = retryGate
        let retry = Task { await model.load(block, context: context, isRetry: true) }
        await retryGate.entered()
        #expect(model.feedback == .loading)
        #expect(!model.canRetry)
        retryGate.release()
        await retry.value
        guard case .failed(let message) = model.feedback else {
            Issue.record("An explicit retry must report its failure")
            return
        }
        #expect(!message.isEmpty)
        #expect(model.canRetry)

        service.downloadGate = nil
        await model.load(block, context: context)
        #expect(model.feedback == .failed(HermesServiceError.disconnected.localizedDescription))
        #expect(model.canRetry)
        service.downloadError = nil
        await model.load(block, context: context, isRetry: true)
        #expect(model.resolved?.block.source == "<button>Native file preview</button>")
        #expect(model.feedback == .quiet)
        #expect(!model.canRetry)
    }

    @Test func cancelledFilePreviewCannotPublishItsLateDownload() async throws {
        let service = RichReplyTestService()
        service.chat.messages[0].text = "::preview{file='report.html'}"
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://preview-cancel.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        let model = ReplyFilePreviewModel()
        let gate = RichReplyFileGate()
        service.downloadGate = gate
        let loading = Task { await model.load(block, context: context, isRetry: true) }
        await gate.entered()
        #expect(model.feedback == .loading)
        model.cancel()
        gate.release()
        await loading.value
        #expect(model.resolved == nil)
        #expect(model.feedback == .quiet)
        #expect(!model.canRetry)
    }

    @Test(arguments: ["unchanged", "revoked", "message"])
    func filePreviewReloadReusesCapturesOnlyForTheSameOccurrence(event: String) async throws {
        let service = RichReplyTestService()
        let directive = "::preview{file='report.html'}"
        service.chat.messages[0].text = directive
        service.chat.messages.append(.init(id: "m1", role: .assistant, text: directive))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://preview-retention.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        let model = ReplyFilePreviewModel()
        await model.load(block, context: context)
        let original = try #require(model.resolved(for: block, context: context))
        #expect(original.block.source == "<button>Native file preview</button>")
        if event == "revoked" {
            service.chat.messages[0].text = "Replaced"
            service.onEvent?(.conversation(try service.authority.opened(service.chat)))
            service.chat.messages[0].text = directive
            service.onEvent?(.conversation(try service.authority.opened(service.chat)))
            #expect(model.resolved(for: block, context: context) == nil,
                    "Restoring canonical text cannot revive a revoked document")
            #expect(model.resolved?.context.permits(original.block) == false)
        }
        let reloadContext = event == "message"
            ? store.richReplyContext(for: service.bot.id, messageID: "m1") : context
        #expect((model.resolved(for: block, context: reloadContext) != nil) == (event == "unchanged"))
        service.downloadError = HermesServiceError.disconnected
        if event == "message" {
            let gate = RichReplyFileGate()
            service.downloadGate = gate
            let reload = Task { await model.load(block, context: reloadContext) }
            defer { gate.release(); reload.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while service.downloads.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try #require(service.downloads.count == 2, "A different occurrence must request its own capture")
            #expect(model.resolved(for: block, context: reloadContext) == nil)
            gate.release(); await reload.value
            #expect(model.resolved(for: block, context: reloadContext) == nil)
        } else {
            await model.load(block, context: reloadContext)
            let captured = try #require(model.resolved(for: block, context: reloadContext))
            #expect(captured.block.source == original.block.source)
            #expect(captured.context.permits(captured.block))
            #expect(service.downloads.count == 1)
            if event == "revoked" { #expect(!original.context.permits(original.block)) }
        }
        model.cancel()
        #expect(model.resolved == nil)
        #expect(model.feedback == .quiet)
        #expect(!model.canRetry)
    }

    @Test func previewDirectiveWaitsForTurnSettleAndFailureCanRetry() async throws {
        let service = RichReplyTestService()
        service.chat.messages[0].text = "::preview{file=\"report.html\"}"
        service.chat.isWorking = true
        service.chat.messages.append(.init(id: "tool", role: .tool, text: "Writing the HTML file"))
        service.chat.messages.append(.init(id: "queued", role: .user, text: "Queued follow-up"))
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://preview-settle.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        await #expect(throws: (any Error).self) { _ = try await context.loadFile(block) }
        #expect(service.downloads.isEmpty)
        service.chat.isWorking = false
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        let model = ReplyFilePreviewModel()
        service.downloadError = HermesServiceError.invalidAttachment
        await model.load(block, context: context)
        #expect(model.resolved == nil)
        #expect(model.errorMessage != nil)
        service.downloadError = nil
        await model.load(block, context: context)
        #expect(model.resolved?.block.source == "<button>Native file preview</button>")
        #expect(model.errorMessage == nil)
    }

    @Test func actualStoreIssuesAndIrreversiblyRetiresCanonicalAuthority() async throws {
        let service = RichReplyTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://cache-test.invalid")!, username: "alice")
        var saved: ConnectionConfiguration?
        let store = AppStore(service: service, persistence: .init(load: { saved }, save: { saved = $0 }, remove: { saved = nil }))
        defer { LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        #expect(context.permits(block))
        #expect(!store.richReplyContext(for: "other", messageID: "m0").permits(block))
        let layout = try #require(DiagramLayout(dark: false, reduceMotion: false, width: 380, viewportHeight: nil))
        let ticket = try #require(context.begin(block, layout: layout, onRevoke: {}).ticket)
        service.chat.messages[0].text = "```mermaid\ngraph LR\nA[Changed] --> B[Done]\n```\n"
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        service.chat.messages[0].text = RichReplyTestService.text
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(!ticket.isCurrent, "A→B→A must not revive an old publication")
        #expect(context.permits(block), "Fresh work on the current canonical A remains authorized")
        store.showsConnection = true
        #expect(!context.permits(block))
        #expect(!store.richReplyContext(for: service.bot.id, messageID: "m0").permits(block))
        ticket.cancel()
    }

    @Test(arguments: ["runtime", "stored", "background", "forget", "failed-forget", "open", "selection", "unicode-selection", "same-id-origin"])
    func actualLifecycleRetiresOnlyTheExpectedEpoch(event: String) async throws {
        let service = RichReplyTestService()
        var saved: ConnectionConfiguration?
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://epoch.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { saved }, save: { saved = $0 }, remove: {
            if event == "failed-forget" { throw HermesServiceError.disconnected }
            saved = nil
        }))
        defer { LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let old = store.richReplyContext(for: service.bot.id, messageID: "m0")
        #expect(old.permits(block))
        switch event {
        case "runtime": service.chat.id = "new-runtime"; service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        case "stored": service.chat.storedID = "new-stored"; service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        case "same-id-origin":
            var replacement = configuration
            replacement.serverURL = URL(string: "https://replaced-origin.invalid")!
            service.onEvent?(.configuration(replacement))
        case "background": await store.setActive(false)
        case "forget", "failed-forget": store.forgetConnection()
        case "open": await store.open(service.bot)
        case "unicode-selection": store.selectedBotID = "cache-bo\u{301}t"
        default: store.selectedBotID = nil
        }
        #expect(old.permits(block) == (event == "failed-forget"))
        #expect(!store.richReplyContext(for: service.bot.id, messageID: "missing").permits(block))
    }

    @Test func URLSecretsCannotBecomeRetainedAccountKeys() async throws {
        let service = RichReplyTestService()
        var saved: ConnectionConfiguration?
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://cache.invalid/?token=test-sentinel")!)
        let store = AppStore(service: service, persistence: .init(load: { saved }, save: { saved = $0 }, remove: { saved = nil }))
        defer { LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        #expect(!store.richReplyContext(for: service.bot.id, messageID: "m0").permits(block))
    }

    @Test func incompleteStreamingBlockCannotAuthorizeExecutionButClosedAppendedBlockSurvives() async throws {
        let service = RichReplyTestService()
        var saved: ConnectionConfiguration?
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://stream.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { saved }, save: { saved = $0 }, remove: { saved = nil }))
        defer { LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let block = try #require(ReplyContent(message: service.chat.messages[0]).blocks.first)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        service.chat.isWorking = true
        service.chat.messages[0].text += "Native appended text"
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(context.permits(block))
        service.chat.messages[0].text = String(RichReplyTestService.text.dropLast())
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(!context.permits(block), "A streaming closing fence needs its final line ending")
        service.chat.messages[0].text = RichReplyTestService.text
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(context.permits(block))
    }

}

@MainActor final class RichReplyTestService: BotService {
    static let text = "```mermaid\ngraph LR\nA[Start] --> B[Done]\n```\n"
    let authority = TestConversationAuthority()

    func conversations(profile: ExactID) async throws -> ConversationDirectory { authority.directory(profile) }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw HermesServiceError.rejected(-32601) }

    var onEvent: ((BotServiceEvent) -> Void)?
    let bot = BotProfile(id: "cache-bot", name: "Cache")
    var chat = Conversation(id: "runtime", storedID: "stored", profileID: "cache-bot", messages: [.init(id: "m0", role: .assistant, text: text)])
    var downloads: [(ChatAttachment, Conversation)] = []
    var downloadGate: RichReplyFileGate?
    var downloadError: (any Error)?
    var downloadData = Data("<button>Native file preview</button>".utf8)
    var downloadWasCancelled = false
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        let conversation = try authority.resolve(access)
        downloads.append((attachment, conversation))
        if let downloadGate { await downloadGate.wait() }
        downloadWasCancelled = Task.isCancelled
        if let downloadError { throw downloadError }
        return .init(data: downloadData, filename: "report.html", mimeType: "text/html")
    }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo { .init(version: "test") }
    func disconnect() {}
    func bots() async throws -> [BotProfile] { [bot] }
    func createBot(_ draft: BotDraft) async throws -> BotProfile { bot }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        return try authority.opened(chat)
    }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment { throw HermesServiceError.disconnected }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
}

@MainActor final class RichReplyFileGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func entered() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

/// Observes the document actually mounted by the native preview, independently
/// of the direct-loader grants and the service's captured-byte count.
@MainActor enum MountedReplyFileDocument {
    private enum Stage: String {
        case mounting, rendering, recognizing

        func budget(observation: Duration) -> Duration {
            switch self {
            case .mounting: .seconds(30)
            case .rendering: .seconds(21)
            case .recognizing: observation
            }
        }
    }

    struct Observation {
        let words: String?
        let image: UIImage?
        let isCurrent: Bool
    }

    static func waitForText(_ expected: String, in root: UIView, excluding previous: WKWebView? = nil,
                            phase: String = "initial document", observationBudget: Duration = .seconds(15),
                            diagnostics: () -> String = { "" },
                            recognize: @escaping @MainActor (CGImage) async throws -> [String] = {
                                try await NativeTextRecognition.recognize($0, languages: ["en-US"])
                            }) async throws -> WKWebView {
        let start = ContinuousClock.now
        var stage = Stage.mounting
        var deadline = start + stage.budget(observation: observationBudget)
        var observation: Observation?
        var rendererStates: [String] = []
        while ContinuousClock.now < deadline {
            rendererStates = []
            for web in webViews(in: root) where web !== previous && web.window != nil && web.bounds.width > 0 && web.bounds.height > 0 {
                guard let renderer = web.navigationDelegate as? RichContentRenderer else { continue }
                if stage == .mounting {
                    stage = .rendering
                    // WebKit's own commit and document budgets begin after attachment.
                    deadline = .now + stage.budget(observation: observationBudget)
                }
                rendererStates.append("\(ObjectIdentifier(web)): \(renderer.state)")
                guard renderer.state == .ready else { continue }
                if stage == .rendering {
                    stage = .recognizing
                    deadline = .now + stage.budget(observation: observationBudget)
                }
                observation = await observe(web, in: root, deadline: deadline, recognize: recognize)
                guard let observation, ContinuousClock.now < deadline else { continue }
                if let words = observation.words, words.localizedStandardContains(expected) { return web }
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        let details = """
        phase=\(phase) stage=\(stage.rawValue) elapsed=\(start.duration(to: .now))
        renderers=\(rendererStates.joined(separator: " | ")) views=\(webViews(in: root).count) root=\(root.bounds) attached=\(root.window != nil)
        words=\(observation?.words ?? "<none>") current=\(observation?.isCurrent ?? false)
        \(diagnostics())
        """
        Attachment.record(details, named: "mounted-document-readiness.txt")
        if let image = observation?.image { Attachment.record(image, named: "mounted-document.png", as: .png) }
        if root.bounds.width > 0, root.bounds.height > 0 {
            let image = UIGraphicsImageRenderer(bounds: root.bounds).image { _ in
                root.drawHierarchy(in: root.bounds, afterScreenUpdates: false)
            }
            Attachment.record(image, named: "mounted-document-host.png", as: .png)
        }
        Issue.record("The actual mounted document did not render: \(expected) (\(phase), \(stage.rawValue))")
        throw DocumentFailure.notRendered
    }

    private static func observe(_ web: WKWebView, in root: UIView, deadline: ContinuousClock.Instant,
                                recognize: @escaping @MainActor (CGImage) async throws -> [String]) async -> Observation {
        guard let renderer = web.navigationDelegate as? RichContentRenderer, renderer.state == .ready else {
            return Observation(words: nil, image: nil, isCurrent: false)
        }
        let result = await renderedText(in: web, deadline: deadline, recognize: recognize)
        return Observation(words: result.words, image: result.image,
            isCurrent: renderer.webView === web && web.navigationDelegate === renderer && renderer.state == .ready &&
                web.window != nil && web.window === root.window && web.isDescendant(of: root) &&
                web.bounds.width > 0 && web.bounds.height > 0)
    }

    private static func webViews(in view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }

    private static func renderedText(in web: WKWebView, deadline: ContinuousClock.Instant,
                                     recognize: @escaping @MainActor (CGImage) async throws -> [String]) async -> (words: String?, image: UIImage?) {
        let image: UIImage? = await withCheckedContinuation { continuation in
            let pending = PendingSnapshot(continuation)
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                pending.finish(nil)
            }
            web.takeSnapshot(with: nil) { image, _ in
                timeout.cancel(); pending.finish(image)
            }
        }
        guard let pixels = image?.cgImage else { return (nil, image) }
        let words = await NativeRecognitionDeadline.run(until: deadline) { try await recognize(pixels) }
        return (words?.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " "), image)
    }

    private enum DocumentFailure: Error { case notRendered }
    private final class PendingSnapshot {
        private var continuation: CheckedContinuation<UIImage?, Never>?
        init(_ continuation: CheckedContinuation<UIImage?, Never>) { self.continuation = continuation }
        func finish(_ image: UIImage?) {
            continuation?.resume(returning: image); continuation = nil
        }
    }
}
