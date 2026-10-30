// Image preparation and host-path/reference rules adapted from Hermex BotAttachmentUpload.swift.
// MIT; see LICENSES/Hermex.txt.
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Preparation owns its ImageIO objects and returns Sendable bytes for the service.
nonisolated enum HermesAttachment {
    struct Prepared: Sendable { let data: Data; let name: String; let mime: String; let image: Bool }
    static func prepare(data: Data, filename: String, mime: String) throws -> Prepared {
        guard !data.isEmpty, data.count <= AttachmentLimits.fileBytes else { throw HermesServiceError.attachmentLimit }
        guard !filename.isEmpty, filename.utf8.count <= 240,
              !filename.contains(where: { $0.isNewline || $0 == "\0" || $0 == "/" || $0 == "\\" }),
              filename != ".", filename != "..", !mime.contains(where: { $0.isWhitespace || $0 == ";" })
        else { throw HermesServiceError.invalidAttachment }
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        if type?.conforms(to: .image) == true || mime.hasPrefix("image/") {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { throw HermesServiceError.invalidAttachment }
            let alpha = [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
            let format = alpha ? UTType.png : UTType.jpeg
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { throw HermesServiceError.invalidAttachment }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length <= AttachmentLimits.fileBytes else { throw HermesServiceError.attachmentLimit }
            let name = (filename as NSString).deletingPathExtension + (alpha ? ".png" : ".jpg")
            return Prepared(data: output as Data, name: name, mime: alpha ? "image/png" : "image/jpeg", image: true)
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard type?.conforms(to: .text) == true || type?.conforms(to: .pdf) == true || type?.conforms(to: .audio) == true
            || ["json", "yaml", "yml", "csv", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip"].contains(ext)
        else { throw HermesServiceError.invalidAttachment }
        return Prepared(data: data, name: filename, mime: type?.preferredMIMEType ?? "application/octet-stream", image: false)
    }
    static func hostPath(_ value: String?) throws -> String {
        guard let value, !value.hasPrefix("//"), !value.hasPrefix("\\\\"),
              value.hasPrefix("/") || value.firstMatch(of: /^[A-Za-z]:[\\\/]/) != nil,
              !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw HermesServiceError.invalidAttachment }
        return value
    }
    static func imageReference(_ path: String) -> String {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "image"
        return "[The user attached an image: \(name)]\n[Examine it with the vision_analyze tool using image_url: \(path)]"
    }
}
