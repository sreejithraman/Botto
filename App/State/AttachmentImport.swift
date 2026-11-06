import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import BottoCore

struct AttachmentPayload: Sendable {
    let data: Data
    let filename: String
    let mimeType: String
}

/// One input's bytes, read only after its import owns the chat's upload slot.
typealias AttachmentRead = @Sendable () async throws -> AttachmentPayload

/// A chosen input, named before its bytes exist so its tile can appear at once.
struct AttachmentInput: Sendable {
    let name: String
    var isImage = false
    let read: AttachmentRead
}

/// A chosen input that has not finished attaching. Only its import can stage it.
struct PendingAttachment: Identifiable {
    enum Phase { case queued, reading, uploading, stopping }
    let id: UUID
    var name: String
    var isImage: Bool
    var preview: UIImage?
    var phase = Phase.queued
}

struct AttachmentReadError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Bounded local previews for files imported on this device. Hermes returns host paths,
/// so evicted previews cannot be regenerated without downloading the file.
@MainActor @Observable final class AttachmentThumbnails {
    private static let capacity = 64
    private var images: [String: UIImage] = [:]
    @ObservationIgnored private var order: [String] = []

    /// Hermes stores a sent image under a new directory, keeping its unique filename.
    func image(for attachment: ChatAttachment) -> UIImage? {
        images[attachment.id] ?? images[attachment.path] ?? images[Self.hostFilename(attachment)]
    }
    private static func hostFilename(_ attachment: ChatAttachment) -> String { (attachment.path as NSString).lastPathComponent }

    func retain(_ image: UIImage?, for attachment: ChatAttachment) {
        guard let image else { return }
        for key in Self.keys(attachment) {
            if images.updateValue(image, forKey: key) == nil { order.append(key) }
        }
        while order.count > Self.capacity { images[order.removeFirst()] = nil }
    }

    func discard(_ attachment: ChatAttachment) {
        let keys = Self.keys(attachment)
        for key in keys { images[key] = nil }
        order.removeAll(where: keys.contains)
    }
    private static func keys(_ attachment: ChatAttachment) -> Set<String> {
        [attachment.id, attachment.path, hostFilename(attachment)]
    }
}

/// Draws a small picture of a local file. A file it can't draw keeps its named tile.
nonisolated enum AttachmentPreview {
    private static let imagePixels = 480
    private static let pagePixels: CGFloat = 480
    /// Matches the sent card's proportions, so an excerpt fills it uncropped.
    private static let textPage = CGSize(width: 360, height: 466)
    private static let textInset: CGFloat = 24
    private static let excerptBytes = 4096

    static func rendered(_ payload: AttachmentPayload) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { render(payload) }.value
    }

    private static func render(_ payload: AttachmentPayload) -> UIImage? {
        let filename = payload.filename, mimeType = payload.mimeType
        if mimeType.hasPrefix("image/") { return image(payload.data) }
        if mimeType == "application/pdf" || (filename as NSString).pathExtension.lowercased() == "pdf" {
            return pdf(payload.data)
        }
        guard ArtifactPlainText.supports(filename: filename, mimeType: mimeType) else { return nil }
        return text(payload.data, mimeType: mimeType)
    }

    private static func image(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: imagePixels] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func pdf(_ data: Data) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              !document.isEncrypted, let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox).size
        let source = page.rotationAngle % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = pagePixels / max(source.width, source.height)
        let bounds = CGRect(origin: .zero, size: source)
        return paper(CGSize(width: ceil(source.width * scale), height: ceil(source.height * scale))) { context in
            context.translateBy(x: 0, y: source.height * scale)
            context.scaleBy(x: scale, y: -scale)
            // This transform never enlarges a page, so the scale above is applied separately.
            context.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
        }
    }

    private static func text(_ data: Data, mimeType: String) -> UIImage? {
        guard let excerpt = excerpt(data, mimeType: mimeType),
              !excerpt.allSatisfy(\.isWhitespace) else { return nil }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let body = NSAttributedString(string: excerpt, attributes: [
            .font: UIFont.systemFont(ofSize: 26), .foregroundColor: UIColor(white: 0.1, alpha: 1), .paragraphStyle: style])
        return paper(textPage) { _ in
            body.draw(with: CGRect(origin: .zero, size: textPage).insetBy(dx: textInset, dy: textInset),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
    }

    /// The cut can land inside a character, so it backs up to the nearest whole one.
    private static func excerpt(_ data: Data, mimeType: String) -> String? {
        let bytes = data.prefix(excerptBytes)
        guard bytes.count == excerptBytes else { return try? ArtifactPlainText.decode(bytes, mimeType: mimeType).get() }
        return (0...3).lazy.compactMap { try? ArtifactPlainText.decode(bytes.dropLast($0), mimeType: mimeType).get() }.first
    }

    private static func paper(_ size: CGSize, draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            draw(renderer.cgContext)
        }
    }
}

/// A pasteboard item that becomes a file rather than text.
struct PastedAttachment: @unchecked Sendable {
    let provider: NSItemProvider
    let type: UTType

    func filename(temporaryFile: URL) -> String {
        let fallback = type.conforms(to: .image) ? "Pasted image" : "Pasted file"
        let suggested = provider.suggestedName ?? temporaryFile.deletingPathExtension().lastPathComponent
        let cleaned = String(suggested.map { $0.isNewline || "/\\\0".contains($0) ? "-" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = cleaned.isEmpty || cleaned.allSatisfy { $0 == "." } ? fallback : cleaned
        let existingExtension = (usable as NSString).pathExtension
        let hasCompatibleExtension = UTType(filenameExtension: existingExtension)?.conforms(to: type) == true
        let suffix = type.preferredFilenameExtension.map { "." + $0 } ?? ""
        let preservedSuffix = hasCompatibleExtension ? "." + existingExtension : suffix
        let stem = usable.lowercased().hasSuffix(preservedSuffix.lowercased()) ? String(usable.dropLast(preservedSuffix.count)) : usable
        var limited = stem
        while !limited.isEmpty, limited.utf8.count + preservedSuffix.utf8.count > 200 { limited.removeLast() }
        return limited + preservedSuffix
    }
}

/// What one paste holds. Item identifiers arrive best representation first.
struct ComposerPaste {
    private(set) var attachments: [PastedAttachment] = []
    private(set) var text: [NSItemProvider] = []

    init(_ pasteboard: UIPasteboard) { self.init(providers: pasteboard.itemProviders) }

    init(providers: [NSItemProvider]) {
        for provider in providers {
            if let type = Self.attachmentType(provider.registeredTypeIdentifiers, named: provider.suggestedName != nil) {
                attachments.append(PastedAttachment(provider: provider, type: type))
            } else { text.append(provider) }
        }
    }

    /// Decides from types alone: names need `itemProviders`, which reads the pasteboard and can
    /// prompt. Unnamed generic data can therefore offer a Paste that UIKit then ignores.
    static func containsAttachment(_ pasteboard: UIPasteboard) -> Bool {
        (pasteboard.types(forItemSet: nil) as? [[String]] ?? []).contains { identifiers in
            !identifiers.contains { UTType($0)?.conforms(to: .text) == true } && attachmentType(identifiers, named: true) != nil
        }
    }

    static func attachmentType(_ identifiers: [String], named: Bool) -> UTType? {
        let types = identifiers.compactMap(UTType.init)
        // A copied link is named after its page but is still text.
        let file = named && !types.contains { $0.conforms(to: .url) }
        if !file, types.contains(where: { $0.conforms(to: .text) }) { return nil }
        let candidates = types.filter { $0.conforms(to: .data) && !$0.conforms(to: .url) }
        return candidates.first { $0.preferredFilenameExtension != nil } ?? (file ? candidates.first : nil)
    }
}

nonisolated enum AttachmentSource {
    static func file(_ url: URL) -> AttachmentInput {
        AttachmentInput(name: url.lastPathComponent,
                        isImage: UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true) {
            try await Task.detached(priority: .userInitiated) { try read(url) }.value
        }
    }

    static func photo(_ item: PhotosPickerItem) -> AttachmentInput {
        AttachmentInput(name: "Photo", isImage: true) {
            let data: Data?
            do { data = try await item.loadTransferable(type: Data.self) }
            catch { throw AttachmentReadError("Couldn’t attach this photo. \(error.localizedDescription)") }
            guard let data else { throw AttachmentReadError("Couldn’t read this photo. Try another image.") }
            let type = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
            return AttachmentPayload(data: data, filename: "Photo.\(type.preferredFilenameExtension ?? "jpg")",
                                     mimeType: type.preferredMIMEType ?? "image/jpeg")
        }
    }

    static func pasted(_ item: PastedAttachment) -> AttachmentInput {
        let isImage = item.type.conforms(to: .image)
        return AttachmentInput(name: item.provider.suggestedName ?? (isImage ? "Pasted image" : "Pasted file"), isImage: isImage) {
            try await withCheckedThrowingContinuation { continuation in
                _ = item.provider.loadFileRepresentation(forTypeIdentifier: item.type.identifier) { url, error in
                    // The provider deletes this file when the handler returns.
                    continuation.resume(with: Result {
                        guard let url else {
                            throw AttachmentReadError("Couldn’t read what you pasted. \(error?.localizedDescription ?? "Try copying it again.")")
                        }
                        return AttachmentPayload(data: try contents(of: url),
                                                 filename: item.filename(temporaryFile: url),
                                                 mimeType: item.type.preferredMIMEType ?? "application/octet-stream")
                    })
                }
            }
        }
    }

    /// Coordination has a file provider download an offloaded file before it is read.
    private static func read(_ url: URL) throws -> AttachmentPayload {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > AttachmentLimits.fileBytes { throw HermesServiceError.attachmentLimit }
        var coordinationError: NSError?
        var result: Result<AttachmentPayload, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { current in
            result = Result {
                let type = try current.resourceValues(forKeys: [.contentTypeKey]).contentType
                return AttachmentPayload(data: try contents(of: current), filename: url.lastPathComponent,
                                         mimeType: type?.preferredMIMEType ?? "application/octet-stream")
            }
        }
        do {
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileReadUnknown) }
            return try result.get()
        } catch let limit as HermesServiceError {
            throw limit
        } catch {
            throw AttachmentReadError("Couldn’t attach this file. \(error.localizedDescription)")
        }
    }

    private static func contents(of url: URL) throws -> Data {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= AttachmentLimits.fileBytes else {
            throw HermesServiceError.attachmentLimit
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
