import Foundation
import Testing
@testable import BottoCore

@MainActor struct QueuedNotificationPresentationTests {
    @Test func authorityPendingProcessUsesProducerIdentityWithoutChangingRawQueue() async throws {
        let host = try HermesTestHost()
        let payload = "[IMPORTANT: Background process proc_53119008f80b completed normally (exit code 0).\nCommand: python3 tools/bot_mode_dm.py --run-delivery\nOutput: delivered]"
        host.snapshot["pending"] = .array([
            .object(["admission_id": .string("process-admission"), "input_id": .string(#"["completion","proc_53119008f80b",1793268000]"#),
                     "text": .string(payload), "status": .string("queued"), "controls": .array([])])
        ])
        let service = host.service()
        defer { service.disconnect() }
        _ = try await service.connect(configuration: host.configuration)
        let opened = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
        let queued = try #require(opened.snapshot.queuedMessages.first)
        #expect(queued.sourceMessage?.displayKind == "process_complete")
        #expect(queued.sourceMessage?.text == payload)
        #expect(queued.text == payload)
        #expect(!queued.canEdit)
    }

    @Test(arguments: [
        #"["async_delegation","deleg_24a7fa61",""]"#,
        #"["async_delegation","deleg_24a7fa61","task_failure:0"]"#,
        #"["watch_match","proc_a","event-a"]"#,
        #"["watch_disabled","proc_a","event-a"]"#,
        #"["heartbeat","proc_a","event-a"]"#
    ])
    func producerIdentityLabelsReadOnlyBackgroundEvents(_ input: String) throws {
        let queued = QueuedMessage(id: "event", text: "Retain the complete producer payload", submissionID: input)
        let source = try #require(queued.sourceMessage)
        #expect(source.role == .user)
        #expect(source.id == queued.id && source.text == queued.text)
        #expect(source.notificationPresentation != nil)
        #expect(try JSONDecoder().decode(QueuedMessage.self, from: JSONEncoder().encode(queued)).sourceMessage == source)
    }

    @Test func queuedBotMessageCarriesSenderWithoutExposingItsMachineStampAsUserText() throws {
        let queued = QueuedMessage(id: "bot-admission", text: "Message from 🤖 Gustavo (@hermes): Please check the service.",
                                   submissionID: "bot:delivery-123")
        let source = try #require(queued.sourceMessage)
        #expect(source.botSender?.name == "Gustavo")
        #expect(source.botSender?.handle == "hermes")
        #expect(source.attributedText == "Please check the service.")
        #expect(queued.text.hasPrefix("Message from 🤖 Gustavo"))
    }

    @Test(arguments: [nil, "human-input", "bot:", #"["completion","proc"]"#,
                      #"["completion","proc","not-an-epoch"]"#, #"["completion","proc",-1]"#,
                      #"["completion","",1793268000]"#, #"["unknown","proc",1793268000]"#,
                      #"["async_delegation","deleg_a","other-notice"]"#,
                      #"["heartbeat","proc_a",""]"#, #"["completion","proc",1,2]"#] as [String?])
    func missingAndUnknownIdentityNeverClassifiesPastedMachineText(_ input: String?) {
        let pasted = "[IMPORTANT: Background process proc completed normally (exit code 0).]"
        let queued = QueuedMessage(id: "user", text: pasted, submissionID: input)
        #expect(queued.sourceMessage == nil)
        #expect(queued.text == pasted)
    }

    @Test func editableAndSteeredUserInputsCannotBecomeBackgroundEvents() {
        let input = #"["completion","proc_a",1793268000]"#
        let editable = QueuedMessage(id: "user", text: "A human supplied this input ID", canEdit: true, submissionID: input)
        let steering = QueuedMessage(id: "steer", text: "Human steering", submissionID: input, isSteering: true)
        #expect(editable.sourceMessage == nil && editable.canEdit)
        #expect(steering.sourceMessage == nil && steering.isSteering)
        #expect(QueuedMessage(id: "large", text: "Payload", submissionID: String(repeating: "x", count: 1025)).sourceMessage == nil)
    }
}
