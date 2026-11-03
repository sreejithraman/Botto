import SwiftUI
import BottoCore

struct BotProfileEditor: View {
    let store: AppStore
    let destination: AppStore.AvatarDestination
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var descriptionHeight: CGFloat = 110
    @State private var name: String
    @State private var description: String
    @State private var selection: BotAvatarChoice?
    @State private var saving = false
    @State private var connectionRequested = false
    @State private var task: Task<Void, Never>?
    @State private var presentation = UUID()
    @State private var error: String?
    @State private var needsReload = false
    @State private var reloading = false
    @State private var retired = false
    @State private var reloadedDestination: AppStore.AvatarDestination?
    @State private var isVisible = false
    @State private var generation = AvatarGenerationModel()

    init(store: AppStore, destination: AppStore.AvatarDestination) {
        self.store = store
        self.destination = destination
        _name = State(initialValue: destination.profile.name)
        _description = State(initialValue: destination.profile.description)
    }

    private var target: AppStore.AvatarDestination { reloadedDestination ?? destination }
    private var profileEdit: BotProfileEdit {
        .init(name: name.utf8.elementsEqual(target.profile.name.utf8) ? nil : name,
              description: description.utf8.elementsEqual(target.profile.description.utf8) ? nil : description)
    }
    private var hasChanges: Bool { selection != nil || profileEdit.name != nil || profileEdit.description != nil }
    private var preview: BotProfile {
        var profile = target.profile
        profile.name = name
        profile.description = description
        if let selection {
            profile.appearance = selection.applying(to: target.profile.appearance ?? BotAppearance())
            profile.hasAvatar = false
        }
        return profile
    }

    private var hasSavedImage: Bool {
        store.hasSavedAvatarImage(for: target.profile)
    }

    private var avatarDescription: String {
        if selection == nil, hasSavedImage { return "Current avatar" }
        let face = preview.face
        let color = preview.appearance?.color.flatMap { $0.isEmpty ? nil : $0 } == nil && preview.appearance?.isGenerated != true
            ? String(localized: "Match the name") : BotAvatarColor.label(for: face.color)
        let sharedShape = preview.appearance?.rawShape != nil && preview.appearance?.shape == nil && preview.appearance?.isGenerated != true
        let shape = preview.appearance?.geometry?.name ?? (sharedShape ? String(localized: "Shared shape") : face.shape.label)
        return "\(shape) · \(color)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if store.isDemo { Text("Sample profile only. No server is changed.").font(.subheadline).foregroundStyle(.secondary) }
                VStack(spacing: 12) {
                    BotAvatar(profile: preview, image: selection == nil ? store.avatar(for: target.profile) : nil, size: 110)
                    Text(name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Avatar preview for \(name)")
                .accessibilityValue(avatarDescription)
                .accessibilityIdentifier("bot-avatar-preview")
                if hasSavedImage {
                    Text("Choosing a face replaces the current image when you save.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if target.profile.appearance?.isGenerated == true {
                    Text("Choosing a shape or color saves a classic face to Hermes and replaces this generated avatar.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                characterGenerator
                    .disabled(saving || reloading || needsReload)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Name").font(.subheadline.weight(.semibold))
                    TextField("Name", text: $name)
                        .textContentType(.nickname)
                        .padding(16).background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("bot-profile-name")
                    Text("Description").font(.subheadline.weight(.semibold)).padding(.top, 10)
                    TextEditor(text: $description)
                        .frame(height: descriptionHeight)
                        .scrollContentBackground(.hidden)
                        .padding(12).background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("Description")
                        .accessibilityIdentifier("bot-profile-description")
                }
                .disabled(saving || reloading || needsReload)
                BotAvatarPicker(profileID: target.profile.id, current: target.profile.appearance ?? BotAppearance(),
                                selection: $selection, hasImage: hasSavedImage)
                    .id(target.id)
                    .disabled(saving || reloading || needsReload || generation.isGenerating)
                if let error { InlineNotice(message: error).accessibilityIdentifier("avatar-error") }
                if needsReload && !retired {
                    Button(reloading ? "Reloading profile…" : "Reload profile") { reload() }
                        .frame(minHeight: 44).disabled(reloading)
                }
            }
            .padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if connectionRequested && !store.isConnected {
                ConnectionStatusView(store: store)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .frame(maxWidth: 540).frame(maxWidth: .infinity)
                    .background(BottoTheme.paper, ignoresSafeAreaEdges: [])
            }
        }
        .background(BottoTheme.paper, ignoresSafeAreaEdges: [])
        .bottoNavigationChrome()
        .navigationTitle("Edit bot").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { retire(); dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { save() }
                    .disabled(saving || reloading || needsReload || generation.isGenerating || !hasChanges || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-bot-profile")
            }
        }
        .interactiveDismissDisabled(saving)
        .tint(BottoTheme.action)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; retire() }
        .onChange(of: store.connectionGeneration) { _, _ in
            interruptNetworkOperation()
        }
        .onChange(of: target.isCurrent(in: store)) { _, current in
            guard !current else { return }
            retire(); needsReload = true; retired = true
            error = "This workspace changed. Close this editor and open the bot again."
        }
        .onChange(of: store.showsConnection) { _, shown in
            if shown { interruptNetworkOperation() }
        }
        .onChange(of: store.isConnected) { _, connected in
            connectionRequested = false
            if !connected { interruptNetworkOperation() }
        }
    }

    private var characterGenerator: some View {
        @Bindable var generation = generation
        return VStack(alignment: .leading, spacing: 12) {
            Text("Create a character").font(.headline)
            Text(store.isDemo
                 ? "Preview a sample cat here. Connect Hermes to create a character from your description."
                 : "Describe a character for your bot. Complex ideas become simple, expressive silhouettes.")
                .font(.subheadline).foregroundStyle(.secondary)
            if !store.isDemo {
                TextField("A sleepy dragon, a gardening companion…", text: $generation.description, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(16).background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Character description")
                    .accessibilityIdentifier("avatar-character-description")
            }
            if generation.isGenerating {
                HStack(spacing: 12) {
                    ProgressView().accessibilityHidden(true)
                    Text("Creating character…").font(.subheadline)
                    Spacer()
                    Button("Cancel") { generation.cancel() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("cancel-avatar-generation")
                }
                .accessibilityElement(children: .contain)
            } else {
                Button(action: generateCharacter) {
                    Label(store.isDemo ? "Preview sample character" : "Generate character", systemImage: "sparkles")
                        .frame(minHeight: 44)
                }
                .disabled(!store.isDemo && generation.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("generate-avatar-character")
            }
            if let error = generation.error {
                InlineNotice(message: error).accessibilityIdentifier("avatar-generation-error")
            }
            if preview.appearance?.geometry != nil {
                Text("This character animates in Botto. Other Hermes apps may show a default face. Save to keep your changes.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func generateCharacter() {
        guard !saving, !reloading, !needsReload, !generation.isGenerating, !store.showsConnection else { return }
        guard store.isConnected else { connectionRequested = true; return }
        if store.isDemo { generation.description = "Sample cat" }
        let destination = target, owner = presentation, connection = store.connectionGeneration
        Task { @MainActor in
            guard isVisible, owns(owner, connection: connection) else { return }
            await generation.generate(using: { description in
                let geometry = try await store.generateAvatar(description: description, for: destination)
                _ = try await BotAvatarRenderCache.shared.prepare(geometry)
                return geometry
            }, accept: { geometry in
                let color: BotAvatarEdit.Color?
                switch selection {
                case .geometry(_, let override): color = override
                case .edit(let edit): color = edit.color
                case .automatic, .shape: color = .automatic
                case .face(let face): color = .value(face.color)
                case nil: color = nil
                }
                selection = .geometry(geometry, color: color)
            })
        }
    }

    private func save() {
        guard hasChanges, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !saving, !needsReload, !generation.isGenerating, !store.showsConnection else { return }
        guard store.isConnected else { connectionRequested = true; return }
        saving = true; error = nil
        let owner = presentation, connection = store.connectionGeneration, destination = target
        let edit = profileEdit, avatar = selection
        task = Task { @MainActor in
            do {
                try await store.saveProfile(edit, avatar: avatar, to: destination)
                guard owns(owner, connection: connection) else { return }
                if canPlayFeedback { BottoHaptics.shared.play(.celebration) }
                saving = false; task = nil; dismiss()
            } catch {
                guard owns(owner, connection: connection) else { return }
                saving = false; task = nil; self.error = error.localizedDescription
                // AppStore reports partialProfile if metadata was saved before avatar validation failed.
                needsReload = switch error {
                case BotAvatarEngineError.unavailable, BotAvatarEngineError.invalidFrame: false
                default: true
                }
                playFailure(error)
            }
        }
    }

    private func reload() {
        guard !reloading else { return }
        guard store.isConnected else { connectionRequested = true; return }
        generation.cancel()
        reloading = true
        let owner = presentation, connection = store.connectionGeneration
        task = Task { @MainActor in
            do {
                let updated = try await store.reloadAvatar(target)
                guard owns(owner, connection: connection) else { return }
                reloadedDestination = updated
                selection = nil; name = updated.profile.name; description = updated.profile.description
                error = nil; needsReload = false
            } catch {
                guard owns(owner, connection: connection) else { return }
                self.error = error.localizedDescription
                playFailure(error)
            }
            reloading = false; task = nil
        }
    }

    private func owns(_ owner: UUID, connection: UUID) -> Bool {
        !Task.isCancelled && presentation == owner && store.connectionGeneration == connection
            && target.isCurrent(in: store) && !store.showsConnection
    }
    private func interruptNetworkOperation() {
        generation.cancel()
        if saving {
            error = HermesServiceError.uncertainProfile.localizedDescription
            needsReload = true
            playFailure(HermesServiceError.uncertainProfile)
        }
        if saving || reloading { retire() }
    }
    private func retire() {
        generation.cancel()
        presentation = UUID(); task?.cancel(); task = nil; saving = false; reloading = false
    }

    private var canPlayFeedback: Bool {
        isVisible && scenePhase == .active && !store.showsConnection && target.isCurrent(in: store)
    }

    private func playFailure(_ error: any Error) {
        guard !(error is CancellationError), canPlayFeedback else { return }
        BottoHaptics.shared.play(.failure(error))
    }
}
