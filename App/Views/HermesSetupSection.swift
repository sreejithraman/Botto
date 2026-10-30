import SwiftUI
import UIKit

struct HermesSetupSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hasCopiedPrompt = false
    @State private var showsPreview = false

    private let copyConfirmation = "Prompt copied. Paste it into your chat with Hermes."

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Need a connection link?")
                        .font(.headline)
                    Text("Send this setup prompt to your Hermes chat.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        copyButton
                        shareButton
                    }
                } else {
                    HStack(spacing: 12) {
                        copyButton
                        shareButton
                    }
                }

                previewButton

                if hasCopiedPrompt {
                    Text(copyConfirmation)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .sheet(isPresented: $showsPreview) {
            promptPreview
                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = HermesSetupPrompt.text
            hasCopiedPrompt = true
            UIAccessibility.post(notification: .announcement, argument: copyConfirmation)
        } label: {
            actionLabel("Copy prompt", systemImage: "doc.on.doc")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy setup prompt")
        .accessibilityIdentifier("setup-copy-prompt")
    }

    private var shareButton: some View {
        ShareLink(item: HermesSetupPrompt.text) {
            actionLabel("Share", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share instructions")
        .accessibilityIdentifier("setup-share-prompt")
    }

    private var previewButton: some View {
        Button { showsPreview = true } label: {
            Text("Preview prompt")
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(BottoTheme.action)
        .accessibilityLabel("Preview setup prompt")
        .accessibilityIdentifier("setup-prompt-preview")
    }

    private var promptPreview: some View {
        NavigationStack {
            ScrollView {
                Text(HermesSetupPrompt.text)
                    .font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .accessibilityIdentifier("setup-prompt-text")
            }
            .background(BottoTheme.paper)
            .bottoNavigationChrome()
            .navigationTitle("Setup prompt")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    Image(systemName: systemImage)
                    Text(title)
                }
            } else {
                Label(title, systemImage: systemImage)
            }
        }
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(BottoTheme.action)
            .background(BottoTheme.surface, in: Capsule())
            .contentShape(Capsule())
    }
}
