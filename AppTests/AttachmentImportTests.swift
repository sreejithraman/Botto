import Foundation
import PDFKit
import Testing
import UIKit
import UniformTypeIdentifiers
import BottoCore
@testable import Botto

@Suite(.serialized) @MainActor struct AttachmentImportTests {
    private struct Failure: Error {}

    private func connected() async throws -> (AppStore, WorkspaceTestService, ConversationWorkspace, ChatScreen, () -> Void) {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://attachment-import.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration)); await store.open(try #require(store.bots.first))
        let screen = try #require(store.chats.screen(profile: service.profile))
        return (store, service, store.chats, screen, { store.forgetConnection(); LocalHistory.remove(for: configuration.id) })
    }

    private func input(_ name: String = "file.txt", read: @escaping AttachmentRead) -> AttachmentInput {
        AttachmentInput(name: name, read: read)
    }

    private func file(_ name: String) -> AttachmentInput {
        input(name) { AttachmentPayload(data: Data("Some notes".utf8), filename: name, mimeType: "text/plain") }
    }

    private var failing: AttachmentInput { input { throw Failure() } }

    /// Opens a reader on one file of a message holding all of these files.
    private func pagedReader(_ names: [String], opening index: Int,
                             downloadError: (any Error)? = nil) async throws -> (AppStore, WorkspaceTestService, WorkspacePresentation, () -> Void) {
        let (store, service, _, _, close) = try await connected()
        service.downloadError = downloadError
        let identity = try #require(service.completedOpens.last?.identity)
        let files = names.map { ChatAttachment(name: $0, path: "/\($0)", mimeType: "text/plain") }
        let message = ChatMessage(id: identity.stored.text + ":row:1", role: .assistant, text: "Files", attachments: files)
        service.snapshots[identity.root]?.messages = [message]
        store.chats.receive(try service.publication(identity))
        let destination = try #require(store.artifactDestination(for: files[index], botID: service.profile.text, producingMessage: message))
        let presentation = WorkspacePresentation()
        presentation.openArtifact(destination, store: store)
        return (store, service, presentation, close)
    }

    private func settled(_ reason: Comment = "a page finishes loading", _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), reason)
    }

    @Test func aBatchStagesInOrderAndOneFailureLeavesTheOthers() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        await workspace.importAttachments([file("a.txt"), failing, file("c.txt")],
                                          to: try #require(workspace.captureImport(screen.owner)))
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.attachments.map(\.name) == ["a.txt", "c.txt"])
        #expect(after.pendingAttachments.isEmpty, "A failed input leaves no tile behind")
        #expect(after.error != nil)
    }

    @Test func aLaterImportClearsItsOwnEarlierFailure() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        await workspace.importAttachments([failing], to: try #require(workspace.captureImport(screen.owner)))
        #expect(workspace.screen(profile: service.profile)?.error != nil)
        await workspace.importAttachments([file("a.txt")], to: try #require(workspace.captureImport(screen.owner)))
        #expect(workspace.screen(profile: service.profile)?.error == nil)
    }

    @Test func aBatchStopsAtTheAttachmentLimitAndSaysWhy() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        let names = (1...(AttachmentLimits.count + 1)).map { "\($0).txt" }
        await workspace.importAttachments(names.map(file), to: try #require(workspace.captureImport(screen.owner)))
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.attachments.count == AttachmentLimits.count)
        #expect(after.error == AttachmentLimits.message)
    }

    @Test func theChatStaysBusyFromTheFirstReadToTheLastUpload() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        let gate = WorkspaceGate()
        let intent = try #require(workspace.captureImport(screen.owner))
        let running = Task { await workspace.importAttachments([file("a.txt"), input { @MainActor in
            await gate.wait()
            return AttachmentPayload(data: Data([2]), filename: "b.txt", mimeType: "text/plain")
        }], to: intent) }
        await gate.entered()
        let held = try #require(workspace.screen(profile: service.profile))
        #expect(held.isUploading && held.attachments.map(\.name) == ["a.txt"])
        #expect(workspace.captureSend(held.owner) == nil, "Send waits for the whole batch")
        gate.release(); await running.value
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(!after.isUploading && after.attachments.map(\.name) == ["a.txt", "b.txt"])
    }

    @Test func eachChosenFileKeepsItsOwnTileUntilItIsAttached() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        let reading = WorkspaceGate(), uploading = WorkspaceGate()
        service.uploadGate = uploading
        let intent = try #require(workspace.captureImport(screen.owner))
        let running = Task { await workspace.importAttachments([input("a.txt") { @MainActor in
            await reading.wait()
            return AttachmentPayload(data: Data("Some notes".utf8), filename: "a.txt", mimeType: "text/plain")
        }, file("b.txt")], to: intent) }
        await reading.entered()

        var held = try #require(workspace.screen(profile: service.profile))
        #expect(held.pendingAttachments.map(\.name) == ["a.txt", "b.txt"])
        #expect(held.pendingAttachments.map(\.phase) == [.reading, .queued])
        #expect(held.pendingAttachments.allSatisfy { $0.preview == nil } && held.attachments.isEmpty)

        reading.release(); await uploading.entered()
        held = try #require(workspace.screen(profile: service.profile))
        #expect(held.pendingAttachments.map(\.phase) == [.uploading, .queued])
        #expect(held.pendingAttachments.first?.preview != nil, "The picture appears before the upload finishes")
        #expect(held.attachments.isEmpty, "Nothing is attached until the host accepts it")
        #expect(workspace.captureSend(held.owner) == nil)

        uploading.release(); service.uploadGate = nil; await running.value
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.pendingAttachments.isEmpty && after.attachments.map(\.name) == ["a.txt", "b.txt"])
    }

    @Test func cancellingOneTileLeavesTheRestOfTheBatch() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        let gate = WorkspaceGate()
        let intent = try #require(workspace.captureImport(screen.owner))
        let running = Task { await workspace.importAttachments([input("late.txt") { @MainActor in
            await gate.wait()
            return AttachmentPayload(data: Data([1]), filename: "late.txt", mimeType: "text/plain")
        }, file("kept.txt"), file("dropped.txt")], to: intent) }
        await gate.entered()
        let pending = try #require(workspace.screen(profile: service.profile)?.pendingAttachments)

        workspace.cancelPendingAttachment(pending[2].id, owner: screen.owner)
        #expect(workspace.screen(profile: service.profile)?.pendingAttachments.map(\.name) == ["late.txt", "kept.txt"])
        workspace.cancelPendingAttachment(pending[0].id, owner: screen.owner)
        #expect(workspace.screen(profile: service.profile)?.pendingAttachments.map(\.phase) == [.stopping, .queued])

        gate.release(); await running.value
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.attachments.map(\.name) == ["kept.txt"] && after.pendingAttachments.isEmpty)
        #expect(after.error == nil && service.uploads.count == 1)
    }

    @Test(arguments: [false, true])
    func cancellingAReadDoesNotWaitForItsProvider(hasFollowingFile: Bool) async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        let gate = WorkspaceGate()
        defer { gate.release() }
        var providerReturned = false
        let slow = input("held.txt") { @MainActor in
            await gate.wait()
            providerReturned = true
            return AttachmentPayload(data: Data("Late bytes".utf8), filename: "held.txt", mimeType: "text/plain")
        }
        let intent = try #require(workspace.captureImport(screen.owner))
        let running = Task { await workspace.importAttachments(hasFollowingFile ? [slow, file("next.txt")] : [slow], to: intent) }
        await gate.entered()
        let pending = try #require(workspace.screen(profile: service.profile)?.pendingAttachments.first)
        workspace.cancelPendingAttachment(pending.id, owner: screen.owner)

        let expected = hasFollowingFile ? ["next.txt"] : []
        try await settled("Cancel releases the chat before the provider returns") {
            let current = workspace.screen(profile: service.profile)
            return current?.isUploading == false && current?.pendingAttachments.isEmpty == true
                && current?.attachments.map(\.name) == expected
        }
        #expect(!providerReturned, "The provider is still held while the composer recovers")
        if !hasFollowingFile {
            await workspace.importAttachments([file("replacement.txt")],
                to: try #require(workspace.captureImport(screen.owner)))
            #expect(workspace.screen(profile: service.profile)?.attachments.map(\.name) == ["replacement.txt"])
        }

        gate.release(); await running.value
        try await settled { providerReturned }
        #expect(workspace.screen(profile: service.profile)?.attachments.map(\.name) ==
                (hasFollowingFile ? ["next.txt"] : ["replacement.txt"]))
        #expect(service.uploads.count == 1 && workspace.screen(profile: service.profile)?.error == nil)
    }

    @Test func aTileCancelledMidUploadStaysUntilTheFrameSettles() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        let gate = WorkspaceGate()
        service.uploadGate = gate
        let intent = try #require(workspace.captureImport(screen.owner))
        let running = Task { await workspace.importAttachments([file("sent.txt"), file("next.txt")], to: intent) }
        await gate.entered()
        let pending = try #require(workspace.screen(profile: service.profile)?.pendingAttachments)
        workspace.cancelPendingAttachment(pending[0].id, owner: screen.owner)
        let held = try #require(workspace.screen(profile: service.profile))
        #expect(held.pendingAttachments.map(\.phase) == [.stopping, .queued] && held.isUploading)
        #expect(workspace.captureSend(held.owner) == nil)

        gate.release(); service.uploadGate = nil; await running.value
        #expect(workspace.screen(profile: service.profile)?.attachments.map(\.name) == ["next.txt"],
                "The cancelled file is never staged, and the batch carries on")
    }

    @Test func pendingTilesStayWithTheirChat() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        await workspace.refreshDirectory(screen.owner)
        let sibling = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        let gate = WorkspaceGate()
        service.uploadGate = gate
        let intent = try #require(workspace.captureImport(screen.owner))
        let running = Task { await workspace.importAttachments([file("mine.txt"), file("queued.txt")], to: intent) }
        await gate.entered()

        await workspace.select(try #require(workspace.captureSelection(sibling, owner: screen.owner)))
        let elsewhere = try #require(workspace.screen(profile: service.profile))
        #expect(elsewhere.owner.chat != screen.owner.chat)
        #expect(elsewhere.pendingAttachments.isEmpty && elsewhere.attachments.isEmpty)

        workspace.cancelImport(intent)
        gate.release(); service.uploadGate = nil; await running.value
        let returned = try #require(workspace.cards(profile: service.profile).first(where: \.isMain)?.id)
        await workspace.select(try #require(workspace.captureSelection(returned, owner: elsewhere.owner)))
        let original = try #require(workspace.screen(profile: service.profile))
        #expect(original.owner.chat == screen.owner.chat)
        #expect(original.pendingAttachments.isEmpty && original.attachments.isEmpty, "A stopped import publishes nothing on return")
    }

    @Test func aDocumentKeepsItsPreviewUnderItsSentPath() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        await workspace.importAttachments([file("notes.txt")], to: try #require(workspace.captureImport(screen.owner)))
        let staged = try #require(workspace.screen(profile: service.profile)?.attachments.first)
        var sent = staged
        sent.stagingID = nil
        #expect(workspace.thumbnails.image(for: sent) != nil)
    }

    @Test func aReaderLoadsOnlyThePagesBesideTheSelectedOne() async throws {
        let (_, service, presentation, close) = try await pagedReader(["a.txt", "b.txt", "c.txt", "d.txt"], opening: 1)
        defer { close() }
        let selected = try #require(presentation.artifact)
        #expect(selected.page?.index == 1 && selected.page?.count == 4)
        try await settled { [0, 1, 2].allSatisfy { presentation.artifactSession(atPage: $0)?.file != nil } }
        #expect(presentation.artifactSession(atPage: 3) == nil && service.downloads == 3)
    }

    @Test func turningThePageKeepsLoadedNeighborsAndRetiresTheFarSide() async throws {
        let (store, service, presentation, close) = try await pagedReader(["a.txt", "b.txt", "c.txt", "d.txt"], opening: 1)
        defer { close() }
        try await settled { [0, 1, 2].allSatisfy { presentation.artifactSession(atPage: $0)?.file != nil } }
        let first = try #require(presentation.artifactSession(atPage: 0))
        let previous = try #require(presentation.artifact)
        let next = try #require(presentation.artifactSession(atPage: 2))
        let file = next.file
        #expect(presentation.moveArtifact(by: 1, id: previous.id, store: store))

        #expect(presentation.artifact === next && next.title == "c.txt" && next.file === file)
        #expect(next.readerID == previous.readerID, "The same reader stays on screen")
        #expect(presentation.artifactSession(atPage: 1) === previous && previous.isCurrent)
        #expect(!first.isCurrent, "A page two steps away gives up its read")
        try await settled { presentation.artifactSession(atPage: 3)?.file != nil }
        #expect(service.downloads == 4, "Only the newly adjacent page is read")
    }

    @Test func aFailedNeighborRetriesWhenItIsSelected() async throws {
        let (store, service, presentation, close) = try await pagedReader(["a.txt", "b.txt"], opening: 0,
                                                                          downloadError: HermesServiceError.disconnected)
        defer { close() }
        let selected = try #require(presentation.artifact)
        let neighbor = try #require(presentation.artifactSession(atPage: 1))
        try await settled { selected.errorMessage != nil && neighbor.errorMessage != nil }
        #expect(selected.file == nil && neighbor.file == nil)

        service.downloadError = nil
        #expect(presentation.moveArtifact(by: 1, id: selected.id, store: store))
        #expect(presentation.artifact === neighbor)
        try await settled { neighbor.file != nil && neighbor.errorMessage == nil }
        #expect(selected.file == nil, "An unselected page waits for a deliberate turn back")
    }

    @Test func aPageCannotTurnWhileExportOwnsTheReader() async throws {
        let (store, _, presentation, close) = try await pagedReader(["a.txt", "b.txt"], opening: 0)
        defer { close() }
        try await settled { [0, 1].allSatisfy { presentation.artifactSession(atPage: $0)?.file != nil } }
        let selected = try #require(presentation.artifact)
        selected.beginOutput(.share)
        let output = try #require(selected.output)
        #expect(!presentation.moveArtifact(by: 1, id: selected.id, store: store))
        #expect(presentation.artifact === selected)

        selected.endOutput(id: output.id)
        #expect(presentation.moveArtifact(by: 1, id: selected.id, store: store))
        let turned = try #require(presentation.artifact)
        turned.beginOutput(.save)
        #expect(turned.output?.file.filename == "b.txt", "Save takes the file on screen")
        #expect(selected.output == nil)
    }

    @Test(arguments: [false, true])
    func anUnloadedNeighborRenewsAccessBeforeSelection(wasLoading: Bool) async throws {
        let (store, service, presentation, close) = try await pagedReader(["a.txt", "b.txt"], opening: 0,
                                                                          downloadError: HermesServiceError.disconnected)
        defer { close() }
        let selected = try #require(presentation.artifact)
        let neighbor = try #require(presentation.artifactSession(atPage: 1))
        try await settled { selected.errorMessage != nil && neighbor.errorMessage != nil }
        service.downloadError = nil
        selected.retry()
        try await settled { selected.file != nil }
        let original = try #require(selected.file)

        let gate = WorkspaceGate()
        defer { gate.release() }
        if wasLoading {
            service.downloadGate = gate
            neighbor.retry()
            await gate.entered()
        }
        let previous = try #require(store.chats.screen(profile: service.profile))
        let identity = try #require(service.completedOpens.last?.identity)
        store.chats.receive(try service.publication(identity))
        #expect(store.chats.screen(profile: service.profile)?.owner != previous.owner)
        #expect(selected.isCurrent && !neighbor.isCurrent)
        service.downloadGate = nil

        #expect(presentation.moveArtifact(by: 1, id: selected.id, store: store))
        gate.release()
        let turned = try #require(presentation.artifact)
        try await settled("The adjacent file loads after chat access renews") { turned.file != nil }
        #expect(turned.isCurrent && turned.title == "b.txt")
        #expect(presentation.artifactSession(atPage: 0)?.file === original)
        turned.beginOutput(.save)
        #expect(turned.output?.file.filename == "b.txt" && turned.output?.file.data == service.downloadData)
    }

    @Test func closingTheReaderRetiresItsNeighbors() async throws {
        let (_, _, presentation, close) = try await pagedReader(["a.txt", "b.txt"], opening: 0)
        defer { close() }
        try await settled { presentation.artifactSession(atPage: 1)?.file != nil }
        let selected = try #require(presentation.artifact)
        let neighbor = try #require(presentation.artifactSession(atPage: 1))
        presentation.closeArtifact(id: selected.id)
        #expect(presentation.artifact == nil && !neighbor.isCurrent)
        #expect(presentation.artifactSession(atPage: 1) == nil)
    }

    @Test func aCancelledImportDropsWorkThatFinishesLate() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        let gate = WorkspaceGate()
        let intent = try #require(workspace.captureImport(screen.owner))
        let running = Task { await workspace.importAttachments([input { @MainActor in
            await gate.wait()
            return AttachmentPayload(data: Data([1]), filename: "late.txt", mimeType: "text/plain")
        }, file("never.txt")], to: intent) }
        await gate.entered()
        workspace.cancelImport(intent)
        #expect(workspace.screen(profile: service.profile)?.isUploading == false)
        gate.release(); await running.value
        let after = try #require(workspace.screen(profile: service.profile))
        #expect(after.attachments.isEmpty && service.uploads.isEmpty)
    }

    @Test func cancellingBeforeDispatchFreesTheChatForTheNextImport() async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        let gate = WorkspaceGate()
        let cancelled = try #require(workspace.captureImport(screen.owner))
        let running = Task { await workspace.importAttachments([input { @MainActor in
            await gate.wait()
            return AttachmentPayload(data: Data([1]), filename: "late.txt", mimeType: "text/plain")
        }], to: cancelled) }
        await gate.entered()
        workspace.cancelImport(cancelled)
        await workspace.importAttachments([file("next.txt")], to: try #require(workspace.captureImport(screen.owner)))
        gate.release(); await running.value
        #expect(workspace.screen(profile: service.profile)?.attachments.map(\.name) == ["next.txt"])
    }

    @Test(arguments: [false, true])
    func aCancelledDispatchedUploadHoldsTheChatUntilItDrainsAndPublishesNothing(fails: Bool) async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        await workspace.importAttachments([file("earlier.txt")], to: try #require(workspace.captureImport(screen.owner)))
        let gate = WorkspaceGate()
        service.uploadGate = gate
        service.uploadError = fails ? HermesServiceError.disconnected : nil
        let intent = try #require(workspace.captureImport(screen.owner))
        let running = Task { await workspace.importAttachments([file("first.txt"), file("never.txt")], to: intent) }
        await gate.entered()
        #expect(service.uploads.count == 2)

        workspace.cancelImport(intent)
        let held = try #require(workspace.screen(profile: service.profile))
        #expect(held.isUploading, "The frame already left, so the chat stays busy")
        #expect(workspace.captureSend(held.owner) == nil)
        let next = try #require(workspace.captureImport(held.owner))
        let refused = Task { await workspace.importAttachments([file("second.txt")], to: next) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.uploads.count == 2, "No second frame goes out behind the first")

        gate.release(); await running.value; await refused.value
        service.uploadGate = nil; service.uploadError = nil
        let drained = try #require(workspace.screen(profile: service.profile))
        #expect(!drained.isUploading && drained.error == nil)
        #expect(drained.attachments.map(\.name) == ["earlier.txt"], "A cancelled import publishes neither its file nor its failure")
        #expect(service.uploads.count == 2, "Cancelling stops the rest of the batch")

        await workspace.importAttachments([file("third.txt")], to: try #require(workspace.captureImport(drained.owner)))
        #expect(workspace.screen(profile: service.profile)?.attachments.map(\.name) == ["earlier.txt", "third.txt"])
    }

    @Test(arguments: [false, true])
    func renewedChatAccessKeepsDispatchedUploadsBusyUntilTheyDrain(fails: Bool) async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        let gate = WorkspaceGate()
        service.uploadGate = gate
        service.uploadError = fails ? HermesServiceError.disconnected : nil
        let running = Task { await workspace.importAttachments([file("old.txt")],
            to: try #require(workspace.captureImport(screen.owner))) }
        await gate.entered()
        let identity = try #require(service.uploads.last)
        workspace.receive(try service.publication(identity))
        let renewed = try #require(workspace.screen(profile: service.profile))
        #expect(renewed.owner != screen.owner)
        #expect(renewed.isUploading)
        #expect(renewed.pendingAttachments.map(\.phase) == [.stopping], "The old upload can't be recalled, so its tile says so")
        workspace.editDraft("Keep this draft", owner: renewed.owner)
        #expect(workspace.captureSend(renewed.owner) == nil)
        let next = try #require(workspace.captureImport(renewed.owner))
        let refused = Task { await workspace.importAttachments([file("too-early.txt")], to: next) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.uploads.count == 1)
        gate.release(); try await running.value; await refused.value
        service.uploadGate = nil; service.uploadError = nil
        let drained = try #require(workspace.screen(profile: service.profile))
        #expect(!drained.isUploading && drained.error == nil && drained.attachments.isEmpty && drained.pendingAttachments.isEmpty)
        #expect(workspace.draft(drained.owner) == "Keep this draft")
        await workspace.importAttachments([file("new.txt")],
            to: try #require(workspace.captureImport(drained.owner)))
        #expect(workspace.screen(profile: service.profile)?.attachments.map(\.name) == ["new.txt"])
    }

    @Test(arguments: ["payload", "archive.unknownkind"])
    func aCopiedGenericFileImportsUnderItsOriginalName(name: String) async throws {
        let (_, service, workspace, screen, close) = try await connected()
        defer { close() }
        let bytes = Data([0, 159, 146, 150])
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { completion in
            completion(bytes, nil); return nil
        }
        let type = try #require(ComposerPaste.attachmentType(provider.registeredTypeIdentifiers, named: true))
        let read = AttachmentSource.pasted(PastedAttachment(provider: provider, type: type))
        let payload = try await read.read()
        #expect(payload.filename == name && payload.mimeType == "application/octet-stream" && payload.data == bytes)

        await workspace.importAttachments([read], to: try #require(workspace.captureImport(screen.owner)))
        #expect(workspace.screen(profile: service.profile)?.attachments.map(\.name) == [name])
    }

    @Test func sentPhotosKeepTheirThumbnailUnderTheHostsNewDirectory() throws {
        let thumbnails = AttachmentThumbnails()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
        let staged = ChatAttachment(name: "Photo.jpg", path: "/h/uploads/upload_abcd1234.jpg", mimeType: "image/jpeg")
        thumbnails.retain(image, for: staged)
        let sent = ChatAttachment(name: "Photo.jpg", path: "/h/native-inputs/7/upload_abcd1234.jpg", mimeType: "image/jpeg")
        #expect(thumbnails.image(for: sent) != nil)
        thumbnails.discard(staged)
        #expect(thumbnails.image(for: sent) == nil)
    }

    @Test(arguments: [
        (["public.jpeg"], false, UTType.jpeg.identifier),
        (["public.png", "public.utf8-plain-text"], false, nil),
        (["com.apple.DocumentManager.FINode.File", "public.plain-text"], true, UTType.plainText.identifier),
        (["public.url", "public.utf8-plain-text"], true, nil),
        (["public.utf8-plain-text"], false, nil),
        (["com.adobe.pdf"], true, UTType.pdf.identifier),
        (["public.data"], true, UTType.data.identifier),
        (["public.data"], false, nil),
        (["com.apple.DocumentManager.FINode.File", "public.data"], true, UTType.data.identifier),
        (["public.url", "public.data"], true, nil),
        (["public.folder"], true, nil),
    ] as [([String], Bool, String?)])
    func pasteTreatsNamedFilesAndImagesAsAttachmentsAndLinksAsText(types: [String], named: Bool, expected: String?) {
        #expect(ComposerPaste.attachmentType(types, named: named)?.identifier == expected)
    }

    @Test(arguments: [
        ("notes.txt", UTType.plainText, "notes.txt"),
        ("photo.jpg", UTType.jpeg, "photo.jpg"),
        ("notes.log", UTType.plainText, "notes.log"),
        ("notes", UTType.plainText, "notes.txt"),
        ("a/b\nc", UTType.jpeg, "a-b-c.jpeg"),
        ("  ", UTType.png, "Pasted image.png"),
        ("..", UTType.pdf, "Pasted file.pdf"),
        ("payload", UTType.data, "payload"),
        ("archive.unknownkind", UTType.data, "archive.unknownkind"),
        ("a/b", UTType.data, "a-b"),
        ("..", UTType.data, "Pasted file"),
    ] as [(String, UTType, String)])
    func pastedFilesGetASafeNameWithOneExtension(suggested: String, type: UTType, expected: String) {
        let provider = NSItemProvider(); provider.suggestedName = suggested
        let name = PastedAttachment(provider: provider, type: type).filename(temporaryFile: URL(fileURLWithPath: "/tmp/x.bin"))
        #expect(name == expected)
    }

    @Test func aFannedCardRestsBehindTheFrontWithoutTiltOrSwing() {
        let front = AttachmentFanPose(distance: 0, cardWidth: 200, reduceMotion: false)
        #expect(front.x == 0 && front.scale == 1 && front.tilt == 0 && front.turn == 0)
        let next = AttachmentFanPose(distance: 1, cardWidth: 200, reduceMotion: false)
        let previous = AttachmentFanPose(distance: -1, cardWidth: 200, reduceMotion: false)
        #expect(next.x > 0 && previous.x == -next.x && next.scale < 1 && abs(previous.tilt) < 0.001)
        #expect(next.turn == -previous.turn)
        #expect(AttachmentFanPose(distance: 3, cardWidth: 200, reduceMotion: false).opacity == 0)
    }

    @Test func onlyTheCardLeavingTheFrontSwingsAndReduceMotionStillsIt() {
        let leaving = AttachmentFanPose(distance: -0.5, cardWidth: 200, reduceMotion: false)
        let rising = AttachmentFanPose(distance: 0.5, cardWidth: 200, reduceMotion: false)
        #expect(leaving.x < -50 && leaving.tilt != 0)
        #expect(rising.x > 0 && rising.tilt == 0)
        let calm = AttachmentFanPose(distance: -0.5, cardWidth: 200, reduceMotion: true)
        #expect(calm.tilt == 0 && calm.turn == 0 && abs(calm.x) < abs(leaving.x))
    }
}

/// Reads pixels the way they reached the screen, to prove a preview shows the file's content.
private struct PreviewPixels {
    private let bytes: [UInt8]
    let width: Int, height: Int

    init(_ image: UIImage) throws {
        let cgImage = try #require(image.cgImage)
        width = cgImage.width; height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    /// Measured from the top left.
    func color(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    func darkShare(rows: Range<Int>) -> Double {
        var dark = 0
        for y in rows { for x in 0..<width where color(x: x, y: y).green < 128 { dark += 1 } }
        return Double(dark) / Double(width * rows.count)
    }
}

@Suite @MainActor struct AttachmentPreviewTests {
    private func pdf(size: CGSize = CGSize(width: 612, height: 792), draw: (CGContext) -> Void) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            context.beginPage()
            draw(context.cgContext)
        }
    }

    private func preview(_ data: Data, name: String, type: String) async -> UIImage? {
        await AttachmentPreview.rendered(AttachmentPayload(data: data, filename: name, mimeType: type))
    }

    @Test func aPDFPreviewDrawsItsFirstPage() async throws {
        let data = pdf { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 612, height: 396))
        }
        let pixels = try PreviewPixels(try #require(await preview(data, name: "report.pdf", type: "application/pdf")))
        #expect(max(pixels.width, pixels.height) == 480)
        let top = pixels.color(x: pixels.width / 2, y: pixels.height / 4)
        let bottom = pixels.color(x: pixels.width / 2, y: pixels.height * 3 / 4)
        #expect(top.red > 200 && top.green < 60, "The page's top half stays on top")
        #expect(bottom.red > 240 && bottom.green > 240)
    }

    @Test func aSmallPDFPageGrowsToFillItsPreview() async throws {
        let data = pdf(size: CGSize(width: 100, height: 100)) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let pixels = try PreviewPixels(try #require(await preview(data, name: "tiny.pdf", type: "application/pdf")))
        #expect(pixels.width == 480 && pixels.color(x: 470, y: 470).green < 30)
    }

    @Test func aTextPreviewDrawsTheFilesOpeningWords() async throws {
        let notes = String(repeating: "Attachment preview notes\n", count: 5)
        let pixels = try PreviewPixels(try #require(await preview(Data(notes.utf8), name: "notes.txt", type: "text/plain")))
        #expect(pixels.width == 360 && pixels.height == 466)
        #expect(pixels.darkShare(rows: 20..<100) > 0.02, "Words start at the top of the page")
        #expect(pixels.darkShare(rows: 300..<460) == 0, "A short file leaves the rest of the page blank")
    }

    @Test func aLongTextFileIsBoundedAndCutOnWholeCharacters() async throws {
        let data = Data(("a" + String(repeating: "é", count: 200_000)).utf8)
        let image = try #require(await preview(data, name: "long.txt", type: "text/plain"))
        #expect(image.size == CGSize(width: 360, height: 466))
    }

    @Test(arguments: [
        ("blank.txt", "text/plain", Data("  \n\t ".utf8)),
        ("broken.pdf", "application/pdf", Data("not a pdf".utf8)),
        ("binary.txt", "text/plain", Data([0, 159, 146, 150])),
        ("archive.zip", "application/zip", Data([80, 75, 3, 4]))
    ])
    func aFileThatCantBeDrawnKeepsItsNamedTile(name: String, type: String, data: Data) async {
        #expect(await preview(data, name: name, type: type) == nil)
    }

    @Test func anEncryptedPDFKeepsItsNamedTile() async throws {
        let document = try #require(PDFDocument(data: pdf { _ in }))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: path) }
        #expect(document.write(to: path, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "user"]))
        #expect(await preview(try Data(contentsOf: path), name: "locked.pdf", type: "application/pdf") == nil)
    }
}
