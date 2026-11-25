import AppKit
import BottoCore
import SwiftUI

/// Plain words for what each provider still needs.
enum MacProviderCopy {
    /// One card per provider, whichever of its accounts is closest to working.
    static func cards(_ providers: [T3ProviderStatus]) -> [(guide: T3ProviderStatus.Guide, state: T3ProviderStatus.State)] {
        let closest: [T3ProviderStatus.State] = [.needsSignIn, .notWorking, .notInstalled, .off]
        return T3ProviderStatus.Guide.allCases.compactMap { guide in
            let states = providers.filter { $0.guide == guide }.map(\.state)
            return closest.first(where: states.contains).map { (guide, $0) }
        }
    }

    static func status(_ state: T3ProviderStatus.State) -> String {
        switch state {
        case .ready: "Ready"
        case .needsSignIn: "Installed. Just needs you to sign in."
        case .notInstalled: "Not on this Mac yet."
        case .notWorking: "Installed, but not answering right now."
        case .off: "Turned off on this Mac."
        }
    }

    static func step(_ state: T3ProviderStatus.State) -> String {
        switch state {
        case .needsSignIn: "Open Terminal, paste this, and follow along in your browser:"
        case .notWorking: "Open it once from Terminal to see what it needs, then come back."
        case .off: "Turn it back on in the engine’s settings, then come back."
        case .notInstalled, .ready: "Install it, sign in once, then come back."
        }
    }

    static func summary(_ providers: [T3ProviderStatus], botName: String) -> String {
        cards(providers).contains { $0.state == .needsSignIn }
            ? "\(botName) can’t think until you sign in to Claude or Codex."
            : "\(botName) needs Claude or Codex on this Mac to think."
    }
}

/// Shown in place of an empty space while no provider on this Mac can answer.
struct MacProviderGuide: View {
    let store: MacBottoStore

    var body: some View {
        let name = store.bot?.name ?? "Botto"
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    MacBotAvatarView(profileID: store.bot?.id ?? "main", appearance: store.bot?.appearance, activity: .sleeping)
                        .frame(width: 104, height: 104)
                    Text("\(name) needs a brain")
                        .font(MacTheme.rounded(.title, weight: .heavy))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 14)
                    Text("\(name) thinks with Claude or Codex, using your own account. Set up either one and \(name) wakes right up.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                    MacProviderCards(store: store)
                        .padding(.top, 26)
                }
                .frame(maxWidth: 500)
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(MacTheme.paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-provider-guide")
    }
}

/// The same news over a conversation that is already under way, which stays readable below it.
struct MacProviderBanner: View {
    let store: MacBottoStore
    @State private var showsGuide = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill").foregroundStyle(MacTheme.action)
            Text(MacProviderCopy.summary(store.providersNeedingSetup, botName: store.bot?.name ?? "Botto"))
                .font(.callout)
            Spacer(minLength: 8)
            Button("Show me how") { showsGuide = true }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(MacTheme.action)
                .popover(isPresented: $showsGuide, arrowEdge: .bottom) {
                    MacProviderCards(store: store)
                        .padding(18)
                        .frame(width: 440)
                        .background(MacTheme.paper)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(MacTheme.surface, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-provider-banner")
    }
}

private struct MacProviderCards: View {
    let store: MacBottoStore

    var body: some View {
        VStack(spacing: 12) {
            ForEach(MacProviderCopy.cards(store.providersNeedingSetup), id: \.guide) { card in
                MacProviderCard(guide: card.guide, state: card.state)
            }
            MacProviderRecheck(store: store)
                .padding(.top, 8)
        }
    }
}

private struct MacProviderRecheck: View {
    let store: MacBottoStore

    var body: some View {
        VStack(spacing: 8) {
            Button(store.isCheckingProviders ? "Checking…" : "Check again") {
                Task { await store.loadProviders() }
            }
            .buttonStyle(MacPillButtonStyle(prominent: false))
            .disabled(store.isCheckingProviders)
            .accessibilityIdentifier("mac-provider-recheck")
            Text("Botto also checks whenever you come back to this window.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct MacProviderCard: View {
    let guide: T3ProviderStatus.Guide
    let state: T3ProviderStatus.State
    @State private var copied = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(guide.name).font(MacTheme.rounded(.title3, weight: .bold))
                Spacer(minLength: 8)
                Text(MacProviderCopy.status(state)).font(.callout).foregroundStyle(.secondary)
            }
            switch state {
            case .needsSignIn:
                step {
                    HStack(spacing: 10) {
                        Text(guide.signInCommand)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(MacTheme.paper, in: .rect(cornerRadius: 9))
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(guide.signInCommand, forType: .string)
                        }
                        .buttonStyle(MacPillButtonStyle(prominent: false))
                        .accessibilityLabel(copied ? "Copied sign-in command" : "Copy sign-in command")
                        Button("Open Terminal") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                        }
                        .buttonStyle(MacPillButtonStyle(prominent: false))
                    }
                }
            case .notWorking, .off:
                step { EmptyView() }
            case .notInstalled, .ready:
                step {
                    Button("Get \(guide.name)") { openURL(guide.installPage) }
                        .buttonStyle(MacPillButtonStyle(prominent: true))
                        .accessibilityHint("Opens the install page in your browser")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    private func step(@ViewBuilder actions: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MacProviderCopy.step(state)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            actions()
        }
    }
}
