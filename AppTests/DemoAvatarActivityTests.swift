import XCTest
import BottoCore
@testable import Botto

@MainActor final class DemoAvatarActivityTests: XCTestCase {
    func testCompletedReplyCelebratesButStopAndReopenDoNotReplaySuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("reply-1.hold"))
        try Data().write(to: directory.appendingPathComponent("reply-2.hold"))
        let service: any BotService = DemoBotService(gateDirectory: directory, performanceFixture: false)
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!))
        defer { service.disconnect() }
        let created = try await service.createConversation(profile: ExactID("milo"), operationID: UUID())
        let opened = try await service.openChat(.stored(created.summary.identity))
        var publications: [OpenedConversation] = []
        service.onEvent = { if case .conversation(let value) = $0 { publications.append(value) } }

        _ = try await service.send(text: "Complete this turn", attachments: [], access: opened.access, operationID: UUID())
        let working = try XCTUnwrap(publications.last?.activity)
        XCTAssertEqual(working.phase, .working)
        XCTAssertNotNil(working.workStartedAt)
        XCTAssertEqual(working.phaseStartedAt, working.workStartedAt)
        XCTAssertNil(working.reaction)
        try await waitUntil { FileManager.default.fileExists(atPath: directory.appendingPathComponent("reply-1.started").path) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-1.hold"))
        try await waitUntil { publications.last?.snapshot.isWorking == false }
        let completed = try XCTUnwrap(publications.last?.activity)
        XCTAssertEqual(completed.lineage, working.lineage)
        XCTAssertNil(completed.phase)
        XCTAssertEqual(completed.reaction?.kind, .succeeded)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(completed.reaction?.occurredAt), try XCTUnwrap(working.workStartedAt))

        let reopened = try await service.openChat(.stored(created.summary.identity))
        XCTAssertNil(reopened.activity?.reaction)
        XCTAssertNotEqual(reopened.activity?.lineage, completed.lineage)
        publications = []
        _ = try await service.send(text: "Stop this turn", attachments: [], access: reopened.access, operationID: UUID())
        XCTAssertEqual(publications.last?.activity?.phase, .working)
        _ = try await service.stop(access: reopened.access, operationID: UUID())
        XCTAssertEqual(publications.last?.snapshot.isWorking, false)
        XCTAssertNil(publications.last?.activity?.phase)
        XCTAssertTrue(publications.allSatisfy { $0.activity?.reaction == nil })
        XCTAssertEqual(publications.last?.activity?.signal?.kind, .stopped)
        let afterStop = try await service.openChat(.stored(created.summary.identity))
        XCTAssertNil(afterStop.activity?.reaction)
        XCTAssertNil(afterStop.activity?.phase)
        XCTAssertNil(afterStop.activity?.signal)
    }

    func testPerformanceReplyPublishesRealTextBeforeReplyingAndKeepsPhaseClockStable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("performance-stream.hold"))
        let service: any BotService = DemoBotService(gateDirectory: directory, performanceFixture: true)
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!))
        defer { service.disconnect() }
        let created = try await service.createConversation(profile: ExactID("milo"), operationID: UUID())
        let opened = try await service.openChat(.stored(created.summary.identity))
        var publications: [OpenedConversation] = []
        service.onEvent = { if case .conversation(let value) = $0 { publications.append(value) } }
        _ = try await service.send(text: "Stream a reply", attachments: [], access: opened.access, operationID: UUID())
        try await waitUntil {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("performance-stream.started").path)
        }
        let placeholder = try XCTUnwrap(publications.first { $0.snapshot.messages.last?.role == .assistant })
        XCTAssertEqual(placeholder.snapshot.messages.last?.text, "")
        XCTAssertEqual(placeholder.activity?.phase, .working)
        let chunks = publications.filter { $0.activity?.phase == .replying }
        XCTAssertEqual(chunks.count, 20)
        XCTAssertTrue(chunks.allSatisfy { $0.activity?.signal?.kind == .replyText })
        XCTAssertEqual(Set(chunks.compactMap { $0.activity?.signal?.id }).count, 20)
        let first = try XCTUnwrap(chunks.first?.activity)
        XCTAssertEqual(chunks.first?.snapshot.messages.last?.text, "Word 0. ")
        XCTAssertEqual(first.workStartedAt, placeholder.activity?.workStartedAt)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(first.phaseStartedAt), try XCTUnwrap(first.workStartedAt))
        XCTAssertTrue(chunks.allSatisfy {
            $0.activity?.lineage == first.lineage &&
            $0.activity?.workStartedAt == first.workStartedAt &&
            $0.activity?.phaseStartedAt == first.phaseStartedAt &&
            $0.activity?.reaction == nil
        })
        _ = try await service.stop(access: opened.access, operationID: UUID())
        XCTAssertNil(publications.last?.activity?.reaction)
        XCTAssertNil(publications.last?.activity?.phase)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("performance-stream.hold"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(3)
        while !condition() {
            guard Date.now < deadline else { throw HermesServiceError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
