import SwiftUI
import Testing
import UIKit
import BottoCore
@testable import Botto

@Suite(.serialized) @MainActor
struct CustomAvatarLayoutTests {
    @Test(.timeLimit(.minutes(1))) func transientRendererFailureResumesFramesAndReleasesEachInstance() async throws {
        let profile = BotProfile(id: "recover-frame", name: "Recover", appearance: BotAppearance(shape: .circle))
        let geometry = BotAvatarCatalog.geometry(for: .circle)
        let source = try await BotAvatarRenderCache.shared.prepare(geometry)
        let expected = try await BotAvatarEngine.shared.frame(geometry,
            options: .init(motion: .happy, reducedMotion: true, view: .init(yaw: 0.6, pitch: 0)))
        let failure = RendererFailureProbe(frame: expected)
        let model = BotAvatarRenderModel(renderFrame: { _, options in try failure.render(options) },
            releaseInstance: { failure.release($0) })
        let playback = Task { await model.run(profile: profile,
            initialPresentation: .init(activity: .idle, enteredAt: .distantPast), still: false) }
        await failure.firstFailure()
        #expect(model.frame == source.source.restingFrame)
        model.updatePresentation(.init(activity: .working, enteredAt: .now))
        for _ in 0..<100 where failure.requests.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(failure.requests.count >= 2, "A transient failure must resume canonical frames in the mounted view.")
        #expect(model.frame == expected)
        let firstID = try #require(failure.requests.first?.instanceID)
        let resumedID = try #require(failure.requests.dropFirst().first?.instanceID)
        #expect(firstID != resumedID)
        #expect(failure.requests.dropFirst().first?.motion == .thinking)
        #expect(failure.releases == [firstID], "The failed instance retires before replacement playback.")
        playback.cancel()
        await playback.value
        #expect(failure.releases == [firstID, resumedID])
    }

    @Test(.timeLimit(.minutes(1))) func persistentRendererFailureStopsAfterBoundedRecovery() async throws {
        let profile = BotProfile(id: "failed-frame", name: "Failed", appearance: BotAppearance(shape: .circle))
        let source = try await BotAvatarRenderCache.shared.prepare(BotAvatarCatalog.geometry(for: .circle))
        let failure = RendererFailureProbe(frame: source.source.restingFrame, failuresBeforeSuccess: .max)
        let model = BotAvatarRenderModel(renderFrame: { _, options in try failure.render(options) },
            releaseInstance: { failure.release($0) })
        await model.run(profile: profile, initialPresentation: .idle, still: false)
        #expect(failure.requests.count == 3)
        let ids = failure.requests.compactMap(\.instanceID)
        #expect(Set(ids).count == 3)
        #expect(failure.releases == ids)
        #expect(model.frame == source.source.restingFrame)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func rendererRecoveryStopsWhenCanceledOrRetired(retire: Bool) async throws {
        let profile = BotProfile(id: "cancel-frame", name: "Cancel", appearance: BotAppearance(shape: .circle))
        let source = try await BotAvatarRenderCache.shared.prepare(BotAvatarCatalog.geometry(for: .circle))
        let failure = RendererFailureProbe(frame: source.source.restingFrame, failuresBeforeSuccess: .max)
        let model = BotAvatarRenderModel(renderFrame: { _, options in try failure.render(options) },
            releaseInstance: { failure.release($0) })
        let playback = Task { await model.run(profile: profile, initialPresentation: .idle, still: false) }
        await failure.firstFailure()
        if retire { model.retire() } else { playback.cancel() }
        await playback.value
        #expect(failure.requests.count == 1)
        #expect(failure.releases == failure.requests.compactMap(\.instanceID))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["resume", "cancel", "retire", "replace"])
    func playbackWaitsForCleanupAndCannotReviveRetiredOwnership(stop: String) async throws {
        let geometry = BotAvatarCatalog.geometry(for: .circle)
        let profile = BotProfile(id: "held-cleanup", name: "Cleanup", appearance: BotAppearance(shape: .circle))
        _ = try await BotAvatarRenderCache.shared.prepare(geometry)
        let expected = try await BotAvatarEngine.shared.frame(geometry,
            options: .init(motion: .happy, reducedMotion: true, view: .init(yaw: 0.6, pitch: 0)))
        let gate = InstanceCleanupGate(frame: expected)
        let model = BotAvatarRenderModel(renderFrame: { _, options in try gate.render(options) },
            releaseInstance: { await gate.release($0) })
        let playback = Task { await model.run(profile: profile, initialPresentation: .idle, still: false) }
        await gate.firstRelease()
        try await Task.sleep(for: .milliseconds(350))
        #expect(gate.requests.count == 1, "Replacement playback must wait beyond backoff for cleanup completion.")
        #expect(gate.completed.isEmpty)
        if stop == "cancel" { playback.cancel() }
        else if stop == "retire" { model.retire() }
        else if stop == "replace" {
            let replacement = BotProfile(id: "cleanup-replacement", name: "New", appearance: BotAppearance(shape: .sun))
            await model.run(profile: replacement, initialPresentation: .idle, still: true)
        }
        let represented = model.representedGeometry
        gate.complete()
        if stop == "resume" {
            await gate.resumedFrame()
            #expect(model.frame == expected)
            #expect(gate.requests.first?.instanceID != gate.requests.dropFirst().first?.instanceID)
            playback.cancel()
        }
        await playback.value
        #expect(gate.completed == gate.entered)
        if stop != "resume" {
            #expect(gate.requests.count == 1)
            #expect(model.representedGeometry == represented)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [BotAvatarEngineError.unavailable, .invalidFrame])
    func transientPreparationFailureRestoresTheRequestedCharacter(failure: BotAvatarEngineError) async throws {
        let circle = BotAvatarCatalog.geometry(for: .circle)
        let custom = try BotAvatarGeometry(json: circle.json.replacingOccurrences(of: #""id":"circle""#, with: #""id":"recovery-custom""#))
        let profile = BotProfile(id: "prepare-recovery", name: "Recover", appearance: BotAppearance(rawShape: custom.recipe))
        let fallback = BotAvatarCatalog.geometry(for: profile.face.shape)
        let ready = try await BotAvatarRenderCache.shared.prepare(custom)
        let safe = try await BotAvatarRenderCache.shared.prepare(fallback)
        var preparations: [String] = []
        var rendered: [String] = []
        let model = BotAvatarRenderModel(prepareAsset: { geometry in
            preparations.append(geometry.id)
            if preparations.count == 1 { throw failure }
            return geometry == custom ? ready : safe
        }, renderFrame: { geometry, _ in
            rendered.append(geometry.id)
            throw CancellationError()
        }, releaseInstance: { _ in })
        await model.run(profile: profile, initialPresentation: .idle, still: false)
        #expect(preparations == [custom.id, custom.id])
        #expect(rendered == [custom.id])
        #expect(model.asset?.source.geometry == custom)
        #expect(model.representedGeometry == custom.json)
    }
    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "retire", "replace"])
    func latePreparationCannotReplaceTheCurrentCharacter(stop: String) async throws {
        let circle = BotAvatarCatalog.geometry(for: .circle)
        let custom = try BotAvatarGeometry(json: circle.json.replacingOccurrences(of: #""id":"circle""#, with: #""id":"held-custom""#))
        let profile = BotProfile(id: "held-preparation", name: "Held", appearance: BotAppearance(rawShape: custom.recipe))
        let ready = BotAvatarNativeAsset(try await BotAvatarEngine.shared.prepare(custom))
        let gate = PreparationGate(ready: ready)
        var frames = 0
        let model = BotAvatarRenderModel(prepareAsset: { try await gate.prepare($0) }, renderFrame: { _, _ in
            frames += 1
            throw CancellationError()
        }, releaseInstance: { _ in })
        let playback = Task { await model.run(profile: profile, initialPresentation: .idle, still: false) }
        await gate.nextRequest()
        await gate.nextRequest()
        let fallback = BotAvatarCatalog.geometry(for: profile.face.shape)
        #expect(model.representedGeometry == fallback.json)
        #expect(model.drawing(for: custom)?.asset.source.geometry == fallback)
        if stop == "cancel" { playback.cancel() }
        else if stop == "retire" { model.retire() }
        else {
            let replacement = BotProfile(id: "replacement", name: "New", appearance: BotAppearance(shape: .sun))
            await model.run(profile: replacement, initialPresentation: .idle, still: true)
        }
        let represented = model.representedGeometry
        gate.complete()
        await playback.value
        #expect(model.representedGeometry == represented)
        #expect(model.asset?.source.geometry != custom)
        #expect(gate.requests == [custom.id, custom.id])
        #expect(frames == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func preparationDistinguishesInvalidRecipesFromTemporaryFailures(invalid: Bool) async throws {
        let circle = BotAvatarCatalog.geometry(for: .circle)
        let custom = try BotAvatarGeometry(json: circle.json.replacingOccurrences(of: #""id":"circle""#, with: #""id":"failed-custom""#))
        let profile = BotProfile(id: "failed-preparation", name: "Failed", appearance: BotAppearance(rawShape: custom.recipe))
        let fallback = BotAvatarCatalog.geometry(for: profile.face.shape)
        let safe = try await BotAvatarRenderCache.shared.prepare(fallback)
        var preparations: [String] = []
        var rendered: [String] = []
        let model = BotAvatarRenderModel(prepareAsset: { geometry in
            preparations.append(geometry.id)
            if geometry == fallback { return safe }
            if invalid { throw BotAvatarEngineError.invalidDefinition(["Rejected by canonical validator"]) }
            throw BotAvatarEngineError.unavailable
        }, renderFrame: { geometry, _ in
            rendered.append(geometry.id)
            throw CancellationError()
        }, releaseInstance: { _ in })
        await model.run(profile: profile, initialPresentation: .idle, still: false)
        #expect(preparations == (invalid ? [custom.id, fallback.id] : [custom.id, custom.id, custom.id]))
        #expect(rendered == (invalid ? [fallback.id] : []))
        #expect(model.representedGeometry == fallback.json)
        #expect(model.drawing(for: custom)?.asset.source.geometry == fallback)
    }


    @Test func playbackIgnoresMessagePreviewAndProfileTitleChanges() {
        var before = BotProfile(id: "playback", name: "Before", appearance: BotAppearance(shape: .cloud))
        let presentation = BotAvatarPresentation(activity: .working, enteredAt: .distantPast)
        let initial = BotAvatarPlayback(profile: before, presentation: presentation, still: false)
        before.name = "After"
        before.preview = "A new streamed message"
        before.updatedAt = .now
        #expect(BotAvatarPlayback(profile: before, presentation: presentation, still: false) == initial)
        let idle = BotAvatarPresentation(activity: .idle, enteredAt: .distantPast)
        #expect(BotAvatarPlayback(profile: before, presentation: idle, still: false) == initial)
        #expect(BotAvatarPlayback(profile: before, presentation: idle, still: true)
            != BotAvatarPlayback(profile: before, presentation: presentation, still: true))
        before.appearance = BotAppearance(shape: .circle)
        #expect(BotAvatarPlayback(profile: before, presentation: presentation, still: false) != initial)
    }

    @Test(.timeLimit(.minutes(1))) func heldFramesKeepTheCurrentPoseAndDoNotBlockNativeReactions() async throws {
        let profile = BotProfile(id: "held-frame", name: "Held", appearance: BotAppearance(shape: .circle))
        let geometry = BotAvatarCatalog.geometry(for: .circle)
        _ = try await BotAvatarRenderCache.shared.prepare(geometry)
        let turned = try await BotAvatarEngine.shared.frame(geometry,
            options: .init(motion: .happy, reducedMotion: true, view: .init(yaw: 0.6, pitch: 0)))
        let gate = NativeFrameGate()
        let model = BotAvatarRenderModel(renderFrame: { _, options in await gate.frame(options: options) })
        let first = Task { await model.run(profile: profile,
            initialPresentation: .init(activity: .finished, enteredAt: .now), still: true) }
        await gate.nextRequest()
        gate.complete(turned)
        await first.value
        #expect(model.frame == turned)

        let presentation = BotAvatarPresentation(activity: .finished, enteredAt: .now.addingTimeInterval(-0.47))
        model.updatePresentation(presentation)
        let changing = Task { await model.run(profile: profile, initialPresentation: presentation, still: false) }
        await gate.nextRequest()
        #expect(model.frame == turned, "An activity change must retain its last complete pose while waiting.")
        let cloud = BotAvatarCatalog.geometry(for: .cloud)
        #expect(model.drawing(for: cloud)?.asset.source.geometry.id == "cloud")
        let uncached = try BotAvatarGeometry(json: geometry.json.replacingOccurrences(
            of: #""id":"circle""#, with: #""id":"uncached-preview""#))
        #expect(model.drawing(for: uncached)?.asset.source.geometry.id == nil,
                "An unprepared selection must never borrow the previous character.")

        let previousDate = model.date
        let clock = Task { await model.runClock(presentation: presentation, still: false) }
        for _ in 0..<100 where model.date == previousDate { await Task.yield() }
        #expect(model.date > previousDate)
        let reaction = BotCharacterFrame.resolve(elapsed: model.date.timeIntervalSince(presentation.enteredAt), activity: .finished)
        #expect(reaction.tuck < 1 && reaction.lift < 0, "The verified reaction progresses before an engine frame arrives.")
        clock.cancel()
        let runtimeID = gate.lastOptions?.instanceID
        model.updatePresentation(.init(activity: .working, enteredAt: .now))
        gate.complete(turned)
        await gate.nextRequest()
        #expect(gate.lastOptions?.instanceID == runtimeID)
        #expect(gate.lastOptions?.motion == .thinking)
        changing.cancel()
        gate.complete(turned)
        await changing.value; await clock.value
        model.retire()
    }

    private static let definitions = [
        #"{"version":1,"id":"cat","name":"Cat","body":{"path":"M50 23C68 23 82 30 82 45C82 58 68 65 50 65C32 65 18 58 18 45C18 30 32 23 50 23ZM24 42C21 32 20 22 22 15C23 11 26 10 29 12C34 16 39 21 44 28L36 42ZM64 42L56 28C61 21 66 16 71 12C74 10 77 11 78 15C80 22 79 32 76 42ZM38 56L62 56C70 56 74 66 74 76C74 83 70 86 63 86L37 86C30 86 26 83 26 76C26 66 30 56 38 56ZM70 72C77 74 81 70 80 64C79 60 81 57 84 58C87 59 88.5 63 88 68C87 77 80 83 70 81Z"},"eyes":{"x":50,"y":43,"spacing":17,"scale":1.1}}"#,
        #"{"version":1,"id":"mug","name":"Mug","body":{"path":"M22 20H62C67 20 70 23 70 28V72C70 80 64 86 56 86H28C20 86 14 80 14 72V28C14 23 17 20 22 20ZM68 36C80 34 87 42 87 53C87 64 80 72 68 70ZM69 45L69 61C75.5 62 79 58.5 79 53C79 47.5 76 44 69 45Z"},"eyes":{"x":42,"y":49,"spacing":16,"scale":1.15}}"#,
        #"{"version":1,"id":"watering-can","name":"Watering Can","body":{"path":"M32 38H62C68 38 71 41 72 47L74 76C74.5 82 70 86 64 86H30C24 86 19.5 82 20 76L22 47C23 41 26 38 32 38ZM23 63C14 63 8.5 57 8.5 48C8.5 37 13 30.5 19 30.5C25 30.5 28.5 34 30 39.5L26 52ZM23.5 42C22 38 20 36 17.5 36C15 36 14 41 14 48C14 54 16 57.5 22 58L23.5 47ZM69 66C75 61 78 55 80 46.5L88 49.5C85 62 80 73 72 81ZM78.7 43A7 4.5 25 0 1 91.3 49A7 4.5 25 0 1 78.7 43Z"},"eyes":{"x":47,"y":61,"spacing":16,"scale":1.15}}"#
    ]

    @Test func canonicalNativePaintContainsEyesAcrossPresetsAndOfficialDefinitions() async throws {
        let custom = try Self.definitions.map { try BotAvatarGeometry(json: $0) }
        let all = BotAvatarShape.allCases.map { BotAvatarCatalog.geometry(for: $0) } + custom
        for geometry in all {
            let asset = try await BotAvatarRenderCache.shared.prepare(geometry)
            for motion in [BotAvatarFrameOptions.Motion.idle, .thinking, .happy] {
                let frame = try await BotAvatarEngine.shared.frame(geometry,
                    options: .init(time: 1.2, motion: motion, view: .init(yaw: 0.3, pitch: -0.14)))
                for size: CGFloat in [30, 56, 120] {
                    let actual = try render(BotAvatarCanvas(asset: asset, frame: frame, color: "#22c55e"), size: size)
                    let body = try render(BotAvatarCanvas(asset: asset, frame: frame, color: "#22c55e", drawsEyes: false), size: size)
                    #expect(overflowPixels(actual, outside: body) == 0, "\(geometry.id)/\(motion)/\(size)")
                    #expect(actual.bytes != body.bytes, "Canonical eye marks are painted.")
                }
            }
        }
    }

    @Test func projectedDepthHappyArcsAndCanonicalBoundsReachNativePainter() async throws {
        for definition in Self.definitions {
            let geometry = try BotAvatarGeometry(json: definition)
            let asset = try await BotAvatarRenderCache.shared.prepare(geometry)
            let rest = asset.source.restingFrame
            let side = try await BotAvatarEngine.shared.frame(geometry,
                options: .init(motion: .happy, reducedMotion: true, view: .init(yaw: 0.84, pitch: 0.17)))
            #expect(side.shapes.contains { if case .eye(_, _, .arc) = $0 { true } else { false } })
            #expect(side.shapes.filter { if case .slice = $0 { true } else { false } }.count > 2)
            let frontPixels = try render(BotAvatarCanvas(asset: asset, frame: rest, color: "#f97316"), size: 120)
            let sidePixels = try render(BotAvatarCanvas(asset: asset, frame: side, color: "#f97316"), size: 120)
            #expect(frontPixels.bytes != sidePixels.bytes)
            let layout = BotAvatarLayout(shape: .circle, size: 100, geometry: geometry)
            #expect(layout.bodyBounds == asset.restingBounds)
            #expect(asset.restingBounds.width > 0 && asset.restingBounds.height > 0)
        }
    }

    @Test func invalidCachedRecipeFallsBackToCanonicalFamily() async throws {
        let invalid = try BotAvatarGeometry(json: #"{"version":1,"id":"invalid","name":"Invalid","body":{"path":"M8 8L12 8L8 12Z"},"eyes":{"x":80,"y":80,"spacing":16,"scale":1}}"#)
        let profile = BotProfile(id: "cached-invalid", name: "Cached", appearance: BotAppearance(
            rawShape: invalid.recipe))
        let model = BotAvatarRenderModel()
        await model.run(profile: profile, initialPresentation: .init(activity: .idle, enteredAt: .distantPast), still: true)
        #expect(model.asset?.source.geometry.id == BotAvatarCatalog.geometry(for: profile.face.shape).id)
        #expect(model.frame != nil)
        let fallbackAsset = try #require(model.asset)
        #expect(!fallbackAsset.source.isRestingPreview)
        for yaw in [-1.2, -0.6, 0.6, 1.2] {
            let moving = try await BotAvatarEngine.shared.frame(fallbackAsset.source.geometry,
                options: .init(time: 2.4, motion: .thinking, view: .init(yaw: yaw, pitch: 0.3)))
            for shape in moving.shapes {
                if case .slice(_, let path, _) = shape {
                    #expect(fallbackAsset.paths[path] != nil,
                            "Moving fallback frames require complete prepared side-stack paths.")
                }
            }
        }
        model.retire()
    }

    @Test func translucentCanonicalSlicesApplyBodyAlphaOnceAndKeepEyesIndependent() async throws {
        let geometry = BotAvatarCatalog.geometry(for: .circle)
        let asset = try await BotAvatarRenderCache.shared.prepare(geometry)
        let frame = asset.source.restingFrame
        let half = try render(BotAvatarCanvas(asset: asset, frame: frame,
            color: "rgba(20, 40, 60, 0.5)", drawsEyes: false), size: 100, scale: 1)
        // Interior overlap covers many canonical slices; opacity belongs to their composite.
        #expect((126...130).contains(Int(half.alpha(50, 65))))
        #expect(half.bytes.enumerated().filter { $0.offset % 4 == 3 }.allSatisfy { $0.element <= 130 })
        let invisibleBody = try render(BotAvatarCanvas(asset: asset, frame: frame,
            color: "rgba(20, 40, 60, 0)", drawsEyes: false), size: 100, scale: 1)
        #expect(BotAvatarColors.presentation("rgba(20, 40, 60, 0)") == "#14283c00")
        let alphas = invisibleBody.bytes.enumerated().filter { $0.offset % 4 == 3 }.map(\.element)
        if alphas.contains(where: { $0 != 0 }) {
            let histogram = Dictionary(grouping: alphas, by: { $0 }).mapValues(\.count)
            Attachment.record(Data("\(invisibleBody.bitmapDescription)\n\(histogram)".utf8), named: "zero-body-bitmap.txt")
            if let png = UIImage(cgImage: invisibleBody.image).pngData() {
                Attachment.record(png, named: "zero-body-bitmap.png")
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            let surface = scheme == .light ? Color.white : Color.black
            let reference = try render(Rectangle().fill(surface), size: 100, scale: 1)
            let body = try render(BotAvatarCanvas(asset: asset, frame: frame,
                color: "rgba(20, 40, 60, 0)", drawsEyes: false)
                .background(surface).environment(\.colorScheme, scheme), size: 100, scale: 1)
            let eyes = try render(BotAvatarCanvas(asset: asset, frame: frame,
                color: "rgba(20, 40, 60, 0)")
                .background(surface).environment(\.colorScheme, scheme), size: 100, scale: 1)
            #expect(body.bytes == reference.bytes, "A zero-alpha body must not change its visible surface.")
            #expect(eyes.bytes != reference.bytes, "Eyes remain visible in both appearances.")
        }
    }

    @Test func typedEllipticalArcsStayCurvesAndPreserveEndpoints() throws {
        let path = try JSONDecoder().decode(BotAvatarVectorPath.self, from: Data(#"{"commands":[{"c":"M","x":20,"y":50},{"c":"A","rx":30,"ry":20,"rot":0,"large":0,"sweep":1,"x":80,"y":50},{"c":"Z"}],"evenOdd":false}"#.utf8)).native
        #expect(path.boundingRect.width >= 59.99)
        #expect(path.boundingRect.height >= 19.99)
        var curved = false
        path.cgPath.applyWithBlock { if $0.pointee.type == .addCurveToPoint { curved = true } }
        #expect(curved)
    }

    private func render(_ view: some View, size: CGFloat, scale: CGFloat = 3) throws -> Pixels {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size))
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Pixels(width: image.width, height: image.height, bytes: bytes, image: image,
            bitmapDescription: "alpha=\(image.alphaInfo.rawValue) bitmap=\(image.bitmapInfo.rawValue) bits=\(image.bitsPerPixel) row=\(image.bytesPerRow) mask=\(image.isMask) opaque=\(renderer.isOpaque)")
    }

    private func overflowPixels(_ actual: Pixels, outside body: Pixels) -> Int {
        var count = 0
        for y in 0..<actual.height {
            for x in 0..<actual.width where actual.alpha(x, y) > 32 && body.alpha(x, y) <= 16 {
                if !(-1...1).contains(where: { dy in (-1...1).contains { dx in body.alpha(x + dx, y + dy) > 16 } }) { count += 1 }
            }
        }
        return count
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        let image: CGImage
        let bitmapDescription: String
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return 0 }
            return bytes[(y * width + x) * 4 + 3]
        }
        func isDark(_ x: Int, _ y: Int) -> Bool {
            let index = (y * width + x) * 4
            return bytes[index + 3] > 240 && (0..<3).allSatisfy { bytes[index + $0] < 65 }
        }
    }
}

@MainActor private final class RendererFailureProbe {
    private enum Failure: Error { case transient }
    private let frame: BotAvatarRenderFrame
    private let failuresBeforeSuccess: Int
    private let failures: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private(set) var requests: [BotAvatarFrameOptions] = []
    private(set) var releases: [String] = []

    init(frame: BotAvatarRenderFrame, failuresBeforeSuccess: Int = 1) {
        self.frame = frame
        self.failuresBeforeSuccess = failuresBeforeSuccess
        (failures, signal) = AsyncStream.makeStream(of: Void.self)
    }
    func render(_ options: BotAvatarFrameOptions) throws -> BotAvatarRenderFrame {
        requests.append(options)
        if requests.count <= failuresBeforeSuccess { signal.yield(()); throw Failure.transient }
        return frame
    }
    func release(_ id: String) { releases.append(id) }
    func firstFailure() async {
        var iterator = failures.makeAsyncIterator()
        _ = await iterator.next()
    }
}

@MainActor private final class InstanceCleanupGate {
    private let frame: BotAvatarRenderFrame
    private let releases: AsyncStream<Void>
    private let releaseSignal: AsyncStream<Void>.Continuation
    private let frames: AsyncStream<Void>
    private let frameSignal: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var requests: [BotAvatarFrameOptions] = []
    private(set) var entered: [String] = []
    private(set) var completed: [String] = []
    init(frame: BotAvatarRenderFrame) {
        self.frame = frame
        (releases, releaseSignal) = AsyncStream.makeStream(of: Void.self)
        (frames, frameSignal) = AsyncStream.makeStream(of: Void.self)
    }
    func render(_ options: BotAvatarFrameOptions) throws -> BotAvatarRenderFrame {
        requests.append(options)
        if requests.count == 1 { throw BotAvatarEngineError.unavailable }
        frameSignal.yield(())
        return frame
    }
    func release(_ id: String) async {
        entered.append(id)
        if entered.count == 1 {
            await withCheckedContinuation { pending = $0; releaseSignal.yield(()) }
        }
        completed.append(id)
    }
    func firstRelease() async {
        var iterator = releases.makeAsyncIterator()
        _ = await iterator.next()
    }
    func resumedFrame() async {
        var iterator = frames.makeAsyncIterator()
        _ = await iterator.next()
    }
    func complete() { let request = pending; pending = nil; request?.resume() }
}

@MainActor private final class NativeFrameGate {
    private let requests: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<BotAvatarRenderFrame, Never>?
    private(set) var lastOptions: BotAvatarFrameOptions?

    init() { (requests, signal) = AsyncStream.makeStream(of: Void.self) }
    func frame(options: BotAvatarFrameOptions) async -> BotAvatarRenderFrame {
        lastOptions = options
        return await withCheckedContinuation { pending = $0; signal.yield(()) }
    }
    func nextRequest() async {
        var iterator = requests.makeAsyncIterator()
        _ = await iterator.next()
    }
    func complete(_ frame: BotAvatarRenderFrame) {
        let request = pending; pending = nil; request?.resume(returning: frame)
    }
}

@MainActor private final class PreparationGate {
    private let ready: BotAvatarNativeAsset
    private let events: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<BotAvatarNativeAsset, Never>?
    private(set) var requests: [String] = []
    init(ready: BotAvatarNativeAsset) {
        self.ready = ready
        (events, signal) = AsyncStream.makeStream(of: Void.self)
    }
    func prepare(_ geometry: BotAvatarGeometry) async throws -> BotAvatarNativeAsset {
        requests.append(geometry.id)
        if requests.count == 1 { signal.yield(()); throw BotAvatarEngineError.unavailable }
        return await withCheckedContinuation { pending = $0; signal.yield(()) }
    }
    func nextRequest() async {
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
    }
    func complete() { let request = pending; pending = nil; request?.resume(returning: ready) }
}
