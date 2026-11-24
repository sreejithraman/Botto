import Foundation

/// How the spaces list, the new-space page, and app launch read one bot's spaces.
/// Pure and shared by the phone and Mac apps so both order and summarize spaces the same way.
public enum T3ChatShelf {
    /// Spaces last, so nothing here groups or expires them by age.
    public struct Spaces: Equatable, Sendable {
        /// The anchor and coordinator, always first.
        public let main: T3ChannelSummary?
        public let pinned: [T3ChannelSummary]
        /// Every other live space, most recently active first.
        public let spaces: [T3ChannelSummary]
        /// Kept behind the quiet archive link.
        public let archived: [T3ChannelSummary]

        /// Live spaces in the order the list shows them.
        public var live: [T3ChannelSummary] { (main.map { [$0] } ?? []) + others }
        public var others: [T3ChannelSummary] { pinned + spaces }
    }

    public static func spaces(_ channels: [T3ChannelSummary]) -> Spaces {
        let ordered = channels.sorted(by: T3ProjectionMapper.listOrder)
        let main = ordered.first { $0.isMain && !$0.isArchived }
        let others = ordered.filter { !$0.isArchived && $0.id != main?.id }
        return Spaces(main: main, pinned: others.filter(\.isPinned), spaces: others.filter { !$0.isPinned },
                      archived: ordered.filter(\.isArchived))
    }

    /// Where launch lands: a space waiting on you, else one Botto is busy in, else the main space,
    /// else the latest live space when no main space exists yet.
    public static func initialSpace(_ channels: [T3ChannelSummary]) -> T3ChannelSummary? {
        let live = channels.filter { !$0.isArchived }
        return live.filter(\.needsYou).max(by: newer)
            ?? live.filter { $0.status != .idle }.max(by: newer)
            ?? live.first(where: \.isMain)
            ?? live.max(by: newer)
    }

    /// At most a couple of quiet notes for the new-space page: spaces that need you, then unread results.
    public static func whileYouWereAway(_ channels: [T3ChannelSummary], limit: Int = 2) -> [T3ChannelSummary] {
        let live = channels.filter { !$0.isArchived }
        let waiting = live.filter(\.needsYou).sorted { newer($1, $0) }
        let unread = live.filter { $0.isUnread && !$0.needsYou && $0.status == .idle }.sorted { newer($1, $0) }
        return Array((waiting + unread).prefix(limit))
    }

    public enum Greeting: String, Sendable {
        case morning = "Morning.", afternoon = "Afternoon.", evening = "Evening."
    }

    public static func greeting(at date: Date = .now, calendar: Calendar = .current) -> Greeting {
        switch calendar.component(.hour, from: date) {
        case 4..<12: .morning
        case 12..<17: .afternoon
        default: .evening
        }
    }

    public struct SearchResults: Equatable, Sendable {
        public let spaces: [T3ChannelSummary]
        public let files: [T3OutputFile]
        public var isEmpty: Bool { spaces.isEmpty && files.isEmpty }
    }

    /// One search over space titles and previews and the files Botto made.
    public static func search(_ query: String, spaces channels: [T3ChannelSummary], files: [T3OutputFile]) -> SearchResults {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return SearchResults(spaces: [], files: []) }
        func matches(_ fields: String...) -> Bool {
            terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }
        return SearchResults(
            spaces: channels.filter { matches($0.displayTitle, $0.preview) }.sorted(by: T3ProjectionMapper.listOrder),
            files: files.filter { matches($0.name, $0.relativePath) })
    }

    private static func newer(_ lhs: T3ChannelSummary, _ rhs: T3ChannelSummary) -> Bool {
        (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
    }
}
