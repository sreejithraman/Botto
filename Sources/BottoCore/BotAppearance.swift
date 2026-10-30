// Shared Hermes defaults adapted from Hermex. MIT; see LICENSES/Hermex.txt.
import Foundation

public enum BotAvatarShape: String, CaseIterable, Codable, Identifiable, Sendable {
    case circle, blob, squircle, pill, triangle, hexagon, cloud, drop
    case nub, sun
    /// Classic shapes are editable; Blobatar-only silhouettes are display choices.
    public static let pickerCases: [BotAvatarShape] = [.circle, .blob, .squircle, .pill, .triangle, .hexagon, .cloud, .drop]
    public var id: String { rawValue }
}

/// A projection of the shared look. Writes merge into freshly read metadata, not this projection.
public struct BotAppearance: Codable, Equatable, Sendable {
    /// Keep the shared choice verbatim, including recipes and future shape kinds.
    public var rawShape: String?
    public var shape: BotAvatarShape? {
        get { rawShape.flatMap(BotAvatarShape.init(rawValue:)) }
        set { rawShape = newValue?.rawValue }
    }
    public var color: String?
    public var custom: Bool
    public var imageKind: String?
    public var expression: String?
    public var isGenerated: Bool { BotAvatarRecipe.isBlobatar(rawShape) }

    private enum CodingKeys: String, CodingKey {
        case rawShape = "shape"
        case color, custom, imageKind, expression
    }

    public init(shape: BotAvatarShape? = nil, color: String? = nil, custom: Bool = false,
                imageKind: String? = nil, expression: String? = nil) {
        self.init(rawShape: shape?.rawValue, color: color, custom: custom || shape != nil || color != nil,
                  imageKind: imageKind, expression: expression)
    }

    /// Reads shared metadata without treating an automatically seeded shape as a user edit.
    public init(rawShape: String?, color: String? = nil, custom: Bool = false,
                imageKind: String? = nil, expression: String? = nil) {
        self.rawShape = rawShape; self.color = color; self.custom = custom
        self.imageKind = imageKind; self.expression = expression
    }

    public func face(for profileID: String) -> BotFace {
        if BotAvatarRecipe.isPrimary(profileID), !custom {
            return BotFace(shape: .squircle, color: "#8b5cf6")
        }
        if let recipe = BotAvatarRecipe.blobatar(rawShape: rawShape, profileID: profileID) {
            return BotFace(shape: recipe.shape, color: BotAvatarColors.blobatarColor(hue: recipe.hue))
        }
        let fallbackColor = BotAvatarRecipe.defaultHue(for: profileID).map { BotAvatarColors.presetColor(hue: $0) } ?? "#8b5cf6"
        return BotFace(shape: shape ?? BotAvatarRecipe.defaultShape(for: profileID),
                       color: color.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackColor)
    }
}

public struct BotFace: Equatable, Sendable {
    public var shape: BotAvatarShape
    public var color: String
    public init(shape: BotAvatarShape, color: String) { self.shape = shape; self.color = color }
}

private extension BotFace {
    // Only deliberate choices normalize recognized presets. Reads retain their source.
    var sharedColor: String { BotAvatarColors.preset(for: color)?.shared ?? color }
}

/// Fields selected for editing. Nil leaves a field unselected; saving may
/// canonicalize a recognized color preset.
public struct BotAvatarEdit: Equatable, Sendable {
    public enum Color: Equatable, Sendable {
        case automatic
        case value(String)
    }
    public var shape: BotAvatarShape?
    public var color: Color?

    public init(shape: BotAvatarShape? = nil, color: Color? = nil) {
        self.shape = shape; self.color = color
    }
}

/// Explicit choices replace any existing image with a drawn face.
public enum BotAvatarChoice: Equatable, Sendable {
    case automatic
    /// A classic shape with no color override: Hermes derives the color from the profile name.
    case shape(BotAvatarShape)
    case face(BotFace)
    case edit(BotAvatarEdit)

    public var appearance: BotAppearance { applying(to: BotAppearance()) }

    /// Preview the same fields that the save boundary will merge into fresh metadata.
    public func applying(to current: BotAppearance) -> BotAppearance {
        switch self {
        case .automatic: return BotAppearance(expression: current.expression)
        case .shape(let shape): return BotAppearance(shape: shape, custom: true, imageKind: "shape", expression: current.expression)
        case .face(let face): return BotAppearance(shape: face.shape, color: face.sharedColor, custom: true, imageKind: "shape", expression: current.expression)
        case .edit(let edit):
            var result = current
            if let shape = edit.shape { result.shape = shape }
            switch edit.color {
            case .automatic: result.color = nil
            case .value(let color): result.color = BotAvatarColors.preset(for: color)?.shared ?? color
            case nil:
                if let color = result.color, let preset = BotAvatarColors.preset(for: color) { result.color = preset.shared }
            }
            result.custom = true; result.imageKind = "shape"
            return result
        }
    }
}

extension BotProfile {
    public var face: BotFace { (appearance ?? BotAppearance()).face(for: id) }
}

extension BotAvatarChoice {
    func validate(current: BotAppearance? = nil) throws {
        if case .edit(let edit) = self {
            guard edit.shape != nil || edit.color != nil else { throw HermesServiceError.invalidAvatar }
            // Blobatar ignores classic color overrides: conversion needs an explicit classic shape.
            if current?.isGenerated == true, edit.color != nil, edit.shape == nil {
                throw HermesServiceError.invalidAvatar
            }
        }
        if let shape = appearance.shape, !BotAvatarShape.pickerCases.contains(shape) {
            throw HermesServiceError.invalidAvatar
        }
        if let color = appearance.color, !BotAvatarColors.isValid(color) {
            throw HermesServiceError.invalidAvatar
        }
    }

    func merging(into received: [String: HermesJSON]) -> [String: HermesJSON] {
        var look = received
        switch self {
        case .automatic:
            for key in ["shape", "color", "custom", "imageKind"] { look.removeValue(forKey: key) }
        case .shape(let shape):
            look["shape"] = .string(shape.rawValue)
            look.removeValue(forKey: "color")
            look["custom"] = .bool(true)
            look["imageKind"] = .string("shape")
        case .face(let face):
            look["shape"] = .string(face.shape.rawValue)
            look["color"] = .string(face.sharedColor)
            look["custom"] = .bool(true)
            look["imageKind"] = .string("shape")
        case .edit(let edit):
            if let shape = edit.shape { look["shape"] = .string(shape.rawValue) }
            switch edit.color {
            case .automatic: look.removeValue(forKey: "color")
            case .value(let color): look["color"] = .string(BotAvatarColors.preset(for: color)?.shared ?? color)
            case nil:
                if let color = look["color"]?.text, let preset = BotAvatarColors.preset(for: color) {
                    look["color"] = .string(preset.shared)
                }
            }
            look["custom"] = .bool(true)
            look["imageKind"] = .string("shape")
        }
        return look
    }
}
