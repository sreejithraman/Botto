import Testing
import SwiftUI
import UIKit
import BottoCore
@testable import Botto

@Suite(.serialized) @MainActor struct SearchMatchTextTests {
    @Test func searchUsesTheSameVisibleTextThatExactNavigationCanReveal() throws {
        let messages = [
            ChatMessage(id: "stored:fixture:phrase", role: .assistant, text: "A **Café** update"),
            ChatMessage(id: "stored:fixture:word", role: .assistant, text: "A nee**dle** in prose"),
            ChatMessage(id: "stored:fixture:link", role: .assistant, text: "Read the [Café](https://example.test/hidden-destination) update")
        ]
        let chat = try searchableChat(messages)
        let snapshot = Conversation(id: chat.identity.root.text, storedID: chat.identity.stored.text,
            profileID: chat.botID, messages: messages)
        for (query, expectedIDs) in [("cafe update", [messages[0].id, messages[2].id]), ("needle", [messages[1].id])] {
            let results = LibrarySearchResults(query: query, bots: [], chats: [chat], artifacts: [])
            #expect(Set(results.messages.map { $0.message.id }) == Set(expectedIDs))
            for result in results.messages {
                #expect(SearchMessageTarget(chat: result.chat, message: result.message, query: query)
                    .resolve(identity: chat.identity, snapshot: snapshot) != nil)
            }
        }
        #expect(LibrarySearchResults(query: "hidden-destination", bots: [], chats: [chat], artifacts: []).messages.isEmpty)
    }

    @Test func literalUserAndBotSenderTextKeepsItsVisibleMarkdownCharacters() throws {
        let literal = "Keep **Café** literal and [notes](https://literal.example/visible-url)"
        let user = ChatMessage(id: "stored:fixture:user", role: .user, text: literal)
        let sender = ChatMessage(id: "stored:fixture:sender", role: .user,
            text: "Message from 🤖 Gustavo (@hermes): " + literal,
            displayKind: "internal_notification")
        #expect(sender.botSender != nil)
        let chat = try searchableChat([user, sender])
        for query in ["**cafe**", "visible-url"] {
            let results = LibrarySearchResults(query: query, bots: [], chats: [chat], artifacts: [])
            #expect(Set(results.messages.map { $0.message.id }) == Set([user.id, sender.id]))
            if query == "**cafe**" { #expect(results.messages.allSatisfy { $0.snippet.contains("**Café**") }) }
            else { #expect(results.messages.allSatisfy { $0.snippet.contains("https://literal.example/visible-url") }) }
            #expect(NativeSearchMatch.contains(query: query, in: user))
            #expect(NativeSearchMatch.contains(query: query, in: sender))
        }
        #expect(LibrarySearchResults(query: "hermes", bots: [], chats: [chat], artifacts: []).messages.isEmpty,
            "The sender stamp is provenance, not the displayed message body")
    }

    @Test(arguments: [1, 50])
    func sourceOnlyPreviewHitsCannotHideReachableMessagesOrCreateOverflow(visibleCount: Int) throws {
        let visible = (0..<visibleCount).map {
            ChatMessage(id: "stored:fixture:visible-\($0)", role: .assistant, text: "The Needle is visible in reply \($0).")
        }
        let sourceOnly = (0..<60).map { index in
            let source: String
            switch index % 4 {
            case 0: source = "```html\n<p>Needle source \(index)</p>\n```"
            case 1: source = "```svg\n<svg><text>Needle source \(index)</text></svg>\n```"
            case 2: source = "```mermaid\ngraph TD\nNeedle-->Hidden\n```"
            default: source = "::preview{file=\"/Needle-\(index).html\"}"
            }
            return ChatMessage(id: "stored:fixture:source-\(index)", role: .assistant, text: "Here is the example.\n\n" + source)
        }
        let chat = try searchableChat(visible + sourceOnly)
        let results = LibrarySearchResults(query: "needle", bots: [], chats: [chat], artifacts: [])
        #expect(results.messages.count == visibleCount)
        #expect(!results.hasMoreMessages)
        #expect(results.messages.allSatisfy { $0.message.id.hasPrefix("stored:fixture:visible-") })
        #expect(sourceOnly.allSatisfy { !NativeSearchMatch.contains(query: "needle", in: $0) })
    }

    @Test func searchDoesNotJoinTextAcrossAnIsolatedPreview() throws {
        let message = ChatMessage(id: "stored:fixture:separate", role: .assistant,
            text: "Copper\n\n```html\n<p>Independent preview</p>\n```\n\nlantern")
        let chat = try searchableChat([message])
        #expect(LibrarySearchResults(query: "copper lantern", bots: [], chats: [chat], artifacts: []).messages.isEmpty)
        #expect(!NativeSearchMatch.contains(query: "copper lantern", in: message))
        #expect(LibrarySearchResults(query: "lantern", bots: [], chats: [chat], artifacts: []).messages.count == 1)
    }

    @Test func directlyRenderedSystemNotesAreSearchableWithoutInboxPreviewEligibility() throws {
        let message = ChatMessage(id: "error:delivery", role: .system, text: "Delivery checkpoint needs attention")
        let chat = try searchableChat([message])
        let results = LibrarySearchResults(query: "delivery checkpoint", bots: [], chats: [chat], artifacts: [])
        #expect(results.messages.map { $0.message.id } == [message.id])
        let snapshot = Conversation(id: chat.identity.root.text, storedID: chat.identity.stored.text,
            profileID: chat.botID, messages: [message])
        #expect(SearchMessageTarget(chat: chat, message: message, query: "delivery checkpoint")
            .resolve(identity: chat.identity, snapshot: snapshot) != nil)
    }

    @Test func ambiguousMessageOccurrencesDoNotShareASearchResultIdentity() throws {
        let messages = [ChatMessage(id: "stored:fixture:duplicate", role: .assistant, text: "Needle first occurrence"),
                        ChatMessage(id: "stored:fixture:duplicate", role: .assistant, text: "Needle conflicting occurrence")]
        let chat = try searchableChat(messages)
        #expect(LibrarySearchResults(query: "needle", bots: [], chats: [chat], artifacts: []).messages.isEmpty)
    }

    @Test func visibleTextProjectionCanBeDerivedOffMainActor() async {
        let message = ChatMessage(id: "stored:fixture:detached", role: .assistant, text: "A **Café** update")
        let text = await Task.detached(priority: .utility) { NativeMessageText.segments(for: message) }.value
        #expect(text == ["A Café update"])
    }

    private func searchableChat(_ messages: [ChatMessage]) throws -> LibraryChat {
        let identity = SessionIdentity(profile: try ExactID("bot"), root: try ExactID("root"), stored: try ExactID("stored"), aliases: [])
        return LibraryChat(workspace: UUID(), identity: identity, botName: "Bot", title: "Main", messages: messages,
            updatedAt: nil, discoveredArtifacts: [], sourceRevisions: [:], searchableText: LibraryChat.searchIndex(messages))
    }

    @Test func occurrenceChecksOnlyTheTextTheNativeMessageRenders() {
        let assistant = ChatMessage(id: "reply", role: .assistant,
            text: "A **Café** report with [notes](https://example.test/hidden-token).\n\n```swift\nlet codeNeedle = 1\n```\n\n```html\n<p>isolated-token</p>\n```")
        #expect(NativeSearchMatch.contains(query: "cafe", in: assistant))
        #expect(NativeSearchMatch.contains(query: "codeNeedle", in: assistant))
        #expect(!NativeSearchMatch.contains(query: "hidden-token", in: assistant))
        #expect(!NativeSearchMatch.contains(query: "isolated-token", in: assistant))
        #expect(!NativeSearchMatch.contains(query: "swift", in: assistant))
        #expect(!NativeSearchMatch.contains(query: "", in: assistant))
        #expect(!NativeSearchMatch.contains(query: "details", in: ChatMessage(id: "tool", role: .tool, text: "details")))
        #expect(NativeSearchMatch.contains(query: "details", in: ChatMessage(id: "error:1", role: .system, text: "details")))
        let projected = ChatMessage(id: "stored:fixture:1", role: .assistant, text: "Older visible reply")
        let attached = ChatMessage(id: "stored:fixture:1", role: .assistant, text: "Provider scaffolding")
        #expect(NativeSearchMatch.contains(query: "visible", in: projected))
        #expect(!NativeSearchMatch.contains(query: "visible", in: attached))
    }

    @Test func markerTracksTheActualLateLineInsideOneTallNativeText() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
            $0.activationState == .foregroundActive
        })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let viewport = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        root.view.addSubview(viewport)
        let scope = NativeTranscriptRowExposure(viewport: viewport)
        let match = NativeSearchMatch(id: UUID(), query: "unique glyph target")
        let prose = (0..<70).map { "Ordinary line \($0)" }.joined(separator: "\n") + "\nunique glyph target\nFinal line"
        let host = UIHostingController(rootView: NativeTranscriptBlock(block: 42) {
            SearchMatchText(prose).font(.system(size: 20)).fixedSize(horizontal: false, vertical: true)
        }.environment(\.nativeTranscriptRow, scope).environment(\.nativeSearchMatch, match)
            .frame(width: 300, alignment: .topLeading))
        root.addChild(host); viewport.addSubview(host.view); host.didMove(toParent: root)
        let size = host.sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        host.view.frame = CGRect(origin: .zero, size: size); viewport.contentSize = size
        root.view.layoutIfNeeded(); host.view.layoutIfNeeded()
        try await wait("late-line native glyph marker") { scope.firstSearchMarker(id: match.id) != nil }
        let result = try #require(scope.firstSearchMarker(id: match.id))
        let marker = result.marker
        let bounds = marker.convert(marker.bounds, to: viewport)
        #expect(result.block == 42)
        #expect(bounds.minY > 1200, "a row-top marker cannot represent the 71st line")
        #expect(bounds.height > 10 && bounds.height < 45)
        #expect(bounds.width > 50 && bounds.width < 300)
        viewport.scrollRectToVisible(bounds, animated: false)
        viewport.layoutIfNeeded()
        let visible = marker.convert(marker.bounds, to: window).intersection(viewport.convert(viewport.bounds, to: window))
        #expect(!visible.isNull && visible.height > 10)
        #expect(viewport.contentOffset.y > 1000)
        print("BOTTO_SEARCH_GLYPH marker=\(bounds) offset=\(viewport.contentOffset)")
        scope.invalidate()
        #expect(scope.firstSearchMarker(id: match.id) == nil)
    }

    @Test func codeMatchCanBeRevealedAcrossBothNativeScrollAxes() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
            $0.activationState == .foregroundActive
        })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let viewport = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        root.view.addSubview(viewport)
        let scope = NativeTranscriptRowExposure(viewport: viewport)
        let match = NativeSearchMatch(id: UUID(), query: "code-target")
        let code = (0..<70).map { "let line\($0) = 0" }.joined(separator: "\n") +
            "\n" + String(repeating: " ", count: 180) + "code-target\nlet tail = 1"
        let message = ChatMessage(id: "code", role: .assistant, text: "```swift\n" + code + "\n```")
        let host = UIHostingController(rootView: AssistantReplyBody(message: message, isStreaming: false)
            .environment(\.nativeTranscriptRow, scope).environment(\.nativeSearchMatch, match)
            .frame(width: 300, alignment: .topLeading))
        root.addChild(host); viewport.addSubview(host.view); host.didMove(toParent: root)
        let size = host.sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        host.view.frame = CGRect(origin: .zero, size: size); viewport.contentSize = size
        root.view.layoutIfNeeded(); host.view.layoutIfNeeded()
        try await wait("two-axis code glyph marker") { scope.firstSearchMarker(id: match.id) != nil }
        let marker = try #require(scope.firstSearchMarker(id: match.id)?.marker)
        let original = marker.convert(marker.bounds, to: viewport)
        #expect(original.minX > 1000 && original.minY > 1000)
        var ancestor = marker.superview
        var horizontal: UIScrollView?
        while let view = ancestor, view !== viewport {
            if let scroll = view as? UIScrollView {
                scroll.scrollRectToVisible(marker.convert(marker.bounds, to: scroll), animated: false)
                scroll.layoutIfNeeded(); horizontal = scroll
            }
            ancestor = view.superview
        }
        let inner = try #require(horizontal)
        #expect(inner.contentOffset.x > 1000)
        viewport.scrollRectToVisible(marker.convert(marker.bounds, to: viewport), animated: false)
        viewport.layoutIfNeeded()
        let glyph = marker.convert(marker.bounds, to: window)
        let clipped = glyph.intersection(inner.convert(inner.bounds, to: window))
            .intersection(viewport.convert(viewport.bounds, to: window))
        #expect(!clipped.isNull && clipped.width > 5 && clipped.height > 5)
        print("BOTTO_SEARCH_CODE original=\(original) innerOffset=\(inner.contentOffset) outerOffset=\(viewport.contentOffset)")
    }

    private func wait(_ description: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Timed out: \(description)")
    }
}
