import SwiftUI
import BottoCore

/// Owns dimensions outside the generation-keyed renderer, within one message.
/// Replacing render authority must still destroy all of the content below it.
struct ReplyBodyLayoutOwner<Content: View>: View {
    let message: ChatMessage
    let acceptsWrites: @MainActor @Sendable () -> Bool
    @ViewBuilder var content: () -> Content
    var providedHistory: ReplyBodyMeasurements? = nil
    @State private var localHistory = ReplyBodyMeasurements()
    private var history: ReplyBodyMeasurements { providedHistory ?? localHistory }

    private var directives: [ReplyBodyDirective] {
        guard message.role == .assistant else { return [] }
        return ReplyContent(message: message).blocks.compactMap { block in
            guard block.filePreview?.isHTML == true else { return nil }
            return .init(message: Data(message.id.utf8), offset: block.id, raw: Data(block.rawText.utf8))
        }
    }

    var body: some View {
        content()
            .environment(\.replyBodyLayout, ReplyBodyLayoutAccess(history: history, acceptsWrites: acceptsWrites))
            .onChange(of: directives, initial: true) { _, current in
                guard acceptsWrites() else { return }
                history.retainOnly(current)
            }
    }
}

struct ReplyBodyDirective: Equatable, Sendable {
    let message: Data
    let offset: Int
    let raw: Data
}

/// Deliberately excludes completeness, render generation and grant identity.
struct ReplyBodyIdentity: Equatable, Sendable {
    let directive: ReplyBodyDirective
    let dynamicType: DynamicTypeSize
    let direction: LayoutDirection
    let colorScheme: ColorScheme
    let reduceMotion: Bool
}

struct ReplyBodyMeasurement: Equatable, Sendable {
    let identity: ReplyBodyIdentity
    let size: CGSize

    func matches(_ identity: ReplyBodyIdentity, width: CGFloat) -> Bool {
        self.identity == identity && abs(size.width - width) < 0.001
    }
}

/// At most one current source/layout/width measurement at each directive offset.
/// No document, renderer, download or grant can be stored here.
@MainActor @Observable final class ReplyBodyMeasurements {
    private var entries: [Int: ReplyBodyMeasurement] = [:]

    func measurement(for identity: ReplyBodyIdentity) -> ReplyBodyMeasurement? {
        guard let entry = entries[identity.directive.offset], entry.identity == identity else { return nil }
        return entry
    }

    func observe(_ identity: ReplyBodyIdentity, size: CGSize, rendered: Bool) {
        // Quiet optional previews can be empty. Their width still invalidates
        // a reservation, even though zero is not a rendered measurement.
        guard size.width.isFinite, size.width > 0, size.height.isFinite, size.height >= 0 else { return }
        let offset = identity.directive.offset
        let previous = entries[offset]
        let next: ReplyBodyMeasurement?
        if rendered && size.height > 0 { next = .init(identity: identity, size: size) }
        else if previous?.matches(identity, width: size.width) == true { next = previous }
        else { next = nil }
        if previous != next { entries[offset] = next }
    }

    func retainOnly(_ directives: [ReplyBodyDirective]) {
        let retained = entries.filter { _, entry in directives.contains(entry.identity.directive) }
        if retained != entries { entries = retained }
    }
}

struct ReplyBodyLayoutAccess: Sendable {
    let history: ReplyBodyMeasurements
    let acceptsWrites: @MainActor @Sendable () -> Bool

    @MainActor func measurement(for identity: ReplyBodyIdentity) -> ReplyBodyMeasurement? {
        history.measurement(for: identity)
    }

    @MainActor @discardableResult
    func observe(_ identity: ReplyBodyIdentity, size: CGSize, rendered: Bool) -> Bool {
        guard acceptsWrites() else { return false }
        history.observe(identity, size: size, rendered: rendered)
        return true
    }
}

private struct ReplyBodyLayoutKey: EnvironmentKey {
    static let defaultValue: ReplyBodyLayoutAccess? = nil
}
extension EnvironmentValues {
    var replyBodyLayout: ReplyBodyLayoutAccess? {
        get { self[ReplyBodyLayoutKey.self] }
        set { self[ReplyBodyLayoutKey.self] = newValue }
    }
}

/// Text remains native. Only complete, explicitly labelled assistant fences
/// cross into the isolated renderer; file references keep their place in prose.
struct AssistantReplyBody: View {
    let message: ChatMessage
    let isStreaming: Bool
    var filePreviewsAreSettled = true
    var onOpenAttachment: ((ChatAttachment) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(ReplyContent(message: message, isStreaming: isStreaming,
                                 filePreviewsAreSettled: filePreviewsAreSettled).blocks) { block in
                NativeTranscriptBlock(block: block.id) {
                switch block.kind {
                case .text:
                    paragraph(block.source)
                case .code:
                    ScrollView(.horizontal) {
                        Text(block.source)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(12)
                    }
                    .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Code: \(block.source)")
                case .preview:
                    RichReplyBlockView(block: block)
                case .filePreview(let reference):
                    if reference.isHTML {
                        ReplyFilePreview(messageID: message.id, block: block, reference: reference,
                                         onOpenAttachment: onOpenAttachment)
                    } else {
                        ArtifactCard(attachment: reference.attachment,
                                     open: onOpenAttachment.map { action in { action(reference.attachment) } })
                    }
                }
                }
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        let parts = ArtifactReferences.segments(in: text)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(parts.indices, id: \.self) { index in
                switch parts[index] {
                case .text(let source):
                    if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownBody(text: source, isReply: true)
                    }
                case .attachment(let attachment):
                    ArtifactCard(attachment: attachment,
                                 open: onOpenAttachment.map { action in { action(attachment) } })
                }
            }
        }
    }
}

/// Native download state surrounds the same isolated renderer used by HTML fences.
private struct ReplyFilePreview: View {
    let messageID: String
    let block: ReplyContent.Block
    let reference: PreviewFileReference
    var onOpenAttachment: ((ChatAttachment) -> Void)?
    @Environment(\.richReplyContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.layoutDirection) private var direction
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.replyBodyLayout) private var providedBodyLayout
    @Environment(\.nativeTranscriptBlock) private var nativeExposure
    @State private var model = ReplyFilePreviewModel()
    @State private var attempt = 0
    @State private var retryRequest: Request?
    // Standalone callers keep their existing same-mount behavior. The message
    // owner, when supplied, is the only history used by transcript children.
    @State private var localBodyLayouts = ReplyBodyMeasurements()

    private struct Request: Equatable {
        let block: ExactReplyBlock
        let authority: RichReplyContext.FileRequestIdentity
        let attempt: Int
        let exposed: Bool
    }

    private struct BodyObservation: Equatable, Sendable {
        let identity: ReplyBodyIdentity
        let size: CGSize
        let rendered: Bool
    }
    private var bodyIdentity: ReplyBodyIdentity {
        .init(directive: .init(message: Data(messageID.utf8), offset: block.id, raw: Data(block.rawText.utf8)),
              dynamicType: dynamicType, direction: direction, colorScheme: colorScheme, reduceMotion: reduceMotion)
    }

    /// Match the actual proposal before reserving height, including the first
    /// layout after a width change. Sizing never publishes state or forces layout.
    private struct BodyLayout: Layout {
        let identity: ReplyBodyIdentity
        let measurement: ReplyBodyMeasurement?
        let rendered: Bool

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let body = subviews.first else { return .zero }
            let natural = body.sizeThatFits(proposal)
            let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? natural.width
            let reserved = !rendered && measurement?.matches(identity, width: width) == true
                ? measurement?.size.height ?? 0 : 0
            return CGSize(width: width, height: max(natural.height, reserved))
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
        }
    }

    var body: some View {
        let identity = bodyIdentity
        let rendered = model.resolved(for: block, context: context) != nil
        let history = providedBodyLayout ?? ReplyBodyLayoutAccess(history: localBodyLayouts, acceptsWrites: { true })
        let measurement = history.measurement(for: identity)
        let request = Request(block: ExactReplyBlock(block), authority: context.fileRequestIdentity, attempt: attempt,
                              exposed: nativeExposure?.isVisible ?? true)
        VStack(alignment: .leading, spacing: 8) {
            BodyLayout(identity: identity, measurement: measurement, rendered: rendered) {
                // One layout child, including the existing error + Retry pair.
                VStack(alignment: .leading, spacing: 8) { previewBody }
            }
            .onGeometryChange(for: BodyObservation.self) { [identity, rendered] geometry in
                BodyObservation(identity: identity, size: geometry.size, rendered: rendered)
            } action: { observation in
                // Old render generations cannot overwrite or clear dimensions
                // already observed by their replacement. Recheck actual content
                // permission before publishing a rendered measurement.
                let accepted = history.observe(observation.identity, size: observation.size,
                    rendered: observation.rendered && model.resolved(for: block, context: context) != nil)
                _ = accepted
            }
            ArtifactCard(attachment: reference.attachment,
                         open: onOpenAttachment.map { action in { action(reference.attachment) } })
        }
        .task(id: request) {
            let isRetry = request == retryRequest
            retryRequest = nil
            guard request.exposed, nativeExposure?.isVisible ?? true else { model.suspend(); return }
            await model.load(block, context: context, isRetry: isRetry)
        }
        .onDisappear { retryRequest = nil; model.cancel() }
    }

    @ViewBuilder private var previewBody: some View {
        if let resolved = model.resolved(for: block, context: context) {
            RichReplyBlockView(block: resolved.block, initialHeight: reference.initialHeight.map(CGFloat.init))
                .environment(\.richReplyContext, resolved.context)
        } else if block.isComplete, context.permits(block) {
            switch model.feedback {
            case .quiet:
                EmptyView()
            case .loading:
                ProgressView("Loading preview…")
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if model.canRetry {
                Button("Try Again") {
                    guard nativeExposure?.isVisible ?? true else { return }
                    attempt += 1
                    retryRequest = Request(block: ExactReplyBlock(block), authority: context.fileRequestIdentity,
                                           attempt: attempt, exposed: true)
                }
            }
        }
    }

}

@MainActor @Observable final class ReplyFilePreviewModel {
    enum Feedback: Equatable { case quiet, loading, failed(String) }
    private struct Input: Equatable {
        let block: ExactReplyBlock
        let authority: RichReplyContext.RequestIdentity
    }
    private var input: Input?
    private var result: ResolvedReplyFile?
    private(set) var feedback: Feedback = .quiet
    private var generation = UUID()
    private var loadedAuthority: RichReplyContext.FileRequestIdentity?
    private var isSuspended = false

    /// Installed bytes remain cached when authority retires. Rendering must use
    /// the accessor below to validate both the directive and its file grant.
    var resolved: ResolvedReplyFile? { result }
    func resolved(for block: ReplyContent.Block, context: RichReplyContext) -> ResolvedReplyFile? {
        guard input == Input(block: ExactReplyBlock(block), authority: context.requestIdentity),
              context.permits(block), let result,
              result.context.permits(result.block) else { return nil }
        return result
    }

    var errorMessage: String? {
        if case .failed(let message) = feedback { message } else { nil }
    }
    var canRetry: Bool { errorMessage != nil }

    func load(_ block: ReplyContent.Block, context: RichReplyContext, isRetry: Bool = false) async {
        guard !Task.isCancelled else { return }
        let next = Input(block: ExactReplyBlock(block), authority: context.requestIdentity)
        let authority = context.fileRequestIdentity
        // Returning from native coverage reuses only the exact current file and
        // live grant. A direct load still supports a deliberate background refresh.
        let reuse = isSuspended && !isRetry && loadedAuthority == authority
            && resolved(for: block, context: context) != nil
        // Leaving and returning to a failed block is not a retry action.
        let preserveFailure = isSuspended && !isRetry && input == next && canRetry
            && context.permits(block)
        isSuspended = false
        if reuse || preserveFailure { return }
        // Reuse successful bytes only for the same exact directive and live
        // authority. A revoked file grant never becomes valid again.
        if input != next || resolved(for: block, context: context) == nil {
            result = nil; loadedAuthority = nil
        }
        generation = UUID()
        guard block.isComplete, context.permits(block) else { cancel(); return }
        input = next
        let owner = generation
        feedback = isRetry ? .loading : .quiet
        defer {
            if owner == generation, case .loading = feedback { feedback = .quiet }
        }
        do {
            let result = try await context.loadFile(block)
            defer { result.finishInstallation() }
            guard owner == generation, !Task.isCancelled, context.permits(block) else { return }
            loadedAuthority = authority
            self.result = result.resolved
        } catch {
            guard owner == generation, !Task.isCancelled, context.permits(block) else { return }
            feedback = .failed(error.localizedDescription)
        }
    }
    // Exposure gates pending work and inline execution, not installed bytes or
    // an already-admitted foreground Source/expanded session's separate lifetime.
    func suspend() {
        generation = UUID(); isSuspended = true
        if case .loading = feedback { feedback = .quiet }
    }
    func cancel() {
        generation = UUID(); input = nil; result = nil; feedback = .quiet
        loadedAuthority = nil; isSuspended = false
    }
}
