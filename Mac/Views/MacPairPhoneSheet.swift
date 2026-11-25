import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct MacPairPhoneSheet: View {
    private enum Route: String, CaseIterable {
        case lan = "LAN"
        case tailscale = "Tailscale"
        case custom = "Custom tunnel URL"
    }

    let server: LocalT3ServerManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("t3CustomTunnelOrigin") private var customAddress = ""
    @State private var route: Route = .lan
    @State private var rawLink: String?
    @State private var generationTask: Task<Void, Never>?
    @State private var error: String?
    @State private var copied = false

    private var routeOrigin: URL? {
        switch route {
        case .lan: server.lanOrigin
        case .tailscale: server.tailscaleOrigin
        case .custom:
            URL(string: customAddress.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.scheme?.lowercased() == "https" ? $0 : nil
            }
        }
    }

    private var pairingURL: String? {
        guard server.state == .running, let rawLink, let routeOrigin else { return nil }
        return T3RouteFormatter.pairingURL(from: rawLink, routeOrigin: routeOrigin)
    }

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
                    Text("Pair your phone directly over LAN, Tailscale, or your own tunnel. No T3 account required.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Route", selection: $route) {
                ForEach(Route.allCases, id: \.self) { choice in Text(choice.rawValue).tag(choice) }
            }
            .pickerStyle(.segmented)

            if route == .custom {
                TextField("Tunnel origin", text: $customAddress, prompt: Text("https://botto.example.com"))
                    .textFieldStyle(.roundedBorder)
            }

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
                if routeOrigin?.scheme == "http" {
                    Text("For a trusted network, turn on Allow an HTTP connection in Botto on your phone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 9) {
                    if generationTask != nil && rawLink == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "qrcode")
                            .font(.system(size: 34))
                            .foregroundStyle(MacTheme.action.opacity(0.7))
                    }
                    Text(pairingStatus)
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
                Button("Fresh Link", systemImage: "arrow.clockwise", action: generate)
                    .buttonStyle(MacPillButtonStyle(prominent: false))
                    .disabled(server.state != .running || generationTask != nil)
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
        .task { await server.refreshRoutes() }
        .onChange(of: server.state, initial: true) { _, state in
            if state == .running {
                generate()
            } else {
                generationTask?.cancel()
                rawLink = nil
            }
        }
        .onChange(of: pairingURL) { _, _ in copied = false }
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
        switch route {
        case .lan where routeOrigin == nil: return "No active LAN IPv4 address was found."
        case .tailscale where routeOrigin == nil: return "No Tailscale IPv4 address was found."
        case .custom where pairingURL == nil && rawLink != nil: return "Enter the HTTPS origin of your tunnel."
        default: return "Generate a fresh link to pair your phone."
        }
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
