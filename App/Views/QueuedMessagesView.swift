import SwiftUI
import BottoCore

struct QueuedMessagesView: View {
    let workspace: ConversationWorkspace
    let screen: ChatScreen?
    let inputAvailable: Bool
    let canAttemptSave: Bool
    let requireConnection: () -> Bool
    @State private var isExpanded = false
    @State private var showsAll = false
    @State private var expandedMessages: Set<String> = []
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 88

    private var messages: [QueuedMessage] { screen?.snapshot?.queuedMessages ?? [] }
    private var visible: [QueuedMessage] { showsAll ? messages : Array(messages.prefix(2)) }
    private var containsOnlyBackgroundEvents: Bool { !messages.isEmpty && messages.allSatisfy { $0.sourceMessage != nil } }

    var body: some View {
        Group {
            if let screen, let edit = screen.queuedEdit {
                QueuedMessageEditorView(workspace: workspace, screen: screen, edit: edit,
                                        inputAvailable: inputAvailable, canAttemptSave: canAttemptSave, requireConnection: requireConnection)
                    .id(edit.id)
            } else if let screen, containsOnlyBackgroundEvents {
                WorkDetailsRow(title: "Pending updates", systemImage: "bell", count: messages.count,
                    accessibilityLabel: messages.count == 1 ? "1 queued background event" : "\(messages.count) queued background events",
                    identifier: "queued-messages-toggle", messages: messages.compactMap(\.sourceMessage),
                    canOpen: inputAvailable, isCurrent: {
                        queuedSnapshot(screen)?.queuedMessages.count == messages.count &&
                            messages.allSatisfy { queuedDetailsAreCurrent($0, screen: screen) }
                    })
                    .padding(.horizontal, 14)
            } else if let screen, !messages.isEmpty {
                VStack(spacing: 0) {
                    Button { isExpanded.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: containsOnlyBackgroundEvents ? "bell.badge" : "text.badge.plus")
                            Text("\(containsOnlyBackgroundEvents ? "Updates" : "Queued") · \(messages.count)").monospacedDigit()
                            Spacer()
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(containsOnlyBackgroundEvents
                        ? (messages.count == 1 ? "1 queued background event" : "\(messages.count) queued background events")
                        : (messages.count == 1 ? "1 queued message" : "\(messages.count) queued messages"))
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint("Double tap to \(isExpanded ? "hide" : "show") queued messages.")
                    .accessibilityIdentifier("queued-messages-toggle")

                    if isExpanded {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(visible.enumerated()), id: \.element.id) { index, message in
                                    let source = message.sourceMessage
                                    let summary = source?.botSender?.label ?? source?.notificationPresentation?.title
                                    let expanded = expandedMessages.contains(message.id)
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(index + 1)")
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .padding(.top, 14).frame(width: 16)
                                        if let summary, let source {
                                            WorkDetailsRow(title: summary,
                                                systemImage: source.botSender != nil ? "bubble.left.and.bubble.right" : source.notificationPresentation?.systemImage ?? "bell",
                                                accessibilityLabel: "Queued background event \(index + 1): \(summary)",
                                                identifier: "queued-message-\(index + 1)",
                                                messages: [source], canOpen: inputAvailable,
                                                isCurrent: { queuedDetailsAreCurrent(message, screen: screen) })
                                        } else {
                                            Button {
                                                if expanded { expandedMessages.remove(message.id) }
                                                else { expandedMessages.insert(message.id) }
                                            } label: {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(message.text).font(.subheadline)
                                                        .lineLimit(expanded ? nil : 2)
                                                        .multilineTextAlignment(.leading)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                    Text(message.isSteering ? "Joining the current reply" : expanded ? "Show less" : "Tap to expand")
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                }
                                                .padding(.vertical, 10).frame(minHeight: 44)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel("Queued message \(index + 1): \(message.text)")
                                            .accessibilityIdentifier("queued-message-\(index + 1)")
                                        }
                                        if message.canEdit && !message.isSteering && source == nil {
                                            Button { workspace.beginQueuedEdit(message, owner: screen.owner) } label: {
                                                Image(systemName: "pencil").frame(width: 44, height: 44)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(!inputAvailable || !screen.canEditDraft)
                                            .accessibilityLabel("Edit queued message \(index + 1)")
                                            .accessibilityIdentifier("edit-queued-message-\(index + 1)")
                                        }
                                    }
                                    if index < visible.count - 1 { Divider() }
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                        .frame(height: min(rowHeight * CGFloat(visible.count) + CGFloat(expandedMessages.count) * rowHeight, 260))
                        .scrollBounceBehavior(.basedOnSize)
                        .accessibilityIdentifier("queued-messages-list")
                        if messages.count > 2 {
                            Button(showsAll ? "Show fewer messages" : "Show all \(messages.count) messages") { showsAll.toggle() }
                                .font(.caption).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 14)
                        }
                    }
                }
                .background {
                    if isExpanded { RoundedRectangle(cornerRadius: 18).fill(BottoTheme.surface) }
                    else { Capsule().fill(BottoTheme.surface) }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .onChange(of: screen?.selectedChatID) { _, _ in
            isExpanded = false; showsAll = false; expandedMessages = []
        }
        .onChange(of: messages.isEmpty) { _, empty in
            if empty { isExpanded = false; showsAll = false; expandedMessages = [] }
        }
        .onChange(of: screen?.queuedEdit?.id) { old, new in
            if old != nil && new == nil { isExpanded = false }
        }
    }

    private func queuedDetailsAreCurrent(_ message: QueuedMessage, screen: ChatScreen) -> Bool {
        guard let snapshot = queuedSnapshot(screen) else { return false }
        let matches = snapshot.queuedMessages.filter { $0.id.utf8.elementsEqual(message.id.utf8) }
        guard matches.count == 1, let current = matches.first else { return false }
        return current.sourceMessage != nil && current.text.utf8.elementsEqual(message.text.utf8) &&
            current.canEdit == message.canEdit && current.isSteering == message.isSteering &&
            current.submissionID.map { Data($0.utf8) } == message.submissionID.map { Data($0.utf8) }
    }

    private func queuedSnapshot(_ screen: ChatScreen) -> Conversation? {
        guard workspace.isCurrent(screen.owner),
              let profileID = screen.snapshot?.profileID, let profile = try? ExactID(profileID) else { return nil }
        return workspace.selection(profile: profile)?.snapshot
    }
}

private struct QueuedMessageEditorView: View {
    let workspace: ConversationWorkspace
    let screen: ChatScreen
    let edit: QueuedMessageEdit
    let inputAvailable: Bool
    let canAttemptSave: Bool
    let requireConnection: () -> Bool
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var editorHeight: CGFloat = 140
    private let maximumEditorHeight: CGFloat = 240

    private var text: Binding<String> {
        Binding(get: { workspace.queuedEditText(screen.owner, id: edit.id) ?? edit.text }, set: { workspace.updateQueuedEdit($0, owner: screen.owner) })
    }
    private var isStillInQueue: Bool {
        screen.snapshot?.queuedMessages.contains {
            $0.id.utf8.elementsEqual(edit.message.id.utf8)
        } == true
    }
    private var isStillEditable: Bool { screen.canReplaceQueuedEdit }
    private var canKeepDraft: Bool { !isStillEditable || edit.isUncertain || edit.error != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(isStillEditable ? "Edit queued message" : (isStillInQueue ? "Queue changed" : "Message has left the queue"))
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: text)
                    .font(.body).focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .frame(height: min(editorHeight, maximumEditorHeight)).padding(8)
                    .background(BottoTheme.paper, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(!inputAvailable || !screen.canEditDraft || edit.isSaving)
                    .accessibilityLabel("Queued message text")
                    .accessibilityIdentifier("queued-message-editor")
                if let error = edit.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("queued-message-edit-error")
                }
                Text(isStillEditable ? "Saving moves this message to the end of the queue." :
                        "Your edits are still here. Keep them as a new draft; nothing will be sent automatically.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("queued-message-edit-status")
            }
            .padding(14)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("queued-message-edit-scroll")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .trailing, spacing: 4) { actions }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .frame(maxHeight: maximumEditorHeight)
        .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .onAppear { isFocused = true }
        .onChange(of: isStillEditable) { wasEditable, editable in
            if wasEditable && !editable {
                AccessibilityNotification.Announcement(isStillInQueue ? "The queue changed. Your edits are still here." :
                    "This message has left the queue. Your edits are still here.").post()
            }
        }
        .onChange(of: edit.error) { _, error in
            if error != nil { AccessibilityNotification.Announcement("Couldn’t save this edit. Your text is still here.").post() }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Cancel") { workspace.cancelQueuedEdit(screen.owner) }
            .disabled(edit.isSaving || !inputAvailable).frame(minHeight: 44)
        if canKeepDraft {
            Button("Keep as draft") { workspace.keepQueuedEditAsDraft(screen.owner) }
                .disabled(edit.isSaving || !inputAvailable || !screen.canEditDraft).frame(minHeight: 44)
                .accessibilityIdentifier("keep-queued-edit-as-draft")
        }
        if isStillEditable || edit.isSaving {
            Button(edit.isSaving ? "Saving…" : "Save changes") {
                guard requireConnection() else { return }
                let workspace = workspace, owner = screen.owner
                Task { await workspace.saveQueuedEdit(owner) }
            }
            .fontWeight(.semibold).frame(minHeight: 44)
            .disabled(!canAttemptSave || !screen.canSaveQueuedEdit || edit.isSaving)
            .accessibilityIdentifier("save-queued-message")
        }
    }
}
