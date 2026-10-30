import AVFoundation
import CoreImage
import CryptoKit
import Darwin
import Foundation
import Vision

// Record the popin performance demo in light mode, default text size, on a
// 402 × 874 point portrait screen. Launch --demo --performance-demo
// --popin-text-performance-demo; add --popin-assistant-performance-demo for
// incoming text. For entry from below, also add --popin-from-below-demo and
// move to Earlier history start before recording.
// From above: two 440-point downward pans over 2.2 seconds each; repeat two
// upward/two downward pans three times. Reverse directions when entering from below.
// Start recording after opening Scout. Analyze every encoded frame; sampling can
// miss the one-frame expansion this check guards against. Run outside timed tests.
// Requires macOS 27 / Xcode 27.
// Usage: swift scripts/check-chat-text-appearance.swift outgoing|incoming above|below video.mp4 report.json
enum MessageDirection: String, Codable { case outgoing, incoming }
enum EntryEdge: String, Codable { case above, below }
struct Entry: Codable {
    let seconds: Double
    let top: Int
    let bottom: Int
    let occupiedRows: Int
}
struct Report: Codable {
    let direction: MessageDirection
    let edge: EntryEdge
    let videoSHA256: String
    let decodedFrames: Int
    let entries: [Entry]
    let largestStep: Int
    let largestUnexpectedStep: Double
    let recognizedWords: [String]
    let failures: [String]
}
enum CheckError: Error { case invalidInput(String) }

@MainActor func check() async throws -> Int32 {
    guard CommandLine.arguments.count == 5,
          let direction = MessageDirection(rawValue: CommandLine.arguments[1]),
          let edge = EntryEdge(rawValue: CommandLine.arguments[2]) else {
        throw CheckError.invalidInput("Expected outgoing|incoming, above|below, video path, and report path.")
    }
    guard #available(macOS 27, *) else { throw CheckError.invalidInput("Requires macOS 27.") }
    let video = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
    let reportURL = URL(fileURLWithPath: CommandLine.arguments[4]).standardizedFileURL.resolvingSymlinksInPath()
    guard video != reportURL else { throw CheckError.invalidInput("The report must not replace its source recording.") }
    let asset = AVURLAsset(url: video)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw CheckError.invalidInput("Recording has no video track.")
    }
    let transform = try await track.load(.preferredTransform)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    let provider = reader.outputProvider(for: output)
    try reader.start()
    let imageContext = CIContext(options: [.cacheIntermediates: false])
    let width = 402, height = 874, cropTop = 192, cropBottom = 777
    var frames = 0, emptyFrames = 0, absent = true, largestStep = 0
    var largestUnexpectedStep = 0.0
    var entries: [Entry] = []
    var previous: Entry?
    var finalImage: CGImage?

    while let ready = try await provider.next() {
        try ready.withUnsafeSampleBuffer { sample in
            try autoreleasepool {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw CheckError.invalidInput("Decoded frame has no pixels.")
                }
                let source = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                let scale = CGFloat(width) / source.extent.width
                let upright = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard abs(upright.extent.height - CGFloat(height)) < 1,
                      let image = imageContext.createCGImage(upright, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
                    throw CheckError.invalidInput("Expected a 402 × 874 point portrait recording.")
                }
                finalImage = image
                frames += 1
                var pixels = [UInt8](repeating: 0, count: width * height * 4)
                var occupiedRows: [Int] = []
                try pixels.withUnsafeMutableBytes { bytes in
                    guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw CheckError.invalidInput("Cannot inspect decoded pixels.")
                    }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    let paper = (400 * width + 10) * 4
                    guard bytes[paper] > 180 && bytes[paper + 1] > 180 && bytes[paper + 2] > 180 else {
                        throw CheckError.invalidInput("Expected the light-mode chat fixture, without covering presentations.")
                    }
                    let left = 92, right = 361
                    for y in cropTop..<cropBottom {
                        var dark = 0
                        for x in left..<right {
                            let offset = (y * width + x) * 4
                            if bytes[offset] < 80 && bytes[offset + 1] < 80 && bytes[offset + 2] < 80 { dark += 1 }
                        }
                        // The outgoing bubble is dark; incoming prose has dark glyphs.
                        // This crop excludes the tool chevrons and pale tool labels.
                        if direction == .outgoing ? Double(dark) / Double(right - left) > 0.70 : dark >= 8 {
                            occupiedRows.append(y)
                        }
                    }
                }
                guard occupiedRows.count > (direction == .outgoing ? 15 : 30), let bottom = occupiedRows.last else {
                    emptyFrames += 1
                    if emptyFrames >= 3 { absent = true; previous = nil }
                    return
                }
                let entry = Entry(seconds: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                                  top: occupiedRows[0], bottom: bottom, occupiedRows: occupiedRows.count)
                if absent { entries.append(entry) }
                if let previous, entry.seconds > previous.seconds {
                    let displacement = abs((edge == .above ? entry.bottom : entry.top) - (edge == .above ? previous.bottom : previous.top))
                    largestStep = max(largestStep, displacement)
                    let expectedTravel = 200 * (entry.seconds - previous.seconds)
                    largestUnexpectedStep = max(largestUnexpectedStep, Double(displacement) - expectedTravel)
                }
                previous = entry; absent = false; emptyFrames = 0
            }
        }
    }
    guard reader.status == .completed else { throw reader.error ?? CheckError.invalidInput("Incomplete video decode.") }

    var endingWords: [String] = []
    if let finalImage, let crop = finalImage.cropping(to: CGRect(x: 0, y: cropTop, width: width, height: cropBottom - cropTop)) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: crop).perform([request])
        endingWords = request.results?.compactMap { $0.topCandidates(1).first?.string.lowercased() } ?? []
    }
    var failures: [String] = []
    if frames < 50 { failures.append("The recording is too short.") }
    if entries.count < 4 { failures.append("Initial entry and three offscreen/return cycles must reveal the large message.") }
    // At 200 points/second, the first eligible painted rows enter close to the expected
    // edge. Incoming prose needs several lines before its sparse ink qualifies.
    let firstEntryLimit = direction == .outgoing ? 240 : 320
    if entries.contains(where: { edge == .above ? $0.bottom > firstEntryLimit : $0.top < cropBottom - (firstEntryLimit - cropTop) }) {
        failures.append("Large content flashed deep inside the viewport instead of entering from its expected edge.")
    }
    if largestUnexpectedStep > 8 { failures.append("Painted content jumped farther than the controlled slow pan permits.") }
    let ending = endingWords.joined(separator: " ")
    let expectedText = edge == .above
        ? ["ending alpha", "ending bravo", "ending charlie", "complete message delta"]
        : ["paragraph 0", "native text", "readable history", "new words arrive"]
    for expected in expectedText where !ending.contains(expected) {
        failures.append("Final rendered text is missing: \(expected).")
    }
    let report = Report(direction: direction, edge: edge, videoSHA256: SHA256.hash(data: try Data(contentsOf: video)).map { String(format: "%02x", $0) }.joined(),
                        decodedFrames: frames, entries: entries, largestStep: largestStep, largestUnexpectedStep: largestUnexpectedStep,
                        recognizedWords: endingWords, failures: failures)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: reportURL, options: .atomic)
    print("\(direction.rawValue): \(frames) frames, \(entries.count) entries, maximum step \(largestStep) points; \(failures.isEmpty ? "passed" : "FAILED").")
    for failure in failures { print(failure) }
    return failures.isEmpty ? 0 : 1
}

do {
    exit(try await check())
} catch {
    fputs("Appearance check error: \(error)\n", stderr)
    exit(2)
}
