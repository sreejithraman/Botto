import SwiftUI
import BottoCore

/// Where a new space starts: a greeting, at most two quiet notes, an optional name, and a composer.
/// Without a name, T3 names the space from its first message.
struct T3FreshPage: View {
    let store: AppStore
    /// False while launch is still finding the main space, when there is nothing to name yet.
    let namesSpace: Bool
    let isExposed: Bool
    let onOpenChat: (T3ChannelSummary) -> Void
    let onStarted: () -> Void

    @Environment(\.t3Chrome) private var chrome
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum Field { case name, message }
    @FocusState private var focused: Field?
    @State private var name = ""
    @State private var draft = ""
    @State private var pendingModel: T3ModelOption?
    @State private var starting = false
    @State private var error: String?
    @State private var connectionRequested = false

    private var hasMessage: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasName: Bool { namesSpace && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A name alone is enough to make a space.
    private var canSend: Bool { (hasMessage || hasName) && !starting && isExposed }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    greeting
                    notes.padding(.top, 34)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
            .scrollDismissesKeyboard(.interactively)
            composer
        }
        .background(BottoTheme.paper)
        .accessibilityIdentifier("t3-fresh-page")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Spaces", systemImage: "line.3.horizontal") { focused = nil; chrome?.openDrawer() }
                    .accessibilityIdentifier("t3-open-drawer")
            }
        }
        .onChange(of: isExposed) { _, exposed in if !exposed { focused = nil } }
        .onChange(of: store.isConnected) { _, connected in if connected { connectionRequested = false } }
    }

    // MARK: Greeting

    private var greeting: some View {
        VStack(spacing: 6) {
            Button { focused = nil; chrome?.openBotto() } label: { face }
                .buttonStyle(.plain)
                .accessibilityLabel("\(store.primaryT3Bot?.name ?? "Botto")’s page")
                .accessibilityHint("Personality, memory, routines and files.")
                .accessibilityIdentifier("t3-fresh-face")
                .padding(.bottom, 16)
            Text(T3ChatShelf.greeting().localized)
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var face: some View {
        if let bot = store.primaryT3Bot {
            AppBotAvatar(store: store, bot: bot, size: 112, fitsBody: true)
                .frame(height: 112, alignment: .bottom)
        } else {
            BotAvatar(profile: BotProfile(id: "t3-waking", name: ""), size: 112,
                      presentation: store.isConnected || store.link == .connecting ? .idle : .offline)
                .frame(height: 112, alignment: .bottom)
        }
    }

    private var subtitle: String {
        if !store.isConnected, store.link != .connecting { return String(localized: "Napping until the host connects.") }
        return String(localized: "What are we getting into?")
    }

    // MARK: While you were away

    @ViewBuilder private var notes: some View {
        let away = T3ChatShelf.whileYouWereAway(store.t3Channels)
        if !away.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("While you were away").font(.footnote).foregroundStyle(.tertiary).padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(away) { channel in note(channel) }
            }
        }
    }

    private func note(_ channel: T3ChannelSummary) -> some View {
        Button { focused = nil; onOpenChat(channel) } label: {
            HStack(spacing: 12) {
                if channel.needsYou {
                    Text("?").font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(BottoTheme.action)
                        .frame(width: 28, height: 28).background(BottoTheme.selection, in: Circle())
                } else {
                    Circle().fill(BottoTheme.action).frame(width: 8, height: 8).frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(noteTitle(channel)).font(.subheadline.weight(.medium)).foregroundStyle(BottoTheme.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2).multilineTextAlignment(.leading)
                    Text(noteDetail(channel)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(BottoCardButtonStyle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open this space.")
        .accessibilityIdentifier("t3-away-\(channel.id)")
    }

    private func noteTitle(_ channel: T3ChannelSummary) -> String {
        let line = channel.preview.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !line.isEmpty { return line }
        return channel.needsYou ? String(localized: "Botto has a question") : String(localized: "Something new")
    }

    private func noteDetail(_ channel: T3ChannelSummary) -> String {
        if channel.needsYou { return String(localized: "\(channel.displayTitle) · waiting on you") }
        guard let date = channel.updatedAt else { return channel.displayTitle }
        return "\(channel.displayTitle) · \(T3TimeLabel.compact(date))"
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if connectionRequested, !store.isConnected {
                ConnectionStatusView(store: store).padding(.horizontal, 16)
            }
            if let error {
                InlineNotice(message: error) { self.error = nil }.padding(.horizontal, 16)
            }
            if namesSpace { nameField }
            VStack(alignment: .leading, spacing: 2) {
                TextField("Message \(store.primaryT3Bot?.name ?? "Botto")", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused, equals: .message)
                    .disabled(starting)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
                    .accessibilityIdentifier("t3-fresh-composer")
                HStack(spacing: 6) {
                    Menu {
                        Button("Photo library", systemImage: "photo") { startWithAttachment(.photos) }
                        Button("Choose a file", systemImage: "doc") { startWithAttachment(.files) }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 17, weight: .medium)).frame(width: 36, height: 36)
                            .background(BottoTheme.paper, in: Circle())
                            .frame(width: 44, height: 44).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(starting || !isExposed)
                    .accessibilityLabel("Add attachment")
                    T3ModelChip(store: store, pending: $pendingModel)
                    Spacer(minLength: 0)
                    Button(action: send) {
                        Group {
                            if starting { ProgressView().tint(BottoTheme.onAction) }
                            else { Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)) }
                        }
                        .foregroundStyle(canSend || starting ? BottoTheme.onAction : BottoTheme.disabledForeground)
                        .frame(width: 44, height: 44)
                        .background(canSend || starting ? BottoTheme.action : .clear, in: Circle())
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel(starting ? "Starting space" : hasMessage || !hasName ? "Send message" : "Create space")
                    .accessibilityIdentifier("t3-fresh-send")
                }
            }
            .padding(6)
            .controlGlass(in: RoundedRectangle(cornerRadius: 26))
            .padding(.horizontal, 12).padding(.bottom, 8)
            .frame(maxWidth: 780)
        }
        .frame(maxWidth: .infinity)
    }

    /// Quiet on purpose: a name is an option, not a step.
    private var nameField: some View {
        TextField("Name this space (optional)", text: $name)
            .font(.subheadline.weight(.medium))
            .focused($focused, equals: .name)
            .submitLabel(.next)
            .onSubmit { focused = .message }
            .disabled(starting)
            .padding(.horizontal, 26).frame(minHeight: 44)
            .frame(maxWidth: 780)
            .accessibilityIdentifier("t3-space-name")
    }

    private func send() {
        guard canSend else { return }
        start(text: draft, send: hasMessage, attachment: nil)
    }

    private func startWithAttachment(_ kind: AppStore.T3ComposerRequest.Kind) {
        guard !starting, isExposed else { return }
        start(text: draft, send: false, attachment: kind)
    }

    private func start(text: String, send: Bool, attachment: AppStore.T3ComposerRequest.Kind?) {
        guard store.isConnected else { connectionRequested = true; return }
        focused = nil
        starting = true
        error = nil
        let workspace = store.chats
        let model = pendingModel
        Task {
            defer { starting = false }
            do {
                let started = try await store.startT3Space(named: namesSpace ? name : "", with: text, model: model, send: send)
                guard store.chats === workspace, let selection = workspace.selection(profile: started.profile),
                      selection.identity == started, workspace.isCurrent(selection.owner) else { return }
                name = ""
                draft = ""
                pendingModel = nil
                store.t3ComposerRequest = attachment.map { .init(kind: $0, owner: selection.owner) }
                onStarted()
            } catch where store.chats === workspace {
                self.error = error.localizedDescription
                if !store.isConnected { connectionRequested = true }
            } catch { }
        }
    }
}

extension T3ChatShelf.Greeting {
    var localized: String {
        switch self {
        case .morning: String(localized: "Morning.")
        case .afternoon: String(localized: "Afternoon.")
        case .evening: String(localized: "Evening.")
        }
    }
}
