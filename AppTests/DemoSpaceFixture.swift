import BottoCore

func demoSpaceIdentity(_ id: String) throws -> SessionIdentity {
    let thread = try ExactID(id)
    return .init(profile: try ExactID("milo"), root: thread, stored: thread, aliases: [])
}
