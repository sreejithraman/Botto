import Testing
import BottoCore
@testable import Botto

struct NativeMessageTextTests {
    @Test func visibleTextProjectionCanBeDerivedOffMainActor() async {
        let message = ChatMessage(id: "stored:fixture:detached", role: .assistant, text: "A **Café** update")
        let text = await Task.detached(priority: .utility) { NativeMessageText.segments(for: message) }.value
        #expect(text == ["A Café update"])
    }
}
