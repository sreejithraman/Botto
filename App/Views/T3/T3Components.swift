import SwiftUI
import BottoCore

/// Capsule actions that sit on warm Botto canvases beside the full-width primary button.
struct BottoPillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }

    private var foreground: Color {
        guard isEnabled else { return BottoTheme.disabledForeground }
        return prominent ? BottoTheme.onAction : BottoTheme.action
    }

    private func background(pressed: Bool) -> Color {
        guard isEnabled else { return BottoTheme.disabledSurface }
        if prominent { return pressed ? BottoTheme.pressedAction : BottoTheme.action }
        return pressed ? BottoTheme.selection.opacity(0.65) : BottoTheme.selection
    }
}

/// A card that sinks a little under the finger, like Inbox rows.
struct BottoCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 22
    var fill: Color = BottoTheme.surface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? BottoTheme.selection : fill,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

extension Font {
    static func bottoRounded(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

struct BottoSectionHeader: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.footnote.weight(.semibold)).accessibilityHidden(true)
            }
            Text(title).font(.bottoRounded(.subheadline))
            if let count {
                Text(count, format: .number).font(.bottoRounded(.caption, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(BottoTheme.surface, in: Capsule())
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Actions the T3 shell lends its space: the spaces drawer, the new-space page, and Botto's page.
struct T3ChromeActions {
    let openDrawer: @MainActor () -> Void
    let newSpace: @MainActor () -> Void
    let openBotto: @MainActor () -> Void
}

extension EnvironmentValues {
    @Entry var t3Chrome: T3ChromeActions?
}

/// What Botto is doing, said quietly under a space's name. Nothing when it is simply idle.
enum T3ActivityCue {
    static func text(for activity: BotMotionActivity) -> String? {
        switch activity {
        case .thinking: String(localized: "thinking…")
        case .working: String(localized: "working…")
        case .tools: String(localized: "using tools…")
        case .replying: String(localized: "replying…")
        case .waiting: String(localized: "waiting on you")
        case .failed: String(localized: "hit a snag")
        case .offline, .unavailable: String(localized: "offline")
        case .idle, .finished: nil
        }
    }

    static func text(for status: BotStatus) -> String? {
        switch status {
        case .waiting: String(localized: "waiting on you")
        case .working: String(localized: "working…")
        case .idle: nil
        }
    }
}

extension View {
    @ViewBuilder func t3HeaderGlass() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

/// The quiet "Model ⌄" control in a composer. It switches only this space's model.
struct T3ModelChip: View {
    let store: AppStore
    /// nil on the new-space page, where the pick waits for the new space.
    var chat: T3ChannelSummary?
    var pending: Binding<T3ModelOption?>? = nil
    @State private var switching = false
    @State private var error: String?

    var body: some View {
        Menu {
            if store.t3Models.isEmpty {
                Text(store.isConnected ? "Loading models…" : "Connect to switch models")
            }
            if pending != nil {
                Button { pending?.wrappedValue = nil } label: {
                    if pending?.wrappedValue == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
                }
            }
            ForEach(store.t3Models) { option in
                Button { choose(option) } label: {
                    if isCurrent(option) { Label(option.label, systemImage: "checkmark") }
                    else { Text(option.label) }
                }
            }
            if let error { Text(error) }
        } label: {
            HStack(spacing: 4) {
                if switching { ProgressView().controlSize(.mini) }
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .disabled(switching)
        .accessibilityLabel("Model, \(label)")
        .accessibilityHint(chat == nil ? "Choose the model for this new space." : "Switch the model for this space.")
        .accessibilityIdentifier("t3-model-chip")
        .task(id: store.connectionGeneration) { await store.loadT3ModelsIfNeeded() }
    }

    private var label: String {
        if let pending { return pending.wrappedValue?.label ?? String(localized: "Automatic") }
        return store.t3ModelLabel(provider: chat?.providerInstanceID, model: chat?.model) ?? String(localized: "Automatic")
    }

    private func isCurrent(_ option: T3ModelOption) -> Bool {
        if let pending { return pending.wrappedValue?.id == option.id }
        return chat?.model == option.modelID && (chat?.providerInstanceID ?? option.providerInstanceID) == option.providerInstanceID
    }

    private func choose(_ option: T3ModelOption) {
        if let pending { pending.wrappedValue = option; return }
        guard let chat, !switching, !isCurrent(option) else { return }
        switching = true
        error = nil
        Task {
            defer { switching = false }
            do {
                try await store.setT3ChannelModel(threadID: chat.id, providerInstanceID: option.providerInstanceID,
                                                  model: option.modelID)
                UIAccessibility.post(notification: .announcement, argument: String(localized: "This space now uses \(option.label)"))
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// A friendly face and short copy for empty, loading and offline T3 surfaces.
struct T3FriendlyPlaceholder<Actions: View>: View {
    let avatarID: String
    var asleep = false
    let title: Text
    let message: Text
    @ViewBuilder var actions: Actions

    init(avatarID: String, asleep: Bool = false, title: LocalizedStringKey, message: LocalizedStringKey,
         @ViewBuilder actions: () -> Actions) {
        self.init(avatarID: avatarID, asleep: asleep, title: Text(title), message: Text(message), actions: actions)
    }

    init(avatarID: String, asleep: Bool = false, title: Text, message: Text, @ViewBuilder actions: () -> Actions) {
        self.avatarID = avatarID
        self.asleep = asleep
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            BotAvatar(profile: BotProfile(id: avatarID, name: ""), size: 72,
                      presentation: asleep ? .offline : .idle)
                .accessibilityHidden(true)
            title.font(.bottoRounded(.title3, weight: .bold)).multilineTextAlignment(.center)
            message.font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(.vertical, 28).padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension T3FriendlyPlaceholder where Actions == EmptyView {
    init(avatarID: String, asleep: Bool = false, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.init(avatarID: avatarID, asleep: asleep, title: Text(title), message: Text(message)) { EmptyView() }
    }

    init(avatarID: String, asleep: Bool = false, title: LocalizedStringKey, verbatim message: String) {
        self.init(avatarID: avatarID, asleep: asleep, title: Text(title), message: Text(verbatim: message)) { EmptyView() }
    }
}

enum T3TimeLabel {
    /// Compact relative stamps for dense rows: "now", "5m", "3h", "Yesterday", "Mar 4".
    static func compact(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "now") }
        if seconds < 3600 { return String(localized: "\(Int(seconds / 60))m") }
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "\(Int(seconds / 3600))h") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func spoken(_ date: Date, now: Date = .now) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

extension T3RoutineSchedule {
    static func summary(_ schedule: Self?, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let schedule else { return String(localized: "Custom schedule") }
        let time = calendar.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)).map {
            $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                          timeZone: calendar.timeZone))
        } ?? String(format: "%02d:%02d", schedule.hour, schedule.minute)
        let days: String = switch schedule.days {
        case Self.everyDay: String(localized: "Daily")
        case Self.weekdays: String(localized: "Weekdays")
        case Self.weekends: String(localized: "Weekends")
        default:
            schedule.days.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }
                .map { calendar.shortWeekdaySymbols[$0] }.joined(separator: ", ")
        }
        return "\(days) · \(time)"
    }
}
