#if DEBUG
import SwiftUI
import BottoCore

struct BotMotionExperiment: Equatable {
    var style: BotMotionStyle = .playful
    var activity: BotMotionActivity = .idle
    var triggeredAt: Date = .now
    var workStartedAt: Date = .now
    var followsLiveActivity = false
}

private struct BotMotionExperimentKey: EnvironmentKey {
    static let defaultValue: BotMotionExperiment? = nil
}

private struct BotMotionActivityKey: EnvironmentKey {
    static let defaultValue: BotMotionActivity? = nil
}

extension EnvironmentValues {
    var botMotionActivity: BotMotionActivity? {
        get { self[BotMotionActivityKey.self] }
        set { self[BotMotionActivityKey.self] = newValue }
    }
    var botMotionExperiment: BotMotionExperiment? {
        get { self[BotMotionExperimentKey.self] }
        set { self[BotMotionExperimentKey.self] = newValue }
    }
}

/// Disposable comparison surface. Its fixtures and demo store never connect to Hermes.
struct BotMotionPrototype: View {
    var onClose: (() -> Void)? = nil
    @State private var experiment = BotMotionExperiment()
    @State private var forceStill = false
    @State private var avatarSize = 88.0
    @State private var inApp = false
    @State private var demo = AppStore(
        service: DemoBotService(),
        persistence: ConnectionPersistence(load: { nil }, save: { _ in }, remove: {})
    )
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private let bots = [
        BotProfile(id: "motion-milo", name: "Milo", preview: "A little company for your day.",
                   appearance: BotAppearance(shape: .squircle, color: "#8b5cf6")),
        BotProfile(id: "motion-scout", name: "Scout", preview: "I've found a few things you'll like.",
                   appearance: BotAppearance(shape: .triangle, color: "#f59e0b")),
        BotProfile(id: "motion-canvas", name: "Canvas", preview: "Ready to make something together?",
                   appearance: BotAppearance(shape: .cloud, color: "#14b8a6"))
    ]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if inApp {
                    RootView(store: demo)
                        .task { if !demo.isDemo { await demo.enterDemo() } }
                } else {
                    gallery
                }
            }
            controls
        }
        .environment(\.botMotionExperiment, {
            var value = experiment
            value.followsLiveActivity = inApp
            return value
        }())
        .environment(\.avatarMotionDisabledForTesting, forceStill)
        .tint(BottoTheme.action)
    }

    private var gallery: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MOTION FOLLOWS ACTIVITY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("A little character in every state.").font(.title3.weight(.medium))
                        Text("Tap a state to compare. These samples use the same animation renderer as your bots. Try the isolated demo to follow activity.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                        ForEach(BotMotionActivity.allCases) { activity in
                            Button {
                                selectActivity(activity)
                            } label: {
                                VStack(spacing: 8) {
                                    BotAvatar(profile: bots[0], size: 56)
                                        .environment(\.botMotionActivity, activity)
                                    Text(activity.rawValue).font(.caption.weight(.medium))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(experiment.activity == activity ? BottoTheme.action : .clear, lineWidth: 1.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Preview \(activity.rawValue)")
                            .accessibilityAddTraits(experiment.activity == activity ? .isSelected : [])
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(experiment.activity.rawValue).font(.headline)
                        Text(experiment.activity.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 84, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Avatar size").font(.subheadline)
                            Spacer()
                            Text("\(Int(avatarSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $avatarSize, in: 30...96, step: 1)
                            .accessibilityLabel("Avatar size")
                    }
                    HStack(spacing: 16) {
                        ForEach(bots) { bot in
                            VStack(spacing: 10) {
                                BotAvatar(profile: bot, size: avatarSize).frame(height: 140)
                                Text(bot.name).font(.subheadline.weight(.medium))
                            }.frame(maxWidth: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("In your inbox · 56 pt").font(.caption).foregroundStyle(.secondary)
                        ForEach(bots) { bot in
                            BotRow(bot: bot, image: nil, unread: false, aggregate: nil)
                            if bot.id != bots.last?.id { Divider().padding(.leading, 74) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("In a chat · 30 pt").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            BotAvatar(profile: bots[0], size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Milo").font(.headline)
                                Text(experiment.activity.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
                        }.padding(16).background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Every shape · 48 pt").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 18) {
                            ForEach(BotAvatarShape.allCases) { shape in
                                VStack(spacing: 6) {
                                    BotAvatar(profile: BotProfile(id: "motion-\(shape.rawValue)", name: shape.rawValue,
                                              appearance: BotAppearance(shape: shape, color: "#8b5cf6")), size: 48)
                                    Text(shape.rawValue.capitalized).font(.caption2)
                                }
                            }
                        }
                    }
                    Text("Sample controls stay in this playground. Saved images and avatar-picker previews stay still.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .background(BottoTheme.paper)
            .navigationTitle("Avatar playground")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onClose)
                            .accessibilityIdentifier("developer.closeAvatarPlayground")
                    }
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Text("PLAYGROUND").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                if inApp, let onClose {
                    Button("Done", action: onClose)
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        .accessibilityIdentifier("developer.closeAvatarPlayground")
                }
                Spacer()
                Button(inApp ? "Back to lab" : "Try in demo") { inApp.toggle() }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            Picker("Motion style", selection: $experiment.style) {
                ForEach(BotMotionStyle.allCases) { style in Text(style.rawValue).tag(style) }
            }.pickerStyle(.segmented)
            HStack {
                if inApp {
                    Text("Following each bot's live activity").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                } else {
                    Picker("Activity", selection: Binding(get: { experiment.activity }, set: { selectActivity($0) })) {
                        ForEach(BotMotionActivity.allCases) { activity in Text(activity.rawValue).tag(activity) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Replay") {
                        let now = Date.now
                        experiment.triggeredAt = now
                        experiment.workStartedAt = now
                    }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                }
            }
            Toggle(systemReduceMotion ? "Reduce Motion is on in iOS" : "Preview Reduce Motion",
                   isOn: Binding(get: { forceStill || systemReduceMotion }, set: { forceStill = $0 }))
                .font(.subheadline).disabled(systemReduceMotion)
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
        .background(.regularMaterial)
    }

    private func selectActivity(_ activity: BotMotionActivity) {
        let now = Date.now
        if activity.isWorkingPhase && (!experiment.activity.isWorkingPhase || activity == experiment.activity) {
            experiment.workStartedAt = now
        }
        experiment.activity = activity
        experiment.triggeredAt = now
    }
}

struct BotMotionPrototypeFace: View {
    let profile: BotProfile
    let size: CGFloat
    let experiment: BotMotionExperiment
    let still: Bool
    @Environment(\.botMotionActivity) private var observedActivity

    var body: some View {
        let activity = observedActivity ?? experiment.activity
        let value = BotAvatarPresentation(activity: activity, enteredAt: experiment.triggeredAt,
            workStartedAt: experiment.workStartedAt)
        BotAvatarMotion(profile: profile, size: size, presentation: value, style: experiment.style, still: still)
    }
}
#endif
