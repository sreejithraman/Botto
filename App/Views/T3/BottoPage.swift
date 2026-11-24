import SwiftUI
import BottoCore

@MainActor @Observable final class T3BrainDrafts {
    var soul = ""
    var memory = ""
    var soulAutosave: T3Autosave?
    var memoryAutosave: T3Autosave?
    var name = ""
    var nameError: String?
    var submittedName: String?
    @ObservationIgnored var nameSave: Task<Void, Never>?
}

/// One page for who Botto is: face and name, personality, memory, routines, skills,
/// the files it made, and one quiet Advanced row. Edits save on their own.
struct BottoPage: View {
    let store: AppStore
    let outputs: T3OutputsModel
    @Bindable var drafts: T3BrainDrafts
    let onOpenChat: (T3ChannelSummary) -> Void
    var onSettings: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var brain: T3BotBrainSnapshot?
    @State private var routines: [T3ScheduledRoutine]?
    @State private var routinesError: String?
    @State private var latestRoutineRead = UUID()
    @State private var loadError: String?
    @State private var retry = 0
    @State private var openedOutput: T3OutputFile?
    @FocusState private var editingName: Bool
    private let workspace: ConversationWorkspace

    private struct BrainLoad: Equatable { let online: Bool; let retry: Int }

    init(store: AppStore, outputs: T3OutputsModel, drafts: T3BrainDrafts, onOpenChat: @escaping (T3ChannelSummary) -> Void,
         onSettings: (() -> Void)? = nil) {
        self.store = store
        self.outputs = outputs
        self.drafts = drafts
        self.onOpenChat = onOpenChat
        self.onSettings = onSettings
        workspace = store.chats
    }

    private var isCurrent: Bool { store.chats === workspace }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    if !store.isConnected, brain == nil { ConnectionStatusView(store: store).padding(.top, 16) }
                    if let loadError, brain == nil {
                        VStack(alignment: .leading, spacing: 10) {
                            InlineNotice(message: loadError)
                            Button("Try again", systemImage: "arrow.clockwise") { retry += 1 }
                                .buttonStyle(BottoPillButtonStyle())
                        }
                        .padding(.top, 16)
                    }
                    if let error = drafts.nameError {
                        InlineNotice(message: error) { drafts.nameError = nil }.padding(.top, 16)
                    }
                    rows.padding(.top, 18)
                    shelf.padding(.top, 22)
                    advancedRow.padding(.top, 22)
                }
                .padding(.horizontal, 20).padding(.bottom, 32)
                .frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BottoTheme.paper)
            .bottoNavigationChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commitName(); dismiss() }.accessibilityIdentifier("botto-page-done")
                }
            }
            .navigationDestination(for: Destination.self) { destination(for: $0) }
            .tint(BottoTheme.action)
        }
        .presentationBackground(BottoTheme.paper)
        .presentationCornerRadius(38)
        .accessibilityIdentifier("botto-page")
        .sheet(item: $openedOutput) { T3OutputPreview(store: store, output: $0) }
        .task(id: BrainLoad(online: store.isConnected, retry: retry)) { await load() }
        .task(id: store.isConnected) { await loadRoutines() }
        .task(id: store.isConnected) { await outputs.load(store) }
        .onChange(of: store.primaryT3Bot?.name) { _, value in
            if !editingName, drafts.submittedName == nil, drafts.nameError == nil, let value { drafts.name = value }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 0) {
            Group {
                if let bot = store.primaryT3Bot {
                    AppBotAvatar(store: store, bot: bot, size: 112, fitsBody: true)
                } else {
                    BotAvatar(profile: BotProfile(id: "t3-botto", name: ""), size: 112,
                              presentation: store.isConnected ? .idle : .offline)
                }
            }
            .frame(height: 112, alignment: .bottom)
            .accessibilityHidden(true)
            TextField("Name", text: $drafts.name)
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .multilineTextAlignment(.center)
                .textContentType(.nickname)
                .submitLabel(.done)
                .focused($editingName)
                .onSubmit(commitName)
                .padding(.top, 14)
                .accessibilityLabel("Name")
                .accessibilityIdentifier("botto-page-name")
            if let bot = store.primaryT3Bot, store.avatarDestination(for: bot) != nil {
                NavigationLink(value: Destination.look) {
                    Text("Change look").font(.subheadline.weight(.semibold)).foregroundStyle(BottoTheme.action)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("botto-page-change-look")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .onAppear { if drafts.name.isEmpty { drafts.name = store.primaryT3Bot?.name ?? "" } }
    }

    // MARK: Rows

    private enum Destination: Hashable {
        case personality, memory, routines, skills, files, advanced, look
    }

    private var rows: some View {
        VStack(spacing: 0) {
            row(.personality, title: "Personality", detail: T3BrainText.personalitySummary(drafts.soul), loaded: drafts.soulAutosave != nil)
            row(.memory, title: "What Botto remembers", detail: T3BrainText.memorySummary(drafts.memory), loaded: drafts.memoryAutosave != nil)
            if !store.isDemo {
                row(.routines, title: "Routines", detail: routineSummary, loaded: true)
            }
            row(.skills, title: "Skills", detail: skillsSummary, loaded: brain != nil, last: true)
        }
    }

    private func row(_ destination: Destination, title: LocalizedStringKey, detail: String, loaded: Bool,
                     last: Bool = false) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(BottoTheme.ink)
                    Text(loaded ? detail : String(localized: "Loading…"))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(.separator).frame(height: 0.5) }
        }
        .disabled(!loaded && destination != .routines)
        .accessibilityIdentifier("botto-page-row-\(String(describing: destination))")
    }

    private var routineSummary: String {
        if routines == nil, routinesError != nil { return String(localized: "Couldn’t load routines") }
        if routines == nil, !store.isConnected { return String(localized: "Connect to see routines") }
        guard let routines else { return String(localized: "Loading…") }
        let active = routines.filter(\.enabled).map(\.name)
        if active.isEmpty { return routines.isEmpty ? String(localized: "None yet") : String(localized: "All paused") }
        return active.joined(separator: " · ")
    }

    private var skillsSummary: String {
        guard let brain else { return "" }
        if brain.skills.isEmpty { return String(localized: "None yet") }
        return brain.skills.map(T3BrainText.skillName).joined(separator: ", ")
    }

    // MARK: Made by Botto

    @ViewBuilder private var shelf: some View {
        let files = outputs.outputs ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Made by Botto").font(.body.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if !files.isEmpty {
                    NavigationLink(value: Destination.files) {
                        Text("See all").font(.subheadline.weight(.medium)).foregroundStyle(BottoTheme.action)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("botto-page-files")
                }
            }
            if let error = outputs.error, files.isEmpty {
                InlineNotice(message: error)
                Button("Try again", systemImage: "arrow.clockwise") { Task { await outputs.load(store) } }
                    .buttonStyle(BottoPillButtonStyle())
            } else if files.isEmpty {
                Text(outputs.outputs == nil
                     ? (store.isConnected ? String(localized: "Looking for files…") : String(localized: "Files appear when the host connects."))
                     : String(localized: "Plans, notes and pictures Botto saves will collect here."))
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(files.prefix(10)) { file in fileCard(file) }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    private func fileCard(_ file: T3OutputFile) -> some View {
        Button { openedOutput = file } label: {
            VStack(alignment: .leading, spacing: 6) {
                T3OutputThumbnail(output: file, model: outputs, store: store)
                Text(T3BrainText.fileTitle(file.name)).font(.footnote.weight(.semibold)).foregroundStyle(BottoTheme.ink)
                    .lineLimit(2).frame(width: 104, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("File \(file.name)")
        .accessibilityHint("Preview, save or share it.")
        .accessibilityIdentifier("botto-file-\(file.relativePath)")
    }

    private var advancedRow: some View {
        NavigationLink(value: Destination.advanced) {
            HStack {
                Text("Model, files on the host, connection").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Advanced")
        .accessibilityValue("Model, files on the host, connection")
        .accessibilityIdentifier("botto-page-advanced")
    }

    @ViewBuilder private func destination(for destination: Destination) -> some View {
        switch destination {
        case .personality:
            if let soulAutosave = drafts.soulAutosave {
                T3ProseEditor(title: "Personality",
                              blurb: "How Botto sounds and what it cares about. It reads this in every space.",
                              text: $drafts.soul, autosave: soulAutosave,
                              reload: { try await store.readT3ProjectFile(relativePath: "SOUL.md") })
                    .onDisappear { soulAutosave.flush(drafts.soul) }
            }
        case .memory:
            if let memoryAutosave = drafts.memoryAutosave {
                T3MemoryView(text: $drafts.memory, autosave: memoryAutosave,
                             reload: { try await store.readT3ProjectFile(relativePath: "MEMORY.md") })
            }
        case .routines:
            T3RoutinesList(store: store, routines: $routines, loadError: routinesError, reload: loadRoutines,
                           isCurrent: { isCurrent }, onOpenChat: { channel in dismiss(); onOpenChat(channel) })
        case .skills:
            T3SkillsList(store: store, skills: brain?.skills ?? [], isCurrent: { isCurrent })
        case .files:
            T3OutputsGrid(store: store, outputs: outputs) { openedOutput = $0 }
        case .advanced:
            T3AdvancedView(store: store, brain: $brain, isCurrent: { isCurrent }, onSettings: onSettings.map { action in
                { dismiss(); action() }
            })
        case .look:
            if let bot = store.primaryT3Bot, let destination = store.avatarDestination(for: bot) {
                T3FaceEditor(store: store, destination: destination)
            }
        }
    }

    // MARK: Loading and saving

    private func load() async {
        guard isCurrent, brain == nil, store.isConnected else { return }
        loadError = nil
        let soulRead = drafts.soulAutosave?.refreshRevision
        let memoryRead = drafts.memoryAutosave?.refreshRevision
        do {
            let loaded = try await store.loadT3BotBrain()
            guard !Task.isCancelled, isCurrent else { return }
            if let autosave = drafts.soulAutosave {
                if autosave.refresh(loaded.soulMarkdown, revision: soulRead) { drafts.soul = loaded.soulMarkdown }
            } else {
                drafts.soul = loaded.soulMarkdown
                drafts.soulAutosave = T3Autosave(saved: drafts.soul) { [store, workspace] value, expected in
                    guard store.chats === workspace else { throw T3ServiceError.disconnected }
                    try await store.saveT3Soul(value, replacing: expected)
                }
            }
            if let autosave = drafts.memoryAutosave {
                if autosave.refresh(loaded.memoryMarkdown, revision: memoryRead) { drafts.memory = loaded.memoryMarkdown }
            } else {
                drafts.memory = loaded.memoryMarkdown
                drafts.memoryAutosave = T3Autosave(saved: drafts.memory) { [store, workspace] value, expected in
                    guard store.chats === workspace else { throw T3ServiceError.disconnected }
                    try await store.saveT3Memory(value, replacing: expected)
                }
            }
            brain = loaded
            if !editingName, drafts.name.isEmpty { drafts.name = store.primaryT3Bot?.name ?? loaded.manifest.displayName }
        } catch where !Task.isCancelled { loadError = error.localizedDescription }
        catch { }
    }

    private func loadRoutines() async {
        guard isCurrent, store.isConnected else { return }
        let request = UUID()
        latestRoutineRead = request
        do {
            let loaded = try await store.listT3Routines()
            guard !Task.isCancelled, isCurrent, latestRoutineRead == request else { return }
            routines = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            routinesError = nil
        } catch where !Task.isCancelled && isCurrent && latestRoutineRead == request {
            routinesError = error.localizedDescription
        } catch { }
    }

    private func commitName() {
        let trimmed = drafts.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCurrent, let current = store.primaryT3Bot?.name else { return }
        guard !trimmed.isEmpty else { drafts.name = current; return }
        guard trimmed != (drafts.submittedName ?? current) else { return }
        drafts.submittedName = trimmed
        let previous = drafts.nameSave
        drafts.nameError = nil
        drafts.nameSave = Task {
            await previous?.value
            guard isCurrent, drafts.submittedName == trimmed else { return }
            defer { if drafts.submittedName == trimmed { drafts.submittedName = nil; drafts.nameSave = nil } }
            do { try await store.renameT3Bot(trimmed) }
            catch where isCurrent && drafts.submittedName == trimmed {
                drafts.nameError = String(localized: "Couldn’t rename Botto. \(error.localizedDescription)")
            } catch { }
        }
    }
}

// MARK: - Text helpers

/// Reads SOUL.md and MEMORY.md as prose so their file names never reach the screen.
enum T3BrainText {
    /// The first sentence-like line that is not a heading.
    static func personalitySummary(_ markdown: String) -> String {
        lines(markdown).first ?? String(localized: "Not written yet")
    }

    /// Each remembered thing, one per bullet or line.
    static func memoryItems(_ markdown: String) -> [String] { lines(markdown) }

    static func memorySummary(_ markdown: String) -> String {
        let items = memoryItems(markdown)
        guard let last = items.last else { return String(localized: "Nothing yet") }
        let count = items.count == 1 ? String(localized: "1 thing") : String(localized: "\(items.count) things")
        return String(localized: "\(count) · last: “\(last)”")
    }

    /// Removes one remembered thing and leaves every other line, heading and spacing as it was.
    static func forgetting(_ item: String, in markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { clean($0) == item }) else { return markdown }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    static func skillName(_ path: String) -> String {
        let last = String(path.split(separator: "/").last ?? Substring(path))
        let base = (last as NSString).deletingPathExtension
        return base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func fileTitle(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    private static func lines(_ markdown: String) -> [String] {
        markdown.components(separatedBy: .newlines).compactMap { line in
            let cleaned = clean(line)
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private static func clean(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") || text.hasPrefix("```") || text.hasPrefix("---") { return "" }
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ ", "> "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
            break
        }
        if let dot = text.firstIndex(of: "."), text[..<dot].allSatisfy(\.isNumber), !text[..<dot].isEmpty,
           text[text.index(after: dot)...].hasPrefix(" ") {
            text = String(text[text.index(dot, offsetBy: 2)...])
        }
        return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Autosave

/// Saves after a short pause in typing, and once more on leaving. A failure keeps the text and offers a retry.
@MainActor @Observable final class T3Autosave {
    enum State: Equatable { case idle, saving, saved, failed(String) }
    private(set) var state: State = .idle
    private var saved: String
    private var desired: String
    private var debounce: Task<Void, Never>?
    private var isWriting = false
    private var revision = UUID()
    private let delay: Duration
    private let write: @MainActor (String, String) async throws -> Void

    init(saved: String, delay: Duration = .milliseconds(800), write: @escaping @MainActor (String, String) async throws -> Void) {
        self.saved = saved
        desired = saved
        self.delay = delay
        self.write = write
    }

    func edited(_ text: String) {
        if text != desired { revision = UUID() }
        desired = text
        debounce?.cancel()
        debounce = nil
        guard !isWriting, text != saved || hasFailed else { return }
        debounce = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.debounce = nil
            self?.persistLatest()
        }
    }

    func flush(_ text: String) {
        desired = text
        let hasWaitingEdit = debounce != nil
        debounce?.cancel()
        debounce = nil
        if hasFailed, !hasWaitingEdit { return }
        persistLatest()
    }

    func retry(_ text: String) {
        desired = text
        debounce?.cancel()
        debounce = nil
        persistLatest()
    }

    private var hasFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var refreshRevision: UUID? { !hasFailed && !isWriting && desired == saved ? revision : nil }

    func refresh(_ text: String, revision observed: UUID?) -> Bool {
        guard let observed, observed == refreshRevision else { return false }
        saved = text
        desired = text
        revision = UUID()
        return true
    }

    func reload(using read: @MainActor () async throws -> String) async -> String? {
        let observed = revision
        do {
            let text = try await read()
            guard !Task.isCancelled, observed == revision, !isWriting else { return nil }
            debounce?.cancel()
            debounce = nil
            saved = text
            desired = text
            revision = UUID()
            state = .idle
            return text
        } catch where !Task.isCancelled && observed == revision {
            state = .failed(error.localizedDescription)
        } catch { }
        return nil
    }

    private func persistLatest() {
        guard !isWriting, desired != saved || hasFailed else { return }
        let text = desired
        let expected = saved
        revision = UUID()
        isWriting = true
        state = .saving
        // Only the debounce can be cancelled. A dispatched write may already have reached the host.
        Task {
            do {
                try await write(text, expected)
                saved = text
                isWriting = false
                state = .saved
                persistLatest()
            } catch {
                isWriting = false
                state = .failed(error.localizedDescription)
            }
        }
    }
}

private struct T3AutosaveStatus: View {
    let autosave: T3Autosave
    let retry: () -> Void
    let reload: () -> Void

    var body: some View {
        switch autosave.state {
        case .idle: EmptyView()
        case .saving: Text("Saving…").font(.caption).foregroundStyle(.secondary)
        case .saved: Text("Saved").font(.caption).foregroundStyle(.tertiary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                InlineNotice(message: String(localized: "Not saved yet. \(message)"))
                Button("Try again", systemImage: "arrow.clockwise", action: retry).buttonStyle(BottoPillButtonStyle())
                Button("Reload from host", action: reload).buttonStyle(BottoPillButtonStyle())
            }
        }
    }
}

struct T3ProseEditor: View {
    let title: LocalizedStringKey
    let blurb: LocalizedStringKey
    @Binding var text: String
    let autosave: T3Autosave
    let reload: @MainActor () async throws -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(blurb).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20)
            TextEditor(text: $text)
                .font(.body).lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 15)
                .accessibilityLabel(title)
                .accessibilityIdentifier("botto-prose-editor")
            T3AutosaveStatus(autosave: autosave, retry: { autosave.retry(text) }, reload: {
                Task { if let loaded = await autosave.reload(using: reload) { text = loaded } }
            }).padding(.horizontal, 20)
        }
        .padding(.top, 8).padding(.bottom, 12)
        .frame(maxWidth: 680).frame(maxWidth: .infinity)
        .background(BottoTheme.paper)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .onChange(of: text) { _, value in autosave.edited(value) }
    }
}

/// Memory reads as a list of things Botto knows; each can be forgotten, or the whole note edited as text.
struct T3MemoryView: View {
    @Binding var text: String
    let autosave: T3Autosave
    let reload: @MainActor () async throws -> String
    @State private var editsText = false

    var body: some View {
        Group {
            if editsText {
                T3ProseEditor(title: "What Botto remembers", blurb: "Durable facts and decisions Botto keeps across spaces.",
                              text: $text, autosave: autosave, reload: reload)
            } else {
                T3MemoryList(text: $text, autosave: autosave, reload: reload)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(editsText ? "Done" : "Edit as text") { editsText.toggle() }
                    .accessibilityIdentifier("botto-memory-mode")
            }
        }
        .onDisappear { autosave.flush(text) }
    }
}

private struct T3MemoryList: View {
    @Binding var text: String
    let autosave: T3Autosave
    let reload: @MainActor () async throws -> String

    var body: some View {
        let items = T3BrainText.memoryItems(text)
        List {
            Section {
                if items.isEmpty {
                    Text("Nothing yet. Tell Botto “remember that…” in any space.").foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item).font(.body).textSelection(.enabled)
                        .swipeActions {
                            Button("Forget", systemImage: "trash", role: .destructive) {
                                text = T3BrainText.forgetting(item, in: text)
                            }
                        }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Swipe to forget something. Botto adds to this as you talk.")
                    T3AutosaveStatus(autosave: autosave, retry: { autosave.retry(text) }, reload: {
                        Task { if let loaded = await autosave.reload(using: reload) { text = loaded } }
                    })
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BottoTheme.paper)
        .navigationTitle("What Botto remembers").navigationBarTitleDisplayMode(.inline)
        .onChange(of: text) { _, value in autosave.edited(value) }
    }
}

// MARK: - Routines

struct T3RoutinesList: View {
    let store: AppStore
    @Binding var routines: [T3ScheduledRoutine]?
    let loadError: String?
    let reload: @MainActor () async -> Void
    let isCurrent: @MainActor () -> Bool
    let onOpenChat: (T3ChannelSummary) -> Void
    @State private var pending: Set<String> = []
    @State private var error: String?
    @State private var showsCreator = false
    @State private var confirmingDelete: T3ScheduledRoutine?

    var body: some View {
        List {
            Section {
                if let routines {
                    if routines.isEmpty {
                        Text("No routines yet.").foregroundStyle(.secondary)
                    }
                    ForEach(routines) { routine in row(routine) }
                } else if let loadError {
                    InlineNotice(message: loadError)
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await reload() } }
                } else if !store.isConnected {
                    ConnectionStatusView(store: store)
                } else {
                    HStack(spacing: 10) { ProgressView(); Text("Checking the schedule…").foregroundStyle(.secondary) }
                }
            } footer: {
                Text("Tip: you can also just ask Botto in a space, like “every Sunday at 8, plan my week.”")
            }
            if let error {
                Section { InlineNotice(message: error) { self.error = nil } }
            }
            if routines != nil, let loadError {
                Section { InlineNotice(message: loadError) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BottoTheme.paper)
        .navigationTitle("Routines").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New routine", systemImage: "plus") { showsCreator = true }
                    .accessibilityIdentifier("t3-new-routine")
            }
        }
        .sheet(isPresented: $showsCreator) {
            T3RoutineCreator(store: store, isCurrent: isCurrent) { routine in
                routines = ((routines ?? []).filter { $0.id != routine.id } + [routine])
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                Task { await reload() }
            }
        }
        .confirmationDialog("Delete this routine?", isPresented: Binding(
            get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }
        ), titleVisibility: .visible, presenting: confirmingDelete) { routine in
            Button("Delete “\(routine.name)”", role: .destructive) { delete(routine) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("It won’t run again. Its past messages stay in their space.") }
        .refreshable { await reload() }
    }

    private func row(_ routine: T3ScheduledRoutine) -> some View {
        let chat = routine.threadID.flatMap { id in store.t3Channels.first { $0.id == id } }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name).font(.body.weight(.semibold))
                    .foregroundStyle(routine.enabled ? BottoTheme.ink : Color.secondary)
                Text(scheduleLine(routine, chat: chat)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if pending.contains(routine.id) {
                ProgressView().frame(width: 51).accessibilityLabel("Updating routine")
            } else {
                Toggle("Active", isOn: Binding(get: { routine.enabled }, set: { setEnabled(routine, $0) }))
                    .labelsHidden().tint(BottoTheme.action)
                    .accessibilityLabel("\(routine.name) active")
                    .accessibilityIdentifier("t3-routine-toggle-\(routine.id)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("t3-routine-\(routine.id)")
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = routine }
        }
        .contextMenu {
            if let chat {
                Button("Open its space", systemImage: "bubble.left") { onOpenChat(chat) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = routine }
        }
    }

    private func scheduleLine(_ routine: T3ScheduledRoutine, chat: T3ChannelSummary?) -> String {
        var parts = [T3RoutineSchedule.summary(routine.cron)]
        if !routine.enabled { parts.append(String(localized: "Paused")) }
        else if let next = routine.nextRunAt { parts.append(String(localized: "next \(next.formatted(.relative(presentation: .named)))")) }
        if let chat { parts.append(String(localized: "in \(chat.displayTitle)")) }
        return parts.joined(separator: " · ")
    }

    private func setEnabled(_ routine: T3ScheduledRoutine, _ enabled: Bool) {
        perform(routine) {
            try await store.setT3RoutineEnabled(id: routine.id, enabled: enabled)
            await reload()
        }
    }

    private func delete(_ routine: T3ScheduledRoutine) {
        perform(routine) {
            try await store.deleteT3Routine(id: routine.id)
            await reload()
        }
    }

    private func perform(_ routine: T3ScheduledRoutine, action: @escaping @MainActor () async throws -> Void) {
        guard isCurrent(), !pending.contains(routine.id) else { return }
        guard store.isConnected else { error = T3ServiceError.disconnected.localizedDescription; return }
        pending.insert(routine.id)
        error = nil
        Task {
            defer { pending.remove(routine.id) }
            do { try await action() }
            catch where isCurrent() { self.error = error.localizedDescription }
            catch { }
        }
    }
}

private struct T3RoutineCreator: View {
    let store: AppStore
    let isCurrent: @MainActor () -> Bool
    let onCreated: (T3ScheduledRoutine) -> Void

    private enum Cadence: Hashable { case daily, weekdays, custom }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var cadence: Cadence = .daily
    @State private var days: Set<Int> = [1, 3, 5]
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    @State private var threadID: String?
    @State private var saving = false
    @State private var error: String?

    private var schedule: T3RoutineSchedule {
        switch cadence {
        case .daily: .daily
        case .weekdays: .weekdays
        case .custom: .days(days)
        }
    }

    private var cron: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return schedule.cron(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
    }

    private var canCreate: Bool {
        !saving && schedule.isValid
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like Morning brief", text: $name)
                        .accessibilityIdentifier("t3-routine-name")
                    TextField("What should Botto do?", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("t3-routine-prompt")
                }
                Section {
                    Picker("Repeat", selection: $cadence) {
                        Text("Daily").tag(Cadence.daily)
                        Text("Weekdays").tag(Cadence.weekdays)
                        Text("Pick days").tag(Cadence.custom)
                    }
                    if cadence == .custom { dayPicker }
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("t3-routine-time")
                } footer: {
                    Text("\(T3RoutineSchedule.summary(cron)), on the host’s clock.")
                }
                Section {
                    Picker("Space", selection: $threadID) {
                        Text("Its own space").tag(String?.none)
                        ForEach(store.t3Channels.filter { !$0.isArchived }) { channel in
                            Text(channel.displayTitle).tag(Optional(channel.id))
                        }
                    }
                    .accessibilityIdentifier("t3-routine-space")
                } footer: {
                    Text("Results arrive as messages in this space.")
                }
                if let error { Section { InlineNotice(message: error) } }
            }
            .scrollContentBackground(.hidden)
            .background(BottoTheme.paper)
            .navigationTitle("New routine").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add", action: create).disabled(!canCreate)
                        .accessibilityIdentifier("t3-routine-create")
                }
            }
            .tint(BottoTheme.action)
        }
        .interactiveDismissDisabled(saving)
    }

    private var dayPicker: some View {
        let calendar = Calendar.current
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
        return HStack(spacing: 4) {
            ForEach(order, id: \.self) { day in
                let selected = days.contains(day)
                Button {
                    if selected { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[day])
                        .font(.bottoRounded(.subheadline, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(selected ? BottoTheme.onAction : BottoTheme.ink)
                        .background(selected ? BottoTheme.action : BottoTheme.surface, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[day])
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    private func create() {
        guard canCreate, isCurrent() else { return }
        guard store.isConnected else { error = T3ServiceError.disconnected.localizedDescription; return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cron = cron
        let threadID = threadID
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                let routine = try await store.createT3Routine(name: name, prompt: prompt, cron: cron, threadID: threadID)
                guard isCurrent() else { return }
                onCreated(routine)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Skills

struct T3SkillsList: View {
    let store: AppStore
    let skills: [String]
    let isCurrent: @MainActor () -> Bool

    var body: some View {
        List {
            Section {
                if skills.isEmpty {
                    Text("No skills yet. Ask Botto to learn one, or add a folder with a SKILL.md under skills/ on the host.")
                        .foregroundStyle(.secondary)
                }
                ForEach(skills, id: \.self) { path in
                    let lower = path.lowercased()
                    let file = lower.hasSuffix(".md") || lower.hasSuffix(".markdown") ? path : "\(path)/SKILL.md"
                    NavigationLink {
                        T3SkillReader(store: store, title: T3BrainText.skillName(path), path: file, isCurrent: isCurrent)
                    } label: {
                        Text(T3BrainText.skillName(path)).font(.body)
                    }
                    .accessibilityIdentifier("botto-skill-\(path)")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BottoTheme.paper)
        .navigationTitle("Skills").navigationBarTitleDisplayMode(.inline)
    }
}

private struct T3SkillReader: View {
    let store: AppStore
    let title: String
    let path: String
    let isCurrent: @MainActor () -> Bool
    @State private var markdown: String?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let markdown {
                    if markdown.isEmpty { Text("This skill is empty.").foregroundStyle(.secondary) }
                    else { MarkdownBody(text: markdown) }
                } else if let error {
                    if !store.isConnected { ConnectionStatusView(store: store) }
                    InlineNotice(message: error)
                    Button("Try again") { retry += 1 }.buttonStyle(BottoPillButtonStyle())
                } else {
                    ProgressView("Opening skill…")
                }
            }
            .padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(BottoTheme.paper)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task(id: retry) {
            guard markdown == nil, isCurrent() else { return }
            error = nil
            do {
                let loaded = try await store.readT3ProjectFile(relativePath: path)
                if !Task.isCancelled, isCurrent() { markdown = loaded }
            } catch where !Task.isCancelled { self.error = error.localizedDescription }
            catch { }
        }
    }
}

// MARK: - Files

struct T3OutputsGrid: View {
    let store: AppStore
    let outputs: T3OutputsModel
    let onOpen: (T3OutputFile) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 16)], alignment: .leading, spacing: 20) {
                ForEach(outputs.outputs ?? []) { file in
                    Button { onOpen(file) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            T3OutputThumbnail(output: file, model: outputs, store: store)
                            Text(T3BrainText.fileTitle(file.name)).font(.footnote.weight(.semibold))
                                .foregroundStyle(BottoTheme.ink).lineLimit(2)
                                .frame(width: 104, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("File \(file.name)")
                }
            }
            .padding(20)
        }
        .background(BottoTheme.paper)
        .navigationTitle("Made by Botto").navigationBarTitleDisplayMode(.inline)
        .refreshable { await outputs.load(store) }
    }
}

// MARK: - Advanced

struct T3AdvancedView: View {
    let store: AppStore
    @Binding var brain: T3BotBrainSnapshot?
    let isCurrent: @MainActor () -> Bool
    let onSettings: (() -> Void)?
    @State private var saving = false
    @State private var error: String?

    private var selection: Binding<String> {
        Binding(get: {
            guard let manifest = brain?.manifest, let model = manifest.model else { return "" }
            return store.t3Models.first { $0.modelID == model && $0.providerInstanceID == manifest.providerInstanceID }?.id
                ?? "saved:\(model)"
        }, set: { id in choose(store.t3Models.first { $0.id == id }) })
    }

    var body: some View {
        Form {
            if !store.isDemo {
                Section {
                    Picker("Default model", selection: selection) {
                        Text("Automatic").tag("")
                        if let model = brain?.manifest.model,
                           !store.t3Models.contains(where: { $0.modelID == model && $0.providerInstanceID == brain?.manifest.providerInstanceID }) {
                            Text("\(model) (unavailable)").tag("saved:\(model)")
                        }
                        ForEach(store.t3Models) { option in
                            Text("\(option.label) · \(option.providerName)").tag(option.id)
                        }
                    }
                    .disabled(saving || brain == nil)
                    .accessibilityIdentifier("botto-default-model")
                } footer: {
                    Text("New spaces start with this. Switch any space’s model from its composer.")
                }
            }
            if let root = brain?.workspaceRoot, !root.isEmpty {
                Section {
                    LabeledContent("Folder") {
                        Text(root).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Copy folder path", systemImage: "doc.on.doc") { UIPasteboard.general.string = root }
                } header: { Text("Files on the host") } footer: {
                    Text("Botto’s personality, memory, skills and files live here on the computer running T3 Code.")
                }
            }
            Section("Connection") {
                LabeledContent("Host", value: store.serverName)
                LabeledContent("Status", value: store.isConnected ? String(localized: "Connected")
                               : store.link == .connecting ? String(localized: "Connecting…") : String(localized: "Offline"))
                if let onSettings {
                    Button("Pairing and settings", systemImage: "gearshape", action: onSettings)
                }
            }
            if let error { Section { InlineNotice(message: error) { self.error = nil } } }
        }
        .scrollContentBackground(.hidden)
        .background(BottoTheme.paper)
        .navigationTitle("Advanced").navigationBarTitleDisplayMode(.inline)
        .task(id: store.connectionGeneration) { await store.loadT3ModelsIfNeeded() }
    }

    private func choose(_ option: T3ModelOption?) {
        guard !saving, isCurrent() else { return }
        guard store.isConnected else { error = T3ServiceError.disconnected.localizedDescription; return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                let manifest = try await store.setT3DefaultModel(option)
                guard isCurrent(), let current = brain else { return }
                brain = T3BotBrainSnapshot(manifest: manifest, soulMarkdown: current.soulMarkdown,
                                           memoryMarkdown: current.memoryMarkdown, skills: current.skills,
                                           workspaceRoot: current.workspaceRoot)
            } catch where isCurrent() { self.error = error.localizedDescription }
            catch { }
        }
    }
}

// MARK: - Look

struct T3FaceEditor: View {
    let store: AppStore
    let destination: AppStore.AvatarDestination
    @Environment(\.dismiss) private var dismiss
    @State private var selection: BotAvatarChoice?
    @State private var saving = false
    @State private var error: String?

    private var preview: BotProfile {
        var bot = destination.profile
        if let selection { bot.appearance = selection.applying(to: bot.appearance ?? BotAppearance()) }
        return bot
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BotAvatar(profile: preview, size: 110)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Preview of \(preview.name)’s look")
                BotAvatarPicker(profileID: preview.id, current: destination.profile.appearance ?? BotAppearance(),
                                selection: $selection)
                if !store.isConnected { ConnectionStatusView(store: store) }
                if let error { InlineNotice(message: error) }
            }
            .padding(24)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
        }
        .background(BottoTheme.paper)
        .navigationTitle("Change look").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Use this look", action: save)
                    .disabled(saving || selection == nil || !destination.isCurrent(in: store) || !store.isConnected)
                    .accessibilityIdentifier("botto-look-save")
            }
        }
    }

    private func save() {
        guard !saving, destination.isCurrent(in: store), let selection else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await store.saveAvatar(selection, to: destination)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
