#if DEBUG || BOTTO_INTERNAL_TOOLS
import SwiftUI

struct DeveloperMenuView: View {
    var onBackToApp: (() -> Void)? = nil
    @State private var presentedTool: DeveloperTool?

    var body: some View {
        List {
            Section("Playgrounds") {
                Button {
                    presentedTool = .avatarPlayground
                } label: {
                    Label("Avatar playground", systemImage: "face.smiling")
                }
                .accessibilityIdentifier("developer.avatarPlayground")
                Button {
                    presentedTool = .hapticsPlayground
                } label: {
                    Label("Haptics playground", systemImage: "waveform.path")
                }
                .accessibilityIdentifier("developer.hapticsPlayground")
            }
        }
        .scrollContentBackground(.hidden)
        .background(BottoTheme.paper, ignoresSafeAreaEdges: [])
        .bottoNavigationChrome()
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onBackToApp {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left", action: onBackToApp)
                        .accessibilityLabel("Back to app")
                }
            }
        }
        .fullScreenCover(item: $presentedTool) { tool in
            switch tool {
            case .avatarPlayground:
                AvatarPlaygroundPresentation()
            case .hapticsPlayground:
                HapticsPlayground()
            }
        }
    }
}

private enum DeveloperTool: Hashable, Identifiable {
    case avatarPlayground
    case hapticsPlayground

    var id: Self { self }
}

private struct AvatarPlaygroundPresentation: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BotMotionPrototype(onClose: { dismiss() })
    }
}
#endif
