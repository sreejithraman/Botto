import SwiftUI
import Testing
import BottoCore
@testable import Botto

struct NativeMessageTextTests {
    @Test func visibleTextProjectionCanBeDerivedOffMainActor() async {
        let message = ChatMessage(id: "stored:fixture:detached", role: .assistant, text: "A **Café** update")
        let text = await Task.detached(priority: .utility) { NativeMessageText.segments(for: message) }.value
        #expect(text == ["A Café update"])
    }

    @Test func fencedCodeBecomesItsOwnBlockAndKeepsItsBlankLines() {
        let blocks = NativeMessageText.markdownBlocks(in: "Intro\n\n```swift\n\nlet a = 1\n\nlet b = 2\n\n```\n\nOutro\n")
        #expect(blocks.map(\.code) == [false, true, false])
        #expect(blocks.map(\.text) == ["Intro", "\nlet a = 1\n\nlet b = 2\n", "Outro"],
                "Prose loses its surrounding blank lines; code keeps every line it was given")
        #expect(blocks.map(\.id) == [0, 1, 2])
    }

    @Test func anUnclosedFenceStillShowsItsCodeAndEmptyBlocksAreDropped() {
        let open = NativeMessageText.markdownBlocks(in: "Before\n```\nlet open = true")
        #expect(open.map(\.code) == [false, true])
        #expect(open.map(\.text) == ["Before", "let open = true"])
        #expect(NativeMessageText.markdownBlocks(in: "```\n```\n\n\n").isEmpty)
    }

    @Test func inlineMarkdownRendersWithoutItsMarkersAndKeepsLineBreaks() throws {
        let text = NativeMessageText.markdownAttributed("A **Café** with [notes](https://example.test/hidden)\nnext line", isReply: true)
        #expect(String(text.characters) == "A Café with notes\nnext line")
        let link = try #require(text.runs.first { $0.link != nil })
        #expect(link.link == URL(string: "https://example.test/hidden"))
        #expect(String(text[link.range].characters) == "notes")
    }

    @Test(arguments: [true, false])
    func headingsDropTheirMarkersAndTakeTheRoleFont(isReply: Bool) throws {
        let text = NativeMessageText.markdownAttributed("## Plan\n\nBody", isReply: isReply)
        #expect(String(text.characters) == "Plan\n\nBody")
        let heading = try #require(text.runs.first)
        #expect(String(text[heading.range].characters) == "Plan")
        #expect(heading.font == (isReply ? Font.title3.weight(.semibold) : .headline))
        #expect(text.runs.last?.font == nil, "Body text after the heading keeps the default font")
    }
}
