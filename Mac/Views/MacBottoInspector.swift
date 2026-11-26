import AppKit
import BottoCore
import SwiftUI

/// The Botto page as a trailing column: one face, then flat rows that open plain-prose pages.
/// Every edit saves itself; there are no Save buttons.
struct MacBottoInspector: View {
    let server: LocalT3ServerManager
    let store: MacBottoStore
    let onPreview: (MacPreviewItem) -> Void
    @State private var path: [Page] = []

    enum Page: Hashable {
        case look, personality, memory, routines, skills, skill(String), files, advanced
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MacBottoHero(store: store) { path.append(.look) }
                        .padding(.bottom, 14)
                    if let brain = store.brain {
                        rows(brain)
                    } else if store.isConnected {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(30)
                    } else {
                        Text("Botto’s page opens when the engine is awake.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .navigationDestination(for: Page.self) { page in
                destination(page)
                    .background(MacTheme.paper)
            }
        }
        .background(MacTheme.paper)
        .task(id: store.isConnected) {
            guard store.isConnected else { return }
            await store.loadBrain()
            async let routines: Void = store.loadRoutines()
            async let outputs: Void = store.loadOutputs()
            async let models: Void = store.loadModels()
            _ = await (routines, outputs, models)
        }
        .task(id: store.workflowRoutinesAvailable) { await store.loadWorkflowRoutines() }
    }

    @ViewBuilder
    private func rows(_ brain: T3BotBrainSnapshot) -> some View {
        NavigationLink(value: Page.personality) {
            MacHairlineRow(title: "Personality", detail: MacBrainSummary.personality(store.soulDraft?.text ?? brain.soulMarkdown))
        }
        .buttonStyle(.plain)
        NavigationLink(value: Page.memory) {
            MacHairlineRow(title: "What Botto remembers", detail: MacBrainSummary.memoryDetail(store.memoryDraft?.text ?? brain.memoryMarkdown))
        }
        .buttonStyle(.plain)
        NavigationLink(value: Page.routines) {
            MacHairlineRow(title: "Routines", detail: routinesDetail)
        }
        .buttonStyle(.plain)
        NavigationLink(value: Page.skills) {
            MacHairlineRow(title: "Skills", detail: brain.skills.isEmpty ? "None yet"
                           : brain.skills.map(MacBrainSummary.skillName).joined(separator: ", "))
        }
        .buttonStyle(.plain)
        madeByBotto
        NavigationLink(value: Page.advanced) {
            HStack {
                Text("Model, files on your Mac, connection").font(.callout).foregroundStyle(.secondary)
                Spacer()
                MacChevron()
            }
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .accessibilityLabel("Advanced")
    }

    private var routinesDetail: String {
        guard let routines = store.routines else { return "Checking…" }
        let workflowRoutines = store.workflowRoutines
        let active = routines.filter(\.enabled).map(\.name) + workflowRoutines.filter(\.enabled).map { $0.proposal.name }
        if routines.isEmpty && workflowRoutines.isEmpty { return "None yet. Ask Botto in any space." }
        if active.isEmpty { return "All paused" }
        return active.joined(separator: " · ")
    }

    @ViewBuilder
    private var madeByBotto: some View {
        let files = store.outputs ?? []
        HStack(alignment: .firstTextBaseline) {
            Text("Made by Botto").font(.body.weight(.semibold))
            Spacer()
            if !files.isEmpty {
                Button("See all") { path.append(.files) }
                    .buttonStyle(.plain)
                    .foregroundStyle(MacTheme.action)
                    .font(.callout.weight(.medium))
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 10)
        if files.isEmpty {
            Text(store.outputs == nil ? "Looking…" : "Things Botto makes for you show up here.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.bottom, 6)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(files.prefix(8)) { file in fileCard(file, width: 96) }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func fileCard(_ file: T3OutputFile, width: CGFloat) -> some View {
        let item = MacPreviewItem.output(file, store: store)
        return Button { onPreview(item) } label: {
            VStack(alignment: .leading, spacing: 5) {
                MacFileThumbnail(item: item).frame(width: width, height: width * 1.18)
                Text((file.name as NSString).deletingPathExtension)
                    .font(.caption.weight(.semibold)).lineLimit(1).frame(width: width, alignment: .leading)
                Text(item.kind.label).font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(file.name)")
    }

    @ViewBuilder
    private func destination(_ page: Page) -> some View {
        switch page {
        case .look: MacLookEditor(store: store)
        case .personality:
            if let draft = store.soulDraft {
                MacProseEditor(title: "Personality",
                               blurb: "How Botto talks and what it cares about, in every space.",
                               autosaver: draft, reload: { try await store.readSkill(relativePath: "SOUL.md") })
            }
        case .memory:
            if let draft = store.memoryDraft {
                MacProseEditor(title: "What Botto remembers",
                               blurb: "Things Botto keeps in mind across spaces. Botto adds to this as you talk; edit anything here.",
                               autosaver: draft, reload: { try await store.readSkill(relativePath: "MEMORY.md") })
            }
        case .routines: MacRoutinesPage(store: store)
        case .skills:
            MacSkillsPage(skills: store.brain?.skills ?? []) { path.append(.skill($0)) }
        case .skill(let skill): MacSkillReader(store: store, path: skill)
        case .files:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 16) {
                    ForEach(store.outputs ?? []) { fileCard($0, width: 96) }
                }
                .padding(20)
            }
            .navigationTitle("Made by Botto")
        case .advanced: MacAdvancedPage(server: server, store: store)
        }
    }
}

/// The big face and Botto's name, edited in place.
private struct MacBottoHero: View {
    let store: MacBottoStore
    let onChangeLook: () -> Void
    @State private var name = ""
    @State private var error: String?
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 8) {
            MacBotAvatarView(profileID: store.bot?.id ?? "main", appearance: store.bot?.appearance,
                             activity: MacAvatarActivity(status: store.botStatus))
                .frame(width: 104, height: 104)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(MacTheme.rounded(.title, weight: .heavy))
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { _, focused in if !focused { commit() } }
                .accessibilityLabel("Botto’s name")
            Button("Change look", action: onChangeLook)
                .buttonStyle(.plain)
                .foregroundStyle(MacTheme.action)
                .font(.callout.weight(.semibold))
                .disabled(store.bot == nil)
            if let error { Text(error).font(.caption).foregroundStyle(MacTheme.error) }
        }
        .frame(maxWidth: .infinity)
        .onAppear { name = store.bot?.name ?? "" }
        .onChange(of: store.bot?.name) { _, latest in if !editing { name = latest ?? "" } }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = store.bot?.name else { return }
        guard !trimmed.isEmpty else { name = current; return }
        guard trimmed != current else { return }
        error = nil
        Task {
            do { try await store.renameBot(trimmed) }
            catch { self.error = error.localizedDescription; name = store.bot?.name ?? current }
        }
    }
}

/// A calm prose page over one brain file. Edits save a moment after typing stops.
struct MacProseEditor: View {
    let title: String
    let blurb: String
    let autosaver: MacAutosaver
    let reload: @MainActor () async throws -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(get: { autosaver.text }, set: { autosaver.edit($0) }))
                .font(.body)
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.vertical, 4)
                .accessibilityLabel(title)
            Text(status)
                .font(.caption)
                .foregroundStyle(isFailed ? MacTheme.error : Color.secondary)
                .contentTransition(.opacity)
            if isFailed {
                HStack {
                    Button("Try Again") { Task { await autosaver.flush() } }
                    Button("Reload from Host") { Task { await autosaver.reload(using: reload) } }
                }
            }
        }
        .padding(20)
        .navigationTitle(title)
        .onDisappear { Task { await autosaver.flush() } }
    }

    private var isFailed: Bool { if case .failed = autosaver.state { true } else { false } }

    private var status: String {
        switch autosaver.state {
        case .idle: "Changes save as you type."
        case .pending, .saving: "Saving…"
        case .saved: "Saved"
        case .failed(let reason): "Couldn’t save yet: \(reason)"
        }
    }
}

/// Choosing a shape or color saves right away.
private struct MacLookEditor: View {
    let store: MacBottoStore
    @State private var error: String?
    @State private var saving = false

    private var face: BotFace? {
        store.bot.map { ($0.appearance ?? BotAppearance()).face(for: $0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MacBotAvatarView(profileID: store.bot?.id ?? "main", appearance: store.bot?.appearance)
                    .frame(width: 110, height: 110)
                    .frame(maxWidth: .infinity)
                Text("Shape").font(.body.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 10)], spacing: 10) {
                    ForEach(BotAvatarShape.pickerCases) { shape in
                        Button { choose(.edit(BotAvatarEdit(shape: shape))) } label: {
                            MacBotAvatarView(profileID: store.bot?.id ?? "main",
                                             appearance: BotAvatarChoice.edit(BotAvatarEdit(shape: shape))
                                                .applying(to: store.bot?.appearance ?? BotAppearance()),
                                             animated: false)
                                .frame(width: 44, height: 44)
                                .padding(6)
                                .background(face?.shape == shape ? MacTheme.selection : .clear, in: .rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(shape.rawValue.capitalized)
                        .accessibilityAddTraits(face?.shape == shape ? .isSelected : [])
                    }
                }
                Text("Color").font(.body.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 10)], spacing: 10) {
                    ForEach(BotAvatarColors.presets) { preset in
                        let selected = face.map { BotAvatarColors.preset(for: $0.color)?.id == preset.id } ?? false
                        Button { choose(.edit(BotAvatarEdit(shape: face?.shape, color: .value(preset.shared)))) } label: {
                            Circle()
                                .fill(Color(hex: preset.hex))
                                .frame(width: 26, height: 26)
                                .overlay { if selected { Circle().stroke(Color.primary, lineWidth: 2).padding(-3) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.id.capitalized)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(MacTheme.error) }
            }
            .padding(20)
            .disabled(saving || store.bot == nil)
        }
        .navigationTitle("Look")
    }

    private func choose(_ choice: BotAvatarChoice) {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do { try await store.setLook(choice) } catch { self.error = error.localizedDescription }
        }
    }
}

private struct MacRoutinesPage: View {
    let store: MacBottoStore
    @State private var adding = false
    @State private var error: String?
    @State private var deleting: RoutineDeletion?
    @State private var updating: Set<UUID> = []

    private enum RoutineDeletion {
        case scheduled(T3ScheduledRoutine)
        case workflow(T3WorkflowRoutine)

        var name: String {
            switch self {
            case .scheduled(let routine): routine.name
            case .workflow(let routine): routine.proposal.name
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Tip: you can also just ask Botto in a space, like “every Sunday at 8, plan my week.”")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
                if let routines = store.routines {
                    if routines.isEmpty, store.workflowRoutines.isEmpty, !adding {
                        Text("No routines yet.").foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(routines) { routine in row(routine) }
                } else {
                    ProgressView().controlSize(.small).padding(.vertical, 12)
                }
                ForEach(store.workflowRoutines) { workflowRow($0) }
                if adding {
                    MacRoutineForm(store: store) { adding = false }
                        .padding(.top, 14)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(MacTheme.error).padding(.top, 8)
                    if store.workflowRoutinesAvailable {
                        Button("Refresh Routines") {
                            self.error = nil
                            Task {
                                await store.loadRoutines()
                                await store.loadWorkflowRoutines()
                            }
                        }
                    }
                }
                if let workflowLoadError = store.workflowRoutinesError {
                    Text(workflowLoadError).font(.caption).foregroundStyle(MacTheme.error).padding(.top, 8)
                    Button("Try again") { Task { await store.loadWorkflowRoutines() } }
                }
            }
            .padding(20)
        }
        .navigationTitle("Routines")
        .toolbar {
            ToolbarItem {
                Button { adding.toggle() } label: { Label("Add routine", systemImage: "plus") }
                    .help("Add a routine")
            }
        }
        .task(id: store.isConnected) {
            await store.loadRoutines()
            await store.loadWorkflowRoutines()
        }
        .confirmationDialog("Delete this routine?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { routine in
            Button("Delete “\(routine.name)”", role: .destructive) {
                switch routine {
                case .scheduled(let task):
                    Task {
                        do { try await store.deleteRoutine(task) } catch { self.error = error.localizedDescription }
                    }
                case .workflow(let workflow):
                    update(workflow) {
                        try await store.deleteWorkflowRoutine(workflow)
                    }
                }
            }
        } message: { _ in Text("It won’t run again. Its space stays.") }
    }

    private func workflowRow(_ routine: T3WorkflowRoutine) -> some View {
        let proposal = routine.proposal
        let detail = T3RoutineSchedule.macSummary(proposal.schedule, showsChosenDays: true) + (routine.enabled ? "" : " · Paused")
        return MacHairlineRow(title: proposal.name, detail: detail) {
            HStack(spacing: 8) {
                Toggle("Active", isOn: Binding(get: { routine.enabled }, set: { enabled in
                    update(routine) {
                        try await store.setWorkflowRoutineEnabled(routine, enabled: enabled)
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("\(proposal.name) active")
                Button { deleting = .workflow(routine) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Delete \(proposal.name)")
            }
            .disabled(updating.contains(routine.id))
        }
        .help(proposal.prompt)
    }

    private func update(_ routine: T3WorkflowRoutine, action: @escaping @MainActor () async throws -> Void) {
        guard updating.insert(routine.id).inserted else { return }
        error = nil
        Task {
            defer { updating.remove(routine.id) }
            do {
                try await action()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func row(_ routine: T3ScheduledRoutine) -> some View {
        MacHairlineRow(title: routine.name, detail: T3RoutineSchedule.macSummary(routine.schedule)) {
            HStack(spacing: 8) {
                Toggle("Active", isOn: Binding(get: { routine.enabled }, set: { enabled in
                    Task {
                        do { try await store.setRoutineEnabled(routine, enabled: enabled) }
                        catch { self.error = error.localizedDescription }
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("\(routine.name) active")
                Button { deleting = .scheduled(routine) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Delete \(routine.name)")
            }
        }
        .help(routine.prompt)
    }
}

private struct MacRoutineForm: View {
    let store: MacBottoStore
    let onDone: () -> Void
    @State private var name = ""
    @State private var prompt = ""
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
    @State private var days = T3RoutineSchedule.everyDay
    @State private var chosenDays: Set<Int> = [1, 3, 5]
    @State private var asksBeforeRunning = false
    @State private var threadID: String?
    @State private var proposal: T3WorkflowRoutineProposal?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let proposal {
                Text(proposal.name).font(.headline)
                Text(T3RoutineSchedule.macSummary(proposal.schedule, showsChosenDays: true))
                if let space = store.channels.first(where: { $0.id == proposal.threadID }) {
                    LabeledContent("Space", value: space.displayTitle)
                }
                Text(proposal.prompt)
                Text("This Routine uses the host’s clock. Botto will ask in this Space before each run.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                editor
            }
            if let error { Text(error).font(.caption).foregroundStyle(MacTheme.error) }
            HStack {
                Spacer()
                Button(proposal == nil ? "Cancel" : "Back") {
                    if proposal == nil { onDone() }
                    else { proposal = nil; error = nil }
                }
                .buttonStyle(MacPillButtonStyle(prominent: false))
                .disabled(saving)
                if let proposal {
                    Button(saving ? "Turning on…" : "Turn on") { turnOn(proposal) }
                        .buttonStyle(MacPillButtonStyle())
                        .disabled(saving)
                } else {
                    Button(asksBeforeRunning ? "Review" : "Add") { add() }
                        .buttonStyle(MacPillButtonStyle())
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || prompt.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (asksBeforeRunning && (threadID == nil || chosenDays.isEmpty)))
                }
            }
        }
        .padding(14)
        .background(MacTheme.surface, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder private var editor: some View {
        TextField("Name, like Morning brief", text: $name).textFieldStyle(.roundedBorder)
        TextField("What should Botto do?", text: $prompt, axis: .vertical)
            .textFieldStyle(.roundedBorder).lineLimit(2...5)
        if store.workflowRoutinesAvailable || asksBeforeRunning {
            Toggle("Ask before each run", isOn: $asksBeforeRunning)
                .onChange(of: asksBeforeRunning) { _, enabled in
                    if enabled, threadID == nil { threadID = store.channels.first { !$0.isArchived }?.id }
                }
        }
        HStack {
            if !asksBeforeRunning {
                Picker("Days", selection: $days) {
                    Text(verbatim: "Every day").tag(T3RoutineSchedule.everyDay)
                    Text(verbatim: "Weekdays").tag(T3RoutineSchedule.weekdays)
                    Text(verbatim: "Weekends").tag(T3RoutineSchedule.weekends)
                }
                .labelsHidden()
                .fixedSize()
            }
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
            Spacer()
        }
        if asksBeforeRunning {
            let calendar = Calendar.current
            let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
            HStack(spacing: 4) {
                ForEach(order, id: \.self) { day in
                    Button(calendar.veryShortWeekdaySymbols[day]) {
                        if chosenDays.contains(day) { chosenDays.remove(day) } else { chosenDays.insert(day) }
                    }
                    .buttonStyle(MacPillButtonStyle(prominent: chosenDays.contains(day)))
                    .accessibilityLabel(calendar.weekdaySymbols[day])
                    .accessibilityAddTraits(chosenDays.contains(day) ? [.isSelected] : [])
                }
            }
            Picker("Space", selection: $threadID) {
                ForEach(store.channels.filter { !$0.isArchived }) { channel in
                    Text(channel.displayTitle).tag(Optional(channel.id))
                }
            }
        }
    }

    private func add() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        guard !saving, let schedule = T3RoutineSchedule(hour: parts.hour ?? 8, minute: parts.minute ?? 0,
                                                         days: asksBeforeRunning ? chosenDays : days) else { return }
        let asksBeforeRunning = asksBeforeRunning
        let threadID = threadID
        let name = name
        let prompt = prompt
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                if asksBeforeRunning {
                    guard let threadID else { throw ConversationServiceError.wrongConversation }
                    proposal = try await store.withWorkflowRoutines {
                        try $0.proposeWorkflowRoutine(name: name, prompt: prompt, schedule: schedule, threadID: threadID)
                    }
                    return
                }
                try await store.createRoutine(name: name, prompt: prompt, schedule: schedule)
                onDone()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func turnOn(_ proposal: T3WorkflowRoutineProposal) {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await store.turnOnWorkflowRoutine(proposal)
                onDone()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct MacSkillsPage: View {
    let skills: [String]
    let open: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if skills.isEmpty {
                    Text("Skills teach Botto how to do particular jobs. Ask Botto to learn one, and it shows up here.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(skills, id: \.self) { skill in
                    Button { open(skill) } label: { MacHairlineRow(title: MacBrainSummary.skillName(skill), detail: "") }
                        .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .navigationTitle("Skills")
    }
}

private struct MacSkillReader: View {
    let store: MacBottoStore
    let path: String
    @State private var contents: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            Group {
                if let contents { MacMarkdownView(text: contents, style: .editorial) }
                else if let error { Text(error).foregroundStyle(MacTheme.error) }
                else { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(MacBrainSummary.skillName(path))
        .task(id: path) {
            do { contents = try await store.readSkill(relativePath: MacBrainSummary.skillFile(path)) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct MacAdvancedPage: View {
    let server: LocalT3ServerManager
    let store: MacBottoStore
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?
    @State private var saving = false

    private var currentModelID: String? {
        guard let manifest = store.brain?.manifest, let provider = manifest.providerInstanceID, let model = manifest.model else {
            return nil
        }
        return store.models.first { $0.providerInstanceID == provider && $0.modelID == model }?.id ?? "\(provider):\(model)"
    }

    var body: some View {
        Form {
            Section {
                Picker("Default model", selection: Binding(get: { currentModelID ?? "" }, set: choose)) {
                    Text("Automatic").tag("")
                    if let current = currentModelID, !store.models.contains(where: { $0.id == current }) {
                        Text(store.brain?.manifest.model ?? current).tag(current)
                    }
                    ForEach(store.models) { Text("\($0.label) · \($0.providerName)").tag($0.id) }
                }
                .disabled(saving)
            } footer: {
                Text("New spaces start with this. Each space can switch from the model button by its message box.")
            }
            Section("Files on your Mac") {
                if let root = store.workspaceRoot {
                    LabeledContent("Botto’s folder") {
                        Text((root as NSString).abbreviatingWithTildeInPath)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    Button("Show in Finder") {
                        let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            Section("Connection") {
                LabeledContent("Local engine", value: engineStatus)
                Button("Pair Phone…") { openWindow(id: MacWindowID.pairPhone) }
                Button("Server Log") { openWindow(id: MacWindowID.serverLog) }
            }
            if let error { Text(error).foregroundStyle(MacTheme.error) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Advanced")
    }

    private var engineStatus: String {
        switch server.state {
        case .running: "Awake"
        case .starting: "Waking up"
        case .stopped: "Asleep"
        case .failed: "Couldn’t start"
        }
    }

    private func choose(_ id: String) {
        let option = store.models.first { $0.id == id }
        guard id.isEmpty || option != nil else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do { try await store.setDefaultModel(option) } catch { self.error = error.localizedDescription }
        }
    }
}

extension Color {
    /// `#rrggbb` presets from Botto's palette.
    init(hex: String) {
        let value = UInt32(hex.dropFirst().prefix(6), radix: 16) ?? 0
        self.init(red: Double(value >> 16) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
