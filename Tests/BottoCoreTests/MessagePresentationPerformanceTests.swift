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

    @Test func longInternalHistoryKeepsItsAttention() {
        let count = 30
        let body = String(repeating: "A completed check with ordinary diagnostic details. ", count: 50)
        let wrapper = "[Cronjob \"Daily check\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n"
        let messages = (0..<count).map { index in
            switch index % 3 {
            case 0: ChatMessage(id: "routine-\(index)", role: .user, text: wrapper + body, displayKind: "internal_notification")
            case 1: ChatMessage(id: "bot-\(index)", role: .user, text: "Message from 🤖 Gustavo (@hermes): " + body, displayKind: "internal_notification")
            default: ChatMessage(id: "completion-\(index)", role: .user, text: body, displayKind: "process_complete")
            }
        }
        let attention = Conversation(id: "chat", storedID: "stored", profileID: "profile", messages: messages).attentionMessages
        #expect(attention.count == count * 2 / 3)
        #expect(attention.first?.id == "bot-1" && attention.last?.id == "completion-\(count - 1)")
    }
}
