import SwiftUI
import UIKit
import BottoCore

struct WorkDetailsDocument {
    let title: String
    let messages: [ChatMessage]
}

/// Semantic row lifetime. A cell lease can end while this unique, unchanged
/// message remains current. This record retains no cell, renderer or document.
@MainActor @Observable final class NativeTranscriptRowAuthority {
    private(set) var isCurrent = true
    func invalidate() { isCurrent = false }
}

/// One foreground reader belongs to the transcript, outside reusable cell hosts.
/// Its captured Core context remains a prerequisite for both source and execution.
@MainActor final class NativeTranscriptPresentation: NSObject, UIAdaptivePresentationControllerDelegate {
    @MainActor @Observable final class Session {
        let id = UUID()
        enum Content {
            case rich(ReplyContent.Block, RichReplyContext)
            case details(WorkDetailsDocument, @MainActor () -> Bool)
        }
        let content: Content
        let authority: NativeTranscriptRowAuthority
        let report: @MainActor (UUID, Bool) -> Void
        var isOpen = true
        var mode: RichReplyPresentationMode
        var environment: NativeTranscriptContext
        var isCurrent: Bool {
            guard isOpen, authority.isCurrent else { return false }
            switch content {
            case let .rich(block, context): return context.permits(block)
            case let .details(_, current): return environment.scenePhase == .active && current()
            }
        }
        init(block: ReplyContent.Block, context: RichReplyContext, authority: NativeTranscriptRowAuthority,
             mode: RichReplyPresentationMode, environment: NativeTranscriptContext,
             report: @escaping @MainActor (UUID, Bool) -> Void) {
            self.content = .rich(block, context); self.authority = authority
            self.mode = mode; self.environment = environment; self.report = report
        }
        init(details: WorkDetailsDocument, authority: NativeTranscriptRowAuthority,
             environment: NativeTranscriptContext, isCurrent: @escaping @MainActor () -> Bool,
             report: @escaping @MainActor (UUID, Bool) -> Void) {
            self.content = .details(details, isCurrent); self.authority = authority
            self.mode = .source; self.environment = environment; self.report = report
        }
    }
    private var session: Session?
    var isPresenting: Bool { session != nil }
    private weak var host: UIViewController?

    func open(block: ReplyContent.Block, context: RichReplyContext, authority: NativeTranscriptRowAuthority,
              mode: RichReplyPresentationMode, environment: NativeTranscriptContext,
              report: @escaping @MainActor (UUID, Bool) -> Void, from owner: UIViewController) {
        guard session == nil, owner.presentedViewController == nil, owner.viewIfLoaded?.window != nil,
              authority.isCurrent, context.permits(block) else { return }
        let current = Session(block: block, context: context, authority: authority, mode: mode,
                              environment: environment, report: report)
        present(current, from: owner)
    }
    func openDetails(_ document: WorkDetailsDocument, authority: NativeTranscriptRowAuthority,
                     environment: NativeTranscriptContext, isCurrent: @escaping @MainActor () -> Bool,
                     report: @escaping @MainActor (UUID, Bool) -> Void, from owner: UIViewController) {
        guard session == nil, owner.presentedViewController == nil, owner.viewIfLoaded?.window != nil,
              authority.isCurrent, environment.scenePhase == .active, isCurrent() else { return }
        let current = Session(details: document, authority: authority, environment: environment,
                              isCurrent: isCurrent, report: report)
        present(current, from: owner)
    }
    private func present(_ current: Session, from owner: UIViewController) {
        let host = UIHostingController(rootView: Foreground(session: current, close: { [weak self] in self?.close(current.id) }))
        host.modalPresentationStyle = .pageSheet
        self.session = current; self.host = host
        host.presentationController?.delegate = self
        host.sheetPresentationController?.prefersGrabberVisible = true
        if case .details = current.content { host.sheetPresentationController?.detents = [.medium(), .large()] }
        current.report(current.id, true)
        guard session?.id == current.id, current.isCurrent else { close(current.id); return }
        owner.present(host, animated: true) { [weak self, weak host] in
            guard let self, self.session?.id == current.id, current.isCurrent,
                  current.environment.scenePhase == .active, host?.viewIfLoaded?.window != nil else { return }
            BottoHaptics.shared.play(.surface)
        }
    }
    func reconcile(environment: NativeTranscriptContext) {
        guard let session else { return }
        session.environment = environment
        if !session.isCurrent { close(session.id) }
    }
    func retire() { if let session { close(session.id) } }
    func close(_ id: UUID) {
        guard let current = session, current.id == id else { return }
        session = nil; current.isOpen = false
        let closing = host; host = nil
        current.report(current.id, false)
        closing?.dismiss(animated: false)
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === host, let current = session else { return }
        close(current.id)
    }
    private struct Foreground: View {
        let session: Session
        let close: () -> Void
        var body: some View {
            Group {
                if session.isCurrent {
                    switch session.content {
                    case let .rich(block, context):
                        RichReplyPresentationContent(block: block, context: context,
                            selection: Binding(get: { session.mode }, set: { if session.isCurrent { session.mode = $0 } }),
                            isCurrent: { session.isCurrent }, close: close)
                    case let .details(document, _):
                        WorkDetailsSheet(document: document, isCurrent: { session.isCurrent }, close: close)
                    }
                }
            }
            .environment(\.scenePhase, session.environment.scenePhase)
            .environment(\.colorScheme, session.environment.colorScheme)
            .preferredColorScheme(session.environment.colorScheme)
            .environment(\.dynamicTypeSize, session.environment.dynamicType)
            .environment(\.layoutDirection, session.environment.direction)
            .tint(BottoTheme.action)
            .onChange(of: session.isCurrent) { _, current in if !current { close() } }
        }
    }
}
