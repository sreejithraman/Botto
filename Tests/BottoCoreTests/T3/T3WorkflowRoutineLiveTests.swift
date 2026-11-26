import Foundation
import Testing
@testable import BottoCore

@MainActor @Suite(.timeLimit(.minutes(3))) struct T3WorkflowRoutineLiveTests {
    @Test(.enabled("Requires the disposable Routine workflow harness") {
        ProcessInfo.processInfo.environment["BOTTO_TEST_T3_WORKFLOW_PAIRING_URL"] != nil
    }) func proposesTurnsOnReconnectsPausesAnswersAndDeletes() async throws {
        let env = ProcessInfo.processInfo.environment
        let parsed = try T3PairingExchange.parse(try #require(env["BOTTO_TEST_T3_WORKFLOW_PAIRING_URL"]))
        let exchange = T3PairingExchange()
        var pairing = try await exchange.exchangePairingCredential(origin: parsed.origin, credential: parsed.credential,
                                                                    clientLabel: "Botto disposable Routine check").configuration
        let projectID = try #require(env["BOTTO_TEST_T3_WORKFLOW_PROJECT"])
        let workspace = try #require(env["BOTTO_TEST_T3_WORKFLOW_ROOT"])
        pairing.t3?.projectID = projectID
        pairing.t3?.workspaceRoot = workspace
        let threadID = try #require(env["BOTTO_TEST_T3_WORKFLOW_SPACE"])
        let service = T3BotService()
        defer { service.disconnect() }

        _ = try await service.connect(configuration: pairing)
        #expect(service.workflowRoutinesAvailable)
        let spaces = service.currentT3Channels.map(\.id)
        let existing = try await service.listRoutines()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let due = Date(timeIntervalSince1970: ceil((Date.now.timeIntervalSince1970 + 18) / 60) * 60)
        let parts = utc.dateComponents([.hour, .minute, .weekday], from: due)
        let day = try #require(parts.weekday) - 1
        let hour = try #require(parts.hour)
        let minute = try #require(parts.minute)
        let schedule = try #require(T3RoutineSchedule(hour: hour, minute: minute, days: [day]))
        let proposal = try service.proposeWorkflowRoutine(name: "Review the plan", prompt: "Read the sample plan.",
                                                          schedule: schedule, threadID: threadID)
        let failure = try service.proposeWorkflowRoutine(name: "Check the model", prompt: "Read the sample plan.",
                                                         schedule: schedule, threadID: threadID)
        #expect(try await service.listWorkflowRoutines().isEmpty)
        let installed = try await service.turnOnWorkflowRoutine(proposal)
        #expect(installed.enabled)
        #expect(try await service.turnOnWorkflowRoutine(proposal) == installed)
        let installedFailure = try await service.turnOnWorkflowRoutine(failure)
        service.disconnect()

        _ = try await service.connect(configuration: pairing)
        #expect(try await service.listWorkflowRoutines() == [installedFailure, installed])
        let watched = try await service.watchWorkflowRoutineActivity(threadID: threadID)
        var questions: [T3WorkflowRoutineQuestion] = []
        for try await activity in watched {
            questions = activity.compactMap(\.question)
            if questions.count == 2 { break }
        }
        let question = try #require(questions.first { $0.proposal == proposal })
        let failureQuestion = try #require(questions.first { $0.proposal == failure })
        #expect(question.choices == ["Run", "Skip"])
        let paused = try await service.setWorkflowRoutineEnabled(installed, enabled: false)
        #expect(!paused.enabled)
        #expect(try await service.workflowRoutineActivity(threadID: threadID).contains { $0.question == question })
        await #expect(throws: T3WorkflowRoutineError.deleteRejected) {
            try await service.deleteWorkflowRoutine(paused)
        }
        let identity = try T3ProjectionMapper.identity(profile: ExactID(projectID), threadID: threadID)
        let opened = try await service.openChat(.stored(identity))
        try await service.answerWorkflowRoutineQuestion(question, choice: "Skip", access: opened.access)
        let result = try await waitFor(seconds: 12, "Routine result") {
            try await service.workflowRoutineActivity(threadID: threadID).first { $0.id == question.runID }?.result
        }
        #expect(result == "Skipped")
        await #expect(throws: T3WorkflowRoutineError.questionChanged) {
            try await service.answerWorkflowRoutineQuestion(question, choice: "Run", access: opened.access)
        }

        // The disposable engine has no provider login. Run must end and leave its Routine deletable.
        try await service.answerWorkflowRoutineQuestion(failureQuestion, choice: "Run", access: opened.access)
        let failureResult = try await waitFor(seconds: 30, "Routine failure result") {
            try await service.workflowRoutineActivity(threadID: threadID).first { $0.id == failureQuestion.runID }?.result
        }
        #expect(failureResult == "Couldn’t finish. Check T3 Code.")
        try await service.deleteWorkflowRoutine(installedFailure)
        try await service.deleteWorkflowRoutine(paused)
        #expect(try await service.listWorkflowRoutines().isEmpty)
        #expect(try await service.listRoutines() == existing)
        #expect(service.currentT3Channels.map(\.id) == spaces)
    }

    private func waitFor<Value>(seconds: Int, _ description: String,
                                read: () async throws -> Value?) async throws -> Value {
        let deadline = ContinuousClock.now + .seconds(seconds)
        repeat {
            if let value = try await read() { return value }
            try await Task.sleep(for: .seconds(1))
        } while ContinuousClock.now < deadline
        Issue.record("Timed out waiting for \(description)")
        throw T3RPCError.timeout
    }
}
