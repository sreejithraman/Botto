import Foundation
import BottoCore

/// Constructs only the trusted outer document. Untrusted bytes enter srcdoc as
/// base64 data in an isolated-world script, never as markup in the host document.
enum RichContentDocument {
    static let hostHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; frame-src about:; connect-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'">
    <meta http-equiv="x-dns-prefetch-control" content="off">
    <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}iframe{display:block;width:100%;height:100%;border:0}</style>
    </head><body></body></html>
    """

    static func bootstrap(block: ReplyContent.Block, generation: String,
                          dark: Bool, reduceMotion: Bool, bundle: Bundle, diagramHeight: CGFloat? = nil) throws -> String {
        guard let format = block.previewFormat, block.isComplete,
              block.source.utf8.count <= ReplyContent.previewByteLimit(for: format) else {
            throw Failure.sourceOnly
        }
        var content: String
        switch format {
        case .html:
            content = block.source
        case .svg:
            content = """
            <div id="diagram"></div><script>
            (() => {
              const svg = new DOMParser().parseFromString(\(decode(block.source)), 'image/svg+xml');
              if (svg.querySelector('parsererror') || svg.documentElement.localName !== 'svg' ||
                  svg.documentElement.namespaceURI !== 'http://www.w3.org/2000/svg') {
                window.bottoPreviewFailed = true; return;
              }
              const element = document.importNode(svg.documentElement, true);
              document.getElementById('diagram').append(element);
              // A declared SVG viewport without a viewBox clips when CSS alone
              // shrinks its height. Preserve its original coordinate space.
              if (\(diagramHeight == nil ? "false" : "true") && !element.hasAttribute('viewBox')) {
                const width = element.width.baseVal.value, height = element.height.baseVal.value;
                if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
                  element.setAttribute('viewBox', `0 0 ${width} ${height}`);
                }
              }
            })();
            </script>
            """
        case .mermaid:
            let engine = try resource("pele-1.9.0", bundle: bundle)
            // The official IIFE is trusted bundled code. Escape only HTML's script
            // terminator in that code; this is not a sanitizer for untrusted HTML.
            let inlineEngine = engine.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
            content = """
            <style>#diagram{--pele-bg:\(dark ? "#1f1e1c" : "#fbf9f4");--pele-fg:\(dark ? "#f5f1eb" : "#25231f");--pele-line:var(--pele-fg);--pele-muted:\(dark ? "#b5afa5" : "#68645d");--pele-surface:\(dark ? "#34312c" : "#eeeae2");--pele-surface-alt:\(dark ? "#464139" : "#e2dcd0");--pele-border:\(dark ? "#999185" : "#8c8477");--pele-accent:\(dark ? "#ff8c70" : "#b83b2b")}</style>
            <div id="diagram"></div><script>\(inlineEngine)</script><script>
            window.bottoPreviewPending = true;
            (() => {
              try {
                // These top-level host options are separate from Mermaid config.
                // maxEdges bounds flowchart/agentflow only. outputLimit is checked
                // after rendering; native deadlines still bound a stuck renderer.
                const result = pele.render(\(decode(block.source)), {
                  links:false, images:false, limit:16384, maxEdges:100, outputLimit:524288,
                  idPrefix:'botto-\(generation)', responsive:true,
                  maxWidth:Math.max(120, document.documentElement.clientWidth-24),
                  fontFamily:'-apple-system, sans-serif', fontFamilyMono:'monospace'
                });
                document.getElementById('diagram').innerHTML = result.svg;
              } catch (_) { window.bottoPreviewFailed = true; }
              window.bottoPreviewPending = false;
            })();
            </script>
            """
        }
        let background = dark ? "#1f1e1c" : "#fbf9f4"
        let foreground = dark ? "#f5f1eb" : "#25231f"
        let motion = reduceMotion
            ? "*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}"
            : ""
        // Only frozen diagrams fit all of their SVG into the capture. HTML and
        // live renderer callers retain their ordinary scrollable child document.
        let diagramFit = diagramHeight != nil && format != .html
            ? "#diagram>svg{width:auto!important;height:auto!important;max-width:100%!important;max-height:\(max(1, (diagramHeight ?? 480) - 24))px!important}"
            : ""
        let child = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; frame-src 'none'; child-src 'none'; connect-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <style>:root{color-scheme:\(dark ? "dark" : "light")}html{background:\(background);color:\(foreground);font:16px -apple-system,sans-serif}body{margin:12px;overflow-wrap:anywhere}img,svg{max-width:100%;height:auto}button,input,select,textarea{font:inherit}button{min-height:44px}pre{white-space:pre-wrap}\(motion)\(diagramFit)</style>
        </head><body>\(content)<script>\(try resource("child", bundle: bundle))</script></body></html>
        """
        return try resource("host", bundle: bundle)
            .replacingOccurrences(of: "__BOTTO_DOCUMENT__", with: decode(child))
            .replacingOccurrences(of: "__BOTTO_GENERATION__", with: "'\(generation)'")
    }

    static func resource(_ name: String, bundle: Bundle) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "RichContent")
                ?? bundle.url(forResource: name, withExtension: "js") else { throw Failure.missingResources }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func decode(_ value: String) -> String {
        "new TextDecoder().decode(Uint8Array.from(atob('\(Data(value.utf8).base64EncodedString())'),c=>c.charCodeAt(0)))"
    }

    enum Failure: Error { case sourceOnly, missingResources }
}
