#if DEBUG
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
            }
        }
    }
}

private enum DeveloperTool: Hashable, Identifiable {
    case avatarPlayground

    var id: Self { self }
}

private struct AvatarPlaygroundPresentation: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BotMotionPrototype(onClose: { dismiss() })
    }
}
#endif
