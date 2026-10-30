import UIKit
import Vision

/// Test-only rendered-content oracle shared by admission and measurements.
@MainActor enum RenderedTranscriptFile {
    struct Observation {
        let hasBars: Bool
        let text: [String]
        var isComplete: Bool {
            let words = text.joined(separator: " ").lowercased()
            return hasBars && words.contains("update preview") && words.contains("ready for review") && !words.contains("loading preview")
        }
    }
    static func observe(_ image: UIImage, in rect: CGRect) throws -> Observation {
        guard hasFileBarPixels(image, in: rect) else { return .init(hasBars: false, text: []) }
        return .init(hasBars: true, text: try recognizedText(image, in: rect))
    }
    private static func recognizedText(_ image: UIImage, in rect: CGRect) throws -> [String] {
        guard !rect.isNull, rect.width > 0, rect.height > 0,
              let crop = image.cgImage?.cropping(to: rect.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: crop).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }
    private static func hasFileBarPixels(_ image: UIImage, in rect: CGRect) -> Bool {
        guard !rect.isNull, rect.width > 0, rect.height > 0,
              let crop = image.cgImage?.cropping(to: rect.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))) else { return false }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            var result = 0
            for offset in stride(from: 0, to: buffer.count, by: 4) {
                let red = Int(buffer[offset]), green = Int(buffer[offset + 1]), blue = Int(buffer[offset + 2])
                // Real Demo HTML defines its bars as #6366f1. This rejects the
                // white/loading panel and pale page background in the same rect.
                if (60...140).contains(red), (60...145).contains(green), blue > 180,
                   blue > red + 50, blue > green + 50 { result += 1 }
            }
            return result
        }
        return count > 25
    }
}
