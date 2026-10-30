import Foundation
import Testing
@testable import BottoCore

@Suite(.serialized) struct MessagePresentationPerformanceTests {
    @Test func notificationHeadersRemainIndependentAcrossConcurrentReaders() async {
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<60 {
                group.addTask {
                    let routine = ChatMessage(id: "routine", role: .user,
                        text: "[Cronjob \"Check \(index)\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\nResult",
                        displayKind: "internal_notification")
                    let bot = ChatMessage(id: "bot", role: .user,
                        text: "Message from 🤖 Bot \(index) (@helper_\(index)): Please inspect.",
                        displayKind: "internal_notification")
                    let human = ChatMessage(id: "human", role: .user, text: routine.text)
                    return routine.scheduledJobName == "Check \(index)" && !routine.requiresAttention &&
                        bot.botSender?.name == "Bot \(index)" && bot.botSender?.handle == "helper_\(index)" &&
                        bot.attributedText == "Please inspect." && bot.requiresAttention &&
                        human.scheduledJobName == nil && human.botSender == nil && human.requiresAttention
                }
            }
            for await correct in group { #expect(correct) }
        }
    }

    @Test func longInternalHistoryKeepsItsAttentionWithinAnInteractionBudget() {
        let benchmark = ProcessInfo.processInfo.environment["BOTTO_MESSAGE_PRESENTATION_BENCHMARK"] == "1"
        let count = benchmark ? 600 : 30
        let body = String(repeating: "A completed check with ordinary diagnostic details. ", count: 50)
        let wrapper = "[Cronjob \"Daily check\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n"
        let messages = (0..<count).map { index in
            switch index % 3 {
            case 0: ChatMessage(id: "routine-\(index)", role: .user, text: wrapper + body, displayKind: "internal_notification")
            case 1: ChatMessage(id: "bot-\(index)", role: .user, text: "Message from 🤖 Gustavo (@hermes): " + body, displayKind: "internal_notification")
            default: ChatMessage(id: "completion-\(index)", role: .user, text: body, displayKind: "process_complete")
            }
        }
        let history = Conversation(id: "chat", storedID: "stored", profileID: "profile", messages: messages)
        var elapsed: [Duration] = []
        for iteration in 0..<(benchmark ? 6 : 1) {
            let start = ContinuousClock.now
            let attention = history.attentionMessages
            let duration = start.duration(to: .now)
            #expect(attention.count == count * 2 / 3)
            #expect(attention.first?.id == "bot-1" && attention.last?.id == "completion-\(count - 1)")
            if benchmark {
                let parts = duration.components
                let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
                print("BOTTO_MESSAGE_PRESENTATION iteration=\(iteration) warmup=\(iteration == 0) messages=\(count) attention=\(attention.count) ms=\(milliseconds)")
                if iteration > 0 { elapsed.append(duration) }
            }
        }
        if benchmark {
            #expect(elapsed.sorted()[elapsed.count / 2] < .milliseconds(100),
                    "Repeated attention checks on unchanged history must leave time for interaction.")
        }
    }
}
