/// Validation shared by HTTP and native sign-in boundaries that forward proxy headers.
enum HermesHeaderPolicy {
    static func isValid(_ headers: [String: String]) -> Bool {
        Set(headers.keys.map { $0.lowercased() }).count == headers.count
            && headers.allSatisfy { name, value in
                ["cf-access-client-id", "cf-access-client-secret"].contains(name.lowercased())
                    && !value.isEmpty && value.utf8.count <= 4_096
                    && value.utf8.allSatisfy { (32...126).contains($0) }
            }
    }
}
