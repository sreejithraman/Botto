import SwiftUI
import BottoCore

struct NewBotView: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatar: BotAvatarChoice? = .automatic
    @State private var instructions = ""
    @State private var creating = false
    @State private var connectionRequested = false
    @State private var creationTask: Task<Void, Never>?
    @State private var presentationID = UUID()
    @State private var error: String?
    @FocusState private var focusedName: Bool

    private let starters: [(String, String, String)] = [
        ("A thoughtful researcher", "Scout", "Help me research ideas. Find trustworthy sources, explain what matters, and flag what is uncertain."),
        ("A little everyday order", "Clover", "Help me organize my day. Turn loose thoughts into practical next steps and ask before taking action."),
        ("A second pair of eyes", "Pip", "Be my careful editor. Help me make writing clearer, shorter, and more natural while keeping my voice.")
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if store.isDemo { DemoBanner().padding(.horizontal, -24) }
                    VStack(spacing: 18) {
                        BotAvatar(profile: preview, size: 110)
                        Text("Every good helper\nstarts with a name.")
                            .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.top, 16)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Name").font(.subheadline.weight(.semibold))
                        TextField("What shall we call them?", text: $name)
                            .font(.title3.weight(.medium)).textContentType(.nickname)
                            .padding(16).background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                            .focused($focusedName).submitLabel(.done)
                            .onSubmit { focusedName = false }
                    }
                    BotAvatarPicker(profileID: preview.id, current: BotAppearance(), selection: $avatar)
                        .disabled(creating)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A little job to do").font(.subheadline.weight(.semibold))
                        TextField("What would you like help with?", text: $instructions, axis: .vertical)
                            .lineLimit(3...7).padding(16)
                            .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                        Text("Tell your bot what to focus on. You can keep shaping things together in your chats.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if instructions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A few starting points").font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 4)
                            ForEach(starters, id: \.0) { starter in
                                Button {
                                    if name.isEmpty { name = starter.1 }
                                    instructions = starter.2
                                } label: {
                                    HStack {
                                        Text(starter.0).multilineTextAlignment(.leading)
                                        Spacer(minLength: 8)
                                        Image(systemName: "arrow.up.left").font(.caption)
                                    }.font(.subheadline).frame(minHeight: 44)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if let error { InlineNotice(message: error) }
                    if connectionRequested && !store.isConnected { ConnectionStatusView(store: store) }
                    Button {
                        create()
                    } label: { Text(creating ? "Making your bot…" : "Create bot") }
                        .buttonStyle(BottoPrimaryButtonStyle())
                        .disabled(creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                }
                .padding(.horizontal, 24).padding(.bottom, 28)
                .frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BottoTheme.paper, ignoresSafeAreaEdges: [])
            .bottoNavigationChrome()
            .navigationTitle("New bot").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(creating) } }
            .interactiveDismissDisabled(creating)
        }
        .tint(BottoTheme.action)
        .onChange(of: avatar) { _, _ in focusedName = false }
        .onChange(of: store.isConnected) { _, _ in connectionRequested = false }
        .onDisappear { retireCreation() }
        .onChange(of: store.connectionGeneration) { _, _ in retireCreation() }
    }
    private var preview: BotProfile {
        let draft = BotDraft(name: name)
        return BotProfile(id: draft.profileID, name: name, appearance: (avatar ?? .automatic).appearance)
    }

    private func create() {
        guard !creating else { return }
        guard store.isConnected else { connectionRequested = true; return }
        creating = true; error = nil
        let draft = BotDraft(name: name.trimmingCharacters(in: .whitespacesAndNewlines), instructions: instructions, avatar: avatar ?? .automatic)
        let presentation = presentationID, connection = store.connectionGeneration
        creationTask = Task { @MainActor in
            defer {
                if ownsCreation(presentation, connection: connection) {
                    creating = false; creationTask = nil
                }
            }
            guard ownsCreation(presentation, connection: connection) else { return }
            let bot = await store.create(draft)
            guard ownsCreation(presentation, connection: connection) else { return }
            if let bot {
                await store.open(bot)
                guard ownsCreation(presentation, connection: connection) else { return }
                dismiss()
            } else {
                error = store.notice ?? "Couldn’t create your bot. Try again."
            }
        }
    }

    private func ownsCreation(_ presentation: UUID, connection: UUID) -> Bool {
        !Task.isCancelled && presentationID == presentation && store.connectionGeneration == connection
    }

    private func retireCreation() {
        presentationID = UUID()
        creationTask?.cancel()
        creationTask = nil; creating = false
        // Cancellation cannot establish whether the host already created the bot.
        // Retire this caller without retrying the mutation.
    }
}
