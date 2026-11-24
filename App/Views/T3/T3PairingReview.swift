import Foundation
import BottoCore

/// Where a pairing link points, checked before anything is sent to it.
struct T3PairingReview: Equatable {
    let origin: URL
    let credential: String

    /// Reads a pairing link, or a server address with its code typed separately. Plain HTTP is refused
    /// outright unless the address is on a local network or Tailscale.
    init(_ input: String, code: String = "") throws {
        let pairing = try T3PairingExchange.parse(input, credential: Self.isPairingLink(input) ? nil : code)
        origin = try PairingAddress.parse(pairing.origin.absoluteString, allowInsecureHTTP: true)
        credential = pairing.credential
    }

    var isEncrypted: Bool { origin.scheme == "https" }

    /// The address to pair with. A local HTTP address needs the person to have allowed it.
    func destination(allowingHTTP: Bool) throws -> URL {
        try PairingAddress.parse(origin.absoluteString, allowInsecureHTTP: allowingHTTP)
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

/// Which connection a fresh install, a saved setup, or an opened link leads to.
enum ConnectionBackend: Hashable {
    case t3, hermes

    static func initial(input: String, saved: ConnectionConfiguration?, isDemo: Bool) -> ConnectionBackend {
        if let named = named(by: input) { return named }
        // A saved Hermes setup keeps its own details page. Everyone else pairs with a Mac.
        return saved != nil && saved?.t3 == nil && !isDemo ? .hermes : .t3
    }

    /// Nil when the text alone doesn't say, such as a bare address.
    static func named(by input: String) -> ConnectionBackend? {
        if T3PairingReview.isPairingLink(input) { return .t3 }
        guard let scheme = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() else { return nil }
        return ["hermes", "botto"].contains(scheme) ? .hermes : nil
    }
}
