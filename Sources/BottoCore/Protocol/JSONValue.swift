// Adapted from Hermex BotProtocol.swift. MIT; see LICENSES/Hermex.txt.
import Foundation

/// A Sendable wire value with no actor-owned state. Projection and serialization
/// stay synchronous on the caller's executor; each operation owns its codec.
nonisolated indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { var v = fields ?? [:]; v[key] = newValue; self = .object(v) }
    }
    var text: String? { if case .string(let v) = self { return v }; return nil }
    var list: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var fields: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var flag: Bool? { if case .bool(let v) = self { return v }; return nil }
    var integer: Int? { if case .number(let v) = self { return Int(exactly: v) }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var date: Date? { number.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } }
    var nonempty: String? { text.flatMap { $0.isEmpty ? nil : $0 } }
    var data: Data { get throws { try JSONEncoder().encode(self) } }
    static func decode(_ data: Data) throws -> JSONValue {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ConversationServiceError.incompatible }
    }
}
