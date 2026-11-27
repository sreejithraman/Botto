import Foundation
import Testing
@testable import BottoCore

@Suite struct T3ProjectionMapperTests {
    @Test func mapsSpacesWithTheirFlagsAndTheMainSpaceFirst() throws {
        let shells = try t3JSON("""
        [
          {"id":"archive","title":"Done","archivedAt":"2026-11-24T12:00:00Z","status":"completed",
           "updatedAt":"2026-11-24T12:10:00Z"},
          {"id":"legacy","title":"#general","status":"running","pinnedAt":"2026-11-23T12:00:00Z",
           "updatedAt":"2026-11-20T12:00:00Z",
           "latestVisibleMessage":{"text":"Current work","updatedAt":"2026-11-24T12:00:00Z"}},
          {"id":"ask","title":"Question","status":"running","pendingRuntimeRequest":{"id":"request","kind":"command"},
           "updatedAt":"2026-11-24T11:00:00Z","modelSelection":{"instanceId":"codex-2","model":"gpt-test"}},
          {"id":"fresh","title":"New thread","status":"idle","updatedAt":"2026-11-24T11:30:00Z",
           "modelSelection":{"provider":"claude","model":"claude-test"}}
        ]
        """)
        let profile = try ExactID("project")
        let mapped = try T3ProjectionMapper.directory(shells.list ?? [], profile: profile, observedAt: .distantPast)
        #expect(mapped.directory.summaries.allSatisfy { !$0.isCanonical })
        // Pinned first, then most recent, then the archive.
        #expect(mapped.channels.map(\.id) == ["legacy", "fresh", "ask", "archive"])
        let legacy = try #require(mapped.channels.first)
        #expect(legacy.isPinned)
        #expect(legacy.isUnread)
        #expect(legacy.preview == "Current work")
        #expect(legacy.displayTitle == "general")
        #expect(mapped.directory.summaries.first?.title == "general")
        #expect(mapped.channels.last?.isArchived == true)
        let ask = try #require(mapped.channels.first(where: { $0.id == "ask" }))
        #expect(ask.status == .waiting)
        #expect(ask.needsYou)
        #expect(ask.providerInstanceID == "codex-2")
        #expect(ask.model == "gpt-test")
        let fresh = try #require(mapped.channels.first(where: { $0.id == "fresh" }))
        #expect(fresh.displayTitle == "New space")
        #expect(fresh.providerInstanceID == "claude")
        #expect(fresh.model == "claude-test")
        #expect(legacy.providerInstanceID == nil && legacy.model == nil)
        #expect(T3ProjectionMapper.mostRecent(mapped.channels)?.id == "fresh")
        #expect(mapped.channels.allSatisfy { !$0.isMain })
        let anchored = try T3ProjectionMapper.directory(shells.list ?? [], profile: profile, observedAt: .distantPast, mainThreadID: "ask")
        #expect(anchored.channels.map(\.id) == ["ask", "legacy", "fresh", "archive"])
        #expect(anchored.channels.filter(\.isMain).map(\.id) == ["ask"])

        let nullPreviewShells = try t3JSON("""
        [{"id":"main","title":"#general","status":"idle","latestVisibleMessage":null,
          "latestRunCompletedAt":"2026-11-24T12:05:00Z","lastVisitedAt":"2026-11-24T12:00:00Z"}]
        """)
        let preview = try #require(ConversationPreview(message: ChatMessage(id: "m1", role: .assistant, text: "Hey Sree!")))
        let withFallback = try T3ProjectionMapper.directory(nullPreviewShells.list ?? [], profile: profile,
                                                            observedAt: .distantPast, previews: ["main": preview])
        #expect(withFallback.channels.first?.preview == "Hey Sree!")
        #expect(withFallback.channels.first?.isUnread == true)
    }

    /// T3 sends no message text with a space, and opening one marks it read.
    @Test func aSpaceRemembersItWasTalkedIn() throws {
        let shells = try t3JSON("""
        [{"id":"used","title":"Botto","status":"idle","latestVisibleMessage":null,"updatedAt":"2026-11-24T12:06:00Z",
          "latestUserMessageAt":"2026-11-24T12:00:00Z","lastVisitedAt":"2026-11-24T12:06:00Z"},
         {"id":"routine","title":"Botto","status":"idle","latestVisibleMessage":null,"updatedAt":"2026-11-24T12:05:00Z",
          "latestRunCompletedAt":"2026-11-24T12:00:00Z","latestUserMessageAt":null,"lastVisitedAt":"2026-11-24T12:06:00Z"},
         {"id":"fresh","title":"Botto","status":"idle","latestVisibleMessage":null,"updatedAt":"2026-11-24T12:04:00Z",
          "latestRunCompletedAt":null,"latestUserMessageAt":null,"lastVisitedAt":"2026-11-24T12:06:00Z"}]
        """)
        let spaces = try T3ProjectionMapper.directory(shells.list ?? [], profile: ExactID("project"), observedAt: .distantPast).channels
        #expect(spaces.map(\.id) == ["used", "routine", "fresh"])
        #expect(spaces.allSatisfy { !$0.isUnread && $0.preview.isEmpty })
        #expect(spaces.map(\.hasMessages) == [true, true, false])
        let cached = try JSONDecoder().decode([T3ChannelSummary].self, from: JSONEncoder().encode(spaces))
        #expect(cached == spaces)
        #expect(spaces[0].replacingPreview("Hi").replacingPreview("").hasMessages)
        let bot = BotProfile(id: "bot", name: "Botto")
        #expect(!T3FirstRun.needsBotSetup(bot, spaces: [spaces[0]]))
        #expect(T3FirstRun.needsBotSetup(bot, spaces: [spaces[2]]))
    }

    @Test func titleSeedsAreOneShortLine() {
        #expect(T3ProjectionMapper.titleSeed("  Plan\n the   Kyoto trip ") == "Plan the Kyoto trip")
        #expect(T3ProjectionMapper.titleSeed(" \n ") == nil)
        let long = T3ProjectionMapper.titleSeed(String(repeating: "word ", count: 40))
        #expect(long?.count == 50)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test func legacyCachesAndManifestsDecode() throws {
        let cached = Data(##"{"id":"a","title":"#general","isMain":true,"isPinned":false,"isArchived":false,"isUnread":false,"status":"idle","preview":""}"##.utf8)
        let channel = try JSONDecoder().decode(T3ChannelSummary.self, from: cached)
        #expect(channel.displayTitle == "general")
        #expect(channel.isMain)
        #expect(channel.replacingPreview("Hi").isMain)
        #expect(channel.model == nil)
        #expect(!channel.hasMessages)
        // Caches from before main spaces carry no isMain.
        let older = Data(##"{"id":"b","title":"New thread","isPinned":false,"isArchived":false,"isUnread":false,"status":"idle","preview":""}"##.utf8)
        let untitled = try JSONDecoder().decode(T3ChannelSummary.self, from: older)
        #expect(!untitled.isMain)
        #expect(untitled.displayTitle == "New space")
        let manifest = try JSONDecoder().decode(T3BotManifest.self, from: Data(#"{"displayName":"Old","mainThreadID":"general"}"#.utf8))
        #expect(manifest.description.isEmpty)
        #expect(manifest.mainThreadID == "general")
    }

    @Test func systemPromptTeachesLiveSpacesAndNamesNone() {
        let prompt = T3BotBootstrap.agentsMarkdown(T3BotManifest(displayName: "Kit", mainThreadID: "secret-main-id"))
        #expect(prompt.hasPrefix("# Kit\n"))
        for tool in ["t3_thread_list", "t3_thread_search", "t3_thread_read", "t3_thread_send", "create_threads",
                     "t3_thread_update", "t3_thread_organize"] {
            #expect(prompt.contains("`\(tool)`"))
        }
        for file in ["SOUL.md", "MEMORY.md", "skills/", "outputs/"] { #expect(prompt.contains("`\(file)`")) }
        #expect(prompt.contains("main space"))
        #expect(prompt.contains("Nothing about the current spaces is written in this file."))
        #expect(prompt.contains("always say \"space\""))
        // Only the manifest's name and description reach the prompt, so space, model and look changes keep it cached.
        #expect(!prompt.contains("secret-main-id"))
        #expect(prompt == T3BotBootstrap.agentsMarkdown(T3BotManifest(displayName: "Kit", providerInstanceID: "claude", model: "x")))
        #expect(T3BotBootstrap.claudeMarkdown(T3BotManifest(displayName: "Kit")) == prompt)
    }

    @Test func projectionMapsRequestsWorkAndLiveCompletion() throws {
        let source = try T3ProjectionMapper.identity(profile: ExactID("project"), threadID: "thread")
        let initial = try t3JSON("""
        {"thread":{"id":"thread"},"runs":[
          {"id":"old","status":"completed","ordinal":1,"completedAt":"2026-11-24T12:00:00Z"},
          {"id":"run","status":"running","ordinal":2,"startedAt":"2026-11-24T12:01:00Z"},
          {"id":"queued","status":"queued","ordinal":3,"userMessageId":"queued-message","queuePosition":1}],
         "messages":[{"id":"queued-message","text":"Next"}],
         "runtimeRequests":[{"id":"approval","kind":"command","status":"pending"},
                            {"id":"question","kind":"user_input","status":"pending"},
                            {"id":"secret","kind":"secret","status":"pending"}],
         "turnItems":[
           {"id":"u","type":"user_message","text":"Hello","runId":"run","ordinal":1},
           {"id":"r","type":"reasoning","streaming":true,"runId":"run","ordinal":2,"updatedAt":"2026-11-24T12:01:01Z"},
           {"id":"a","type":"approval_request","requestId":"approval","prompt":"Run tests?"},
           {"id":"secret-card","type":"secret_request","secretStatus":"pending","label":"API credential"},
           {"id":"q","type":"user_input_request","requestId":"question",
            "questions":[{"id":"language","header":"Language","question":"Which language?",
                          "options":[{"label":"Swift","value":"swift"}]}]}],
         "visibleTurnItems":[{"position":0,"item":{"id":"u","type":"user_message","text":"Hello","runId":"run","ordinal":1}}]}
        """)
        let lineage = UUID()
        var projection = T3ThreadProjection(snapshot: initial, sequence: 10, hasMoreHistory: false, lineage: lineage)
        #expect(projection.conversation(source).messages.map(\.text) == ["Hello"])
        #expect(projection.conversation(source).queuedMessages.first?.text == "Next")
        #expect(projection.pendingRequests.map(\.kind) == [.approval, .question, .unsupported, .unsupported])
        #expect(projection.pendingRequests.last?.id == "secret-card")
        #expect(projection.pendingRequests[1].choices == [RequestChoice(id: "swift", label: "Swift")])
        #expect(projection.activity.phase == .thinking)
        #expect(projection.activity.reaction == nil)

        projection.apply(try event("turn-item.updated", #"{"id":"c","type":"command_execution","status":"running","runId":"run","ordinal":3,"updatedAt":"2026-11-24T12:01:02Z"}"#), sequence: 11, live: true)
        #expect(projection.activity.phase == .tools)
        projection.apply(try event("turn-item.updated", #"{"id":"reply","type":"assistant_message","text":"Hi","streaming":true,"runId":"run","ordinal":4,"updatedAt":"2026-11-24T12:01:03Z"}"#), sequence: 12, live: true)
        #expect(projection.activity.phase == .replying)
        #expect(projection.conversation(source).messages.last?.text == "Hi")

        let completed = try event("run.updated", #"{"id":"run","status":"completed","ordinal":2,"completedAt":"2026-11-24T12:01:04Z"}"#)
        var failed = projection
        failed.apply(try event("run.updated", #"{"id":"run","status":"failed","ordinal":2,"completedAt":"2026-11-24T12:01:04Z"}"#),
                     sequence: 13, live: true)
        #expect(failed.activity.reaction?.kind == .failed)
        var replay = projection
        replay.apply(completed, sequence: 13, live: false)
        #expect(replay.activity.reaction == nil)
        projection.apply(completed, sequence: 13, live: true)
        #expect(projection.activity.reaction?.kind == .succeeded)
        #expect(projection.activity.phase == nil)
        let reaction = projection.activity.reaction
        projection.apply(completed, sequence: 13, live: true)
        #expect(projection.activity.reaction == reaction)
    }

    @Test func projectionResolvesDedupedTextOmittedMessages() throws {
        let source = try T3ProjectionMapper.identity(profile: ExactID("project"), threadID: "thread")
        let initial = try t3JSON("""
        {"thread":{"id":"thread"},"runs":[{"id":"run","status":"running","ordinal":1}],
         "messages":[{"id":"m1","role":"user","text":"Deduped prompt"}],
         "turnItems":[{"id":"u1","type":"user_message","messageId":"m1","text":"","textOmitted":true,"runId":"run","ordinal":1}],
         "visibleTurnItems":[{"position":0,"item":{"id":"u1","type":"user_message","messageId":"m1","text":"","textOmitted":true,"runId":"run","ordinal":1}}]}
        """)
        var projection = T3ThreadProjection(snapshot: initial, sequence: 1, hasMoreHistory: false, lineage: UUID())
        #expect(projection.conversation(source).messages.map(\.text) == ["Deduped prompt"])
        projection.apply(try event("message.updated", #"{"id":"m2","role":"assistant","text":"Deduped answer"}"#), sequence: 2, live: true)
        projection.apply(try event("turn-item.updated", #"{"id":"a1","type":"assistant_message","messageId":"m2","text":"","textOmitted":true,"streaming":true,"runId":"run","ordinal":2}"#), sequence: 3, live: true)
        #expect(projection.conversation(source).messages.map(\.text) == ["Deduped prompt", "Deduped answer"])
        #expect(projection.activity.signal?.kind == .replyText)
    }

    @Test func liveTimelineOrdersLocalTurnsAndHidesRolledBackOrUndeliveredRows() throws {
        let source = try T3ProjectionMapper.identity(profile: ExactID("project"), threadID: "thread")
        let initial = try t3JSON("""
        {"thread":{"id":"thread"},
         "runs":[{"id":"old","status":"completed","ordinal":1},{"id":"current","status":"running","ordinal":2}],
         "visibleTurnItems":[
           {"position":0,"visibility":"inherited","item":{"id":"parent","type":"assistant_message","text":"Shared context","runId":"old","ordinal":1000}},
           {"position":1,"visibility":"local","item":{"id":"prompt","type":"user_message","text":"Current prompt","runId":"current","ordinal":200}},
           {"position":2,"visibility":"local","item":{"id":"answer","type":"assistant_message","text":"Current answer","runId":"current","ordinal":220}}]}
        """)
        var projection = T3ThreadProjection(snapshot: initial, sequence: 1, hasMoreHistory: true, lineage: UUID())
        projection.apply(try event("turn-item.updated", #"{"id":"active","type":"assistant_message","text":"Unfinished work","runId":"current","ordinal":100}"#), sequence: 2, live: true)
        projection.apply(try event("turn-item.updated", #"{"id":"late","type":"assistant_message","text":"Older work","runId":"old","ordinal":110}"#), sequence: 3, live: true)
        projection.apply(try event("turn-item.updated", #"{"id":"early","type":"assistant_message","text":"First reply","runId":"current","ordinal":210}"#), sequence: 4, live: true)
        #expect(projection.conversation(source).messages.map(\.text) == ["Shared context", "Unfinished work", "Current prompt", "First reply", "Current answer"])

        projection.apply(try event("run.created", #"{"id":"queued","status":"queued","ordinal":3}"#), sequence: 5, live: true)
        projection.apply(try event("turn-item.updated", #"{"id":"held","type":"user_message","inputIntent":"queued_turn","text":"Never delivered","runId":"queued","ordinal":300}"#), sequence: 6, live: true)
        projection.apply(try event("run.updated", #"{"id":"queued","status":"cancelled","ordinal":3,"startedAt":null}"#), sequence: 7, live: true)
        #expect(!projection.conversation(source).messages.contains { $0.text == "Never delivered" })

        projection.apply(try event("run.updated", #"{"id":"current","status":"rolled_back","ordinal":2}"#), sequence: 8, live: true)
        #expect(projection.conversation(source).messages.map(\.text) == ["Shared context"])
    }

    @Test func aSnapshotsVisitMarkIsTheNewestHostTimeItShows() throws {
        let source = try T3ProjectionMapper.identity(profile: ExactID("project"), threadID: "thread")
        let initial = try t3JSON("""
        {"thread":{"id":"thread"},
         "runs":[{"id":"run","status":"completed","ordinal":1,"completedAt":"2026-11-24T12:00:03.250Z"}],
         "visibleTurnItems":[
           {"position":0,"item":{"id":"prompt","type":"user_message","text":"Hi","runId":"run","ordinal":1,"updatedAt":"2026-11-24T12:00:01.000Z"}},
           {"position":1,"item":{"id":"answer","type":"assistant_message","text":"Hello","runId":"run","ordinal":2,"updatedAt":"2026-11-24T12:00:03.100Z"}}]}
        """)
        var projection = T3ThreadProjection(snapshot: initial, sequence: 1, hasMoreHistory: false, lineage: UUID())
        // The host's unread mark compares the run's completion, which follows its reply's last update.
        #expect(projection.conversation(source).visitMark?.hostTime == "2026-11-24T12:00:03.250Z")
        projection.apply(try event("run.created", #"{"id":"next","status":"running","ordinal":2}"#), sequence: 2, live: true)
        projection.apply(try event("turn-item.updated", #"{"id":"next","type":"user_message","text":"Again","runId":"next","ordinal":3,"updatedAt":"2026-11-24T12:00:07.000Z"}"#), sequence: 3, live: true)
        #expect(projection.conversation(source).visitMark?.hostTime == "2026-11-24T12:00:07.000Z")
        projection.apply(try event("run.created", #"{"id":"queued","status":"queued","ordinal":3}"#), sequence: 4, live: true)
        projection.apply(try event("turn-item.updated", #"{"id":"held","type":"user_message","inputIntent":"queued_turn","text":"Later","runId":"queued","ordinal":4,"updatedAt":"2026-11-24T12:00:09.000Z"}"#), sequence: 5, live: true)
        #expect(projection.conversation(source).visitMark?.hostTime == "2026-11-24T12:00:07.000Z", "A held prompt isn't shown")
        projection.apply(try event("run.updated", #"{"id":"queued","status":"cancelled","ordinal":3,"startedAt":null,"completedAt":"2026-11-24T12:00:10.000Z"}"#), sequence: 6, live: true)
        #expect(projection.conversation(source).isWorking)
        #expect(projection.conversation(source).visitMark?.hostTime == "2026-11-24T12:00:07.000Z",
                "A queued cancellation does not supersede the run that is still working")
        projection.apply(try event("run.updated", #"{"id":"next","status":"completed","ordinal":2,"completedAt":"2026-11-24T12:00:11.000Z"}"#), sequence: 7, live: true)
        #expect(projection.conversation(source).visitMark?.hostTime == "2026-11-24T12:00:11.000Z")
    }

    @Test(arguments: ["cancelled", "rolled_back"])
    func reopeningASettledSpaceVisitsThroughItsTerminalChange(status: String) throws {
        let profile = try ExactID("project")
        let source = try T3ProjectionMapper.identity(profile: profile, threadID: "thread")
        let initial = try t3JSON("""
        {"thread":{"id":"thread"},
         "runs":[{"id":"earlier","status":"completed","ordinal":1,"completedAt":"2026-11-24T12:00:05.000Z"},
                 {"id":"latest","status":"\(status)","ordinal":2,"startedAt":null,"completedAt":"2026-11-24T12:00:10.000Z"}],
         "visibleTurnItems":[]}
        """)
        let projection = T3ThreadProjection(snapshot: initial, sequence: 1, hasMoreHistory: false, lineage: UUID())
        let opened = projection.conversation(source)
        #expect(!opened.isWorking)
        #expect(opened.messages.isEmpty)
        let mark = try #require(opened.visitMark)

        func unread(afterVisit time: String) throws -> Bool {
            let shell = try t3JSON("""
            {"id":"thread","status":"\(status)","latestRunCompletedAt":"2026-11-24T12:00:10.000Z","lastVisitedAt":"\(time)"}
            """)
            let directory = try T3ProjectionMapper.directory([shell], profile: profile, observedAt: .distantPast)
            return try #require(directory.channels.first).isUnread
        }
        #expect(try unread(afterVisit: "2026-11-24T12:00:05.000Z"))
        #expect(try !unread(afterVisit: mark.hostTime))
    }

    @Test func deliveryRestoresHeldPromptLoadedInSnapshot() throws {
        let source = try T3ProjectionMapper.identity(profile: ExactID("project"), threadID: "thread")
        let initial = try t3JSON("""
        {"thread":{"id":"thread"},"runs":[{"id":"queued","status":"queued","ordinal":1}],
         "turnItems":[{"id":"held","type":"user_message","inputIntent":"queued_turn","text":"Held","runId":"queued","ordinal":100}],
         "visibleTurnItems":[]}
        """)
        var projection = T3ThreadProjection(snapshot: initial, sequence: 1, hasMoreHistory: false, lineage: UUID())
        #expect(projection.conversation(source).messages.isEmpty)
        projection.apply(try event("run.updated", #"{"id":"queued","status":"preparing","ordinal":1}"#), sequence: 2, live: true)
        #expect(projection.conversation(source).messages.map(\.text) == ["Held"])
    }

    private func event(_ type: String, _ payload: String) throws -> JSONValue {
        try t3JSON("""
        {"id":"event-\(type)","threadId":"thread","type":"\(type)","occurredAt":"2026-11-24T12:01:04Z","payload":\(payload)}
        """)
    }
}

func t3JSON(_ source: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
}
