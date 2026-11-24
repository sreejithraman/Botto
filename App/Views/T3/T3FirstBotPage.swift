import SwiftUI
import BottoCore

/// First run: the bot gets a name, which its main space shares, and a face.
struct T3FirstBotPage: View {
    let store: AppStore
    let bot: BotProfile
    let onSettings: () -> Void

    @State private var name = ""
    @State private var picked: BotFace?
    @State private var saving = false
    @State private var error: String?
    @State private var connectionRequested = false
    @FocusState private var naming: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Leaving the name alone keeps the one the bot came with.
    private var chosenName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? bot.name : typed
    }
    private var largeText: Bool { dynamicTypeSize.isAccessibilitySize }
    private var face: BotFace { picked ?? (bot.appearance ?? BotAppearance()).face(for: bot.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                BotAvatar(profile: preview(face), size: 120)
                    .frame(height: 120, alignment: .bottom)
                    .accessibilityHidden(true)
                Text("Meet your new bot")
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 14)
                Text("Give it a name and a face. You can change both whenever you like.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                nameField.padding(.top, 22)
                shapes.padding(.top, 22)
                colors.padding(.top, 14)
                if largeText { footer.padding(.top, 22) }
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { settings }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            // Large text leaves no room for a pinned button beside the keyboard, so it scrolls with the page.
            if !largeText {
                footer.padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(BottoTheme.paper)
            }
        }
        .background(BottoTheme.paper.ignoresSafeArea())
        .disabled(saving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("t3-first-bot")
        .onChange(of: store.isConnected) { _, connected in if connected { connectionRequested = false } }
    }

    /// The way to another Mac or the demo, for someone who didn't mean to set up this one.
    private var settings: some View {
        Button("Settings", systemImage: "gearshape") { naming = false; onSettings() }
            .labelStyle(.iconOnly).font(.body).foregroundStyle(.secondary)
            .frame(width: 44, height: 44).contentShape(Rectangle())
            .padding(.trailing, 10)
            .accessibilityIdentifier("t3-first-bot-settings")
    }

    private var nameField: some View {
        VStack(spacing: 8) {
            TextField("Name", text: $name, prompt: Text(bot.name))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
                .textContentType(.nickname)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($naming)
                .padding(.horizontal, 16).frame(minHeight: 56)
                .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityLabel("Your bot’s name")
                .accessibilityIdentifier("t3-first-bot-name")
            Text("Its main space gets this name too.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var shapes: some View {
        LazyVGrid(columns: columns(4), spacing: 8) {
            ForEach(BotAvatarShape.pickerCases) { shape in
                let selected = face.shape == shape
                Button {
                    naming = false
                    if !selected { BottoHaptics.shared.play(.avatarSelection) }
                    picked = BotFace(shape: shape, color: face.color)
                } label: {
                    BotAvatar(profile: preview(BotFace(shape: shape, color: face.color)), size: 46, motion: .still)
                        .padding(8)
                        .background(selected ? BottoTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(shape.label) face")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("t3-first-bot-shape-\(shape.rawValue)")
            }
        }
    }

    private var colors: some View {
        let current = BotAvatarColor.matching(face.color)?.id
        return LazyVGrid(columns: columns(6), spacing: 2) {
            ForEach(BotAvatarColors.presets) { preset in
                let selected = current == preset.id
                Button {
                    naming = false
                    if !selected { BottoHaptics.shared.play(.selection) }
                    picked = BotFace(shape: face.shape, color: preset.hex)
                } label: {
                    Circle().fill(Color.botBody(preset.hex))
                        .frame(width: 28, height: 28)
                        .overlay { if selected { Circle().stroke(BottoTheme.ink, lineWidth: 2).padding(-4) } }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(BotAvatarColor.matching(preset.hex)?.localizedName ?? preset.id)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("t3-first-bot-color-\(preset.id)")
            }
        }
    }

    /// Four shapes or six colors to a row, so neither leaves a stray one behind.
    private func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: count)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if connectionRequested, !store.isConnected { ConnectionStatusView(store: store) }
            if let error { InlineNotice(message: error) { self.error = nil } }
            Button(action: save) {
                Text(saving ? "Saving…" : "Say hello to \(chosenName)")
                    .lineLimit(largeText ? 3 : 1)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.vertical, 14)
            }
            .buttonStyle(BottoPrimaryButtonStyle())
            .accessibilityIdentifier("t3-first-bot-save")
        }
        .frame(maxWidth: 480)
    }

    private func preview(_ face: BotFace) -> BotProfile {
        BotProfile(id: bot.id, name: "", appearance: BotAppearance(shape: face.shape, color: face.color))
    }

    private func save() {
        guard !saving else { return }
        naming = false
        guard store.isConnected else { connectionRequested = true; return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await store.setUpT3Bot(name: chosenName, face: face)
                BottoHaptics.shared.play(.celebration)
            } catch {
                self.error = T3FirstRun.message(for: error)
                if !store.isConnected { connectionRequested = true }
            }
        }
    }
}
