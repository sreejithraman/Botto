import SwiftUI
import UIKit
import BottoCore

struct MessageView: View {
    let message: ChatMessage
    var isStreaming = false
    var rendersRichContent = true
    var filePreviewsAreSettled = true
    var senderProfile: BotProfile?
    var senderImage: UIImage?
    var onOpenAttachment: ((ChatAttachment) -> Void)?
    private let rawRevision: Data?
    private var outgoing: Bool { message.isOutgoingUserMessage }

    init(message: ChatMessage, isStreaming: Bool = false, rendersRichContent: Bool = true, filePreviewsAreSettled: Bool = true,
         senderProfile: BotProfile? = nil, senderImage: UIImage? = nil,
         onOpenAttachment: ((ChatAttachment) -> Void)? = nil) {
        self.message = message; self.isStreaming = isStreaming; self.rendersRichContent = rendersRichContent
        self.filePreviewsAreSettled = filePreviewsAreSettled
        self.senderProfile = senderProfile; self.senderImage = senderImage
        self.onOpenAttachment = onOpenAttachment
        rawRevision = message.notificationPresentation == nil ? nil : Data(message.text.utf8)
    }

    var body: some View {
        if !message.isVisible {
            EmptyView()
        } else if let notification = message.notificationPresentation {
            WorkDetailsRow(title: notification.title, systemImage: notification.systemImage,
                accessibilityLabel: message.scheduledJobName.map { "Show details for scheduled check, \($0)" } ?? "Show details for \(notification.title)",
                identifier: (message.scheduledJobName == nil ? "notification-details-" : "scheduled-details-") + message.id,
                messages: [message])
        } else if let sender = message.botSender {
            incomingBotMessage(sender)
        } else if message.role == .system && isImportantSystemNote {
            Label {
                SearchMatchText(message.text).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(.subheadline).foregroundStyle(BottoTheme.error)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if message.role == .tool || message.role == .system {
            WorkDetailsRow(title: message.toolName ?? "Work details",
                systemImage: message.role == .tool ? "wrench.and.screwdriver" : "info.circle",
                identifier: "message-details-" + message.id, messages: [message])
        } else {
            let presentation = AttachmentPresentation.display(message)
            HStack(alignment: .top, spacing: 0) {
                if outgoing { Spacer(minLength: 35) }
                VStack(alignment: .leading, spacing: 10) {
                    if !presentation.text.isEmpty {
                        if outgoing { SearchMatchText(presentation.text).textSelection(.enabled) }
                        else if !rendersRichContent { MarkdownBody(text: presentation.text) }
                        else { AssistantReplyBody(message: message, isStreaming: isStreaming,
                                                  filePreviewsAreSettled: filePreviewsAreSettled,
                                                  onOpenAttachment: onOpenAttachment) }
                    }
                    ForEach(presentation.attachments) { attachment in
                        ArtifactCard(attachment: attachment, outgoing: outgoing,
                                     open: onOpenAttachment.map { action in { action(attachment) } })
                    }
                }
                .font(.body).lineSpacing(outgoing ? 3 : 4)
                .padding(.horizontal, outgoing ? 16 : 0)
                .padding(.vertical, outgoing ? 13 : 6)
                .foregroundStyle(outgoing ? BottoTheme.onOutgoing : BottoTheme.ink)
                .background {
                    if outgoing { RoundedRectangle(cornerRadius: 23).fill(BottoTheme.outgoing) }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
        }
    }

    // These app-authored notes report failed or uncertain work and must stay visible.
    private var isImportantSystemNote: Bool {
        ["error:", "outcome:", "uncertain:"].contains { message.id.hasPrefix($0) }
    }

    private func incomingBotMessage(_ sender: ChatMessage.MessageSender) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ChatSenderAvatar(sender: sender, profile: senderProfile, image: senderImage)
            VStack(alignment: .leading, spacing: 7) {
                Text("\(sender.name) · @\(sender.handle)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityLabel(sender.label)
                    .accessibilityIdentifier("message-sender-" + message.id)
                SearchMatchText(message.attributedText).font(.body).lineSpacing(3).textSelection(.enabled)
                ForEach(message.attachments) { attachment in
                    ArtifactCard(attachment: attachment, outgoing: false,
                        open: onOpenAttachment.map { action in { action(attachment) } })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .foregroundStyle(BottoTheme.ink)
            .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row and reader treatment for tools, background work, and routine chat notes.
struct WorkDetailsRow: View {
    let title: String
    let systemImage: String
    let count: Int?
    let accessibilityLabel: String?
    let identifier: String
    let messages: [ChatMessage]
    let canOpen: Bool
    let isCurrent: @MainActor () -> Bool
    private let displayRevision: [NativeTranscriptRowValue]
    @Environment(\.nativeTranscriptRow) private var nativeRow
    @Environment(\.reportChatModal) private var reportModal
    @Environment(\.scenePhase) private var scenePhase
    @State private var standalone: StandaloneDetails?
    @State private var reportedID: UUID?

    private struct StandaloneDetails: Identifiable {
        let id = UUID()
        let document: WorkDetailsDocument
        let admitsRead: @MainActor () -> Bool
    }

    init(title: String, systemImage: String, count: Int? = nil, accessibilityLabel: String? = nil,
         identifier: String, messages: [ChatMessage], canOpen: Bool = true,
         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.title = title; self.systemImage = systemImage; self.count = count
        self.accessibilityLabel = accessibilityLabel; self.identifier = identifier
        self.messages = messages; self.canOpen = canOpen; self.isCurrent = isCurrent
        displayRevision = messages.map { .message($0, working: false) }
    }

    private var canPresent: Bool {
        scenePhase == .active && isCurrent() && (nativeRow.map { $0.canPresent } ?? canOpen)
    }

    var body: some View {
        Button {
            guard canPresent else { return }
            let document = WorkDetailsDocument(title: title, messages: messages)
            if let nativeRow {
                nativeRow.present(details: document, report: reportModal)
            } else {
                let session = StandaloneDetails(document: document, admitsRead: isCurrent)
                standalone = session; reportedID = session.id
                reportModal(session.id, true)
            }
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let count { Text("\(count)").monospacedDigit() }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(BottoTheme.ink)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(minHeight: 44).contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel ?? title)
            .accessibilityIdentifier(identifier)
        }
        .buttonStyle(.plain)
        .disabled(!canPresent)
        .sheet(item: $standalone, onDismiss: closeStandalone) { session in
            WorkDetailsSheet(document: session.document,
                isCurrent: { standalone?.id == session.id && session.admitsRead() && scenePhase == .active },
                close: closeStandalone)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .hapticSheet(enabled: standalone?.id == session.id && session.admitsRead() && scenePhase == .active)
        }
        .onChange(of: displayRevision) { _, _ in closeStandalone() }
        .onChange(of: isCurrent()) { _, current in if !current { closeStandalone() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { closeStandalone() } }
        .onDisappear { closeStandalone() }
    }

    private func closeStandalone() {
        standalone = nil
        if let id = reportedID { reportedID = nil; reportModal(id, false) }
    }
}

struct WorkDetailsSheet: View {
    let document: WorkDetailsDocument
    let isCurrent: @MainActor () -> Bool
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(document.messages.enumerated()), id: \.offset) { index, message in
                        let entryTitle = message.toolName ?? message.notificationPresentation?.title ?? message.botSender?.label
                        VStack(alignment: .leading, spacing: 12) {
                            if document.messages.count > 1 || entryTitle.map({ $0 != document.title }) == true {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if document.messages.count > 1 {
                                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    Text(entryTitle ?? "Work details").fontWeight(.semibold)
                                }.font(.subheadline)
                            }
                            RawMessagePayload(text: message.text, isCurrent: isCurrent,
                                copyIdentifier: "work-details-copy-" + message.id)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if index + 1 < document.messages.count { Divider() }
                    }
                }
                .padding(20)
            }
            .background(BottoTheme.paper)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(BottoTheme.action)
        .accessibilityAction(.escape) { close() }
        .onChange(of: isCurrent()) { _, current in if !current { close() } }
    }
}

struct RawMessagePayload: View {
    let text: String
    private let revision: Data
    let isCurrent: @MainActor () -> Bool
    let copyIdentifier: String

    init(text: String, revision: Data? = nil, isCurrent: @escaping @MainActor () -> Bool = { false },
         copyIdentifier: String = "work-details-copy") {
        self.text = text; self.revision = revision ?? Data(text.utf8)
        self.isCurrent = isCurrent; self.copyIdentifier = copyIdentifier
    }
    @State private var copied = false
    @State private var loadedSections: [PreparedSection]?

    private nonisolated struct PreparedSection: Sendable {
        let title: String?
        let markdown: String?
        let parts: [String]
    }

    private nonisolated static func prepare(_ text: String) -> [PreparedSection] {
        HermesDetailPayload.sections(text).map { section in
            let markdown = section.format == .markdown && section.text.utf8.count < 32_768
            return PreparedSection(title: section.title, markdown: markdown ? section.text : nil,
                                   parts: markdown ? [] : sections(section.text))
        }
    }

    /// Keep native Text below its layout limits without changing the copyable payload.
    nonisolated static func sections(_ text: String) -> [String] {
        var remaining = text[...]
        var result: [String] = []
        while !remaining.isEmpty {
            let limit = remaining.index(remaining.startIndex, offsetBy: 512, limitedBy: remaining.endIndex) ?? remaining.endIndex
            let boundary = remaining[..<limit].lastIndex(of: "\n").map { remaining.index(after: $0) } ?? limit
            result.append(String(remaining[..<boundary]))
            remaining = remaining[boundary...]
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                guard isCurrent() else { return }
                UIPasteboard.general.string = text; copied = true
                BottoHaptics.shared.play(.accepted)
            } label: {
                Label(copied ? "Copied" : "Copy original", systemImage: "doc.on.doc")
                    .accessibilityIdentifier(copyIdentifier)
            }
            .disabled(!isCurrent())
            .font(.caption).frame(minHeight: 44)
            .accessibilityIdentifier(copyIdentifier)

            if let loadedSections {
                ForEach(Array(loadedSections.enumerated()), id: \.offset) { index, section in
                    VStack(alignment: .leading, spacing: 8) {
                        if let title = section.title {
                            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        if let markdown = section.markdown {
                            MarkdownBody(text: markdown)
                                .accessibilityIdentifier("work-details-section-\(index)")
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(section.parts.enumerated()), id: \.offset) { part, text in
                                    Text(text.hasSuffix("\n") ? String(text.dropLast()) : text)
                                        .font(.system(.callout, design: .monospaced))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityIdentifier("work-details-section-\(index)-part-\(part)")
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView("Loading details")
            }
        }
        .task(id: revision) {
            loadedSections = nil; copied = false
            let sections = await Task.detached(priority: .userInitiated) { Self.prepare(text) }.value
            guard !Task.isCancelled else { return }
            loadedSections = sections
        }
    }
}

/// Contiguous prose shares one selection; fenced code keeps its spacing.
struct MarkdownBody: View {
    let text: String
    var isReply = false
    private var blocks: [NativeMessageText.MarkdownBlock] { NativeMessageText.markdownBlocks(in: text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(blocks) { block in
                if block.code {
                    ScrollView(.horizontal) {
                        SearchMatchText(block.text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                            .padding(12)
                    }
                    .background(isReply ? BottoTheme.surface : BottoTheme.paper, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Code: \(block.text)")
                } else {
                    SearchMatchText(attributed(block.text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    func attributed(_ text: String) -> AttributedString {
        NativeMessageText.markdownAttributed(text, isReply: isReply)
    }
}
