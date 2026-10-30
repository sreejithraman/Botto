import Foundation

/// Validates the HTTP request received by the native PKCE loopback broker.
/// The listener owns single-use delivery; this value performs no I/O.
public struct NativeSignInCallback: Sendable {
    public enum Failure: Error { case invalidRequest }
    public static let maximumRequestBytes = 16_384

    public static func code(in request: Data, expectedState: String, port: UInt16) throws -> String {
        guard request.count <= maximumRequestBytes,
              request.allSatisfy({ (32...126).contains($0) || $0 == 13 || $0 == 10 }),
              let text = String(data: request, encoding: .ascii), text.hasSuffix("\r\n\r\n")
        else { throw Failure.invalidRequest }
        let lines = text.components(separatedBy: "\r\n")
        let line = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard line.count == 3, line[0] == "GET", line[2] == "HTTP/1.1",
              line[1].hasPrefix("/callback?"), !line[1].contains("#"), !line[1].contains("\\"),
              line[1].utf8.count <= 4_096, !expectedState.isEmpty
        else { throw Failure.invalidRequest }
        var hosts: [String] = []
        for header in lines.dropFirst().dropLast(2) {
            let parts = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty,
                  parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || $0 == 45 })
            else { throw Failure.invalidRequest }
            if parts[0].lowercased() == "host" { hosts.append(parts[1].trimmingCharacters(in: .whitespaces)) }
            if ["content-length", "transfer-encoding"].contains(parts[0].lowercased()) {
                throw Failure.invalidRequest
            }
        }
        guard hosts == ["127.0.0.1:\(port)"] else { throw Failure.invalidRequest }
        let fields = line[1].dropFirst("/callback?".count).split(separator: "&", omittingEmptySubsequences: false)
        guard fields.count == 2 else { throw Failure.invalidRequest }
        var values: [String: String] = [:]
        for field in fields {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, ["code", "state"].contains(pair[0]), values[String(pair[0])] == nil,
                  let value = pair[1].removingPercentEncoding, !value.isEmpty, value.utf8.count <= 1_024,
                  value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || [45, 46, 95, 126].contains($0) })
            else { throw Failure.invalidRequest }
            values[String(pair[0])] = value
        }
        guard values["state"] == expectedState, let code = values["code"] else { throw Failure.invalidRequest }
        return code
    }
}
