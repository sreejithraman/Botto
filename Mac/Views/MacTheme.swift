import AppKit
import BottoCore
import SwiftUI

// MARK: - Theme

/// Botto's warm paper palette, matching the phone app's asset catalog in both appearances.
enum MacTheme {
    static let paper = dynamic(light: (0.985, 0.977, 0.957), dark: (0.075, 0.073, 0.070))
    static let surface = dynamic(light: (0.945, 0.935, 0.912), dark: (0.135, 0.130, 0.123))
    static let surfaceDeep = dynamic(light: (0.915, 0.902, 0.872), dark: (0.175, 0.168, 0.159))
    static let action = dynamic(light: (0.66, 0.25, 0.0), dark: (1.0, 0.55, 0.44))
    static let pressedAction = dynamic(light: (0.56, 0.20, 0.0), dark: (1.0, 0.65, 0.54))
    static let onAction = dynamic(light: (1, 1, 1), dark: (0, 0, 0))
    static let selection = dynamic(light: (0.965, 0.89, 0.85), dark: (0.27, 0.16, 0.13))
    static let error = dynamic(light: (0.65, 0.12, 0.12), dark: (1.0, 0.4118, 0.3804))
    static let outgoing = dynamic(light: (0.12, 0.12, 0.11), dark: (0.88, 0.86, 0.82))
    static let onOutgoing = dynamic(light: (1, 1, 1), dark: (0, 0, 0))
    static let hairline = Color.primary.opacity(0.08)
    static let running = dynamic(light: (0.20, 0.52, 0.30), dark: (0.45, 0.80, 0.52))

    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded, weight: weight)
    }

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

struct MacPillButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MacTheme.rounded(.body, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: .capsule)
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }

    private var foreground: Color {
        guard isEnabled else { return .secondary }
        return prominent ? MacTheme.onAction : MacTheme.action
    }

    private func background(pressed: Bool) -> Color {
        guard isEnabled else { return MacTheme.surfaceDeep }
        if prominent { return pressed ? MacTheme.pressedAction : MacTheme.action }
        return pressed ? MacTheme.selection.opacity(0.7) : MacTheme.selection
    }
}

/// A quiet row on warm paper, separated by hairlines rather than boxed.
struct MacHairlineRow<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 11)
        .contentShape(.rect)
        .overlay(alignment: .bottom) { Rectangle().fill(MacTheme.hairline).frame(height: 1) }
    }
}

extension MacHairlineRow where Trailing == MacChevron {
    init(title: String, detail: String) {
        self.init(title: title, detail: detail) { MacChevron() }
    }
}

struct MacChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
    }
}

/// A friendly full-pane state: the bot's face, a short line of copy and an action.
struct MacMoodState<Actions: View>: View {
    let profileID: String
    let appearance: BotAppearance?
    let activity: MacAvatarActivity
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            MacBotAvatarView(profileID: profileID, appearance: appearance, activity: activity)
                .frame(width: 104, height: 104)
                .padding(.bottom, 6)
            Text(title)
                .font(MacTheme.rounded(.title2, weight: .bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 380)
            HStack(spacing: 10) { actions }
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension MacMoodState where Actions == EmptyView {
    init(profileID: String, appearance: BotAppearance?, activity: MacAvatarActivity, title: String, message: String) {
        self.init(profileID: profileID, appearance: appearance, activity: activity, title: title, message: message) {
            EmptyView()
        }
    }
}

