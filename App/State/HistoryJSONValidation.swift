import Foundation

/// Foundation folds canonically equivalent object keys before Decodable sees them.
/// Reject ambiguity before decoding so migration never silently drops source values.
enum HistoryJSONValidation {
    static func check(_ data: Data) throws {
        let bytes = Array(data)
        enum Container { case object(Set<String>), array }
        var containers: [Container] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123: containers.append(.object([])); index += 1 // {
            case 91: containers.append(.array); index += 1 // [
            case 125, 93:
                guard !containers.isEmpty else { throw HistoryFailure.corrupt }
                containers.removeLast(); index += 1
            case 34:
                let start = index
                index += 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { index += 1; closed = true; break }
                    index += 1
                }
                guard closed else { throw HistoryFailure.corrupt }
                var next = index
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    guard let last = containers.indices.last, case .object(var keys) = containers[last] else {
                        throw HistoryFailure.corrupt
                    }
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                    guard keys.insert(key).inserted else { throw HistoryFailure.corrupt }
                    containers[last] = .object(keys)
                }
            default: index += 1
            }
        }
        guard containers.isEmpty else { throw HistoryFailure.corrupt }
    }
}
