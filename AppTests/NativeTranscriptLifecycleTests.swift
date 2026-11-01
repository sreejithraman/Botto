import Testing
import SwiftUI
import UIKit
import WebKit
import Observation
import Synchronization
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct NativeTranscriptLifecycleTests {
    @Test func currentIdentityNotifiesForegroundConsumersOnRetirementButNotCoverage() {
        let scope = NativeTranscriptRowExposure(viewport: UIScrollView())
        let changes = Mutex(0)
        _ = withObservationTracking { scope.isCurrent } onChange: { changes.withLock { $0 += 1 } }
        scope.setActive(false)
        #expect(scope.isCurrent && changes.withLock { $0 } == 0,
            "covering the row for its own Source/expanded sheet must not retire that foreground owner")
        scope.invalidate()
        #expect(!scope.isCurrent && changes.withLock { $0 } == 1)
        scope.setActive(true); scope.setDisplayed(true)
        #expect(!scope.isCurrent)
    }

    @Test(arguments: [RichReplyPresentationMode.source, .expanded])
    func foregroundPresentationSurvivesEnvironmentReconfigurationAndCellReuse(mode: RichReplyPresentationMode) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = NativeTranscriptController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { controller.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let message = ChatMessage(id: "foreground", role: .assistant, text: """
            ```html
            <p>Retained source across cell replacement.</p>
            <button id='counter' onclick='this.textContent=Number(this.textContent)+1'>0</button>
            <script>
            const nonce = String(Math.random());
            document.getElementById('counter').click();
            setInterval(() => parent.postMessage({testReport:{nonce:nonce,counter:document.getElementById('counter').textContent}}, '*'), 100);
            </script>
            ```
            """)
        let block = try #require(ReplyContent(message: message).blocks.first { $0.previewFormat == .html })
        var context = NativeTranscriptContext(workspace: ObjectIdentifier(controller), profile: Data("foreground".utf8),
            chat: ChatID(), owner: nil, generation: UUID(), reviewingConnection: false)
        let row = NativeTranscriptRow(id: .message(Data(message.id.utf8)), value: .message(message, working: false)) { _, _ in
            AnyView(RichReplyBlockView(block: block).environment(\.richReplyContext, .isolated))
        }
        let rows = [row] + (0..<20).map { index in
            NativeTranscriptRow(id: .message(Data("spacer-\(index)".utf8)), value: .auxiliary("spacer"), content: { _, _ in AnyView(Color.clear.frame(height: 350)) })
        } + [NativeTranscriptRow(id: .terminal, value: .auxiliary("terminal"), content: { _, _ in AnyView(Color.clear.frame(height: 1)) })]
        let rawSnapshot = Conversation(id: "foreground", storedID: "foreground", profileID: "foreground", messages: [message])
        let taskSnapshot: @MainActor () -> Conversation? = { rawSnapshot }
        controller.apply(context, snapshot: rawSnapshot, rows: rows, active: true, currentTaskSnapshot: taskSnapshot)
        try await wait("actual committed native transcript") { controller.collection.contentSize.height > 6000 }
        controller.collection.setContentOffset(.zero, animated: false)
        controller.collection.layoutIfNeeded()
        controller.scrollViewDidEndDragging(controller.collection, willDecelerate: false)
        let actionLabel = mode == .source ? "Show HTML source" : "Expand HTML preview"
        try await wait("actual displayed, eligible rich action") {
            (controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)?.exposure?.canPresent == true &&
                controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)).map { accessibilityElement(actionLabel, in: $0) != nil } == true
        }
        let currentCell = try #require(controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        let action = try #require(accessibilityElement(actionLabel, in: currentCell))
        #expect(action.accessibilityActivate())
        try await wait("actual presented Source controller") { controller.presentedViewController != nil }
        let source = try #require(controller.presentedViewController)
        let closeLabel = mode == .source ? "Close HTML source" : "Close HTML preview"
        try await wait("actual foreground content and Close action are presented") {
            source.view.window != nil && accessibilityElement(closeLabel, in: source.view) != nil && !source.isBeingPresented
        }
        var expandedDocument: WKWebView?
        var documentNonce: String?
        if mode == .expanded {
            try await wait("actual expanded WebKit document") { !webViews(source.view).isEmpty }
            let web = try #require(webViews(source.view).first)
            let report = try await childReport(web)
            #expect(report["counter"] == "1")
            documentNonce = try #require(report["nonce"])
            expandedDocument = web
        } else {
            #expect(accessibilityElement("Preview source", in: source.view) != nil)
            // A container-owned reserved edge must bound the readable viewport,
            // even though the code itself intentionally scrolls horizontally.
            source.additionalSafeAreaInsets.right = 64
            try await wait("the native Source safe area is applied") { source.view.safeAreaInsets.right >= 64 }
            func scrolls(_ view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
            }
            let code = try #require(scrolls(source.view).first { $0.contentSize.width > $0.bounds.width })
            func readableViewport() -> CGRect {
                var result = code.convert(code.bounds, to: source.view)
                var ancestor: UIView? = code
                while let view = ancestor {
                    if view.clipsToBounds { result = result.intersection(view.convert(view.bounds, to: source.view)) }
                    ancestor = view.superview
                }
                return result
            }
            try await wait("Source pixels respect the container's reserved edge after layout") {
                let rect = readableViewport(), safe = source.view.safeAreaLayoutGuide.layoutFrame
                return rect.width > 0 && rect.maxX <= safe.maxX + 1
            }
            // Clipping the underlap must not make the end of a long line
            // unreachable through ordinary horizontal scrolling.
            let endOffset = max(-code.adjustedContentInset.left,
                code.contentSize.width - code.bounds.width + code.adjustedContentInset.right)
            code.setContentOffset(CGPoint(x: endOffset, y: code.contentOffset.y), animated: false)
            #expect(code.contentOffset.x > 0 && code.isScrollEnabled)
            let end = code.convert(CGPoint(x: code.contentSize.width, y: code.contentOffset.y), to: source.view)
            #expect(end.x <= source.view.safeAreaLayoutGuide.layoutFrame.maxX + 1)
            context.colorScheme = .dark
        }
        context.dynamicType = .accessibility1
        controller.apply(context, snapshot: rawSnapshot, rows: rows, active: false, currentTaskSnapshot: taskSnapshot)
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.presentedViewController === source, "harmless environment refresh must preserve the foreground document")
        let cell = try #require(controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)
        let scope = try #require(cell.exposure)
        controller.collection.scrollToItem(at: IndexPath(item: rows.count - 1, section: 0), at: .bottom, animated: false)
        controller.collection.layoutIfNeeded()
        try await wait("source cell actually left the native viewport") { controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) == nil && cell.exposure !== scope }
        // The source remains semantically current even though its original host
        // no longer participates in this native viewport.
        for _ in 0..<500 { await Task.yield() }
        #expect(controller.presentedViewController === source && !source.isBeingDismissed && accessibilityElement(closeLabel, in: source.view) != nil,
                "cell recycling must not close a semantically current foreground document")
        #expect(!scope.isCurrent || !cell.isDisplayed)
        if let expandedDocument {
            #expect(webViews(source.view).contains { $0 === expandedDocument })
            let report = try await childReport(expandedDocument)
            #expect(report["counter"] == "1" && report["nonce"] == documentNonce,
                    "the original sandbox document and its local state must survive, not just its outer WKWebView")
            let showSource = try #require(accessibilityElement("Show HTML source", in: source.view, requiring: .button))
            #expect(showSource.accessibilityActivate())
            try await wait("expanded Source action remains current after original cell retirement") {
                accessibilityElement("Preview source", in: source.view) != nil
            }
        }
        // Actual semantic replacement must clear the foreground document; cell
        // continuity never grants it authority after its message changes.
        var replacement = message; replacement.text = "Replacement literal message"
        let changed = NativeTranscriptRow(id: row.id, value: .message(replacement, working: false), content: { _, _ in AnyView(Text(replacement.text)) })
        let replacementSnapshot = Conversation(id: "foreground", storedID: "foreground", profileID: "foreground", messages: [replacement])
        controller.apply(context, snapshot: replacementSnapshot, rows: [changed] + rows.dropFirst(), active: false, currentTaskSnapshot: { replacementSnapshot })
        try await wait("actual semantic content replacement dismisses foreground") { controller.presentedViewController == nil }
        #expect(accessibilityElement("Preview source", in: controller.view) == nil)
    }

    private func childReport(_ web: WKWebView) async throws -> [String: String] {
        weak var renderer = web.navigationDelegate as? RichContentRenderer
        let readyDeadline = ContinuousClock.now + .seconds(21)
        var committed = false
        while ContinuousClock.now < readyDeadline {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.querySelector('iframe') !== null")) as? Bool == true {
                committed = true; break
            }
            await Task.yield()
        }
        if !committed {
            Attachment.record("loading=\(web.isLoading) attached=\(web.window != nil) bounds=\(web.bounds) renderer=\(String(describing: renderer?.state))",
                              named: "Expanded preview host readiness")
        }
        try #require(committed, "actual renderer host document must commit before installing its report listener")
        _ = try await web.evaluateJavaScript("""
            window.testReport = null;
            if (!window.foregroundProbeListener) {
                window.foregroundProbeListener = true;
                window.addEventListener('message', e => {
                    if (e.source === document.querySelector('iframe').contentWindow && e.data.testReport)
                        window.testReport = e.data.testReport;
                });
            }
            """)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let json = try await web.evaluateJavaScript("JSON.stringify(window.testReport)") as? String,
               let report = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [String: String] {
                return report
            }
            await Task.yield()
        }
        Issue.record("actual opaque expanded document did not report its local state")
        return [:]
    }

    private func accessibilityElement(_ label: String, in root: NSObject, requiring traits: UIAccessibilityTraits = []) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 30, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if object.accessibilityLabel == label,
               traits.isEmpty || (object.isAccessibilityElement && object.accessibilityTraits.contains(traits)) { return object }
            if let view = object as? UIView {
                for child in view.subviews { if let found = find(child, depth: depth + 1) { return found } }
            }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject,
                       let found = find(child, depth: depth + 1) { return found }
                }
            }
            return nil
        }
        return find(root, depth: 0)
    }

    @Test(arguments: [false, true])
    func preparedNonvisibleCellCannotReviveFileWorkWhenDisplayedAfterCoverOrRetirement(retire: Bool) async throws {
        let service = try WorkspaceTestService(), session = service.summaries[0].identity
        let message = ChatMessage(id: "prepared-file", role: .assistant, text: "::preview{file=\"report.html\"}")
        service.snapshots[session.root] = .init(id: session.root.text, storedID: session.stored.text,
            profileID: session.profile.text, messages: [message])
        service.downloadData = Data("<!doctype html><html><body><p>Late prepared document.</p></body></html>".utf8)
        let gate = WorkspaceGate(); service.downloadGate = gate
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-preparation.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let screen = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(screen.owner); store.chats.displayed(screen.owner)
        let rich = store.richReplyContext(for: service.profile.text, messageID: message.id)
        #expect(rich.permits(try #require(ReplyContent(message: message).blocks.first)))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = NativeTranscriptController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { gate.release(); controller.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let context = NativeTranscriptContext(workspace: ObjectIdentifier(store.chats), profile: Data(service.profile.text.utf8),
            chat: screen.selectedChatID, owner: screen.owner, generation: store.artifactGeneration, reviewingConnection: false)
        let file = NativeTranscriptRow(id: .message(Data(message.id.utf8)), value: .message(message, working: false)) { _, _ in
            AnyView(AssistantReplyBody(message: message, isStreaming: false)
                .environment(\.richReplyContext, rich).environment(\.scenePhase, .active))
        }
        let rows: [NativeTranscriptRow] = [file,
            .init(id: .empty, value: .auxiliary("space"), content: { _, _ in AnyView(Color.clear.frame(height: 1600)) }),
            .init(id: .terminal, value: .auxiliary("terminal"), content: { _, _ in AnyView(Color.clear.frame(height: 1)) })]
        let workspace = store.chats, generation = store.artifactGeneration, owner = screen.owner
        let taskSnapshot: @MainActor () -> Conversation? = {
            guard store.chats === workspace, store.artifactGeneration == generation, workspace.isCurrent(owner) else { return nil }
            return workspace.screen(profile: service.profile)?.snapshot
        }
        controller.apply(context, snapshot: screen.snapshot, rows: rows, active: true, currentTaskSnapshot: taskSnapshot)
        try await wait("actual terminal below offscreen file") {
            controller.collection.cellForItem(at: IndexPath(item: 2, section: 0))?.frame.intersects(controller.collection.bounds) == true
        }
        let prepared = NativeTranscriptCell(frame: CGRect(x: 20, y: controller.collection.bounds.minY + 10,
            width: controller.collection.bounds.width - 40, height: 260))
        controller.prepare(prepared, for: file)
        controller.collection.addSubview(prepared)
        try await wait("actual prepared hosting content attached without display permission") {
            markers(prepared).contains { $0.bounds.height > 0 && $0.window != nil }
        }
        #expect(!controller.collection.visibleCells.contains(prepared))
        #expect(!prepared.isDisplayed)
        #expect(markers(prepared).allSatisfy { $0.presence?.isVisible != true })
        #expect(service.downloads == 0)
        if retire { controller.retire() }
        else { controller.apply(context, snapshot: screen.snapshot, rows: rows, active: false, currentTaskSnapshot: taskSnapshot) }
        // Exercise the production owned delegate after a configured but
        // non-displayed host crosses coverage/retirement. The old controller's
        // current policy must fence this late native lifecycle callback.
        controller.collectionView(controller.collection, willDisplay: prepared, forItemAt: IndexPath(item: 0, section: 0))
        let revived = markers(prepared).contains { $0.presence?.isVisible == true }
        #expect(!revived, "native block exposure must stay denied independently of deeper core/task guards")
        #expect(service.downloads == 0)
        if retire { #expect(prepared.exposure?.isCurrent == false) }
        gate.release()
        for _ in 0..<40 { await Task.yield() }
        #expect(webViews(prepared).isEmpty)
        #expect(markers(prepared).allSatisfy { $0.presence?.isVisible != true })
    }
    @Test func richCoverageReportThatRetiresItsTaskCannotPresentTheReleasedReservation() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let message = ChatMessage(id: "retiring-rich", role: .assistant, text: "```html\n<p>Reserved rich reader</p>\n```")
        service.snapshots[identity.root]?.messages = [message]
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-rich-reservation.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let workspace = store.chats, screen = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(screen.owner); workspace.displayed(screen.owner)
        let rich = store.richReplyContext(for: service.profile.text, messageID: message.id)
        let block = try #require(ReplyContent(message: message).blocks.first { $0.previewFormat == .html })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }, controller = NativeTranscriptController(), window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { controller.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let generation = store.artifactGeneration, owner = screen.owner
        let context = NativeTranscriptContext(workspace: ObjectIdentifier(workspace), profile: Data(service.profile.text.utf8),
            chat: screen.selectedChatID, owner: owner, generation: generation, reviewingConnection: false)
        let row = NativeTranscriptRow(id: .message(Data(message.id.utf8)), value: .message(message, working: false)) { _, _ in
            AnyView(RichReplyBlockView(block: block).environment(\.richReplyContext, rich))
        }
        controller.apply(context, snapshot: screen.snapshot, rows: [row], active: true, currentTaskSnapshot: {
            guard store.chats === workspace, generation == store.artifactGeneration, workspace.isCurrent(owner) else { return nil }
            return workspace.screen(profile: service.profile)?.snapshot
        })
        try await wait("real rich row has an admitted current native lease") {
            (controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)?.exposure?.canPresent == true
        }
        let scope = try #require((controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)?.exposure)
        var reports: [(UUID, Bool)] = []
        scope.present(block: block, context: rich, mode: .source) { id, shown in
            reports.append((id, shown))
            if shown { store.forgetConnection() }
        }
        #expect(controller.presentedViewController == nil)
        #expect(reports.map(\.1) == [true, false] && reports.first?.0 == reports.last?.0)
        #expect(!scope.canPresent)
    }

    @Test func detailsReaderSurvivesOwnCoverageEnvironmentAndCellReuseThenRetiresCopyOnClose() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.close() }
        try await wait("notification has an admitted current native row") { fixture.firstScope?.canPresent == true }
        let scope = try #require(fixture.firstScope)
        scope.present(details: .init(title: "Daily review", messages: [fixture.original]), report: fixture.report)
        try await wait("details sheet presents with its own coverage") {
            fixture.controller.presentedViewController?.isBeingPresented == false && fixture.covered
        }
        let sheet = try #require(fixture.controller.presentedViewController)
        try await wait("sheet Copy control is available") { accessibilityElement("Copy original", in: sheet.view) != nil }
        let copy = try #require(accessibilityElement("Copy original", in: sheet.view))
        #expect(!scope.canPresent && fixture.reports.map(\.1) == [true])
        UIPasteboard.general.string = "before-copy-sentinel"
        #expect(copy.accessibilityActivate())
        try await wait("covered sheet copies exact original bytes") {
            UIPasteboard.general.string.map { Data($0.utf8) } == Data(fixture.original.text.utf8)
        }
        fixture.context.colorScheme = .dark; fixture.context.dynamicType = .xxxLarge; fixture.apply()
        let cell = try #require(fixture.controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)
        cell.prepareForReuse()
        #expect(!scope.isCurrent && fixture.controller.presentedViewController === sheet)
        #expect(fixture.reports.map(\.1) == [true])
        #expect(accessibilityElement("Close", in: sheet.view) == nil)
        let presentation = try #require(sheet.presentationController)
        sheet.dismiss(animated: false)
        presentation.delegate?.presentationControllerDidDismiss?(presentation)
        try await wait("interactive dismissal releases the exact sheet coverage") { fixture.controller.presentedViewController == nil }
        #expect(fixture.reports.map(\.1) == [true, false] && fixture.reports[0].0 == fixture.reports[1].0)
        UIPasteboard.general.string = "closed-copy-sentinel"
        _ = copy.accessibilityActivate()
        #expect(UIPasteboard.general.string == "closed-copy-sentinel")
    }

    @Test(arguments: ["text", "provenance", "visibility", "duplicate", "removal", "task", "background"])
    func detailsReaderRetiresCopyWhenItsRawRowOrContextChanges(change: String) async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.close() }
        try await wait("details native row is admitted") { fixture.firstScope?.canPresent == true }
        let scope = try #require(fixture.firstScope)
        scope.present(details: .init(title: "Daily review", messages: [fixture.original]), report: fixture.report)
        try await wait("details sheet is presented") { fixture.controller.presentedViewController?.isBeingPresented == false && fixture.covered }
        let sheet = try #require(fixture.controller.presentedViewController)
        try await wait("sheet has original Copy control") { accessibilityElement("Copy original", in: sheet.view) != nil }
        let copy = try #require(accessibilityElement("Copy original", in: sheet.view))
        var changed = fixture.original
        switch change {
        case "text": changed.text += "\nChanged payload"
        case "provenance": changed.displayKind = nil
        case "visibility": changed.isSilent = true
        default: break
        }
        if change == "task" { fixture.store.forgetConnection(); fixture.apply() }
        else if change == "background" { fixture.context.scenePhase = .background; fixture.apply() }
        else if change == "removal" { try fixture.publish([]) }
        else if change == "duplicate" {
            var hidden = fixture.original; hidden.isSilent = true
            try fixture.publish([fixture.original, hidden])
        } else { try fixture.publish([changed]) }
        try await wait("raw/context revision closes the old reader") { fixture.controller.presentedViewController == nil }
        UIPasteboard.general.string = "retired-copy-sentinel"
        _ = copy.accessibilityActivate()
        #expect(UIPasteboard.general.string == "retired-copy-sentinel")
        #expect(fixture.reports.map(\.1) == [true, false] && fixture.reports[0].0 == fixture.reports[1].0)
        #expect(fixture.service.downloads == 0 && fixture.service.responses.isEmpty)
    }

    @Test(arguments: ["split", "removed", "duplicate", "reordered"])
    func workDetailsRetainsGrowingGroupButRetiresChangedIdentityOrBoundaries(change: String) async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.close() }
        let first = ChatMessage(id: "tool-one", role: .tool, text: "{\"answer\":1}", toolName: "first")
        let second = ChatMessage(id: "tool-two", role: .tool, text: "second exact result", toolName: "second")
        try fixture.publish([first, second])
        try await wait("grouped tool row is admitted") { fixture.firstScope?.canPresent == true }
        let scope = try #require(fixture.firstScope)
        #expect(!scope.admitsContent)
        scope.present(details: .init(title: "Work details", messages: [first]), report: fixture.report)
        scope.present(details: .init(title: "Work details", messages: [second, first]), report: fixture.report)
        #expect(fixture.controller.presentedViewController == nil && fixture.reports.isEmpty)
        scope.present(details: .init(title: "Work details", messages: [first, second]), report: fixture.report)
        try await wait("diagnostic reader accepts every exact tool group member") { fixture.covered && fixture.controller.presentedViewController?.isBeingPresented == false }
        let sheet = try #require(fixture.controller.presentedViewController)
        #expect(sheet.sheetPresentationController?.detents.map(\.identifier) == [.medium, .large])
        var revised = first; revised.text = "Updated tool result"
        let third = ChatMessage(id: "tool-three", role: .tool, text: "New work", toolName: "third")
        try fixture.publish([revised, second, third])
        #expect(fixture.controller.presentedViewController === sheet && fixture.reports.map(\.1) == [true])
        let hidden = ChatMessage(id: "hidden-separator", role: .system, text: "hidden", isSilent: true)
        let replacement: [ChatMessage] = switch change {
        case "split": [revised, hidden, second, third]
        case "removed": [revised, third]
        case "duplicate": [revised, second, third, revised]
        default: [revised, third, second]
        }
        try fixture.publish(replacement)
        try await wait("changed group identity or boundary retires the reader") { fixture.controller.presentedViewController == nil }
        #expect(fixture.reports.map(\.1) == [true, false])
        try fixture.publish([first, second])
        try await wait("disclosure can reopen after work changes") { fixture.firstScope?.canPresent == true }
        fixture.firstScope?.present(details: .init(title: "Work details", messages: [first, second]), report: fixture.report)
        try await wait("fresh work reader opens") { fixture.controller.presentedViewController != nil }
        #expect(fixture.reports.map(\.1) == [true, false, true])
    }

    @Test func detailsCoverageReservationRejectsCompetingReaderAndSynchronousRetirement() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.close() }
        try await wait("diagnostic row is admitted") { fixture.firstScope?.canPresent == true }
        let scope = try #require(fixture.firstScope)
        let document = WorkDetailsDocument(title: "Diagnostic", messages: [fixture.original])
        scope.present(details: document) { id, shown in
            if shown {
                scope.present(details: document, report: fixture.report)
                #expect(fixture.reports.isEmpty)
            }
            fixture.report(id, shown)
            if shown { fixture.controller.retire() }
        }
        #expect(fixture.controller.presentedViewController == nil)
        #expect(fixture.reports.map(\.1) == [true, false] && fixture.reports[0].0 == fixture.reports[1].0)
    }

    @Test(arguments: ["rich", "request", "details"])
    func nativeForegroundAndRequestReservationsExcludeEachOtherBeforeCoverageReturns(winner: String) async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.close() }
        let richMessage = ChatMessage(id: "competing-rich", role: .assistant, text: "```html\n<p>Competing rich reader</p>\n```")
        let choice = RequestChoice(id: "always", label: "Always allow")
        let request = PendingRequest(id: "competing-request", kind: .approval, title: "Competing request", choices: [choice])
        let identity = fixture.service.summaries[0].identity
        fixture.service.snapshots[identity.root]?.pendingRequests = [request]
        try fixture.publish([fixture.original, richMessage])
        try await wait("rich reader and request routes are admitted before reservation") {
            (0..<3).allSatisfy {
                (fixture.controller.collection.cellForItem(at: IndexPath(item: $0, section: 0)) as? NativeTranscriptCell)?.exposure?.canPresent == true
            }
        }
        func scope(_ item: Int) throws -> NativeTranscriptRowExposure {
            try #require((fixture.controller.collection.cellForItem(at: IndexPath(item: item, section: 0)) as? NativeTranscriptCell)?.exposure)
        }
        let rich = try scope(1), requestScope = try scope(2)
        let block = try #require(ReplyContent(message: richMessage).blocks.first { $0.previewFormat == .html })
        let richContext = fixture.store.richReplyContext(for: fixture.service.profile.text, messageID: richMessage.id)
        let report: @MainActor (UUID, Bool) -> Void = { id, shown in
            if shown {
                rich.present(block: block, context: richContext, mode: .source, report: fixture.report)
                if winner != "request", let confirmation = requestScope.requestActions?.choose(choice) {
                    requestScope.presentRequestConfirmation?(confirmation, fixture.report)
                    #expect(!confirmation.isCurrent)
                }
                #expect(fixture.reports.isEmpty, "the synchronous reservation interval admits no competing owner")
            }
            fixture.report(id, shown)
        }
        var requestConfirmation: RequestCardConfirmation?
        switch winner {
        case "rich": rich.present(block: block, context: richContext, mode: .source, report: report)
        case "details":
            let details = try scope(0)
            details.present(details: .init(title: "Work details", messages: [fixture.original]), report: report)
        default:
            requestConfirmation = try #require(requestScope.requestActions?.choose(choice))
            requestScope.presentRequestConfirmation?(try #require(requestConfirmation), report)
        }
        try await wait("exactly the reserved native owner is presented") { fixture.controller.presentedViewController != nil }
        #expect(fixture.reports.map(\.1) == [true])
        #expect((fixture.controller.presentedViewController is UIAlertController) == (winner == "request"))
        if let requestConfirmation { requestConfirmation.cancel(); fixture.apply() }
        else { try fixture.publish([]) }
        try await wait("the reserved owner releases its own coverage once") { fixture.controller.presentedViewController == nil }
        #expect(fixture.reports.map(\.1) == [true, false] && fixture.reports.first?.0 == fixture.reports.last?.0)
        try await wait("remaining actual request regains admission after coverage release") {
            let item = winner == "request" ? 2 : 0
            return (fixture.controller.collection.cellForItem(at: IndexPath(item: item, section: 0)) as? NativeTranscriptCell)?.exposure?.canPresent == true
        }
        #expect(fixture.service.responses.isEmpty)
    }

    @MainActor fileprivate final class TranscriptFixture {
        let service: WorkspaceTestService
        let store: AppStore
        let configuration: ConnectionConfiguration
        let original: ChatMessage
        let owner: PresentationOwner
        let access: ConversationAccess
        var context: NativeTranscriptContext
        let controller = NativeTranscriptController()
        let window: UIWindow
        let previous: UIWindow?
        let currentTaskSnapshot: @MainActor () -> Conversation?
        var reports: [(UUID, Bool)] = []
        var covered = false
        var admitted = true
        var firstScope: NativeTranscriptRowExposure? {
            (controller.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? NativeTranscriptCell)?.exposure
        }
        init() async throws {
            service = try WorkspaceTestService()
            let identity = service.summaries[0].identity
            original = .init(id: "scheduled-owner", role: .user,
                text: "[Cronjob \"Daily review\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n" + String(repeating: "Exact e\u{301} raw payload.\n", count: 80), displayKind: "internal_notification")
            service.snapshots[identity.root]?.messages = [original]
            configuration = .init(serverURL: URL(string: "https://native-scheduled-lifetime.invalid")!)
            store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
            try #require(await store.connect(configuration)); await store.open(try #require(store.bots.first))
            let workspace = store.chats, screen = try #require(workspace.screen(profile: service.profile)), store = store
            owner = screen.owner
            access = try #require(service.completedOpens.last).access
            await workspace.refreshDirectory(owner); workspace.displayed(owner)
            let profile = service.profile, owner = owner, generation = store.artifactGeneration
            context = .init(workspace: ObjectIdentifier(workspace), profile: Data(profile.text.utf8), chat: screen.selectedChatID,
                owner: owner, generation: generation, reviewingConnection: false)
            currentTaskSnapshot = {
                guard store.chats === workspace, store.artifactGeneration == generation, !store.showsConnection,
                      workspace.isCurrent(owner), workspace.screen(profile: profile)?.owner == owner else { return nil }
                return workspace.screen(profile: profile)?.snapshot
            }
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
            apply()
        }
        func report(_ id: UUID, _ shown: Bool) {
            reports.append((id, shown)); covered = shown
            store.chats.setTranscriptVisible(!shown, owner: owner)
            apply()
        }
        func apply() {
            let snapshot = store.chats.screen(profile: service.profile)?.snapshot
            var rows: [NativeTranscriptRow] = NativeTranscriptMessagePlan(snapshot?.messages ?? []).displayRows.map { row in
                switch row {
                case let .message(entry):
                    NativeTranscriptRow(id: entry.id, value: .message(entry.message, working: false)) { _, _ in
                        AnyView(MessageView(message: entry.message).environment(\.reportChatModal, self.report))
                    }
                case let .workDetails(messages):
                    NativeTranscriptRow(id: row.id, value: .workDetails(messages)) { _, _ in
                        AnyView(WorkDetailsView(messages: messages).environment(\.reportChatModal, self.report))
                    }
                }
            }
            if let screen = store.chats.screen(profile: service.profile) {
                for entry in NativeTranscriptRequestPlan(screen.requests).entries {
                    let input = RequestCardInput(row: entry.row, store: store, workspace: store.chats, owner: screen.owner, profile: service.profile)
                    rows.append(.init(id: entry.id, value: .request(entry.row.request, enabled: screen.canAct), request: entry.isAmbiguous ? nil : input) { scope, _ in
                        AnyView(RequestCard(input: input, canAct: screen.canAct, canEditDraft: screen.canEditDraft, lifetime: scope.requestState))
                    })
                }
            }
            rows.append(NativeTranscriptRow(id: .terminal, value: .auxiliary("terminal")) { _, _ in AnyView(Color.clear.frame(height: 1)) })
            controller.apply(context, snapshot: snapshot, rows: rows, active: !covered, currentTaskSnapshot: currentTaskSnapshot,
                admitsAction: { [admitted] in admitted })
        }
        func publish(_ messages: [ChatMessage]) throws {
            let identity = service.summaries[0].identity
            service.snapshots[identity.root]?.messages = messages
            let snapshot = try #require(service.snapshots[identity.root])
            service.onEvent?(.conversation(.init(identity: identity, snapshot: snapshot, access: access)))
            apply()
        }
        func close() {
            controller.retire(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.forgetConnection(); LocalHistory.remove(for: configuration.id)
        }
    }

    private func markers(_ view: UIView) -> [NativeTranscriptBlockMarker] {
        (view as? NativeTranscriptBlockMarker).map { [$0] } ?? view.subviews.flatMap(markers)
    }
    private func webViews(_ view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
    private func wait(_ reason: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Timed out: \(reason)")
    }
}

@Suite(.serialized, RichReplyRuntime()) @MainActor struct NativeTranscriptRequestReservationTests {
    @Test(arguments: ["retire", "cancel"])
    func requestRetiredDuringCoverageCannotPresentItsReleasedAlert(retirement: String) async throws {
        let fixture = try await NativeTranscriptLifecycleTests.TranscriptFixture()
        defer { fixture.close() }
        let choice = RequestChoice(id: "always", label: "Always allow")
        let request = PendingRequest(id: "retiring-request", kind: .approval, title: "Approve this scope?", choices: [choice])
        let identity = fixture.service.summaries[0].identity
        fixture.service.snapshots[identity.root]?.pendingRequests = [request]
        try fixture.publish([])
        try await wait("actual request row has an admitted current native lease") { fixture.firstScope?.canPresent == true }
        let scope = try #require(fixture.firstScope)
        let confirmation = try #require(scope.requestActions?.choose(choice))
        let present = try #require(scope.presentRequestConfirmation)
        present(confirmation) { id, shown in
            fixture.report(id, shown)
            if shown {
                if retirement == "retire" { fixture.controller.retire() }
                else { confirmation.cancel() }
            }
        }
        #expect(fixture.controller.presentedViewController == nil,
            "a request released synchronously by its coverage reporter must never present its old local alert")
        #expect(fixture.reports.map(\.1) == [true, false] && fixture.reports.first?.0 == fixture.reports.last?.0)
        #expect(!confirmation.isCurrent)
        #expect(fixture.service.responses.isEmpty && fixture.service.responseOperations.isEmpty)
    }

    @Test func ownCoverageKeepsConfirmationCurrentAndFreshRequestRejectsRetiredCallbacks() async throws {
        let fixture = try await NativeTranscriptLifecycleTests.TranscriptFixture()
        defer { fixture.close() }
        let choice = RequestChoice(id: "always", label: "Always allow")
        let request = PendingRequest(id: "covered-request", kind: .approval, title: "Approve this scope?", choices: [choice])
        let identity = fixture.service.summaries[0].identity
        fixture.service.snapshots[identity.root]?.pendingRequests = [request]
        try fixture.publish([])
        try await wait("actual request is ready before covering itself") { fixture.firstScope?.canPresent == true }
        let scope = try #require(fixture.firstScope)
        let confirmation = try #require(scope.requestActions?.choose(choice))
        scope.presentRequestConfirmation?(confirmation, fixture.report)
        try await wait("own coverage still presents the captured confirmation") {
            fixture.controller.presentedViewController is UIAlertController && fixture.controller.presentedViewController?.isBeingPresented == false
        }
        let original = try #require(fixture.controller.presentedViewController)
        #expect(confirmation.isCurrent && !scope.canPresent && fixture.reports.map(\.1) == [true])
        #expect(fixture.service.responses.isEmpty && fixture.service.responseOperations.isEmpty)
        confirmation.cancel(); fixture.apply()
        try await wait("cancel releases the original alert") { fixture.controller.presentedViewController == nil }
        #expect(fixture.reports.map(\.1) == [true, false] && fixture.reports[0].0 == fixture.reports[1].0)
        fixture.apply()
        try await wait("current uncovered publication restores actual native admission") { fixture.firstScope?.canPresent == true }
        let currentScope = try #require(fixture.firstScope)
        let replacement = try #require(currentScope.requestActions?.choose(choice))
        currentScope.presentRequestConfirmation?(replacement, fixture.report)
        try await wait("a deliberate fresh request presents a replacement alert") {
            fixture.controller.presentedViewController is UIAlertController && fixture.controller.presentedViewController?.isBeingPresented == false
        }
        let replacementAlert = try #require(fixture.controller.presentedViewController)
        #expect(replacementAlert !== original && replacement.isCurrent)
        #expect(fixture.reports.map(\.1) == [true, false, true])
        #expect(fixture.reports.allSatisfy { $0.0 == confirmation.modalID }, "one request lifetime reuses its modal ID across distinct alert reservations")
        confirmation.cancel(); confirmation.confirm()
        if let oldPresentation = original.presentationController { fixture.controller.presentationControllerDidDismiss(oldPresentation) }
        #expect(fixture.controller.presentedViewController === replacementAlert && replacement.isCurrent && fixture.reports.count == 3)
        #expect(fixture.service.responses.isEmpty && fixture.service.responseOperations.isEmpty)
        replacement.confirm()
        try await wait("only the deliberate current confirmation sends its captured request once") {
            fixture.service.responses == [request] && fixture.service.responseOperations.count == 1
        }
        fixture.apply()
        try await wait("successful confirmation releases its own alert coverage") { fixture.controller.presentedViewController == nil }
        #expect(fixture.reports.map(\.1) == [true, false, true, false])
        replacement.confirm(); confirmation.confirm()
        #expect(fixture.service.responseOperations.count == 1)
    }

    private func wait(_ reason: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Timed out: \(reason)")
    }
}
