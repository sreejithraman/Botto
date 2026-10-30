import CoreGraphics
import Foundation
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor enum DiagramAdmission {
    case pixels(DiagramPresentation, DiagramRenderTicket), render(DiagramRenderTicket), busy, denied
    var ticket: DiagramRenderTicket? { if case .render(let ticket) = self { ticket } else { nil } }
}

/// Reservation lifetime follows native capture ownership, independently of its
/// publication authority. Cancellation cannot spend the same bytes twice.
@MainActor final class DiagramRenderTicket {
    private let scope: RichReplyPresentations
    private let messageID: Data
    private let block: ExactReplyBlock
    private let layout: DiagramLayout?
    private let onRevoke: @MainActor () -> Void
    private var cancelled = false
    private var capturing = false
    private var reservation: UUID?
    init(scope: RichReplyPresentations, messageID: Data, block: ExactReplyBlock,
                     layout: DiagramLayout?, reservesCapture: Bool = true, onRevoke: @escaping @MainActor () -> Void) {
        self.scope = scope; self.messageID = messageID; self.block = block
        self.layout = layout; self.onRevoke = onRevoke
        if layout != nil && reservesCapture { reservation = DiagramMemory.shared.reserve() }
    }
    var isCurrent: Bool { !cancelled && scope.permits(block, messageID: messageID) }
    func startCapture() -> Bool {
        guard isCurrent, reservation != nil, !capturing else { return false }
        capturing = true
        return true
    }
    func cancel() {
        cancelled = true
        if !capturing { releaseReservation() }
    }
    func cancelAndNotify() {
        guard !cancelled else { return }
        cancel(); onRevoke()
    }
    /// Invoke even when the renderer/view has disappeared. The native completion
    /// owns this ticket until the image and callback have actually drained.
    func finishCapture(_ image: CGImage?, height: CGFloat) -> DiagramPresentation? {
        defer {
            capturing = false
            // A failed/retired callback can still own WebKit's native image until
            // it returns. Publish availability on the next main-actor turn.
            if let reservation {
                self.reservation = nil
                Task { @MainActor in DiagramMemory.shared.release(reservation) }
            }
        }
        guard capturing, isCurrent, let image, let layout, let reservation,
              height.isFinite, (120...480).contains(height),
              image.width > 0, image.height > 0, max(image.width, image.height) <= 1_024,
              image.bytesPerRow > 0, image.height <= DiagramMemory.maximumImageBytes / image.bytesPerRow else { return nil }
        let cost = image.bytesPerRow * image.height
        let storage = DiagramStorage(image: image, charge: reservation)
        DiagramMemory.shared.transfer(reservation, bytes: cost)
        self.reservation = nil
        let value = DiagramPresentation(storage: storage, height: height)
        scope.retain(value, key: .init(messageID: messageID, block: block, layout: layout))
        DiagramMemory.shared.track(value, scope: scope)
        return value
    }
    private func releaseReservation() {
        guard let reservation else { return }
        self.reservation = nil
        DiagramMemory.shared.release(reservation)
    }
    deinit {
        // If WebKit loses a pending callback, there is no proof that capture
        // ownership drained. Keep that charge rather than admit unaccounted work.
        if let reservation, !capturing { Task { @MainActor in DiagramMemory.shared.release(reservation) } }
    }
}

/// This storage is never returned to application callers. Every native drawing
/// view keeps this companion alive for as long as it can draw the CGImage.
private final class DiagramStorage {
    let image: CGImage
    let charge: UUID
    init(image: CGImage, charge: UUID) { self.image = image; self.charge = charge }
    deinit {
        let charge = charge
        Task { @MainActor in DiagramMemory.shared.release(charge) }
    }
}

@MainActor @Observable final class DiagramPresentation {
    private var storage: DiagramStorage?
    let height: CGFloat
    fileprivate init(storage: DiagramStorage, height: CGFloat) { self.storage = storage; self.height = height }
    var isAvailable: Bool { storage != nil }
    var pixelWidth: Int { storage?.image.width ?? 0 }
    var pixelHeight: Int { storage?.image.height ?? 0 }
    func revoke() { storage = nil }
    fileprivate func drawingStorage() -> DiagramStorage? { storage }
}

/// Process-wide accounting only; lookup authority stays inside each scope.
@MainActor @Observable final class DiagramMemory {
    static let shared = DiagramMemory()
    static let maximumImageBytes = 4 * 1_024 * 1_024
    private static let maximumBytes = 16 * 1_024 * 1_024
    private static let maximumCount = 12
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private(set) var pressureEpoch: UInt64 = 0
    @ObservationIgnored private var charges: [UUID: Int] = [:]
    @ObservationIgnored private var reservations: Set<UUID> = []
    private final class Entry {
        weak var presentation: DiagramPresentation?
        weak var scope: RichReplyPresentations?
        init(_ value: DiagramPresentation, scope: RichReplyPresentations) { presentation = value; self.scope = scope }
    }
    private final class Scope {
        weak var value: RichReplyPresentations?
        init(_ value: RichReplyPresentations) { self.value = value }
    }
    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var scopes: [Scope] = []
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    #if os(iOS)
    @ObservationIgnored private var warningObserver: NSObjectProtocol?
    #endif
    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { Task { @MainActor in Self.shared.handlePressure() } }
        source.resume(); pressureSource = source
        #if os(iOS)
        warningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                                object: nil, queue: .main) { _ in
            Task { @MainActor in Self.shared.handlePressure() }
        }
        #endif
    }
    func register(_ scope: RichReplyPresentations) {
        scopes.removeAll { $0.value == nil }; scopes.append(Scope(scope))
    }
    func touch(_ value: DiagramPresentation) {
        guard let index = entries.firstIndex(where: { $0.presentation === value }) else { return }
        entries.append(entries.remove(at: index))
    }
    fileprivate func track(_ value: DiagramPresentation, scope: RichReplyPresentations) {
        entries.removeAll { $0.presentation == nil }; entries.append(Entry(value, scope: scope))
    }
    func canReserve() -> Bool {
        guard reservations.count < 2 else { return false }
        entries.removeAll { $0.presentation == nil }
        while charges.count >= Self.maximumCount || charges.values.reduce(0, +) > Self.maximumBytes - Self.maximumImageBytes {
            guard !entries.isEmpty else { return false }
            let victim = entries.removeFirst()
            if let value = victim.presentation { victim.scope?.evict(value) }
            Task { @MainActor in self.revision &+= 1 }
            return false
            // Held drawing storage remains charged. Deinit publishes availability
            // on the main actor; a deferred renderer retries after that drain.
        }
        return true
    }
    fileprivate func reserve() -> UUID {
        let id = UUID()
        charges[id] = Self.maximumImageBytes; reservations.insert(id)
        return id
    }
    fileprivate func transfer(_ id: UUID, bytes: Int) {
        charges[id] = bytes; reservations.remove(id); revision &+= 1
    }
    fileprivate func release(_ id: UUID) {
        charges[id] = nil; reservations.remove(id); revision &+= 1
    }
    func handlePressure() {
        // Cancellation releases permits and can queue capacity retries. Fence
        // those retries before publishing any of that ordinary availability.
        pressureEpoch &+= 1
        for scope in scopes.compactMap(\.value) { scope.revokeContents() }
        revision &+= 1
    }
}

/// Native drawing owns a charged companion. SwiftUI never receives a raw image
/// or UIImage/NSImage value that could outlive the storage ledger.
struct DiagramPixelsView: View {
    let presentation: DiagramPresentation
    var body: some View {
        NativeDiagramPixels(presentation: presentation)
            .opacity(presentation.isAvailable ? 1 : 0)
    }
}

#if os(iOS)
private struct NativeDiagramPixels: UIViewRepresentable {
    let presentation: DiagramPresentation
    func makeUIView(context: Context) -> DrawingView { DrawingView() }
    func updateUIView(_ view: DrawingView, context: Context) { view.install(presentation) }
    final class DrawingView: UIView {
        private var presentation: DiagramPresentation?
        private var companion: DiagramStorage?
        override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func install(_ value: DiagramPresentation) {
            presentation = value; companion = value.drawingStorage(); setNeedsDisplay()
        }
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext(), let companion, presentation?.isAvailable == true else { return }
            context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(companion.image, in: fittedRect(width: companion.image.width, height: companion.image.height, bounds: bounds))
        }
    }
}
#else
private struct NativeDiagramPixels: NSViewRepresentable {
    let presentation: DiagramPresentation
    func makeNSView(context: Context) -> DrawingView { DrawingView() }
    func updateNSView(_ view: DrawingView, context: Context) { view.install(presentation) }
    final class DrawingView: NSView {
        private var presentation: DiagramPresentation?
        private var companion: DiagramStorage?
        func install(_ value: DiagramPresentation) {
            presentation = value; companion = value.drawingStorage(); needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext, let companion, presentation?.isAvailable == true else { return }
            context.interpolationQuality = .high
            context.draw(companion.image, in: fittedRect(width: companion.image.width, height: companion.image.height, bounds: bounds))
        }
    }
}
#endif

private func fittedRect(width: Int, height: Int, bounds: CGRect) -> CGRect {
    let scale = min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
    return CGRect(x: 0, y: bounds.height - CGFloat(height) * scale,
                  width: CGFloat(width) * scale, height: CGFloat(height) * scale)
}
