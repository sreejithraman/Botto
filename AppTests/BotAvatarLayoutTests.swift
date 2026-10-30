import SwiftUI
import Testing
import UIKit
import XCTest
import BottoCore
@testable import Botto

@Suite(.serialized)
@MainActor
struct BotAvatarLayoutTests {
    @Test(arguments: BotAvatarShape.allCases)
    func fittedBodiesShareVisibleTop(shape: BotAvatarShape) throws {
        let profile = BotProfile(id: "fitted-body", name: "Body", appearance: BotAppearance(shape: shape))
        let actual = try render(BotAvatar(profile: profile, size: 56, motion: .still, fitsBody: true)
            .frame(width: 56, height: 56, alignment: .top), size: 56, scale: 1)
        let firstRow = (0..<actual.height).first { y in
            (0..<actual.width).contains { actual.alpha($0, y) > 32 }
        }
        #expect(try #require(firstRow) <= 1, "The visible \(shape) body starts at the shared top edge.")
    }

    @Test func fittedImagesPreserveAspectRatioAndShareVisibleTop() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        }
        let actual = try render(BotAvatar(profile: BotProfile(id: "fitted-image", name: "Image"),
            image: image, size: 56, motion: .still, fitsBody: true)
            .frame(width: 56, height: 56, alignment: .top), size: 56, scale: 1)
        #expect((0..<actual.width).contains { actual.alpha($0, 0) > 128 })
        #expect((0..<actual.width).allSatisfy { actual.alpha($0, 30) == 0 }, "The image stays 2:1.")
    }

    @Test func fittedShortBodyKeepsThinkingCueNearBody() throws {
        let profile = BotProfile(id: "fitted-cue", name: "Cue", appearance: BotAppearance(shape: .pill))
        let actual = try render(BotAvatar(profile: profile, size: 56,
            presentation: .init(activity: .thinking, enteredAt: .distantPast), fitsBody: true)
            .environment(\.avatarMotionDisabledForTesting, true)
            .padding(.top, 16).frame(width: 96, height: 96, alignment: .top), size: 96, scale: 1)
        let firstRow = (0..<actual.height).first { y in
            (0..<actual.width).contains { actual.alpha($0, y) > 32 }
        }
        #expect(try #require(firstRow) >= 7, "The cue fits in the header's clearance above the body.")
    }

    @Test func standardPresetEyesAreDarkInBothAppearances() throws {
        for preset in BotAvatarColors.presets {
            for source in [preset.shared, preset.hex] {
                for scheme in [ColorScheme.light, .dark] {
                    let actual = try render(Rectangle().fill(Color.botEyes(on: source))
                        .environment(\.colorScheme, scheme), size: 24)
                    let expected = try render(Rectangle().fill(.black.opacity(0.85)), size: 24)
                    let matches = actual.bytes == expected.bytes
                    #expect(matches, "\(preset.id) must keep the standard dark eyes in \(scheme)")
                }
            }
        }
    }

    @Test func customOpaqueColorsKeepAutomaticEyeContrast() throws {
        for (source, eyeColor) in [("#123456", Color.white.opacity(0.9)), ("#f8ead0", Color.black.opacity(0.85))] {
            for scheme in [ColorScheme.light, .dark] {
                let actual = try render(Rectangle().fill(Color.botEyes(on: source))
                    .environment(\.colorScheme, scheme), size: 24)
                let expected = try render(Rectangle().fill(eyeColor), size: 24)
                let matches = actual.bytes == expected.bytes
                #expect(matches, "Custom \(source) must keep contrasting eyes in \(scheme)")
            }
        }
    }

    @Test func nativeFacesUseBottoPresetsAndKeepCustomHSLColors() throws {
        let samples: [(String, Color)] = [
            ("hsl(0 68% 58%)", Color(red: 239.0 / 255, green: 68.0 / 255, blue: 68.0 / 255)),
            ("rgb(220.728 147.9 75.072)", Color(red: 249.0 / 255, green: 115.0 / 255, blue: 22.0 / 255)),
            ("hsl(30 40% 50%)", Color(red: 179.0 / 255, green: 128.0 / 255, blue: 77.0 / 255)),
            ("rgba(20, 40, 60, 0.5)", Color(red: 20.0 / 255, green: 40.0 / 255, blue: 60.0 / 255, opacity: 128.0 / 255))
        ]
        for (source, expected) in samples {
            let actual = try render(Rectangle().fill(Color.botBody(source)), size: 24)
            let reference = try render(Rectangle().fill(expected), size: 24)
            let matches = actual.bytes == reference.bytes
            #expect(matches, "Native color must honor \(source)")
        }
    }

    @Test func transparentCustomFacesKeepVisibleEyesInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let actual = try render(Rectangle().fill(Color.botEyes(on: "rgba(0, 0, 0, 0)"))
                .environment(\.colorScheme, scheme), size: 24)
            let expected = try render(Rectangle().fill(scheme == .dark ? Color.white.opacity(0.9) : .black.opacity(0.85)), size: 24)
            let matches = actual.bytes == expected.bytes
            #expect(matches, "Transparent eyes must contrast in \(scheme)")
        }
    }

    @Test func triangleEyesStayInsideBodyAtOnboardingSize() throws {
        let profile = BotProfile(id: "triangle", name: "Triangle", appearance: BotAppearance(
            shape: .triangle, color: "#22c55e", expression: "neutral"
        ))
        let actual = try render(BotAvatar(profile: profile, size: 300, motion: .still), size: 300)
        let body = try render(BotAvatarBody(shape: .triangle).fill(.black), size: 300)
        #expect(overflowPixels(actual, outside: body) == 0)
    }

    @Test(arguments: BotAvatarShape.allCases)
    func expressionsAndMotionFitBody(shape: BotAvatarShape) throws {
        // Sample working gaze/lid bounds, real sway frames and the settled frame.
        // Head roll rotates the body and the face together.
        var settledBlink = BotFacePose.settledWorking
        settledBlink.lid = BotFacePose.blink.lid
        let poses: [BotFacePose] = [.rest, .blink, .settledWorking, settledBlink,
                                  .working(at: 5), .working(at: 15), .working(at: 25)] + [-0.0475, -0.0075].flatMap { x in
            [-0.024, 0.024].flatMap { y in
                [0.06, 1.0].map { lid in BotFacePose(gazeX: x, gazeY: y, roll: y < 0 ? -4.2 : 4.2, lid: lid) }
            }
        }
        var failures: [String] = []
        for size: CGFloat in [24, 56, 120, 300] {
            let scale: CGFloat = size <= 56 ? 3 : 1
            for scheme in [ColorScheme.light, .dark] {
                for (index, pose) in poses.enumerated() {
                    let body = try render(BotAvatarBody(shape: shape).fill(Color.botBody("#22c55e"))
                        .rotationEffect(.degrees(pose.roll)).environment(\.colorScheme, scheme), size: size, scale: scale)
                    for expression in BotAvatarExpression.allCases {
                        let profile = BotProfile(id: "fixture", name: "Fixture", appearance: BotAppearance(
                            shape: shape, color: "#22c55e", expression: expression.rawValue
                        ))
                        let actual = try render(BotAvatarMark(profile: profile, size: size, pose: pose)
                            .environment(\.colorScheme, scheme), size: size, scale: scale)
                        let overflow = overflowPixels(actual, outside: body)
                        if overflow > 0 || (pose.lid == 1 && actual.bytes == body.bytes) {
                            failures.append("\(shape)/\(expression)/\(size)/\(scheme)/pose \(index): \(overflow) overflow pixels")
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty == true, "\(failures.count) failing frames: \(failures.prefix(12))")
    }

    @Test func largeWorkingCapsulesStayInsideAtDisplayScale() throws {
        let poses: [BotFacePose] = [.rest] + [-0.0475, -0.0075].flatMap { x in
            [-0.024, 0.024].map { y in BotFacePose(gazeX: x, gazeY: y, roll: y < 0 ? -4.2 : 4.2) }
        }
        for shape in [BotAvatarShape.triangle, .cloud, .drop, .pill] {
            for pose in poses {
                let body = try render(BotAvatarBody(shape: shape).fill(.black)
                    .rotationEffect(.degrees(pose.roll)), size: 300)
                for expression in BotAvatarExpression.allCases {
                    let profile = BotProfile(id: "fixture", name: "Fixture", appearance: BotAppearance(
                        shape: shape, color: "#22c55e", expression: expression.rawValue
                    ))
                    let actual = try render(BotAvatarMark(profile: profile, size: 300, pose: pose), size: 300)
                    #expect(overflowPixels(actual, outside: body) == 0, "\(shape)/\(expression)/\(pose)")
                }
            }
        }
    }

    @Test func whiteCustomColorsStayWhiteInBothAppearances() throws {
        for source in ["#ffffff", "#FFFFFF", "#fff", "white", "rgb(255 255 255)", "hsl(0 0% 100%)"] {
            for scheme in [ColorScheme.light, .dark] {
                let actualBody = try render(Rectangle().fill(Color.botBody(source))
                    .environment(\.colorScheme, scheme), size: 24)
                let expectedBody = try render(Rectangle().fill(Color.white), size: 24)
                let bodyMatches = actualBody.bytes == expectedBody.bytes
                #expect(bodyMatches, "\(source) must stay white in \(scheme)")
                let actualEyes = try render(Rectangle().fill(Color.botEyes(on: source))
                    .environment(\.colorScheme, scheme), size: 24)
                let expectedEyes = try render(Rectangle().fill(Color.black.opacity(0.85)), size: 24)
                let eyesMatch = actualEyes.bytes == expectedEyes.bytes
                #expect(eyesMatch)
            }
        }
    }

    @Test func fallbackColorsAndExpressionsStayContained() throws {
        for shape in BotAvatarShape.allCases {
            for color in ["#22c55e", "#123456", "#ffffff", "invalid"] {
                for scheme in [ColorScheme.light, .dark] {
                    for size: CGFloat in [56, 300] {
                        let body = try render(BotAvatarBody(shape: shape).fill(Color.botBody(color))
                            .environment(\.colorScheme, scheme), size: size)
                        let neutral = BotProfile(id: "fixture", name: "Fixture", appearance: BotAppearance(
                            shape: shape, color: color, expression: "neutral"
                        ))
                        let expected = try render(BotAvatar(profile: neutral, size: size, motion: .still)
                            .environment(\.colorScheme, scheme), size: size)
                        #expect(expected.bytes != body.bytes)
                        for expression: String? in [nil, "future-expression"] {
                            var profile = neutral
                            profile.appearance?.expression = expression
                            let actual = try render(BotAvatar(profile: profile, size: size, motion: .still)
                                .environment(\.colorScheme, scheme), size: size)
                            #expect(actual.bytes == expected.bytes)
                            #expect(overflowPixels(actual, outside: body) == 0)
                        }
                    }
                }
            }
        }
    }

    @Test func rotatedCapsulesHaveBreathingRoom() throws {
        let poses: [BotFacePose] = [.rest] + [-0.0475, -0.0075].flatMap { x in
            [-0.024, 0.024].map { y in BotFacePose(gazeX: x, gazeY: y) }
        }
        var failures: [String] = []
        for shape in BotAvatarShape.allCases {
            let body = try render(BotAvatarBody(shape: shape).fill(Color.botBody("#22c55e")), size: 300, scale: 1)
            for expression in BotAvatarExpression.allCases {
                let profile = BotProfile(id: "fixture", name: "Fixture", appearance: BotAppearance(
                    shape: shape, color: "#22c55e", expression: expression.rawValue
                ))
                for (index, pose) in poses.enumerated() {
                    let actual = try render(BotAvatarMark(profile: profile, size: 300, pose: pose), size: 300, scale: 1)
                    var crowded = false
                    for y in 0..<actual.height {
                        for x in 0..<actual.width {
                            // The green fixture's dark eye pixels differ strongly
                            // from the body. Compare full capsules, never centers.
                            let offset = (y * actual.width + x) * 4
                            guard Int(body.bytes[offset + 1]) - Int(actual.bytes[offset + 1]) > 48,
                                  actual.alpha(x, y) > 128 else { continue }
                            // Three pixels at 300 pt: at least 1% of the mark
                            // separates the painted eye from the body boundary.
                            for (dx, dy) in [(3, 0), (-3, 0), (0, 3), (0, -3)] {
                                if body.alpha(x + dx, y + dy) < 128 { crowded = true }
                            }
                        }
                    }
                    if crowded { failures.append("\(shape)/\(expression)/pose \(index)") }
                }
            }
        }
        #expect(failures.isEmpty == true, "Capsules need padding: \(failures)")
    }

    @Test func reducedMotionPolicyAndForcedStillUseTheStaticFrame() throws {
        for shape in BotAvatarShape.allCases {
            for expression in BotAvatarExpression.allCases {
                let profile = BotProfile(id: "fixture", name: "Fixture", appearance: BotAppearance(
                    shape: shape, color: "#22c55e", expression: expression.rawValue
                ))
                let still = try render(BotAvatar(profile: profile, size: 56, motion: .still), size: 56)
                for motion in [BotFaceMotion.idle, .working(since: Date(timeIntervalSinceReferenceDate: 0))] {
                    #expect(motion.honoring(reduceMotion: true) == .still)
                    // The OS Reduce Motion environment value is read-only. Use
                    // the existing debug override to render the same still branch;
                    // this does not claim an OS accessibility-setting test.
                    let reduced = try render(BotAvatar(profile: profile, size: 56, motion: motion)
                        .environment(\.scenePhase, .active)
                        .environment(\.avatarMotionDisabledForTesting, true), size: 56)
                    #expect(reduced.bytes == still.bytes)
                }
            }
        }
    }

    @Test func canonicalFallbackAndImagePrecedenceArePreserved() throws {
        for id in ["default", "research", "inbox-triage", "triangle", "new-helper"] {
            let automatic = BotProfile(id: id, name: id)
            var explicit = automatic
            explicit.appearance = BotAppearance(shape: automatic.face.shape, color: automatic.face.color)
            #expect(try render(BotAvatar(profile: automatic, size: 56, motion: .still), size: 56).bytes
                == render(BotAvatar(profile: explicit, size: 56, motion: .still), size: 56).bytes)
        }
        let renderer = ImageRenderer(content: Rectangle().fill(.blue).frame(width: 20, height: 20))
        let image = UIImage(cgImage: try #require(renderer.cgImage))
        let profile = BotProfile(id: "triangle", name: "Triangle", appearance: BotAppearance(shape: .triangle))
        let actual = try render(BotAvatar(profile: profile, image: image, size: 56, motion: .still), size: 56)
        let expected = try render(Image(uiImage: image).resizable().scaledToFit(), size: 56)
        #expect(actual.bytes == expected.bytes)
    }

    @Test func offlineSavedImageKeepsItsPixelsAndShowsAStaticSignalCue() throws {
        let renderer = ImageRenderer(content: Rectangle().fill(.blue).frame(width: 20, height: 20))
        let image = UIImage(cgImage: try #require(renderer.cgImage))
        let profile = BotProfile(id: "photo", name: "Photo", appearance: BotAppearance(shape: .squircle))
        for size: CGFloat in [30, 32, 56, 72] {
            let online = try render(BotAvatar(profile: profile, image: image, size: size), size: size * 2)
            let offline = try render(BotAvatar(profile: profile, image: image, size: size, presentation: .offline)
                .environment(\.avatarMotionDisabledForTesting, true), size: size * 2)
            #expect(offline.bytes != online.bytes)
            let center = (offline.height / 2 * offline.width + offline.width / 2) * 4
            #expect(Array(offline.bytes[center..<center + 4]) == Array(online.bytes[center..<center + 4]))
        }
    }

    @Test func toolCueOverlapsEveryBody() throws {
        var failures: [String] = []
        let scale: CGFloat = 3
        for shape in BotAvatarShape.allCases {
            let profile = BotProfile(id: "tool-attachment", name: "Tool attachment",
                appearance: BotAppearance(shape: shape, color: "#f97316"))
            for size: CGFloat in [30, 56, 96] {
                let canvas = size * 2
                let body = try render(BotAvatarBody(shape: shape).fill(.black)
                    .frame(width: size, height: size), size: canvas, scale: scale)
                let reference = try render(BotAvatarMark(profile: profile, size: size), size: canvas, scale: scale)
                let actual = try render(BotAvatarMotion(profile: profile, size: size,
                    presentation: .init(activity: .tools, enteredAt: .distantPast), still: true), size: canvas, scale: scale)
                var overlap = 0
                for offset in stride(from: 0, to: actual.bytes.count, by: 4) where body.bytes[offset + 3] > 240 {
                    if (0..<3).contains(where: {
                        abs(Int(actual.bytes[offset + $0]) - Int(reference.bytes[offset + $0])) > 32
                    }) { overlap += 1 }
                }
                // Require visible overlap rather than a one-pixel edge touch.
                let minimumOverlap = Int(size * size * scale * scale * 0.0025)
                if overlap < minimumOverlap {
                    failures.append("\(shape)/\(size): \(overlap) overlap pixels, need \(minimumOverlap)")
                }
            }
        }
        let allOverlap = failures.isEmpty
        #expect(allOverlap, "Wrench must overlap each silhouette: \(failures)")
    }

    @Test func activityCuesLeaveEveryExpressionReadable() throws {
        var failures: [String] = []
        let activities: [BotMotionActivity] = [.thinking, .tools, .failed, .waiting, .unavailable, .offline]
        for shape in BotAvatarShape.allCases {
            for expression in BotAvatarExpression.allCases {
                let profile = BotProfile(id: "cue-clearance", name: "Cue clearance", appearance: BotAppearance(
                    shape: shape, color: "#f97316", expression: expression.rawValue
                ))
                for activity in activities {
                    let frame = BotCharacterFrame.resting(activity: activity)
                    for size: CGFloat in [30, 96] {
                        let reference = try render(BotAvatarMark(profile: profile, size: size,
                            pose: BotFacePose(lid: frame.lid), animatedEyes: frame.eyes(for: profile)), size: size)
                        let actual = try render(BotAvatarMotion(profile: profile, size: size,
                            presentation: .init(activity: activity, enteredAt: .distantPast), still: true), size: size)
                        var covered = 0
                        for offset in stride(from: 0, to: reference.bytes.count, by: 4) {
                            guard reference.bytes[offset + 3] > 240,
                                  (0..<3).allSatisfy({ reference.bytes[offset + $0] < 65 }) else { continue }
                            if (0..<3).contains(where: {
                                abs(Int(actual.bytes[offset + $0]) - Int(reference.bytes[offset + $0])) > 8
                            }) { covered += 1 }
                        }
                        if covered > 0 {
                            failures.append("\(shape)/\(expression)/\(activity)/\(size): \(covered) eye pixels covered")
                        }
                    }
                }
            }
        }
        let allClear = failures.isEmpty
        #expect(allClear, "Activity cues must leave eyes clear: \(failures.prefix(20))")
    }

    private func render(_ view: some View, size: CGFloat, scale: CGFloat = 3) throws -> Pixels {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size))
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Pixels(width: image.width, height: image.height, bytes: bytes)
    }

    /// Compare the actual SwiftUI output to the actual body silhouette. One physical
    /// pixel of edge tolerance covers raster antialiasing, not a protruding capsule.
    private func overflowPixels(_ actual: Pixels, outside body: Pixels) -> Int {
        var count = 0
        for y in 0..<actual.height {
            for x in 0..<actual.width where actual.alpha(x, y) > 32 {
                if body.alpha(x, y) > 16 { continue }
                let covered = (-1...1).contains { dy in
                    (-1...1).contains { dx in body.alpha(x + dx, y + dy) > 16 }
                }
                if !covered { count += 1 }
            }
        }
        return count
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return 0 }
            return bytes[(y * width + x) * 4 + 3]
        }
    }
}

/// Retains native renders for human inspection alongside the pixel assertions.
final class BotAvatarProofTests: XCTestCase {
    @MainActor func testCaptureActivityCueCorners() throws {
        let activities: [BotMotionActivity] = [.thinking, .tools, .failed, .waiting, .unavailable, .offline]
        for scheme in [ColorScheme.light, .dark] {
            for avatarSize: CGFloat in [30, 72] {
                let content = VStack(spacing: 14) {
                    HStack {
                        Text("Shape").frame(width: 90, alignment: .leading)
                        ForEach(activities) { activity in
                            Text(activity.rawValue).font(.caption).frame(width: 100)
                        }
                    }
                    ForEach(BotAvatarShape.allCases) { shape in
                        HStack(spacing: 8) {
                            Text(shape.rawValue.capitalized).font(.caption).frame(width: 90, alignment: .leading)
                            ForEach(activities) { activity in
                                let profile = BotProfile(id: "cue-proof", name: "Cue proof",
                                    appearance: BotAppearance(shape: shape, color: "#f97316"))
                                BotAvatarMotion(profile: profile, size: avatarSize,
                                    presentation: .init(activity: activity, enteredAt: .distantPast), still: true)
                                    .frame(width: 100, height: avatarSize + 28)
                            }
                        }
                    }
                    HStack(spacing: 36) {
                        ForEach([30.0, 56.0, 96.0], id: \.self) { size in
                            VStack(spacing: 12) {
                                BotAvatarMotion(profile: BotProfile(id: "small-cue", name: "Cue proof",
                                    appearance: BotAppearance(shape: .squircle, color: "#f97316")), size: size,
                                    presentation: .init(activity: .waiting, enteredAt: .distantPast), still: true)
                                Text("\(Int(size)) pt").font(.caption)
                            }
                        }
                    }.padding(.top, 16)
                }
                .padding(24).background(BottoTheme.paper).foregroundStyle(BottoTheme.ink)
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
                attachment.name = "Activity cue corners - \(Int(avatarSize)) pt - \(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor func testCaptureRedShadeComparison() throws {
        let content = VStack(spacing: 16) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                HStack(spacing: 40) {
                    ForEach(["#ef4444", "#f05252"], id: \.self) { color in
                        VStack(spacing: 8) {
                            BotAvatar(profile: BotProfile(id: "red-proof", name: "Red",
                                appearance: BotAppearance(shape: .squircle, color: color)), size: 120, motion: .still)
                            Text(color == "#ef4444" ? "Current red" : "Brighter red").font(.headline)
                        }
                    }
                }
                .padding(24).frame(width: 440).background(BottoTheme.paper)
                .environment(\.colorScheme, scheme)
            }
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
        attachment.name = "Current and brighter red with dark eyes"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testCaptureBottoAvatarFamiliesAndPalette() throws {
        let kinds = ["round", "organic", "boxy", "capsule", "nub", "cloud", "droplet", "hexagon", "sun", "triangle"]
        let content = VStack(alignment: .leading, spacing: 20) {
            Text("Botto avatars").font(.title.bold())
            Text("Shared shape families · Botto’s own faces and colors").font(.subheadline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
                ForEach(kinds, id: \.self) { kind in
                    let profile = BotProfile(id: "avatar-proof", name: kind,
                        appearance: BotAppearance(rawShape: "blobatar:botto-avatar:\(kind)", custom: true))
                    VStack(spacing: 4) {
                        BotAvatar(profile: profile, size: 96, motion: .still)
                        Text(kind.capitalized).font(.caption)
                    }
                }
            }
            Text("Familiar preset colors").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 16) {
                ForEach(BotAvatarColors.presets) { preset in
                    let profile = BotProfile(id: "preset", name: preset.id,
                        appearance: BotAppearance(shape: .squircle, color: preset.shared))
                    VStack(spacing: 4) {
                        BotAvatar(profile: profile, size: 76, motion: .still)
                        Text(BotAvatarColor.label(for: preset.shared)).font(.caption)
                    }
                }
            }
            HStack(spacing: 18) {
                BotAvatar(profile: BotProfile(id: "custom", name: "Custom", appearance: BotAppearance(
                    shape: .cloud, color: "hsl(30 40% 50%)")), size: 72, motion: .still)
                VStack(alignment: .leading) {
                    Text("Custom colors stay exact").font(.headline)
                    Text("This custom brown is preserved rather than mapped to a preset.").font(.caption)
                }
            }
        }
        .padding(24).frame(width: 728).background(.white).foregroundStyle(.black)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Botto avatar families and regular palette"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
