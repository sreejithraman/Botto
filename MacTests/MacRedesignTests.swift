import BottoCore
import Foundation
import Testing
@testable import BottoMac

struct MacActivityCueTests {
    @Test func cuesReadAsQuietLowercaseLines() {
        #expect(MacAvatarActivity.thinking.cue == "thinking…")
        #expect(MacAvatarActivity.working.cue == "working…")
        #expect(MacAvatarActivity.waiting.cue == "waiting on you")
        #expect(MacAvatarActivity.idle.cue == nil)
    }

    @Test func sleepingIsNeitherBusyNorWaiting() {
        #expect(!MacAvatarActivity.sleeping.isBusy)
        #expect(MacAvatarActivity.sleeping.label == "Asleep")
        #expect(MacAvatarActivity.tools.isBusy)
    }
}

@MainActor struct MacAutosaverTests {
    @Test func typingBurstSavesOnlyTheNewestText() async throws {
        var saves: [String] = []
        let saver = MacAutosaver(initial: "start", delay: .milliseconds(20)) { saves.append($0) }
        saver.edit("s")
        saver.edit("st")
        saver.edit("still typing")
        #expect(saver.state == .pending)
        try await Task.sleep(for: .milliseconds(120))
        #expect(saves == ["still typing"])
        #expect(saver.state == .saved)
    }

    @Test func revertingBeforeTheDelaySavesNothing() async throws {
        var saves: [String] = []
        let saver = MacAutosaver(initial: "same", delay: .milliseconds(20)) { saves.append($0) }
        saver.edit("changed")
        saver.edit("same")
        try await Task.sleep(for: .milliseconds(80))
        #expect(saves.isEmpty)
    }

    @Test func flushSavesImmediatelyAndFailuresRetryWithTheNextFlush() async {
        struct Offline: LocalizedError { var errorDescription: String? { "Offline." } }
        final class Log { var attempts: [String] = []; var fail = true }
        let log = Log()
        let saver = MacAutosaver(initial: "", delay: .seconds(60)) { value in
            log.attempts.append(value)
            if log.fail { throw Offline() }
        }
        saver.edit("remember the milk")
        await saver.flush()
        #expect(saver.state == .failed("Offline."))
        log.fail = false
        await saver.flush()
        #expect(log.attempts == ["remember the milk", "remember the milk"])
        #expect(saver.state == .saved)
    }
}

struct MacPresentationTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func brainSummariesNeverMentionFileNames() {
        let soul = "# Soul\n\nCurious, a little dry, keeps answers short.\n"
        #expect(MacBrainSummary.personality(soul) == "Curious, a little dry, keeps answers short.")
        let memory = "# Memory\n\n- Lives in Oakland\n- **Vegetarian** on weekdays\n"
        #expect(MacBrainSummary.memory(memory).count == 2)
        #expect(MacBrainSummary.memoryDetail(memory) == "2 things · last: “Vegetarian on weekdays”")
        #expect(MacBrainSummary.memoryDetail(T3BotBootstrap.memoryMarkdown) == "Nothing yet")
        #expect(!MacBrainSummary.memoryDetail(memory).contains("MEMORY"))
    }

    @Test func skillsReadAsNames() {
        #expect(MacBrainSummary.skillName("skills/trip-planning") == "Trip Planning")
        #expect(MacBrainSummary.skillFile("skills/trip-planning") == "skills/trip-planning/SKILL.md")
        #expect(MacBrainSummary.skillFile("notes.md") == "skills/notes.md")
    }

    @Test func routineSchedulesRoundTrip() {
        let locale = Locale(identifier: "en_US_POSIX")
        #expect(MacRoutineSchedule.weekdays.cron(hour: 8, minute: 30) == "30 8 * * 1-5")
        #expect(MacRoutineSchedule.everyDay.cron(hour: 9, minute: 0) == "0 9 * * *")
        #expect(MacRoutineSchedule.summary("0 9 * * *", calendar: calendar, locale: locale).hasPrefix("Every day · "))
        #expect(MacRoutineSchedule.summary("30 17 * * 1,2,3,4,5", calendar: calendar, locale: locale).hasPrefix("Weekdays · "))
        #expect(MacRoutineSchedule.summary("", calendar: calendar, locale: locale) == "Custom schedule")
    }

    @Test func rowTimesAreCalm() throws {
        let locale = Locale(identifier: "en_US_POSIX")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 15)))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 7, minute: 40)))
        let thursday = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9)))
        let old = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9)))
        #expect(MacTimeLabel.compact(morning, now: now, calendar: calendar, locale: locale).contains("7:40"))
        #expect(MacTimeLabel.compact(thursday, now: now, calendar: calendar, locale: locale) == "Thu")
        #expect(MacTimeLabel.compact(old, now: now, calendar: calendar, locale: locale) == "Oct 2")
    }

    @Test func filesPreviewByKind() {
        #expect(MacFileKind(name: "plan.md", mimeType: "application/octet-stream") == .markdown)
        #expect(MacFileKind(name: "plot.png", mimeType: "image/png") == .image)
        #expect(MacFileKind(name: "logo.svg", mimeType: "image/svg+xml") == .other)
        #expect(MacFileKind(name: "data.csv", mimeType: "text/csv") == .text)
        #expect(MacPageThumbnail.excerpt(from: "# Kyoto, 5 slow days\n\n- **Slow** mornings\n```\ncode\n```") ==
            ["Kyoto, 5 slow days", "Slow mornings", "code"])
    }
}

@MainActor struct MacBottoStoreTests {
    private func store() throws -> MacBottoStore {
        let suite = "botto.mac.store-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return MacBottoStore(session: MacSessionPersistence(slot: MacSessionPersistenceTests.MemorySlot(), defaults: defaults))
    }

    @Test func offlineStoreHasNoOpenSpaceAndRefusesWork() async throws {
        let store = try store()
        #expect(store.selectedChannelID == nil)
        #expect(store.modelLabel(for: nil) == "Automatic")
        let started = await store.startSpace(text: "Plan the Kyoto trip", files: [])
        #expect(started.spaceID == nil && !started.sent)
        let named = await store.startSpace(named: "Kyoto trip", text: "", files: [])
        #expect(named.spaceID == nil && !named.sent)
        #expect(!(await store.send(text: "hello")))
        await #expect(throws: T3ServiceError.disconnected) { try await store.saveSoul("Be kind.") }
        store.showFreshPage()
        #expect(store.openedConversation == nil)
    }

    @Test func modelChipPrefersTheSpacesOwnModel() throws {
        let store = try store()
        let chat = T3ChannelSummary(id: "a", title: "Kyoto", isPinned: false, isArchived: false, isUnread: false,
                                    status: .idle, preview: "", updatedAt: nil, providerInstanceID: "claude", model: "opus-test")
        #expect(store.modelLabel(for: chat) == "opus-test")
    }

    @Test func sidebarAndLaunchShareTheMainSpaceAnchor() {
        func space(_ id: String, main: Bool = false, pinned: Bool = false, status: BotStatus = .idle) -> T3ChannelSummary {
            T3ChannelSummary(id: id, title: id, isMain: main, isPinned: pinned, isArchived: false, isUnread: false,
                             status: status, preview: "", updatedAt: nil)
        }
        let spaces = [space("a"), space("pinned", pinned: true), space("home", main: true)]
        #expect(T3ChatShelf.spaces(spaces).live.map(\.id) == ["home", "pinned", "a"])
        #expect(T3ChatShelf.initialSpace(spaces)?.id == "home")
        #expect(T3ChatShelf.initialSpace(spaces + [space("ask", status: .waiting)])?.id == "ask")
    }
}
