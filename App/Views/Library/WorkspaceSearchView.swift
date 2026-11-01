import SwiftUI
import BottoCore

struct WorkspaceSearchView: View {
    let store: AppStore
    let library: WorkspaceLibrary
    @Binding var query: String
    let onBot: (BotProfile) -> Void
    let onChat: (LibraryChat) -> Void
    let onArtifact: (LibraryArtifact) -> Void
    let onMessage: (SearchMessageTarget) -> Void
    @State private var thumbnails = LibraryThumbnails()
    @Environment(\.scenePhase) private var scenePhase

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let results = LibrarySearchResults(query: term, bots: store.bots, chats: library.chats, artifacts: library.artifacts)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.isDemo { DemoBanner().padding(.horizontal, -20) }
                    LibraryStatus(library: library, refresh: { await store.refreshLibrary(force: true) })
                    if term.isEmpty {
                        if !library.chats.isEmpty {
                            searchSection("Recent chats") {
                                ForEach(library.chats.prefix(8)) { chat in chatButton(chat) }
                            }
                        } else if library.isLoading {
                            ProgressView("Finding chats…").frame(maxWidth: .infinity).padding(.vertical, 48)
                        } else {
                            ContentUnavailableView("Everything, within reach", systemImage: "magnifyingglass",
                                description: Text("Find a bot, a conversation, or something they made."))
                        }
                    } else {
                        if !results.bots.isEmpty {
                            searchSection("Bots") {
                                ForEach(results.bots) { bot in botButton(bot) }
                            }
                        }
                        if !results.chats.isEmpty {
                            searchSection("Chats") {
                                ForEach(results.chats) { chat in chatButton(chat) }
                            }
                        }
                        if !results.artifacts.isEmpty {
                            searchSection("Artifacts") {
                                ForEach(results.artifacts) { item in artifactButton(item) }
                            }
                        }
                        if !results.messages.isEmpty {
                            searchSection("Messages") {
                                ForEach(results.messages) { match in messageButton(match) }
                            }
                            if results.hasMoreMessages {
                                Text("Showing the first 50 matching messages. Refine your search to find more.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BottoTheme.paper)
            .overlay {
                if !term.isEmpty && results.isEmpty {
                    if library.isLoading { ProgressView("Searching chats…") }
                    else { ContentUnavailableView.search(text: term) }
                }
            }
            .navigationTitle("Search")
            .bottoNavigationChrome()
            .accessibilityIdentifier("workspace-search")
            .refreshable { await store.refreshLibrary(force: true) }
        }
        .searchable(text: $query, prompt: "Bots, chats, and artifacts")
        .background {
            LibraryPreviewThumbnailHost(renderer: thumbnails.previews, isActive: scenePhase == .active)
                .frame(width: 400, height: 284).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func searchSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
        } header: {
            Text(title).font(.headline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func botButton(_ bot: BotProfile) -> some View {
        Button { onBot(bot) } label: {
            HStack(alignment: .top, spacing: 14) {
                AppBotAvatar(store: store, bot: bot, size: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    SearchHighlightedText(text: bot.name, query: term).font(.headline)
                    if !bot.description.isEmpty {
                        SearchHighlightedText(text: bot.description, query: term)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain).accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-bot-\(bot.id)")
    }

    private func chatButton(_ chat: LibraryChat) -> some View {
        let main = chat.title == "Main"
        return Button { onChat(chat) } label: {
            HStack(alignment: .top, spacing: 14) {
                SearchChatAvatar(store: store, chat: chat)
                VStack(alignment: .leading, spacing: 5) {
                    SearchHighlightedText(text: main ? chat.botName : chat.title, query: term).font(.headline).lineLimit(2)
                    SearchHighlightedText(text: main ? chat.title : chat.botName, query: term)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if let preview = ConversationPreview.latest(in: chat.messages) {
                        SearchHighlightedText(text: preview.text, query: term)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain).accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-chat-\(chat.title)")
    }

    private func artifactButton(_ item: LibraryArtifact) -> some View {
        Button { onArtifact(item) } label: {
            HStack(alignment: .center, spacing: 14) {
                SearchArtifactCover(item: item, library: library, thumbnails: thumbnails)
                VStack(alignment: .leading, spacing: 6) {
                    SearchHighlightedText(text: item.artifact.title, query: term)
                        .font(.subheadline.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                    Text(item.chat.botName + " · " + item.chat.title)
                        .font(.caption).foregroundStyle(.secondary)
                    if item.artifact.category == .reference {
                        Text("Reference").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-search-artifact-\(item.artifact.title)")
    }

    private func messageButton(_ match: LibrarySearchResults.MessageMatch) -> some View {
        Button { onMessage(.init(chat: match.chat, message: match.message, query: term)) } label: {
            SearchMessagePreview(store: store, match: match, query: term)
        }
        .buttonStyle(.plain).accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-message-\(match.message.id)")
    }
}

private struct SearchChatAvatar: View {
    let store: AppStore
    let chat: LibraryChat
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        Group {
            if let bot = store.bot(withID: chat.botID) {
                BotAvatar(profile: bot, image: store.avatar(for: bot), size: size, motion: .still)
            } else {
                Text(String(chat.botName.prefix(1)).uppercased())
                    .font(.headline).foregroundStyle(BottoTheme.action)
                    .frame(width: size, height: size).background(BottoTheme.surface, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SearchArtifactCover: View {
    let item: LibraryArtifact
    let library: WorkspaceLibrary
    let thumbnails: LibraryThumbnails
    @State private var cover: (content: LibraryThumbnails.Content, image: UIImage)?
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 72

    var body: some View {
        ZStack {
            BottoTheme.surface
            if let cover, cover.content.representsSameSource(as: request.content) {
                Image(uiImage: cover.image).resizable().scaledToFit().padding(6)
            } else {
                Image(systemName: item.artifact.kind.librarySymbol)
                    .font(.title2).foregroundStyle(BottoTheme.action)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
        .task(id: request) {
            guard LibraryThumbnails.supports(item) else { return }
            let content = request.content
            let image = await thumbnails.image(for: item, library: library)
            guard !Task.isCancelled, library.isCurrent(item), let image else { return }
            cover = (content, image)
        }
    }

    private var request: LibraryThumbnails.Request {
        LibraryThumbnails.request(for: item, library: library, rendererRevision: thumbnails.previews.mountRevision)
    }
}

private struct SearchMessagePreview: View {
    let store: AppStore
    let match: LibrarySearchResults.MessageMatch
    let query: String
    private var outgoing: Bool { match.message.isOutgoingUserMessage }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SearchChatAvatar(store: store, chat: match.chat)
                VStack(alignment: .leading, spacing: 4) {
                    Text(match.chat.botName).font(.subheadline.weight(.semibold))
                    Text(match.chat.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                if outgoing { Spacer(minLength: 24) }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(outgoing ? "You" : (match.message.botSender?.name ?? "Reply"))
                            .fontWeight(.medium)
                        if let date = match.message.timestamp {
                            Text(date, style: .date)
                        }
                    }
                    .font(.caption).foregroundStyle(outgoing ? BottoTheme.onOutgoing.opacity(0.8) : .secondary)
                    SearchHighlightedText(text: match.snippet, query: query)
                        .font(.body).lineSpacing(3).lineLimit(5)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .foregroundStyle(outgoing ? BottoTheme.onOutgoing : BottoTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(outgoing ? BottoTheme.outgoing : BottoTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                if !outgoing { Spacer(minLength: 12) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

struct SearchHighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(Self.attributed(text, query: query))
    }

    static func attributed(_ text: String, query: String) -> AttributedString {
        var value = AttributedString(text)
        guard !query.isEmpty else { return value }
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: cursor..<text.endIndex, locale: .current), !match.isEmpty {
            if let range = Range(match, in: value) {
                value[range].backgroundColor = BottoTheme.selection
                value[range].foregroundColor = BottoTheme.ink
                value[range].inlinePresentationIntent = .stronglyEmphasized
            }
            cursor = match.upperBound
        }
        return value
    }
}

struct LibrarySearchResults {
    struct MessageMatch: Identifiable {
        struct ID: Hashable { let chat: LibraryChat.ID; let message: Data }
        let chat: LibraryChat
        let message: ChatMessage
        let snippet: String
        var id: ID { ID(chat: chat.id, message: Data(message.id.utf8)) }
    }

    let bots: [BotProfile]
    let chats: [LibraryChat]
    let artifacts: [LibraryArtifact]
    let messages: [MessageMatch]
    let hasMoreMessages: Bool
    var isEmpty: Bool { bots.isEmpty && chats.isEmpty && artifacts.isEmpty && messages.isEmpty }

    init(query: String, bots: [BotProfile], chats: [LibraryChat], artifacts: [LibraryArtifact]) {
        guard !query.isEmpty else {
            self.bots = []; self.chats = []; self.artifacts = []; messages = []; hasMoreMessages = false
            return
        }
        self.bots = bots.filter { $0.name.localizedStandardContains(query) || $0.description.localizedStandardContains(query) }
        self.chats = chats.filter { $0.title.localizedStandardContains(query) }
        self.artifacts = artifacts.filter {
            $0.artifact.title.localizedStandardContains(query) || $0.artifact.searchableText.localizedStandardContains(query)
        }
        var matches: [MessageMatch] = []
        var overflow = false
        for chat in chats {
            for message in chat.messages.reversed() {
                guard let readable = chat.searchableText[Data(message.id.utf8)]?.first(where: {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
                }) else { continue }
                guard matches.count < 50 else { overflow = true; break }
                matches.append(MessageMatch(chat: chat, message: message, snippet: Self.snippet(readable, query: query)))
            }
            if overflow { break }
        }
        messages = matches
        hasMoreMessages = overflow
    }

    private static func snippet(_ text: String, query: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let range = collapsed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(collapsed.prefix(160))
        }
        let start = collapsed.index(range.lowerBound, offsetBy: -45, limitedBy: collapsed.startIndex) ?? collapsed.startIndex
        let end = collapsed.index(range.upperBound, offsetBy: 100, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        return (start == collapsed.startIndex ? "" : "…") + collapsed[start..<end] + (end == collapsed.endIndex ? "" : "…")
    }
}
