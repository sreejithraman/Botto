import SwiftUI
import BottoCore

/// Botto's spaces: the main one first, then pinned and ongoing ones, plus one search over spaces and files.
/// Spaces are lasting places, so they carry plain names and are never grouped or expired by age.
struct T3ChatsDrawer: View {
    let store: AppStore
    let outputs: T3OutputsModel
    let openingChatID: String?
    @Binding var error: String?
    let isExposed: Bool
    let onOpen: (T3ChannelSummary) -> Void
    let onNewSpace: () -> Void
    let onOpenFile: (T3OutputFile) -> Void
    let onBotto: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var searching: Bool
    @State private var query = ""
    @State private var showsArchived = false
    @State private var changing: Set<String> = []
    @State private var renaming: T3ChannelSummary?
    @State private var renameText = ""
    @State private var connectionRequested = false

    var body: some View {
        VStack(spacing: 0) {
            if store.isDemo { DemoBanner() }
            search.padding(.horizontal, 16).padding(.top, 8)
            Button { searching = false; onNewSpace() } label: {
                Label("New space", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold)).foregroundStyle(BottoTheme.action)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.vertical, 4)
            .accessibilityIdentifier("t3-drawer-new-space")
            if connectionRequested, !store.isConnected {
                ConnectionStatusView(store: store).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let error {
                InlineNotice(message: error) { self.error = nil }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            list
            footer
        }
        .background(BottoTheme.paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("t3-spaces-drawer")
        .alert("Rename space", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .onChange(of: isExposed) { _, exposed in
            if !exposed { searching = false }
        }
        .onChange(of: store.isConnected) { _, connected in if connected { connectionRequested = false } }
        .onChange(of: store.configuration?.id) { _, _ in
            query = ""; showsArchived = false; changing = []; renaming = nil; connectionRequested = false
        }
    }

    // MARK: Search

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).accessibilityHidden(true)
            TextField("Search spaces and files", text: $query)
                .focused($searching)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("t3-drawer-search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: List

    private var list: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                spaces
            } else {
                results(T3ChatShelf.search(query, spaces: store.t3Channels, files: outputs.outputs ?? []))
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 44)
        .refreshable {
            await store.refresh()
            await outputs.load(store)
        }
    }

    @ViewBuilder private var spaces: some View {
        let shelf = T3ChatShelf.spaces(store.t3Channels)
        let archived = shelf.archived
        if shelf.live.isEmpty {
            Text(emptyText).font(.subheadline).foregroundStyle(.secondary)
                .padding(.vertical, 24).listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        if let main = shelf.main { Section { row(main) } }
        if !shelf.others.isEmpty {
            Section { ForEach(shelf.others) { row($0) } } header: { groupHeader(String(localized: "Spaces")) }
        }
        if !archived.isEmpty {
            Section {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showsArchived.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(showsArchived ? "Hide archived" : "Archived")
                        Text(archived.count, format: .number).foregroundStyle(.tertiary)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(showsArchived ? 0 : -90))
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                .accessibilityValue(showsArchived ? "Shown" : "Hidden")
                .accessibilityIdentifier("t3-archived-toggle")
                if showsArchived { ForEach(archived) { row($0) } }
            }
        }
    }

    private var emptyText: String {
        if store.link == .connecting { return String(localized: "Waking up…") }
        if !store.isConnected { return String(localized: "Spaces appear when the host connects.") }
        return String(localized: "No spaces yet. Say hi to start one.")
    }

    @ViewBuilder private func results(_ results: T3ChatShelf.SearchResults) -> some View {
        if let error = outputs.error {
            Section {
                InlineNotice(message: error)
                Button("Retry files", systemImage: "arrow.clockwise") { Task { await outputs.load(store) } }
            }
        } else if results.isEmpty {
            Text("Nothing matches “\(query)”.").font(.subheadline).foregroundStyle(.secondary)
                .padding(.vertical, 24).listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        if !results.spaces.isEmpty {
            Section { ForEach(results.spaces) { row($0) } } header: { groupHeader(String(localized: "Spaces")) }
        }
        if !results.files.isEmpty {
            Section {
                ForEach(results.files) { file in
                    Button { searching = false; onOpenFile(file) } label: {
                        HStack(spacing: 12) {
                            T3OutputThumbnail(output: file, model: outputs, store: store, width: 30)
                            Text(file.name).font(.body).foregroundStyle(BottoTheme.ink)
                                .lineLimit(2).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 16))
                    .accessibilityLabel("File \(file.name)")
                }
            } header: { groupHeader(String(localized: "Made by Botto")) }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.medium)).foregroundStyle(.tertiary).textCase(nil)
            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 16))
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ channel: T3ChannelSummary) -> some View {
        let selected = store.selectedT3ChannelID == channel.id
        let isMain = channel.isMain && !channel.isArchived
        let busy = openingChatID == channel.id || changing.contains(channel.id)
        return Button { searching = false; onOpen(channel) } label: {
            HStack(alignment: isMain ? .center : .top, spacing: 10) {
                if isMain { mainFace }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(channel.displayTitle)
                            .font(isMain ? .bottoRounded(.body, weight: .bold) : .body.weight(channel.isUnread ? .semibold : .medium))
                            .foregroundStyle(channel.isArchived ? Color.secondary : BottoTheme.ink)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        if channel.isPinned, !channel.isArchived, !isMain {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
                                .accessibilityLabel("Pinned")
                        }
                    }
                    if let detail = detail(channel) {
                        Text(detail.text).font(.subheadline.weight(detail.attention ? .medium : .regular))
                            .foregroundStyle(detail.attention ? BottoTheme.action : .secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    }
                }
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.small).padding(.top, 2)
                } else if channel.isUnread, !channel.needsYou {
                    Circle().fill(BottoTheme.action).frame(width: 8, height: 8).padding(.top, 7)
                        .accessibilityHidden(true)
                } else if let date = channel.updatedAt {
                    Text(T3TimeLabel.compact(date)).font(.caption).foregroundStyle(.tertiary).padding(.top, 3)
                        .accessibilityLabel(T3TimeLabel.spoken(date))
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background((selected || channel.needsYou) ? BottoTheme.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(openingChatID != nil)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue(channel, selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(isMain ? "t3-main-space" : "t3-space-\(channel.id)")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !channel.isArchived, !isMain {
                Button(channel.isPinned ? "Unpin" : "Pin", systemImage: channel.isPinned ? "pin.slash" : "pin") {
                    togglePin(channel)
                }
                .tint(BottoTheme.action)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: !isMain) {
            // The main space stays; it can only be renamed.
            if !isMain {
                Button(channel.isArchived ? "Unarchive" : "Archive",
                       systemImage: channel.isArchived ? "tray.and.arrow.up" : "archivebox") { toggleArchive(channel) }
                    .tint(.gray)
            }
            if !channel.isArchived {
                Button("Rename", systemImage: "pencil") { beginRename(channel) }.tint(.indigo)
            }
        }
        .contextMenu { menu(channel) }
    }

    /// Botto's own face marks its main space; the name beside it is whatever the user chose.
    /// It stays a plain awake face: other spaces' questions belong to their own rows and the footer.
    private var mainFace: some View {
        let bot = store.primaryT3Bot
        return BotAvatar(profile: bot ?? BotProfile(id: "t3-waking", name: ""),
                         size: 30, presentation: store.link == .offline ? .offline : .idle)
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
    }

    private func detail(_ channel: T3ChannelSummary) -> (text: String, attention: Bool)? {
        let line = channel.preview.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if channel.needsYou {
            return (line.isEmpty ? String(localized: "Waiting on you") : String(localized: "Waiting on you: \(line)"), true)
        }
        if channel.status == .working, !channel.isArchived { return (String(localized: "Working on it…"), true) }
        return line.isEmpty ? nil : (line, false)
    }

    private func accessibilityValue(_ channel: T3ChannelSummary, selected: Bool) -> String {
        var parts: [String] = []
        if channel.isMain, !channel.isArchived { parts.append(String(localized: "Main space")) }
        if selected { parts.append(String(localized: "Open")) }
        if channel.isUnread { parts.append(String(localized: "Unread")) }
        if channel.isArchived { parts.append(String(localized: "Archived")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private func menu(_ channel: T3ChannelSummary) -> some View {
        if channel.isUnread, !channel.isArchived {
            Button("Mark as read", systemImage: "checkmark.circle") { markRead(channel) }
        }
        let isMain = channel.isMain && !channel.isArchived
        if !channel.isArchived {
            if !isMain {
                Button(channel.isPinned ? "Unpin" : "Pin", systemImage: channel.isPinned ? "pin.slash" : "pin") { togglePin(channel) }
            }
            Button("Rename", systemImage: "pencil") { beginRename(channel) }
        }
        if !isMain {
            Button(channel.isArchived ? "Unarchive" : "Archive",
                   systemImage: channel.isArchived ? "tray.and.arrow.up" : "archivebox") { toggleArchive(channel) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { searching = false; onBotto() } label: {
                HStack(spacing: 10) {
                    Group {
                        if let bot = store.primaryT3Bot {
                            AppBotAvatar(store: store, bot: bot, size: 38, fitsBody: true)
                        } else {
                            BotAvatar(profile: BotProfile(id: "t3-waking", name: ""), size: 38,
                                      presentation: store.isConnected ? .idle : .offline)
                        }
                    }
                    .frame(width: 42, height: 42, alignment: .bottom)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.primaryT3Bot?.name ?? "Botto").font(.bottoRounded(.body, weight: .bold))
                            .foregroundStyle(BottoTheme.ink)
                        Text(store.isDemo ? "Personality and memory" : "Personality, memory, routines")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Open Botto’s page.")
            .accessibilityIdentifier("t3-drawer-botto")
            Button("Settings", systemImage: "gearshape") { searching = false; onSettings() }
                .labelStyle(.iconOnly).font(.body).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
                .accessibilityIdentifier("t3-drawer-settings")
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
    }

    // MARK: Actions

    private func beginRename(_ channel: T3ChannelSummary) {
        renameText = channel.isUntitled ? "" : channel.displayTitle
        renaming = channel
    }

    private func commitRename() {
        guard let channel = renaming else { return }
        renaming = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != channel.displayTitle else { return }
        change(channel) { try await store.renameT3Channel(threadID: channel.id, title: title) }
    }

    private func togglePin(_ channel: T3ChannelSummary) {
        change(channel) { try await store.setT3ChannelPinned(threadID: channel.id, pinned: !channel.isPinned) }
    }

    private func toggleArchive(_ channel: T3ChannelSummary) {
        change(channel) { try await store.archiveT3Channel(threadID: channel.id, archived: !channel.isArchived) }
    }

    private func markRead(_ channel: T3ChannelSummary) {
        change(channel) { try await store.markT3ChannelVisited(threadID: channel.id) }
    }

    private func change(_ channel: T3ChannelSummary, action: @escaping @MainActor () async throws -> Void) {
        guard isExposed, !changing.contains(channel.id) else { return }
        guard store.isConnected else { connectionRequested = true; return }
        let scope = store.configuration?.id
        changing.insert(channel.id)
        error = nil
        Task {
            do { try await action() }
            catch where store.configuration?.id == scope { self.error = error.localizedDescription }
            catch { }
            if store.configuration?.id == scope { changing.remove(channel.id) }
        }
    }
}
