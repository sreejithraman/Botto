enum HermesProtocolVersion {
    static func isSupported(_ version: String) -> Bool {
        if version == "unknown" { return true }
        let components = version.split(separator: ".").prefix(3).compactMap { Int($0.prefix(while: \.isNumber)) }
        return components.count == 3 && !components.lexicographicallyPrecedes([0, 21, 5])
    }
}
