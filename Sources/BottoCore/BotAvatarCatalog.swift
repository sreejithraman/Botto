import Foundation

/// One reference-engine definition for each shared Hermes shape family.
nonisolated public enum BotAvatarCatalog {
    public static func geometry(for shape: BotAvatarShape) -> BotAvatarGeometry {
        guard let geometry = definitions[shape] else {
            preconditionFailure("The bundled avatar catalog must cover every Hermes shape family.")
        }
        return geometry
    }

    private static let definitions: [BotAvatarShape: BotAvatarGeometry] = {
        guard let url = Bundle.module.url(forResource: "HermesAvatarDefinitions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let geometries = try? JSONDecoder().decode([BotAvatarGeometry].self, from: data),
              geometries.count == BotAvatarShape.allCases.count else {
            preconditionFailure("The bundled Hermes avatar definitions are missing or malformed.")
        }
        var result: [BotAvatarShape: BotAvatarGeometry] = [:]
        for geometry in geometries {
            guard let shape = BotAvatarShape(rawValue: geometry.id), result.updateValue(geometry, forKey: shape) == nil else {
                preconditionFailure("The bundled Hermes avatar definitions must map one to one to shape families.")
            }
        }
        return result
    }()
}
