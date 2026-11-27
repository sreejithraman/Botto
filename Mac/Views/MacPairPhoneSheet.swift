import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import BottoCore

/// The routes a phone can reach this Mac by, in the order phones try them after the one that last
/// worked: LAN is direct and fastest at home, Tailscale reaches the Mac from anywhere on the tailnet,
/// and an HTTPS tunnel relays through another service, so it comes last. The first available route
/// is the primary one, which older phone builds pair with.
struct MacPairingRoutes: Equatable {
    struct Route: Identifiable, Equatable {
        let name: String
        /// Where the route goes when it is in the code.
        let origin: URL?
        /// Why the route isn't in the code.
        let unavailable: String?
        var id: String { name }
    }

    static let tunnelName = "HTTPS tunnel"
    let routes: [Route]

    init(lan: URL?, tailscale: URL?, tunnel: String) {
        func local(_ origin: URL?) -> URL? {
            origin.flatMap { PairingRoutes.allowed([$0], allowingHTTP: true).first }
        }
        let tunnel = tunnel.trimmingCharacters(in: .whitespacesAndNewlines)
        let secure = try? PairingAddress.parse(tunnel)
        routes = [
            Route(name: "LAN", origin: local(lan),
                  unavailable: lan == nil ? "No active LAN IPv4 address was found." : "Not a local network address."),
            Route(name: "Tailscale", origin: local(tailscale),
                  unavailable: "Tailscale is off, or this Mac has no Tailscale address."),
            Route(name: Self.tunnelName, origin: secure,
                  unavailable: tunnel.isEmpty ? "No tunnel saved." : "Enter the tunnel’s HTTPS origin, such as https://botto.example.com."),
        ]
    }

    var inCode: [URL] { routes.compactMap(\.origin) }

    /// The pairing link for every available route. T3 prints it for its loopback origin.
    func pairingURL(from rawPairingURL: String) -> String? {
        guard let primary = inCode.first,
              let link = T3RouteFormatter.pairingURL(from: rawPairingURL, routeOrigin: primary) else { return nil }
        return PairingRoutes.link(link, adding: Array(inCode.dropFirst()))
    }
}

struct MacPairPhoneSheet: View {
    let server: LocalT3ServerManager
    @AppStorage("t3CustomTunnelOrigin") private var customAddress = ""
    @State private var rawLink: String?
    @State private var generationTask: Task<Void, Never>?
    @State private var error: String?

    private var routes: MacPairingRoutes {
        MacPairingRoutes(lan: server.lanOrigin, tailscale: server.tailscaleOrigin, tunnel: customAddress)
    }

    var body: some View {
        MacPairPhoneContent(
            routes: routes, tunnel: $customAddress,
            pairingURL: server.state == .running ? rawLink.flatMap(routes.pairingURL) : nil,
            status: pairingStatus, isGenerating: generationTask != nil && rawLink == nil, error: error,
            canRefresh: server.state == .running && generationTask == nil, refresh: generate
        )
        .task { await server.refreshRoutes() }
        .onChange(of: server.state, initial: true) { _, state in
            if state == .running {
                generate()
            } else {
                generationTask?.cancel()
                rawLink = nil
            }
        }
        .task(id: rawLink) {
            guard let rawLink else { return }
            try? await Task.sleep(for: .seconds(300))
            if !Task.isCancelled, self.rawLink == rawLink { self.rawLink = nil }
        }
        .onDisappear { generationTask?.cancel() }
    }

    private var pairingStatus: String {
        if server.state != .running { return "Start the local server to pair a phone." }
        if generationTask != nil && rawLink == nil { return "Generating a pairing link…" }
        if routes.inCode.isEmpty { return "No route reaches this Mac yet. Join a network, turn on Tailscale, or save a tunnel." }
        return "Generate a fresh link to pair your phone."
    }

    private func generate() {
        guard generationTask == nil else { return }
        error = nil
        rawLink = nil
        generationTask = Task {
            defer { generationTask = nil }
            do {
                let link = try await server.mintPairingLink()
                if !Task.isCancelled { rawLink = link }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

/// What the pair sheet shows, apart from the local server that feeds it.
struct MacPairPhoneContent: View {
    let routes: MacPairingRoutes
    @Binding var tunnel: String
    let pairingURL: String?
    let status: String
    let isGenerating: Bool
    let error: String?
    let canRefresh: Bool
    let refresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(MacTheme.action)
                    .frame(width: 46, height: 46)
                    .background(MacTheme.selection, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take Botto with you")
                        .font(MacTheme.rounded(.title2, weight: .bold))
                    Text("Pair your phone once. It reaches this Mac over LAN at home, and over Tailscale or your own tunnel away. No T3 account required.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            routeList

            if let pairingURL, let qr = PairingQRCode.image(for: pairingURL) {
                Image(qr, scale: 1, orientation: .up, label: Text("Phone pairing QR code"))
                    .interpolation(.none)
                    .padding(10)
                    .background(.white, in: .rect(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    .frame(maxWidth: .infinity, minHeight: 238)
                    .privacySensitive()
                Text(pairingURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MacTheme.surface, in: .rect(cornerRadius: 10))
                    .privacySensitive()
                    .accessibilityLabel("Pairing URL: \(pairingURL)")
                Label("Scan in Botto on your phone. The link expires after five minutes and works once.",
                      systemImage: "camera.viewfinder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if routes.inCode.contains(where: { $0.scheme == "http" }) {
                    Text("For LAN and Tailscale, turn on Allow an HTTP connection in Botto on your phone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 9) {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "qrcode")
                            .font(.system(size: 34))
                            .foregroundStyle(MacTheme.action.opacity(0.7))
                    }
                    Text(status)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 238)
                .background(MacTheme.surface, in: .rect(cornerRadius: 20))
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(MacTheme.error)
                    .font(.callout)
            }

            HStack {
                Button("Fresh Link", systemImage: "arrow.clockwise", action: refresh)
                    .buttonStyle(MacPillButtonStyle(prominent: false))
                    .disabled(!canRefresh)
                if let pairingURL {
                    Button(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(pairingURL, forType: .string)
                    }
                    .buttonStyle(MacPillButtonStyle(prominent: false))
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(MacPillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(MacTheme.paper)
        .tint(MacTheme.action)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: pairingURL) { _, _ in copied = false }
    }

    /// A route claims to be in the code only while a code is on screen, not while one is being made
    /// or after it expired.
    static func mark(for route: MacPairingRoutes.Route, showingCode: Bool) -> String {
        route.origin == nil ? "Not available" : showingCode ? "In the code" : "Available"
    }

    private var routeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(routes.routes) { route in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: route.origin == nil ? "minus.circle" : "checkmark.circle.fill")
                        .foregroundStyle(route.origin == nil ? Color.secondary : MacTheme.action)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.name).font(.callout.weight(.semibold))
                        Text(route.origin?.absoluteString ?? route.unavailable ?? "")
                            .font(route.origin == nil ? .callout : .system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(Self.mark(for: route, showingCode: pairingURL != nil))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(route.origin == nil ? Color.secondary : MacTheme.action)
                }
                .accessibilityElement(children: .combine)
                if route.name == MacPairingRoutes.tunnelName {
                    TextField("Tunnel origin", text: $tunnel, prompt: Text("https://botto.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 26)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.surface, in: .rect(cornerRadius: 14))
    }
}

private enum PairingQRCode {
    private static let context = CIContext()

    static func image(for url: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        // Integer scaling plus a white quiet zone keeps the modules scannable in either appearance.
        let quietZone = code.extent.insetBy(dx: -4, dy: -4)
        let padded = code.composited(over: CIImage(color: .white).cropped(to: quietZone))
        let scale = max(1, floor(218 / quietZone.width))
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaled = padded.samplingNearest().transformed(by: transform)
        return context.createCGImage(scaled, from: quietZone.applying(transform))
    }
}
