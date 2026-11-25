import BottoCore
import SwiftUI

/// What someone has picked on the first-run page so far. The window owns it, so a dropped connection keeps it.
struct MacFirstBotDraft: Equatable {
    var name = ""
    var face: BotFace?
}

/// First run: the bot gets a name, which its main space shares, and a face.
struct MacFirstBotPage: View {
    let store: MacBottoStore
    let bot: BotProfile
    @Binding var draft: MacFirstBotDraft
    @State private var saving = false
    @State private var error: String?
    @FocusState private var naming: Bool

    /// Leaving the name alone keeps the one the bot came with.
    private var name: String {
        let typed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? bot.name : typed
    }
    private var face: BotFace { draft.face ?? (bot.appearance ?? BotAppearance()).face(for: bot.id) }
    private var appearance: BotAppearance { BotAvatarChoice.face(face).appearance }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    MacBotAvatarView(profileID: bot.id, appearance: appearance, activity: saving ? .thinking : .idle)
                        .frame(width: 124, height: 124)
                    Text("Meet your new bot")
                        .font(MacTheme.rounded(.largeTitle, weight: .heavy))
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 14)
                    Text("Give it a name and a face. You can change both whenever you like.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                    nameField.padding(.top, 22)
                    shapes.padding(.top, 22)
                    colors.padding(.top, 16)
                    if let error {
                        Text(error).font(.callout).foregroundStyle(MacTheme.error).multilineTextAlignment(.center)
                            .padding(.top, 16)
                    }
                    Button(saving ? "Saving…" : "Say hello to \(name)", action: save)
                        .buttonStyle(MacPillButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving)
                        .lineLimit(1)
                        .padding(.top, 26)
                        .accessibilityIdentifier("mac-first-bot-save")
                }
                .frame(maxWidth: 480)
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(MacTheme.paper)
        .disabled(saving)
        .onAppear { naming = true }
    }

    private var nameField: some View {
        VStack(spacing: 6) {
            TextField("Name", text: $draft.name, prompt: Text(bot.name))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(MacTheme.rounded(.title2, weight: .bold))
                .focused($naming)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(width: 300)
                .background(MacTheme.surface, in: .rect(cornerRadius: 16))
                .accessibilityLabel("Your bot’s name")
                .accessibilityIdentifier("mac-first-bot-name")
            Text("Its main space gets this name too.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var shapes: some View {
        HStack(spacing: 6) {
            ForEach(BotAvatarShape.pickerCases) { shape in
                let selected = face.shape == shape
                Button { draft.face = BotFace(shape: shape, color: face.color) } label: {
                    MacBotAvatarView(profileID: bot.id, appearance: BotAppearance(shape: shape, color: face.color), animated: false)
                        .frame(width: 40, height: 40)
                        .padding(6)
                        .background(selected ? MacTheme.selection : .clear, in: .rect(cornerRadius: 14))
                        .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(shape.rawValue.capitalized) face")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var colors: some View {
        let current = BotAvatarColors.preset(for: face.color)?.id
        return HStack(spacing: 11) {
            ForEach(BotAvatarColors.presets) { preset in
                let selected = current == preset.id
                Button { draft.face = BotFace(shape: face.shape, color: preset.hex) } label: {
                    Circle()
                        .fill(Color(hex: preset.hex))
                        .frame(width: 24, height: 24)
                        .overlay { if selected { Circle().stroke(Color.primary, lineWidth: 2).padding(-4) } }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.id.capitalized)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await store.setUpBot(name: name, face: face)
                draft = MacFirstBotDraft()
            } catch { self.error = T3FirstRun.message(for: error) }
        }
    }
}
