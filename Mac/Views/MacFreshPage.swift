import BottoCore
import SwiftUI

/// The page a new space starts from. Nothing exists on the host until it has a name or a first message.
struct MacFreshPage: View {
    let store: MacBottoStore
    @Binding var name: String
    @Binding var draft: String
    /// The space was created but its first message didn't go out; keep the words with that space.
    let onUnsent: (_ spaceID: String, _ text: String) -> Void
    @State private var files: [URL] = []
    @State private var dropTargeted = false
    @State private var composerFocusRequests = 0

    private var botName: String { store.bot?.name ?? "Botto" }

    var body: some View {
        let away = T3ChatShelf.whileYouWereAway(store.channels)
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 0) {
                MacBotAvatarView(profileID: store.bot?.id ?? "main", appearance: store.bot?.appearance,
                                 activity: store.isStartingSpace ? .thinking : MacAvatarActivity(status: store.botStatus))
                    .frame(width: 118, height: 118)
                TimelineView(.everyMinute) { context in
                    Text(T3ChatShelf.greeting(at: context.date).rawValue)
                        .font(MacTheme.rounded(.largeTitle, weight: .heavy))
                        .padding(.top, 20)
                }
                Text("What are we getting into?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                if !away.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("While you were away").font(.callout).foregroundStyle(.tertiary).padding(.leading, 4)
                        ForEach(away) { chat in note(chat) }
                    }
                    .frame(maxWidth: 440)
                    .padding(.top, 34)
                }
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 6) {
                nameField
                composer
            }
                .frame(maxWidth: 720)
                .padding(.horizontal, 32)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacTheme.paper)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(MacTheme.action, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let picked = urls.filter(\.isFileURL)
            files += picked
            return !picked.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private func note(_ chat: T3ChannelSummary) -> some View {
        Button { Task { await store.openChannel(chat.id) } } label: {
            HStack(spacing: 12) {
                if chat.needsYou {
                    Text("?")
                        .font(MacTheme.rounded(.callout, weight: .bold))
                        .foregroundStyle(MacTheme.action)
                        .frame(width: 26, height: 26)
                        .background(MacTheme.selection, in: .circle)
                } else {
                    Circle().fill(MacTheme.action).frame(width: 8, height: 8).frame(width: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(chat.preview.isEmpty ? chat.displayTitle : firstLine(chat.preview))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(chat.needsYou ? "\(chat.displayTitle) · waiting on you"
                         : [chat.displayTitle, chat.updatedAt.map { MacTimeLabel.compact($0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(MacTheme.surface, in: .rect(cornerRadius: 18))
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(chat.displayTitle)")
    }

    private var hasName: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Quiet on purpose: a name is an option, not a step.
    private var nameField: some View {
        TextField("Name this space (optional)", text: $name)
            .textFieldStyle(.plain)
            .font(.body.weight(.medium))
            .onSubmit { composerFocusRequests += 1 }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .disabled(!store.isConnected || store.isStartingSpace)
            .accessibilityIdentifier("mac-space-name")
    }

    private var composer: some View {
        MacComposer(draft: $draft, placeholder: "Message \(botName)",
                    modelLabel: store.freshModel?.label ?? store.modelLabel(for: nil),
                    isWorking: false, isBusy: store.isStartingSpace, hasAttachments: !files.isEmpty, canStop: false,
                    allowsEmpty: hasName, focusRequests: composerFocusRequests,
                    onAttach: { files += MacFilePicker.pick(message: "Choose files to share with \(botName).") },
                    onSend: start, onStop: {}) {
            if !files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: MacAttachmentKind.symbol(for: MacAttachmentKind.mimeType(for: url)))
                                    .foregroundStyle(MacTheme.action)
                                Text(url.lastPathComponent).font(.caption.weight(.medium)).lineLimit(1)
                                Button { files.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(MacTheme.paper, in: .rect(cornerRadius: 10))
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        } modelMenu: {
            Button {
                store.freshModel = nil
            } label: {
                if store.freshModel == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            if !store.models.isEmpty { Divider() }
            ForEach(store.models) { option in
                Button { store.freshModel = option } label: {
                    if store.freshModel == option { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                }
            }
        }
        .disabled(!store.isConnected)
    }

    private func start() {
        let text = draft
        let title = name
        let attached = files
        Task {
            let result = await store.startSpace(named: title, text: text, files: attached)
            guard result.sent || result.spaceID != nil else { return }
            if name == title { name = "" }
            if draft == text { draft = "" }
            files = []
            // The new space is open now; its composer keeps words that didn't go out.
            if !result.sent, let space = result.spaceID { onUnsent(space, text) }
        }
    }

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}
