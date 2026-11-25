@testable import BottoCore
import Foundation
import Testing
@testable import BottoMac

struct MacPreviewFileTests {
    @Test func previewUsesAPrivateDirectoryAndCleansUpItsCopy() async throws {
        let artifact = DownloadedArtifact(data: Data("Notes".utf8), filename: "folder/Notes.txt", mimeType: "text/plain")
        var file: MacPreviewFile? = try await MacPreviewFile.write(artifact)
        let url = try #require(file?.url)
        let directory = url.deletingLastPathComponent()
        #expect(url.lastPathComponent == "Notes.txt")
        #expect(try Data(contentsOf: url) == artifact.data)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        file = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

@MainActor struct MacProseConflictTests {
    @Test func refreshesCleanProseWithoutOverwritingAnEditDuringTheRead() async {
        var replaced: [String] = []
        let autosaver = MacAutosaver(initial: "Old host text", delay: .seconds(60)) { _, expected in
            replaced.append(expected)
        }
        autosaver.refresh("Current host text", revision: autosaver.refreshRevision)
        #expect(autosaver.text == "Current host text")

        let readRevision = autosaver.refreshRevision
        autosaver.edit("My draft")
        autosaver.refresh("A host update", revision: readRevision)
        #expect(autosaver.text == "My draft")
        await autosaver.flush()
        #expect(replaced == ["Current host text"])
    }

    @Test func keepsTheDraftUntilAnExplicitReload() async {
        let current = "Host updated this"
        let autosaver = MacAutosaver(initial: "Previous host text", delay: .seconds(60)) { _, expected in
            #expect(expected == "Previous host text")
            throw T3ServiceError.proseChanged
        }
        autosaver.edit("Keep my draft")
        await autosaver.flush()
        #expect(autosaver.text == "Keep my draft")
        #expect(autosaver.hasUnsavedEdits)
        await autosaver.reload { current }
        #expect(autosaver.text == current)
        #expect(!autosaver.hasUnsavedEdits)
    }
}

@MainActor struct MacFreshDraftTests {
    @Test func modelChoiceCannotReturnToAutomaticAfterAnExplicitSpaceStart() async throws {
        let draft = MacFreshDraft()
        let first = T3ModelOption(id: "first", providerInstanceID: "first", providerName: "First",
                                  modelID: "first", label: "First")
        let second = T3ModelOption(id: "second", providerInstanceID: "second", providerName: "Second",
                                   modelID: "second", label: "Second")
        draft.text = "Keep this"
        draft.selectModel(first)
        #expect(draft.offersAutomaticModel)
        await #expect(throws: HermesServiceError.rejected(400)) {
            _ = try await draft.submit { _ in "first-space" } send: { _, _, _, model in
                #expect(model == first)
                throw HermesServiceError.rejected(400)
            }
        }
        #expect(!draft.offersAutomaticModel)
        draft.selectModel(nil)
        #expect(draft.model == first)
        draft.selectModel(second)
        #expect(draft.model == second)
    }

    @Test func rejectedFirstSendRetriesInTheCreatedSpaceAndSettlesTheWholeDraft() async throws {
        let draft = MacFreshDraft()
        let file = URL(fileURLWithPath: "/example/plan.txt")
        draft.name = "Weekend"
        draft.text = "Plan a trip"
        draft.files = [file]
        var created: [String?] = []
        var delivered: [String] = []
        var reject = true
        func create(_ title: String?) async throws -> String {
            created.append(title)
            return "weekend-space"
        }
        func send(_ id: String, _ text: String, _ files: [URL], _: T3ModelOption?) async throws {
            #expect(id == "weekend-space")
            #expect(files == [file])
            if reject { throw HermesServiceError.rejected(400) }
            delivered.append(text)
        }
        await #expect(throws: HermesServiceError.rejected(400)) {
            _ = try await draft.submit(create: create, send: send)
        }
        #expect(draft.createdSpace == "weekend-space")
        #expect(draft.text == "Plan a trip")
        #expect(draft.files == [file])
        #expect(delivered.isEmpty)

        reject = false
        #expect(try await draft.submit(create: create, send: send) == "weekend-space")
        #expect(created == ["Weekend"])
        #expect(delivered == ["Plan a trip"])
        #expect(draft.createdSpace == nil)
        #expect(draft.name.isEmpty && draft.text.isEmpty && draft.files.isEmpty)
        #expect(try await draft.submit(create: create, send: send) == nil)
    }
}

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
        let saver = MacAutosaver(initial: "start", delay: .milliseconds(20)) { value, _ in saves.append(value) }
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
        let saver = MacAutosaver(initial: "same", delay: .milliseconds(20)) { value, _ in saves.append(value) }
        saver.edit("changed")
        saver.edit("same")
        try await Task.sleep(for: .milliseconds(80))
        #expect(saves.isEmpty)
    }

    @Test func flushSavesImmediatelyAndFailuresRetryWithTheNextFlush() async {
        struct Offline: LocalizedError { var errorDescription: String? { "Offline." } }
        final class Log { var attempts: [String] = []; var fail = true }
        let log = Log()
        let saver = MacAutosaver(initial: "", delay: .seconds(60)) { value, _ in
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
        store.fresh.text = "Plan the Kyoto trip"
        await store.startSpace()
        #expect(store.fresh.createdSpace == nil && store.fresh.text == "Plan the Kyoto trip")
        store.fresh.text = ""
        store.fresh.name = "Kyoto trip"
        await store.startSpace()
        #expect(store.fresh.createdSpace == nil && store.fresh.name == "Kyoto trip")
        #expect(!(await store.send(text: "hello")))
        await #expect(throws: T3ServiceError.disconnected) { try await store.saveSoul("Be kind.") }
        store.showFreshPage()
        #expect(store.openedConversation == nil)
    }

    @Test func uncertainActionSurvivesNavigationAndDismissingAnotherError() throws {
        let store = try store()
        store.recordMutationFailure(HermesServiceError.uncertain)
        let notice = try #require(store.pendingMutationNotice)
        store.showFreshPage()
        #expect(store.pendingMutationNotice == notice)
        store.recordMutationFailure(HermesServiceError.invalidAttachment)
        _ = try #require(store.error)
        store.dismissError()
        #expect(store.error == nil)
        #expect(store.pendingMutationNotice == notice)
        store.acknowledgeUncertainAction()
        #expect(store.pendingMutationNotice == nil)
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
