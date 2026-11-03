import Foundation

/// Bounded Open Bot Avatar v1 data for transport and storage. The reference
/// engine validates path semantics and eye containment before use.
nonisolated public struct BotAvatarGeometry: Equatable, Sendable, Codable {
    public struct Eyes: Equatable, Sendable, Codable {
        public let x: Double
        public let y: Double
        public let spacing: Double
        public let scale: Double
    }

    public enum DefinitionError: Error, LocalizedError, Sendable {
        case invalidDefinition, unsupportedVersion, tooComplex
        public var errorDescription: String? {
            switch self {
            case .invalidDefinition: "The character definition isn’t valid Open Bot Avatar data. Try generating it again."
            case .unsupportedVersion: "This character format isn’t supported. Generate a new character."
            case .tooComplex: "The character is too complex. Try a simpler description."
            }
        }
    }

    public static let maximumJSONBytes = 8192
    private static let recipePrefix = "botto-path:1:"

    public let id: String
    public let name: String
    public let eyes: Eyes
    public let bodyPath: String
    public let json: String
    private let definition: Definition
    private let encodedRecipe: String

    public init(json: String) throws {
        guard json.utf8.count <= Self.maximumJSONBytes else { throw DefinitionError.tooComplex }
        do { self = try JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
        catch let error as DefinitionError { throw error }
        catch { throw DefinitionError.invalidDefinition }
    }

    public init(from decoder: any Decoder) throws {
        let definition = try Definition(from: decoder)
        guard definition.version == 1 else { throw DefinitionError.unsupportedVersion }
        guard definition.body.path.utf8.count <= 6000 else { throw DefinitionError.tooComplex }
        guard [definition.eyes.x, definition.eyes.y, definition.eyes.spacing, definition.eyes.scale].allSatisfy(\.isFinite) else {
            throw DefinitionError.invalidDefinition
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(definition)
        guard bytes.count <= Self.maximumJSONBytes else { throw DefinitionError.tooComplex }
        self.id = definition.id
        self.name = definition.name
        self.eyes = definition.eyes
        self.bodyPath = definition.body.path
        self.json = String(decoding: bytes, as: UTF8.self)
        self.definition = definition
        self.encodedRecipe = Self.recipePrefix + bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public func encode(to encoder: any Encoder) throws { try definition.encode(to: encoder) }

    public var recipe: String { encodedRecipe }

    public static func fromRecipe(_ raw: String?) -> Self? {
        guard let raw, raw.hasPrefix(recipePrefix), raw.utf8.count <= 11_000 else { return nil }
        let payload = String(raw.dropFirst(recipePrefix.count))
        guard !payload.isEmpty, payload.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64), bytes.count <= maximumJSONBytes,
              let json = String(data: bytes, encoding: .utf8) else { return nil }
        return try? Self(json: json)
    }

    private struct Definition: Codable, Equatable, Sendable {
        let version: Int
        let id: String
        let name: String
        let body: Body
        let eyes: Eyes
        private enum CodingKeys: String, CodingKey { case version, id, name, body, eyes }
        init(from decoder: any Decoder) throws {
            try Self.requireKeys(decoder, ["version", "id", "name", "body", "eyes"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            body = try values.decode(Body.self, forKey: .body)
            let eyeDecoder = try values.superDecoder(forKey: .eyes)
            try Self.requireKeys(eyeDecoder, ["x", "y", "spacing", "scale"])
            eyes = try Eyes(from: eyeDecoder)
        }
        static func requireKeys(_ decoder: any Decoder, _ allowed: Set<String>) throws {
            let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
            guard Set(keys) == allowed else { throw DefinitionError.invalidDefinition }
        }
    }
    private struct Body: Codable, Equatable, Sendable {
        let path: String
        private enum CodingKeys: String, CodingKey { case path }
        init(from decoder: any Decoder) throws {
            try Definition.requireKeys(decoder, ["path"])
            path = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .path)
        }
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
