import Foundation

nonisolated public enum HermesDetailPayload {
    nonisolated public enum Format: Equatable, Sendable { case plain, markdown, json }

    nonisolated public struct Section: Equatable, Sendable {
        public let title: String?
        public let text: String
        public let format: Format
    }

    public static func sections(_ text: String) -> [Section] {
        guard text.utf8.count <= 256 * 1024,
              let json = validatedJSON(text) else {
            return [Section(title: nil, text: text, format: .plain)]
        }
        return render(json, title: nil, depth: 0)
    }

    private static func render(_ json: String, title: String?, depth: Int) -> [Section] {
        guard depth < 4, json.first == "{" else {
            return [Section(title: title, text: pretty(json), format: .json)]
        }
        var sections: [Section] = []
        var remaining: [String] = []
        for field in split(String(json.dropFirst().dropLast()), separator: 44) {
            let pair = split(field, separator: 58)
            guard pair.count == 2,
                  let key = decodeString(pair[0]),
                  ["content", "text", "output", "result"].contains(key) else {
                remaining.append(field)
                continue
            }
            let value = pair[1]
            let heading = title.map { "\($0) · \(key.capitalized)" } ?? key.capitalized
            if let decoded = decodeString(value) {
                if let nested = validatedJSON(decoded) {
                    sections += render(nested, title: heading, depth: depth + 1)
                } else {
                    sections.append(Section(title: heading, text: decoded, format: .markdown))
                }
            } else if value.first == "{" {
                sections += render(value, title: heading, depth: depth + 1)
            } else if key == "content", value.first == "[", value != "[]" {
                let blocks = split(String(value.dropFirst().dropLast()), separator: 44)
                for (index, block) in blocks.enumerated() {
                    sections += render(block, title: "\(heading) · \(index + 1)", depth: depth + 1)
                }
            } else {
                remaining.append(field)
            }
        }
        if !remaining.isEmpty || sections.isEmpty {
            let residual = "{" + remaining.joined(separator: ",") + "}"
            sections.append(Section(title: sections.isEmpty ? title : "Details", text: pretty(residual), format: .json))
        }
        return sections
    }

    // Validate before formatting, but retain lexical tokens so numbers and repeated keys survive.
    private static func validatedJSON(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.first == "{" || text.first == "[" else { return nil }
        var depth = 0
        var quoted = false
        var escaped = false
        var previous: UInt8?
        for byte in text.utf8 {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 32 else { return nil }
            } else if byte == 125 || byte == 93 {
                // Foundation accepts trailing commas; details only format complete strict JSON.
                guard previous != 44 else { return nil }
                depth -= 1
            }
            if ![9, 10, 13, 32].contains(byte) { previous = byte }
        }
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else { return nil }
        return text
    }

    private static func decodeString(_ json: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(json.utf8))
    }

    private static func split(_ json: String, separator: UInt8) -> [String] {
        let bytes = Array(json.utf8)
        var parts: [String] = []
        var start = 0
        var depth = 0
        var quoted = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1 }
            else if byte == 125 || byte == 93 { depth -= 1 }
            else if byte == separator && depth == 0 {
                parts.append(String(decoding: bytes[start..<index], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                start = index + 1
            }
        }
        let last = String(decoding: bytes[start...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    private static func pretty(_ json: String) -> String {
        var output: [UInt8] = []
        var depth = 0
        var quoted = false
        var escaped = false
        var previous: UInt8?
        func newline() {
            output.append(10)
            output += repeatElement(32, count: depth * 2)
        }
        for byte in json.utf8 {
            if quoted {
                output.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if [9, 10, 13, 32].contains(byte) { continue }
            switch byte {
            case 34:
                if previous == 123 || previous == 91 { newline() }
                quoted = true
                output.append(byte)
            case 123, 91:
                if previous == 123 || previous == 91 { newline() }
                output.append(byte)
                depth += 1
            case 125, 93:
                depth -= 1
                if previous != 123 && previous != 91 { newline() }
                output.append(byte)
            case 44: output.append(byte); newline()
            case 58: output += [byte, 32]
            default:
                if previous == 123 || previous == 91 { newline() }
                output.append(byte)
            }
            previous = byte
        }
        return String(decoding: output, as: UTF8.self)
    }
}
