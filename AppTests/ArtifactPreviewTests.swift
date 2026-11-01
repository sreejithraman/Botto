import Foundation
import Testing
import CoreGraphics
import ImageIO
import BottoCore
import UniformTypeIdentifiers
@testable import Botto

@MainActor struct ArtifactPreviewTests {
    @Test(arguments: [UTType.pdf, .plainText, .png, .html, .data])
    func bytePreservingDocumentDeclaresConcreteExportTypes(type: UTType) {
        #expect(ArtifactDocument.writableContentTypes.contains(type),
                "SwiftUI requires the concrete requested type, even when it conforms to public.data")
    }

    @Test(arguments: [
        ("pdf", "text/plain", UTType.pdf),
        ("txt", "application/pdf", UTType.plainText),
        ("png", "application/octet-stream", UTType.png),
        ("html", "text/html", UTType.html),
        ("", "image/jpeg", UTType.jpeg),
        ("bin", "application/octet-stream", UTType.data),
        ("json", "application/json", UTType.data)
    ])
    func exportKeepsExtensionPrecedenceAndDeclaredFallback(ext: String, mime: String, expected: UTType) {
        let type = ArtifactDocument.exportType(filenameExtension: ext, mimeType: mime)
        #expect(type == expected)
        #expect(ArtifactDocument.writableContentTypes.contains(type))
    }

    @Test func previewAndExportKeepExactBytesInPrivateSanitizedFile() async throws {
        let bytes = Data([0, 255, 128, 10, 13, 0])
        let model = ArtifactPreviewModel()
        await model.load { DownloadedArtifact(data: bytes, filename: "../../report.bin", mimeType: "application/octet-stream") }
        let file = try #require(model.file)
        #expect(file.filename == "report.bin")
        #expect(try Data(contentsOf: file.url) == bytes)
        #expect(file.data == bytes)
        #expect(file.url.deletingLastPathComponent() != FileManager.default.temporaryDirectory)
        model.cancel()
    }
    @Test func downloadUsesCapturedConversationAndRefusesSelectionRetirement() async throws {
        let service = ArtifactService()
        let storage = ArtifactStorage()
        let store = AppStore(service: service, persistence: storage.persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://artifact.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        await store.open(service.profiles[0])
        let epoch = store.artifactGeneration
        let attachment = ChatAttachment(name: "report.txt", path: "/workspace/report.txt", mimeType: "text/plain")
        let destination = try #require(store.artifactDestination(for: attachment, botID: "canvas"))
        let downloaded = try await store.downloadArtifact(destination)
        #expect(downloaded.data == Data("origin bytes".utf8))
        #expect(service.downloads.first?.0 == attachment)
        #expect(service.downloads.first?.1.id == "runtime-canvas")
        #expect(service.downloads.first?.1.storedID == "stored-canvas")
        store.selectedBotID = "other"
        #expect(store.artifactGeneration != epoch)
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination) }
        #expect(service.downloads.count == 1)
    }

    @Test(arguments: ["selection", "reopen", "workspace", "reconnect", "recovery", "background", "runtime", "stored", "forget"])
    func retiredOwnersCancelInflightDownloadsAndCannotPublishLateBytes(retirement: String) async throws {
        let service = ArtifactService()
        let store = AppStore(service: service, persistence: ArtifactStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://artifact.example")!)
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://other.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id); LocalHistory.remove(for: replacement.id) }
        #expect(await store.connect(connection))
        await store.open(service.profiles[0])
        let epoch = store.artifactGeneration
        let destination = try #require(store.artifactDestination(for: .init(name: "report.txt", path: "/report.txt"), botID: "canvas"))
        let gate = ArtifactGate()
        service.gate = gate
        let loading = Task { try await store.downloadArtifact(destination) }
        await gate.entered()
        switch retirement {
        case "selection": store.selectedBotID = "other"
        case "reopen": await store.open(service.profiles[0])
        case "workspace": #expect(await store.connect(replacement))
        case "reconnect": #expect(await store.connect(connection))
        case "recovery": service.onEvent?(.disconnected("Offline")); service.onEvent?(.connected(.init(version: "test")))
        case "background": await store.setActive(false)
        case "runtime": service.onEvent?(.conversation(try service.authority.opened(.init(id: "new-runtime", storedID: "stored-canvas", profileID: "canvas"))))
        case "stored": service.onEvent?(.conversation(try service.authority.opened(.init(id: "runtime-canvas", storedID: "new-stored", profileID: "canvas"))))
        default: store.forgetConnection()
        }
        #expect(store.artifactGeneration != epoch)
        #expect(!store.isCurrentArtifactDestination(destination))
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await loading.value }
        #expect(service.downloadWasCancelled)
        #expect(service.downloads.count == 1)
        #expect(service.downloads[0].1.id == "runtime-canvas")
    }

    @Test(arguments: [false, true])
    func completedLocalFileRemainsAuthorizedAcrossDisconnectAndRecovery(recover: Bool) async throws {
        let service = ArtifactService()
        let store = AppStore(service: service, persistence: ArtifactStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://artifact.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        await store.open(service.profiles[0])
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt")
        let destination = try #require(store.artifactDestination(for: attachment, botID: "canvas"))
        let model = ArtifactPreviewModel()
        defer { model.cancel() }
        await model.load { try await store.downloadArtifact(destination) }
        let file = try #require(model.file)

        service.onEvent?(.disconnected("Offline"))
        #expect(store.isAuthorizedArtifactPresentation(destination))
        #expect(!store.isCurrentArtifactDestination(destination))
        let offline = try #require(store.artifactDestination(for: attachment, botID: "canvas"))
        #expect(store.isAuthorizedArtifactPresentation(offline))
        #expect(!store.isCurrentArtifactDestination(offline))
        store.finishArtifact(offline)
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination) }
        #expect(service.downloads.count == 1)
        if recover { service.onEvent?(.connected(.init(version: "test"))) }

        #expect(store.isAuthorizedArtifactPresentation(destination))
        #expect(!store.isCurrentArtifactDestination(destination), "Recovery cannot revive a retired download owner")
        #expect(model.file === file)
        #expect(try Data(contentsOf: file.url) == Data("origin bytes".utf8))
    }

    @Test(arguments: ["background", "foreground", "reconnect", "reopen", "secret rotation"])
    func completedLocalFileSurvivesSameOwnerConnectionWork(transition: String) async throws {
        let service = ArtifactService()
        let store = AppStore(service: service, persistence: ArtifactStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://artifact.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        await store.start()
        #expect(await store.connect(connection))
        await store.open(service.profiles[0])
        let destination = try #require(store.artifactDestination(for: .init(name: "report.txt", path: "/report.txt"), botID: "canvas"))
        let model = ArtifactPreviewModel()
        defer { model.cancel() }
        await model.load { try await store.downloadArtifact(destination) }
        let file = try #require(model.file)
        switch transition {
        case "background", "foreground":
            await store.setActive(false)
            #expect(store.isAuthorizedArtifactPresentation(destination))
            #expect(!store.isCurrentArtifactDestination(destination))
            if transition == "foreground" {
                await store.setActive(true)
                #expect(store.isConnected)
            }
        case "reconnect": #expect(await store.connect(connection))
        case "reopen": await store.open(service.profiles[0])
        default:
            var rotated = connection
            rotated.password = "replacement-secret"
            service.onEvent?(.configuration(rotated))
        }
        #expect(store.isAuthorizedArtifactPresentation(destination))
        #expect(model.file === file)
        #expect(try Data(contentsOf: file.url) == Data("origin bytes".utf8))
        #expect(service.downloads.count == 1)
        if transition != "secret rotation" {
            #expect(!store.isCurrentArtifactDestination(destination))
            await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination) }
            #expect(service.downloads.count == 1)
        }
    }

    @Test func localFileRemainsAuthorizedWhenSameSourceLearnsAliases() async throws {
        let service = ArtifactService()
        let store = AppStore(service: service, persistence: ArtifactStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://artifact-alias.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        await store.open(service.profiles[0])
        let destination = try #require(store.artifactDestination(for: .init(name: "report.txt", path: "/report.txt"), botID: "canvas"))
        let model = ArtifactPreviewModel()
        defer { model.cancel() }
        await model.load { try await store.downloadArtifact(destination) }
        let file = try #require(model.file)
        let current = try service.authority.opened(#require(store.conversation(for: "canvas")))
        let identity = SessionIdentity(profile: current.identity.profile, root: current.identity.root,
                                       stored: current.identity.stored, aliases: [try ExactID("discovered-alias")])
        service.onEvent?(.conversation(.init(identity: identity, snapshot: current.snapshot, access: current.access)))
        #expect(store.isAuthorizedArtifactPresentation(destination))
        #expect(try Data(contentsOf: file.url) == Data("origin bytes".utf8))
    }

    @Test(arguments: ["selection", "review", "workspace", "account", "account bytes", "install", "provider", "runtime", "runtime bytes", "stored", "stored bytes", "forget"])
    func completedLocalPresentationRevokesWhenItsOwnerChanges(change: String) async throws {
        let service = ArtifactService()
        let store = AppStore(service: service, persistence: ArtifactStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://artifact.example")!, username: "Café")
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://other.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id); LocalHistory.remove(for: replacement.id) }
        #expect(await store.connect(connection))
        await store.open(service.profiles[0])
        service.onEvent?(.conversation(try service.authority.opened(.init(id: "runtime-Café", storedID: "stored-Café", profileID: "canvas"))))
        let destination = try #require(store.artifactDestination(for: .init(name: "report.txt", path: "/report.txt"), botID: "canvas"))
        let model = ArtifactPreviewModel()
        defer { model.cancel() }
        await model.load { try await store.downloadArtifact(destination) }
        #expect(model.file != nil)
        #expect(store.isAuthorizedArtifactPresentation(destination))
        switch change {
        case "selection":
            store.selectedBotID = "other"
            #expect(!store.isAuthorizedArtifactPresentation(destination))
            store.selectedBotID = "canvas"
        case "review":
            store.showsConnection = true
            #expect(!store.isAuthorizedArtifactPresentation(destination))
            store.showsConnection = false
        case "workspace":
            #expect(await store.connect(replacement))
            await store.open(service.profiles[0])
        case "account", "account bytes", "install", "provider":
            var changed = connection
            if change == "account" { changed.username = "other-account" }
            if change == "account bytes" { changed.username = "Cafe\u{301}" }
            if change == "install" { changed.installID = "other-install" }
            if change == "provider" { changed.nativeCredential = .init(refreshToken: "test-token", provider: "other-provider") }
            service.onEvent?(.configuration(changed))
            #expect(!store.isAuthorizedArtifactPresentation(destination))
            service.onEvent?(.configuration(connection))
        case "runtime", "runtime bytes", "stored", "stored bytes":
            var changed = destination.conversation
            if change == "runtime" { changed.id = "other-runtime" }
            if change == "runtime bytes" { changed.id = "runtime-Cafe\u{301}" }
            if change == "stored" { changed.storedID = "other-stored" }
            if change == "stored bytes" { changed.storedID = "stored-Cafe\u{301}" }
            service.onEvent?(.conversation(try service.authority.opened(changed)))
            #expect(!store.isAuthorizedArtifactPresentation(destination))
            service.onEvent?(.conversation(try service.authority.opened(destination.conversation)))
        default: store.forgetConnection()
        }
        #expect(!store.isAuthorizedArtifactPresentation(destination), "Returning to an old owner must not restore retired presentation")
        #expect(!store.isCurrentArtifactDestination(destination))
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(destination) }
        #expect(service.downloads.count == 1)
    }

    @Test func oversizedServiceResultDoesNotCreateAFileAndCanRetry() async throws {
        let model = ArtifactPreviewModel()
        await model.load { DownloadedArtifact(data: Data(repeating: 7, count: 25 * 1024 * 1024 + 1), filename: "too-big.bin", mimeType: "application/octet-stream") }
        #expect(model.file == nil)
        #expect(model.errorMessage?.contains("25 MB") == true)
        #expect(!model.isLoading)
        await model.load { DownloadedArtifact(data: Data("retry bytes".utf8), filename: "retry.txt", mimeType: "text/plain") }
        #expect(model.file?.data == Data("retry bytes".utf8))
        #expect(model.errorMessage == nil)
        model.cancel()
    }

    @Test func ordinaryDemoIncludesRichCanvasAndScopedDownloads() async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://demo.botto.local")!)
        let rich = DemoBotService()
        _ = try await rich.connect(configuration: connection)
        #expect(try await rich.bots().map(\.id) == ["milo", "scout", "iris", "atlas", "canvas"])
        let canvas = try #require(try await rich.bots().first { $0.id == "canvas" })
        #expect(canvas.name == "Canvas")
        #expect(canvas.isPinned)
        let opened = try await rich.openChat(.canonical(profile: try ExactID(canvas.id), expectedRoot: nil))
        let chat = opened.snapshot
        let text = try #require(chat.messages.last?.text)
        #expect(text.contains("Before the dashboard"))
        #expect(text.contains("```html"))
        #expect(text.contains("```mermaid"))
        #expect(text.contains("```svg"))
        #expect(text.contains("```swift"))
        for name in ["report.pdf", "notes.txt", "chart.png", "report.html"] {
            let opened = try await rich.openChat(.canonical(profile: try ExactID(canvas.id), expectedRoot: nil))
            let attachment = ChatAttachment(name: name, path: "/demo/canvas/" + name)
            let first = try await rich.downloadArtifact(attachment, access: opened.access)
            let second = try await rich.downloadArtifact(attachment, access: opened.access)
            #expect(first.filename == name)
            #expect(!first.data.isEmpty)
            #expect(first.data == second.data)
            if name == "report.pdf" {
                let provider = try #require(CGDataProvider(data: first.data as CFData))
                let document = try #require(CGPDFDocument(provider))
                #expect(document.numberOfPages == 1)
                #expect(document.page(at: 1)?.getBoxRect(.mediaBox).width == 612)
            }
            if name == "chart.png" {
                let source = try #require(CGImageSourceCreateWithData(first.data as CFData, nil))
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(image.width == 96)
                #expect(image.height == 64)
            }
            if name == "notes.txt" { #expect(String(data: first.data, encoding: .utf8)?.contains("Canvas demo") == true) }
            if name == "report.html" { #expect(String(data: first.data, encoding: .utf8)?.contains("<!doctype html>") == true) }
            let other = try await rich.openChat(.canonical(profile: try ExactID("scout"), expectedRoot: nil))
            await #expect(throws: (any Error).self) { _ = try await rich.downloadArtifact(attachment, access: other.access) }
        }
    }

    @Test func returningToSameSelectionDoesNotReviveRetiredDestination() async throws {
        let service = ArtifactService()
        let store = AppStore(service: service, persistence: ArtifactStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://artifact.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        await store.open(service.profiles[0])
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt")
        let old = try #require(store.artifactDestination(for: attachment, botID: "canvas"))
        store.selectedBotID = "other"
        store.selectedBotID = "canvas"
        #expect(!store.isCurrentArtifactDestination(old))
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(old) }
        let fresh = try #require(store.artifactDestination(for: attachment, botID: "canvas"))
        #expect(store.isCurrentArtifactDestination(fresh))
        _ = try await store.downloadArtifact(fresh)
        #expect(service.downloads.count == 1)
    }

    @Test func connectionReviewRetiresPendingReadAndCancelRequiresFreshDestination() async throws {
        let service = ArtifactService()
        let store = AppStore(service: service, persistence: ArtifactStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://artifact.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        await store.open(service.profiles[0])
        let attachment = ChatAttachment(name: "report.txt", path: "/report.txt")
        let old = try #require(store.artifactDestination(for: attachment, botID: "canvas"))
        let rowEpoch = store.artifactGeneration
        let gate = ArtifactGate()
        service.gate = gate
        let loading = Task { try await store.downloadArtifact(old) }
        await gate.entered()

        store.showsConnection = true
        let reviewEpoch = store.artifactGeneration
        #expect(reviewEpoch != rowEpoch)
        #expect(!store.isCurrentArtifactDestination(old))
        #expect(store.artifactDestination(for: attachment, botID: "canvas") == nil)
        store.showsConnection = true
        #expect(store.artifactGeneration == reviewEpoch)
        store.showsConnection = false
        #expect(store.artifactGeneration == reviewEpoch)
        #expect(!store.isCurrentArtifactDestination(old))

        // Even a service that ignores cancellation cannot return late bytes
        // after the connection review has already been canceled.
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await loading.value }
        #expect(service.downloadWasCancelled)
        service.gate = nil
        await #expect(throws: (any Error).self) { _ = try await store.downloadArtifact(old) }
        #expect(service.downloads.count == 1)
        let fresh = try #require(store.artifactDestination(for: attachment, botID: "canvas"))
        #expect(store.isCurrentArtifactDestination(fresh))
        let downloaded = try await store.downloadArtifact(fresh)
        #expect(downloaded.data == Data("origin bytes".utf8))
        #expect(service.downloads.count == 2)
    }

    @Test func dismissalKeepsActiveReadersThenRemovesOnlyOwnedDirectory() async throws {
        let model = ArtifactPreviewModel()
        let sibling = ArtifactPreviewModel()
        await model.load { DownloadedArtifact(data: Data("share reader".utf8), filename: "shared.txt", mimeType: "text/plain") }
        await sibling.load { DownloadedArtifact(data: Data("other preview".utf8), filename: "other.txt", mimeType: "text/plain") }
        var reader = model.file
        let url = try #require(reader?.url)
        let siblingURL = try #require(sibling.file?.url)
        model.cancel()
        #expect(try Data(contentsOf: url) == Data("share reader".utf8))
        reader = nil
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: siblingURL) == Data("other preview".utf8))
        sibling.cancel()
        #expect(!FileManager.default.fileExists(atPath: siblingURL.deletingLastPathComponent().path))
    }

    @Test(arguments: [("..\\..\\notes.txt", "notes.txt"), ("/", "File"), ("..", "File"), ("\0", "File"), ("a:b.txt", "ab.txt")])
    func untrustedFilenameCannotEscapePrivateDirectory(input: String, expected: String) async throws {
        let model = ArtifactPreviewModel()
        await model.load { DownloadedArtifact(data: Data("safe".utf8), filename: input, mimeType: "text/plain") }
        let file = try #require(model.file)
        #expect(file.filename == expected)
        #expect(file.url.deletingLastPathComponent().lastPathComponent.hasPrefix("botto-artifact-"))
        #expect(try Data(contentsOf: file.url) == Data("safe".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        model.cancel()
    }

    @Test func emptyAndLongUnicodeNamedFilesRemainExportable() async throws {
        let model = ArtifactPreviewModel()
        await model.load { DownloadedArtifact(data: Data(), filename: String(repeating: "🌱", count: 100) + ".txt", mimeType: "text/plain") }
        let file = try #require(model.file)
        #expect(file.filename.utf8.count <= 200)
        #expect(file.url.pathExtension == "txt")
        #expect(file.data.isEmpty)
        #expect(try Data(contentsOf: file.url).isEmpty)
        #expect(model.errorMessage == nil)
        model.cancel()
    }

    @Test func combiningMarkExtensionRemainsExportable() async throws {
        let model = ArtifactPreviewModel()
        let bytes = Data([0, 255, 128, 10, 13, 0])
        let filename = "a.e" + String(repeating: "\u{0301}", count: 100)
        #expect(filename.utf8.count == 203)
        await model.load { DownloadedArtifact(data: bytes, filename: filename, mimeType: "application/octet-stream") }
        let file = try #require(model.file)
        #expect(!file.filename.isEmpty)
        #expect(file.filename.utf8.count <= 200)
        #expect(file.data == bytes)
        #expect(try Data(contentsOf: file.url) == bytes)
        model.cancel()
    }

    @Test(arguments: [
        (".e" + String(repeating: "\u{0301}", count: 100), "File"),
        ("e" + String(repeating: "\u{0301}", count: 100) + ".txt", "File.txt"),
        ("report.pdf", "report.pdf"),
        ("report.abcdefghijklmnopq", "report.abcdefghijklmnop")
    ])
    func oversizedGraphemesAndNormalExtensionsKeepPrivateExportBytes(input: String, expected: String) async throws {
        let bytes = Data([0, 255, 128, 10, 13, 0])
        let model = ArtifactPreviewModel()
        await model.load { DownloadedArtifact(data: bytes, filename: input, mimeType: "application/octet-stream") }
        let file = try #require(model.file)
        #expect(file.filename == expected)
        #expect(file.filename.utf8.count <= 200)
        #expect(file.url.deletingLastPathComponent().lastPathComponent.hasPrefix("botto-artifact-"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        #expect(file.data == bytes)
        #expect(try Data(contentsOf: file.url) == bytes)
        model.cancel()
    }

    @Test func newerPreviewWinsOverIgnoredCancellationFromEarlierLoad() async throws {
        let model = ArtifactPreviewModel()
        let gate = ArtifactGate()
        let old = Task {
            await model.load {
                await gate.wait()
                return DownloadedArtifact(data: Data("old".utf8), filename: "old.txt", mimeType: "text/plain")
            }
        }
        await gate.entered()
        await model.load { DownloadedArtifact(data: Data("new".utf8), filename: "new.txt", mimeType: "text/plain") }
        gate.release()
        await old.value
        #expect(model.file?.filename == "new.txt")
        #expect(model.file?.data == Data("new".utf8))
        #expect(!model.isLoading)
        model.cancel()
    }

    @Test func callerCancellationCancelsServiceReadWithoutRetiringChat() async throws {
        let service = ArtifactService()
        let store = AppStore(service: service, persistence: ArtifactStorage().persistence)
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://artifact.example")!)
        defer { store.forgetConnection(); LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        await store.open(service.profiles[0])
        let destination = try #require(store.artifactDestination(for: .init(name: "report.txt", path: "/report.txt"), botID: "canvas"))
        let gate = ArtifactGate()
        service.gate = gate
        let loading = Task { try await store.downloadArtifact(destination) }
        await gate.entered()
        loading.cancel()
        // The cancellation handler synchronously cancels the service task.
        gate.release()
        await #expect(throws: CancellationError.self) { _ = try await loading.value }
        #expect(service.downloadWasCancelled)
        #expect(store.isCurrentArtifactDestination(destination))
    }

    @Test func dismissalCancelsDownloadAndRejectsLateBytes() async throws {
        let gate = ArtifactGate()
        let model = ArtifactPreviewModel()
        var cancelled = false
        let loading = Task {
            await model.load {
                await gate.wait()
                cancelled = Task.isCancelled
                return DownloadedArtifact(data: Data("late".utf8), filename: "late.txt", mimeType: "text/plain")
            }
        }
        await gate.entered()
        model.cancel()
        gate.release()
        await loading.value
        #expect(cancelled)
        #expect(model.file == nil)
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
    }
}

@MainActor private final class ArtifactGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func entered() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class ArtifactStorage {
    var value: ConnectionConfiguration?
    var persistence: ConnectionPersistence {
        ConnectionPersistence(load: { self.value }, save: { self.value = $0 }, remove: { self.value = nil })
    }
}

@MainActor private final class ArtifactService: BotService {
    let authority = TestConversationAuthority()

    func conversations(profile: ExactID) async throws -> ConversationDirectory { authority.directory(profile) }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw HermesServiceError.rejected(-32601) }

    var onEvent: ((BotServiceEvent) -> Void)?
    let profiles = [BotProfile(id: "canvas", name: "Canvas"), BotProfile(id: "other", name: "Other")]
    var downloads: [(ChatAttachment, Conversation)] = []
    var gate: ArtifactGate?
    var downloadWasCancelled = false
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo { ServerInfo(version: "test") }
    func disconnect() {}
    func bots() async throws -> [BotProfile] { profiles }
    func createBot(_ draft: BotDraft) async throws -> BotProfile { profiles[0] }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let bot = BotProfile(id: authority.profile(target), name: "Fixture")
        return try authority.opened(Conversation(id: "runtime-" + bot.id, storedID: "stored-" + bot.id, profileID: bot.id))
    }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        throw HermesServiceError.invalidAttachment
    }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        downloads.append((attachment, try authority.resolve(access)))
        if let gate { await gate.wait() }
        downloadWasCancelled = Task.isCancelled
        return DownloadedArtifact(data: Data("origin bytes".utf8), filename: attachment.name, mimeType: attachment.mimeType)
    }
}
