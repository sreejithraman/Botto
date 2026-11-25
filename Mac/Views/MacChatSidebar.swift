import BottoCore
import SwiftUI

/// The spaces list: Botto's face on top, one search over spaces and files, then the main space and every lasting one.
struct MacChatSidebar: View {
    let server: LocalT3ServerManager
    let store: MacBottoStore
    let onRename: (T3ChannelSummary) -> Void
    let onPreview: (MacPreviewItem) -> Void
    @State private var query = ""
    @State private var showsArchived = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            MacSidebarFace(server: server, store: store)
                .padding(.top, 14)
                .padding(.bottom, 10)
            searchField
                .padding(.horizontal, 12)
            Button { store.showFreshPage() } label: {
                Label("New space", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.isConnected ? MacTheme.action : Color.secondary)
            .disabled(!store.isConnected)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .accessibilityIdentifier("mac-new-space")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        spaceList
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand(perform: moveSelection)
        }
        .background(MacTheme.surface)
        .task(id: query.isEmpty) {
            if !query.isEmpty, store.outputs == nil { await store.loadOutputs() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Search spaces and files", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(MacTheme.paper.opacity(0.8), in: .rect(cornerRadius: 10))
    }

    // MARK: Spaces

    @ViewBuilder
    private var spaceList: some View {
        let shelf = T3ChatShelf.spaces(store.channels)
        let archived = shelf.archived
        if shelf.live.isEmpty, archived.isEmpty, store.isConnected {
            Text("No spaces yet. Say hello and Botto will name the space for you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
        if let main = shelf.main { row(main) }
        if !shelf.others.isEmpty {
            groupTitle("Spaces")
            ForEach(shelf.others) { row($0) }
        }
        if !archived.isEmpty {
            Button {
                withAnimation(.snappy) { showsArchived.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text("Archived")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(showsArchived ? 90 : 0))
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsArchived ? "Hide archived spaces" : "Show archived spaces")
            if showsArchived {
                ForEach(archived) { row($0) }
            }
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ chat: T3ChannelSummary) -> some View {
        // The main space stays; it can only be renamed.
        let isMain = chat.isMain && !chat.isArchived
        return MacChatRow(chat: chat, isSelected: chat.id == store.selectedChannelID, face: isMain ? store.bot : nil) {
            Task { await store.openChannel(chat.id) }
        }
        .contextMenu {
            if !chat.isArchived {
                if !isMain {
                    Button(chat.isPinned ? "Unpin" : "Pin") {
                        Task { await store.setChannelPinned(threadID: chat.id, pinned: !chat.isPinned) }
                    }
                }
                Button("Rename…") { onRename(chat) }
            }
            if chat.isUnread {
                Button("Mark as Read") { Task { await store.markRead(threadID: chat.id) } }
            }
            if !isMain {
                Divider()
                Button(chat.isArchived ? "Unarchive" : "Archive") {
                    Task { await store.archiveChannel(threadID: chat.id, archived: !chat.isArchived) }
                }
            }
        }
    }

    // MARK: Search

    @ViewBuilder
    private var searchResults: some View {
        let results = T3ChatShelf.search(query, spaces: store.channels, files: store.outputs ?? [])
        if results.isEmpty {
            Text(store.outputs == nil ? "Searching…" : "Nothing matches “\(query)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
        }
        if !results.spaces.isEmpty {
            groupTitle("Spaces")
            ForEach(results.spaces) { row($0) }
        }
        if !results.files.isEmpty {
            groupTitle("Files")
            ForEach(results.files) { file in
                Button { onPreview(.output(file, store: store)) } label: {
                    HStack(spacing: 10) {
                        MacPageThumbnail(kind: MacFileKind(name: file.name, mimeType: file.mimeType))
                            .frame(width: 26, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Text("Made by Botto").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let shelf = T3ChatShelf.spaces(store.channels)
        let spaces = shelf.live + (showsArchived ? shelf.archived : [])
        guard !spaces.isEmpty else { return }
        let current = spaces.firstIndex { $0.id == store.selectedChannelID }
        let next: Int
        switch direction {
        case .up: next = max(0, (current ?? spaces.count) - 1)
        case .down: next = min(spaces.count - 1, (current ?? -1) + 1)
        default: return
        }
        let id = spaces[next].id
        Task { await store.openChannel(id) }
    }
}

/// Botto's live face replaces the engine status bar. Asleep, it offers to wake; awake, it opens the Botto page.
struct MacSidebarFace: View {
    let server: LocalT3ServerManager
    let store: MacBottoStore

    private var engineAwake: Bool { server.state == .running || server.state == .starting }

    private var activity: MacAvatarActivity {
        if !engineAwake { return .sleeping }
        if !store.isConnected { return .thinking }
        return MacAvatarActivity(status: store.botStatus)
    }

    var body: some View {
        VStack(spacing: 6) {
            Button { if store.isConnected { store.showsInspector.toggle() } } label: {
                MacBotAvatarView(profileID: store.bot?.id ?? "main", appearance: store.bot?.appearance, activity: activity)
                    .frame(width: 62, height: 62)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!store.isConnected)
            .help(store.isConnected ? "Botto (⌘I)" : "")
            .accessibilityLabel("\(store.bot?.name ?? "Botto"), \(status)")
            .accessibilityHint(store.isConnected ? "Opens personality, memory and routines" : "")
            Text(store.bot?.name ?? "Botto")
                .font(MacTheme.rounded(.headline, weight: .bold))
            if engineAwake {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(activity == .waiting ? MacTheme.action : .secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: status)
            } else {
                Button("Wake Botto") { server.start() }
                    .buttonStyle(MacPillButtonStyle())
                    .controlSize(.small)
                    .padding(.top, 2)
                    .accessibilityIdentifier("mac-wake-botto")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var status: String {
        switch server.state {
        case .stopped: return "Asleep"
        case .failed: return "Couldn’t wake up"
        case .starting: return "Waking up…"
        case .running:
            guard store.isConnected else { return store.isConnecting ? "Waking up…" : "Can’t reach the engine" }
            return activity.label ?? "Personality, memory, routines"
        }
    }
}

struct MacChatRow: View {
    let chat: T3ChannelSummary
    let isSelected: Bool
    /// The bot, when this row is its main space.
    var face: BotProfile?
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: isMain ? .center : .firstTextBaseline, spacing: 8) {
                if let face {
                    MacBotAvatarView(profileID: face.id, appearance: face.appearance, activity: MacAvatarActivity(status: chat.status))
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if chat.isPinned, !chat.isArchived, !isMain {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel("Pinned")
                        }
                        Text(chat.displayTitle)
                            .font(isMain ? MacTheme.rounded(.body, weight: .bold) : .body.weight(chat.isUnread && !isSelected ? .semibold : .medium))
                            .foregroundStyle(chat.isArchived ? Color.secondary : Color.primary)
                            .lineLimit(1)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(chat.needsYou ? MacTheme.action : .secondary)
                            .fontWeight(chat.needsYou ? .medium : .regular)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(background, in: .rect(cornerRadius: 11))
            .contentShape(.rect(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityValue([isMain ? "Main space" : nil, chat.isUnread ? "Unread" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier(isMain ? "mac-main-space" : "mac-space-\(chat.id)")
    }

    private var isMain: Bool { chat.isMain && !chat.isArchived }

    private var subtitle: String? {
        let preview = chat.preview.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if chat.needsYou { return preview.isEmpty ? "Waiting on you" : "Waiting on you: \(preview)" }
        if chat.status == .working, !chat.isArchived, preview.isEmpty { return "Working…" }
        return preview.isEmpty ? nil : preview
    }

    @ViewBuilder
    private var trailing: some View {
        if chat.isUnread, !isSelected, !chat.isArchived {
            Circle().fill(MacTheme.action).frame(width: 7, height: 7).accessibilityHidden(true)
        } else if let date = chat.updatedAt {
            Text(MacTimeLabel.compact(date)).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var background: Color {
        if isSelected { return MacTheme.selection }
        if chat.needsYou { return MacTheme.selection.opacity(0.45) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }
}
