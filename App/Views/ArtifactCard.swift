import SwiftUI
import BottoCore
import UniformTypeIdentifiers

struct ArtifactCard: View {
    let attachment: ChatAttachment
    var outgoing = false
    var open: (() -> Void)?

    private var typeName: String {
        UTType(mimeType: attachment.mimeType)?.localizedDescription ?? "File"
    }

    var body: some View {
        Button { open?() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.name).font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(typeName).font(.caption).opacity(0.7)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(outgoing ? Color.white.opacity(0.1) : BottoTheme.surface,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        .accessibilityLabel("Open \(attachment.name)")
        .accessibilityValue(typeName)
        .accessibilityHint(open == nil ? "Reconnect to open this file." : "Preview, save, or share this file.")
    }
}
