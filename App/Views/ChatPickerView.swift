import SwiftUI
import UIKit
import BottoCore

/// A caller-owned projection. Main is a Botto label, never a server-side rename.
struct ChatPickerItem: Identifiable, Equatable {
    let id: String
    let title: String
    let userPreview: String
    let replyPreview: String
    let isMain: Bool
    let isSelected: Bool
    let isPreferred: Bool
    let isUnread: Bool
    let activity: ActivityPresentation
    var status: BotStatus? { activity.currentStatus }
    /// Whether the caller can open this chat, including a read-only cached chat.
    let isAvailable: Bool
    let canClose: Bool

    init(id: String, title: String, userPreview: String = "", replyPreview: String = "",
         isMain: Bool = false, isSelected: Bool = false, isPreferred: Bool = false,
         isUnread: Bool = false, isAvailable: Bool = true, canClose: Bool = false, activity: ActivityPresentation = .unobserved) {
        self.id = id
        self.title = title
        self.userPreview = userPreview
        self.replyPreview = replyPreview
        self.isMain = isMain
        self.isSelected = isSelected
        self.isPreferred = isPreferred
        self.isUnread = isUnread
        self.activity = activity
        self.isAvailable = isAvailable
        self.canClose = canClose
    }

    var displayTitle: String {
        if isMain { return "Main" }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New chat" : title
    }

    func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [displayTitle, userPreview, replyPreview].contains {
            $0.localizedStandardContains(query)
        }
    }

    var statusLabel: String? {
        activity.label
    }

    var preferredActionTitle: String { isPreferred ? "Use last opened chat" : "Open by default" }

    var accessibilityLabel: String {
        [displayTitle, isSelected ? "Current chat" : nil, isPreferred ? "Opens by default" : nil,
         isUnread ? "Unread" : nil, activity.accessibilityLabel, isAvailable ? nil : "Unavailable"]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// A bot-scoped tab overview. Ordering, availability and effects belong to the caller.
struct ChatPickerView: View {
    let bot: BotProfile
    let items: [ChatPickerItem]
    let previews: ChatTabPreviews
    let transition: ChatOverviewTransition
    let onDone: () -> Void
    let closedItems: [ChatPickerItem]
    let recentlyClosedID: String?
    let onClose: (String) -> Void
    let onReopen: (String) -> Void
    let headerClearance: CGFloat
    let isLoading: Bool
    let isConnected: Bool
    let isCreating: Bool
    let canCreate: Bool
    let error: String?
    let connectionFeedback: ConnectionStatusView?
    let onSelect: (String) -> Void
    let onCreate: () -> Void
    let onSetPreferred: (String?) -> Void
    let onRefresh: () -> Void

    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var search = ""
    @State private var connectionRequested = false
    @State private var refreshRequested = false

    init(bot: BotProfile, items: [ChatPickerItem], previews: ChatTabPreviews,
         transition: ChatOverviewTransition, onDone: @escaping () -> Void, headerClearance: CGFloat = 56,
         isLoading: Bool = false, isConnected: Bool = true, isCreating: Bool = false, canCreate: Bool = true,
         error: String? = nil, connectionFeedback: ConnectionStatusView? = nil,
         onSelect: @escaping (String) -> Void, onCreate: @escaping () -> Void,
         onSetPreferred: @escaping (String?) -> Void, onRefresh: @escaping () -> Void,
         closedItems: [ChatPickerItem] = [], recentlyClosedID: String? = nil,
         onClose: @escaping (String) -> Void = { _ in }, onReopen: @escaping (String) -> Void = { _ in }) {
        self.bot = bot
        self.items = items
        self.previews = previews
        self.transition = transition; self.onDone = onDone; self.headerClearance = headerClearance
        self.isLoading = isLoading
        self.isConnected = isConnected
        self.isCreating = isCreating
        self.canCreate = canCreate
        self.error = error
        self.connectionFeedback = connectionFeedback
        self.onSelect = onSelect
        self.onCreate = onCreate
        self.onSetPreferred = onSetPreferred
        self.onRefresh = onRefresh
        self.closedItems = closedItems
        self.recentlyClosedID = recentlyClosedID
        self.onClose = onClose; self.onReopen = onReopen
    }

    private var filteredItems: [ChatPickerItem] { items.filter { $0.matches(search: search) } }
    private var hasSearch: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        searchField
                        if let error { errorNotice(error) }
                        if connectionRequested && !isConnected, let connectionFeedback { connectionFeedback }
                        collection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, headerClearance)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 660, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onAppear {
                    if let selected = items.first(where: \.isSelected) { scroll.scrollTo(selected.id, anchor: .center) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("chat-tabs-scroll")
            bottomBar
        }
        .background(BottoTheme.paper)
        .tint(BottoTheme.action)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-picker")
        .accessibilityAction(.escape, onDone)
        .onChange(of: isConnected) { _, _ in
            connectionRequested = false; refreshRequested = false
        }
        .onChange(of: isLoading) { _, loading in
            if !loading { refreshRequested = false }
        }
    }

    private var bottomBar: some View {
        ZStack {
            Group {
                if let recentlyClosedID, closedItems.contains(where: { $0.id == recentlyClosedID }) {
                    HStack(spacing: 6) {
                        Text("Chat closed").foregroundStyle(.secondary)
                        Button("Undo") { onReopen(recentlyClosedID) }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("undo-close-chat")
                    }
                } else {
                    Text(chatCount).foregroundStyle(.secondary)
                        .accessibilityIdentifier("chat-count")
                }
            }
            .font(.footnote)
            .padding(.horizontal, 64)
            HStack {
                createButton.frame(width: 48, height: 48).tabControlGlass(in: Circle())
                Spacer()
                if !closedItems.isEmpty {
                    Menu {
                        Section("Closed chats on this device") {
                            ForEach(closedItems) { item in
                                Button(item.displayTitle) { onReopen(item.id) }
                                    .accessibilityIdentifier("reopen-chat-\(item.id)")
                            }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .frame(width: 48, height: 48)
                    }
                    .tabControlGlass(in: Circle())
                    .accessibilityLabel("Closed chats")
                    .accessibilityIdentifier("closed-chats")
                }
            }
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Find a chat", text: $search)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search chats with \(bot.name)")
                .accessibilityIdentifier("chat-picker-search")
                .frame(minHeight: 48)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, search.isEmpty ? 16 : 0)
        .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 17))
    }

    private var createButton: some View {
        Button {
            guard canCreate, !isCreating else { return }
            guard isConnected else { connectionRequested = true; return }
            onCreate()
        } label: {
            HStack(spacing: 8) {
                if isCreating {
                    ProgressView().tint(BottoTheme.action).accessibilityHidden(true)
                } else {
                    Image(systemName: "plus")
                }
            }
            .font(.subheadline.weight(.medium))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tint(BottoTheme.action).foregroundStyle(BottoTheme.action)
        .disabled(isCreating || !canCreate)
        .accessibilityLabel("New chat")
        .accessibilityValue(isCreating ? "Creating chat" : "")
        .accessibilityHint("Start an independent chat.")
        .accessibilityIdentifier("new-chat")
    }

    private func errorNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(.subheadline)
            Button {
                guard isConnected else { connectionRequested = true; return }
                refreshRequested = true
                onRefresh()
            } label: {
                HStack(spacing: 8) {
                    if refreshRequested && isLoading {
                        ProgressView().accessibilityLabel("Updating chats")
                            .accessibilityIdentifier("chat-picker-refresh-progress")
                    }
                    Label(refreshRequested && isLoading ? "Retrying…" : "Retry", systemImage: "arrow.clockwise")
                }
            }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
                .disabled(isLoading)
                .accessibilityIdentifier("chat-picker-retry")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var chatCount: String { items.count == 1 ? "1 chat" : "\(items.count) chats" }

    @ViewBuilder private var collection: some View {
        if items.isEmpty && isLoading {
            ProgressView("Loading chats…")
                .frame(maxWidth: .infinity, minHeight: 140)
        } else if filteredItems.isEmpty {
            if hasSearch {
                emptyState("No matching chats", message: "Try another word from a title or chat.",
                           symbol: "magnifyingglass")
            } else if error == nil {
                emptyState("No chats yet", message: "Start a new chat with \(bot.name).",
                           symbol: "bubble.left.and.bubble.right")
            }
        } else {
            LazyVGrid(columns: textSize.isAccessibilitySize
                      ? [GridItem(.flexible(), alignment: .top)]
                      : [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 16) {
                ForEach(filteredItems) { item in
                    ChatPickerCard(item: item, transition: transition, preview: previews.image(for: item.id, colorScheme: colorScheme, textSize: textSize), onSelect: { onSelect(item.id) }, onSetPreferred: {
                        onSetPreferred(item.isPreferred ? nil : item.id)
                    }, onClose: { onClose(item.id) })
                    .id(item.id)
                }
            }
        }
    }

    private func emptyState(_ title: String, message: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.title).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }
}

struct ChatPickerCard: View {
    let item: ChatPickerItem
    let transition: ChatOverviewTransition
    let preview: UIImage?
    let onSelect: () -> Void
    let onSetPreferred: () -> Void
    var onClose: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cardButton
            if item.canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel("Close \(item.displayTitle)")
                .accessibilityHint("Keep its history and drafts. Reopen it from Closed chats.")
                .accessibilityIdentifier("close-chat-\(item.id)")
                .padding(4)
            }
        }
    }

    private var cardButton: some View {
        Button {
            guard item.isAvailable else { return }
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                previewCanvas
                HStack(alignment: .top, spacing: 8) {
                    Text(item.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    indicators
                }
                metadata
            }
            .multilineTextAlignment(.leading)
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .foregroundStyle(BottoTheme.ink)
            .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(item.isSelected ? BottoTheme.action : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isAvailable)
        .contextMenu {
            Button(item.preferredActionTitle, systemImage: item.isPreferred ? "pin.slash" : "pin") {
                onSetPreferred()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(previewAccessibilityValue)
        .accessibilityHint(item.isAvailable ? "Open this chat." : "This chat is not available to open.")
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .accessibilityAction(named: item.preferredActionTitle, onSetPreferred)
        .accessibilityIdentifier("chat-card-\(item.id)")
    }

    private var indicators: some View {
        HStack(spacing: 8) {
            if item.isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(BottoTheme.action) }
            if item.isPreferred { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
            if item.isUnread {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(BottoTheme.attention)
            }
            if item.status == .waiting {
                Image(systemName: BottoTheme.needsYouSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BottoTheme.attention)
                    .padding(6)
                    .background(BottoTheme.attentionSurface, in: Circle())
            }
        }
        .font(.caption)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let status = item.statusLabel, item.status != .waiting {
                Label(status, systemImage: statusSymbol)
            }
            if !item.isAvailable { Label("Unavailable", systemImage: "exclamationmark.circle") }
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusSymbol: String {
        item.activity.symbol
    }

    private var previewCanvas: some View {
        GeometryReader { geometry in
            Group {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                } else {
                    ChatTabExcerpt(item: item)
                        .frame(width: 390, height: 560, alignment: .top)
                        .scaleEffect(geometry.size.width / 390, anchor: .topLeading)
                }
            }
            .opacity(transition.hasNativePreview(for: item.id) ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .aspectRatio(390.0 / 560, contentMode: .fit)
        .overlay(ChatOverviewCardAnchor(id: item.id, transition: transition))
        .clipped()
        .background(BottoTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("chat-preview-\(item.id)")
    }

    private var previewAccessibilityValue: String {
        [item.userPreview.isEmpty ? nil : "You: \(item.userPreview)",
         item.replyPreview.isEmpty ? nil : "Preview: \(item.replyPreview)"]
            .compactMap { $0 }.joined(separator: ". ")
    }
}

/// Memory-only captures retain pixels, never a chat's view, renderer, or reader.
@MainActor @Observable final class ChatTabPreviews {
    private struct Entry {
        let image: UIImage
        let colorScheme: ColorScheme
        let textSize: DynamicTypeSize
        let cost: Int
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var cost = 0
    private let costLimit = 8 * 1_024 * 1_024

    func image(for id: String, colorScheme: ColorScheme, textSize: DynamicTypeSize) -> UIImage? {
        guard let entry = entries[id], entry.colorScheme == colorScheme, entry.textSize == textSize else { return nil }
        return entry.image
    }

    func capture(_ image: UIImage, id: String, colorScheme: ColorScheme, textSize: DynamicTypeSize) {
        guard let pixels = image.cgImage else { return }
        let imageCost = pixels.bytesPerRow * pixels.height
        guard imageCost <= costLimit else { return }
        if let previous = entries.removeValue(forKey: id) { cost -= previous.cost }
        order.removeAll { $0 == id }; order.append(id)
        entries[id] = Entry(image: image, colorScheme: colorScheme, textSize: textSize, cost: imageCost)
        cost += imageCost
        while cost > costLimit || order.count > 12 {
            if let removed = entries.removeValue(forKey: order.removeFirst()) { cost -= removed.cost }
        }
    }

    func removeAll() { entries = [:]; order = []; cost = 0 }
}

private struct ChatTabExcerpt: View {
    let item: ChatPickerItem
    var body: some View {
        VStack(spacing: 14) {
            if !item.userPreview.isEmpty {
                MessageView(message: .init(id: "preview-user", role: .user,
                                           text: String(item.userPreview.prefix(200))), rendersRichContent: false)
            }
            if !item.replyPreview.isEmpty {
                MessageView(message: .init(id: "preview-assistant", role: .assistant,
                                           text: String(item.replyPreview.prefix(512))), rendersRichContent: false)
            }
            if item.userPreview.isEmpty && item.replyPreview.isEmpty {
                ContentUnavailableView("No saved messages yet", systemImage: "bubble.left.and.bubble.right")
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BottoTheme.paper)
        .dynamicTypeSize(.large)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension View {
    @ViewBuilder func tabControlGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26, *) {
            if interactive { glassEffect(.regular.interactive(), in: shape) }
            else { glassEffect(.regular, in: shape) }
        } else { background(.regularMaterial, in: shape) }
    }
}
