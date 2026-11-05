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

struct ChatCloseNotice: Identifiable, Equatable {
    let id = UUID()
    let chatID: String
}

/// A bot-scoped tab overview. Ordering, availability and effects belong to the caller.
struct ChatPickerView: View {
    let bot: BotProfile
    let items: [ChatPickerItem]
    let previews: ChatTabPreviews
    let transition: ChatOverviewTransition
    let onDone: () -> Void
    let closedItems: [ChatPickerItem]
    let closeNotice: ChatCloseNotice?
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingCloseID: String?
    @State private var search = ""
    @State private var connectionRequested = false
    @State private var refreshRequested = false
    @State private var showsClosedChats = false
    @State private var presentedSnackbarItem: ChatPickerItem?
    @Namespace private var footerGlassNamespace

    init(bot: BotProfile, items: [ChatPickerItem], previews: ChatTabPreviews,
         transition: ChatOverviewTransition, onDone: @escaping () -> Void, headerClearance: CGFloat = 56,
         isLoading: Bool = false, isConnected: Bool = true, isCreating: Bool = false, canCreate: Bool = true,
         error: String? = nil, connectionFeedback: ConnectionStatusView? = nil,
         onSelect: @escaping (String) -> Void, onCreate: @escaping () -> Void,
         onSetPreferred: @escaping (String?) -> Void, onRefresh: @escaping () -> Void,
         closedItems: [ChatPickerItem] = [], closeNotice: ChatCloseNotice? = nil,
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
        self.closeNotice = closeNotice
        self.onClose = onClose; self.onReopen = onReopen
    }

    private var filteredItems: [ChatPickerItem] { items.filter { $0.matches(search: search) } }
    private var hasSearch: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var snackbarItem: ChatPickerItem? { closedItems.first { $0.id == closeNotice?.chatID } }

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
        .onChange(of: closeNotice?.id) { _, _ in
            guard let item = closedItems.first(where: { $0.id == closeNotice?.chatID }) else { return }
            AccessibilityNotification.Announcement("\(item.displayTitle) closed. History and drafts saved. Undo available.").post()
        }
        // Start footer transitions after UIKit has replaced the hosted content.
        .task(id: closedItems.isEmpty) {
            guard !Task.isCancelled else { return }
            withAnimation(footerAnimation) { showsClosedChats = !closedItems.isEmpty }
        }
        .task(id: snackbarItem) {
            guard !Task.isCancelled else { return }
            withAnimation(footerAnimation) { presentedSnackbarItem = snackbarItem }
        }
        .onChange(of: search) { _, _ in confirmingCloseID = nil }
        .onChange(of: items) { _, items in
            if !items.contains(where: { $0.id == confirmingCloseID && $0.canClose }) { confirmingCloseID = nil }
        }
        .onChange(of: isConnected) { _, _ in
            connectionRequested = false; refreshRequested = false
        }
        .onChange(of: isLoading) { _, loading in
            if !loading { refreshRequested = false }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 8) { bottomBarContent }
        } else {
            bottomBarContent
        }
    }

    private var bottomBarContent: some View {
        HStack(spacing: 12) {
            ZStack {
                if showsClosedChats {
                    Menu {
                        Section("Closed chats on this device") {
                            ForEach(closedItems) { item in
                                Button(item.displayTitle) { onReopen(item.id) }
                                    .accessibilityIdentifier("reopen-chat-\(item.id)")
                            }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .dynamicTypeSize(Self.footerGlyphTextSizes)
                            .frame(width: 48, height: 48)
                    }
                    .tabFooterGlass(in: Circle(), id: "history", namespace: footerGlassNamespace,
                                    reduceMotion: reduceMotion)
                    .accessibilityLabel("Closed chats")
                    .accessibilityIdentifier("closed-chats")
                }
            }
            .frame(width: 48, height: 48)
            ZStack {
                if let item = presentedSnackbarItem {
                    closeSnackbar(item)
                        .id(item.id)
                        .zIndex(1)
                } else {
                    Text(chatCount).foregroundStyle(.secondary)
                        .font(.footnote)
                        .accessibilityIdentifier("chat-count")
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            createButton.frame(width: 48, height: 48)
                .tabFooterGlass(in: Circle(), id: "new-chat", namespace: footerGlassNamespace,
                                reduceMotion: reduceMotion)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    /// Larger symbols leave the footer's 48-point circles.
    private static let footerGlyphTextSizes = ...DynamicTypeSize.accessibility1

    private var footerAnimation: Animation {
        reduceMotion ? .easeOut : .default
    }

    private func closeSnackbar(_ item: ChatPickerItem) -> some View {
        let layout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text("Chat closed")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(textSize.isAccessibilitySize ? 2 : 1)
                Text(item.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(textSize.isAccessibilitySize ? 2 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button { onReopen(item.id) } label: {
                Text("Undo")
                    .font(.footnote.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44,
                           alignment: textSize.isAccessibilitySize ? .leading : .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(BottoTheme.action)
            .accessibilityIdentifier("undo-close-chat")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .tabFooterGlass(in: RoundedRectangle(cornerRadius: 28), id: "close-notice",
                        namespace: footerGlassNamespace, reduceMotion: reduceMotion, interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-close-snackbar")
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
                    Image(systemName: "plus").dynamicTypeSize(Self.footerGlyphTextSizes)
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
                    }, onClose: {
                        confirmingCloseID = nil
                        onClose(item.id)
                    }, confirmsClose: Binding(get: { confirmingCloseID == item.id }, set: {
                        confirmingCloseID = $0 ? item.id : nil
                    }))
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
    @Binding var confirmsClose: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(item: ChatPickerItem, transition: ChatOverviewTransition, preview: UIImage?,
         onSelect: @escaping () -> Void, onSetPreferred: @escaping () -> Void,
         onClose: @escaping () -> Void = {}, confirmsClose: Binding<Bool> = .constant(false)) {
        self.item = item; self.transition = transition; self.preview = preview
        self.onSelect = onSelect; self.onSetPreferred = onSetPreferred; self.onClose = onClose
        self._confirmsClose = confirmsClose
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cardButton
            if item.canClose {
                closeControl
                    .padding(4)
            }
        }
    }

    private var closeControl: some View {
        Button {
            if confirmsClose { onClose() }
            else { confirmsClose = true }
        } label: {
            Group {
                if confirmsClose {
                    Text("Close")
                        .padding(.horizontal, 14)
                        .transition(.opacity)
                } else {
                    Image(systemName: "xmark")
                        .transition(.opacity)
                }
            }
            .font(.footnote.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(confirmsClose ? BottoTheme.action : BottoTheme.ink)
        .tabControlGlass(in: Capsule())
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: confirmsClose)
        .accessibilityLabel(confirmsClose ? "Confirm closing \(item.displayTitle)" : "Close \(item.displayTitle)")
        .accessibilityHint(confirmsClose
                          ? "Tap again to close. Tap the chat card to cancel. History and drafts are kept."
                          : "Ask to close this chat. History and drafts are kept.")
        .accessibilityValue(confirmsClose ? "Confirmation required" : "")
        .accessibilityIdentifier(confirmsClose ? "confirm-close-chat-\(item.id)" : "close-chat-\(item.id)")
        .accessibilityAction(.escape) { confirmsClose = false }
    }

    private var cardButton: some View {
        Button {
            if confirmsClose { confirmsClose = false; return }
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
        .disabled(!item.isAvailable && !confirmsClose)
        .contextMenu {
            Button(item.preferredActionTitle, systemImage: item.isPreferred ? "pin.slash" : "pin") {
                onSetPreferred()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(previewAccessibilityValue)
        .accessibilityHint(confirmsClose ? "Cancel closing this chat."
                           : item.isAvailable ? "Open this chat." : "This chat is not available to open.")
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
    @ViewBuilder func tabFooterGlass<S: Shape>(in shape: S, id: String, namespace: Namespace.ID,
                                               reduceMotion: Bool, interactive: Bool = true) -> some View {
        if #available(iOS 26, *) {
            tabControlGlass(in: shape, interactive: interactive)
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
                .transition(.opacity)
        } else {
            tabControlGlass(in: shape, interactive: interactive)
                .transition(.opacity)
        }
    }

    @ViewBuilder func tabControlGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26, *) {
            if interactive { glassEffect(.regular.interactive(), in: shape) }
            else { glassEffect(.regular, in: shape) }
        } else { background(.regularMaterial, in: shape) }
    }
}
