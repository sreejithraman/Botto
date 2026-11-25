import AppKit
import BottoCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Composer

/// One composer for the new-space page and open spaces: attach, a quiet model chip, and one Send/Stop button.
struct MacComposer<Accessory: View, ModelMenu: View>: View {
    @Binding var draft: String
    let placeholder: String
    let modelLabel: String
    let isWorking: Bool
    let isBusy: Bool
    let hasAttachments: Bool
    let canStop: Bool
    /// The new-space page can send a name with no message.
    var allowsEmpty = false
    /// Bump to move typing here, such as after naming a space.
    var focusRequests = 0
    let onAttach: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var modelMenu: ModelMenu
    @FocusState private var focused: Bool

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Send turns into Stop while Botto works and there's nothing new to send.
    private var showsStop: Bool { isWorking && !hasText && !hasAttachments }
    private var canSend: Bool { (hasText || hasAttachments || allowsEmpty) && !isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            accessory
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 6)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Button(action: onAttach) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(MacTheme.paper, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Attach files")
                .accessibilityLabel("Attach files")
                Menu { modelMenu } label: {
                    HStack(spacing: 3) {
                        Text(modelLabel).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Model for this space")
                .accessibilityLabel("Model, \(modelLabel)")
                Spacer()
                if showsStop {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(MacTheme.outgoing, in: .circle)
                            .foregroundStyle(MacTheme.onOutgoing)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStop)
                    .help("Stop (⌘.)")
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Group {
                            if isBusy { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)) }
                        }
                        .frame(width: 32, height: 32)
                        .background(canSend ? MacTheme.action : MacTheme.surfaceDeep, in: .circle)
                        .foregroundStyle(canSend ? MacTheme.onAction : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .help("Send (⌘↩)")
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(10)
        .background(MacTheme.surface, in: .rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(focused ? MacTheme.action.opacity(0.35) : .clear, lineWidth: 1.5)
        }
        .background {
            // ⌘. stops Botto whether or not the button shows Stop.
            Button("Stop", action: onStop).keyboardShortcut(".", modifiers: .command)
                .disabled(!isWorking || !canStop).hidden()
        }
        .animation(.easeOut(duration: 0.15), value: focused)
        .onAppear { focused = true }
        .onChange(of: focusRequests) { _, _ in focused = true }
    }

    private func send() {
        guard canSend else { return }
        onSend()
    }
}

@MainActor enum MacFilePicker {
    static func pick(message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.message = message
        return panel.runModal() == .OK ? panel.urls : []
    }
}

// MARK: - Space

struct MacChatPane: View {
    let store: MacBottoStore
    let opened: OpenedConversation
    @Binding var draft: String
    let onPreview: (MacPreviewItem) -> Void
    @State private var followsLatest = true
    @State private var dropTargeted = false
    private let transcriptEnd = "transcript-end"

    private var botName: String { store.bot?.name ?? "Botto" }
    private var chat: T3ChannelSummary? { store.selectedChannel }
    private var isArchived: Bool { chat?.isArchived == true }
    private var activity: MacAvatarActivity {
        MacAvatarActivity(status: opened.snapshot.isWorking ? .working : .idle, phase: opened.activity?.phase,
                          needsResponse: !opened.snapshot.pendingRequests.isEmpty)
    }

    var body: some View {
        let messages = opened.snapshot.messages.filter { $0.isSilent != true }
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(messages) { message in
                            MacTranscriptMessage(message: message) { attachment in
                                onPreview(.attachment(attachment, store: store))
                            }
                        }
                        ForEach(opened.snapshot.pendingRequests) { request in
                            MacRuntimeRequestCard(request: request, store: store)
                        }
                        ForEach(opened.snapshot.queuedMessages) { message in
                            HStack {
                                Spacer(minLength: 80)
                                Label(message.text, systemImage: "clock")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .overlay {
                                        Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                            .foregroundStyle(.tertiary)
                                    }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Queued: \(message.text)")
                        }
                        if let cue = activity.cue, activity.isBusy {
                            MacWorkingLine(text: "\(botName) is \(cue)")
                        }
                        Color.clear.frame(height: 1).id(transcriptEnd)
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 80
                } action: { _, nearEnd in
                    followsLatest = nearEnd
                }
                .onChange(of: opened.snapshot) { _, _ in
                    if followsLatest { proxy.scrollTo(transcriptEnd, anchor: .bottom) }
                }
            }
            composer
        }
        .overlay { if dropTargeted { dropOverlay } }
        .dropDestination(for: URL.self) { urls, _ in
            guard !isArchived else { return false }
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            attach(files)
            return true
        } isTargeted: { dropTargeted = $0 && !isArchived }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { store.showsInspector.toggle() } label: {
                MacBotAvatarView(profileID: store.bot?.id ?? "main", appearance: store.bot?.appearance, activity: activity)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help("Botto (⌘I)")
            .accessibilityLabel("Open Botto")
            VStack(alignment: .leading, spacing: 1) {
                Text(chat?.displayTitle ?? "Space")
                    .font(MacTheme.rounded(.headline, weight: .bold))
                    .lineLimit(1)
                if let cue = activity.cue {
                    Text(cue)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MacTheme.action)
                        .contentTransition(.opacity)
                } else if isArchived {
                    Text("archived").font(.caption).foregroundStyle(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: activity)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(MacTheme.paper)
        .accessibilityElement(children: .contain)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 22)
            .strokeBorder(MacTheme.action, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(MacTheme.selection.opacity(0.55), in: .rect(cornerRadius: 22))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 34))
                    Text("Drop to share with \(botName)").font(MacTheme.rounded(.title3, weight: .semibold))
                }
                .foregroundStyle(MacTheme.action)
            }
            .padding(14)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    @ViewBuilder
    private var composer: some View {
        Group {
            if isArchived {
                HStack {
                    Label("This space is archived.", systemImage: "archivebox").foregroundStyle(.secondary)
                    Spacer()
                    Button("Unarchive") {
                        guard let id = chat?.id else { return }
                        Task { await store.archiveChannel(threadID: id, archived: false) }
                    }
                    .buttonStyle(MacPillButtonStyle(prominent: false))
                }
                .font(.callout)
                .padding(14)
                .background(MacTheme.surface, in: .rect(cornerRadius: 20))
            } else {
                MacComposer(draft: $draft, placeholder: "Reply to \(botName)", modelLabel: store.modelLabel(for: chat),
                            isWorking: opened.snapshot.isWorking, isBusy: store.isSending || store.isUploading,
                            hasAttachments: !store.stagedAttachments.isEmpty, canStop: !store.isStopping,
                            onAttach: { attach(MacFilePicker.pick(message: "Choose files to share with \(botName).")) },
                            onSend: send, onStop: stop) {
                    if !store.stagedAttachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(store.stagedAttachments) { item in
                                    MacStagedAttachmentPill(item: item) { store.removeStagedAttachment(item.id) }
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                } modelMenu: {
                    ForEach(store.models) { option in
                        Button {
                            Task { await store.setChannelModel(option) }
                        } label: {
                            if option.modelID == chat?.model { Label(option.label, systemImage: "checkmark") }
                            else { Text(option.label) }
                        }
                    }
                    if store.models.isEmpty { Text("No other models on this Mac") }
                }
            }
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 32)
        .padding(.top, 4)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(MacTheme.paper)
    }

    private func send() {
        let submitted = draft
        Task {
            guard store.openedConversation?.access == opened.access else { return }
            if await store.send(text: submitted), draft == submitted { draft = "" }
        }
    }

    private func stop() {
        Task {
            guard store.openedConversation?.access == opened.access else { return }
            await store.stop()
        }
    }

    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            guard store.openedConversation?.access == opened.access else { return }
            await store.attach(urls)
        }
    }
}

/// A shimmering line while Botto works, so the face and this line say it without status pills.
struct MacWorkingLine: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0.5 : (timeline.date.timeIntervalSinceReferenceDate / 2.2)
                .truncatingRemainder(dividingBy: 1)
            Text(text)
                .font(.callout)
                .foregroundStyle(LinearGradient(stops: [
                    .init(color: .secondary.opacity(0.55), location: max(0, phase - 0.3)),
                    .init(color: .primary, location: phase),
                    .init(color: .secondary.opacity(0.55), location: min(1, phase + 0.3)),
                ], startPoint: .leading, endPoint: .trailing))
        }
        .accessibilityLabel(text)
    }
}

// MARK: - Transcript

/// Botto speaks in plain text with no bubble or repeated face; only your messages are bubbles.
struct MacTranscriptMessage: View {
    let message: ChatMessage
    let onOpen: (ChatAttachment) -> Void

    var body: some View {
        switch message.role {
        case .tool, .system:
            MacToolCard(message: message)
        case .user:
            HStack {
                Spacer(minLength: 90)
                VStack(alignment: .trailing, spacing: 6) {
                    attachments(alignment: .trailing)
                    if !text.isEmpty {
                        MacMarkdownView(text: text, style: .outgoing)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(MacTheme.outgoing, in: UnevenRoundedRectangle(
                                topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20))
                    }
                }
            }
            .help(timestamp)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                MacMarkdownView(text: text, style: .editorial)
                attachments(alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(timestamp)
        }
    }

    private var text: String { message.displayText ?? message.text }

    private var timestamp: String {
        message.timestamp?.formatted(date: .abbreviated, time: .shortened) ?? ""
    }

    /// Files read as a miniature of the page itself, not a filename tile.
    @ViewBuilder
    private func attachments(alignment: HorizontalAlignment) -> some View {
        if !message.attachments.isEmpty {
            VStack(alignment: alignment, spacing: 6) {
                ForEach(message.attachments) { attachment in
                    let kind = MacFileKind(name: attachment.name, mimeType: attachment.mimeType)
                    Button { onOpen(attachment) } label: {
                        HStack(spacing: 12) {
                            MacPageThumbnail(kind: kind).frame(width: 44, height: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(attachment.name)).font(.body.weight(.semibold)).lineLimit(1)
                                Text(detail(attachment, kind: kind)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxWidth: 320, alignment: .leading)
                        .background(MacTheme.surface, in: .rect(cornerRadius: 16))
                        .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(attachment.name)")
                }
            }
        }
    }

    private func title(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    private func detail(_ attachment: ChatAttachment, kind: MacFileKind) -> String {
        let size = attachment.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [kind.label, size, "click to open"].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Runtime requests

/// Approvals and questions read as an ordinary message with clear buttons, on warm peach.
struct MacRuntimeRequestCard: View {
    let request: PendingRequest
    let store: MacBottoStore
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).font(.body.weight(.semibold))
            if !request.detail.isEmpty {
                MacMarkdownView(text: request.detail, style: .editorial)
                    .font(.callout)
            }
            if !request.choices.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack { choices }
                    VStack(alignment: .leading) { choices }
                }
            }
            if request.kind == .question && request.choices.isEmpty {
                TextField("Your answer", text: $answer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(9)
                    .background(MacTheme.paper.opacity(0.75), in: .rect(cornerRadius: 12))
                    .onSubmit { respond(.text(answer)) }
                Button("Answer") { respond(.text(answer)) }
                    .buttonStyle(MacPillButtonStyle())
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(15)
        .frame(maxWidth: 520, alignment: .leading)
        .background(MacTheme.selection, in: .rect(cornerRadius: 20))
        .disabled(store.respondingRequestIDs.contains(request.id))
        .accessibilityElement(children: .contain)
    }

    /// The first choice is the go-ahead; the rest sit beside it, quieter.
    private var choices: some View {
        ForEach(Array(request.choices.enumerated()), id: \.element.id) { index, choice in
            Button(choice.label) { respond(.choice(choice.id)) }
                .buttonStyle(MacPillButtonStyle(prominent: index == 0))
        }
    }

    private func respond(_ response: RequestResponse) {
        Task { await store.respond(to: request, response: response) }
    }
}

struct MacStagedAttachmentPill: View {
    let item: MacStagedAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                switch item.state {
                case .uploading: ProgressView().controlSize(.mini)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MacTheme.error)
                case .ready: Image(systemName: MacAttachmentKind.symbol(for: item.mimeType)).foregroundStyle(MacTheme.action)
                }
            }
            .frame(width: 26, height: 26)
            .background(MacTheme.paper, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption2).foregroundStyle(failed ? MacTheme.error : .secondary).lineLimit(1)
            }
            .frame(maxWidth: 170, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(item.name)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(MacTheme.surface, in: .rect(cornerRadius: 12))
        .help(failedMessage ?? item.name)
        .accessibilityElement(children: .contain)
    }

    private var failed: Bool { failedMessage != nil }
    private var failedMessage: String? {
        if case .failed(let message) = item.state { message } else { nil }
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)
        switch item.state {
        case .uploading: return "Uploading · \(size)"
        case .failed: return "Upload failed"
        case .ready: return size
        }
    }
}

struct MacToolCard: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MacTheme.action)
                        .frame(width: 22, height: 22)
                        .background(MacTheme.selection, in: .rect(cornerRadius: 7))
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if !summary.isEmpty, !expanded {
                        Text(summary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) details")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                ScrollView([.vertical, .horizontal]) {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(MacTheme.paper, in: .rect(cornerRadius: 9))
                .padding([.horizontal, .bottom], 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(MacTheme.surface.opacity(0.7), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(MacTheme.hairline) }
        .clipShape(.rect(cornerRadius: 12))
    }

    private var detail: String { message.displayText ?? message.text }

    private var title: String {
        message.toolName ?? (message.role == .tool ? "Tool" : "System note")
    }

    private var summary: String {
        detail.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? ""
    }

    private var symbol: String {
        guard message.role == .tool else { return "info.circle" }
        let name = (message.toolName ?? "").lowercased()
        if ["bash", "shell", "terminal", "exec", "command", "run"].contains(where: name.contains) { return "terminal" }
        if ["search", "grep", "find", "glob"].contains(where: name.contains) { return "magnifyingglass" }
        if ["web", "fetch", "http", "browse", "url"].contains(where: name.contains) { return "globe" }
        if ["edit", "write", "patch", "apply"].contains(where: name.contains) { return "pencil" }
        if ["read", "file", "open", "view"].contains(where: name.contains) { return "doc.text" }
        if ["todo", "plan", "task"].contains(where: name.contains) { return "checklist" }
        return "wrench.and.screwdriver"
    }
}

