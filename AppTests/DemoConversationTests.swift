import XCTest
import BottoCore
@testable import Botto

@MainActor final class DemoConversationTests: XCTestCase {
    private func connected() async throws -> any BotService {
        let service = DemoBotService()
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!))
        return service
    }

    func testQueuedAdmissionsDrainInFIFOOrderWithoutRestartingActiveReply() async throws {
        let directory = try makeGateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("reply-1.hold"))
        try Data().write(to: directory.appendingPathComponent("reply-2.hold"))
        try Data().write(to: directory.appendingPathComponent("reply-3.hold"))
        let service = DemoBotService(gateDirectory: directory, performanceFixture: false)
        let opened = try await emptyConversation(service)
        var latest = opened.snapshot
        service.onEvent = { if case .conversation(let value) = $0 { latest = value.snapshot } }
        _ = try await service.send(text: "Active", attachments: [], access: opened.access, operationID: UUID())
        try await waitForMarker("reply-1.started", directory: directory)
        let first = UUID(), second = UUID()
        _ = try await service.send(text: "First pending", attachments: [], access: opened.access, operationID: first)
        _ = try await service.send(text: "Second pending", attachments: [], access: opened.access, operationID: second)
        XCTAssertEqual(latest.queuedMessages.map(\.text), ["First pending", "Second pending"])
        XCTAssertEqual(latest.queuedMessages.map(\.submissionID), [first.uuidString, second.uuidString])
        XCTAssertTrue(latest.queuedMessages.allSatisfy(\.canEdit))
        XCTAssertFalse(latest.messages.contains { $0.role == .assistant })

        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-1.hold"))
        try await waitForMarker("reply-2.started", directory: directory)
        XCTAssertTrue(latest.isWorking)
        XCTAssertEqual(latest.queuedMessages.map(\.text), ["Second pending"])
        XCTAssertEqual(latest.messages.last?.id, "submission:" + first.uuidString)
        XCTAssertEqual(latest.messages.filter { $0.role == .assistant }.count, 1)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-2.hold"))
        try await waitForMarker("reply-3.started", directory: directory)
        XCTAssertTrue(latest.queuedMessages.isEmpty)
        XCTAssertEqual(latest.messages.last?.id, "submission:" + second.uuidString)
        XCTAssertEqual(latest.messages.filter { $0.role == .assistant }.count, 2)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-3.hold"))
        try await waitUntil { !latest.isWorking }
        XCTAssertEqual(latest.messages.filter { $0.role == .assistant }.count, 3)
        XCTAssertEqual(latest.messages.filter { $0.role == .user }.map(\.text),
                       ["Active", "First pending", "Second pending"])
    }

    func testReplacingPendingMessagePreservesMultilineTextAndAdmitsAtTail() async throws {
        let directory = try makeGateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("reply-1.hold"))
        let service = DemoBotService(gateDirectory: directory, performanceFixture: false)
        let opened = try await emptyConversation(service)
        var latest = opened.snapshot
        var sources: [SessionIdentity] = []
        service.onEvent = {
            if case .conversation(let value) = $0 { latest = value.snapshot; sources.append(value.identity) }
        }
        _ = try await service.send(text: "Active", attachments: [], access: opened.access, operationID: UUID())
        try await waitForMarker("reply-1.started", directory: directory)
        let oldOperation = UUID()
        _ = try await service.send(text: "Original", attachments: [], access: opened.access, operationID: oldOperation)
        _ = try await service.send(text: "Already waiting", attachments: [], access: opened.access, operationID: UUID())
        let original = try XCTUnwrap(latest.queuedMessages.first)
        var changedOriginal = original
        changedOriginal.text = "A different original"
        do {
            _ = try await service.replaceQueuedMessage(changedOriginal, text: "Unconfirmed edit", access: opened.access, operationID: UUID())
            XCTFail("An admission ID alone cannot replace a different original payload")
        } catch { XCTAssertEqual(error as? HermesServiceError, .queuedMessageUnavailable) }
        XCTAssertEqual(latest.queuedMessages.map(\.text), ["Original", "Already waiting"])
        let editOperation = UUID()
        let editedText = "  First line\n\nSecond line\n  Last line  \n"
        let receipt = try await service.replaceQueuedMessage(original, text: editedText,
            access: opened.access, operationID: editOperation)
        XCTAssertEqual(receipt.operationID, editOperation)
        XCTAssertEqual(receipt.source, opened.identity)
        XCTAssertEqual(receipt.admissionID, editOperation.uuidString)
        XCTAssertEqual(receipt.journal, .saved)
        XCTAssertEqual(latest.queuedMessages.map(\.text), ["Already waiting", editedText])
        let edited = try XCTUnwrap(latest.queuedMessages.last)
        XCTAssertEqual(edited.id, editOperation.uuidString)
        XCTAssertEqual(edited.submissionID, editOperation.uuidString)
        XCTAssertTrue(edited.canEdit)
        XCTAssertFalse(latest.messages.contains { $0.id == "submission:" + oldOperation.uuidString })
        XCTAssertEqual(latest.messages.filter { $0.id == "submission:" + editOperation.uuidString }.map(\.text), [editedText])
        XCTAssertTrue(sources.allSatisfy { $0 == opened.identity })
        do {
            _ = try await service.replaceQueuedMessage(original, text: "Replay", access: opened.access, operationID: editOperation)
            XCTFail("An operation UUID cannot admit a second edit")
        } catch { XCTAssertEqual(error as? HermesServiceError, .staleConversation) }
        do {
            _ = try await service.replaceQueuedMessage(original, text: "Stale editor", access: opened.access, operationID: UUID())
            XCTFail("The old admission retired when it was replaced")
        } catch { XCTAssertEqual(error as? HermesServiceError, .queuedMessageUnavailable) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-1.hold"))
        try await waitUntil { !latest.isWorking }
        XCTAssertEqual(latest.messages.filter { $0.role == .user }.map(\.text), ["Active", "Already waiting", editedText])
        XCTAssertEqual(latest.messages.filter { $0.role == .assistant }.count, 3)
    }

    func testMessageStartingBeforeSaveCannotBecomeANewTurn() async throws {
        try await assertStartedMessageCannotBeReplaced(afterSaveBegins: false)
    }

    func testMessageStartingWhileSaveWaitsCannotBecomeANewTurn() async throws {
        try await assertStartedMessageCannotBeReplaced(afterSaveBegins: true)
    }

    func testConcurrentReplacementRetiresOriginalAdmissionWhileFirstSaveWaits() async throws {
        let directory = try makeGateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("reply-1.hold"))
        try Data().write(to: directory.appendingPathComponent("replace-queued-1.hold"))
        let service = DemoBotService(gateDirectory: directory, performanceFixture: false)
        let opened = try await emptyConversation(service)
        var latest = opened.snapshot
        service.onEvent = { if case .conversation(let value) = $0 { latest = value.snapshot } }
        _ = try await service.send(text: "Active", attachments: [], access: opened.access, operationID: UUID())
        try await waitForMarker("reply-1.started", directory: directory)
        _ = try await service.send(text: "Original", attachments: [], access: opened.access, operationID: UUID())
        let original = try XCTUnwrap(latest.queuedMessages.first)
        let heldEdit = Task {
            try await service.replaceQueuedMessage(original, text: "Obsolete edit", access: opened.access, operationID: UUID())
        }
        try await waitForMarker("replace-queued-1.started", directory: directory)
        let winningOperation = UUID()
        _ = try await service.replaceQueuedMessage(original, text: "Confirmed edit", access: opened.access, operationID: winningOperation)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("replace-queued-1.hold"))
        do { _ = try await heldEdit.value; XCTFail("A different edit already retired this admission") }
        catch { XCTAssertEqual(error as? HermesServiceError, .queuedMessageUnavailable) }
        XCTAssertEqual(latest.queuedMessages.map(\.text), ["Confirmed edit"])
        XCTAssertEqual(latest.queuedMessages.map(\.id), [winningOperation.uuidString])
        XCTAssertEqual(latest.messages.filter { $0.role == .user }.map(\.text), ["Active", "Confirmed edit"])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-1.hold"))
        try await waitUntil { !latest.isWorking }
        XCTAssertEqual(latest.messages.filter { $0.role == .assistant }.count, 2)
    }

    func testQueuedAttachmentsAreReadOnlyEvenIfCallerClaimsEditCapability() async throws {
        let directory = try makeGateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("reply-1.hold"))
        let service = DemoBotService(gateDirectory: directory, performanceFixture: false)
        let opened = try await emptyConversation(service)
        var latest = opened.snapshot
        service.onEvent = { if case .conversation(let value) = $0 { latest = value.snapshot } }
        _ = try await service.send(text: "Active", attachments: [], access: opened.access, operationID: UUID())
        try await waitForMarker("reply-1.started", directory: directory)
        let file = try await service.upload(data: Data("file".utf8), filename: "notes.txt", mimeType: "text/plain", access: opened.access)
        let operation = UUID()
        _ = try await service.send(text: "With a file", attachments: [file], access: opened.access, operationID: operation)
        let queued = try XCTUnwrap(latest.queuedMessages.first)
        XCTAssertFalse(queued.canEdit)
        XCTAssertEqual(queued.submissionID, operation.uuidString)
        var forged = queued
        forged.canEdit = true
        for candidate in [queued, forged] {
            do {
                _ = try await service.replaceQueuedMessage(candidate, text: "Drop the file", access: opened.access, operationID: UUID())
                XCTFail("An attachment admission cannot be edited as text")
            } catch { XCTAssertEqual(error as? HermesServiceError, .queuedMessageUnavailable) }
        }
        XCTAssertEqual(latest.queuedMessages, [queued])
        XCTAssertEqual(latest.messages.last?.attachments, [file])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-1.hold"))
        try await waitUntil { !latest.isWorking }
        XCTAssertEqual(latest.messages.filter { $0.role == .user }.map(\.text), ["Active", "With a file"])
        XCTAssertEqual(latest.messages.first { $0.id == "submission:" + operation.uuidString }?.attachments, [file])
        XCTAssertEqual(latest.messages.filter { $0.role == .assistant }.count, 2)
    }

    func testStopPromotesAcceptedQueueInsteadOfDiscardingIt() async throws {
        let directory = try makeGateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for number in 1...3 { try Data().write(to: directory.appendingPathComponent("reply-\(number).hold")) }
        let service = DemoBotService(gateDirectory: directory, performanceFixture: false)
        let opened = try await emptyConversation(service)
        var latest = opened.snapshot
        service.onEvent = { if case .conversation(let value) = $0 { latest = value.snapshot } }
        _ = try await service.send(text: "Interrupted", attachments: [], access: opened.access, operationID: UUID())
        try await waitForMarker("reply-1.started", directory: directory)
        _ = try await service.send(text: "First accepted", attachments: [], access: opened.access, operationID: UUID())
        _ = try await service.send(text: "Second accepted", attachments: [], access: opened.access, operationID: UUID())
        _ = try await service.stop(access: opened.access, operationID: UUID())
        XCTAssertTrue(latest.isWorking)
        XCTAssertEqual(latest.queuedMessages.map(\.text), ["Second accepted"])
        XCTAssertEqual(latest.messages.last?.text, "First accepted")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-1.hold"))
        try await waitForMarker("reply-2.started", directory: directory)
        _ = try await service.stop(access: opened.access, operationID: UUID())
        XCTAssertTrue(latest.isWorking)
        XCTAssertTrue(latest.queuedMessages.isEmpty)
        XCTAssertEqual(latest.messages.last?.text, "Second accepted")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-2.hold"))
        try await waitForMarker("reply-3.started", directory: directory)
        XCTAssertFalse(latest.messages.contains { $0.role == .assistant }, "Stopped completions cannot affect the promoted turn")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-3.hold"))
        try await waitUntil { !latest.isWorking }
        XCTAssertEqual(latest.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(latest.messages.filter { $0.role == .user }.map(\.text), ["Interrupted", "First accepted", "Second accepted"])
    }

    func testPerformanceStreamSurvivesSteeringAndDrainsQueuedFollowup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hold = directory.appendingPathComponent("performance-stream.hold")
        try Data().write(to: hold)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DemoBotService(gateDirectory: directory, performanceFixture: true)
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!))
        defer { service.disconnect() }
        let opened = try await service.openChat(.canonical(profile: ExactID("scout"), expectedRoot: nil))
        var latest = opened.snapshot
        service.onEvent = { if case .conversation(let value) = $0 { latest = value.snapshot } }
        _ = try await service.send(text: "Start", attachments: [], access: opened.access, operationID: UUID())
        let started = directory.appendingPathComponent("performance-stream.started")
        let startDeadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        _ = try await service.send(text: "Steer this reply", attachments: [], delivery: .steer, access: opened.access, operationID: UUID())
        XCTAssertTrue(latest.queuedMessages.isEmpty, "Steering belongs to the active turn")
        let queueOperation = UUID()
        _ = try await service.send(text: "Queue another reply", attachments: [], delivery: .queue, access: opened.access, operationID: queueOperation)
        let queued = try XCTUnwrap(latest.queuedMessages.first)
        XCTAssertEqual(queued.text, "Queue another reply")
        XCTAssertEqual(queued.submissionID, queueOperation.uuidString)
        XCTAssertTrue(queued.canEdit)
        _ = try await service.send(text: "Keep both admissions", attachments: [], delivery: .steer, access: opened.access, operationID: UUID())
        XCTAssertEqual(latest.queuedMessages, [queued], "Steering cannot consume an accepted follow-up")
        let active = try XCTUnwrap(latest.messages.first { $0.id == "performance-reply-1" })
        XCTAssertTrue(active.text.contains("Word 19."))
        XCTAssertFalse(active.text.contains("Word 199."))
        try FileManager.default.removeItem(at: hold)
        let completionDeadline = ContinuousClock.now + .seconds(15)
        while latest.isWorking, ContinuousClock.now < completionDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(latest.isWorking)
        XCTAssertTrue(latest.queuedMessages.isEmpty)
        for number in 1...2 {
            let reply = try XCTUnwrap(latest.messages.first { $0.id == "performance-reply-\(number)" })
            XCTAssertTrue(reply.text.contains("Word 199."))
            XCTAssertTrue(reply.text.contains("Performance stream \(number) complete."))
        }
        XCTAssertEqual(latest.messages.filter { $0.role == .user && $0.text == "Steer this reply" }.count, 1)
        XCTAssertEqual(latest.messages.filter { $0.role == .user && $0.text == "Keep both admissions" }.count, 1)
        XCTAssertEqual(latest.messages.filter { $0.id == "submission:" + queueOperation.uuidString }.count, 1)
        XCTAssertEqual(latest.messages.filter { $0.id.hasPrefix("performance-reply-") }.count, 2)
    }

    func testReadEvidenceMatchesCompleteLocalReadsAndSelectedPublications() async throws {
        let service = try await connected()
        defer { service.disconnect() }
        let profile = try ExactID("milo")
        let main = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
        let initial = try XCTUnwrap(main.readEvidence?.summaryObservedBeforeRead)
        let directory = try await service.conversations(profile: profile)
        XCTAssertEqual(initial, directory.summaries.first(where: \.isCanonical))
        XCTAssertEqual(initial.identity, main.identity)

        let sideSummary = try XCTUnwrap(directory.summaries.first { !$0.isCanonical })
        let side = try await service.openChat(.stored(sideSummary.identity))
        XCTAssertEqual(side.readEvidence?.summaryObservedBeforeRead, sideSummary)
        var publications: [OpenedConversation] = []
        service.onEvent = { if case .conversation(let value) = $0 { publications.append(value) } }
        _ = try await service.send(text: "A complete local update", attachments: [],
                                   access: side.access, operationID: UUID())
        let updated = try XCTUnwrap(publications.last)
        let current = try await service.conversations(profile: profile)
        XCTAssertEqual(updated.identity, side.identity)
        XCTAssertEqual(updated.snapshot.messages.last?.text, "A complete local update")
        XCTAssertEqual(updated.readEvidence?.summaryObservedBeforeRead,
                       current.summaries.first { $0.identity == side.identity })
        XCTAssertEqual(main.readEvidence?.summaryObservedBeforeRead, initial,
                       "Later local changes cannot backfill an older read witness.")
    }

    func testOrdinaryDemoHasIndependentChatsAndPreservesMain() async throws {
        let service = try await connected()
        let profile = try ExactID("milo")
        let directory = try await service.conversations(profile: profile)
        XCTAssertEqual(directory.summaries.map(\.title), ["Bot Chat", "Weekend plan", "Research notes"])
        let main = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
        XCTAssertEqual(main.snapshot.messages.first?.text, "Help me get a handle on tomorrow.")
        XCTAssertEqual(main.snapshot.pendingRequests.first?.id, "demo-approval")
        let operation = UUID()
        let created = try await service.createConversation(profile: profile, operationID: operation)
        XCTAssertEqual(created.operationID, operation)
        XCTAssertFalse(created.summary.isCanonical)
        XCTAssertNotEqual(created.summary.identity.root, main.identity.root)
        let side = try await service.openChat(.stored(created.summary.identity))
        XCTAssertTrue(side.snapshot.messages.isEmpty)
        let reopened = try await service.openChat(.canonical(profile: profile, expectedRoot: main.identity.root))
        XCTAssertEqual(reopened.identity, main.identity)
        XCTAssertEqual(reopened.snapshot.messages, main.snapshot.messages)
    }
    func testSwitchRetiresAuthorityButKeepsSourceWorkRunning() async throws {
        let service = try await connected()
        let profile = try ExactID("milo")
        let source = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
        let receipt = try await service.send(text: "Only Main", attachments: [], access: source.access, operationID: UUID())
        let directory = try await service.conversations(profile: profile)
        let sideIdentity = try XCTUnwrap(directory.summaries.first { !$0.isCanonical }?.identity)
        let side = try await service.openChat(.stored(sideIdentity))
        var publications: [OpenedConversation] = []
        service.onEvent = { event in if case .conversation(let value) = event { publications.append(value) } }
        do {
            _ = try await service.send(text: "Stale", attachments: [], access: source.access, operationID: UUID())
            XCTFail("A retired grant must never dispatch")
        } catch { XCTAssertEqual(error as? HermesServiceError, .staleConversation) }
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(publications.isEmpty, "A’s completion must not publish into selected B")
        let b = try await service.openChat(.stored(side.identity))
        XCTAssertFalse(b.snapshot.messages.contains { $0.text == "Only Main" })
        let a = try await service.openChat(.stored(source.identity))
        XCTAssertEqual(receipt.source, a.identity)
        XCTAssertFalse(a.snapshot.isWorking)
        XCTAssertTrue(a.snapshot.messages.contains { $0.text.contains("You’ve got the idea.") })
    }

    func testArtifactsCannotCrossSiblingChatAndCanvasMainStaysOwned() async throws {
        let service = try await connected()
        let canvas = try await service.openChat(.canonical(profile: try ExactID("canvas"), expectedRoot: nil))
        let report = ChatAttachment(name: "report.pdf", path: "/demo/canvas/report.pdf", mimeType: "application/pdf")
        let data = try await service.downloadArtifact(report, access: canvas.access)
        XCTAssertTrue(data.data.starts(with: Data("%PDF".utf8)))
        let created = try await service.createConversation(profile: canvas.identity.profile, operationID: UUID())
        let side = try await service.openChat(.stored(created.summary.identity))
        do {
            _ = try await service.downloadArtifact(report, access: side.access)
            XCTFail("Main’s historical file is not a sibling’s file")
        } catch { XCTAssertEqual(error as? HermesServiceError, .invalidAttachment) }
        let file = try await service.upload(data: Data("side".utf8), filename: "notes.txt", mimeType: "text/plain", access: side.access)
        _ = try await service.send(text: "My file", attachments: [file], access: side.access, operationID: UUID())
        let main = try await service.openChat(.stored(canvas.identity))
        do {
            _ = try await service.send(text: "Borrow file", attachments: [file], access: main.access, operationID: UUID())
            XCTFail("Upload belongs to the exact source")
        } catch { XCTAssertEqual(error as? HermesServiceError, .invalidAttachment) }
    }

    func testRecoveryAndOtherServiceCannotReviveRetiredGrants() async throws {
        let service = try await connected()
        let main = try await service.openChat(.canonical(profile: try ExactID("milo"), expectedRoot: nil))
        service.disconnect()
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!))
        let reopened = try await service.openChat(.stored(main.identity))
        XCTAssertEqual(main.identity, reopened.identity)
        for candidate in [service, try await connected()] {
            do {
                _ = try await candidate.stop(access: main.access, operationID: UUID())
                XCTFail("A grant is issued by one live attachment only")
            } catch { XCTAssertEqual(error as? HermesServiceError, .staleConversation) }
        }
        let wrongProfile = SessionIdentity(profile: try ExactID("Milo"), root: main.identity.root,
                                           stored: main.identity.stored, aliases: main.identity.aliases)
        do {
            _ = try await service.openChat(.stored(wrongProfile))
            XCTFail("Profile case is identity")
        } catch { XCTAssertEqual(error as? HermesServiceError, .profileUnavailable) }
    }

    func testRequestMustStillExistInExactSource() async throws {
        let service = try await connected()
        let main = try await service.openChat(.canonical(profile: try ExactID("milo"), expectedRoot: nil))
        let request = try XCTUnwrap(main.snapshot.pendingRequests.first)
        let side = try await service.createConversation(profile: main.identity.profile, operationID: UUID())
        let other = try await service.openChat(.stored(side.summary.identity))
        do {
            _ = try await service.respond(to: request, response: .choice("once"), access: other.access, operationID: UUID())
            XCTFail("Matching request IDs outside their source cannot authorize a response")
        } catch { XCTAssertEqual(error as? HermesServiceError, .staleConversation) }
        let reopened = try await service.openChat(.stored(main.identity))
        _ = try await service.respond(to: request, response: .choice("deny"), access: reopened.access, operationID: UUID())
        do {
            _ = try await service.respond(to: request, response: .choice("once"), access: reopened.access, operationID: UUID())
            XCTFail("An already answered request must retire")
        } catch { XCTAssertEqual(error as? HermesServiceError, .staleConversation) }
    }

    func testLateAdmissionReceiptStaysWithSourceAfterSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service: any BotService = DemoBotService(gateDirectory: directory)
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!))
        let main = try await service.openChat(.canonical(profile: try ExactID("milo"), expectedRoot: nil))
        let side = try await service.createConversation(profile: main.identity.profile, operationID: UUID())
        let hold = directory.appendingPathComponent("send-ack.hold")
        try Data().write(to: hold)
        let operation = UUID()
        let send = Task { try await service.send(text: "ACK for Main", attachments: [], access: main.access, operationID: operation) }
        try await waitForMarker("send-ack.started", directory: directory)
        _ = try await service.openChat(.stored(side.summary.identity))
        try FileManager.default.removeItem(at: hold)
        let receipt = try await send.value
        XCTAssertEqual(receipt.source, main.identity)
        XCTAssertEqual(receipt.operationID, operation)
        let b = try await service.openChat(.stored(side.summary.identity))
        XCTAssertTrue(b.snapshot.messages.isEmpty)
        let a = try await service.openChat(.stored(main.identity))
        XCTAssertTrue(a.snapshot.messages.contains { $0.text == "ACK for Main" })
    }

    func testOlderOpenCannotRetireNewerAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service: any BotService = DemoBotService(gateDirectory: directory)
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!))
        let main = try await service.openChat(.canonical(profile: try ExactID("milo"), expectedRoot: nil))
        let side = try await service.createConversation(profile: main.identity.profile, operationID: UUID())
        let hold = directory.appendingPathComponent("open-2.hold")
        try Data().write(to: hold)
        let oldOpen = Task { try await service.openChat(.stored(main.identity)) }
        try await waitForMarker("open-2.started", directory: directory)
        let b = try await service.openChat(.stored(side.summary.identity))
        try FileManager.default.removeItem(at: hold)
        do { _ = try await oldOpen.value; XCTFail("Old attachment must retire") }
        catch { XCTAssertEqual(error as? HermesServiceError, .staleConversation) }
        let receipt = try await service.send(text: "Still B", attachments: [], access: b.access, operationID: UUID())
        XCTAssertEqual(receipt.source, b.identity)
    }

    func testStagingSurvivesNavigationAndRejectsHistoryForgeryReplayAndRecovery() async throws {
        let service = try await connected()
        let source = try await service.openChat(.canonical(profile: try ExactID("canvas"), expectedRoot: nil))
        let uploaded = try await service.upload(data: Data("hello".utf8), filename: "hello.txt", mimeType: "text/plain", access: source.access)
        XCTAssertNotNil(uploaded.stagingID)
        let side = try await service.createConversation(profile: source.identity.profile, operationID: UUID())
        let b = try await service.openChat(.stored(side.summary.identity))
        do {
            _ = try await service.send(text: "Wrong source", attachments: [uploaded], access: b.access, operationID: UUID())
            XCTFail("A’s upload token cannot send in B")
        } catch { XCTAssertEqual(error as? HermesServiceError, .invalidAttachment) }
        let reopened = try await service.openChat(.stored(source.identity))
        var forged = uploaded
        forged.name = "forged.txt"
        do {
            _ = try await service.send(text: "Forged descriptor", attachments: [forged], access: reopened.access, operationID: UUID())
            XCTFail("The complete upload descriptor must match")
        } catch { XCTAssertEqual(error as? HermesServiceError, .invalidAttachment) }
        let historical = ChatAttachment(name: "report.pdf", path: "/demo/canvas/report.pdf", mimeType: "application/pdf")
        do {
            _ = try await service.send(text: "Historical path", attachments: [historical], access: reopened.access, operationID: UUID())
            XCTFail("A historical downloadable path is not an upload grant")
        } catch { XCTAssertEqual(error as? HermesServiceError, .invalidAttachment) }
        _ = try await service.send(text: "Preserved upload", attachments: [uploaded], access: reopened.access, operationID: UUID())
        do {
            _ = try await service.send(text: "Already admitted", attachments: [uploaded], access: reopened.access, operationID: UUID())
            XCTFail("An admitted upload token is consumed")
        } catch { XCTAssertEqual(error as? HermesServiceError, .invalidAttachment) }
        let pending = try await service.upload(data: Data("fresh".utf8), filename: "hello.txt", mimeType: "text/plain", access: reopened.access)
        XCTAssertNotEqual(pending.stagingID, uploaded.stagingID)
        service.disconnect()
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!))
        let recovered = try await service.openChat(.stored(source.identity))
        do {
            _ = try await service.send(text: "Prior connection", attachments: [pending], access: recovered.access, operationID: UUID())
            XCTFail("Recovery retires upload capabilities")
        } catch { XCTAssertEqual(error as? HermesServiceError, .invalidAttachment) }
    }

    func testUploadAcquisitionCannotFinishInReplacementChat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service: any BotService = DemoBotService(gateDirectory: directory)
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!))
        let source = try await service.openChat(.canonical(profile: try ExactID("canvas"), expectedRoot: nil))
        let side = try await service.createConversation(profile: source.identity.profile, operationID: UUID())
        let hold = directory.appendingPathComponent("upload.hold")
        try Data().write(to: hold)
        let upload = Task { try await service.upload(data: Data("late".utf8), filename: "late.txt", mimeType: "text/plain", access: source.access) }
        try await waitForMarker("upload.started", directory: directory)
        let b = try await service.openChat(.stored(side.summary.identity))
        try FileManager.default.removeItem(at: hold)
        do { _ = try await upload.value; XCTFail("Acquisition retired before dispatch cannot grant a file") }
        catch { XCTAssertEqual(error as? HermesServiceError, .staleConversation) }
        let receipt = try await service.send(text: "Still B", attachments: [], access: b.access, operationID: UUID())
        XCTAssertEqual(receipt.source, b.identity)
    }

    func testCreateFromRetiredConnectionCannotAppendToRecoveredDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service: any BotService = DemoBotService(gateDirectory: directory)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!)
        _ = try await service.connect(configuration: configuration)
        let profile = try ExactID("milo")
        let hold = directory.appendingPathComponent("create-chat.hold")
        try Data().write(to: hold)
        let create = Task { try await service.createConversation(profile: profile, operationID: UUID()) }
        try await waitForMarker("create-chat.started", directory: directory)
        service.disconnect()
        _ = try await service.connect(configuration: configuration)
        try FileManager.default.removeItem(at: hold)
        do { _ = try await create.value; XCTFail("Retired pre-dispatch create cannot mutate recovered session") }
        catch { XCTAssertEqual(error as? HermesServiceError, .staleConversation) }
        let current = try await service.conversations(profile: profile)
        XCTAssertEqual(current.summaries.count, 3)
    }

    func testConcurrentWorkAndStopRemainIndependentPerChat() async throws {
        let service = try await connected()
        let profile = try ExactID("milo")
        let a = try await service.createConversation(profile: profile, operationID: UUID())
        let b = try await service.createConversation(profile: profile, operationID: UUID())
        let first = try await service.openChat(.stored(a.summary.identity))
        _ = try await service.send(text: "A work", attachments: [], access: first.access, operationID: UUID())
        let second = try await service.openChat(.stored(b.summary.identity))
        _ = try await service.send(text: "B work", attachments: [], access: second.access, operationID: UUID())
        _ = try await service.stop(access: second.access, operationID: UUID())
        let directory = try await service.conversations(profile: profile)
        if case .known(.working, _) = directory.activity[a.summary.identity] {} else { XCTFail("A is still working") }
        if case .known(.idle, _) = directory.activity[b.summary.identity] {} else { XCTFail("Only B stopped") }
        try await Task.sleep(for: .milliseconds(1000))
        let completed = try await service.openChat(.stored(a.summary.identity))
        XCTAssertTrue(completed.snapshot.messages.contains { $0.role == .assistant })
        let stopped = try await service.openChat(.stored(b.summary.identity))
        XCTAssertFalse(stopped.snapshot.messages.contains { $0.role == .assistant })
    }

    func testRosterRefreshSamplesCompletedSiblingActivityWithoutChangingSelection() async throws {
        let service = try await connected()
        let profile = try ExactID("milo")
        let created = try await service.createConversation(profile: profile, operationID: UUID())
        let source = try await service.openChat(.stored(created.summary.identity))
        _ = try await service.send(text: "Work in A", attachments: [], access: source.access, operationID: UUID())
        let directory = try await service.conversations(profile: profile)
        let target = try XCTUnwrap(directory.summaries.first { $0.title == "Weekend plan" })
        let b = try await service.openChat(.stored(target.identity))
        var latest: [SessionIdentity: ObservedActivity] = [:]
        var profiles: [ExactID] = []
        var conversationPublications = 0
        service.onEvent = { event in
            switch event {
            case .activityBatch(let updates):
                for update in updates {
                    profiles.append(update.profile)
                    for (identity, activity) in update.observations { latest[identity] = activity }
                }
            case .conversation: conversationPublications += 1
            default: break
            }
        }
        _ = try await service.bots()
        if case .known(.working, _) = latest[source.identity] {} else { XCTFail("Refresh observes A working") }
        try await Task.sleep(for: .milliseconds(1000))
        latest = [:]; profiles = []
        let bots = try await service.bots()
        XCTAssertEqual(profiles, bots.map { try! ExactID($0.id) })
        if case .known(.idle, _) = latest[source.identity] {} else { XCTFail("Refresh observes A’s completion") }
        if case .known(.idle, _) = latest[b.identity] {} else { XCTFail("B remains independently idle") }
        let main = try XCTUnwrap(directory.summaries.first(where: \.isCanonical))
        if case .known(.waiting, _) = latest[main.identity] {} else { XCTFail("An unrelated approval remains waiting") }
        XCTAssertEqual(conversationPublications, 0, "Sampling never publishes A into selected B")
        let receipt = try await service.send(text: "B still selected", attachments: [], access: b.access, operationID: UUID())
        XCTAssertEqual(receipt.source, b.identity, "Sampling never retires or replaces B’s access")
    }

    private func assertStartedMessageCannotBeReplaced(afterSaveBegins: Bool) async throws {
        let directory = try makeGateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("reply-1.hold"))
        try Data().write(to: directory.appendingPathComponent("reply-2.hold"))
        let service = DemoBotService(gateDirectory: directory, performanceFixture: false)
        let opened = try await emptyConversation(service)
        var latest = opened.snapshot
        service.onEvent = { if case .conversation(let value) = $0 { latest = value.snapshot } }
        _ = try await service.send(text: "Active", attachments: [], access: opened.access, operationID: UUID())
        try await waitForMarker("reply-1.started", directory: directory)
        _ = try await service.send(text: "Original pending", attachments: [], access: opened.access, operationID: UUID())
        let original = try XCTUnwrap(latest.queuedMessages.first)
        let editOperation = UUID()
        var replacement: Task<MutationReceipt, Error>?
        if afterSaveBegins {
            try Data().write(to: directory.appendingPathComponent("replace-queued.hold"))
            replacement = Task {
                try await service.replaceQueuedMessage(original, text: "Must not send", access: opened.access, operationID: editOperation)
            }
            try await waitForMarker("replace-queued.started", directory: directory)
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-1.hold"))
        try await waitForMarker("reply-2.started", directory: directory)
        XCTAssertTrue(latest.queuedMessages.isEmpty)
        if afterSaveBegins {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("replace-queued.hold"))
        } else {
            replacement = Task {
                try await service.replaceQueuedMessage(original, text: "Must not send", access: opened.access, operationID: editOperation)
            }
        }
        let attempt = try XCTUnwrap(replacement)
        do { _ = try await attempt.value; XCTFail("The admission is already running") }
        catch { XCTAssertEqual(error as? HermesServiceError, .queuedMessageUnavailable) }
        XCTAssertTrue(latest.queuedMessages.isEmpty)
        XCTAssertFalse(latest.messages.contains { $0.id == "submission:" + editOperation.uuidString })
        XCTAssertEqual(latest.messages.filter { $0.role == .user }.map(\.text), ["Active", "Original pending"])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("reply-2.hold"))
        try await waitUntil { !latest.isWorking }
        XCTAssertEqual(latest.messages.filter { $0.role == .assistant }.count, 2)
    }

    private func makeGateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func emptyConversation(_ service: DemoBotService) async throws -> OpenedConversation {
        _ = try await service.connect(configuration: ConnectionConfiguration(serverURL: URL(string: "https://demo.invalid")!))
        let created = try await service.createConversation(profile: ExactID("milo"), operationID: UUID())
        return try await service.openChat(.stored(created.summary.identity))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(3)
        while !condition() {
            guard Date.now < deadline else { throw HermesServiceError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForMarker(_ name: String, directory: URL) async throws {
        let deadline = Date.now.addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            guard Date.now < deadline else { throw HermesServiceError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

}
