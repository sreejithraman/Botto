import Foundation
import Testing
import BottoCore
import SwiftUI
import UIKit
@testable import Botto

@MainActor @Suite(.serialized, RichReplyRuntime()) struct AppStoreRichReplyTests {
    @Test(arguments: ["working", "canonical"])
    func mountedFilePreviewReloadsWhenRevocationAndRestorationArriveBeforeViewUpdate(event: String) async throws {
        let service = RichReplyTestService()
        service.chat.messages[0].text = "::preview{file='report.html'}"
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://mounted-preview.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration)); await store.open(service.bot)
        let context = store.richReplyContext(for: service.bot.id, messageID: "m0")
        let view = ScrollView {
            AssistantReplyBody(message: service.chat.messages[0], isStreaming: false)
                .environment(\.richReplyContext, context)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var deadline = ContinuousClock.now + .seconds(5)
        while service.downloads.count < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(service.downloads.count == 1)
        // Let the successful bytes publish, then coalesce both canonical events.
        try await Task.sleep(for: .milliseconds(50))
        let original = service.chat.messages[0].text
        if event == "working" { service.chat.isWorking = true }
        else { service.chat.messages[0].text = "Replaced" }
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        service.chat.isWorking = false; service.chat.messages[0].text = original
        service.onEvent?(.conversation(try service.authority.opened(service.chat)))
        deadline = ContinuousClock.now + .seconds(5)
        while service.downloads.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(service.downloads.count == 2, "A revoked document must receive a fresh authorized load")
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
    func filePreviewReloadRetainsOnlyTheSameAuthorizedSuccess(event: String) async throws {
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
        let gate = RichReplyFileGate()
        service.downloadGate = gate
        service.downloadError = HermesServiceError.disconnected
        let reload = Task { await model.load(block, context: reloadContext) }
        await gate.entered()
        #expect((model.resolved(for: block, context: reloadContext) != nil) == (event == "unchanged"))
        gate.release()
        await reload.value
        #expect((model.resolved(for: block, context: reloadContext) != nil) == (event == "unchanged"))
        if event == "unchanged" {
            #expect(model.resolved?.context.requestIdentity == original.context.requestIdentity,
                    "A failed background reload keeps the existing authorized document")
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
