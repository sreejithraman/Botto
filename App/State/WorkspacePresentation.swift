import Foundation
import Observation
import BottoCore

struct SearchMessageTarget {
    let chat: LibraryChat
    let message: ChatMessage
    let query: String

    static func sameSource(_ first: SessionIdentity, _ second: SessionIdentity) -> Bool {
        first.profile == second.profile && first.root == second.root && first.stored == second.stored
    }

    @MainActor func resolve(identity: SessionIdentity, snapshot: Conversation?) -> ChatMessage? {
        guard Self.sameSource(identity, chat.identity), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.hasStableIdentity(storedID: identity.stored.text),
              let snapshot, Data(snapshot.profileID.utf8) == identity.profile.bytes,
              Data(snapshot.storedID.utf8) == identity.stored.bytes,
              snapshot.unavailableMessageIDs?.contains(Data(message.id.utf8)) != true else { return nil }
        let matches = snapshot.messages.filter { Data($0.id.utf8) == Data(message.id.utf8) }
        guard matches.count == 1, let current = matches.first,
              current.isVisible, current.hasStableIdentity(storedID: identity.stored.text), NativeSearchMatch.contains(query: query, in: current),
              NativeTranscriptMessagePlan(snapshot.messages, queuedMessages: snapshot.queuedMessages).displayRows.contains(where: {
                  if case .message(let entry) = $0 { return !entry.isAmbiguous && Data(entry.message.id.utf8) == Data(message.id.utf8) }
                  return false
              }) else { return nil }
        return current
    }
}

struct SearchMessageFocus: Identifiable {
    let id = UUID()
    let workspace: ObjectIdentifier
    let owner: PresentationOwner
    let identity: SessionIdentity
    let message: ChatMessage
    let query: String
    var needsReveal = true

    @MainActor func matches(workspace: ConversationWorkspace) -> Bool {
        guard ObjectIdentifier(workspace) == self.workspace, workspace.isCurrent(owner),
              let selection = workspace.selection(profile: identity.profile), selection.owner == owner,
              let selectedIdentity = selection.identity, SearchMessageTarget.sameSource(selectedIdentity, identity) else { return false }
        return TranscriptMessageIndex(selection.snapshot).matches(message)
    }
}

enum SearchMessageOpeningResult {
    case opened(SearchMessageFocus), unavailable, couldNotOpen, superseded
}
enum SearchFocusResult { case revealed, unavailable, cancelled }

enum WorkspaceDestination: Hashable { case bots, artifacts, search }

/// Scene-owned task presentation. Native hosts project this state; they never
/// create a second destination or own a download's lifetime.
@MainActor @Observable final class WorkspacePresentation {
    private enum Target {
        case chat
        case artifact(ArtifactPreviewSession, expanded: Bool)
    }
    private enum Surface {
        case reading(Target)
        case browsingBots(returnTo: Target)
    }
    private var surface: Surface = .reading(.chat)
    /// Loaded pages beside the selected file, by position, so a swipe shows their content.
    /// They never own export or navigation; only `artifact` does.
    private var artifactNeighbors: [Int: ArtifactPreviewSession] = [:]
    private(set) var revision = UUID()
    var destination = WorkspaceDestination.bots
    var libraryReader: LibraryArtifactPreviewSession?
    var libraryOpening: Task<Void, Never>?
    private var chatAfterReaderDismissal: LibraryChat?
    private(set) var searchFocus: SearchMessageFocus?
    var searchError: String?

    private var target: Target {
        switch surface {
        case .reading(let target), .browsingBots(let target): target
        }
    }
    var isBrowsingBots: Bool {
        if case .browsingBots = surface { return true }
        return false
    }
    var artifact: ArtifactPreviewSession? {
        if case .artifact(let session, _) = target { return session }
        return nil
    }
    var isArtifactExpanded: Bool {
        if case .artifact(_, let expanded) = target { return expanded }
        return false
    }

    func openArtifact(_ destination: AppStore.ArtifactDestination, store: AppStore) {
        guard artifact?.id != destination.id else { return }
        guard store.canStartArtifactRead(destination), artifact?.isPresentingOutput != true else {
            store.finishArtifact(destination)
            return
        }
        let previous = artifact
        searchFocus = nil
        let session = ArtifactPreviewSession(destination: destination, store: store)
        surface = .reading(.artifact(session, expanded: false)); revision = UUID()
        // Retire UI/callback ownership before releasing its operation reservation.
        previous?.finish(); retireArtifactNeighbors()
        session.retry()
        loadArtifactNeighbors(reusing: [:], store: store)
    }

    func artifactSession(atPage index: Int) -> ArtifactPreviewSession? {
        artifact?.page?.index == index ? artifact : artifactNeighbors[index]
    }

    /// Selects a sibling, returning false when the current reader can't turn the page.
    @discardableResult func moveArtifact(by step: Int, id: UUID, store: AppStore) -> Bool {
        guard let selected = artifact, selected.id == id, !isBrowsingBots, !selected.isPresentingOutput,
              let index = selected.page?.index else { return false }
        var pages = artifactNeighbors
        pages[index] = selected
        guard let next = sibling(of: selected, by: step, reusing: pages.removeValue(forKey: index + step),
                                 store: store) else { return false }
        searchFocus = nil
        surface = .reading(.artifact(next, expanded: isArtifactExpanded)); revision = UUID()
        next.retry()
        loadArtifactNeighbors(reusing: pages, store: store)
        return true
    }

    /// Keeps the pages one step away and retires the rest. A neighbor's failure stays
    /// on its own page, where the reader can retry once it is selected.
    private func loadArtifactNeighbors(reusing pages: [Int: ArtifactPreviewSession], store: AppStore) {
        var retired = pages
        var neighbors: [Int: ArtifactPreviewSession] = [:]
        if let selected = artifact, let page = selected.page {
            for index in [page.index - 1, page.index + 1] where (0..<page.count).contains(index) {
                let retained = retired.removeValue(forKey: index)
                guard let session = sibling(of: selected, by: index - page.index, reusing: retained,
                                            store: store) else { continue }
                neighbors[index] = session
                if session !== retained { session.retry() }
            }
        }
        artifactNeighbors = neighbors
        retired.values.forEach { $0.finish() }
    }

    private func sibling(of selected: ArtifactPreviewSession, by step: Int,
                         reusing retained: ArtifactPreviewSession?, store: AppStore) -> ArtifactPreviewSession? {
        if let retained, retained.isCurrent { return retained }
        retained?.finish()
        guard let destination = selected.adjacentDestination(by: step) else { return nil }
        guard store.canStartArtifactRead(destination) else { store.finishArtifact(destination); return nil }
        return ArtifactPreviewSession(destination: destination, store: store, readerID: selected.readerID)
    }

    private func retireArtifactNeighbors() {
        let neighbors = artifactNeighbors
        artifactNeighbors = [:]
        neighbors.values.forEach { $0.finish() }
    }

    func cancelLibraryOpening() {
        chatAfterReaderDismissal = nil
        libraryOpening?.cancel(); libraryOpening = nil
    }

    func closeLibraryReader(opening chat: LibraryChat? = nil) {
        chatAfterReaderDismissal = chat
        libraryReader?.finish()
        libraryReader = nil
    }

    func takeChatAfterReaderDismissal() -> LibraryChat? {
        defer { chatAfterReaderDismissal = nil }
        return chatAfterReaderDismissal
    }

    func browseBots() {
        guard !isBrowsingBots, artifact?.isPresentingOutput != true else { return }
        searchFocus = nil
        surface = .browsingBots(returnTo: target); revision = UUID()
    }

    func resumeTask() {
        guard isBrowsingBots else { return }
        surface = .reading(target); revision = UUID()
    }

    /// Settles the whole destination at once: a tab or reader left for a later update
    /// still covers the workspace, and its compact column can then miss the native split view.
    func didChooseConversation() {
        searchFocus = nil; searchError = nil
        cancelLibraryOpening(); closeLibraryReader()
        destination = .bots
        let previous = artifact
        surface = .reading(.chat); revision = UUID()
        previous?.finish(); retireArtifactNeighbors()
    }

    func didChooseConversation(focusing focus: SearchMessageFocus) {
        didChooseConversation()
        searchFocus = focus
    }

    func selectedBotChanged(store: AppStore) {
        if let focus = searchFocus, focus.matches(workspace: store.chats),
           store.selectedBotID.map({ Data($0.utf8) }) == focus.identity.profile.bytes { return }
        if store.selectedBotID != nil { didChooseConversation() }
        else { reconcile(store: store) }
    }

    func retireSearchFocus() { searchFocus = nil }

    func reportSearchFocus(_ id: UUID, result: SearchFocusResult) {
        guard searchFocus?.id == id else { return }
        switch result {
        case .revealed: searchFocus?.needsReveal = false
        case .cancelled: searchFocus = nil
        case .unavailable:
            searchFocus = nil
            searchError = "This message is no longer available here. Refresh Search and try again."
        }
    }

    func closeArtifact(id: UUID) {
        guard artifact?.id == id, artifact?.isPresentingOutput != true else { return }
        removeArtifact()
    }

    func setArtifactExpanded(_ expanded: Bool, id: UUID) {
        guard let artifact, artifact.id == id, artifact.isCurrent,
              !isBrowsingBots, !artifact.isPresentingOutput,
              isArtifactExpanded != expanded else { return }
        surface = .reading(.artifact(artifact, expanded: expanded)); revision = UUID()
    }

    /// Bindings also check their geometric host. A callback from a previous
    /// semantic surface cannot close a resumed or replacement reader.
    func acceptsArtifactCallback(id: UUID, revision: UUID) -> Bool {
        self.revision == revision && artifact?.id == id && !isBrowsingBots
            && artifact?.isCurrent == true && artifact?.isPresentingOutput != true
    }

    func retryArtifact(id: UUID, revision: UUID, canPresent: () -> Bool) {
        guard acceptsArtifactCallback(id: id, revision: revision), canPresent() else { return }
        artifact?.retry()
    }

    func reconcile(store: AppStore) {
        if let focus = searchFocus {
            let selectedProfile = store.selectedBotID.map { Data($0.utf8) } == focus.identity.profile.bytes
            if !selectedProfile || !focus.matches(workspace: store.chats) {
                if selectedProfile, focus.needsReveal, store.chats.isCurrent(focus.owner) {
                    searchError = "This message is no longer available here. Refresh Search and try again."
                }
                searchFocus = nil
            }
        }
        if let artifact, !artifact.isCurrent(in: store) { removeArtifact() }
    }

    private func removeArtifact() {
        let previous = artifact
        surface = isBrowsingBots ? .browsingBots(returnTo: .chat) : .reading(.chat)
        revision = UUID()
        previous?.finish(); retireArtifactNeighbors()
    }
}

/// Owns one captured capability, load, and local file across all native hosts.
/// Views may request outputs, but cannot load, cancel, or finish the model.
@MainActor @Observable final class ArtifactPreviewSession: Identifiable, ArtifactReadingSession {
    typealias Output = ArtifactOutput

    let id: UUID
    /// Shared by the pages of one reader, so turning a page keeps the reader on screen.
    let readerID: UUID
    private var destination: AppStore.ArtifactDestination
    private let store: AppStore
    private let model = ArtifactPreviewModel()

    var file: ArtifactPreviewFile? { isCurrent ? model.file : nil }
    var errorMessage: String? { isCurrent ? model.errorMessage : nil }
    var requiresConnection: Bool { isCurrent && model.requiresConnection }
    var isLoading: Bool { isCurrent && model.isLoading }
    // Local captures follow semantic presentation; cache misses still require live access.
    var isCurrent: Bool {
        !model.isFinished && store.isAuthorizedArtifactPresentation(destination)
            && (model.file != nil || store.canStartArtifactRead(destination))
    }
    var output: Output? { isCurrent ? model.output : nil }
    var exportError: String? { isCurrent ? model.exportError : nil }
    var exportErrorID: UUID? { isCurrent ? model.exportErrorID : nil }
    var isPresentingOutput: Bool { isCurrent && model.isPresentingOutput }
    var title: String { destination.attachment.name }

    fileprivate init(destination: AppStore.ArtifactDestination, store: AppStore, readerID: UUID = UUID()) {
        id = destination.id; self.destination = destination; self.store = store; self.readerID = readerID
    }

    fileprivate func isCurrent(in store: AppStore) -> Bool { self.store === store && isCurrent }

    var page: (index: Int, count: Int)? {
        let siblings = destination.siblings
        guard siblings.count > 1, let index = siblings.firstIndex(where: { $0.id == destination.attachment.id }) else { return nil }
        return (index, siblings.count)
    }
    fileprivate func adjacentDestination(by step: Int) -> AppStore.ArtifactDestination? {
        store.artifactDestination(adjacentTo: destination, by: step)
    }

    func retry() { load(.initial) }
    func reload() { load(.reload) }

    private func load(_ request: ArtifactPreviewModel.Request) {
        model.request(request, isCurrent: { [weak self] in self?.isCurrent == true }, prepareDownload: {
            if let renewed = store.renewedArtifactDestination(destination) { destination = renewed }
            return { [store, destination] in
                try await store.downloadArtifact(destination, force: request == .reload)
            }
        })
    }

    func beginOutput(_ kind: Output.Kind) {
        guard isCurrent else { return }
        model.beginOutput(kind)
    }

    func endOutput(id: UUID, error: Error? = nil) {
        guard isCurrent else { return }
        model.endOutput(id: id, error: error)
    }

    func clearExportError(id: UUID?) { model.clearExportError(id: id) }

    fileprivate func finish() {
        guard model.finish() else { return }
        store.finishArtifact(destination)
    }
}
