import BottoCore
import Foundation

/// Short, calm time stamps for space rows: a clock time today, a weekday this week, else a date.
enum MacTimeLabel {
    static func compact(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(style.hour().minute()) }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo {
            return date.formatted(style.weekday(.abbreviated))
        }
        return date.formatted(style.month(.abbreviated).day())
    }
}

/// Plain-language summaries of Botto's brain files, so the page never shows SOUL.md or MEMORY.md.
enum MacBrainSummary {
    /// The first line of prose: what Botto is like, in its own words.
    static func personality(_ markdown: String) -> String {
        proseLines(markdown).first ?? "Tell Botto who to be"
    }

    /// How many things Botto remembers, and the latest one.
    static func memory(_ markdown: String) -> (count: Int, latest: String?) {
        let lines = proseLines(markdown)
        return (lines.count, lines.last)
    }

    static func memoryDetail(_ markdown: String) -> String {
        let summary = memory(markdown)
        guard let latest = summary.latest else { return "Nothing yet" }
        let things = summary.count == 1 ? "1 thing" : "\(summary.count) things"
        return "\(things) · last: “\(latest)”"
    }

    static func skillName(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let base = (name as NSString).deletingPathExtension
        return base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .capitalized(with: nil)
    }

    static func skillFile(_ path: String) -> String {
        let relative = path.hasPrefix("skills/") ? path : "skills/" + path
        let ext = (relative as NSString).pathExtension.lowercased()
        return ["md", "markdown"].contains(ext) ? relative : relative + "/SKILL.md"
    }

    /// Lines of meaning: headings, rules, fences, and the default template line are skipped.
    private static func proseLines(_ markdown: String) -> [String] {
        markdown.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("```"), !line.hasPrefix("---"),
                  !line.hasPrefix(">") else { return nil }
            for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count))
                break
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
                line = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            return line.isEmpty || line == "Keep durable decisions and useful context here." ? nil : line
        }
    }
}

extension T3RoutineSchedule {
    static func macSummary(_ schedule: Self?, calendar: Calendar = .current, locale: Locale = .current,
                           showsChosenDays: Bool = false) -> String {
        guard let schedule, let date = calendar.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)) else {
            return "Custom schedule"
        }
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .hour().minute())
        let days: String
        switch schedule.days {
        case Self.everyDay: days = "Every day"
        case Self.weekdays: days = "Weekdays"
        case Self.weekends: days = "Weekends"
        default:
            var weekdayCalendar = calendar
            weekdayCalendar.locale = locale
            days = showsChosenDays
                ? schedule.days.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }.map { weekdayCalendar.shortWeekdaySymbols[$0] }.joined(separator: ", ")
                : "Some days"
        }
        return "\(days) · \(time)"
    }
}
