import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A QR carries only an address. Parsing never connects or changes a saved connection.
public struct PairingAddress: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case invalidAddress
        case tooLong
        case unsupportedPath
        case insecureHTTP

        public var errorDescription: String? {
            switch self {
            case .invalidAddress: "Use an HTTPS server origin or a supported Hermes connection code."
            case .tooLong: "This connection code is too long."
            case .unsupportedPath: "Enter the server origin without a path."
            case .insecureHTTP: "HTTP requires the explicit trusted local network option."
            }
        }
    }

    public static func parse(_ input: String, allowInsecureHTTP: Bool = false) throws -> URL {
        try validateText(input)
        guard let parts = URLComponents(string: input), let scheme = parts.scheme?.lowercased() else {
            throw Failure.invalidAddress
        }
        if scheme == "hermes" || scheme == "botto" {
            let authority = input.dropFirst(scheme.count + 3).prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
            guard input.prefix(scheme.count + 3).lowercased() == scheme + "://",
                  authority == (scheme == "hermes" ? "connect" : "hermes"),
                  parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
                  (scheme == "hermes" && parts.percentEncodedHost == "connect" && parts.percentEncodedPath.isEmpty)
                    || (scheme == "botto" && parts.percentEncodedHost == "hermes" && parts.percentEncodedPath == "/connect"),
                  let query = parts.percentEncodedQuery,
                  query.hasPrefix("url="), !query.contains("&"),
                  let destination = String(query.dropFirst(4)).removingPercentEncoding, !destination.isEmpty
            else { throw Failure.invalidAddress }
            // Decode exactly once. The nested value must itself be an HTTP(S) origin.
            return try origin(destination, allowInsecureHTTP: allowInsecureHTTP)
        }
        return try origin(input, allowInsecureHTTP: allowInsecureHTTP)
    }

    private static func origin(_ input: String, allowInsecureHTTP: Bool) throws -> URL {
        try validateText(input)
        guard var parts = URLComponents(string: input),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) != false,
              parts.percentEncodedHost?.contains("%") == false,
              let url = parts.url, url.host != nil
        else { throw Failure.invalidAddress }
        // Do not normalize away dot segments, credentials, or an encoded path.
        guard parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/" else {
            throw Failure.unsupportedPath
        }
        // Validate numeric hosts separately: URLComponents accepts invalid IP literals.
        // DNS labels are deliberately ASCII;
        // international hostnames can be entered using their IDNA ASCII spelling.
        if host.hasPrefix("[") {
            var address = in6_addr()
            guard host.hasSuffix("]"), String(host.dropFirst().dropLast()).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1
            else { throw Failure.invalidAddress }
        } else {
            let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
            guard host.utf8.count <= 253, labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }) else { throw Failure.invalidAddress }
            if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
                guard labels.count == 4, labels.allSatisfy({ label in
                    (label.count == 1 || label.first != "0") && Int(label).map { (0...255).contains($0) } == true
                }) else { throw Failure.invalidAddress }
            }
        }
        // Reject an empty or nondecimal explicit port, which URLComponents can erase.
        let authority = input.dropFirst(scheme.count + 3).prefix(while: { $0 != "/" })
        if let colon = authority.lastIndex(of: ":"), !authority.hasSuffix("]") {
            let port = authority[authority.index(after: colon)...]
            guard !port.isEmpty, port.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(port), (1...65535).contains(number)
            else { throw Failure.invalidAddress }
        }
        guard input.lowercased().hasPrefix(scheme + "://") else { throw Failure.invalidAddress }
        if scheme == "http", !(allowInsecureHTTP && isLocalHost(host)) { throw Failure.insecureHTTP }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = ""
        guard let normalized = parts.url else { throw Failure.invalidAddress }
        return normalized
    }

    private static func validateText(_ input: String) throws {
        guard input.utf8.count <= 4_096 else { throw Failure.tooLong }
        guard !input.isEmpty, !input.contains("\\"),
              !input.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidAddress }
        let bytes = Array(input.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else {
                    throw Failure.invalidAddress
                }
                index += 3
            } else { index += 1 }
        }
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func isLocalHost(_ input: String) -> Bool {
        let host = input.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host.hasPrefix("[") {
            var address = in6_addr()
            guard String(host.dropFirst().dropLast()).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            return (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
                || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        let components = host.split(separator: ".")
        let octets = components.compactMap { Int($0) }
        guard components.count == 4, octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
            || (octets[0] == 100 && (64...127).contains(octets[1]))
    }
}
