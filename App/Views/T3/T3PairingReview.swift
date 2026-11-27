import Foundation
import BottoCore

/// Where a pairing link points, checked before anything is sent to it.
struct T3PairingReview: Equatable {
    /// The link's primary route.
    let origin: URL
    let credential: String
    /// The routes shown for review, primary first. A further route that fails the pairing address rule
    /// is dropped here, so it is never shown or used.
    let routes: [URL]

    /// Reads a pairing link, or a server address with its code typed separately. Plain HTTP is refused
    /// outright unless the address is on a local network or Tailscale.
    init(_ input: String, code: String = "") throws {
        let pairing = try T3PairingExchange.parse(input, credential: Self.isPairingLink(input) ? nil : code)
        origin = try PairingAddress.parse(pairing.origin.absoluteString, allowInsecureHTTP: true)
        credential = pairing.credential
        routes = PairingRoutes.allowed([origin] + pairing.routes, allowingHTTP: true)
    }

    var isEncrypted: Bool { routes.allSatisfy { $0.scheme == "https" } }
    var hasSecureRoute: Bool { routes.contains { $0.scheme == "https" } }

    /// The routes to pair with, in order. HTTP routes join only when the person allowed them,
    /// and the consent covers exactly the HTTP routes shown.
    func destinations(allowingHTTP: Bool) throws -> [URL] {
        let routes = PairingRoutes.allowed(routes, allowingHTTP: allowingHTTP)
        guard !routes.isEmpty else { throw PairingAddress.Failure.insecureHTTP }
        return routes
    }

    static func isPairingLink(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return URLComponents(string: text)?.scheme?.lowercased() == "t3code" || (try? T3PairingExchange.parse(text)) != nil
    }

    /// What went wrong, for someone holding a phone next to their Mac.
    static func message(for error: any Error) -> String {
        switch error {
        case PairingAddress.Failure.insecureHTTP:
            String(localized: "That address isn’t protected, and it isn’t on your own network. Use your Mac’s LAN or Tailscale link, or an https address.")
        case T3PairingError.missingCredential:
            String(localized: "That link is missing its pairing code. Copy a fresh link from Botto on your Mac.")
        case T3PairingError.invalidOrigin, is PairingAddress.Failure:
            String(localized: "That doesn’t look like a pairing link from Botto on your Mac.")
        case T3PairingError.httpStatus(400), T3PairingError.httpStatus(401), T3PairingError.httpStatus(403):
            String(localized: "That link has expired or was already used. Get a fresh one on your Mac.")
        case T3PairingError.incompatibleProtocol:
            String(localized: "Botto on your Mac needs an update before this phone can pair.")
        case let error as URLError where error.code != .cancelled:
            String(localized: "Couldn’t reach your Mac. Check that Botto is awake there and both are on the same network.")
        default:
            error.localizedDescription
        }
    }
}
