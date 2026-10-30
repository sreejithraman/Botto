import Foundation
import BottoCore
import SwiftUI

/// Swift String equality intentionally folds canonical Unicode variants. Render
/// identity instead follows the exact parser bytes, including the original fence.
struct ExactReplyBlock: Hashable, Sendable {
    let offset: Int
    let kind: String
    let source: Data
    let raw: Data
    let complete: Bool
    init(_ block: ReplyContent.Block) {
        offset = block.id
        switch block.kind {
        case .text: kind = "text"
        case .code(let language): kind = "code:" + (language ?? "")
        case .preview(let format): kind = "preview:" + format.rawValue
        case .filePreview: kind = "filePreview"
        }
        source = Data(block.source.utf8); raw = Data(block.rawText.utf8)
        complete = block.isComplete
    }
}

struct DiagramLayout: Hashable, Sendable {
    let dark: Bool
    let reduceMotion: Bool
    let width: CGFloat
    let viewportHeight: CGFloat?
    init?(dark: Bool, reduceMotion: Bool, width: CGFloat, viewportHeight: CGFloat?) {
        guard width.isFinite, width > 0,
              viewportHeight.map({ $0.isFinite && $0 > 0 }) ?? true else { return nil }
        self.dark = dark; self.reduceMotion = reduceMotion
        self.width = width; self.viewportHeight = viewportHeight
    }
}

enum RichReplyContext: Sendable {
    case isolated
    case chat(RichReplyMessage?)

    struct RequestIdentity: Hashable {
        fileprivate let scope: UUID?
        fileprivate let message: Data?
        fileprivate let allowed: Bool
        fileprivate let document: UUID?
    }
    @MainActor var requestIdentity: RequestIdentity {
        switch self {
        case .isolated: .init(scope: nil, message: nil, allowed: true, document: nil)
        case .chat(let message): .init(scope: message?.scope.id, message: message?.messageID,
                                      allowed: message?.scope.isCurrent == true && (message?.fileBinding?.grant.isCurrent ?? true),
                                      document: message?.fileBinding?.grant.id)
        }
    }
    struct FileRequestIdentity: Equatable {
        let authority: RequestIdentity
        let revision: Int
    }
    @MainActor var fileRequestIdentity: FileRequestIdentity {
        let revision: Int
        if case .chat(let message) = self { revision = message?.scope.fileRevision ?? 0 }
        else { revision = 0 }
        return .init(authority: requestIdentity, revision: revision)
    }
    @MainActor func permits(_ block: ReplyContent.Block) -> Bool {
        switch self {
        case .isolated: true
        case .chat(let message): message?.permits(block) == true
        }
    }
    @MainActor func lookup(_ block: ReplyContent.Block, layout: DiagramLayout) -> DiagramPresentation? {
        guard case .chat(let message) = self, let message else { return nil }
        return message.scope.lookup(block, messageID: message.messageID, layout: layout)
    }
    @MainActor func begin(_ block: ReplyContent.Block, layout: DiagramLayout?,
                          onRevoke: @escaping @MainActor () -> Void) -> DiagramAdmission {
        guard case .chat(let message) = self, let message, message.permits(block) else { return .denied }
        return message.scope.begin(message.fileBinding?.origin ?? block, messageID: message.messageID,
                                   layout: layout, onRevoke: onRevoke)
    }

    /// Download outside WebKit, then grant only these exact bytes the directive's lifetime.
    @MainActor func loadFile(_ block: ReplyContent.Block) async throws -> PendingReplyFile {
        guard case .chat(let message) = self, let message, message.fileBinding == nil,
              block.filePreview?.isHTML == true, message.permits(block) else {
            throw HermesServiceError.staleConversation
        }
        let task = Task { try await message.scope.downloadFile(block, messageID: message.messageID) }
        guard let ticket = message.scope.fileGrant(block, messageID: message.messageID, onRevoke: { task.cancel() }) else {
            task.cancel(); throw HermesServiceError.staleConversation
        }
        var transferred = false
        defer { if !transferred { ticket.cancel() } }
        let download = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        defer { if !transferred { download.finishInstallation() } }
        try Task.checkCancellation()
        guard !task.isCancelled, ticket.isCurrent else { throw HermesServiceError.staleConversation }
        guard let resolved = block.resolvingFile(download.artifact) else { throw ReplyFileFailure.invalidHTML }
        let binding = RichReplyMessage.FileBinding(origin: block, resolved: ExactReplyBlock(resolved), grant: ticket)
        transferred = true
        let content = ResolvedReplyFile(block: resolved, context: .chat(.init(scope: message.scope,
                                    messageID: message.messageID, fileBinding: binding)))
        return PendingReplyFile(resolved: content, download: download)
    }
}

struct ResolvedReplyFile {
    let block: ReplyContent.Block
    let context: RichReplyContext
}

/// Keep the operation reservation out of the model's long-lived presentation.
struct PendingReplyFile {
    let resolved: ResolvedReplyFile
    fileprivate let download: AppStore.ReplyFileDownload

    @MainActor func finishInstallation() { download.finishInstallation() }
}

private enum ReplyFileFailure: Error, LocalizedError {
    case invalidHTML
    var errorDescription: String? { "This preview needs a nonempty UTF-8 HTML file up to 128 KiB. You can still open the original file." }
}

struct RichReplyMessage: Sendable {
    fileprivate let scope: RichReplyPresentations
    fileprivate let messageID: Data
    fileprivate struct FileBinding: Sendable {
        let origin: ReplyContent.Block
        let resolved: ExactReplyBlock
        let grant: ReplyFileGrant
    }
    fileprivate let fileBinding: FileBinding?
    fileprivate init(scope: RichReplyPresentations, messageID: String) {
        self.scope = scope; self.messageID = Data(messageID.utf8); fileBinding = nil
    }
    fileprivate init(scope: RichReplyPresentations, messageID: Data, fileBinding: FileBinding) {
        self.scope = scope; self.messageID = messageID; self.fileBinding = fileBinding
    }
    @MainActor func permits(_ block: ReplyContent.Block) -> Bool {
        if let fileBinding {
            return fileBinding.grant.isCurrent && ExactReplyBlock(block) == fileBinding.resolved
                && scope.permits(ExactReplyBlock(fileBinding.origin), messageID: messageID)
        }
        return scope.permits(ExactReplyBlock(block), messageID: messageID)
    }
}

private struct RichReplyContextKey: EnvironmentKey {
    static let defaultValue: RichReplyContext = .isolated
}
extension EnvironmentValues {
    var richReplyContext: RichReplyContext {
        get { self[RichReplyContextKey.self] }
        set { self[RichReplyContextKey.self] = newValue }
    }
}

/// Authority and canonical text stay in AppStore. This module keeps only bounded
/// exact keys and successful passive presentations, never another chat history.
@MainActor @Observable final class RichReplyPresentations {
    let id = UUID()
    private(set) var retired = false
    private(set) var fileRevision = 0
    @ObservationIgnored private weak var owner: AppStore?
    @ObservationIgnored private let destination: AppStore.RichReplyDestination?
    @ObservationIgnored private var entries: [Key: DiagramPresentation] = [:]
    @ObservationIgnored private var held: [WeakPresentation] = []
    @ObservationIgnored private var work: [WeakTicket] = []
    @ObservationIgnored private var fileGrants: [WeakFileGrant] = []

    struct Key: Hashable {
        let messageID: Data
        let block: ExactReplyBlock
        let layout: DiagramLayout
    }
    private final class WeakPresentation {
        weak var value: DiagramPresentation?
        let key: Key
        init(_ value: DiagramPresentation, key: Key) { self.value = value; self.key = key }
    }
    private final class WeakTicket {
        weak var value: DiagramRenderTicket?
        init(_ value: DiagramRenderTicket) { self.value = value }
    }
    private final class WeakFileGrant {
        weak var value: ReplyFileGrant?
        init(_ value: ReplyFileGrant) { self.value = value }
    }
    init(owner: AppStore, destination: AppStore.RichReplyDestination) {
        self.owner = owner; self.destination = destination
        DiagramMemory.shared.register(self)
    }
    /// Each standalone renderer has a private scope. It cannot share by source.
    init() { owner = nil; destination = nil; DiagramMemory.shared.register(self) }
    var isCurrent: Bool {
        !retired && (destination.map { owner?.isCurrentRichReplyDestination($0) == true } ?? true)
    }
    func message(_ messageID: String) -> RichReplyContext {
        guard isCurrent, let destination,
              owner?.richReplyBlocks(messageID: Data(messageID.utf8), destination: destination) != nil else { return .chat(nil) }
        return .chat(RichReplyMessage(scope: self, messageID: messageID))
    }
    func permits(_ block: ExactReplyBlock, messageID: Data) -> Bool {
        guard isCurrent else { return false }
        guard let destination else { return true }
        return owner?.richReplyBlocks(messageID: messageID, destination: destination)?.contains(block) == true
    }
    func lookup(_ block: ReplyContent.Block, messageID: Data, layout: DiagramLayout) -> DiagramPresentation? {
        let key = Key(messageID: messageID, block: ExactReplyBlock(block), layout: layout)
        guard permits(key.block, messageID: messageID), let value = entries[key], value.isAvailable else { return nil }
        DiagramMemory.shared.touch(value)
        return value
    }
    func begin(_ block: ReplyContent.Block, messageID: Data, layout: DiagramLayout?,
               onRevoke: @escaping @MainActor () -> Void) -> DiagramAdmission {
        let exact = ExactReplyBlock(block)
        guard block.isComplete, block.previewFormat != nil || (block.filePreview?.isHTML == true && layout == nil),
              permits(exact, messageID: messageID) else { return .denied }
        if let layout, let result = lookup(block, messageID: messageID, layout: layout) {
            let activity = DiagramRenderTicket(scope: self, messageID: messageID, block: exact,
                                               layout: layout, reservesCapture: false, onRevoke: onRevoke)
            work.removeAll { $0.value == nil }; work.append(WeakTicket(activity))
            return .pixels(result, activity)
        }
        guard layout == nil || DiagramMemory.shared.canReserve() else { return .busy }
        let ticket = DiagramRenderTicket(scope: self, messageID: messageID, block: exact, layout: layout, onRevoke: onRevoke)
        work.removeAll { $0.value == nil }; work.append(WeakTicket(ticket))
        return .render(ticket)
    }
    func downloadFile(_ block: ReplyContent.Block, messageID: Data) async throws -> AppStore.ReplyFileDownload {
        guard let destination, let owner, permits(ExactReplyBlock(block), messageID: messageID) else {
            throw HermesServiceError.staleConversation
        }
        return try await owner.downloadReplyFile(block, messageID: messageID, destination: destination)
    }
    func fileGrant(_ block: ReplyContent.Block, messageID: Data,
                   onRevoke: @escaping @MainActor () -> Void) -> ReplyFileGrant? {
        let exact = ExactReplyBlock(block)
        guard block.filePreview?.isHTML == true, block.isComplete, permits(exact, messageID: messageID) else { return nil }
        let grant = ReplyFileGrant(scope: self, messageID: messageID, block: exact, onRevoke: onRevoke)
        fileGrants.removeAll { $0.value == nil }; fileGrants.append(WeakFileGrant(grant))
        return grant
    }
    func retain(_ presentation: DiagramPresentation, key: Key) {
        entries[key] = presentation
        held.removeAll { $0.value == nil }; held.append(WeakPresentation(presentation, key: key))
    }
    func evict(_ presentation: DiagramPresentation) {
        entries = entries.filter { $0.value !== presentation }
    }
    func reconcileCanonicalConversation() {
        held.removeAll { $0.value == nil }
        for item in held where !permits(item.key.block, messageID: item.key.messageID) {
            item.value?.revoke(); entries[item.key] = nil
        }
        work.removeAll { $0.value == nil }
        for item in work where item.value?.isCurrent == false { item.value?.cancelAndNotify() }
        fileGrants.removeAll { $0.value == nil }
        var revokedFile = false
        for item in fileGrants where item.value?.isCurrent == false {
            if item.value?.cancelAndNotify() == true { revokedFile = true }
        }
        if revokedFile { fileRevision += 1 }
    }
    func retire() {
        retired = true
        let grants = fileGrants.compactMap(\.value)
        fileGrants = []
        for grant in grants { _ = grant.cancelAndNotify() }
        revokeContents()
    }
    func revokeContents() {
        for item in held { item.value?.revoke() }
        entries = [:]; held = []
        let current = work.compactMap(\.value)
        work = []
        for ticket in current { ticket.cancelAndNotify() }
    }
}

/// File authority follows canonical conversation ownership. Memory pressure may
/// retire renderers, but it must not invalidate unchanged downloaded HTML.
@MainActor final class ReplyFileGrant {
    let id = UUID()
    private let scope: RichReplyPresentations
    private let messageID: Data
    private let block: ExactReplyBlock
    private let onRevoke: @MainActor () -> Void
    private var cancelled = false

    init(scope: RichReplyPresentations, messageID: Data, block: ExactReplyBlock,
         onRevoke: @escaping @MainActor () -> Void) {
        self.scope = scope; self.messageID = messageID; self.block = block; self.onRevoke = onRevoke
    }
    var isCurrent: Bool { !cancelled && scope.permits(block, messageID: messageID) }
    func cancel() { cancelled = true }
    func cancelAndNotify() -> Bool {
        guard !cancelled else { return false }
        cancel(); onRevoke()
        return true
    }
}
