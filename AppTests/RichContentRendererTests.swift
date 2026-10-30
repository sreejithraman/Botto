import Foundation
import BottoCore
import Testing
import WebKit
import CoreGraphics
import ImageIO
import SwiftUI
#if RICH_CONTENT_STANDALONE
@testable import RichContentHarness
import AppKit
#else
@testable import Botto
import UIKit
#endif

/// Production WKWebView checks; device interaction and external-network
/// observation require separate acceptance.
@MainActor @Suite(.serialized, RichReplyRuntime())
struct RichContentRendererTests {
    @Test func requestedHTMLHeightSurvivesLoadingUntilContentMeasurement() async throws {
        let renderer = makeRenderer()
        await renderer.load(block("html", "<p>Measured content</p>"), initialHeight: 360)
        defer { renderer.stop() }
        #expect(renderer.state == .loading)
        #expect(renderer.height == 360)
        let window = try await attach(renderer)
        defer { detach(window) }
        try await ready(renderer)
        #expect(renderer.height < 360, "Measured content replaces the initial hint")
    }
    @Test func htmlExecutesLocalJavaScriptInsideAnOpaqueFrame() async throws {
        let renderer = makeRenderer()
        let block = block("html", """
        <button id='counter' onclick='this.textContent=Number(this.textContent)+1'>0</button>
        <script>
        document.getElementById('counter').click();
        setInterval(() => parent.postMessage({testReport:{counter:document.getElementById('counter').textContent}}, '*'), 100);
        </script>
        """)
        await renderer.load(block)
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        try await ready(renderer)
        let web = try #require(renderer.webView)
        let isolated = try await evaluate(web, "document.querySelector('iframe').contentDocument === null")
        #expect(isolated == "1")
        let report = try await childReport(web)
        #expect(report["counter"] == "1")
        #expect(renderer.height >= 120 && renderer.height <= 480)
    }

    @Test func cancelledLoadCannotLeaveAPreviewOrSpinnerAlive() async {
        let renderer = makeRenderer()
        let source = block("html", "<p>Cancelled</p>")
        let task = Task { await renderer.load(source) }
        task.cancel()
        await task.value
        #expect(renderer.webView == nil)
        #expect(renderer.state == .idle)
    }

    @Test func delayedNativeAttachmentDoesNotConsumeTheExecutionDeadline() async throws {
        let renderer = makeRenderer()
        await renderer.load(block("html", "<p>Visible later</p>"))
        defer { renderer.stop() }
        try await Task.sleep(for: .seconds(6))
        #expect(renderer.state == .loading, "A detached WebKit view is suspended, not an unresponsive document")
        let window = try await attach(renderer)
        defer { detach(window) }
        try await ready(renderer)
    }

    @Test func bundledMermaidAndSVGRenderRealPixels() async throws {
        for (language, source) in [
            ("mermaid", "graph LR\nA[Start] --> B[Done]"),
            ("svg", "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='120'><rect width='240' height='120' fill='#e05020'/><text x='20' y='60'>Local SVG</text></svg>")
        ] {
            let renderer = makeRenderer()
            await renderer.load(block(language, source))
            let window = try await attach(renderer)
            defer { renderer.stop(); detach(window) }
            try await ready(renderer)
            let web = try #require(renderer.webView)
            let png = try await snapshot(web)
            #expect(try distinctPixelColors(png) > 8, "The actual snapshot must contain diagram ink, not only an empty background")
            #if RICH_CONTENT_STANDALONE
            try png.write(to: URL(fileURLWithPath: "/tmp/botto-rich-webkit-\(language).png"))
            #endif
        }
    }

    @Test(arguments: ["mermaid", "svg"])
    func renderedDiagramPixelsSurviveRetirementAndInvalidateWithTheirInput(language: String) async throws {
        let renderer = makeRenderer()
        let source = block(language, language == "mermaid" ? "graph LR\nA[Start] --> B[Done]" :
            "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='120'><rect width='240' height='120' fill='teal'/><circle cx='70' cy='60' r='40' fill='orange'/></svg>")
        await renderer.load(source, diagramWidth: 420)
        let mounted = try #require(renderer.webView)
        let window = try await attach(renderer, size: CGSize(width: 420, height: 480))
        defer { renderer.stop(); detach(window) }
        try await wait { renderer.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 420) != nil || renderer.webView == nil }
        try await recordDiagramEvidence(renderer.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 420),
                                  renderer: renderer, web: mounted, named: "retained-\(language)")
        let pixels = try #require(renderer.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 420))
        #expect(renderer.state == .ready)
        #expect(renderer.webView == nil, "A rendered static diagram must retire untrusted JavaScript immediately")
        #expect(pixels.pixelWidth <= 1_024 && pixels.pixelHeight <= 1_024)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try await nativePixels(pixels), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(try distinctPixelColors(data as Data) > 8, "Frozen content must contain actual diagram ink")
        for _ in 0..<3 {
            renderer.suspend()
            await renderer.load(source, diagramWidth: 420)
            #expect(renderer.state == .ready)
            #expect(renderer.webView == nil)
            #expect(renderer.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 420) === pixels)
        }
        #expect(renderer.diagramPresentation(for: source, dark: true, reduceMotion: false, width: 420) == nil)
        #expect(renderer.diagramPresentation(for: source, dark: false, reduceMotion: true, width: 420) == nil)
        #expect(renderer.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 300) == nil)
        #expect(renderer.diagramPresentation(for: block(language, "Different source"), dark: false, reduceMotion: false, width: 420) == nil)
        let otherOwner = makeRenderer()
        #expect(otherOwner.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 420) == nil,
                "Identical source in another owner must not inherit pixels")

        // A real changed request must execute and replace the pixels, rather than
        // merely hiding an old image behind a key comparison.
        await renderer.load(source, dark: true, reduceMotion: true, diagramWidth: 420)
        #expect(renderer.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 420) == nil)
        let changedWindow = try await attach(renderer, size: CGSize(width: 420, height: 480))
        defer { detach(changedWindow) }
        try await wait { renderer.diagramPresentation(for: source, dark: true, reduceMotion: true, width: 420) != nil || renderer.webView == nil }
        #expect(renderer.diagramPresentation(for: source, dark: true, reduceMotion: true, width: 420) != nil)
        #expect(renderer.webView == nil)
        let replacement = block(language, language == "mermaid" ? "graph LR\nC[Changed] --> D[New]" :
            "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='120'><rect width='240' height='120' fill='purple'/><circle cx='70' cy='60' r='40' fill='yellow'/></svg>")
        await renderer.load(replacement, dark: true, reduceMotion: true, diagramWidth: 300)
        let replacementWindow = try await attach(renderer, size: CGSize(width: 300, height: 480))
        defer { detach(replacementWindow) }
        try await wait { renderer.diagramPresentation(for: replacement, dark: true, reduceMotion: true, width: 300) != nil || renderer.webView == nil }
        #expect(renderer.diagramPresentation(for: replacement, dark: true, reduceMotion: true, width: 300) != nil)
        #expect(renderer.diagramPresentation(for: source, dark: true, reduceMotion: true, width: 420) == nil)
        renderer.stop()
        #expect(renderer.diagramPresentation(for: replacement, dark: true, reduceMotion: true, width: 300) == nil)
    }

    @Test func expandedTallDiagramCanFreezeWithinAShortViewport() async throws {
        let renderer = makeRenderer()
        let source = block("svg", "<svg xmlns='http://www.w3.org/2000/svg' width='300' height='700'><rect width='300' height='700' fill='teal'/><circle cx='80' cy='80' r='50' fill='orange'/></svg>")
        await renderer.load(source, diagramWidth: 420, diagramViewportHeight: 300)
        let web = try #require(renderer.webView)
        let window = try await attach(renderer, size: CGSize(width: 420, height: 300))
        defer { renderer.stop(); detach(window) }
        try await wait { renderer.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 420, viewportHeight: 300) != nil || renderer.webView == nil }
        try await recordDiagramEvidence(renderer.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 420, viewportHeight: 300),
                                  renderer: renderer, web: web, named: "expanded-svg-420x300")
        let image = try #require(renderer.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 420, viewportHeight: 300),
                                 "Expansion must capture its available viewport even when the inline document measures taller")
        #expect(abs(Double(image.pixelHeight) / Double(image.pixelWidth) - 300.0 / 420.0) < 0.01)
        #expect(renderer.webView == nil)
    }

    @Test(arguments: ["svg", "mermaid"], [320.0, 420.0])
    func frozenTallDiagramContainsBothEnds(language: String, width: Double) async throws {
        let renderer = makeRenderer()
        let source = block(language, language == "svg" ?
            "<svg xmlns='http://www.w3.org/2000/svg' width='300' height='1400'><rect width='300' height='1400' fill='#d7eee9'/><rect x='12' y='15' width='276' height='65' fill='#ff8000'/><rect x='12' y='1300' width='276' height='80' fill='#d000ff'/><text x='24' y='60' font-size='32'>TOP</text><text x='24' y='1360' font-size='32'>BOTTOM</text></svg>" :
            "graph TB\nA[TOP] --> B[Second] --> C[Third] --> D[Fourth] --> E[Fifth] --> F[Sixth] --> G[Seventh] --> H[BOTTOM]\nstyle A fill:#ff8000\nstyle H fill:#d000ff")
        await renderer.load(source, diagramWidth: width, diagramViewportHeight: 300)
        let web = try #require(renderer.webView)
        let window = try await attach(renderer, size: CGSize(width: width, height: 300))
        defer { renderer.stop(); detach(window) }
        try await wait { renderer.diagramPresentation(for: source, dark: false, reduceMotion: false,
            width: width, viewportHeight: 300) != nil || renderer.webView == nil }
        try await recordDiagramEvidence(renderer.diagramPresentation(for: source, dark: false, reduceMotion: false,
            width: width, viewportHeight: 300), renderer: renderer, web: web, named: "tall-\(language)-\(Int(width))x300")
        let image = try #require(renderer.diagramPresentation(for: source, dark: false, reduceMotion: false,
            width: width, viewportHeight: 300))
        let native = try await nativePixels(image)
        let context = try #require(CGContext(data: nil, width: native.width, height: native.height,
            bitsPerComponent: 8, bytesPerRow: native.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(native, in: CGRect(x: 0, y: 0, width: native.width, height: native.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var top = 0, bottom = 0
        for i in stride(from: 0, to: native.width * native.height * 4, by: 4) {
            if bytes[i] > 230 && (100...155).contains(bytes[i + 1]) && bytes[i + 2] < 30 { top += 1 }
            // The native adapter draws through the platform color profile. The
            // saturated purple sentinel can acquire green during that transform.
            if (185...230).contains(bytes[i]), bytes[i + 2] > 230,
               Int(bytes[i + 2]) - Int(bytes[i + 1]) > 170,
               Int(bytes[i]) - Int(bytes[i + 1]) > 120 { bottom += 1 }
        }
        #expect(top > 20, "The first diagram node must have actual pixels")
        #expect(bottom > 20, "The final diagram node must survive freezing, beyond the original viewport")
        #expect(renderer.webView == nil)
    }

    @Test func destroyedDiagramOwnerRejectsLateWebKitCompletion() async throws {
        let renderer = makeRenderer()
        let source = block("mermaid", "graph LR\nA[Retired] --> B[Owner]")
        await renderer.load(source, diagramWidth: 420)
        let window = try await attach(renderer, size: CGSize(width: 420, height: 480))
        defer { detach(window) }
        let retired = try #require(renderer.webView)
        renderer.stop()
        renderer.webViewWebContentProcessDidTerminate(retired)
        try await Task.sleep(for: .milliseconds(500))
        #expect(renderer.state == .idle)
        #expect(renderer.webView == nil)
        #expect(renderer.diagramPresentation(for: source, dark: false, reduceMotion: false, width: 420) == nil)
        #expect(retired.navigationDelegate == nil && retired.uiDelegate == nil)
        #expect(retired.configuration.userContentController.userScripts.isEmpty)
    }

    @Test func malformedAndOversizedContentKeepSourceWithoutAnActiveWebView() async throws {
        let renderer = makeRenderer()
        let oversized = block("html", String(repeating: "a", count: 140_000))
        await renderer.load(oversized)
        #expect(renderer.webView == nil)
        guard case .failed = renderer.state else { Issue.record("Oversized source must not render"); return }
        #expect(oversized.source.count == 140_001)
        let malformed = block("svg", "<svg><not-closed>")
        await renderer.load(malformed)
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        try await contentFailure(renderer)
        #expect(renderer.webView == nil)
        #expect(malformed.source == "<svg><not-closed>\n")
    }

    @Test func mermaidCannotOverrideEdgeBudgetWithADirectiveOrFrontmatter() async throws {
        let renderer = makeRenderer()
        let prefixes = [
            "%%{init: { 'maxEdges': 99999, 'securityLevel': 'loose', 'secure': [] }}%%\n",
            "---\nconfig:\n  maxEdges: 99999\n  flowchart:\n    maxEdges: 99999\n---\n"
        ]
        for prefix in prefixes {
            let diagram = prefix + "graph LR\n" + (0..<105).map { "A\($0)-->A\($0+1)" }.joined(separator: "\n")
            await renderer.load(block("mermaid", diagram))
            let window = try await attach(renderer)
            defer { renderer.stop(); detach(window) }
            try await contentFailure(renderer)
            #expect(renderer.webView == nil)
        }
    }

    @Test(arguments: [
            ("flow", "flowchart LR\nA[Draft] --> B[Review]"),
            ("sequence", "sequenceDiagram\nAlice->>Bob: Héllo 世界\nBob-->>Alice: Reviewed"),
            ("mindmap", "mindmap\n  root((Launch))\n    Review\n    Publish"),
            ("architecture", "architecture-beta\nservice api(server)[API]\nservice db(database)[Database]\napi:R -- L:db"),
            ("unicode-directive", "%%{init: { 'theme':'dark', 'themeVariables':{'fontFamily':'remote-font'} }}%%\nflowchart LR\nA[Révision 世界] --> B[✓ Ready]")
    ]) func peleRendersCommonAndPreviouslyUnsupportedDiagrams(name: String, source: String) async throws {
        let renderer = makeRenderer()
        await renderer.load(block("mermaid", source), dark: name == "mindmap")
        try installDiagramProbe(renderer)
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        try await ready(renderer)
        let web = try #require(renderer.webView)
        let report = try await childReport(web)
        #expect(report["svg"] == "1", "\(name) must produce a real SVG")
        #expect(report["activeElements"] == "0")
        #expect(report["handlers"] == "0")
        #expect(try distinctPixelColors(try await snapshot(web)) > 8)
        if name == "flow" {
            web.frame.size.width = 240
            try await Task.sleep(for: .milliseconds(200))
            let resized = try await childReport(web)
            #expect(resized["fitsWidth"] == "true", "The SVG must fit a narrower native surface")
        }
    }

    @Test(arguments: [
            """
            %%{init: { 'links':true, 'images':true, 'securityLevel':'loose' }}%%
            flowchart TD
            A["<img src='https://example.invalid/x' onerror='parent.pwned=true'>"] --> B
            click A "javascript:alert(1)"
            style A fill:red,stroke:#444
            """,
            """
            ---
            config:
              links: true
              images: true
            ---
            flowchart LR
            A@{ img: "https://example.invalid/image.png", label: "Remote", w: 100, h: 100 } --> B
            click B "https://example.invalid/link"
            """,
            "flowchart TD\nA[\"javascript:alert(1)\"]:::internal-link --> B"
    ]) func peleHostOptionsDisableLinksImagesAndActiveLabels(source: String) async throws {
        let renderer = makeRenderer()
        await renderer.load(block("mermaid", source))
        try installDiagramProbe(renderer)
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        try await ready(renderer)
        let web = try #require(renderer.webView)
        let report = try await childReport(web)
        #expect(report["activeElements"] == "0")
        #expect(report["handlers"] == "0")
        #expect(report["externalAttributes"] == "0")
        #expect(report["resources"] == "0")
        #expect(report["bridge"] == "undefined")
        #expect(report["parent"] == "SecurityError")
        #expect(try await evaluate(web, "location.href") == "about:blank")
        #expect(try await evaluate(web, "typeof window.pwned") == "undefined")
    }

    @Test func peleSourceOutputAndUnsupportedInputRemainBounded() async throws {
        let renderer = makeRenderer()
        let utf8 = block("mermaid", "flowchart LR\nA[" + String(repeating: "界", count: 6000) + "]")
        await renderer.load(utf8)
        #expect(renderer.webView == nil)
        #expect(utf8.source.utf8.count > ReplyContent.previewByteLimit(for: .mermaid))
        let largeOutput = "---\nconfig:\n  outputLimit: 99999999\n---\nflowchart TD\n"
            + (0..<2200).map { "N" + String($0, radix: 36) }.joined(separator: "\n")
        #expect(largeOutput.utf8.count < ReplyContent.previewByteLimit(for: .mermaid))
        for source in [largeOutput, "zenuml\nA->B: Unsupported", "flowchart NO\nA-->|",
                       "flowchart TD\nA --> B\nstyle A fill:url(https://example.invalid/x)"] {
            await renderer.load(block("mermaid", source))
            let window = try await attach(renderer)
            defer { renderer.stop(); detach(window) }
            try await contentFailure(renderer)
            #expect(renderer.webView == nil)
        }
    }

    /// Test-only telemetry runs inside the real opaque child, added before native
    /// attachment. It is absent from shipped resources and grants no app services.
    private func installDiagramProbe(_ renderer: RichContentRenderer) throws {
        let web = try #require(renderer.webView)
        web.configuration.userContentController.addUserScript(WKUserScript(source: """
        if (window !== top) setInterval(() => {
          const svg = document.querySelector('#diagram svg');
          if (!svg) return;
          const nodes = [svg, ...svg.querySelectorAll('*')];
          const attrs = nodes.flatMap(n => Array.from(n.attributes));
          let parentAccess;
          try { parentAccess = String(parent.document.body); } catch(e) { parentAccess=e.name; }
          parent.postMessage({testReport:{
            svg:String(document.querySelectorAll('#diagram > svg').length),
            activeElements:String(svg.querySelectorAll('a,image,script,foreignObject,iframe').length),
            handlers:String(attrs.filter(a => /^on/i.test(a.name)).length),
            externalAttributes:String(attrs.filter(a => !a.name.startsWith('xmlns') && /https?:|javascript:|file:/i.test(a.value)).length),
            resources:String(performance.getEntriesByType('resource').length),
            bridge:typeof window.webkit, parent:parentAccess,
            fitsWidth:String(svg.getBoundingClientRect().width <= document.documentElement.clientWidth)
          }}, '*');
        }, 100);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .page))
    }

    @Test func hostileHeightHintsRemainBoundedAndNeverOscillate() async throws {
        let renderer = makeRenderer()
        await renderer.load(block("html", """
        <p>A small document</p><script>
        let iteration = 0;
        setInterval(() => {
          const heights = [0, NaN, Infinity, -100, '480', 9999999999, 1];
          parent.postMessage({channel:'botto-size',kind:'ready',height:heights[iteration++ % heights.length]}, '*');
        }, 10);
        </script>
        """))
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        try await ready(renderer)
        try await wait { renderer.height == 480 }
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            #expect(renderer.height == 480)
        }
    }

    @Test func infiniteJavaScriptTimesOutAndReleasesTheWebView() async throws {
        let renderer = makeRenderer()
        let source = block("html", "<script>while(true) {}</script>")
        await renderer.load(source)
        let probe = try executionProbe(renderer)
        weak let retired = renderer.webView
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        try await wait { probe.started != nil || renderer.webView == nil }
        let started = try #require(probe.started, "A startup failure is not evidence of retiring running JavaScript")
        try await wait { if case .failed = renderer.state { true } else { false } }
        #expect(ContinuousClock.now - started < .seconds(7))
        #expect(renderer.webView == nil)
        try await wait { retired == nil }
        #expect(source.source.contains("while(true)"))
        renderer.suspend()
        await renderer.load(source)
        #expect(renderer.webView == nil, "Returning to a failed block must not restart its infinite loop")
        guard case .failed = renderer.state else { Issue.record("Suspension lost the terminal failure"); return }
    }

    @Test func aLaterInfiniteLoopAlsoRetiresAPreviouslyReadyPreview() async throws {
        let renderer = makeRenderer()
        await renderer.load(block("html", "<p>Ready first</p><script>setTimeout(() => { while(true) {} }, 1500);</script>"))
        weak let retired = renderer.webView
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        try await ready(renderer)
        let ready = ContinuousClock.now
        try await wait { if case .failed = renderer.state { true } else { false } }
        #expect(ContinuousClock.now - ready < .seconds(7))
        #expect(renderer.webView == nil)
        try await wait { retired == nil }
    }

    @Test func previewCannotSeeSharedCookies() async throws {
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "botto-renderer-test.invalid", .path: "/", .name: "hermes-test-\(UUID())", .value: "credential-sentinel"
        ]))
        let shared = WKWebsiteDataStore.default().httpCookieStore
        await shared.setCookie(cookie)
        let renderer = makeRenderer()
        await renderer.load(block("html", "<p>No shared credentials</p>"))
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        let web = try #require(renderer.webView)
        #expect(!web.configuration.websiteDataStore.isPersistent)
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        #expect(!cookies.contains { $0.name == cookie.name })
        await shared.deleteCookie(cookie)
    }

    @Test func childSelfNavigationAndDownloadsCannotReplaceThePreview() async throws {
        let renderer = makeRenderer()
        await renderer.load(block("html", """
        <p>Original content</p><script>
        setTimeout(() => { location.href='about:blank'; }, 1000);
        setTimeout(() => { location.href='botto-forbidden://open'; }, 1200);
        setTimeout(() => {
          const a=document.createElement('a'); a.href='data:text/plain,download';
          a.download='unsafe.txt'; document.body.append(a); a.click();
        }, 1400);
        setInterval(() => parent.postMessage({testReport:{url:location.href,text:document.body.textContent.includes('Original content') ? 'present' : 'lost'}}, '*'), 100);
        </script>
        """))
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        try await ready(renderer)
        try await Task.sleep(for: .seconds(2))
        let web = try #require(renderer.webView)
        let report = try await childReport(web)
        #expect(report["url"] == "about:srcdoc")
        #expect(report["text"] == "present")
        #expect(renderer.state == .ready)
    }

    @Test func repeatedInputKeepsTheDocumentAndReplacementFencesOldLifetimes() async throws {
        let renderer = makeRenderer()
        let first = block("html", "<p>First</p>")
        await renderer.load(first)
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        try await ready(renderer)
        let oldView = try #require(renderer.webView)
        await renderer.load(first)
        #expect(renderer.webView === oldView)
        await renderer.load(block("html", "<p>Replacement</p>"))
        #expect(renderer.webView !== oldView)
        renderer.webViewWebContentProcessDidTerminate(oldView)
        #expect(renderer.webView != nil)
        renderer.stop()
        #expect(renderer.webView == nil)
        #expect(renderer.state == .idle)
    }

    #if os(iOS)
    /// Offscreen previews release their document and watchdog even while SwiftUI retains the row.
    @Test func inlineViewportOwnsTheDocumentLifetime() async throws {
        let model = ViewportFixtureModel()
        let source = block("html", """
        <div style='height:220px'>Viewport fixture</div><script>
        setInterval(() => parent.postMessage({testReport:{value:'local JS alive'}}, '*'), 100);
        </script>
        """)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ViewportFixture(block: source, model: model)
            .environment(\.scenePhase, .active))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { detach(window) }
        try await Task.sleep(for: .seconds(6))
        #expect(webViews(in: host.view).isEmpty, "Initially offscreen content must not start WebKit or a timeout")

        model.target = "top"
        try await wait { !webViews(in: host.view).isEmpty }
        var web: WKWebView? = try #require(webViews(in: host.view).first)
        try await waitForFrame(try #require(web))
        #expect(try await childReport(try #require(web))["value"] == "local JS alive")
        let visibleHeight = try #require(web).bounds.height
        model.update += 1
        try await Task.sleep(for: .milliseconds(350))
        #expect(webViews(in: host.view).first === web, "Visible native updates must keep the same document")

        weak var retired = web
        web = nil
        model.target = "bottom"
        try await wait { webViews(in: host.view).isEmpty }
        try await wait { retired == nil }
        try await Task.sleep(for: .seconds(6))
        model.target = "top"
        try await wait { !webViews(in: host.view).isEmpty }
        let reopened = try #require(webViews(in: host.view).first)
        try await waitForFrame(reopened)
        #expect(try await childReport(reopened)["value"] == "local JS alive")
        #expect(reopened.bounds.height >= visibleHeight, "Offscreen retirement must preserve the measured layout height")
    }

    @Observable final class ViewportFixtureModel {
        var target = "bottom"
        var update = 0
    }

    private struct ViewportFixture: View {
        let block: ReplyContent.Block
        let model: ViewportFixtureModel
        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        VStack(alignment: .leading) {
                            Text("Before preview \(model.update)").id("top")
                            RichReplyBlockView(block: block)
                            Color.clear.frame(height: 1600)
                            Text("Newest text").id("bottom")
                        }.padding(20)
                    }
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(model.target == "bottom" ? .bottom : nil, for: .sizeChanges)
                .onChange(of: model.target) { _, target in
                    proxy.scrollTo(target, anchor: target == "top" ? .top : .bottom)
                }
            }
        }
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }

    private func waitForFrame(_ web: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(21)
        while ContinuousClock.now < deadline {
            do {
                if try await evaluate(web, "document.querySelector('iframe') !== null") == "1" { return }
            } catch ProbeFailure.javaScriptTimedOut {
                // A cold native process has not necessarily started JavaScript.
                // Keep the fixture within the same startup + execution deadline.
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ProbeFailure.javaScriptTimedOut
    }
    #endif

    /// Native snapshots and their color interpretation travel with the result
    /// bundle. A missing image records state/geometry instead of inventing pixels.
    private func recordDiagramEvidence(_ presentation: DiagramPresentation?, renderer: RichContentRenderer,
                                       web: WKWebView, named name: String) async throws {
        var details = "state=\(renderer.state) measuredHeight=\(renderer.height)\n\(geometry(of: web))"
        if let presentation {
            let image = try await nativePixels(presentation)
            Attachment.record(image, named: "\(name)-native.png", as: .png)
            if let profile = image.colorSpace?.copyICCData() {
                Attachment.record(Array(profile as Data), named: "\(name)-native-profile.icc")
            }
            details += "\npixels=\(image.width)x\(image.height) bits=\(image.bitsPerComponent)/\(image.bitsPerPixel) bytesPerRow=\(image.bytesPerRow)"
            details += "\ncolorSpace=\(String(describing: image.colorSpace)) alpha=\(image.alphaInfo) bitmap=\(image.bitmapInfo)"
            let device = try pixelHistogram(image, space: CGColorSpaceCreateDeviceRGB())
            let srgb = try pixelHistogram(image, space: #require(CGColorSpace(name: CGColorSpace.sRGB)))
            details += "\nDeviceRGB: \(device)\nsRGB: \(srgb)"
        } else { details += "\nNo native snapshot was produced." }
        Attachment.record(details, named: "\(name)-pixels-and-geometry.txt")
    }

    /// Inspect output through the actual native drawing adapter. No raw cache
    /// getter exists merely to let tests bypass charged storage ownership. UIKit
    /// must mount the host before capture so SwiftUI creates the drawing view.
    private func nativePixels(_ presentation: DiagramPresentation) async throws -> CGImage {
        let size = CGSize(width: presentation.pixelWidth, height: presentation.pixelHeight)
        #if RICH_CONTENT_STANDALONE
        let content = DiagramPixelsView(presentation: presentation).frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.cgImage)
        #else
        try await wait {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .contains { $0.activationState == .foregroundActive }
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let available = scene.coordinateSpace.bounds.insetBy(dx: 20, dy: 100).size
        let scale = min(1, min(available.width / size.width, available.height / size.height))
        let logical = CGSize(width: size.width * scale, height: size.height * scale)
        let host = UIHostingController(rootView: DiagramPixelsView(presentation: presentation)
            .frame(width: logical.width, height: logical.height).ignoresSafeArea())
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container
        container.addChild(host); container.view.addSubview(host.view)
        host.view.frame = CGRect(origin: .zero, size: logical)
        host.view.autoresizingMask = []
        host.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer {
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
            window.isHidden = true; window.rootViewController = nil
            previousKey?.makeKey()
        }
        func drawingView(in view: UIView) -> UIView? {
            if String(reflecting: type(of: view)).contains("DrawingView"), view.bounds.width > 0, view.bounds.height > 0 { return view }
            return view.subviews.lazy.compactMap { drawingView(in: $0) }.first
        }
        try await wait {
            host.view.layoutIfNeeded()
            return drawingView(in: host.view) != nil
        }
        let drawing = try #require(drawingView(in: host.view))
        drawing.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let result = try #require(UIGraphicsImageRenderer(size: size, format: format).image { output in
            output.cgContext.scaleBy(x: size.width / logical.width, y: size.height / logical.height)
            host.view.layer.render(in: output.cgContext)
        }.cgImage)
        Attachment.record(result, named: "exact-native-drawing-capture.png", as: .png)
        Attachment.record("host=\(host.view.bounds) drawing=\(drawing.bounds) window=\(drawing.window != nil) display=\(drawing.layer.needsDisplay()) contents=\(drawing.layer.contents != nil)", named: "mounted-native-drawing.txt")
        return result
        #endif
    }

    private func pixelHistogram(_ image: CGImage, space: CGColorSpace) throws -> String {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var colors: [UInt32: Int] = [:]
        var top = 0, bottom = 0
        for i in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            let color = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
            colors[color, default: 0] += 1
            if bytes[i] > 230 && (100...155).contains(bytes[i + 1]) && bytes[i + 2] < 30 { top += 1 }
            if (185...230).contains(bytes[i]) && bytes[i + 1] < 30 && bytes[i + 2] > 230 { bottom += 1 }
        }
        let common = colors.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(12).map { String(format: "#%06x:%d", $0.key, $0.value) }.joined(separator: ", ")
        return "TOP=\(top) BOTTOM=\(bottom) mostCommon=[\(common)]"
    }

    private func geometry(of web: WKWebView) -> String {
        var lines = ["web.bounds=\(web.bounds) frame=\(web.frame) autoresizing=\(web.autoresizingMask.rawValue) attached=\(web.window != nil)"]
        var ancestor = web.superview
        while let view = ancestor {
            #if RICH_CONTENT_STANDALONE
            lines.append("\(type(of: view)) bounds=\(view.bounds) frame=\(view.frame)")
            #else
            lines.append("\(type(of: view)) bounds=\(view.bounds) frame=\(view.frame) transform=\(view.transform) safeArea=\(view.safeAreaInsets)")
            #endif
            ancestor = view.superview
        }
        if let window = web.window { lines.append("window.frame=\(window.frame)") }
        return lines.joined(separator: "\n")
    }

    private func recordMountedGeometry(_ web: WKWebView, expected: CGSize) {
        Attachment.record("requested=\(expected)\n\(geometry(of: web))", named: "mounted-\(Int(expected.width))x\(Int(expected.height))-geometry.txt")
        #expect(web.bounds.size == expected, "The mounted native viewport must match the renderer request before readiness")
        #expect(web.window != nil)
        #if !RICH_CONTENT_STANDALONE
        if let window = web.window {
            #expect(window.bounds.insetBy(dx: -1, dy: -1).contains(web.convert(web.bounds, to: window)),
                    "A fixed logical viewport must fit onscreen, including on narrower phones")
        }
        #endif
    }

    private func snapshot(_ web: WKWebView) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: nil) { image, error in
                if let error { continuation.resume(throwing: error); return }
                #if RICH_CONTENT_STANDALONE
                let data = image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
                #else
                let data = image?.pngData()
                #endif
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
    }

    private func distinctPixelColors(_ data: Data) throws -> Int {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var colors = Set<UInt32>()
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            colors.insert(UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2]))
        }
        return colors.count
    }

    @Test func sandboxBlocksParentBridgeNetworkFilesNavigationFramesAndModals() async throws {
        let renderer = makeRenderer()
        await renderer.load(block("html", """
        <script>
        const result = {};
        const attempt = (key, action) => { try { result[key] = String(action()); } catch(e) { result[key] = e.name; } };
        const violations = new Set();
        document.addEventListener('securitypolicyviolation', e => violations.add(e.violatedDirective));
        attempt('parent', () => parent.document.body.innerHTML);
        attempt('bridge', () => typeof window.webkit);
        attempt('parentBridge', () => typeof parent.webkit);
        attempt('cookie', () => document.cookie);
        attempt('storage', () => localStorage.getItem('Hermes'));
        attempt('rtc', () => typeof RTCPeerConnection);
        attempt('worker', () => typeof Worker);
        attempt('camera', () => typeof navigator.mediaDevices);
        attempt('popup', () => window.open('https://example.invalid/popup') === null);
        attempt('alert', () => { alert('must not show'); return 'returned'; });
        attempt('confirm', () => confirm('must not show'));
        attempt('prompt', () => prompt('must not show'));
        attempt('topNavigation', () => { top.location = 'https://example.invalid/top'; return 'allowed'; });
        fetch('https://example.invalid/fetch').then(() => result.fetch='loaded', () => result.fetch='blocked');
        fetch('file:///etc/passwd').then(r => r.text()).then(() => result.file='read', () => result.file='blocked');
        const image = new Image(); image.onload=() => result.image='loaded'; image.onerror=() => result.image='blocked';
        image.src='https://example.invalid/image.png'; document.body.append(image);
        const script = document.createElement('script'); script.src='https://example.invalid/script.js'; document.body.append(script);
        const nested = document.createElement('iframe');
        nested.srcdoc='<script>parent.nestedExecuted=true;<\\/script>';
        document.body.append(nested);
        attempt('nestedRTC', () => typeof nested.contentWindow.RTCPeerConnection);
        const blank = document.createElement('iframe'); document.body.append(blank);
        attempt('blankRTC', () => typeof blank.contentWindow.RTCPeerConnection);
        attempt('prototypeRTC', () => typeof Object.getPrototypeOf(window).RTCPeerConnection);
        attempt('filePicker', () => typeof HTMLInputElement.prototype.showPicker);
        const form = document.createElement('form'); form.action='https://example.invalid/form'; document.body.append(form); form.submit();
        setInterval(() => {
          result.origin = origin;
          result.nested = String(window.nestedExecuted === true);
          result.cspConnect = String(violations.has('connect-src'));
          result.cspImage = String(violations.has('img-src'));
          result.cspScript = String(violations.has('script-src-elem') || violations.has('script-src'));
          result.childURL = location.href;
          parent.postMessage({testReport:result}, '*');
        }, 100);
        </script><p>Still here</p>
        """))
        let window = try await attach(renderer)
        defer { renderer.stop(); detach(window) }
        try await ready(renderer)
        let web = try #require(renderer.webView)
        let report = try await childReport(web)
        #expect(report["parent"] == "SecurityError")
        #expect(report["parentBridge"] == "SecurityError")
        #expect(report["bridge"] == "undefined")
        #expect(report["cookie"] == "SecurityError" || report["cookie"] == "")
        #expect(report["storage"] == "SecurityError")
        #expect(report["origin"] == "null")
        #expect(report["rtc"] == "undefined")
        #expect(report["worker"] == "undefined")
        #expect(report["camera"] == "undefined")
        #expect(report["popup"] == "true")
        #expect(report["alert"] == "returned")
        #expect(report["confirm"] == "false")
        #expect(report["prompt"] == "null")
        #expect(report["topNavigation"] == "SecurityError")
        #expect(report["fetch"] == "blocked")
        #expect(report["file"] == "blocked")
        #expect(report["image"] == "blocked")
        #expect(report["nested"] == "false")
        #expect(report["nestedRTC"] == "undefined" || report["nestedRTC"] == "SecurityError")
        #expect(report["blankRTC"] == "undefined" || report["blankRTC"] == "SecurityError")
        #expect(report["prototypeRTC"] == "undefined")
        #expect(report["filePicker"] == "undefined")
        #expect(report["cspConnect"] == "true")
        #expect(report["cspImage"] == "true")
        #expect(report["cspScript"] == "true")
        #expect(report["childURL"] == "about:srcdoc")
        #expect(try await evaluate(web, "location.href") == "about:blank")
        #expect(try await evaluate(web, "typeof window.webkit") == "undefined")
    }

    private func childReport(_ web: WKWebView) async throws -> [String: String] {
        _ = try await evaluate(web, """
        window.testReport = null;
        window.addEventListener('message', e => {
          if (e.source === document.querySelector('iframe').contentWindow && e.data.testReport)
            window.testReport = e.data.testReport;
        });
        """)
        for _ in 0..<80 {
            let json = try await evaluate(web, "JSON.stringify(window.testReport)")
            if let report = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [String: String] {
                return report
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("The sandbox fixture did not report its observed browser behavior")
        return [:]
    }

    private func makeRenderer() -> RichContentRenderer {
        #if RICH_CONTENT_STANDALONE
        RichContentRenderer(bundle: .module)
        #else
        RichContentRenderer()
        #endif
    }

    private func block(_ language: String, _ source: String) -> ReplyContent.Block {
        ReplyContent(assistantText: "```\(language)\n\(source)\n```").blocks[0]
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(21)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(condition(), "Renderer did not reach the expected observable state")
    }

    private func ready(_ renderer: RichContentRenderer) async throws {
        try await wait { renderer.state == .ready || renderer.webView == nil }
        try #require(renderer.state == .ready, "A failed WebKit startup must not count as a rendering pass")
    }

    private func contentFailure(_ renderer: RichContentRenderer) async throws {
        try await wait { if case .failed = renderer.state { true } else { false } }
        try #require(renderer.state == .failed("This content could not be rendered. Source is still available."),
                     "An engine rejection must be distinguished from a WebKit startup timeout")
    }

    private final class ExecutionProbe: NSObject, WKScriptMessageHandler {
        var started: ContinuousClock.Instant?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.frameInfo.isMainFrame { started = .now }
        }
    }

    private func executionProbe(_ renderer: RichContentRenderer) throws -> ExecutionProbe {
        let probe = ExecutionProbe()
        let controller = try #require(renderer.webView).configuration.userContentController
        let world = WKContentWorld.world(name: "Botto.Tests.Execution")
        controller.add(probe, contentWorld: world, name: "started")
        controller.addUserScript(WKUserScript(source: "window.webkit.messageHandlers.started.postMessage('started')",
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        return probe
    }

    private func evaluate(_ web: WKWebView, _ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingEvaluation(continuation)
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                pending.finish(.failure(ProbeFailure.javaScriptTimedOut))
            }
            web.evaluateJavaScript(script) { value, error in
                timeout.cancel()
                if let error { pending.finish(.failure(error)) }
                else { pending.finish(.success(String(describing: value ?? "undefined"))) }
            }
        }
    }

    private enum ProbeFailure: Error { case javaScriptTimedOut }

    /// Test probes must also be bounded when WebKit or the simulator is stuck.
    private final class PendingEvaluation {
        private var continuation: CheckedContinuation<String, any Error>?
        init(_ continuation: CheckedContinuation<String, any Error>) { self.continuation = continuation }
        func finish(_ result: Result<String, any Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    #if RICH_CONTENT_STANDALONE
    private func attach(_ renderer: RichContentRenderer, size: CGSize? = nil) async throws -> NSWindow {
        _ = NSApplication.shared
        let bounds = CGRect(origin: .zero, size: size ?? CGSize(width: 420, height: 480))
        let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: bounds)
        let web = try #require(renderer.webView)
        web.frame = container.bounds
        web.autoresizingMask = size == nil ? [.width, .height] : []
        container.addSubview(web)
        window.contentView = container
        window.orderFront(nil)
        if let size { recordMountedGeometry(web, expected: size) }
        return window
    }
    private func detach(_ window: NSWindow) { window.orderOut(nil); window.contentView = nil }
    #else
    private func attach(_ renderer: RichContentRenderer, size: CGSize? = nil) async throws -> UIWindow {
        // Swift Testing may start before the host scene has installed its first
        // window. Wait for that window before presenting this fixture.
        try await wait {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains {
                $0.activationState == .foregroundActive && $0.windows.contains { $0.isKeyWindow && !$0.isHidden }
            }
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        let web = try #require(renderer.webView)
        controller.view.frame = window.bounds
        if let size {
            // Resolve the available native area without attaching WebKit yet.
            // A 420-point logical viewport must also fit a 402-point phone.
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            let available = controller.view.bounds.inset(by: controller.view.safeAreaInsets)
            let scale = min(1, available.width / size.width, available.height / size.height)
            let container = UIView(frame: CGRect(origin: .zero, size: size))
            container.autoresizingMask = []
            container.transform = CGAffineTransform(scaleX: scale, y: scale)
            container.center = CGPoint(x: available.minX + size.width * scale / 2,
                                       y: available.minY + size.height * scale / 2)
            web.frame = container.bounds
            web.autoresizingMask = []
            container.addSubview(web)
            controller.view.addSubview(container)
            controller.view.layoutIfNeeded()
            recordMountedGeometry(web, expected: size)
        } else {
            web.frame = controller.view.bounds
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.addSubview(web)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }
        return window
    }
    private func detach(_ window: UIWindow) { window.isHidden = true; window.rootViewController = nil }
    #endif
}
