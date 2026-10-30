import SwiftUI
import BottoCore

/// Panning belongs to the diagram only while enlarged. At fit size the chat's
/// scroll view keeps the gesture. Zoom never restarts an untrusted document.
struct DiagramImageView: View {
    static let controlsHeight: CGFloat = 52
    let presentation: DiagramPresentation
    let block: ReplyContent.Block
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    private var scale: CGFloat { min(8, max(1, zoom * magnification)) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    DiagramPixelsView(presentation: presentation)
                        .accessibilityLabel(block.previewFormat == .mermaid ? "Mermaid diagram" : "SVG preview")
                        .frame(width: geometry.size.width * scale, height: geometry.size.height * scale,
                               alignment: .topLeading)
                        .accessibilityAddTraits(.isImage)
                        .accessibilityValue(block.source)
                        .accessibilityHint("Use Zoom diagram to enlarge, then scroll. Use Fit diagram to reset. Source contains the diagram code.")
                }
                .scrollDisabled(scale == 1)
                .simultaneousGesture(MagnifyGesture()
                    .updating($magnification) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(8, max(1, zoom * value.magnification)) })
            }
            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Button { zoom = min(8, zoom * 2) } label: {
                        Image(systemName: "plus.magnifyingglass").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Zoom diagram")
                    .disabled(zoom == 8)
                    Button { zoom = 1 } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Fit diagram")
                    .disabled(zoom == 1)
                }
                .buttonStyle(.borderless)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(4)
            }
            .frame(height: Self.controlsHeight)
        }
    }
}
