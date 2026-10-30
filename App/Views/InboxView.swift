import SwiftUI
import BottoCore

struct InboxView: View {
    @Bindable var store: AppStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var onSettings: () -> Void
    var onNewBot: () -> Void
    var onOpened: () -> Void = {}
    var isExposed = true
    @State private var hiddenEntries: [AppStore.InboxEntry] = []

    var body: some View {
        let entries = isExposed ? store.inbox : hiddenEntries
        let bots = entries.map(\.bot)
        let pinned = bots.filter { store.isPinned($0) }
        let lastBotID = entries.last?.id
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.isDemo { DemoBanner().padding(.horizontal, -20).padding(.bottom, 20) }
                if let notice = store.notice {
                    InlineNotice(message: notice) { store.notice = nil }.padding(.bottom, 16)
                }
                if !dynamicTypeSize.isAccessibilitySize && !pinned.isEmpty {
                    pinnedRail(pinned).padding(.bottom, 25)
                }
                if entries.isEmpty {
                    emptyState.padding(.vertical, 38).frame(maxWidth: .infinity)
                } else {
                    ForEach(entries) { entry in
                        let bot = entry.bot
                        Button { open(bot) } label: {
                            BotRow(bot: bot, image: store.avatar(for: bot), store: store, unread: entry.isUnread,
                                   aggregate: entry.aggregate)
                        }
                        .buttonStyle(BotRowButtonStyle())
                        .accessibilityIdentifier("bot-row-\(bot.id)")
                        .contextMenu {
                            if entry.aggregate?.attentionChat != nil {
                                Button("Needs you", systemImage: BottoTheme.needsYouSymbol) { open(bot, attention: true) }
                            }
                            Button(store.isPinned(bot) ? "Unpin bot" : "Pin bot", systemImage: store.isPinned(bot) ? "pin.slash" : "pin") {
                                store.togglePin(bot)
                            }
                        }
                        .accessibilityAction(named: store.isPinned(bot) ? "Unpin" : "Pin") { store.togglePin(bot) }
                        if bot.id != lastBotID {
                            Divider().padding(.leading, 74)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
            .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("bot-inbox")
        .background(BottoTheme.paper, ignoresSafeAreaEdges: [])
        .onChange(of: isExposed, initial: true) { _, exposed in
            if !exposed { hiddenEntries = store.inbox }
        }
        .refreshable { await store.refresh(revalidateAvatars: true) }
        .task(id: store.isConnected && isExposed) {
            guard store.isConnected && isExposed else { return }
            // Hermes doesn't broadcast every other bot's in-memory approval state.
            // Sample while the inbox is visible; disappearing or going offline cancels it.
            await store.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled, isExposed else { return }
                await store.refresh()
            }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape", action: onSettings)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New bot", systemImage: "plus") { onNewBot() }
            }
        }
    }
    private func open(_ bot: BotProfile, attention: Bool = false) {
        store.selectedBotID = bot.id
        let workspace = store.chats
        guard let profile = try? ExactID(bot.id),
              let intent = workspace.captureOpening(profile: profile, attention: attention) else { return }
        onOpened()
        Task { await workspace.open(intent) }
    }

    private func pinnedRail(_ pinned: [BotProfile]) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(pinned) { bot in
                        Button { open(bot) } label: {
                            VStack(spacing: 9) {
                                AppBotAvatar(store: store, bot: bot, size: 70, fitsBody: true)
                                    .frame(height: 70, alignment: .top)
                                Text(bot.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(width: 82)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Unpin bot", systemImage: "pin.slash") { store.togglePin(bot) } }
                        .accessibilityLabel("\(bot.name), pinned")
                        .accessibilityValue(store.avatarPresentation(for: bot).accessibilityStatus ?? "")
                        .accessibilityIdentifier("pinned-bot-\(bot.id)")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, pinnedCuePadding)
            }
            .scrollIndicators(.hidden)
            .clipped()
            .padding(.horizontal, -20)
        }
    }
    private var pinnedCuePadding: CGFloat { 20 }
    @ViewBuilder private var emptyState: some View {
        if store.isRefreshing || store.link == .connecting {
            VStack(spacing: 16) {
                BotAvatar(profile: BotProfile(id: "loading", name: ""), size: 64)
                Text("Finding your bots…").font(.headline)
                Text("They’ll be right here.").foregroundStyle(.secondary)
            }
        } else if !store.isConnected {
            ConnectionStatusView(store: store)
        } else {
            VStack(spacing: 16) {
                BotAvatar(profile: BotProfile(id: "first-bot", name: ""), size: 84)
                Text("Meet your first helper.").font(.title2.weight(.semibold))
                Text(store.isConnected ? "Give a bot a name and a little job to do." : "Reconnect to find your bots.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if store.isConnected {
                    Button("Create a bot") { onNewBot() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
    }
}

private struct BotRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? BottoTheme.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 18))
    }
}

struct BotRow: View {
    let bot: BotProfile
    let image: UIImage?
    var store: AppStore? = nil
    let unread: Bool
    let aggregate: ChatAggregate?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var preview: String {
        let summary = ReplyContent.summary(bot.preview)
        return summary.isEmpty ? ReplyContent.summary(bot.description) : summary
    }
    private func timeLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        avatar
                        Spacer(minLength: 0)
                        unreadIndicator
                    }
                    content
                }
            } else {
                HStack(alignment: .top, spacing: 15) {
                    avatar
                    content
                    unreadIndicator
                }
            }
        }
        .padding(.vertical, 17).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(store?.avatarPresentation(for: bot).accessibilityStatus ?? "")
    }
    @ViewBuilder private var avatar: some View {
        if let store {
            AppBotAvatar(store: store, bot: bot, size: 56)
        } else {
            BotAvatar(profile: bot, image: image, size: 56)
        }
    }
    private var content: some View {
        let preview = preview
        return VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    Text(bot.name).font(.headline).foregroundStyle(BottoTheme.ink)
                    if let date = bot.updatedAt {
                        Text(timeLabel(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(bot.name).font(.headline).foregroundStyle(BottoTheme.ink).lineLimit(2)
                    Spacer(minLength: 4)
                    if let date = bot.updatedAt {
                        Text(timeLabel(date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(preview.isEmpty ? (aggregate?.hasHistory != true && bot.preview.isEmpty && bot.updatedAt == nil ? "Start a chat" : "No recent message") : preview)
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .multilineTextAlignment(.leading)
            if let aggregate {
                if aggregate.count > 1 {
                    Text("\(aggregate.count) chats")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let label = aggregate.activity.label {
                    Label(label, systemImage: aggregate.activity.symbol)
                        .font(.caption.weight(aggregate.status == .waiting ? .medium : .regular))
                        .foregroundStyle(aggregate.status == .waiting ? BottoTheme.attention : .secondary)
                        .accessibilityLabel(aggregate.activity.accessibilityLabel ?? label)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var unreadIndicator: some View {
        if unread {
            Circle().fill(BottoTheme.attention).frame(width: 7, height: 7).padding(.top, 9)
                .accessibilityLabel("Unread")
        }
    }
}

struct ConnectionStatusView: View {
    let store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(store.link == .connecting ? "Connecting to your Hermes…" : "You’re offline",
                  systemImage: store.link == .connecting ? "network" : "wifi.slash")
                .font(.subheadline.weight(.semibold))
            Text("Try your action again once connected. Nothing will be sent automatically.")
                .font(.footnote).foregroundStyle(.secondary)
            if store.link != .connecting {
                if let error = store.connectionError {
                    Text(error).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                }
                Button("Reconnect") {
                    if let configuration = store.configuration { Task { await store.connect(configuration) } }
                }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("connection-feedback")
    }
}
