import Foundation
import Testing
@testable import BottoCore

@Suite struct T3ChatShelfTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func space(_ id: String, hoursAgo: Double?, main: Bool = false, pinned: Bool = false, archived: Bool = false,
                       unread: Bool = false, status: BotStatus = .idle, preview: String = "") -> T3ChannelSummary {
        T3ChannelSummary(id: id, title: id, isMain: main, isPinned: pinned, isArchived: archived, isUnread: unread,
                         status: status, preview: preview, updatedAt: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) })
    }

    @Test func keepsTheMainSpaceOnTopAndNeverBucketsByTime() {
        let channels = [space("old", hoursAgo: 24 * 300), space("week", hoursAgo: 24 * 3), space("today", hoursAgo: 1),
                        space("home", hoursAgo: 24 * 90, main: true), space("pinned", hoursAgo: 24 * 40, pinned: true),
                        space("gone", hoursAgo: 0.5, archived: true), space("undated", hoursAgo: nil)]
        let shelf = T3ChatShelf.spaces(channels)
        #expect(shelf.main?.id == "home")
        #expect(shelf.pinned.map(\.id) == ["pinned"])
        // However old, an ongoing space stays in the one list, newest first.
        #expect(shelf.spaces.map(\.id) == ["today", "week", "old", "undated"])
        #expect(shelf.archived.map(\.id) == ["gone"])
        #expect(shelf.live.map(\.id) == ["home", "pinned", "today", "week", "old", "undated"])

        let pinnedMain = T3ChatShelf.spaces([space("home", hoursAgo: 1, main: true, pinned: true)])
        #expect(pinnedMain.main?.id == "home" && pinnedMain.others.isEmpty)
        let withoutMain = T3ChatShelf.spaces([space("only", hoursAgo: 1)])
        #expect(withoutMain.main == nil && withoutMain.live.map(\.id) == ["only"])
    }

    @Test func launchOpensAnActiveSpaceElseTheMainSpace() {
        let home = space("home", hoursAgo: 24 * 9, main: true)
        #expect(T3ChatShelf.initialSpace([space("recent", hoursAgo: 1), home])?.id == "home")
        let working = space("working", hoursAgo: 1, status: .working)
        #expect(T3ChatShelf.initialSpace([home, working])?.id == "working")
        #expect(T3ChatShelf.initialSpace([home, working, space("waiting", hoursAgo: 30, status: .waiting)])?.id == "waiting")
        #expect(T3ChatShelf.initialSpace([home, space("gone", hoursAgo: 1, archived: true, status: .waiting)])?.id == "home")
        #expect(T3ChatShelf.initialSpace([space("stale", hoursAgo: 80), space("recent", hoursAgo: 30)])?.id == "recent")
        #expect(T3ChatShelf.initialSpace([space("gone", hoursAgo: 1, archived: true)]) == nil)
    }

    @Test func whileYouWereAwayShowsAtMostTwoQuietNotes() {
        let spaces = [space("read", hoursAgo: 1), space("result", hoursAgo: 3, unread: true),
                     space("ask", hoursAgo: 5, status: .waiting), space("newer-result", hoursAgo: 2, unread: true),
                     space("working", hoursAgo: 1, unread: true, status: .working)]
        #expect(T3ChatShelf.whileYouWereAway(spaces).map(\.id) == ["ask", "newer-result"])
        #expect(T3ChatShelf.whileYouWereAway([space("read", hoursAgo: 1)]).isEmpty)
    }

    @Test func greetsByTimeOfDay() {
        func at(_ hour: Int) -> Date { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)! }
        #expect(T3ChatShelf.greeting(at: at(8), calendar: calendar) == .morning)
        #expect(T3ChatShelf.greeting(at: at(13), calendar: calendar) == .afternoon)
        #expect(T3ChatShelf.greeting(at: at(21), calendar: calendar) == .evening)
        #expect(T3ChatShelf.greeting(at: at(2), calendar: calendar).rawValue == "Evening.")
    }

    @Test func searchCoversSpacesAndFiles() {
        let spaces = [space("Kyoto trip", hoursAgo: 1, preview: "Book the 8:12?"), space("Bike light", hoursAgo: 2)]
        let files = [T3OutputFile(name: "kyoto-plan.md", relativePath: "outputs/kyoto-plan.md", mimeType: "text/markdown"),
                     T3OutputFile(name: "release.md", relativePath: "outputs/release.md", mimeType: "text/markdown")]
        let results = T3ChatShelf.search("kyoto", spaces: spaces, files: files)
        #expect(results.spaces.map(\.id) == ["Kyoto trip"])
        #expect(results.files.map(\.name) == ["kyoto-plan.md"])
        #expect(T3ChatShelf.search("8:12", spaces: spaces, files: files).spaces.map(\.id) == ["Kyoto trip"])
        #expect(T3ChatShelf.search("  ", spaces: spaces, files: files).isEmpty)
    }
}
