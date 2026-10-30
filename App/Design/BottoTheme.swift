import SwiftUI
import UIKit

enum BottoTheme {
    static let needsYouSymbol = "questionmark.bubble.fill"

    static let paper = Color(.bottoPaper)
    static let surface = Color(.bottoSurface)
    static let ink = Color.primary
    static let coral = Color(.accent)
    static let action = Color(.accent)
    static let onAction = Color(.bottoOnAction)
    static let pressedAction = Color(.bottoPressedAction)
    static let selection = Color(.bottoSelection)
    static let onSelection = action
    static let attention = coral
    static let attentionSurface = selection
    static let error = Color(.bottoError)
    static let disabledForeground = Color(uiColor: .tertiaryLabel)
    static let disabledSurface = surface
    static let outgoing = Color(.bottoOutgoing)
    static let onOutgoing = Color(.bottoOnOutgoing)
}

extension View {
    /// Keep the canvas continuous while native bars own separation on scroll.
    @ViewBuilder func bottoNavigationChrome() -> some View {
        let canvas = containerBackground(BottoTheme.paper, for: .navigation)
            .containerBackground(BottoTheme.paper, for: .navigationSplitView)
        if #available(iOS 27, *) {
            canvas.toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            canvas
        }
    }
}

struct BottoPrimaryButtonStyle: ButtonStyle {
    var tint: Color = BottoTheme.action
    var pressedTint: Color = BottoTheme.pressedAction
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(isEnabled ? BottoTheme.onAction : BottoTheme.disabledForeground)
            .background(isEnabled ? (configuration.isPressed ? pressedTint : tint)
                        : BottoTheme.disabledSurface, in: Capsule())
            .contentShape(Capsule())
    }
}

struct BottoMark: View {
    var size: CGFloat = 34
    var body: some View {
        Image("BottoMark")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}

struct DemoBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Label("Demo workspace", systemImage: "sparkles")
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Demo workspace").fontWeight(.semibold)
                    Text("Sample bots, safely here.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(BottoTheme.surface)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Demo workspace. Sample bots only; no real actions are performed.")
    }
}

struct InlineNotice: View {
    let message: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(BottoTheme.attention)
            Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if let dismiss {
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
            }
        }
        .padding(.leading, 14).padding(.vertical, 10).padding(.trailing, dismiss == nil ? 14 : 0)
        .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}
