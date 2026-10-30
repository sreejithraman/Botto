import SwiftUI
import BottoCore

struct BotProfileView: View {
    let store: AppStore
    let bot: BotProfile
    let isCurrent: () -> Bool
    @Binding var editor: AppStore.AvatarDestination?
    private var current: BotProfile { store.bot(withID: bot.id) ?? bot }

    var body: some View {
        VStack(spacing: 12) {
            AppBotAvatar(store: store, bot: current, size: 72)
                .frame(width: 96, height: 96)
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        guard isCurrent(), editor == nil else { return }
                        editor = store.avatarDestination(for: current)
                    } label: {
                        Image(systemName: "pencil").font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(BottoTheme.surface, in: Circle())
                            .overlay(Circle().strokeBorder(BottoTheme.paper, lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BottoTheme.ink)
                    .accessibilityLabel("Edit \(current.name)")
                    .accessibilityIdentifier("bot-profile-edit")
                    .disabled(!isCurrent() || editor != nil)
                }
            Text(current.name).font(.title2.weight(.semibold))
                .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            if !current.description.isEmpty {
                Text(current.description).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Server") { Text(store.serverName).textSelection(.enabled) }
                    if let model = current.model, !model.isEmpty {
                        LabeledContent("Model") { Text(model).textSelection(.enabled) }
                    }
                    Text(store.isDemo ? "This sample stays on your device." : "Tools and model settings come from your Hermes.")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline).padding(.top, 12)
            } label: {
                Label(store.isConnected ? store.serverName : "Offline · \(store.serverName)", systemImage: "house")
                    .font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("bot-profile-details")
        }
        .frame(maxWidth: .infinity)
        .navigationDestination(isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })) {
            if let editor {
                BotProfileEditor(store: store, destination: editor).id(editor.id)
            }
        }
        .onChange(of: editor.map { $0.isCurrent(in: store) }) { _, current in
            if current == false { editor = nil }
        }
    }
}
