import Foundation
import CryptoKit
import ImageIO
import Testing
@testable import BottoCore

@MainActor @Test func customAvatarSavePublishesAStaticPNGAlongsideItsRecipe() async throws {
    let host = try HermesTestHost()
    host.profiles = .object(["profiles": .array([.object(["name": .string(host.bot.id),
        "has_avatar": .bool(false), "ui_meta_revisions": .object(["hermes-bots": .number(1)]),
        "ui_meta": .object(["hermes-bots": .object(["title": .string("Keep title")])])])])])
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "profiles.configure":
            return .object(["applied": .object(["ui_meta": .bool(true),
                "ui_meta_revisions": .object(["hermes-bots": .number(2)])])])
        case "profiles.set_asset": return .object(["ok": .bool(true), "asset": .string("avatar")])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    let geometry = BotAvatarCatalog.geometry(for: .triangle)
    let saved = try await service.setAvatar(.geometry(geometry, color: .value("#123456")), for: bot)
    let writes = host.sockets[0].sent.filter { $0["method"].text == "profiles.set_asset" }
    #expect(writes.count == 1)
    let payload = try #require(writes.first?["params"]["data"].text)
    let data = try #require(Data(base64Encoded: String(payload.dropFirst("data:image/png;base64,".count))))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 512 && image.height == 512)
    #expect(saved.hasAvatar == true && saved.appearance?.geometry != nil)
    let look = try #require(host.sockets[0].sent.first { $0["method"].text == "profiles.configure" })["params"]["ui_meta"]["hermes-bots"]
    #expect(look["title"].text == "Keep title")
    #expect(look["imageKind"].text == "shape")
    #expect(look["bottoPreviewSHA256"].text == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    #expect(!writes.contains { $0["params"]["clear"].flag == true })
}

@Test func staticPreviewKeepsTransparentMarginsBodyColorAndEyes() async throws {
    let source = try await BotAvatarEngine.shared.prepare(BotAvatarCatalog.geometry(for: .squircle))
    let preview = try BotAvatarStaticPreview.render(source, color: "#123456")
    let imageSource = try #require(CGImageSourceCreateWithData(preview.data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    var pixels = [UInt8](repeating: 0, count: 512 * 512 * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: 512, height: 512, bitsPerComponent: 8,
            bytesPerRow: 512 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        return true
    }
    #expect(drawn)
    #expect(pixels[3] == 0)
    let center = (256 * 512 + 256) * 4
    #expect(Array(pixels[center..<(center + 4)]) == [18, 52, 86, 255])
    #expect(stride(from: 0, to: pixels.count, by: 4).contains { index in
        pixels[index] > 200 && pixels[index + 1] > 200 && pixels[index + 2] > 200 && pixels[index + 3] == 255
    }, "Dark custom bodies need visible light eyes.")
    if let directory = ProcessInfo.processInfo.environment["BOTTO_STATIC_AVATAR_OUTPUT"] {
        try preview.data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("squircle.png"))
    }
}

@MainActor @Test func customAvatarColorEditsRefreshThePNGAndPresetEditsRemoveIt() async throws {
    let fixture = try StaticPreviewHost()
    let service = fixture.host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: fixture.host.configuration)
    let original = try #require(try await service.bots().first)
    let geometry = BotAvatarCatalog.geometry(for: .cloud)
    let first = try await service.setAvatar(.geometry(geometry, color: .value("#123456")), for: original)
    let firstImage = try #require(try await service.avatarAsset(for: first))
    #expect(firstImage.isStaticPreview(for: first.appearance))
    let colored = try await service.setAvatar(.edit(.init(color: .value("#abcdef"))), for: first)
    let secondImage = try #require(try await service.avatarAsset(for: colored))
    #expect(colored.appearance?.rawShape == first.appearance?.rawShape)
    #expect(secondImage != firstImage && secondImage.isStaticPreview(for: colored.appearance))
    let restored = try JSONDecoder().decode(BotProfile.self, from: JSONEncoder().encode(colored))
    #expect(secondImage.isStaticPreview(for: restored.appearance))
    var photo = restored.appearance; photo?.imageKind = "photo"
    #expect(!secondImage.isStaticPreview(for: photo))
    #expect(!firstImage.isStaticPreview(for: colored.appearance))
    let classic = try await service.setAvatar(.shape(.hexagon), for: colored)
    #expect(classic.appearance?.geometry == nil && classic.appearance?.bottoPreviewSHA256 == nil)
    #expect(classic.hasAvatar == false && fixture.asset == nil)
    #expect(fixture.host.sockets[0].sent.filter { $0["method"].text == "profiles.set_asset" }.count == 3)
}

@MainActor @Test(arguments: ["reject", "timeout"])
func customAvatarUploadFailureReportsPartialSaveWithoutReplayingIt(failure: String) async throws {
    let fixture = try StaticPreviewHost()
    fixture.uploadFailure = failure
    let service = fixture.host.service(requestTimeout: .milliseconds(80)); defer { service.disconnect() }
    _ = try await service.connect(configuration: fixture.host.configuration)
    let original = try #require(try await service.bots().first)
    await #expect(throws: HermesServiceError.partialAvatar) {
        _ = try await service.setAvatar(.geometry(BotAvatarCatalog.geometry(for: .drop)), for: original)
    }
    if failure == "timeout" { _ = try await service.connect(configuration: fixture.host.configuration) }
    let fresh = try #require(try await service.bots().first)
    #expect(fresh.appearance?.geometry != nil && fresh.hasAvatar == false)
    #expect(fixture.asset == nil)
    #expect(fixture.host.sockets.flatMap(\.sent).filter { $0["method"].text == "profiles.set_asset" }.count == 1)
    await #expect(throws: HermesServiceError.avatarConflict) {
        _ = try await service.setAvatar(.shape(.circle), for: original)
    }
    fixture.uploadFailure = nil
    let saved = try await service.setAvatar(.geometry(try #require(fresh.appearance?.geometry)), for: fresh)
    #expect(saved.hasAvatar == true)
}

@MainActor private final class StaticPreviewHost {
    let host: HermesTestHost
    var asset: BotAvatarAsset?
    var uploadFailure: String?
    private var revision = 1
    private var look: HermesJSON = .object(["title": .string("Kept"), "future": .bool(true)])
    init() throws {
        host = try HermesTestHost()
        host.methodOverride = { [unowned self] frame, socket in
            switch frame["method"].text {
            case "profiles.list":
                return .object(["profiles": .array([.object(["name": .string(host.bot.id),
                    "has_avatar": .bool(asset != nil), "ui_meta_revisions": .object(["hermes-bots": .number(Double(revision))]),
                    "ui_meta": .object(["hermes-bots": look])])])])
            case "profiles.configure":
                #expect(frame["params"]["ui_meta_expected_revisions"]["hermes-bots"].integer == revision)
                look = frame["params"]["ui_meta"]["hermes-bots"]; revision += 1
                #expect(look["future"].flag == true)
                return .object(["applied": .object(["ui_meta": .bool(true),
                    "ui_meta_revisions": .object(["hermes-bots": .number(Double(revision))])])])
            case "profiles.set_asset":
                if uploadFailure == "reject" { socket.reject(frame, code: 500); return nil }
                if uploadFailure == "timeout" { return nil }
                if frame["params"]["clear"].flag == true { asset = nil }
                else if let text = frame["params"]["data"].text,
                        let bytes = Data(base64Encoded: String(text.dropFirst("data:image/png;base64,".count))) {
                    asset = BotAvatarAsset(data: bytes, mimeType: "image/png")
                }
                return .object(["ok": .bool(true), "asset": .string("avatar")])
            case "profiles.get_asset":
                guard let asset else { return .object(["found": .bool(false)]) }
                return .object(["found": .bool(true), "mime": .string(asset.mimeType),
                    "size": .number(Double(asset.data.count)), "data": .string("data:image/png;base64," + asset.data.base64EncodedString())])
            default: return host.defaultReply(frame, socket: socket)
            }
        }
    }
}
