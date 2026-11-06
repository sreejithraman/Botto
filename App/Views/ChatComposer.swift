import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import BottoCore

struct ChatComposer: View {
    let store: AppStore
    let bot: BotProfile
    let workspace: ConversationWorkspace
    let screen: ChatScreen?
    let inputAvailable: Bool
    let importsAllowed: Bool
    let importPresentationRevision: UUID
    let editingRevision: UUID
    let onPickerPresentation: (Bool) -> Void
    let canContinueEditing: () -> Bool
    let editingHandle: ComposerEditingHandle
    @Binding var connectionRequested: Bool
    @State private var showsFiles = false
    @State private var showsPhotos = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    private struct AttachmentImport: Equatable {
        let id = UUID()
        let destination: ImportIntent
        let owner: PresentationOwner
        let workspace: ConversationWorkspace

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }
    @State private var filePicker: AttachmentImport?
    @State private var photoPicker: AttachmentImport?
    @State private var runningImport: AttachmentImport?
    @State private var importTask: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum AttachmentNotice {
        case failure(String)
        case pasteGuidance(String)
        case interrupted

        var message: String {
            switch self {
            case .failure(let message), .pasteGuidance(let message): message
            case .interrupted: "Attachment import stopped. Check the attached files before sending."
            }
        }
        var survivesOwnerChange: Bool {
            if case .interrupted = self { true } else { false }
        }
    }
    @State private var attachmentError: AttachmentNotice?
    @State private var stopping: UUID?

    private var draft: Binding<String> {
        let owner = screen?.owner
        let workspace = workspace
        return Binding(get: { owner.map { workspace.draft($0) } ?? "" }, set: { text in
            guard let owner else { return }
            workspace.editDraft(text, owner: owner)
        })
    }
    private var photoSelection: Binding<[PhotosPickerItem]> {
        let picker = photoPicker
        return Binding(get: { selectedPhotos }, set: { photos in
            guard let picker, importsAllowed, photoPicker == picker else { return }
            selectedPhotos = photos
        })
    }
    private var photoRoom: Int { max(AttachmentLimits.count - (screen?.attachments.count ?? 0), 1) }
    private var working: Bool { screen?.snapshot?.isWorking == true }
    private var hasContent: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(screen?.attachments.isEmpty ?? true)
    }
    private var offersStop: Bool { working && (!hasContent || sending || uploading || screen?.needsReattachment == true) }
    private var canStop: Bool { working && canCompose && stopping == nil }
    private var canSteer: Bool { canSend && screen?.attachments.isEmpty == true }
    private var defaultDelivery: MessageDelivery { working && canSteer ? .steer : .queue }
    private var actionEnabled: Bool { offersStop ? canStop : canSend && stopping == nil }
    private var actionSymbol: String {
        if offersStop || stopping != nil { return "stop.fill" }
        if working { return defaultDelivery == .steer ? "arrow.turn.up.right" : "text.badge.plus" }
        return "arrow.up"
    }
    private var actionLabel: String {
        if stopping != nil { return "Stopping…" }
        if offersStop { return "Stop response" }
        if working { return defaultDelivery == .steer ? "Steer message" : "Queue message" }
        return "Send message"
    }
    private var sending: Bool { screen?.isSending == true }
    private var uploading: Bool { runningImport != nil || screen?.isUploading == true }
    private var canCompose: Bool { inputAvailable && screen.map(store.canCompose) == true }
    private var canSend: Bool {
        canCompose && screen?.needsReattachment != true && !sending && !uploading &&
        hasContent
    }
    var body: some View {
        VStack(spacing: 10) {
            if let error = attachmentError {
                InlineNotice(message: error.message) { attachmentError = nil }.padding(.horizontal, 16)
            }
            if screen?.needsReattachment == true {
                Text("Attach these files again before sending.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            if let screen, !screen.attachments.isEmpty || !screen.pendingAttachments.isEmpty {
                HStack(spacing: 4) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(screen.attachments) { attachment in
                                StagedAttachmentTile(name: attachment.name, isImage: attachment.mimeType.hasPrefix("image/"),
                                                     thumbnail: workspace.thumbnails.image(for: attachment), removable: !sending) {
                                    workspace.removeAttachment(attachment, owner: screen.owner)
                                }
                            }
                            ForEach(screen.pendingAttachments) { pending in
                                StagedAttachmentTile(name: pending.name, isImage: pending.isImage, thumbnail: pending.preview,
                                                     pending: pending.phase, removable: true) {
                                    workspace.cancelPendingAttachment(pending.id, owner: screen.owner)
                                }
                            }
                        }.padding(.horizontal, 16)
                    }.scrollIndicators(.hidden)
                    if screen.pendingAttachments.count > 1, runningImport != nil {
                        Button("Cancel All") { cancelAttachmentImport(showNotice: true) }
                            .font(.caption).frame(minWidth: 44, minHeight: 44).padding(.trailing, 12).contentShape(Rectangle())
                            .accessibilityIdentifier("composer-cancel-attachment")
                    }
                }
            }
            QueuedMessagesView(workspace: workspace, screen: screen, inputAvailable: inputAvailable,
                               canAttemptSave: canCompose, requireConnection: requireConnection)
                .frame(maxWidth: 780).padding(.horizontal, 16)
            if sending {
                Text("Sending…").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("Photo library", systemImage: "photo") {
                        guard canCompose, requireConnection() else { return }
                        editingHandle.cancel()
                        guard let screen, let destination = workspace.captureImport(screen.owner) else { return }
                        photoPicker = AttachmentImport(destination: destination, owner: screen.owner, workspace: workspace)
                        selectedPhotos = []
                        showsPhotos = true
                    }
                    Button("Choose a file", systemImage: "doc") {
                        guard canCompose, requireConnection() else { return }
                        editingHandle.cancel()
                        guard let screen, let destination = workspace.captureImport(screen.owner) else { return }
                        filePicker = AttachmentImport(destination: destination, owner: screen.owner, workspace: workspace)
                        showsFiles = true
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 20)).frame(width: 48, height: 48)
                        .controlGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer-add-attachment")
                .accessibilityLabel("Add attachment").disabled(!canCompose || uploading || sending)
                HStack(alignment: .bottom, spacing: 8) {
                    NativeComposerEditor(text: draft,
                        identity: screen.map { .init(owner: $0.owner, viewLifetime: $0.selectedViewLifetime, revision: editingRevision) },
                        enabled: inputAvailable && screen?.canEditDraft == true,
                        placeholder: "Message \(bot.name)", accessibilityLabel: "Message to \(bot.name)",
                        editing: editingHandle, canEdit: {
                            guard canContinueEditing(), let screen else { return false }
                            return workspace.canEditDraft(screen.owner)
                        }, pasteAttachments: pasteAttachments, admitAttachmentPaste: admitAttachmentPaste)
                    Button {
                        if offersStop { stop() } else { send(defaultDelivery) }
                    } label: {
                        Image(systemName: actionSymbol)
                            .font(.system(size: offersStop ? 14 : 17, weight: .semibold))
                            .foregroundStyle(actionEnabled ? BottoTheme.onAction : BottoTheme.disabledForeground)
                            .frame(width: 44, height: 44)
                            .background(actionEnabled ? BottoTheme.action : .clear, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).disabled(!actionEnabled)
                    .accessibilityLabel(actionLabel)
                    .accessibilityIdentifier("chat-send-button")
                    .accessibilityHint(working ? "Touch and hold for message options." : "")
                    .contextMenu {
                        if working {
                            Button("Steer", systemImage: "arrow.turn.up.right") { send(.steer) }
                                .disabled(!canSteer || stopping != nil)
                            Button("Queue", systemImage: "text.badge.plus") { send(.queue) }
                                .disabled(!canSend || stopping != nil)
                            Button("Stop response", systemImage: "stop.fill") { stop() }
                                .disabled(!canStop)
                        }
                    }
                    .padding(3)
                }
                .controlGlass(in: RoundedRectangle(cornerRadius: 26))
            }
            .composerGlassGroup()
            .padding(.horizontal, 12).padding(.bottom, 8)
            .frame(maxWidth: 780)
        }
        .frame(maxWidth: .infinity)
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: { [picker = filePicker] result in
            guard let picker, importsAllowed, filePicker == picker,
                  picker.workspace.isCurrent(picker.owner) else { return }
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else {
                    picker.workspace.cancelImport(picker.destination); filePicker = nil; return
                }
                filePicker = nil
                start(picker, reading: urls.map(AttachmentSource.file))
            case .failure(let error):
                picker.workspace.cancelImport(picker.destination)
                filePicker = nil
                if !(error is CancellationError) { attachmentError = .failure(error.localizedDescription) }
            }
        }, onCancellation: { [picker = filePicker] in
            guard let picker else { return }
            picker.workspace.cancelImport(picker.destination)
            if filePicker == picker { filePicker = nil }
        })
        .photosPicker(isPresented: $showsPhotos, selection: photoSelection, maxSelectionCount: photoRoom, matching: .images)
        .onChange(of: selectedPhotos) { _, photos in
            guard !photos.isEmpty, let picker = photoPicker else { return }
            photoPicker = nil
            start(picker, reading: photos.map(AttachmentSource.photo))
        }
        .onChange(of: showsFiles || showsPhotos) { _, shown in onPickerPresentation(shown) }
        .onChange(of: importPresentationRevision) { _, _ in cancelAttachmentImport(showNotice: true) }
        .onChange(of: screen?.owner) { previous, next in
            stopping = nil
            if attachmentError?.survivesOwnerChange != true { attachmentError = nil }
            cancelAttachmentImport(showNotice: previous != nil && previous?.chat == next?.chat)
        }
        .onChange(of: ObjectIdentifier(workspace)) { _, _ in cancelAttachmentImport() }
        .onChange(of: importsAllowed) { _, available in
            if !available { cancelAttachmentImport(showNotice: true) }
        }
        .onChange(of: store.isConnected) { _, connected in
            if connected { clearPasteGuidance() }
        }
        .onChange(of: canCompose && !sending && !uploading) { _, available in
            if available { clearPasteGuidance() }
        }
        .onChange(of: showsPhotos) { _, shown in
            if !shown, selectedPhotos.isEmpty, let picker = photoPicker {
                picker.workspace.cancelImport(picker.destination); photoPicker = nil
            }
        }
    }

    private func send(_ delivery: MessageDelivery) {
        #if DEBUG
        editingHandle.editor?.markSend()
        #endif
        editingHandle.commit()
        guard canSend, stopping == nil, requireConnection() else { return }
        guard let screen, let intent = workspace.captureSend(screen.owner, delivery: delivery) else { return }
        let workspace = workspace
        Task { await workspace.send(intent) }
    }

    private func stop() {
        guard canStop, requireConnection() else { return }
        guard let screen, let intent = workspace.captureStop(screen.owner) else { return }
        let workspace = workspace
        let operation = UUID()
        stopping = operation
        Task {
            await workspace.stop(intent)
            if stopping == operation { stopping = nil }
        }
    }

    private func requireConnection() -> Bool {
        guard inputAvailable, let screen, workspace.isCurrent(screen.owner) else { return false }
        guard store.isConnected else { connectionRequested = true; return false }
        return screen.canAct
    }

    private func cancelAttachmentImport(showNotice: Bool = false) {
        let interrupted = runningImport.map { $0.workspace === workspace && $0.owner.chat == screen?.owner.chat } == true
        importTask?.cancel(); importTask = nil
        if let runningImport { runningImport.workspace.cancelImport(runningImport.destination) }
        if let filePicker { filePicker.workspace.cancelImport(filePicker.destination) }
        if let photoPicker { photoPicker.workspace.cancelImport(photoPicker.destination) }
        filePicker = nil; photoPicker = nil; runningImport = nil
        if showNotice {
            if interrupted { attachmentError = .interrupted }
        } else { attachmentError = nil }
        selectedPhotos = []
        showsFiles = false; showsPhotos = false
    }

    private func start(_ attachmentImport: AttachmentImport, reading inputs: [AttachmentInput]) {
        guard !uploading, importsAllowed, attachmentImport.workspace.isCurrent(attachmentImport.owner) else {
            attachmentImport.workspace.cancelImport(attachmentImport.destination); return
        }
        runningImport = attachmentImport; attachmentError = nil
        importTask = Task { @MainActor in
            await attachmentImport.workspace.importAttachments(inputs, to: attachmentImport.destination)
            if runningImport == attachmentImport { runningImport = nil; importTask = nil; selectedPhotos = [] }
        }
    }

    private func pasteAttachments(owner: PresentationOwner, items: [PastedAttachment]) {
        guard let destination = workspace.captureImport(owner) else { return }
        start(AttachmentImport(destination: destination, owner: owner, workspace: workspace),
              reading: items.map(AttachmentSource.pasted))
    }

    private func admitAttachmentPaste(owner: PresentationOwner) -> Bool {
        guard importsAllowed, inputAvailable, workspace.isCurrent(owner) else { return false }
        guard store.isConnected else {
            connectionRequested = true
            attachmentError = .pasteGuidance("Connect to the bot, then paste again.")
            return false
        }
        guard canCompose else {
            attachmentError = .pasteGuidance(screen?.isOpening == true ? "The chat is opening. Paste again when it’s ready." :
                "The chat isn’t ready for attachments. Reopen it, then paste again.")
            return false
        }
        guard !sending, !uploading else {
            attachmentError = .pasteGuidance(sending ? "Wait for the message to send, then paste again." : "Wait for the current attachment to finish.")
            return false
        }
        return true
    }

    private func clearPasteGuidance() {
        if case .pasteGuidance? = attachmentError { attachmentError = nil }
    }
}

extension View {
    @ViewBuilder func controlGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder fileprivate func composerGlassGroup() -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 8) { self }
        } else {
            self
        }
    }
}
