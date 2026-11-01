#if DEBUG || BOTTO_INTERNAL_TOOLS
import SwiftUI
import BottoCore

struct HapticsPlayground: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var haptics = BottoHaptics.shared
    @State private var presentation = BotAvatarPresentation.idle
    @State private var showsSheet = false
    private let bot = BotProfile(id: "haptics-milo", name: "Milo",
                                appearance: BotAppearance(shape: .squircle, color: "#8b5cf6"))

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Haptics", selection: $haptics.mode) {
                        ForEach(HapticMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("haptics.mode")
                    Toggle("Pulse while streaming", isOn: $haptics.streamingEnabled)
                        .disabled(haptics.mode == .off)
                } footer: {
                    Text("These controls use your app preferences. Use a physical iPhone to compare the feel.")
                }
                Section {
                    HStack {
                        Spacer()
                        BotAvatarMotion(profile: bot, size: 88, presentation: presentation,
                                        still: reduceMotion)
                            .frame(width: 140, height: 140)
                            .accessibilityLabel("Milo, \(presentation.activity.rawValue)")
                        Spacer()
                    }
                    Button("Open sample sheet", systemImage: "rectangle.bottomthird.inset.filled") {
                        showsSheet = true
                    }
                    .accessibilityIdentifier("haptics.openSheet")
                } header: {
                    Text("In context")
                }
                Section("Vocabulary") {
                    ForEach(HapticEvent.allCases) { event in
                        Button {
                            preview(event)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).foregroundStyle(BottoTheme.ink)
                                Text(event.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("haptics.preview.\(event.rawValue)")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(BottoTheme.paper, ignoresSafeAreaEdges: [])
            .bottoNavigationChrome()
            .navigationTitle("Haptics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showsSheet) {
                HapticSampleSheet()
                    .hapticSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onDisappear { haptics.cancel() }
        }
    }

    private func preview(_ event: HapticEvent) {
        let activity: BotMotionActivity = switch event {
        case .attention: .waiting
        case .replyFinished, .celebration: .finished
        case .error: .failed
        case .streaming: .replying
        default: .idle
        }
        presentation = .init(activity: activity, enteredAt: .now, reactionID: UUID())
        haptics.play(event)
    }
}

private struct HapticSampleSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("A soft arrival").font(.title2.weight(.semibold))
                Text("Compare opening this sheet in Subtle and Playful. Drag between its two heights to check the native interaction.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BottoTheme.paper, ignoresSafeAreaEdges: [])
            .bottoNavigationChrome()
            .navigationTitle("Sample sheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
