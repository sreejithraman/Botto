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

/// The same picture or file glyph in the composer and on a sent message.
private struct AttachmentFace: View {
    let name: String
    let isImage: Bool
    let thumbnail: UIImage?
    let size: CGSize
    /// Leaves the middle of a tile free for its ring until a preview arrives.
    var isPending = false

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else if isPending {
                Text(name).font(.caption2).lineLimit(1).truncationMode(.middle).padding(8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: isImage ? "photo" : "doc").font(.title3)
                    Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                        .truncationMode(.middle).padding(.horizontal, 8)
                }
            }
        }
        // A document reads from its top; a photo crops around its middle.
        .frame(width: size.width, height: size.height, alignment: thumbnail == nil || isImage ? .center : .top)
    }
}

extension PendingAttachment.Phase {
    var label: String {
        switch self {
        case .queued: "Waiting to attach"
        case .reading: "Reading"
        case .uploading: "Uploading"
        case .stopping: "Cancelling"
        }
    }
}

/// A file in the composer. A pending file keeps its ring until it is attached.
struct StagedAttachmentTile: View {
    private static let side: CGFloat = 76
    let name: String
    let isImage: Bool
    let thumbnail: UIImage?
    var pending: PendingAttachment.Phase?
    let removable: Bool
    let remove: () -> Void

    var body: some View {
        AttachmentFace(name: name, isImage: isImage, thumbnail: thumbnail, size: CGSize(width: Self.side, height: Self.side),
                       isPending: pending != nil)
            .background(BottoTheme.surface)
            .overlay {
                if pending != nil {
                    if thumbnail != nil { Color.black.opacity(0.32) }
                    AttachmentActivityRing(color: thumbnail == nil ? .accentColor : .white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .ignore).accessibilityLabel(name)
            .accessibilityValue(pending?.label ?? "")
            .accessibilityIdentifier(pending == nil ? "composer-attachment" : "composer-pending-attachment")
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(.black.opacity(0.62), in: Circle())
                        .frame(width: 44, height: 44, alignment: .topTrailing).padding(3).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(pending == nil ? "Remove \(name)" : "Cancel \(name)")
                .disabled(!removable || pending == .stopping)
            }
    }
}

private struct AttachmentActivityRing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
        .onAppear { spinning = !reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in spinning = !reduced }
    }
}

/// Where a card sits in a fanned deck. `distance` counts pages from the front card and
/// is negative for cards already swiped past.
struct AttachmentFanPose: Equatable {
    static let visibleDepth: CGFloat = 3
    private static let peek: CGFloat = 26
    private static let deeperPeek: CGFloat = 9
    private static let tuckedScale: CGFloat = 0.93
    private static let deeperScale: CGFloat = 0.05
    private static let turn = 16.0
    private static let swingShare: CGFloat = 0.55
    private static let swingTilt = 7.0

    let x: CGFloat
    let scale: CGFloat
    let tilt: Double
    let turn: Double
    let opacity: Double

    init(distance: CGFloat, cardWidth: CGFloat, reduceMotion: Bool) {
        let side: CGFloat = distance < 0 ? -1 : 1
        let depth = abs(distance)
        let tucked = min(depth, 1)
        let deeper = min(max(depth - 1, 0), 1)
        // Only the card leaving the front swings out; the next one rises straight into place.
        let swing = !reduceMotion && distance < 0 && depth < 1 ? sin(.pi * depth) : 0

        x = side * (Self.peek * tucked + Self.deeperPeek * deeper) - cardWidth * Self.swingShare * swing
        scale = 1 - (1 - Self.tuckedScale) * tucked - Self.deeperScale * deeper
        tilt = -Self.swingTilt * Double(swing)
        turn = reduceMotion ? 0 : Double(side * tucked) * Self.turn
        opacity = Double(min(max(Self.visibleDepth - depth, 0), 1))
    }
}

/// A sent message's attachments as a fanned deck. A clear paging scroll view takes the
/// touches, so swipes keep native axis locking with the transcript, and its offset
/// poses the cards drawn beneath it.
struct SentAttachmentStack: View {
    private static let card = CGSize(width: 204, height: 264)
    private static let cornerRadius: CGFloat = 22
    private static let fanMargin: CGFloat = 32
    let attachments: [ChatAttachment]
    let thumbnails: AttachmentThumbnails
    let open: ((ChatAttachment) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    private var position: Int { Int(progress.rounded()) }
    private var nearbyAttachments: [(index: Int, attachment: ChatAttachment)] {
        attachments.enumerated().filter { abs(CGFloat($0.offset) - progress) < AttachmentFanPose.visibleDepth }
            .map { (index: $0.offset, attachment: $0.element) }
    }

    var body: some View {
        ZStack {
            deck
            pages
        }
        .frame(width: Self.card.width, height: Self.card.height)
        .overlay(alignment: .bottomTrailing) {
            if attachments.count > 1 {
                Text("\(position + 1) of \(attachments.count)").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.62), in: Capsule()).padding(10)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(.trailing, attachments.count > 1 ? Self.fanMargin : 0)
        .padding(.vertical, 4)
        .accessibilityIdentifier("sent-attachment-stack")
    }

    private var deck: some View {
        ZStack {
            ForEach(nearbyAttachments, id: \.attachment.id) { index, attachment in
                let distance = CGFloat(index) - progress
                let pose = AttachmentFanPose(distance: distance, cardWidth: Self.card.width, reduceMotion: reduceMotion)
                AttachmentFace(name: attachment.name, isImage: attachment.mimeType.hasPrefix("image/"),
                               thumbnail: thumbnails.image(for: attachment), size: Self.card)
                    .background(BottoTheme.surface).foregroundStyle(BottoTheme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 1)
                    .rotation3DEffect(.degrees(pose.turn), axis: (x: 0, y: 1, z: 0), perspective: 0.7)
                    .rotationEffect(.degrees(pose.tilt))
                    .scaleEffect(pose.scale)
                    .offset(x: pose.x)
                    .opacity(pose.opacity)
                    .zIndex(-abs(distance))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    Button { open?(attachment) } label: {
                        Color.clear.contentShape(Rectangle())
                            .frame(width: Self.card.width, height: Self.card.height)
                    }
                    .buttonStyle(.plain).disabled(open == nil)
                    .accessibilityLabel("Open \(attachment.name)")
                    .accessibilityValue("\(index + 1) of \(attachments.count)")
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging).scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x / Self.card.width } action: { _, page in
            progress = min(max(page, 0), CGFloat(attachments.count - 1))
        }
    }
}
