import Foundation

nonisolated public struct BotAvatarBounds: Codable, Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double
}

nonisolated public struct BotAvatarAffine: Codable, Equatable, Sendable {
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double
    public let tx: Double
    public let ty: Double

    public init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        a = try values.decode(Double.self); b = try values.decode(Double.self)
        c = try values.decode(Double.self); d = try values.decode(Double.self)
        tx = try values.decode(Double.self); ty = try values.decode(Double.self)
        guard values.isAtEnd, [a, b, c, d, tx, ty].allSatisfy(\.isFinite) else {
            throw DecodingError.dataCorruptedError(in: values, debugDescription: "Invalid avatar matrix")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        for value in [a, b, c, d, tx, ty] { try values.encode(value) }
    }
}

nonisolated public struct BotAvatarVectorPath: Codable, Equatable, Sendable {
    public enum Command: Equatable, Sendable, Codable {
        case move(x: Double, y: Double)
        case line(x: Double, y: Double)
        case quadratic(cx: Double, cy: Double, x: Double, y: Double)
        case cubic(c1x: Double, c1y: Double, c2x: Double, c2y: Double, x: Double, y: Double)
        case arc(rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool, x: Double, y: Double)
        case close

        private enum Keys: String, CodingKey { case c, x, y, x1, y1, x2, y2, rx, ry, rot, large, sweep }
        public init(from decoder: any Decoder) throws {
            let v = try decoder.container(keyedBy: Keys.self)
            func number(_ key: Keys) throws -> Double { try v.decode(Double.self, forKey: key) }
            switch try v.decode(String.self, forKey: .c) {
            case "M": self = .move(x: try number(.x), y: try number(.y))
            case "L": self = .line(x: try number(.x), y: try number(.y))
            case "Q": self = .quadratic(cx: try number(.x1), cy: try number(.y1), x: try number(.x), y: try number(.y))
            case "C": self = .cubic(c1x: try number(.x1), c1y: try number(.y1), c2x: try number(.x2), c2y: try number(.y2), x: try number(.x), y: try number(.y))
            case "A": self = .arc(rx: try number(.rx), ry: try number(.ry), rotation: try number(.rot),
                                   large: try number(.large) == 1, sweep: try number(.sweep) == 1, x: try number(.x), y: try number(.y))
            case "Z": self = .close
            default: throw DecodingError.dataCorruptedError(forKey: .c, in: v, debugDescription: "Unknown avatar path command")
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var v = encoder.container(keyedBy: Keys.self)
            func point(_ x: Double, _ y: Double) throws { try v.encode(x, forKey: .x); try v.encode(y, forKey: .y) }
            switch self {
            case .move(let x, let y): try v.encode("M", forKey: .c); try point(x, y)
            case .line(let x, let y): try v.encode("L", forKey: .c); try point(x, y)
            case .quadratic(let cx, let cy, let x, let y):
                try v.encode("Q", forKey: .c); try v.encode(cx, forKey: .x1); try v.encode(cy, forKey: .y1); try point(x, y)
            case .cubic(let x1, let y1, let x2, let y2, let x, let y):
                try v.encode("C", forKey: .c); try v.encode(x1, forKey: .x1); try v.encode(y1, forKey: .y1)
                try v.encode(x2, forKey: .x2); try v.encode(y2, forKey: .y2); try point(x, y)
            case .arc(let rx, let ry, let rotation, let large, let sweep, let x, let y):
                try v.encode("A", forKey: .c); try v.encode(rx, forKey: .rx); try v.encode(ry, forKey: .ry)
                try v.encode(rotation, forKey: .rot); try v.encode(large ? 1 : 0, forKey: .large); try v.encode(sweep ? 1 : 0, forKey: .sweep); try point(x, y)
            case .close: try v.encode("Z", forKey: .c)
            }
        }
    }
    public let commands: [Command]
    public let evenOdd: Bool
}

nonisolated public struct BotAvatarFrameOptions: Codable, Equatable, Sendable {
    public enum Motion: String, Codable, Sendable { case idle, thinking, happy }
    public struct View: Codable, Equatable, Sendable {
        public var yaw: Double
        public var pitch: Double
        public init(yaw: Double, pitch: Double) { self.yaw = yaw; self.pitch = pitch }
    }
    public struct Gaze: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var weight: Double
        public init(x: Double, y: Double, weight: Double = 1) { self.x = x; self.y = y; self.weight = weight }
    }
    public var time: Double
    public var motion: Motion
    public var reducedMotion: Bool
    public var depth: Double
    public var view: View?
    public var gaze: Gaze?
    public var instanceID: String?
    public var now: Double?

    public init(time: Double = 0, motion: Motion = .idle, reducedMotion: Bool = false, depth: Double = 6,
                view: View? = nil, gaze: Gaze? = nil, instanceID: String? = nil, now: Double? = nil) {
        self.time = time; self.motion = motion; self.reducedMotion = reducedMotion; self.depth = depth
        self.view = view; self.gaze = gaze; self.instanceID = instanceID; self.now = now
    }
}

nonisolated public struct BotAvatarRenderFrame: Codable, Equatable, Sendable {
    public enum EyeMark: Equatable, Sendable, Codable {
        case pill(x: Double, y: Double, width: Double, height: Double, radius: Double)
        case arc(x0: Double, y0: Double, cx: Double, cy: Double, x1: Double, y1: Double, strokeWidth: Double)
        private enum Keys: String, CodingKey { case shape, x, y, width, height, radius, x0, y0, cx, cy, x1, y1, strokeWidth }
        public init(from decoder: any Decoder) throws {
            let v = try decoder.container(keyedBy: Keys.self)
            func n(_ key: Keys) throws -> Double { try v.decode(Double.self, forKey: key) }
            switch try v.decode(String.self, forKey: .shape) {
            case "pill": self = .pill(x: try n(.x), y: try n(.y), width: try n(.width), height: try n(.height), radius: try n(.radius))
            case "arc": self = .arc(x0: try n(.x0), y0: try n(.y0), cx: try n(.cx), cy: try n(.cy), x1: try n(.x1), y1: try n(.y1), strokeWidth: try n(.strokeWidth))
            default: throw DecodingError.dataCorruptedError(forKey: .shape, in: v, debugDescription: "Unknown avatar eye")
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var v = encoder.container(keyedBy: Keys.self)
            switch self {
            case .pill(let x, let y, let width, let height, let radius):
                try v.encode("pill", forKey: .shape); try v.encode(x, forKey: .x); try v.encode(y, forKey: .y)
                try v.encode(width, forKey: .width); try v.encode(height, forKey: .height); try v.encode(radius, forKey: .radius)
            case .arc(let x0, let y0, let cx, let cy, let x1, let y1, let stroke):
                try v.encode("arc", forKey: .shape); try v.encode(x0, forKey: .x0); try v.encode(y0, forKey: .y0)
                try v.encode(cx, forKey: .cx); try v.encode(cy, forKey: .cy); try v.encode(x1, forKey: .x1); try v.encode(y1, forKey: .y1); try v.encode(stroke, forKey: .strokeWidth)
            }
        }
    }
    public enum Shape: Equatable, Sendable, Codable {
        case slice(key: String, path: String, matrix: BotAvatarAffine)
        case eye(key: String, matrix: BotAvatarAffine, mark: EyeMark)
        private enum Keys: String, CodingKey { case kind, key, path, matrix, mark }
        public init(from decoder: any Decoder) throws {
            let v = try decoder.container(keyedBy: Keys.self)
            let key = try v.decode(String.self, forKey: .key), matrix = try v.decode(BotAvatarAffine.self, forKey: .matrix)
            switch try v.decode(String.self, forKey: .kind) {
            case "slice": self = .slice(key: key, path: try v.decode(String.self, forKey: .path), matrix: matrix)
            case "eye": self = .eye(key: key, matrix: matrix, mark: try v.decode(EyeMark.self, forKey: .mark))
            default: throw DecodingError.dataCorruptedError(forKey: .kind, in: v, debugDescription: "Unknown avatar shape")
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var v = encoder.container(keyedBy: Keys.self)
            switch self {
            case .slice(let key, let path, let matrix):
                try v.encode("slice", forKey: .kind); try v.encode(key, forKey: .key); try v.encode(path, forKey: .path); try v.encode(matrix, forKey: .matrix)
            case .eye(let key, let matrix, let mark):
                try v.encode("eye", forKey: .kind); try v.encode(key, forKey: .key); try v.encode(matrix, forKey: .matrix); try v.encode(mark, forKey: .mark)
            }
        }
    }
    public let name: String
    public let color: String
    public let ink: String
    public let root: BotAvatarAffine
    public let shapes: [Shape]
}

nonisolated public struct BotAvatarDrawingAsset: Codable, Equatable, Sendable {
    public let geometry: BotAvatarGeometry
    public let key: String
    public let paths: [String: BotAvatarVectorPath]
    public let outline: BotAvatarVectorPath
    public let restingBounds: BotAvatarBounds
    public let restingFrame: BotAvatarRenderFrame
    public let isRestingPreview: Bool
}
