import SwiftUI
import BottoCore

struct OnboardingView: View {
    let store: AppStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var openingDemo = false
    @State private var confirmsForget = false
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 32)
                        VStack(spacing: 20) {
                            BottoGreeting(style: .welcome)
                            Text(BottoBrand.tagline)
                                .font(.title3).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 280)
                        }
                        .frame(maxWidth: 440)
                        Spacer(minLength: 48)
                        actions
                    }
                    .padding(.horizontal, 28).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            .background(BottoTheme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("Forget this connection?", isPresented: $confirmsForget, titleVisibility: .visible) {
                Button("Forget on this device", role: .destructive) { Task { await store.forgetConnectionWithPush() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saved sign-in details, drafts, and cached messages will be removed locally. Botto also removes this device's notification pairings. Your bots and chats stay on Hermes.")
            }
        }
    }
    private var actions: some View {
        VStack(spacing: store.savedSetupLoadFailed ? 16 : 5) {
            if let notice = store.notice {
                InlineNotice(message: notice) { store.notice = nil }
            }
            if store.savedSetupLoadFailed {
                savedSetupRecovery
            } else {
                Button { store.showsConnection = true } label: {
                    primaryLabel("Connect your Hermes")
                }
                .buttonStyle(BottoPrimaryButtonStyle())
            }
            Button {
                guard !openingDemo else { return }
                openingDemo = true
                Task { await store.enterDemo(); openingDemo = false }
            } label: {
                Text(openingDemo ? "Opening demo…" : "Explore the demo")
                    .font(.headline).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(openingDemo)
        }
        .padding(.top, 12)
        .frame(maxWidth: 500).frame(maxWidth: .infinity)
    }

    private var savedSetupRecovery: some View {
        VStack(spacing: 16) {
            recoveryMessage
            Button { store.retrySavedSetup() } label: {
                primaryLabel("Retry saved setup")
            }
            .buttonStyle(BottoPrimaryButtonStyle(tint: BottoTheme.error,
                                                       pressedTint: BottoTheme.error.opacity(0.85)))
            Button(role: .destructive) { confirmsForget = true } label: {
                Text("Forget saved setup")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(BottoTheme.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saved-setup-recovery")
    }

    private var recoveryMessage: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.title2)
                .foregroundStyle(BottoTheme.error)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Can’t open saved setup")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(store.connectionError ?? "Try again to open your saved connection.")
                    .font(.subheadline)
                    .foregroundStyle(BottoTheme.ink)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func primaryLabel(_ title: String) -> some View {
        Text(title)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 32).padding(.vertical, 16)
    }

}
