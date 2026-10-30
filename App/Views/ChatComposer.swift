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
    @State private var selectedPhoto: PhotosPickerItem?
    private struct AttachmentPicker: Equatable {
        let id = UUID()
        let destination: ImportIntent
        let owner: PresentationOwner
        let workspace: ConversationWorkspace

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }
    @State private var filePicker: AttachmentPicker?
    @State private var photoPicker: AttachmentPicker?
    @State private var fileTask: Task<Void, Never>?
    @State private var attachmentReadID: UUID?
    @State private var photoTask: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var attachmentError: String?
    @State private var stopping: UUID?

    private var draft: Binding<String> {
        let owner = screen?.owner
        let workspace = workspace
        return Binding(get: { owner.map { workspace.draft($0) } ?? "" }, set: { text in
            guard let owner else { return }
            workspace.editDraft(text, owner: owner)
        })
    }
    private var photoSelection: Binding<PhotosPickerItem?> {
        let picker = photoPicker
        return Binding(get: { selectedPhoto }, set: { photo in
            guard let picker, importsAllowed, photoPicker == picker else { return }
            selectedPhoto = photo
        })
    }
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
    private var uploading: Bool { attachmentReadID != nil || screen?.isUploading == true }
    private var canCompose: Bool {
        inputAvailable && screen?.canEditDraft == true &&
        (screen?.canAct == true || !store.isConnected)
    }
    private var canSend: Bool {
        canCompose && screen?.needsReattachment != true && !sending && !uploading &&
        hasContent
    }
    var body: some View {
        VStack(spacing: 10) {
            if let error = attachmentError {
                InlineNotice(message: error) { attachmentError = nil }.padding(.horizontal, 16)
            }
            if screen?.needsReattachment == true {
                Text("Attach these files again before sending.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            if let screen, !screen.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(screen.attachments) { attachment in
                            HStack(spacing: 8) {
                                Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                                Text(attachment.name).font(.caption).lineLimit(1)
                                Button { workspace.removeAttachment(attachment, owner: screen.owner) } label: {
                                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 44, height: 44)
                                }.buttonStyle(.plain).accessibilityLabel("Remove \(attachment.name)")
                                    .disabled(sending)
                            }
                            .padding(.leading, 12).background(BottoTheme.surface, in: Capsule())
                        }
                    }.padding(.horizontal, 16)
                }.scrollIndicators(.hidden)
            }
            QueuedMessagesView(workspace: workspace, screen: screen, inputAvailable: inputAvailable,
                               canAttemptSave: canCompose, requireConnection: requireConnection)
                .frame(maxWidth: 780).padding(.horizontal, 16)
            if uploading || sending {
                Text(uploading ? "Attaching…" : "Sending…")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("Photo library", systemImage: "photo") {
                        guard canCompose, requireConnection() else { return }
                        editingHandle.cancel()
                        guard let screen, let destination = workspace.captureImport(screen.owner) else { return }
                        photoPicker = AttachmentPicker(destination: destination, owner: screen.owner, workspace: workspace)
                        selectedPhoto = nil
                        showsPhotos = true
                    }
                    Button("Choose a file", systemImage: "doc") {
                        guard canCompose, requireConnection() else { return }
                        editingHandle.cancel()
                        guard let screen, let destination = workspace.captureImport(screen.owner) else { return }
                        filePicker = AttachmentPicker(destination: destination, owner: screen.owner, workspace: workspace)
                        showsFiles = true
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 20)).frame(width: 48, height: 48)
                        .composerGlass(in: Circle())
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
                        })
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
                .composerGlass(in: RoundedRectangle(cornerRadius: 26))
            }
            .composerGlassGroup()
            .padding(.horizontal, 12).padding(.bottom, 8)
            .frame(maxWidth: 780)
        }
        .frame(maxWidth: .infinity)
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: false, onCompletion: { [picker = filePicker] result in
            guard let picker, importsAllowed, filePicker == picker,
                  picker.workspace.isCurrent(picker.owner) else { return }
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    picker.workspace.cancelImport(picker.destination); filePicker = nil; return
                }
                readFile(url, picker: picker)
            case .failure(let error):
                picker.workspace.cancelImport(picker.destination)
                filePicker = nil
                if !(error is CancellationError) { attachmentError = error.localizedDescription }
            }
        }, onCancellation: { [picker = filePicker] in
            guard let picker else { return }
            picker.workspace.cancelImport(picker.destination)
            if filePicker == picker { filePicker = nil }
        })
        .photosPicker(isPresented: $showsPhotos, selection: photoSelection, matching: .images)
        .onChange(of: selectedPhoto) { _, photo in
            photoTask?.cancel()
            if photo != nil { photoTask = Task { await readPhoto() } }
        }
        .onChange(of: showsFiles || showsPhotos) { _, shown in onPickerPresentation(shown) }
        .onChange(of: importPresentationRevision) { _, _ in cancelAttachmentImport() }
        .onChange(of: screen?.owner) { _, _ in
            stopping = nil
            cancelAttachmentImport()
        }
        .onChange(of: importsAllowed) { _, available in
            if !available { cancelAttachmentImport() }
        }
        .onChange(of: showsPhotos) { _, shown in
            if !shown, selectedPhoto == nil, let picker = photoPicker {
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

    private func cancelAttachmentImport() {
        photoTask?.cancel(); photoTask = nil
        fileTask?.cancel()
        fileTask = nil
        if let filePicker { filePicker.workspace.cancelImport(filePicker.destination) }
        if let photoPicker { photoPicker.workspace.cancelImport(photoPicker.destination) }
        filePicker = nil; photoPicker = nil
        attachmentReadID = nil; attachmentError = nil
        selectedPhoto = nil
        showsFiles = false; showsPhotos = false
    }

    private func readFile(_ url: URL, picker: AttachmentPicker) {
        guard !uploading, importsAllowed, filePicker == picker,
              picker.workspace.isCurrent(picker.owner) else { return }
        attachmentReadID = picker.id; attachmentError = nil
        fileTask = Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                picker.workspace.cancelImport(picker.destination)
                if attachmentReadID == picker.id {
                    attachmentReadID = nil; fileTask = nil; filePicker = nil
                }
            }
            do {
                try Task.checkCancellation()
                let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                guard (metadata.fileSize ?? 0) <= AttachmentLimits.fileBytes else {
                    attachmentError = AttachmentLimits.message; return
                }
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                guard !Task.isCancelled, importsAllowed, filePicker == picker else { return }
                await picker.workspace.upload(data, filename: url.lastPathComponent,
                                              mimeType: metadata.contentType?.preferredMIMEType ?? "application/octet-stream",
                                              to: picker.destination)
            } catch {
                if !Task.isCancelled, importsAllowed, filePicker == picker {
                    attachmentError = "Couldn’t attach this file. \(error.localizedDescription)"
                }
            }
        }
    }

    private func readPhoto() async {
        guard let photo = selectedPhoto, let picker = photoPicker, !uploading, importsAllowed,
              picker.workspace.isCurrent(picker.owner) else { return }
        attachmentReadID = picker.id; attachmentError = nil
        defer {
            picker.workspace.cancelImport(picker.destination)
            if attachmentReadID == picker.id {
                attachmentReadID = nil; selectedPhoto = nil; photoPicker = nil
            }
        }
        do {
            let data = try await photo.loadTransferable(type: Data.self)
            guard !Task.isCancelled, importsAllowed, photoPicker == picker else { return }
            guard let data else {
                attachmentError = "Couldn’t read this photo. Try another image."; return
            }
            let type = photo.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .jpeg
            await picker.workspace.upload(data, filename: "Photo.\(type.preferredFilenameExtension ?? "jpg")",
                                          mimeType: type.preferredMIMEType ?? "image/jpeg", to: picker.destination)
        } catch {
            if !Task.isCancelled, importsAllowed, photoPicker == picker {
                attachmentError = "Couldn’t attach this photo. \(error.localizedDescription)"
            }
        }
    }
}

private extension View {
    @ViewBuilder func composerGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder func composerGlassGroup() -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 8) { self }
        } else {
            self
        }
    }
}
