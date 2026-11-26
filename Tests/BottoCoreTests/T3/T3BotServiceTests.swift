import Foundation
import Testing
@testable import BottoCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct T3BotServiceTests {
    enum ConnectionLoss: Sendable { case socket, shell, thread }

    @Test func refusesReplacementForASavedProject() async throws {
        let host = T3ServiceHost(existing: true)
        var saved = try existingConfiguration()
        saved.t3?.projectID = "deleted-project"
        saved.t3?.workspaceRoot = "/host/.botto/bots/main"
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        await #expect(throws: T3ServiceError.differentWorkspace) { try await service.connect(configuration: saved) }
        #expect(service.currentBotWorkspaceRoot == nil)
        #expect(await host.writtenFiles.isEmpty)
    }

    @Test func refusesAProjectRemovedBeforeTheFirstShellSnapshot() async throws {
        let host = T3ServiceHost(existing: true)
        await host.omitProjectFromShell()
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        await #expect(throws: T3ServiceError.differentWorkspace) {
            try await service.connect(configuration: existingConfiguration())
        }
        #expect(service.currentBotWorkspaceRoot == nil)
        #expect(await host.writtenFiles.isEmpty)
    }

    @Test func explicitPairingRecreatesADeletedProjectWithANewIdentity() async throws {
        let host = T3ServiceHost()
        await host.replayDeletedProjectOnFirstCreate()
        var configuration = try existingConfiguration()
        configuration.t3?.projectID = nil
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }

        _ = try await service.connect(configuration: configuration)
        let requests = await host.projectCreations
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let replacement = try #require(requests.last)
        #expect(replacement["projectId"] != first["projectId"])
        #expect(replacement["commandId"] != first["commandId"])
        #expect(replacement["workspaceRoot"].text == "/host/.botto/bots/main")
        #expect(try await service.bots().first?.id == replacement["projectId"].text)
        #expect(service.currentT3Channels.first(where: \.isMain) != nil)
    }

    @Test func retiresLiveWorkspaceOnRootChangeOrRemoval() async throws {
        for changedRoot in [true, false] {
            let host = T3ServiceHost(existing: true)
            let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host },
                                       reconnectDelays: [.zero])
            defer { service.disconnect() }
            let (events, observer) = AsyncStream<BotServiceEvent>.makeStream()
            service.onEvent = { observer.yield($0) }
            _ = try await service.connect(configuration: existingConfiguration())
            try await host.changeSavedProject(rootChanged: changedRoot)
            for await event in events {
                if case .disconnected = event { break }
                if case .configuration(let updated) = event {
                    #expect(updated.t3?.workspaceRoot == "/host/.botto/bots/main")
                }
            }
            #expect(service.currentBotWorkspaceRoot == nil)
            await #expect(throws: T3ServiceError.disconnected) { try await service.saveSoul("Must not move") }
            #expect(await host.ticketAttempts == 1)
        }
    }

    @Test func lostCommandAcknowledgementUsesSharedUncertainty() async throws {
        let host = T3ServiceHost(existing: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host }, reconnectDelays: [])
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        await host.loseNextCommandAcknowledgement()
        await #expect(throws: ConversationServiceError.uncertain) {
            try await service.setChannelPinned(threadID: "existing-general", pinned: true)
        }
        let state = await host.state
        #expect(state.threads["existing-general"]?["pinnedAt"] != .null)
    }

    @Test func refusesAProseSaveAfterTheHostFileChanges() async throws {
        let host = T3ServiceHost(existing: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        let loaded = try await service.loadBotBrain().memoryMarkdown
        let draft = loaded + "\nMy new note."
        let hostText = loaded + "\nBotto’s new note."
        await host.write("MEMORY.md", hostText)

        await #expect(throws: T3ServiceError.proseChanged) { try await service.saveMemory(draft, replacing: loaded) }
        #expect(try await service.readProjectFile(relativePath: "MEMORY.md") == hostText)
        #expect(await !host.writtenFiles.contains("MEMORY.md"))
        #expect(draft == loaded + "\nMy new note.")
    }

    @Test func modelChangeMergesWithProfileEditsAndClearsSavedEffectiveChoice() async throws {
        let host = T3ServiceHost(existing: true)
        var saved = try existingConfiguration()
        saved.t3?.providerInstanceID = "previous"
        saved.t3?.model = "previous-model"
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: saved)
        let model = try #require(try await service.availableModels().first)
        let bot = try #require(try await service.bots().first)
        _ = try await service.updateProfile(.init(name: "Kit"), for: bot)
        try await service.setDefaultModel(model)
        #expect(try await service.loadBotBrain().manifest.displayName == "Kit")
        #expect(try await service.loadBotBrain().manifest.model == model.modelID)

        try await service.setDefaultModel(nil)
        #expect(try await service.loadBotBrain().manifest.model == nil)
        _ = try await service.createChat(title: "Automatic")
        #expect(await host.createdThreads.last?["modelSelection"]["model"].text == model.modelID)
    }

    @Test(arguments: [ConnectionLoss.socket, .shell, .thread])
    func reconnectsAndReattachesSelectedChannel(after loss: ConnectionLoss) async throws {
        let host = T3ServiceHost(existing: true, archivedChannel: true, ticketStatuses: [200, 503, 200])
        let recoveredHost = T3ServiceHost(existing: true, archivedChannel: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { request in
            request.url?.absoluteString.contains("reconnect-ticket") == true ? recoveredHost : host
        }, reconnectDelays: [.milliseconds(1), .milliseconds(5)])
        let (events, observe) = AsyncStream<BotServiceEvent>.makeStream()
        service.onEvent = { observe.yield($0) }
        defer { service.disconnect() }
        let info = try await service.connect(configuration: existingConfiguration())
        let profile = try ExactID("bot-project")
        let directory = try await service.conversations(profile: profile)
        let identity = try #require(directory.summaries.first { $0.identity.stored.text == "archived-channel" }?.identity)
        let originallyOpened = try await service.openChat(.stored(identity))
        var published = events.makeAsyncIterator()
        while let event = await published.next(isolation: MainActor.shared) {
            if case .connected = event { break }
        }

        switch loss {
        case .socket: await host.dropSocket()
        case .shell: try await host.endShellStream()
        case .thread: try await host.endThreadStream("archived-channel")
        }
        var sawDisconnect = false
        while let event = await published.next(isolation: MainActor.shared) {
            if case .disconnected = event { sawDisconnect = true }
            if case .connected(let reconnected) = event {
                #expect(sawDisconnect)
                #expect(reconnected == info)
                break
            }
        }
        let reattached = try await nextConversation(&published) { $0.identity == identity }
        #expect(reattached.access != originallyOpened.access)
        #expect(await host.ticketAttempts == 3)
        #expect(await recoveredHost.threadSubscriptions == ["archived-channel"])
        await #expect(throws: ConversationServiceError.staleConversation) {
            try await service.stop(access: originallyOpened.access, operationID: UUID())
        }
    }

    @Test(arguments: [true, false]) func stopsReconnectForAuthFailureOrExplicitDisconnect(authFailure: Bool) async throws {
        let host = T3ServiceHost(existing: true, ticketStatuses: [200, 401])
        let delay = authFailure ? Duration.milliseconds(5) : .milliseconds(75)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host },
                                   reconnectDelays: [delay, .milliseconds(5)])
        let (events, observe) = AsyncStream<BotServiceEvent>.makeStream()
        service.onEvent = { observe.yield($0) }
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())

        await host.dropSocket()
        var published = events.makeAsyncIterator()
        while let event = await published.next(isolation: MainActor.shared) {
            guard case .disconnected(let reason) = event else { continue }
            if !authFailure {
                service.disconnect()
                break
            }
            if reason.contains("HTTP 401") { break }
        }
        try await Task.sleep(for: delay + .milliseconds(25))
        #expect(await host.ticketAttempts == (authFailure ? 2 : 1))
        await #expect(throws: T3ServiceError.disconnected) { try await service.bots() }
    }

    private func existingConfiguration() throws -> ConnectionConfiguration {
        let origin = try #require(URL(string: "https://t3.example"))
        let connection = T3Connection(environmentID: "environment", accessToken: "bearer", projectID: "bot-project")
        return .init(serverURL: origin, t3: connection)
    }

    @Test func observesPushActivityInABottoSpaceWithoutOpeningItsChat() async throws {
        let host = T3ServiceHost(existing: true, archivedChannel: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        let (activities, observed) = AsyncStream<T3PushActivity>.makeStream()
        service.onPushActivity = { observed.yield($0) }
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())

        let deadline = ContinuousClock.now + .seconds(3)
        while await host.threadSubscriptions.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await host.threadSubscriptions == ["existing-general"])
        try await host.completeForPush("existing-general", id: "blocked-run", holding: true)
        try await host.completeForPush("existing-general")
        let activity = try #require(await firstActivity(activities))
        #expect(activity.scope == T3PushScope(environmentID: "environment", projectID: "bot-project"))
        #expect(activity.spaceID == "existing-general")
        #expect(activity.id == "fixture-routine-run")
        #expect(activity.kind == .reply)
    }

    @Test func workflowStepsStayOutOfSpacesDirectoryAndPushSubscriptions() async throws {
        let host = T3ServiceHost(existing: true)
        try await host.addWorkflowStep("workflow-active")
        try await host.addWorkflowStep("workflow-archived", archived: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        let (activities, observed) = AsyncStream<T3PushActivity>.makeStream()
        service.onPushActivity = { observed.yield($0) }
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())

        #expect(service.currentT3Channels.map(\.id) == ["existing-general"])
        let bot = try #require(try await service.bots().first)
        let profile = try ExactID(bot.id)
        let directory = try await service.conversations(profile: profile)
        #expect(directory.summaries.map { $0.identity.stored.text } == ["existing-general"])

        try await host.addWorkflowStep("workflow-live")
        try await host.completeForPush("existing-general")
        let activity = try #require(await firstActivity(activities))
        #expect(activity.spaceID == "existing-general")
        #expect(service.currentT3Channels.map(\.id) == ["existing-general"])
        #expect(await host.threadSubscriptions == ["existing-general"])
    }

    private func firstActivity(_ activities: AsyncStream<T3PushActivity>) async -> T3PushActivity? {
        await withTaskGroup(of: T3PushActivity?.self) { group in
            group.addTask {
                var iterator = activities.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    @Test func openingAndExplicitlyVisitingDispatchReadWatermarks() async throws {
        let host = T3ServiceHost(existing: true, withholdFirstVisitReply: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        var visits = host.visits.makeAsyncIterator()
        let profile = try ExactID("bot-project")
        let opened = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
        #expect(opened.identity.stored.text == "existing-general")
        let automatic = try #require(await visits.next(isolation: MainActor.shared))
        try await host.rejectFirstVisit()
        try await service.markChannelVisited(threadID: "existing-general")
        let explicit = try #require(await visits.next(isolation: MainActor.shared))
        for command in [automatic, explicit] {
            #expect(command["type"].text == "thread.visit")
            #expect(command["threadId"].text == "existing-general")
            #expect(command["opened"].flag == true)
            let visitedAt = try #require(command["visitedAt"].text)
            #expect(visitedAt.hasSuffix("Z"))
            #expect(T3PairingExchange.date(visitedAt) != nil)
        }
    }

    @Test func sendsChannelModelSelectionToT3() async throws {
        let host = T3ServiceHost(existing: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())

        try await service.setChannelModel(threadID: "existing-general", providerInstanceID: "codex-2", model: "gpt-test")
        let commands = await host.modelCommands
        #expect(commands.count == 1)
        let command = try #require(commands.first)
        #expect(command["type"].text == "thread.model-selection.set")
        #expect(command["threadId"].text == "existing-general")
        #expect(command["modelSelection"] == .object(["instanceId": .string("codex-2"), "model": .string("gpt-test")]))
    }

    @Test func listsAndDownloadsWorkspaceOutputsWithoutOpeningAChannel() async throws {
        let host = T3ServiceHost(existing: true)
        let service: any T3BotBrainControlling = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        #expect(try await service.listOutputs().isEmpty)
        #expect(await host.listedDirectories == [""])

        await host.addOutputs()
        let outputs = try await service.listOutputs()
        #expect(outputs.map(\.id) == ["outputs/nested/guide.PDF", "outputs/report.txt", "outputs/unknown.bin"])
        #expect(outputs.map(\.name) == ["guide.PDF", "report.txt", "unknown.bin"])
        #expect(outputs.map(\.mimeType) == ["application/pdf", "text/plain", "application/octet-stream"])
        let file = try #require(outputs.first)
        let artifact = try await service.downloadOutput(file)
        #expect(artifact == DownloadedArtifact(data: Data([0x25, 0x50, 0x44, 0x46, 0, 0xff]),
                                              filename: "guide.PDF", mimeType: "application/pdf"))
        #expect(await host.threadSubscriptions.isEmpty)
        let traversal = T3OutputFile(name: "outside.txt", relativePath: "outputs/../outside.txt", mimeType: "text/plain")
        await #expect(throws: T3ServiceError.invalidPath) { try await service.downloadOutput(traversal) }
    }

    @Test func workflowRoutineProposalStaysOffAndBelongsToAnActiveSpace() async throws {
        let host = T3ServiceHost(existing: true, archivedChannel: true, workflowsEnabled: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        let writes = await host.writtenFiles
        let schedule = try #require(T3RoutineSchedule(hour: 9, minute: 15, days: [1, 3]))

        let proposal = try service.proposeWorkflowRoutine(name: " Check the plan ", prompt: "Review the latest notes.",
                                                          schedule: schedule, threadID: "existing-general")
        #expect(proposal.name == "Check the plan")
        #expect(proposal.threadID == "existing-general")
        #expect(proposal.schedule == schedule)
        #expect(await host.writtenFiles == writes)
        #expect(await host.createdThreads.isEmpty)
        #expect(await host.routineUpserts.isEmpty)
        #expect(throws: ConversationServiceError.wrongConversation) {
            try service.proposeWorkflowRoutine(name: "Check the plan", prompt: "Review the latest notes.",
                                               schedule: schedule, threadID: "archived-channel")
        }
    }

    @Test func turningOnAWorkflowRoutinePublishesItOnce() async throws {
        let host = T3ServiceHost(existing: true, workflowsEnabled: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        let schedule = try #require(T3RoutineSchedule(hour: 9, minute: 15, days: [3, 1]))
        let proposal = try service.proposeWorkflowRoutine(name: "Check the plan", prompt: "Review the latest notes.",
                                                          schedule: schedule, threadID: "existing-general")
        #expect(await host.workflowWrites.isEmpty)
        await host.warnOnNextWorkflowSave("An unrelated workflow could not load.")
        let installed = try await service.turnOnWorkflowRoutine(proposal)
        #expect(installed.proposal == proposal)
        #expect(installed.enabled)
        #expect(try await service.turnOnWorkflowRoutine(proposal) == installed)
        #expect(try await service.listWorkflowRoutines() == [installed])
        let writes = await host.workflowWrites
        #expect(writes.count == 1)
        let write = try #require(writes.first)
        #expect(write["name"].text == "botto-routine-\(proposal.id.uuidString.lowercased()).ts")
        #expect(write["source"].text?.contains(#"T3.daily("09:15", { weekdays: [1,3] })"#) == true)
        #expect(await host.routineUpserts.isEmpty)
        #expect(await host.createdThreads.isEmpty)
    }

    @Test func pausingAndDeletingWorkflowRoutinesLeavesTheirSpaceAndLegacyTasks() async throws {
        let host = T3ServiceHost(existing: true, workflowsEnabled: true)
        try await host.seedRoutines()
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        let schedule = try #require(T3RoutineSchedule(hour: 9, minute: 15, days: [3]))
        let proposal = try service.proposeWorkflowRoutine(name: "Check the plan", prompt: "Review the notes.",
                                                          schedule: schedule, threadID: "existing-general")
        let active = try await service.turnOnWorkflowRoutine(proposal)
        let paused = try await service.setWorkflowRoutineEnabled(active, enabled: false)
        #expect(!paused.enabled)
        #expect(try await service.setWorkflowRoutineEnabled(active, enabled: false) == paused)
        #expect(try await service.listWorkflowRoutines() == [paused])
        await #expect(throws: T3WorkflowRoutineError.changed) { try await service.deleteWorkflowRoutine(active) }

        try await service.deleteWorkflowRoutine(paused)
        try await service.deleteWorkflowRoutine(paused)
        #expect(try await service.listWorkflowRoutines().isEmpty)
        #expect(await host.workflowWrites.count == 2)
        #expect(await host.workflowDeletes.count == 1)
        #expect(try await service.listRoutines().map(\.id) == ["once-task"])
        #expect(service.currentT3Channels.map(\.id) == ["existing-general"])
    }

    @Test func workflowRoutineQuestionsBelongToTheLinkedSpace() async throws {
        let host = T3ServiceHost(existing: true, archivedChannel: true, workflowsEnabled: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        let schedule = try #require(T3RoutineSchedule(hour: 9, minute: 15, days: [3]))
        let proposal = try service.proposeWorkflowRoutine(name: "Check the plan", prompt: "Review the notes.",
                                                          schedule: schedule, threadID: "existing-general")
        _ = try await service.turnOnWorkflowRoutine(proposal)
        let workflow = "botto-routine-\(proposal.id.uuidString.lowercased())"
        try await host.seedWorkflowQuestions(workflow: workflow)
        let activities = try await service.workflowRoutineActivity(threadID: "existing-general")
        #expect(activities.map(\.id) == ["own-run"])
        let question = try #require(activities.first?.question)
        #expect(question.choices == ["Run", "Skip"])
        #expect(try await service.workflowRoutineActivity(threadID: "archived-channel").isEmpty)
        let profile = try ExactID("bot-project")
        let linked = try T3ProjectionMapper.identity(profile: profile, threadID: "existing-general")
        let other = try T3ProjectionMapper.identity(profile: profile, threadID: "archived-channel")
        let unrelated = try await service.openChat(.stored(other))
        await #expect(throws: ConversationServiceError.wrongConversation) {
            try await service.answerWorkflowRoutineQuestion(question, choice: "Skip", access: unrelated.access)
        }
        let opened = try await service.openChat(.stored(linked))
        await #expect(throws: T3WorkflowRoutineError.questionChanged) {
            try await service.answerWorkflowRoutineQuestion(question, choice: "Delete", access: opened.access)
        }

        var snapshots = await host.holdNextWorkflowSnapshot().makeAsyncIterator()
        let pendingAnswer = Task { try await service.answerWorkflowRoutineQuestion(question, choice: "Run", access: opened.access) }
        _ = try #require(await snapshots.next(isolation: MainActor.shared))
        _ = try await service.openChat(.stored(other))
        try await host.releaseWorkflowSnapshot()
        await #expect(throws: ConversationServiceError.staleConversation) { try await pendingAnswer.value }
        #expect(await host.workflowAnswers.isEmpty)

        let reopened = try await service.openChat(.stored(linked))
        try await service.answerWorkflowRoutineQuestion(question, choice: "Skip", access: reopened.access)
        let completed = try await service.workflowRoutineActivity(threadID: "existing-general")
        #expect(completed.first?.question == nil)
        #expect(completed.first?.result == "Skipped")
        await #expect(throws: T3WorkflowRoutineError.questionChanged) {
            try await service.answerWorkflowRoutineQuestion(question, choice: "Skip", access: reopened.access)
        }
        #expect(await host.workflowAnswers.map { $0["runId"].text } == ["own-run"])
    }

    @Test func managesProjectRoutinesThroughT3ScheduledTasks() async throws {
        let host = T3ServiceHost(existing: true, archivedChannel: true)
        try await host.seedRoutines()
        let service: any T3BotBrainControlling = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        let initial = try await service.listRoutines()
        #expect(initial.map(\.id) == ["once-task"])
        await #expect(throws: T3ServiceError.invalidResponse) {
            try await service.setRoutineEnabled(id: "other-task", enabled: false)
        }
        await #expect(throws: T3ServiceError.invalidResponse) {
            try await service.deleteRoutine(id: "other-task")
        }
        let existing = try #require(initial.first)
        #expect(existing.id == "once-task")
        #expect(existing.schedule == nil)
        #expect(existing.lastRunAt == T3PairingExchange.date("2026-11-24T12:00:00Z"))

        let daily = try #require(T3RoutineSchedule(hour: 9, minute: 0))
        let morning = try await service.createRoutine(name: "Morning brief", prompt: "Summarize inbox",
                                                      schedule: daily, threadID: nil)
        #expect(morning.name == "Morning brief")
        #expect(morning.prompt == "Summarize inbox")
        #expect(morning.enabled)
        #expect(morning.schedule == daily)
        // Without a space, a routine gets its own, named after it.
        let routineChat = try #require(await host.createdThreads.last)
        #expect(await host.createdThreads.count == 1)
        #expect(routineChat["title"].text == "Morning brief")
        #expect(routineChat["titleRenamed"].flag == true)
        #expect(morning.threadID == routineChat["threadId"].text)
        #expect(service.currentT3Channels.first { $0.id == morning.threadID }?.displayTitle == "Morning brief")
        #expect(morning.nextRunAt == T3PairingExchange.date("2026-11-25T09:00:00.000Z"))
        #expect(morning.lastRunAt == nil)

        try await service.archiveChannel(threadID: "archived-channel", archived: false)
        let workdays = try #require(T3RoutineSchedule(hour: 17, minute: 30, days: T3RoutineSchedule.weekdays))
        let weekdays = try await service.createRoutine(name: "Build report", prompt: "Summarize builds",
                                                       schedule: workdays, threadID: "archived-channel")
        #expect(weekdays.threadID == "archived-channel")
        #expect(weekdays.schedule == workdays)
        let payloads = await host.routineUpserts
        #expect(payloads.count == 2)
        #expect(payloads.first?["schedule"] == .object(["type": .string("fixed_time"), "timeOfDay": .string("09:00")]))
        #expect(payloads.last?["schedule"] == .object([
            "type": .string("fixed_time"), "timeOfDay": .string("17:30"), "weekdays": .array([1, 2, 3, 4, 5].map { .number($0) })
        ]))

        try await service.setRoutineEnabled(id: morning.id, enabled: false)
        let afterDisable = try await service.listRoutines()
        #expect(Set(afterDisable.map(\.id)) == [morning.id, weekdays.id, existing.id])
        #expect(afterDisable.first { $0.id == morning.id }?.enabled == false)

        try await service.deleteRoutine(id: morning.id)
        let afterDelete = try await service.listRoutines()
        #expect(Set(afterDelete.map(\.id)) == [weekdays.id, existing.id])
        #expect(await host.interruptedRoutineStreams >= 3)
    }

    @Test func fixedRoutineSchedulesRequireADayAndAValidTime() {
        #expect(T3RoutineSchedule(hour: 9, minute: 0, days: []) == nil)
        #expect(T3RoutineSchedule(hour: 9, minute: 0, days: [7]) == nil)
        #expect(T3RoutineSchedule(hour: 24, minute: 0) == nil)
        #expect(T3RoutineSchedule(hour: 9, minute: 60) == nil)
        #expect(T3RoutineSchedule(hour: 0, minute: 5, days: [0])?.days == [0])
    }

    @Test func lostRoutineAcknowledgementReportsAnUncertainCreation() async throws {
        let host = T3ServiceHost(existing: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        await host.loseNextRoutineAcknowledgement()
        let schedule = try #require(T3RoutineSchedule(hour: 9, minute: 0))
        await #expect(throws: ConversationServiceError.uncertain) {
            try await service.createRoutine(name: "Morning brief", prompt: "Summarize inbox",
                                            schedule: schedule, threadID: nil)
        }
        #expect(await host.routineUpserts.count == 1)
        #expect(await host.createdThreads.count == 1)
    }

    @Test func bootstrapsOneBotAndRunsAChannelThroughTheService() async throws {
        let host = T3ServiceHost()
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { request in
            #expect(request.url?.absoluteString == "wss://t3.example/ws?orchestrationProtocol=2&wsTicket=short%2Bticket")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return host
        })
        let (events, observe) = AsyncStream<BotServiceEvent>.makeStream()
        service.onEvent = { observe.yield($0) }
        defer { service.disconnect() }
        var published = events.makeAsyncIterator()
        let base = try #require(URL(string: "https://t3.example"))
        let configuration = ConnectionConfiguration(serverURL: base, t3: T3Connection(environmentID: "", accessToken: "bearer"))
        #expect(try await service.connect(configuration: configuration) == ServerInfo(version: "2.4", installID: "environment"))
        if case .configuration(let saved) = await published.next(isolation: MainActor.shared) {
            #expect(saved.t3?.environmentID == "environment")
            #expect(saved.t3?.projectID == "bot-project")
            #expect(saved.t3?.workspaceRoot == "/host/.botto/bots/main")
            #expect(saved.t3?.model == "claude-test")
        } else { Issue.record("Expected the resolved connection to be published") }

        let roster = try await service.bots()
        let bot = try #require(roster.first)
        #expect(roster.count == 1)
        #expect(bot.name == "Botto")
        let brain = try await service.loadBotBrain()
        // Connecting gives a new bot its main space, named after it.
        let mainCreation = try #require(await host.createdThreads.last)
        #expect(await host.createdThreads.count == 1)
        #expect(mainCreation["title"].text == "Botto")
        #expect(mainCreation["titleRenamed"].flag == true)
        let mainID = try #require(brain.manifest.mainThreadID)
        #expect(mainCreation["threadId"].text == mainID)
        #expect(service.currentT3Channels.map(\.id) == [mainID])
        #expect(service.currentT3Channels.first?.isMain == true)
        #expect(service.currentT3Channels.first?.displayTitle == "Botto")
        #expect(brain.skills == ["skills/check"])
        #expect(brain.soulMarkdown == T3BotBootstrap.soulMarkdown)
        let instructions = try await service.readProjectFile(relativePath: "AGENTS.md")
        for path in ["SOUL.md", "MEMORY.md", "skills/", "outputs/"] { #expect(instructions.contains(path)) }
        #expect(try await service.readProjectFile(relativePath: "CLAUDE.md") == instructions)
        #expect(try await service.availableModels().map(\.modelID) == ["claude-test"])
        await #expect(throws: T3ServiceError.invalidPath) { try await service.readProjectFile(relativePath: "../outside") }

        try await service.saveSoul("Be curious.")
        try await service.saveMemory("The first channel is for tests.")
        var manifest = brain.manifest
        manifest.description = "Builds tools"
        // The service owns the main space, so an edit that lost its ID keeps it.
        manifest.mainThreadID = nil
        try await service.saveManifest(manifest)
        let updated = try await service.updateProfile(.init(name: "Builder"), for: bot)
        #expect(updated.name == "Builder")
        let avatar = try await service.setAvatar(.shape(.circle), for: updated)
        #expect(avatar.appearance?.shape == .circle)
        let savedBrain = try await service.loadBotBrain()
        #expect(savedBrain.manifest.description == "Builds tools")
        #expect(savedBrain.manifest.mainThreadID == mainID)
        #expect(savedBrain.soulMarkdown == "Be curious.")
        #expect(savedBrain.memoryMarkdown == "The first channel is for tests.")
        #expect(try await service.readProjectFile(relativePath: "CLAUDE.md").contains("# Builder"))

        let profile = try ExactID(bot.id)
        // Renaming the bot leaves the main space's name to the user.
        #expect(service.currentT3Channels.map(\.displayTitle) == ["Botto"])
        let channel = try await service.createChat(title: nil)
        let identity = channel.summary.identity
        let channelID = identity.stored.text
        let creation = try #require(await host.createdThreads.last)
        #expect(creation["title"].text == "New thread")
        #expect(creation["titleRenamed"].flag == false)
        #expect(service.currentT3Channels.map(\.displayTitle) == ["Botto", "New space"])
        let listing = try await service.conversations(profile: profile)
        #expect(listing.summaries.map(\.identity.stored.text) == [mainID, channelID])
        #expect(listing.summaries.allSatisfy { !$0.isCanonical })
        let firstOpen = try await service.openChat(.stored(identity))
        #expect(firstOpen.snapshot.messages.isEmpty)
        #expect(firstOpen.activity?.reaction == nil)

        let upload = try await service.upload(data: Data("file bytes".utf8), filename: "note.txt",
                                              mimeType: "text/plain", access: firstOpen.access)
        let mainIdentity = try T3ProjectionMapper.identity(profile: profile, threadID: mainID)
        let otherSpace = try await service.openChat(.stored(mainIdentity))
        await #expect(throws: ConversationServiceError.invalidAttachment) {
            try await service.send(text: "Start", attachments: [upload], delivery: .queue,
                                   access: otherSpace.access, operationID: UUID())
        }
        let opened = try await service.openChat(.stored(identity))
        let operation = UUID()
        let send = try await service.send(text: "Start", attachments: [upload], delivery: .queue, access: opened.access,
                                          operationID: operation)
        #expect(send.source == identity)
        #expect(send.admissionID == operation.uuidString)
        let streaming = try await nextConversation(&published) { $0.snapshot.messages.last?.text == "Streaming reply" }
        #expect(streaming.access == opened.access)
        #expect(streaming.activity?.phase == .replying)
        #expect(service.currentT3Channels.first(where: { $0.id == channelID })?.preview == "Streaming reply")

        _ = try await service.send(text: "Steer", attachments: [], delivery: .steer, access: opened.access, operationID: UUID())
        _ = try await service.send(text: "Queue", attachments: [], delivery: .queue, access: opened.access, operationID: UUID())
        let queued = try await nextConversation(&published) { $0.snapshot.queuedMessages.first?.text == "Queue" }
        let message = try #require(queued.snapshot.queuedMessages.first)
        let edited = try await service.replaceQueuedMessage(message, text: "Revised", access: opened.access, operationID: UUID())
        #expect(edited.admissionID == message.submissionID)
        _ = try await nextConversation(&published) { $0.snapshot.queuedMessages.first?.text == "Revised" }

        try await host.ask(in: channelID)
        let waiting = try await nextConversation(&published) { $0.snapshot.pendingRequests.count == 2 }
        let approval = try #require(waiting.snapshot.pendingRequests.first(where: { $0.kind == .approval }))
        let question = try #require(waiting.snapshot.pendingRequests.first(where: { $0.kind == .question }))
        await #expect(throws: ConversationServiceError.invalidResponse) {
            try await service.respond(to: question, response: .text(""), access: opened.access, operationID: UUID())
        }
        _ = try await service.respond(to: approval, response: .choice("accept"), access: opened.access, operationID: UUID())
        _ = try await service.respond(to: question, response: .choice("swift"), access: opened.access, operationID: UUID())
        _ = try await service.stop(access: opened.access, operationID: UUID())
        let stopped = try await nextConversation(&published) { $0.activity?.signal?.kind == .stopped }
        #expect(!stopped.snapshot.isWorking)

        let latest = try await service.conversationHistory(identity, offset: 0)
        #expect(latest.messages.map(\.text) == ["Latest"])
        let offset = try #require(latest.nextOffset)
        #expect(try await service.recentConversationHistory(identity)?.hasEarlierMessages == true)
        let older = try await service.conversationHistory(identity, offset: offset)
        #expect(older.messages.map(\.text) == ["Earlier"])
        #expect(older.nextOffset == nil)
        await #expect(throws: T3ServiceError.unknownHistoryOffset) { try await service.conversationHistory(identity, offset: 99) }
        let artifact = try await service.downloadArtifact(.init(name: "report.txt", path: "outputs/report.txt"), access: opened.access)
        #expect(artifact.data == Data("report".utf8))

        try await service.renameChannel(threadID: channelID, title: "Release")
        try await service.setChannelPinned(threadID: channelID, pinned: true)
        try await service.archiveChannel(threadID: channelID, archived: true)
        while service.currentT3Channels.first(where: { $0.id == channelID })?.isArchived != true {
            if await published.next(isolation: MainActor.shared) == nil { throw T3ServiceError.missingChannel }
        }
        let archived = try #require(service.currentT3Channels.first(where: { $0.id == channelID }))
        #expect(archived.title == "Release")
        #expect(archived.isPinned)

        // A bare open lands in the main space and creates nothing.
        let main = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
        #expect(main.identity.stored.text == mainID)
        #expect(await host.createdThreads.count == 2)
        let kept = try await service.openChat(.canonical(profile: profile, expectedRoot: identity.root))
        #expect(kept.identity == identity)
        let bookMergedIdentity = SessionIdentity(profile: profile, root: main.identity.root, stored: main.identity.stored,
                                                 aliases: [main.identity.root])
        let reopened = try await service.openChat(.stored(bookMergedIdentity))
        #expect(reopened.identity.stored == main.identity.stored)
        await #expect(throws: ConversationServiceError.staleConversation) {
            try await service.send(text: "Bad route", attachments: [], delivery: .queue, access: opened.access, operationID: UUID())
        }
    }

    @Test func spacesComeAndGoWithoutRewritingThePrompt() async throws {
        let host = T3ServiceHost()
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let origin = try #require(URL(string: "https://t3.example"))
        _ = try await service.connect(configuration: .init(serverURL: origin, t3: T3Connection(environmentID: "", accessToken: "bearer")))
        let mainID = try #require(service.currentT3Channels.first { $0.isMain }?.id)
        let bot = try #require(try await service.bots().first)
        func promptWrites() async -> Int { await host.writtenFiles.filter { ["AGENTS.md", "CLAUDE.md"].contains($0) }.count }
        #expect(await promptWrites() == 2)

        let named = try await service.createChat(title: "Kyoto trip").summary.identity.stored.text
        #expect(await host.createdThreads.last?["title"].text == "Kyoto trip")
        #expect(await host.createdThreads.last?["titleRenamed"].flag == true)
        try await service.renameChannel(threadID: named, title: "Kyoto, slowly")
        try await service.renameChannel(threadID: mainID, title: "Home")
        try await service.setChannelPinned(threadID: named, pinned: true)
        try await service.archiveChannel(threadID: named, archived: true)
        _ = try await service.setAvatar(.shape(.circle), for: bot)
        #expect(await promptWrites() == 2)

        // The main space takes any name and can't be archived.
        await #expect(throws: T3ServiceError.protectedMainSpace) {
            try await service.archiveChannel(threadID: mainID, archived: true)
        }
        #expect(try await service.loadBotBrain().manifest.mainThreadID == mainID)

        _ = try await service.updateProfile(.init(name: "Kit"), for: bot)
        #expect(await promptWrites() == 4)
        #expect(await host.createdThreads.count == 2)

        // Reconnecting adopts the same main space under the user's name for it.
        let later = T3ServiceHost(existing: true)
        await later.restore(host.state)
        let relaunched = T3BotService(transport: { try await later.http($0) }, webSocket: { _ in later })
        defer { relaunched.disconnect() }
        _ = try await relaunched.connect(configuration: existingConfiguration())
        #expect(relaunched.currentT3Channels.first { $0.isMain }?.id == mainID)
        #expect(relaunched.currentT3Channels.first { $0.isMain }?.displayTitle == "Home")
        #expect(await later.createdThreads.isEmpty)
        #expect(await later.writtenFiles.isEmpty)
    }

    @Test func aBotWithoutAModelConnectsWithoutAMainSpace() async throws {
        let host = T3ServiceHost(models: false)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let origin = try #require(URL(string: "https://t3.example"))
        _ = try await service.connect(configuration: .init(serverURL: origin, t3: T3Connection(environmentID: "", accessToken: "bearer")))
        #expect(service.currentT3Channels.isEmpty)
        #expect(await host.createdThreads.isEmpty)

        // Once the host has a model, the next look at models brings the main space.
        await host.installModels()
        #expect(try await service.availableModels().map(\.modelID) == ["claude-test"])
        #expect(service.currentT3Channels.map(\.isMain) == [true])
        #expect(service.currentT3Channels.map(\.displayTitle) == ["Botto"])
    }

    @Test(arguments: [true, false])
    func recoversAnArchivedOrDeletedMainSpace(archived: Bool) async throws {
        let host = T3ServiceHost(existing: true)
        if archived { try await host.archiveFromAnotherClient("existing-general") } else { await host.deleteThread("existing-general") }
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        let main = try #require(service.currentT3Channels.first { $0.isMain })
        #expect(!main.isArchived)
        #expect(main.displayTitle == "Existing Bot")
        #expect((main.id == "existing-general") == archived)
        #expect(await host.createdThreads.count == (archived ? 0 : 1))
        #expect(try await service.loadBotBrain().manifest.mainThreadID == main.id)
    }

    @Test func refusesToReplaceMainWhenItsArchiveCannotBeRead() async throws {
        let host = T3ServiceHost(existing: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let (events, observer) = AsyncStream<BotServiceEvent>.makeStream()
        service.onEvent = { observer.yield($0) }
        _ = try await service.connect(configuration: existingConfiguration())
        await host.setArchiveReadDenied(true)
        try await host.archiveFromAnotherClient("existing-general")
        for await event in events {
            if case .conversationDirectoryChanged = event, service.currentT3Channels.isEmpty { break }
        }
        let profile = try ExactID("bot-project")
        await #expect(throws: T3RPCError.remote(tag: "ArchiveUnavailable", message: "Archive unavailable")) {
            try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
        }
        #expect(await host.createdThreads.isEmpty)
        #expect(try await service.loadBotBrain().manifest.mainThreadID == "existing-general")
        await host.setArchiveReadDenied(false)
        _ = try await service.availableModels()
        #expect(service.currentT3Channels.first(where: \.isMain)?.id == "existing-general")
    }

    @Test func independentMainRepairsTargetTheSameThread() async throws {
        func repair() async throws -> String {
            let host = T3ServiceHost(existing: true)
            await host.deleteThread("existing-general")
            let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
            defer { service.disconnect() }
            _ = try await service.connect(configuration: existingConfiguration())
            return try #require(await host.createdThreads.first?["threadId"].text)
        }
        let first = try await repair()
        #expect(try await repair() == first)
    }

    @Test func refusesToReplaceATombstonedReplacement() async throws {
        let host = T3ServiceHost(existing: true)
        let replacement = T3ProjectionMapper.stableUUID("botto-main:bot-project:replacement:existing-general").uuidString
        await host.deleteThread("existing-general")
        await host.deleteThread(replacement)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        let profile = try ExactID("bot-project")
        await #expect(throws: T3ServiceError.mainSpaceRecoveryRequired) {
            try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
        }
        #expect(await host.createdThreads.isEmpty)
        #expect(try await service.loadBotBrain().manifest.mainThreadID == "existing-general")
    }

    @Test(arguments: [true, false])
    func keepsTheMainPointerWhenItsShellOrLookupIsUnavailable(lookupDenied: Bool) async throws {
        let host = T3ServiceHost(existing: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let (events, observer) = AsyncStream<BotServiceEvent>.makeStream()
        service.onEvent = { observer.yield($0) }
        _ = try await service.connect(configuration: existingConfiguration())
        await host.setMainLookupDenied(lookupDenied)
        try await host.replaceMainWithoutPublishing()
        var updates = events.makeAsyncIterator()
        while let event = await updates.next(isolation: MainActor.shared) {
            if case .conversationDirectoryChanged = event, service.currentT3Channels.isEmpty { break }
        }

        let profile = try ExactID("bot-project")
        let target = SessionTarget.canonical(profile: profile, expectedRoot: nil)
        if lookupDenied {
            await #expect(throws: T3RPCError.remote(tag: "LookupUnavailable", message: "Lookup unavailable")) {
                try await service.openChat(target)
            }
        } else {
            await #expect(throws: T3ServiceError.mainSpaceSynchronizing) { try await service.openChat(target) }
        }
        #expect(await host.createdThreads.isEmpty)
        #expect(try await service.loadBotBrain().manifest.mainThreadID == "new-main")

        await host.setMainLookupDenied(false)
        try await host.publishReplacementMain()
        while let event = await updates.next(isolation: MainActor.shared) {
            if case .conversationDirectoryChanged = event,
               service.currentT3Channels.contains(where: { $0.id == "new-main" }) { break }
        }
        let opened = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
        #expect(opened.identity.stored.text == "new-main")
        #expect(service.currentT3Channels.first(where: \.isMain)?.id == "new-main")
    }

    @Test(arguments: ["AGENTS.md", "CLAUDE.md", "bot.json"])
    func retryConvergesPromptFilesAndManifest(afterFailedWrite path: String) async throws {
        let host = T3ServiceHost(existing: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        let bot = try #require(try await service.bots().first)
        let original = try await service.readProjectFile(relativePath: "bot.json")
        var expected = try await service.loadBotBrain().manifest
        expected.displayName = "Kit"
        await host.rejectNextWrite(to: path)

        await #expect(throws: T3RPCError.remote(tag: "ProjectWriteFileError", message: "Write refused")) {
            try await service.updateProfile(.init(name: "Kit"), for: bot)
        }
        #expect(try await service.readProjectFile(relativePath: "bot.json") == original)
        _ = try await service.updateProfile(.init(name: "Kit"), for: bot)
        #expect(try await service.loadBotBrain().manifest == expected)
        #expect(try await service.readProjectFile(relativePath: "AGENTS.md") == T3BotBootstrap.agentsMarkdown(expected))
        #expect(try await service.readProjectFile(relativePath: "CLAUDE.md") == T3BotBootstrap.claudeMarkdown(expected))
    }

    @Test func bootstrapUpgradesOnlyAGeneratedPrompt() async throws {
        let host = T3ServiceHost(existing: true)
        let manifest = T3BotManifest(displayName: "Existing Bot", description: "A pre-existing bot")
        await host.write("CLAUDE.md", T3BotBootstrap.legacyAgentsMarkdown(manifest))
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        #expect(try await service.readProjectFile(relativePath: "CLAUDE.md") == T3BotBootstrap.claudeMarkdown(manifest))
        #expect(try await service.readProjectFile(relativePath: "AGENTS.md") == "Custom provider instructions")
    }

    @Test func adoptsAnExistingBotsMainSpaceByWorkspaceWhenStillUnbound() async throws {
        let host = T3ServiceHost(existing: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let origin = try #require(URL(string: "https://t3.example"))
        let connection = T3Connection(environmentID: "environment", accessToken: "bearer",
                                      workspaceRoot: "/host/.botto/bots/main")
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: origin, t3: connection))
        let brain = try await service.loadBotBrain()
        #expect(brain.manifest.displayName == "Existing Bot")
        #expect(brain.manifest.mainThreadID == "existing-general")
        #expect(brain.soulMarkdown == "Keep this soul.")
        #expect(brain.memoryMarkdown == "Keep this memory.")
        #expect(try await service.readProjectFile(relativePath: "AGENTS.md") == "Custom provider instructions")
        #expect(await host.writtenFiles == ["CLAUDE.md"])
        #expect(await host.createdThreads.isEmpty)
        // The "#general" an older build gave the main space becomes the bot's name.
        #expect(service.currentT3Channels.map(\.displayTitle) == ["Existing Bot"])
        #expect(service.currentT3Channels.map(\.isMain) == [true])
    }

    @Test func firstSetupNamesTheBotAndItsMainSpaceAndSavesTheFace() async throws {
        let host = T3ServiceHost()
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let origin = try #require(URL(string: "https://t3.example"))
        _ = try await service.connect(configuration: .init(serverURL: origin, t3: T3Connection(environmentID: "", accessToken: "bearer")))
        let fresh = try #require(try await service.bots().first)
        #expect(T3FirstRun.needsBotSetup(fresh, spaces: service.currentT3Channels))

        await #expect(throws: T3ServiceError.invalidName) {
            try await service.setUpBot(name: "  ", face: BotFace(shape: .cloud, color: "orange"))
        }
        #expect(T3FirstRun.needsBotSetup(fresh, spaces: service.currentT3Channels))
        let orange = try #require(BotAvatarColors.presets.first { $0.id == "orange" })
        try await service.setUpBot(name: " Miso ", face: BotFace(shape: .cloud, color: orange.hex))

        let (files, threads) = await host.state
        let saved = try JSONDecoder().decode(T3BotManifest.self, from: Data(try #require(files["bot.json"]).utf8))
        #expect(saved.displayName == "Miso")
        #expect(saved.avatar?.shape == .cloud)
        #expect(saved.avatar?.color == orange.shared)
        let main = try #require(saved.mainThreadID)
        #expect(threads[main]?["title"].text == "Miso")
        #expect(threads.count == 1)
        #expect(files["AGENTS.md"]?.hasPrefix("# Miso\n") == true)

        // Another device reads the same files, so setup is finished there too.
        let phoneHost = T3ServiceHost()
        await phoneHost.restore((files, threads))
        let phone = T3BotService(transport: { try await phoneHost.http($0) }, webSocket: { _ in phoneHost })
        defer { phone.disconnect() }
        _ = try await phone.connect(configuration: .init(serverURL: origin, t3: T3Connection(environmentID: "", accessToken: "bearer")))
        let bot = try #require(try await phone.bots().first)
        #expect(bot.name == "Miso")
        #expect(!T3FirstRun.needsBotSetup(bot, spaces: phone.currentT3Channels))
        #expect(phone.currentT3Channels.map(\.displayTitle) == ["Miso"])
    }

    @Test func interruptedSetupKeepsWhatWasSavedAndCanBeTriedAgain() async throws {
        let host = T3ServiceHost()
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let origin = try #require(URL(string: "https://t3.example"))
        _ = try await service.connect(configuration: .init(serverURL: origin, t3: T3Connection(environmentID: "", accessToken: "bearer")))
        let face = BotFace(shape: .cloud, color: "#f97316")

        // Without its name and face saved, nothing else may say the bot is set up.
        await host.refuse("projects.writeFile")
        await #expect(throws: (any Error).self) { try await service.setUpBot(name: "Miso", face: face) }
        let untouched = try #require(try await service.bots().first)
        #expect(T3FirstRun.needsBotSetup(untouched, spaces: service.currentT3Channels))
        #expect(service.currentT3Channels.map(\.displayTitle) == ["Botto"])

        // bot.json lands last, so a retry writes the prompts it missed.
        for path in ["AGENTS.md", "CLAUDE.md", "bot.json"] {
            await host.refuse(path)
            await #expect(throws: (any Error).self) { try await service.setUpBot(name: "Miso", face: face) }
            let files = await host.state.files
            let kept = try JSONDecoder().decode(T3BotManifest.self, from: Data(try #require(files["bot.json"]).utf8))
            #expect(kept.displayName == "Botto")
        }
        // Going back to the saved name takes the prompts back too.
        await host.refuse("thread.metadata.update")
        await #expect(throws: (any Error).self) { try await service.setUpBot(name: "Botto", face: face) }
        #expect(await host.state.files["AGENTS.md"]?.hasPrefix("# Botto\n") == true)
        #expect(await host.state.files["CLAUDE.md"]?.hasPrefix("# Botto\n") == true)

        await host.refuse("thread.metadata.update")
        await #expect(throws: (any Error).self) { try await service.setUpBot(name: "Miso", face: face) }
        #expect(await host.state.files["AGENTS.md"]?.hasPrefix("# Miso\n") == true)
        #expect(await host.state.files["CLAUDE.md"]?.hasPrefix("# Miso\n") == true)
        var saved = try JSONDecoder().decode(T3BotManifest.self, from: Data(try #require(await host.state.files["bot.json"]).utf8))
        #expect(saved.displayName == "Miso")
        #expect(saved.avatar?.shape == .cloud)
        #expect(service.currentT3Channels.map(\.displayTitle) == ["Botto"])

        await host.refuse(nil)
        try await service.setUpBot(name: "Mochi", face: face)
        saved = try JSONDecoder().decode(T3BotManifest.self, from: Data(try #require(await host.state.files["bot.json"]).utf8))
        #expect(saved.displayName == "Mochi")
        #expect(service.currentT3Channels.map(\.displayTitle) == ["Mochi"])
    }

    @Test func setupLeftOpenKeepsWhatAnotherDeviceChose() async throws {
        let host = T3ServiceHost()
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let origin = try #require(URL(string: "https://t3.example"))
        _ = try await service.connect(configuration: .init(serverURL: origin, t3: T3Connection(environmentID: "", accessToken: "bearer")))
        var other = try JSONDecoder().decode(T3BotManifest.self, from: Data(try #require(await host.state.files["bot.json"]).utf8))
        other.displayName = "Mochi"
        other.avatar = BotAppearance(shape: .drop)
        try await host.write("bot.json", T3BotBootstrap.manifestJSON(other))

        try await service.setUpBot(name: "Miso", face: BotFace(shape: .cloud, color: "#f97316"))
        let saved = try JSONDecoder().decode(T3BotManifest.self, from: Data(try #require(await host.state.files["bot.json"]).utf8))
        #expect(saved.displayName == "Mochi")
        #expect(saved.avatar == other.avatar)
        // This device has caught up.
        let bot = try #require(try await service.bots().first)
        #expect(bot.name == "Mochi")
        #expect(bot.appearance == other.avatar)
        #expect(service.currentT3Channels.map(\.displayTitle) == ["Mochi"])
    }

    @Test(arguments: ["Mochi", "Botto"]) func setupFinishedOnAnotherDeviceReachesAConnectedOne(named name: String) async throws {
        let host = T3ServiceHost()
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let origin = try #require(URL(string: "https://t3.example"))
        _ = try await service.connect(configuration: .init(serverURL: origin, t3: T3Connection(environmentID: "", accessToken: "bearer")))
        let main = try #require(service.currentT3Channels.first { $0.isMain }?.id)
        var other = try JSONDecoder().decode(T3BotManifest.self, from: Data(try #require(await host.state.files["bot.json"]).utf8))
        other.displayName = name
        other.avatar = BotAppearance(shape: .drop)
        try await host.write("bot.json", T3BotBootstrap.manifestJSON(other))
        try await host.renameFromAnotherClient(main, to: name)

        let deadline = ContinuousClock.now + .seconds(10)
        while try await service.bots().first?.appearance == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let bot = try #require(try await service.bots().first)
        #expect(bot.name == name)
        #expect(bot.appearance == other.avatar)
    }

    @Test func aSpaceOnlyASignedOutProviderCouldAnswerWaitsToBecomeMain() async throws {
        let host = T3ServiceHost(signedOut: true)
        await host.write("bot.json", #"{"displayName":"Botto","providerInstanceID":"claude-1","model":"claude-test"}"#)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let origin = try #require(URL(string: "https://t3.example"))
        _ = try await service.connect(configuration: .init(serverURL: origin, t3: T3Connection(environmentID: "", accessToken: "bearer")))
        #expect(await host.createdThreads.isEmpty)
        // Nor does just opening the bot make one.
        let profile = try ExactID("bot-project")
        await #expect(throws: T3ServiceError.missingModel) {
            _ = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
        }
        #expect(await host.createdThreads.isEmpty)
        // One someone starts anyway keeps the model they chose.
        _ = try await service.createChat(title: "Kyoto")
        #expect(await host.createdThreads.count == 1)

        await host.signIn()
        _ = try await service.providers()
        _ = try await service.availableModels()
        #expect(service.currentT3Channels.first { $0.isMain }?.displayTitle == "Botto")
    }

    @Test func aSignedOutDefaultNeverStartsASpace() async throws {
        let host = T3ServiceHost(signedOutDefault: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let origin = try #require(URL(string: "https://t3.example"))
        _ = try await service.connect(configuration: .init(serverURL: origin, t3: T3Connection(environmentID: "", accessToken: "bearer")))
        let created = try #require(await host.createdThreads.first)
        #expect(created["modelSelection"]["instanceId"].text == "claude-1")
        // The choice itself is kept for when it signs in again.
        #expect(await host.state.files["bot.json"]?.contains("codex-1") == true)
    }

    @Test func aBotNamedBeforeAProviderExistsGivesItsNameToTheMainSpaceLater() async throws {
        let host = T3ServiceHost(models: false, signedOut: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        let origin = try #require(URL(string: "https://t3.example"))
        _ = try await service.connect(configuration: .init(serverURL: origin, t3: T3Connection(environmentID: "", accessToken: "bearer")))
        #expect(service.currentT3Channels.isEmpty)
        let waiting = try await service.providers()
        #expect(waiting == [T3ProviderStatus(id: "claude-1", driver: "claudeAgent", state: .needsSignIn)])
        #expect(T3FirstRun.providersNeedingSetup(waiting) == waiting)

        try await service.setUpBot(name: "Miso", face: BotFace(shape: .drop, color: "#8b5cf6"))
        #expect(service.currentT3Channels.isEmpty)

        // Models a signed-out provider lists are no use yet.
        await host.installModels()
        #expect(try await service.availableModels().isEmpty)
        #expect(service.currentT3Channels.isEmpty)
        await host.signIn()
        let ready = try await service.providers()
        #expect(ready.map(\.state) == [.ready])
        #expect(T3FirstRun.providersNeedingSetup(ready).isEmpty)
        #expect(try await service.availableModels().map(\.modelID) == ["claude-test"])
        #expect(service.currentT3Channels.map(\.displayTitle) == ["Miso"])
        #expect(service.currentT3Channels.map(\.isMain) == [true])
    }

    @Test func autosavedBrainEditsApplyInOrderWithoutCollisions() async throws {
        let host = T3ServiceHost(existing: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        defer { service.disconnect() }
        _ = try await service.connect(configuration: existingConfiguration())
        let bot = try #require(try await service.bots().first)

        let souls = ["one", "two", "three"].map { text in Task { try await service.saveSoul(text) } }
        let name = Task { try await service.updateProfile(.init(name: "Quick"), for: bot) }
        let look = Task { try await service.setAvatar(.shape(.circle), for: bot) }
        let memory = Task { try await service.saveMemory("Remember this.") }
        for save in souls { try await save.value }
        _ = try await name.value
        _ = try await look.value
        try await memory.value

        let brain = try await service.loadBotBrain()
        #expect(brain.soulMarkdown == "three")
        #expect(brain.memoryMarkdown == "Remember this.")
        #expect(brain.manifest.displayName == "Quick")
        #expect(brain.manifest.avatar?.shape == .circle)
        // Superseded autosaves are skipped instead of written out of order.
        #expect(await host.writtenFiles.filter { $0 == "SOUL.md" }.count < 3)
    }

    @Test func loadsArchivedChannelsAndTracksArchiveChanges() async throws {
        let host = T3ServiceHost(existing: true, archivedChannel: true)
        let service = T3BotService(transport: { try await host.http($0) }, webSocket: { _ in host })
        let (events, observe) = AsyncStream<BotServiceEvent>.makeStream()
        service.onEvent = { observe.yield($0) }
        defer { service.disconnect() }

        let origin = try #require(URL(string: "https://t3.example"))
        let connection = T3Connection(environmentID: "environment", accessToken: "bearer", projectID: "bot-project")
        _ = try await service.connect(configuration: .init(serverURL: origin, t3: connection))
        let archived = try #require(service.currentT3Channels.first(where: { $0.id == "archived-channel" }))
        #expect(archived.isArchived)
        #expect(archived.isPinned)

        let bot = try #require(try await service.bots().first)
        let profile = try ExactID(bot.id)
        let directory = try await service.conversations(profile: profile)
        let identity = try #require(directory.summaries.first(where: { $0.identity.stored.text == archived.id })?.identity)
        #expect(try await service.openChat(.stored(identity)).identity == identity)

        try await service.archiveChannel(threadID: archived.id, archived: false)
        #expect(service.currentT3Channels.first(where: { $0.id == archived.id })?.isArchived == false)

        try await host.archiveFromAnotherClient(archived.id)
        var published = events.makeAsyncIterator()
        while service.currentT3Channels.first(where: { $0.id == archived.id })?.isArchived != true {
            guard let event = await published.next(isolation: MainActor.shared) else { throw T3ServiceError.missingChannel }
            if case .disconnected = event { throw T3ServiceError.disconnected }
        }
        #expect(service.currentT3Channels.first(where: { $0.id == archived.id })?.isPinned == true)
    }

    private func nextConversation(_ events: inout AsyncStream<BotServiceEvent>.Iterator,
                                  matching: (OpenedConversation) -> Bool) async throws -> OpenedConversation {
        while let event = await events.next(isolation: MainActor.shared) {
            if case .conversation(let update) = event, matching(update) { return update }
            if case .disconnected = event { throw T3ServiceError.disconnected }
        }
        throw T3ServiceError.disconnected
    }
}

private actor T3ServiceHost: T3WebSocketTransport {
    private let socket = T3TestSocket()
    private let root = "/host/.botto/bots/main"
    private var projectID = "bot-project"
    private let time = "2026-11-24T12:00:00Z"
    private let existing: Bool
    private var models: Bool
    private var signedOut: Bool
    private let signedOutDefault: Bool
    private var probedSignedOut: Bool
    private var refused: String?
    private let ticketStatuses: [Int]
    nonisolated let visits: AsyncStream<JSONValue>
    private let visitCommands: AsyncStream<JSONValue>.Continuation
    private let workflowsEnabled: Bool
    private var withholdFirstVisitReply: Bool
    private var withheldVisitID: String?
    private(set) var modelCommands: [JSONValue] = []
    private var outputsAvailable = false
    private(set) var listedDirectories: [String] = []
    private var scheduledTasks: [String: JSONValue] = [:]
    private var workflowDefinitions: [String: JSONValue] = [:]
    private(set) var workflowWrites: [JSONValue] = []
    private var workflowSaveWarning: String?
    private(set) var workflowDeletes: [String] = []
    private(set) var workflowAnswers: [JSONValue] = []
    private var workflowRuns: [JSONValue] = []
    private var workflowQuestions: [JSONValue] = []
    private var waitingForWorkflowSnapshot: AsyncStream<String>.Continuation?
    private var heldWorkflowSnapshotID: String?
    private var routineStreams: Set<String> = []
    private(set) var interruptedRoutineStreams = 0
    private(set) var routineUpserts: [JSONValue] = []
    private(set) var ticketAttempts = 0
    private(set) var threadSubscriptions: [String] = []
    private(set) var writtenFiles: [String] = []
    private var rejectedWritePath: String?
    private var deniesArchiveReads = false
    private var deniesMainLookup = false
    private var omitsShellProject = false
    private var dropsCommandAcknowledgement = false
    private var dropsRoutineAcknowledgement = false
    private var replaysDeletedProject = false
    private(set) var projectCreations: [JSONValue] = []
    private(set) var createdThreads: [JSONValue] = []
    private var files: [String: String] = [:]
    private var threads: [String: JSONValue] = [:]
    private var deletedThreadIDs: Set<String> = []
    private var sequence = 0
    private var shellStream: String?
    private var threadStreams: [String: String] = [:]

    init(existing: Bool = false, archivedChannel: Bool = false, ticketStatuses: [Int] = [200],
         withholdFirstVisitReply: Bool = false, models: Bool = true, signedOut: Bool = false,
         signedOutDefault: Bool = false, workflowsEnabled: Bool = false) {
        self.existing = existing
        self.workflowsEnabled = workflowsEnabled
        self.models = models
        self.signedOut = signedOut
        probedSignedOut = signedOut
        self.signedOutDefault = signedOutDefault
        self.ticketStatuses = ticketStatuses
        self.withholdFirstVisitReply = withholdFirstVisitReply
        (visits, visitCommands) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        if existing {
            files = [
                "bot.json": #"{"displayName":"Existing Bot","description":"A pre-existing bot","mainThreadID":"existing-general"}"#,
                "SOUL.md": "Keep this soul.", "MEMORY.md": "Keep this memory.", "AGENTS.md": "Custom provider instructions"
            ]
            threads["existing-general"] = .object(["id": .string("existing-general"), "projectId": .string(projectID),
                                                  "title": .string("#general"), "status": .string("idle")])
        }
        if signedOutDefault {
            files["bot.json"] = #"{"displayName":"Botto","description":"","providerInstanceID":"codex-1","model":"gpt-test"}"#
        }
        if archivedChannel {
            threads["archived-channel"] = .object([
                "id": .string("archived-channel"), "projectId": .string(projectID), "title": .string("Archived channel"),
                "archivedAt": .string(time), "pinnedAt": .string(time)
            ])
        }
    }

    func addWorkflowStep(_ id: String, archived: Bool = false) throws {
        var shell: JSONValue = .object([
            "id": .string(id), "projectId": .string(projectID), "title": .string("Workflow step"),
            "lineage": .object(["workflowStep": .bool(true)])
        ])
        if archived { shell["archivedAt"] = .string(time) }
        threads[id] = shell
        try shellUpdate(id)
    }

    func archiveFromAnotherClient(_ thread: String) throws {
        threads[thread]?["archivedAt"] = .string(time)
        try shellUpdate(thread)
    }

    var state: (files: [String: String], threads: [String: JSONValue]) { (files, threads) }
    func restore(_ state: (files: [String: String], threads: [String: JSONValue])) {
        (files, threads) = (state.files, state.threads)
    }
    func installModels() { models = true }
    func signIn() { signedOut = false }
    func renameFromAnotherClient(_ thread: String, to title: String) throws {
        threads[thread]?["title"] = .string(title)
        try shellUpdate(thread)
    }
    /// Fails one RPC, thread command or file write until told otherwise.
    func refuse(_ name: String?) { refused = name }
    func deleteThread(_ id: String) {
        threads[id] = nil
        deletedThreadIDs.insert(id)
    }
    func write(_ path: String, _ contents: String) { files[path] = contents }
    func rejectNextWrite(to path: String) { rejectedWritePath = path }
    func setArchiveReadDenied(_ denied: Bool) { deniesArchiveReads = denied }
    func setMainLookupDenied(_ denied: Bool) { deniesMainLookup = denied }
    func omitProjectFromShell() { omitsShellProject = true }
    func loseNextCommandAcknowledgement() { dropsCommandAcknowledgement = true }
    func loseNextRoutineAcknowledgement() { dropsRoutineAcknowledgement = true }
    func replayDeletedProjectOnFirstCreate() { replaysDeletedProject = true }

    func replaceMainWithoutPublishing() throws {
        let stream = try #require(shellStream)
        threads["existing-general"] = nil
        threads["new-main"] = .object([
            "id": .string("new-main"), "projectId": .string(projectID), "title": .string("New Main")
        ])
        files["bot.json"] = #"{"displayName":"Existing Bot","mainThreadID":"new-main"}"#
        sequence += 1
        try chunk(stream, values: [.object([
            "kind": .string("thread.removed"), "sequence": .number(Double(sequence)),
            "location": .string("active"), "threadId": .string("existing-general")
        ])])
    }

    func publishReplacementMain() throws { try shellUpdate("new-main") }

    func changeSavedProject(rootChanged: Bool) throws {
        let stream = try #require(shellStream)
        if rootChanged {
            var moved = project
            moved["workspaceRoot"] = .string("/host/other-bot")
            try chunk(stream, values: [.object(["kind": .string("project.updated"), "project": moved])])
        } else {
            try chunk(stream, values: [.object(["kind": .string("project.removed"), "projectId": .string(projectID)])])
        }
    }

    func addOutputs() { outputsAvailable = true }

    func warnOnNextWorkflowSave(_ message: String) { workflowSaveWarning = message }

    func holdNextWorkflowSnapshot() -> AsyncStream<String> {
        let (requests, continuation) = AsyncStream<String>.makeStream()
        waitingForWorkflowSnapshot = continuation
        return requests
    }

    func releaseWorkflowSnapshot() throws {
        let id = try #require(heldWorkflowSnapshotID)
        heldWorkflowSnapshotID = nil
        try sendWorkflowSnapshot(id)
    }

    private func sendWorkflowSnapshot(_ id: String) throws {
        try chunk(id, values: [.object(["runs": .array(workflowRuns), "questions": .array(workflowQuestions)])])
    }

    func seedWorkflowQuestions(workflow: String) throws {
        workflowRuns = [
            try t3JSON(#"{"runId":"own-run","version":1,"status":"waiting","result":null}"#),
            try t3JSON(#"{"runId":"foreign-run","workflow":"foreign-workflow","version":1,"status":"waiting","result":null}"#),
        ]
        workflowRuns[0]["workflow"] = .string(workflow)
        workflowRuns.append(.object([
            "runId": .string("old-run"), "workflow": .string(workflow), "version": .number(1),
            "status": .string("completed"), "result": .string("Older result"),
        ]))
        workflowQuestions = [
            try t3JSON(#"{"runId":"own-run","name":"run-routine","request":{"title":"Run the Routine?","choices":["Run","Skip"],"data":{"threadId":"existing-general"}}}"#),
            try t3JSON(#"{"runId":"foreign-run","name":"run-routine","request":{"title":"Foreign question","choices":["Run","Skip"],"data":{"threadId":"existing-general"}}}"#),
        ]
    }

    func seedRoutines() throws {
        let once = scheduledTask(id: "once-task", input: try t3JSON("""
        {"title":"One-time brief","prompt":"Write a brief","enabled":false,
         "projectId":"bot-project","threadId":"existing-general","threadMode":"continue",
         "schedule":{"type":"once","runAt":"\(time)"},"workspaceStrategy":{"type":"root"},
         "modelSelection":{"instanceId":"claude-1","model":"claude-test"},
         "runtimeMode":"approval-required","interactionMode":"default"}
        """), lastRun: .string(time))
        scheduledTasks["once-task"] = once
        var other = once
        other["id"] = .string("other-task")
        other["projectId"] = .string("other-project")
        scheduledTasks["other-task"] = other
    }

    private func scheduledTask(id: String, input: JSONValue, lastRun: JSONValue = .null) -> JSONValue {
        var task = input
        task["id"] = .string(id)
        task["createdAt"] = .string(time)
        task["updatedAt"] = .string(time)
        task["createdBy"] = .string("user")
        task["creationSource"] = .string("mobile")
        task["nextRunAt"] = input["enabled"].flag == true ? .string("2026-11-25T09:00:00.000Z") : .null
        task["lastRunAt"] = lastRun
        task["lastRunStatus"] = .string(lastRun == .null ? "never" : "succeeded")
        task["lastRunError"] = .null
        task["runCount"] = .number(lastRun == .null ? 0 : 1)
        return task
    }

    func http(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if url.path == "/api/assets/signed/guide.PDF" {
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data([0x25, 0x50, 0x44, 0x46, 0, 0xff]), response)
        }
        let json: String
        let status: Int
        switch url.path {
        case "/.well-known/t3/environment":
            json = #"{"environmentId":"environment","label":"Host","serverVersion":"2.4","orchestrationProtocolVersion":2}"#
            status = 200
        case "/api/auth/websocket-ticket/rpc":
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer bearer")
            status = ticketAttempts < ticketStatuses.count ? ticketStatuses[ticketAttempts] : 200
            let ticket = ticketAttempts == 0 ? "short+ticket" : "reconnect-ticket"
            ticketAttempts += 1
            json = """
            {"ticket":"\(ticket)","expiresAt":"2099-11-24T12:00:00Z"}
            """
        case "/api/projects":
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer bearer")
            json = try String(decoding: JSONValue.object(["projects": .array(existing ? [project] : [])]).data, as: UTF8.self)
            status = 200
        case "/api/attachments/upload/signed":
            #expect(request.httpMethod == "POST")
            #expect(request.httpBody == Data("file bytes".utf8))
            json = ""
            status = 204
        case "/api/assets/signed/report.txt":
            #expect(request.httpMethod == "GET")
            json = "report"
            status = 200
        default:
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer bearer")
            #expect(request.value(forHTTPHeaderField: "x-t3-orchestration-protocol") == "2")
            if url.path.hasSuffix("/bounded") {
                let id = url.deletingLastPathComponent().lastPathComponent
                json = """
                {"historyCursor":"older+page","hasMoreHistory":true,
                 "projection":{"thread":{"id":"\(id)"},
                  "visibleTurnItems":[{"position":0,"item":{"id":"latest","type":"assistant_message","text":"Latest"}}]}}
                """
                status = 200
            } else if url.path.hasSuffix("/history") {
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
                    URLQueryItem(name: "cursor", value: "older+page")
                ])
                #expect(url.absoluteString.hasSuffix("?cursor=older%2Bpage"))
                json = #"{"nextCursor":null,"hasMoreHistory":false,"items":[{"position":0,"item":{"id":"earlier","type":"user_message","text":"Earlier"}}]}"#
                status = 200
            } else {
                Issue.record("Unexpected HTTP request \(url.path)")
                json = ""
                status = 404
            }
        }
        return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }

    func send(_ data: Data) throws {
        let frame = try JSONDecoder().decode(JSONValue.self, from: data)
        switch frame["_tag"].text {
        case "Ack", "Pong": return
        case "Interrupt":
            let thread = threadStreams.first { $0.value == frame["requestId"].text }?.key
            if let thread { threadStreams[thread] = nil }
            if let id = frame["requestId"].text, routineStreams.remove(id) != nil { interruptedRoutineStreams += 1 }
            return
        case "Ping": try emit(.object(["_tag": .string("Pong")])); return
        case "Request": break
        default: Issue.record("Unexpected RPC frame"); return
        }
        let id = try #require(frame["id"].text)
        let request = frame["payload"]
        if let refused, frame["tag"].text == refused || request["type"].text == refused
            || (frame["tag"].text == "projects.writeFile" && request["relativePath"].text == refused) {
            try emit(t3JSON("""
            {"_tag":"Exit","requestId":"\(id)","exit":{"_tag":"Failure","cause":[
             {"_tag":"Fail","error":{"_tag":"DispatchError","message":"Refused"}}
            ]}}
            """))
            return
        }
        let reply: JSONValue
        switch frame["tag"].text {
        case "server.getConfig", "server.refreshProviders":
            // Only a refresh looks again; the config repeats what was last found.
            if frame["tag"].text == "server.refreshProviders" { probedSignedOut = signedOut }
            reply = try t3JSON("""
            {"cwd":"/srv","environment":{"environmentId":"environment"},"threadSnapshotPagination":true,
             "settings":{"defaultRuntimeMode":"approval-required","workflowsEnabled":\(workflowsEnabled)},
             "providers":[{"instanceId":"claude-1","driver":"claudeAgent","displayName":"Claude",
               "installed":true,"enabled":true,"auth":{"status":"\(probedSignedOut ? "unauthenticated" : "authenticated")"},"models":[\(models ? #"{"slug":"claude-test","name":"Claude Test","isDefault":true}"# : "")]}
             \(signedOutDefault ? #",{"instanceId":"codex-1","driver":"codex","installed":true,"enabled":true,"auth":{"status":"unauthenticated"},"models":[{"slug":"gpt-test"}]}"# : "")]}
            """)
        case "projects.mutate":
            #expect(!existing)
            #expect(request["type"].text == "project.create")
            #expect(request["workspaceRoot"].text == (projectCreations.isEmpty ? "~/.botto/bots/main" : root))
            #expect(request["createWorkspaceRootIfMissing"].flag == true)
            projectCreations.append(request)
            if replaysDeletedProject { projectID = try #require(request["projectId"].text) }
            var createdProject = project
            if replaysDeletedProject, projectCreations.count == 1 { createdProject["deletedAt"] = .string(time) }
            reply = createdProject
        case "projects.readFile":
            #expect(request["cwd"].text == root)
            let path = try #require(request["relativePath"].text)
            let value = files[path]
            #expect(value != nil || request["allowMissing"].flag == true)
            reply = .object(["relativePath": .string(path), "contents": .string(value ?? ""),
                             "truncated": .bool(false), "exists": .bool(value != nil)])
        case "projects.writeFile":
            #expect(request["cwd"].text == root)
            let path = try #require(request["relativePath"].text)
            if rejectedWritePath == path {
                rejectedWritePath = nil
                try reject(id, tag: "ProjectWriteFileError", message: "Write refused")
                return
            }
            let contents = try #require(request["contents"].text)
            files[path] = contents
            writtenFiles.append(path)
            reply = .object(["relativePath": .string(path)])
        case "projects.listEntries":
            #expect(request["cwd"].text == root)
            let directory = try #require(request["directoryPath"].text)
            listedDirectories.append(directory)
            let entries: [(String, String)]
            switch directory {
            case "": entries = outputsAvailable ? [("skills", "directory"), ("outputs", "directory")] : [("skills", "directory")]
            case "skills": entries = [("skills/check", "directory")]
            case "outputs": entries = [("outputs/report.txt", "file"), ("outputs/nested", "directory"),
                                         ("outputs/Meeting 10:30.md", "file"), ("outputs/unknown.bin", "file")]
            case "outputs/nested": entries = [("outputs/nested/guide.PDF", "file")]
            default: throw T3ServiceError.invalidPath
            }
            reply = .object(["entries": .array(entries.map { .object(["path": .string($0.0), "kind": .string($0.1)]) }),
                             "truncated": .bool(false)])
        case "orchestration.subscribeShell":
            #expect(request["requestCompletionMarker"].flag == true)
            shellStream = id
            try chunk(id, values: [
                .object(["kind": .string("snapshot"), "snapshot": .object([
                    "projects": .array(omitsShellProject ? [] : [project]),
                    "threads": .array(threads.values.filter { $0["archivedAt"] == .null }),
                    "archivedThreads": .array([])
                ])]),
                .object(["kind": .string("synchronized")])
            ])
            return
        case "orchestration.getThreadLinkMetadata":
            if deniesMainLookup {
                try reject(id, tag: "LookupUnavailable", message: "Lookup unavailable")
                return
            }
            let ids = try #require(request["threadIds"].list)
            var metadata: [String: JSONValue] = [:]
            for id in ids.compactMap(\.text) {
                if let thread = threads[id] {
                    metadata[id] = .object(["projectId": thread["projectId"], "title": thread["title"]])
                }
            }
            reply = .object(metadata)
        case "orchestration.getArchivedShellSnapshot":
            if deniesArchiveReads {
                try reject(id, tag: "ArchiveUnavailable", message: "Archive unavailable")
                return
            }
            reply = .object([
                "snapshotSequence": .number(Double(sequence)),
                "threads": .array(threads.values.filter { $0["archivedAt"] != .null })
            ])
        case "orchestration.subscribeThread":
            #expect(request["requestCompletionMarker"].flag == true)
            #expect(request["acceptBoundedSnapshot"].flag == true)
            let thread = try #require(request["threadId"].text)
            threadSubscriptions.append(thread)
            threadStreams[thread] = id
            try chunk(id, values: [
                .object(["kind": .string("snapshot"), "snapshotSequence": .number(Double(sequence)),
                         "projection": .object(["thread": .object(["id": .string(thread)]), "visibleTurnItems": .array([])])]),
                .object(["kind": .string("synchronized")])
            ])
            return
        case "orchestration.dispatchCommand":
            if request["type"].text == "thread.create", let thread = request["threadId"].text,
               threads[thread] != nil || deletedThreadIDs.contains(thread) {
                try reject(id, tag: "OrchestrationV2DispatchCommandError",
                           message: "Thread \(thread) already exists. Use a new thread id.")
                return
            }
            try apply(request)
            if dropsCommandAcknowledgement {
                dropsCommandAcknowledgement = false
                try emit(.object(["_tag": .string("Defect"), "defect": .string("Lost acknowledgement")]))
                return
            }
            if request["type"].text == "thread.visit", withholdFirstVisitReply {
                withholdFirstVisitReply = false
                withheldVisitID = id
                return
            }
            sequence += 1
            reply = .object(["sequence": .number(Double(sequence))])
        case "attachments.createUploadUrl":
            #expect(request["type"].text == "file")
            #expect(request["name"].text == "note.txt")
            #expect(request["sizeBytes"].integer == 10)
            reply = try t3JSON(#"{"attachmentId":"uploaded","relativeUrl":"/api/attachments/upload/signed","expiresAt":4100000000000}"#)
        case "assets.createUrl":
            let resource = request["resource"]
            if resource["_tag"].text == "draft-workspace-file" {
                #expect(resource["cwd"].text == root)
                #expect(resource["path"].text == "outputs/nested/guide.PDF")
                #expect(resource["disposition"].text == "attachment")
                reply = try t3JSON(#"{"relativeUrl":"/api/assets/signed/guide.PDF","expiresAt":4100000000000}"#)
            } else {
                #expect(resource["_tag"].text == "workspace-file")
                #expect(resource["path"].text == "outputs/report.txt")
                reply = try t3JSON(#"{"relativeUrl":"/api/assets/signed/report.txt","expiresAt":4100000000000}"#)
            }
        case "workflows.subscribe":
            if let observer = waitingForWorkflowSnapshot {
                heldWorkflowSnapshotID = id
                waitingForWorkflowSnapshot = nil
                observer.yield(id)
                observer.finish()
            } else {
                try sendWorkflowSnapshot(id)
            }
            return
        case "workflows.answer":
            workflowAnswers.append(request)
            let run = try #require(workflowRuns.firstIndex { $0["runId"] == request["runId"] })
            workflowRuns[run]["status"] = .string("completed")
            workflowRuns[run]["result"] = .string("Skipped")
            workflowQuestions.removeAll { $0["runId"] == request["runId"] && $0["name"] == request["name"] }
            reply = .null
        case "workflows.getDefinition":
            reply = .object(["single": .bool(false), "files": .array(Array(workflowDefinitions.values)),
                             "problems": .array([])])
        case "workflows.saveDefinition":
            workflowWrites.append(request)
            let name = try #require(request["name"].text)
            let workflow = String(name.dropLast(3))
            let source = try #require(request["source"].text)
            let registration = try #require(source.firstMatch(of: /version <= ([0-9]+)/))
            let version = try #require(Int(registration.1))
            workflowDefinitions[name] = .object(["name": .string(name), "source": request["source"],
                                                  "workflows": .array((1...version).map { .string("\(workflow)@\($0)") }),
                                                  "problems": .array([])])
            let warnings = workflowSaveWarning.map { [JSONValue.object(["message": .string($0)])] } ?? []
            workflowSaveWarning = nil
            reply = .object(["changed": .bool(true), "problems": .array(warnings)])
        case "workflows.deleteDefinition":
            let name = try #require(request["name"].text)
            workflowDeletes.append(name)
            reply = .object(["changed": .bool(workflowDefinitions.removeValue(forKey: name) != nil), "problems": .array([])])
        case "scheduledTasks.subscribe":
            #expect(request == .object([:]))
            routineStreams.insert(id)
            try chunk(id, values: [.object(["tasks": .array(Array(scheduledTasks.values)), "timeZone": .string("UTC")])])
            return
        case "scheduledTasks.upsert":
            #expect(request["projectId"].text == projectID)
            #expect(request["threadMode"].text == "continue")
            #expect(request["workspaceStrategy"] == .object(["type": .string("root")]))
            #expect(request["modelSelection"] == .object(["instanceId": .string("claude-1"), "model": .string("claude-test")]))
            #expect(request["runtimeMode"].text == "approval-required")
            #expect(request["interactionMode"].text == "default")
            routineUpserts.append(request)
            let taskID = "task-\(routineUpserts.count)"
            let task = scheduledTask(id: taskID, input: request)
            scheduledTasks[taskID] = task
            if dropsRoutineAcknowledgement {
                dropsRoutineAcknowledgement = false
                try emit(.object(["_tag": .string("Defect"), "defect": .string("Lost acknowledgement")]))
                return
            }
            reply = .object(["task": task])
        case "scheduledTasks.setEnabled":
            let taskID = try #require(request["id"].text)
            #expect(request == .object(["id": .string(taskID), "enabled": .bool(false)]))
            var task = try #require(scheduledTasks[taskID])
            task["enabled"] = request["enabled"]
            task["nextRunAt"] = .null
            scheduledTasks[taskID] = task
            reply = .object(["task": task])
        case "scheduledTasks.delete":
            let taskID = try #require(request["id"].text)
            #expect(request == .object(["id": .string(taskID)]))
            let removed = scheduledTasks.removeValue(forKey: taskID)
            _ = try #require(removed)
            reply = .object(["id": .string(taskID)])
        default:
            Issue.record("Unexpected RPC \(frame["tag"].text ?? "")")
            throw T3ServiceError.invalidResponse
        }
        try emit(.object(["_tag": .string("Exit"), "requestId": .string(id),
                          "exit": .object(["_tag": .string("Success"), "value": reply])]))
    }

    func receive() async throws -> Data { try await socket.receive() }
    func close() async { await socket.close() }
    func dropSocket() { socket.incoming.finish(throwing: T3RPCError.transport) }

    func completeForPush(_ thread: String, id: String = "fixture-routine-run", holding: Bool = false) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        threads[thread]?["status"] = .string("completed")
        threads[thread]?["latestRunId"] = .string(id)
        threads[thread]?["latestRunCompletedAt"] = .string(formatter.string(from: .now))
        threads[thread]?["pendingBackgroundTasks"] = holding ? .array([.object(["kind": .string("subagent")])]) : .array([])
        try shellUpdate(thread)
    }

    func endShellStream() throws { try endStream(#require(shellStream)) }

    func endThreadStream(_ thread: String) throws { try endStream(#require(threadStreams[thread])) }

    private func endStream(_ id: String) throws {
        try emit(.object(["_tag": .string("Exit"), "requestId": .string(id),
                          "exit": .object(["_tag": .string("Success"), "value": .null])]))
    }

    func rejectFirstVisit() throws {
        let id = try #require(withheldVisitID)
        try emit(t3JSON("""
        {"_tag":"Exit","requestId":"\(id)","exit":{"_tag":"Failure","cause":[
         {"_tag":"Fail","error":{"_tag":"DispatchError","message":"Could not mark channel visited"}}
        ]}}
        """))
    }

    func ask(in thread: String) throws {
        try event("turn-item.updated", payload: t3JSON(#"{"id":"approval-item","type":"approval_request","requestId":"approval","prompt":"Run it?"}"#), thread: thread)
        try event("runtime-request.updated", payload: t3JSON(#"{"id":"approval","kind":"command","status":"pending"}"#), thread: thread)
        try event("turn-item.updated", payload: t3JSON("""
        {"id":"question-item","type":"user_input_request","requestId":"question",
         "questions":[{"id":"language","header":"Language","question":"Which?","options":[{"label":"Swift","value":"swift"}]}]}
        """), thread: thread)
        try event("runtime-request.updated", payload: t3JSON(#"{"id":"question","kind":"user_input","status":"pending"}"#), thread: thread)
    }

    private var project: JSONValue {
        .object(["id": .string(projectID), "workspaceRoot": .string(root), "defaultModelSelection": .null])
    }

    private func apply(_ command: JSONValue) throws {
        let thread = try #require(command["threadId"].text)
        switch command["type"].text {
        case "thread.create":
            #expect(command["projectId"].text == projectID)
            #expect(command["modelSelection"]["instanceId"].text == "claude-1")
            #expect(command["modelSelection"]["model"].text == "claude-test")
            createdThreads.append(command)
            threads[thread] = .object(["id": .string(thread), "projectId": .string(projectID),
                                       "title": command["title"], "status": .string("idle"),
                                       "modelSelection": command["modelSelection"],
                                       "updatedAt": .string("2026-11-24T12:00:0\(createdThreads.count)Z")])
            try shellUpdate(thread)
        case "message.dispatch":
            switch command["text"].text {
            case "Start":
                #expect(command["attachments"].list?.first?["id"].text == "uploaded")
                #expect(command["dispatchMode"]["type"].text == "start_immediately")
                // The first message of an untitled space seeds its title.
                #expect(command["titleSeed"].text == "Start")
                try event("turn-item.updated", payload: t3JSON("""
                {"type":"user_message","id":"start-message","text":"Start","updatedAt":"\(time)"}
                """), thread: thread)
                try event("run.created", payload: t3JSON("""
                {"id":"running","status":"running","ordinal":1,"startedAt":"\(time)"}
                """), thread: thread)
                try event("turn-item.updated", payload: t3JSON("""
                {"type":"assistant_message","id":"reply","runId":"running","streaming":true,"text":"Streaming reply","updatedAt":"\(time)"}
                """), thread: thread)
            case "Steer":
                #expect(command["titleSeed"] == .null)
                #expect(command["dispatchMode"]["type"].text == "steer_active")
                #expect(command["dispatchMode"]["targetRunId"].text == "running")
            case "Queue":
                #expect(command["dispatchMode"]["type"].text == "queue_after_active")
                try event("message.updated", payload: t3JSON(#"{"id":"queued-msg","text":"Queue"}"#), thread: thread)
                try event("run.created", payload: t3JSON(#"{"id":"queued","status":"queued","userMessageId":"queued-msg","ordinal":2,"queuePosition":1}"#), thread: thread)
            default: Issue.record("Unexpected send")
            }
        case "queued-run.edit":
            #expect(command["runId"].text == "queued")
            #expect(command["text"].text == "Revised")
            try event("message.updated", payload: .object(["id": .string("queued-msg"), "text": command["text"]]), thread: thread)
        case "runtime-request.respond":
            let request = try #require(command["requestId"].text)
            if request == "approval" { #expect(command["decision"].text == "accept") }
            else if request == "question" { #expect(command["answers"]["language"].text == "swift") }
            else { Issue.record("Unexpected request ID") }
            try event("runtime-request.updated", payload: .object(["id": .string(request), "status": .string("resolved")]), thread: thread)
        case "run.interrupt":
            #expect(command["runId"].text == "running")
            try event("run.updated", payload: t3JSON("""
            {"id":"running","status":"interrupted","ordinal":1,"completedAt":"\(time)"}
            """), thread: thread)
        case "thread.metadata.update":
            threads[thread]?["title"] = command["title"]
            try shellUpdate(thread)
        case "thread.visit":
            visitCommands.yield(command)
        case "thread.model-selection.set":
            modelCommands.append(command)
        case "thread.pin":
            threads[thread]?["pinnedAt"] = .string(time)
            try shellUpdate(thread)
        case "thread.archive":
            try archiveFromAnotherClient(thread)
        case "thread.unarchive":
            threads[thread]?["archivedAt"] = .null
            try shellUpdate(thread)
        default: Issue.record("Unexpected orchestration command")
        }
    }

    private func shellUpdate(_ thread: String) throws {
        guard let stream = shellStream, let shell = threads[thread] else { return }
        sequence += 1
        let item: JSONValue
        if shell["archivedAt"] == .null {
            item = .object(["kind": .string("thread.updated"), "sequence": .number(Double(sequence)),
                            "location": .string("active"), "thread": shell])
        } else {
            item = .object(["kind": .string("thread.removed"), "sequence": .number(Double(sequence)),
                            "location": .string("active"), "threadId": .string(thread)])
        }
        try chunk(stream, values: [item])
    }

    private func event(_ type: String, payload: JSONValue, thread: String) throws {
        let stream = try #require(threadStreams[thread])
        sequence += 1
        let event: JSONValue = .object(["id": .string("event-\(sequence)"), "threadId": .string(thread),
                                         "type": .string(type), "occurredAt": .string(time), "payload": payload])
        try chunk(stream, values: [.object(["kind": .string("event"), "sequence": .number(Double(sequence)), "event": event])])
    }

    private func chunk(_ requestID: String, values: [JSONValue]) throws {
        try emit(.object(["_tag": .string("Chunk"), "requestId": .string(requestID), "values": .array(values)]))
    }

    private func reject(_ id: String, tag: String, message: String) throws {
        try emit(.object(["_tag": .string("Exit"), "requestId": .string(id), "exit": .object([
            "_tag": .string("Failure"), "cause": .array([
                .object(["_tag": .string("Fail"), "error": .object(["_tag": .string(tag), "message": .string(message)])])
            ])
        ])]))
    }

    private func emit(_ frame: JSONValue) throws { socket.incoming.yield(try frame.data) }
}
