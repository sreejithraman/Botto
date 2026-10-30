#if DEBUG
import Foundation
import BottoCore

/// The original ten-message benchmark corpus, shared without a second row tree.
enum TranscriptMeasurementFixture {
    static func messages(count: Int, rich: ChatMessage, activeRichTail: Bool = false) -> [ChatMessage] {
        var messages = (0..<count).map { index in
            let id = String(format: "bench-%05d", index)
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            switch index % 10 {
            case 8:
                return ChatMessage(id: id, role: rich.role, text: rich.text, timestamp: date, toolName: rich.toolName, attachments: rich.attachments)
            case 0, 3, 6:
                return ChatMessage(id: id, role: .user, text: "A local task with exact source whitespace.\n  Keep this line.  ", timestamp: date)
            case 4:
                return ChatMessage(id: id, role: .tool, text: "Local fixture result\nSecond result line", timestamp: date, toolName: "Fixture")
            default:
                return ChatMessage(id: id, role: .assistant, text: "A native answer for this local measurement.\n\nThe final paragraph remains readable above the composer.", timestamp: date)
            }
        }
        if activeRichTail, let last = messages.last {
            messages[count - 1] = ChatMessage(id: last.id, role: rich.role, text: rich.text,
                timestamp: last.timestamp, toolName: rich.toolName, attachments: rich.attachments)
        }
        return messages
    }
}
#endif
