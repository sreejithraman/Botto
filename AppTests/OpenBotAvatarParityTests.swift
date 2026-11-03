import SwiftUI
import Testing
import UIKit
import WebKit
import BottoCore
@testable import Botto

@Suite(.serialized) @MainActor
struct OpenBotAvatarParityTests {
    @Test func nativeCanvasMatchesIndependentCanonicalSVGs() async throws {
        let fixtures = try fixtures()
        #expect(fixtures.cases.count == 16)
        let reference = try SVGReferenceRasterizer(scene: try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
        defer { reference.close() }
        for fixture in fixtures.cases {
            let geometry = fixture.definition
            let asset = try await BotAvatarEngine.shared.prepare(geometry, depth: fixture.options.depth)
            let frame = try await BotAvatarEngine.shared.frame(geometry, options: fixture.options)
            let renderer = ImageRenderer(content: BotAvatarCanvas(asset: BotAvatarNativeAsset(asset), frame: frame,
                color: fixtures.color).frame(width: 256, height: 256).background(.white).environment(\.colorScheme, .light))
            renderer.scale = 1
            let actual = try #require(renderer.uiImage)
            let expected = try await reference.render(fixture.svg)
            let nativePixels = try Raster(actual), referencePixels = try Raster(expected)
            let difference = nativePixels.difference(from: referencePixels)
            if difference.misplacedPixels > 0 || difference.interiorColorErrors > 0 {
                if let data = actual.pngData() { Attachment.record(data, named: fixture.name + "-native.png") }
                if let data = expected.pngData() { Attachment.record(data, named: fixture.name + "-reference.png") }
            }
            #expect(difference.misplacedPixels == 0, "\(fixture.name): \(difference.misplacedPixels) pixels differ beyond the one-pixel edge allowance")
            #expect(difference.interiorColorErrors == 0, "\(fixture.name): \(difference.interiorColorErrors) solid interior pixels differ by more than 8 channel levels")
        }
    }

    @Test func rasterComparisonRejectsWrongViewAndMissingHappyEyes() async throws {
        let fixtures = try fixtures()
        let reference = try SVGReferenceRasterizer(scene: try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
        defer { reference.close() }
        let rest = try #require(fixtures.cases.first { $0.name == "cat-rest" })
        let turned = try #require(fixtures.cases.first { $0.name == "cat-turned-happy" })
        let a = try Raster(await reference.render(rest.svg))
        let b = try Raster(await reference.render(turned.svg))
        #expect(a.difference(from: a).misplacedPixels == 0)
        #expect(a.difference(from: b).misplacedPixels > 100, "Using the wrong canonical view must fail the parity comparison")
        let missingEyes = turned.svg.replacingOccurrences(of: "stroke=\"#1a1e22\"", with: "stroke=\"#b0c8e0\"")
        let withoutEyes = try Raster(await reference.render(missingEyes))
        #expect(b.difference(from: withoutEyes).misplacedPixels > 10, "Missing happy eye strokes must fail the same comparison")
    }

    private func fixtures() throws -> Fixtures {
        let url = try #require(Bundle(for: FixtureBundle.self).url(forResource: "OpenBotAvatarParity", withExtension: "json"))
        let result = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        #expect(result.source == "3a5119877844165eebafe57d3100da475f67d0a8")
        return result
    }

    private final class FixtureBundle: NSObject {}
    private struct Fixtures: Decodable {
        let source: String
        let color: String
        let cases: [Fixture]
    }
    private struct Fixture: Decodable {
        let name: String
        let definition: BotAvatarGeometry
        let options: BotAvatarFrameOptions
        let svg: String
    }

    private struct Raster {
        let bytes: [UInt8]
        let labels: [Int]
        let size = 256
        init(_ image: UIImage) throws {
            let source = try #require(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
            let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
                guard let context = CGContext(data: storage.baseAddress, width: 256, height: 256,
                    bitsPerComponent: 8, bytesPerRow: 256 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(source, in: CGRect(x: 0, y: 0, width: 256, height: 256))
                return true
            }
            #expect(drawn)
            bytes = pixels
            let paints = [[255, 255, 255], [176, 200, 224], [26, 30, 34]]
            labels = stride(from: 0, to: pixels.count, by: 4).map { offset in
                paints.indices.min { a, b in
                    func distance(_ paint: [Int]) -> Int {
                        (0..<3).reduce(0) { $0 + (Int(pixels[offset + $1]) - paint[$1]) * (Int(pixels[offset + $1]) - paint[$1]) }
                    }
                    return distance(paints[a]) < distance(paints[b])
                }!
            }
        }
        // Quantize antialias colors to the nearest of the three intentional paint colors.
        // A symmetric neighborhood check allows a one-pixel edge shift, never a missing hole or eye.
        private func label(_ x: Int, _ y: Int) -> Int {
            labels[y * size + x]
        }
        func difference(from other: Raster) -> (misplacedPixels: Int, interiorColorErrors: Int) {
            var misplaced = 0, interior = 0
            for y in 1..<(size - 1) {
                for x in 1..<(size - 1) {
                    let a = label(x, y), b = other.label(x, y)
                    var aNearby = false, bNearby = false, uniform = true
                    for dy in -1...1 { for dx in -1...1 {
                        aNearby = aNearby || other.label(x + dx, y + dy) == a
                        bNearby = bNearby || label(x + dx, y + dy) == b
                        let center = (y * size + x) * 4, neighbor = ((y + dy) * size + x + dx) * 4
                        uniform = uniform && (0..<3).allSatisfy { abs(Int(other.bytes[center + $0]) - Int(other.bytes[neighbor + $0])) <= 1 }
                    } }
                    if !aNearby || !bNearby { misplaced += 1 }
                    if uniform {
                        let offset = (y * size + x) * 4
                        if (0..<3).contains(where: { abs(Int(bytes[offset + $0]) - Int(other.bytes[offset + $0])) > 8 }) { interior += 1 }
                    }
                }
            }
            return (misplaced, interior)
        }
    }
}

@MainActor private final class SVGReferenceRasterizer: NSObject, @preconcurrency WKNavigationDelegate {
    private let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 256, height: 256))
    private let window: UIWindow
    private weak var previousKey: UIWindow?
    private var loaded = false
    private var navigationError: Error?
    private var snapshot: Result<UIImage, Error>?

    init(scene: UIWindowScene) {
        window = UIWindow(windowScene: scene)
        previousKey = scene.windows.first { $0.isKeyWindow }
        super.init()
        let controller = UIViewController()
        window.rootViewController = controller
        window.frame = scene.coordinateSpace.bounds
        controller.view.addSubview(web)
        web.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16),
            web.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 16),
            web.widthAnchor.constraint(equalToConstant: 256),
            web.heightAnchor.constraint(equalToConstant: 256)
        ])
        web.navigationDelegate = self
        web.isOpaque = true
        web.backgroundColor = .white
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }
    func close() {
        web.stopLoading()
        web.removeFromSuperview()
        window.isHidden = true
        previousKey?.makeKey()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error }

    func render(_ svg: String) async throws -> UIImage {
        loaded = false; navigationError = nil; snapshot = nil
        let deadline = ContinuousClock.now + .seconds(15)
        web.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{margin:0;width:256px;height:256px;background:#fff}svg{display:block}</style></head><body>\(svg)</body></html>", baseURL: nil)
        while !loaded, navigationError == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if let navigationError { throw navigationError }
        guard loaded else { throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Reference SVG navigation exceeded 15 seconds"]) }
        let top = try await web.evaluateJavaScript("document.querySelector('svg').getBoundingClientRect().top")
        #expect((top as? Double) == 0)
        #expect(web.scrollView.adjustedContentInset == .zero)
        #expect(web.safeAreaInsets == .zero)
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        config.snapshotWidth = 256
        web.takeSnapshot(with: config) { [weak self] image, error in
            if let image { self?.snapshot = .success(image) }
            else { self?.snapshot = .failure(error ?? CocoaError(.fileReadUnknown)) }
        }
        while snapshot == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard let snapshot else { throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Reference SVG snapshot exceeded 15 seconds"]) }
        return try snapshot.get()
    }
}
