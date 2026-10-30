import Foundation
import Testing
import BottoCore
#if os(iOS)
import SwiftUI
import UIKit
import WebKit
import Vision
#endif
#if RICH_CONTENT_STANDALONE
@testable import RichContentHarness
#else
@testable import Botto
#endif

@MainActor @Suite(.serialized, RichReplyRuntime()) struct AppStoreRichReplyTests {
    #if os(iOS)
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
        if event == "working" { service.chat.isWorking = true }
        else { service.chat.messages[0].text = "Replaced" }
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        service.chat.isWorking = false; service.chat.messages[0].text = original
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        #expect(!originalFile.context.permits(originalFile.block), "Restoring source must not revive the original file grant")
        let recovered = try await MountedReplyFileDocument.waitForText("Native file preview", in: host.view, excluding: mounted)
        #expect(recovered !== mounted && mounted.superview == nil,
                "The mounted preview must replace its revoked document, not just reauthorize a direct loader")
        let replacement = try await context.loadFile(block)
        defer { replacement.finishInstallation() }
        #expect(replacement.resolved.context.permits(replacement.resolved.block))
        #expect(replacement.resolved.block.source == originalFile.block.source)
        #expect(service.downloads.count == 1, "Fresh authority can install the same captured bytes without another host fetch")
    }
    #endif
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
    var downloadWasCancelled = false
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        let conversation = try authority.resolve(access)
        downloads.append((attachment, conversation))
        if let downloadGate { await downloadGate.wait() }
        downloadWasCancelled = Task.isCancelled
        if let downloadError { throw downloadError }
        return .init(data: Data("<button>Native file preview</button>".utf8), filename: "report.html", mimeType: "text/html")
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

#if os(iOS)
/// Observes the document actually mounted by the native preview, independently
/// of the direct-loader grants and the service's captured-byte count.
@MainActor enum MountedReplyFileDocument {
    static func waitForText(_ expected: String, in root: UIView, excluding previous: WKWebView? = nil) async throws -> WKWebView {
        let deadline = ContinuousClock.now + .seconds(10)
        var observed: (words: String?, image: UIImage?)?
        while ContinuousClock.now < deadline {
            for web in webViews(in: root) where web !== previous && web.window != nil && web.bounds.width > 0 && web.bounds.height > 0 {
                observed = await renderedText(in: web)
                if let words = observed?.words, words.localizedStandardContains(expected) { return web }
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        let diagnostic = FileManager.default.temporaryDirectory.appendingPathComponent("botto-mounted-\(UUID().uuidString).png")
        if let image = observed?.image?.pngData() { try? image.write(to: diagnostic) }
        print("BOTTO_MOUNTED_DOCUMENT stage=\(previous == nil ? "initial" : "replacement") views=\(webViews(in: root).count) root=\(root.bounds) words=\(observed?.words ?? "<none>") image=\(diagnostic.path)")
        Issue.record("The actual mounted document did not render: \(expected)")
        throw DocumentFailure.notRendered
    }

    private static func webViews(in view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }

    private static func renderedText(in web: WKWebView) async -> (words: String?, image: UIImage?) {
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
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: pixels).perform([request])
            let words = request.results?.compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return (words, image)
        } catch { return (nil, image) }
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
#endif
