import Testing
import SwiftUI
import UIKit
import BottoCore
@testable import Botto

@Suite(.serialized) @MainActor struct NativeComposerEditorTests {
    @Test func nativeEditingWritesExactWhitespaceAndMultilineReturnToCurrentDraft() async throws {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-composer.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let screen = try #require(store.chats.screen(profile: service.profile))
        let owner = screen.owner
        let binding = Binding(get: { store.chats.draft(owner) }, set: { store.chats.editDraft($0, owner: owner) })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); let root = UIViewController(); window.rootViewController = root
        let editor = NativeComposerTextView(); editor.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        root.view.addSubview(editor); window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { editor.cancelEditing(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        editor.configure(text: binding, identity: .init(owner: owner, viewLifetime: screen.selectedViewLifetime, revision: UUID()),
            enabled: true, placeholder: "Message Bot", label: "Message to Bot", dynamicType: .large,
            canEdit: { store.chats.isCurrent(owner) })
        #expect(editor.becomeFirstResponder())
        let expected = "  Main line one\\n  line two  \nSecond paragraph"
        editor.insertText(expected)
        #expect(editor.text == expected)
        #expect(store.chats.draft(owner) == expected)
        #expect(service.opens.count == 1 && service.sends.isEmpty)
    }
    @Test func synchronousWorkspaceObservationCannotRollBackTheNativeEditBeingPublished() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        let revision = UUID()
        fixture.configure(screen, revision: revision)
        #expect(fixture.editor.becomeFirstResponder())
        let expected = "Canvas tail after rich preview\n  keep this source draft  "
        var prefix = ""
        for character in expected {
            // @Observable invalidates before installing the new record, causing
            // configure to reenter inside the Binding setter.
            withObservationTracking { _ = fixture.store.chats.draft(screen.owner) } onChange: {
                MainActor.assumeIsolated { fixture.configure(screen, revision: revision) }
            }
            prefix.append(character)
            fixture.editor.insertText(String(character))
            try #require(fixture.editor.text == prefix, "Native text must retain the in-flight edit")
            try #require(fixture.store.chats.draft(screen.owner) == prefix, "The current owner receives the exact edit")
        }
        #expect(fixture.service.sends.isEmpty)
    }

    @Test(arguments: [false, true])
    func inFlightDraftWriteDoesNotSuppressAReplacementContextOrEditingRetirement(replacement: Bool) async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        let revision = UUID()
        fixture.configure(screen, revision: revision)
        #expect(fixture.editor.becomeFirstResponder())
        withObservationTracking { _ = fixture.store.chats.draft(screen.owner) } onChange: {
            MainActor.assumeIsolated {
                if replacement {
                    fixture.editor.configure(text: .constant("Replacement context"),
                        identity: .init(owner: screen.owner, viewLifetime: UUID(), revision: UUID()),
                        enabled: true, placeholder: "New task", label: "New task", dynamicType: .large,
                        canEdit: { false })
                } else {
                    fixture.liveEligible = false
                    fixture.configure(screen, revision: revision, enabled: false)
                }
            }
        }
        fixture.editor.insertText("C")
        #expect(!fixture.editor.isFirstResponder)
        if replacement { #expect(fixture.editor.text == "Replacement context") }
        else { #expect(!fixture.editor.isEditable && !fixture.editor.isUserInteractionEnabled) }
        #expect(fixture.store.chats.draft(screen.owner) == "C")
    }

    @Test func currentCompositionSurvivesUpdatesButReplacementCannotCommitOrUndoIntoNewDraft() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let first = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        let generation = UUID()
        fixture.configure(first, revision: generation)
        #expect(fixture.editor.becomeFirstResponder())
        fixture.editor.insertText("  before ")
        fixture.editor.setMarkedText("조합", selectedRange: NSRange(location: 2, length: 0))
        let native = fixture.editor.text
        let selection = fixture.editor.selectedRange
        let marked = try #require(fixture.editor.markedTextRange)
        let markedOffset = fixture.editor.offset(from: fixture.editor.beginningOfDocument, to: marked.start)
        fixture.configure(first, revision: generation)
        #expect(fixture.editor.text == native && fixture.editor.selectedRange == selection)
        let stillMarked = try #require(fixture.editor.markedTextRange)
        #expect(fixture.editor.offset(from: fixture.editor.beginningOfDocument, to: stillMarked.start) == markedOffset)
        await fixture.store.open(try #require(fixture.store.bots.first))
        let replacement = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        #expect(replacement.owner != first.owner)
        let expected = "  Replacement task\nkeeps this draft  "
        fixture.store.chats.editDraft(expected, owner: replacement.owner)
        fixture.configure(replacement, revision: UUID())
        #expect(fixture.editor.markedTextRange == nil && !fixture.editor.isFirstResponder)
        #expect(fixture.editor.undoManager?.canUndo != true)
        fixture.editor.unmarkText()
        fixture.editor.undoManager?.undo()
        #expect(fixture.editor.text == expected)
        #expect(fixture.store.chats.draft(replacement.owner) == expected)
        #expect(fixture.service.sends.isEmpty)
    }

    @Test func manualCommitPublishesCompositionAndRejectsARetiredOwner() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        fixture.configure(screen, revision: UUID())
        #expect(fixture.editor.becomeFirstResponder())
        fixture.editor.insertText("  before ")
        fixture.editor.setMarkedText("조합", selectedRange: NSRange(location: 2, length: 0))
        let expected = try #require(fixture.editor.text)
        _ = try #require(fixture.editor.markedTextRange)
        fixture.editor.commitComposition()
        #expect(fixture.editor.markedTextRange == nil)
        #expect(fixture.editor.text == expected && fixture.store.chats.draft(screen.owner) == expected)
        #expect(fixture.editor.isFirstResponder && fixture.service.sends.isEmpty)
        fixture.editor.commitComposition()
        #expect(fixture.store.chats.draft(screen.owner) == expected)

        await fixture.store.open(try #require(fixture.store.bots.first))
        let replacement = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        try #require(replacement.owner != screen.owner)
        fixture.store.chats.editDraft("Replacement draft", owner: replacement.owner)
        fixture.editor.text = "Stale native input"
        fixture.editor.commitComposition()
        #expect(fixture.store.chats.draft(replacement.owner) == "Replacement draft")
        #expect(fixture.service.sends.isEmpty)
    }

    @Test func nativeMeasurementCapsLinesAndReactsToLiveAccessibilityTextWithoutTruncatingDraft() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        let revision = UUID()
        let value = (0..<25).map { "Line \($0) keeps all its words." }.joined(separator: "\n") + "\n"
        fixture.store.chats.editDraft(value, owner: screen.owner)
        fixture.configure(screen, revision: revision)
        fixture.editor.selectedRange = NSRange(location: 8, length: 9)
        let regularFont = try #require(fixture.editor.font)
        let normal = fixture.editor.fittingSize(width: 320)
        let normalLines = (normal.height - fixture.editor.textContainerInset.top - fixture.editor.textContainerInset.bottom) / regularFont.lineHeight
        #expect(normalLines >= 6 && normalLines < 6.1, "Standard text shows six lines before native scrolling")
        fixture.configure(screen, revision: revision, dynamic: .accessibility3)
        let larger = try #require(fixture.editor.font)
        let accessible = fixture.editor.fittingSize(width: 240)
        let accessibleLines = (accessible.height - fixture.editor.textContainerInset.top - fixture.editor.textContainerInset.bottom) / larger.lineHeight
        #expect(larger.pointSize > regularFont.pointSize)
        #expect(accessibleLines >= 3 && accessibleLines < 3.1, "Accessibility text shows three lines before native scrolling")
        #expect(fixture.editor.text == value && fixture.store.chats.draft(screen.owner) == value)
        #expect(fixture.editor.selectedRange == NSRange(location: 8, length: 9))
        #expect(fixture.editor.isScrollEnabled)
        #expect(fixture.editor.accessibilityIdentifier == "chat-composer" && fixture.editor.accessibilityLabel == "Message to Bot")
    }

    @Test func temporaryCoveragePreservesTheNativeSelection() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        let revision = UUID()
        fixture.configure(screen, revision: revision)
        #expect(fixture.editor.becomeFirstResponder())
        fixture.editor.insertText("Before middle after")
        fixture.editor.selectedRange = NSRange(location: 7, length: 6)
        fixture.liveEligible = false
        fixture.configure(screen, revision: revision, enabled: false)
        fixture.liveEligible = true
        fixture.configure(screen, revision: revision)
        #expect(fixture.editor.selectedRange == NSRange(location: 7, length: 6))
        #expect(fixture.store.chats.draft(screen.owner) == "Before middle after")
        #expect(!fixture.editor.isFirstResponder, "Returning from coverage does not reopen the keyboard.")
    }

    @Test func overviewImportInvalidationDoesNotReplaceTheHostedComposerSelection() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        let coverage = try fixture.hostComposer(screen)
        try await waitForLayout(fixture) { coverage.editing.editor?.isEditable == true }
        let editor = try #require(coverage.editing.editor)
        try #require(editor.becomeFirstResponder())
        editor.insertText("Before middle after")
        editor.selectedRange = NSRange(location: 7, length: 6)
        coverage.editing.cancel()
        coverage.importRevision = UUID()
        coverage.covered = true
        try await waitForLayout(fixture) { !editor.isEditable }
        coverage.covered = false
        try await waitForLayout(fixture) { editor.isEditable }
        #expect(coverage.editing.editor === editor)
        #expect(editor.selectedRange == NSRange(location: 7, length: 6))
        #expect(fixture.store.chats.draft(screen.owner) == "Before middle after")
        #expect(!editor.isFirstResponder)
    }

    @Test func manualBlurAndInitiallyUnfocusedReattachmentDoNotStartEditing() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        fixture.configure(screen, revision: UUID())
        fixture.editor.removeFromSuperview(); fixture.root.view.addSubview(fixture.editor)
        await Task { @MainActor in }.value
        #expect(!fixture.editor.isFirstResponder)
        #expect(fixture.editor.becomeFirstResponder())
        // Reattachment is not a request to resume deliberate manual blur.
        fixture.editor.resignFirstResponder()
        fixture.editor.removeFromSuperview(); fixture.root.view.addSubview(fixture.editor)
        await Task { @MainActor in }.value
        #expect(!fixture.editor.isFirstResponder)
    }

    @Test func confirmedCoverPreventsEditingAndCannotWriteThroughTheCapturedDraftBinding() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        let revision = UUID()
        fixture.store.chats.editDraft("  Covered draft stays exact\n", owner: screen.owner)
        fixture.configure(screen, revision: revision)
        #expect(fixture.editor.becomeFirstResponder())
        fixture.liveEligible = false
        fixture.configure(screen, revision: revision, enabled: false)
        #expect(!fixture.editor.isEditable && !fixture.editor.isUserInteractionEnabled && !fixture.editor.isFirstResponder)
        fixture.editor.insertText("stale input")
        #expect(fixture.store.chats.draft(screen.owner) == "  Covered draft stays exact\n")
        #expect(fixture.service.sends.isEmpty)
    }

    @Test func hostedNativeEditsGrowShrinkAndScrollAtTheLineCap() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        let geometry = fixture.host(screen, width: 180)
        try await waitForLayout(fixture) { (geometry.editing.editor?.bounds.height ?? 0) > 0 }
        let editor = try #require(geometry.editing.editor)
        try #require(editor.becomeFirstResponder())
        let singleLineHeight = editor.bounds.height
        let wrapped = "  Words that wrap across the narrow native composer while preserving every space.  "
        editor.insertText(wrapped)
        try await waitForLayout(fixture) { editor.bounds.height > singleLineHeight + 5 }
        #expect(editor.text == wrapped && fixture.store.chats.draft(screen.owner) == wrapped)
        #expect(editor.selectedRange == NSRange(location: wrapped.utf16.count, length: 0))

        editor.selectedRange = NSRange(location: 0, length: wrapped.utf16.count)
        editor.insertText("Short")
        try await waitForLayout(fixture) { abs(editor.bounds.height - singleLineHeight) < 1 }
        editor.insertText("\nNext")
        try await waitForLayout(fixture) { editor.bounds.height > singleLineHeight + 5 }
        editor.selectedRange = NSRange(location: 5, length: 5)
        editor.deleteBackward()
        try await waitForLayout(fixture) { abs(editor.bounds.height - singleLineHeight) < 1 }
        #expect(editor.text == "Short" && fixture.store.chats.draft(screen.owner) == "Short")

        let tail = (0..<12).map { "\nLine \($0)" }.joined()
        editor.insertText(tail)
        let expected = "Short" + tail
        let font = try #require(editor.font)
        let cap = ceil(editor.textContainerInset.top + editor.textContainerInset.bottom + font.lineHeight * 6)
        try await waitForLayout(fixture) { abs(editor.bounds.height - cap) < 1 && editor.contentSize.height > editor.bounds.height }
        try await waitForLayout(fixture) {
            guard let selection = editor.selectedTextRange else { return false }
            let caret = editor.caretRect(for: selection.end)
            return caret.minY >= editor.bounds.minY - 1 && caret.maxY <= editor.bounds.maxY + 1
        }
        #expect(editor.text == expected && fixture.store.chats.draft(screen.owner) == expected)
        #expect(editor.selectedRange == NSRange(location: expected.utf16.count, length: 0))
        #expect(editor.isScrollEnabled)
        editor.selectedRange = NSRange(location: 0, length: expected.utf16.count)
        editor.insertText("Again")
        try await waitForLayout(fixture) { abs(editor.bounds.height - singleLineHeight) < 1 }
        #expect(editor.text == "Again" && fixture.store.chats.draft(screen.owner) == "Again")
        #expect(editor.selectedRange == NSRange(location: 5, length: 0))
        #expect(fixture.service.sends.isEmpty)
    }

    @Test func hostedGeometryTracksWidthTypeDirectionAndProgrammaticClear() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        let value = "Words wrap when the allocated native editor becomes narrower."
        fixture.store.chats.editDraft(value, owner: screen.owner)
        let geometry = fixture.host(screen, width: 320)
        try await waitForLayout(fixture) { abs((geometry.editing.editor?.bounds.width ?? 0) - 320) < 1 }
        let editor = try #require(geometry.editing.editor)
        editor.selectedRange = NSRange(location: 6, length: 4)
        let wideHeight = editor.bounds.height
        geometry.width = 150
        try await waitForLayout(fixture) { abs(editor.bounds.width - 150) < 1 && editor.bounds.height > wideHeight + 5 }
        geometry.width = 320
        try await waitForLayout(fixture) { abs(editor.bounds.width - 320) < 1 && abs(editor.bounds.height - wideHeight) < 1 }
        let normalPointSize = try #require(editor.font).pointSize
        geometry.dynamicType = .accessibility3
        geometry.direction = .rightToLeft
        try await waitForLayout(fixture) {
            (editor.font?.pointSize ?? 0) > normalPointSize && editor.bounds.height > wideHeight + 5 &&
                editor.semanticContentAttribute == .forceRightToLeft && editor.textContainerInset.right == 16
        }
        #expect(editor.text == value && fixture.store.chats.draft(screen.owner) == value)
        #expect(editor.selectedRange == NSRange(location: 6, length: 4))
        let largeHeight = editor.bounds.height
        fixture.store.chats.editDraft("", owner: screen.owner)
        try await waitForLayout(fixture) { editor.text.isEmpty && editor.bounds.height < largeHeight - 5 }
        #expect(editor.selectedRange == NSRange(location: 0, length: 0))
        #expect(editor.subviews.compactMap { $0 as? UILabel }.contains { $0.text == "Message Bot" && !$0.isHidden })
        geometry.dynamicType = .large
        geometry.direction = .leftToRight
        try await waitForLayout(fixture) {
            editor.font?.pointSize == normalPointSize && editor.textContainerInset.left == 16 &&
                editor.textContainerInset.right == 0 && editor.bounds.height < largeHeight - 5
        }
        #expect(fixture.service.sends.isEmpty)
    }

    @Test func hostedMarkedTextCanWrapAndCommitWithoutLosingNativeSelection() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let screen = try #require(fixture.store.chats.screen(profile: fixture.service.profile))
        let geometry = fixture.host(screen, width: 160)
        try await waitForLayout(fixture) { (geometry.editing.editor?.bounds.height ?? 0) > 0 }
        let editor = try #require(geometry.editing.editor)
        try #require(editor.becomeFirstResponder())
        editor.insertText("Before ")
        let shortHeight = editor.bounds.height
        let marked = "조합 중인 긴 문장은 좁은 입력 영역에서 여러 줄로 이어집니다"
        editor.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0))
        let expected = try #require(editor.text)
        let selection = editor.selectedRange
        try #require(editor.markedTextRange != nil)
        try await waitForLayout(fixture) { editor.bounds.height > shortHeight + 5 }
        #expect(editor.text == expected && editor.selectedRange == selection)
        #expect(editor.markedTextRange != nil)
        editor.commitComposition()
        try await waitForLayout(fixture) { fixture.store.chats.draft(screen.owner) == expected }
        #expect(editor.text == expected && editor.selectedRange == selection)
        #expect(editor.markedTextRange == nil && editor.isFirstResponder)
        #expect(fixture.service.sends.isEmpty)
    }

    private func waitForLayout(_ fixture: Fixture, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            fixture.window.layoutIfNeeded()
            if condition() { return }
            await Task.yield()
        } while ContinuousClock.now < deadline
        try #require(condition(), "Hosted editor must settle without forcing a layout invalidation")
    }

    private func fixture() async throws -> Fixture {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-composer-lifecycle.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let fixture = Fixture(store: store, service: service, configuration: configuration, scene: scene)
        fixture.window.makeKeyAndVisible(); fixture.window.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while !fixture.root.appeared && ContinuousClock.now < deadline { await Task.yield() }
        try #require(fixture.root.appeared)
        return fixture
    }

    @MainActor private final class Fixture {
        let store: AppStore
        let service: WorkspaceTestService
        let configuration: ConnectionConfiguration
        let window: UIWindow
        let root = NativeEditorTestController()
        let editor = NativeComposerTextView()
        weak var previous: UIWindow?
        var liveEligible = true
        private var hosted: UIViewController?
        private var hostedGeometry: EditorGeometry?
        private var composerCoverage: ComposerCoverage?
        init(store: AppStore, service: WorkspaceTestService, configuration: ConnectionConfiguration, scene: UIWindowScene) {
            self.store = store; self.service = service; self.configuration = configuration
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); window.rootViewController = root
            editor.frame = CGRect(x: 0, y: 0, width: 320, height: 150)
            root.view.addSubview(editor)
        }
        func configure(_ screen: ChatScreen, revision: UUID, dynamic: DynamicTypeSize = .large, enabled: Bool = true) {
            let owner = screen.owner
            let binding = Binding(get: { self.store.chats.draft(owner) }, set: { self.store.chats.editDraft($0, owner: owner) })
            editor.configure(text: binding, identity: .init(owner: owner, viewLifetime: screen.selectedViewLifetime, revision: revision),
                enabled: enabled, placeholder: "Message Bot", label: "Message to Bot", dynamicType: dynamic,
                canEdit: { self.liveEligible && self.store.chats.isCurrent(owner) && self.store.chats.screen(profile: self.service.profile)?.canEditDraft == true })
        }
        func close() {
            hostedGeometry?.editing.cancel()
            composerCoverage?.editing.cancel()
            hosted?.willMove(toParent: nil); hosted?.view.removeFromSuperview(); hosted?.removeFromParent()
            hosted = nil; hostedGeometry = nil
            editor.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.forgetConnection(); LocalHistory.remove(for: configuration.id)
        }
        func host(_ screen: ChatScreen, width: CGFloat) -> EditorGeometry {
            editor.removeFromSuperview()
            let geometry = EditorGeometry(workspace: store.chats, screen: screen, width: width)
            let host = UIHostingController(rootView: HostedEditor(geometry: geometry))
            root.addChild(host)
            host.view.frame = root.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.view.addSubview(host.view); host.didMove(toParent: root)
            hosted = host; hostedGeometry = geometry
            return geometry
        }
        func hostComposer(_ screen: ChatScreen) throws -> ComposerCoverage {
            editor.removeFromSuperview()
            let coverage = ComposerCoverage()
            let bot = try #require(store.bots.first)
            let host = UIHostingController(rootView: HostedComposer(store: store, bot: bot, screen: screen, coverage: coverage))
            root.addChild(host)
            host.view.frame = root.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.view.addSubview(host.view); host.didMove(toParent: root)
            hosted = host; composerCoverage = coverage
            return coverage
        }
    }

}

@MainActor @Observable private final class ComposerCoverage {
    let editing = ComposerEditingHandle()
    let editingRevision = UUID()
    var importRevision = UUID()
    var covered = false
}

@MainActor private struct HostedComposer: View {
    let store: AppStore
    let bot: BotProfile
    let screen: ChatScreen
    let coverage: ComposerCoverage
    @State private var connectionRequested = false
    var body: some View {
        ChatComposer(store: store, bot: bot, workspace: store.chats, screen: screen,
            inputAvailable: !coverage.covered, importsAllowed: !coverage.covered,
            importPresentationRevision: coverage.importRevision, editingRevision: coverage.editingRevision,
            onPickerPresentation: { _ in }, canContinueEditing: { !coverage.covered },
            editingHandle: coverage.editing, connectionRequested: $connectionRequested)
    }
}

@MainActor @Observable private final class EditorGeometry {
    let workspace: ConversationWorkspace
    let identity: NativeComposerEditor.Identity
    let editing = ComposerEditingHandle()
    var width: CGFloat
    var dynamicType: DynamicTypeSize = .large
    var direction: LayoutDirection = .leftToRight
    init(workspace: ConversationWorkspace, screen: ChatScreen, width: CGFloat) {
        self.workspace = workspace; self.width = width
        identity = .init(owner: screen.owner, viewLifetime: screen.selectedViewLifetime, revision: UUID())
    }
}

@MainActor private struct HostedEditor: View {
    let geometry: EditorGeometry
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeComposerEditor(text: Binding(
                get: { geometry.workspace.draft(geometry.identity.owner) },
                set: { geometry.workspace.editDraft($0, owner: geometry.identity.owner) }),
                identity: geometry.identity, enabled: true, placeholder: "Message Bot",
                accessibilityLabel: "Message to Bot", editing: geometry.editing,
                canEdit: { geometry.workspace.canEditDraft(geometry.identity.owner) })
                .frame(width: geometry.width)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.dynamicTypeSize, geometry.dynamicType)
        .environment(\.layoutDirection, geometry.direction)
    }
}

@MainActor private final class NativeEditorTestController: UIViewController {
    private(set) var appeared = false
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared = true }
}
