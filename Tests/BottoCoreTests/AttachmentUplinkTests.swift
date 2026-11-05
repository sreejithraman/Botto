import Foundation
import Testing
@testable import BottoCore

/// URLSession finishes `send` once the frame is buffered and reports no byte
/// progress, so a slow uplink shows up only as a reply that arrives late.
/// Requests sent after the frame wait behind it on the same socket.
@MainActor private final class SlowUplink {
    private let host: HermesTestHost
    private var held: [(HermesJSON, ScriptedSocket)] = []
    private(set) var frameArrived = false

    init(_ host: HermesTestHost) {
        self.host = host
        host.methodOverride = { [self] frame, socket in
            guard !frameArrived else { return host.defaultReply(frame, socket: socket) }
            held.append((frame, socket))
            return nil
        }
    }
    private static func isAttachment(_ frame: HermesJSON) -> Bool { ["file.attach", "image.attach_bytes"].contains(frame["method"].text) }
    var holdsAttachment: Bool { held.contains { Self.isAttachment($0.0) } }
    var heldAttachments: Int { held.count { Self.isAttachment($0.0) } }
    var holdsOrdinaryRequest: Bool { held.contains { !Self.isAttachment($0.0) } }

    func deliver() {
        frameArrived = true
        release { _ in true }
    }

    /// Answers the oldest held attachment; everything else keeps waiting.
    func deliverOldestAttachment() {
        guard let oldest = held.first(where: { Self.isAttachment($0.0) }) else { return }
        release { $0["id"].integer == oldest.0["id"].integer }
    }

    func deliverOrdinaryRequests() {
        release { !Self.isAttachment($0) }
    }

    private func release(where matches: (HermesJSON) -> Bool) {
        for (frame, socket) in held where matches(frame) && !socket.closed {
            guard let result = host.defaultReply(frame, socket: socket) else { continue }
            socket.push(.object(["jsonrpc": .string("2.0"), "id": frame["id"], "result": result]))
        }
        held.removeAll { matches($0.0) }
    }
}

@MainActor private func openChat(_ host: HermesTestHost, _ service: HermesBotService) async throws -> OpenedConversation {
    _ = try await service.connect(configuration: host.configuration)
    return try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
}

@MainActor @Test(arguments: [true, false])
func aSlowAttachmentFrameOutlivesTheRequestAndSilenceTimers(image: Bool) async throws {
    let host = try HermesTestHost()
    let service = host.service(requestTimeout: .milliseconds(300), heartbeat: .milliseconds(50), silence: .milliseconds(300),
                               attachmentUplink: 20)
    defer { service.disconnect() }
    let chat = try await openChat(host, service)
    let socket = try #require(host.sockets.last)
    let uplink = SlowUplink(host)

    let upload = Task {
        try await service.upload(data: image ? attachmentPNG : Data("hello".utf8), filename: image ? "pixel.png" : "notes.txt",
                                 mimeType: image ? "image/png" : "text/plain", access: chat.access)
    }
    try await Task.sleep(for: .milliseconds(900))
    #expect(uplink.holdsAttachment)
    uplink.deliver()

    #expect(try await upload.value.stagingID != nil)
    #expect(host.sockets.count == 1, "The chat's connection and earlier staged files must survive")
    #expect(!socket.closed)
}

@MainActor @Test func otherRequestsWaitForTheAttachmentFrameAheadOfThem() async throws {
    let host = try HermesTestHost()
    let service = host.service(requestTimeout: .milliseconds(300), attachmentUplink: 20)
    defer { service.disconnect() }
    let chat = try await openChat(host, service)
    let socket = try #require(host.sockets.last)
    let uplink = SlowUplink(host)

    let upload = Task {
        try await service.upload(data: Data("hello".utf8), filename: "notes.txt", mimeType: "text/plain", access: chat.access)
    }
    try await eventually { uplink.holdsAttachment }
    let directory = Task { try await service.conversations(profile: ExactID(host.bot.id)) }
    try await Task.sleep(for: .milliseconds(900))
    uplink.deliver()

    _ = try await upload.value
    _ = try await directory.value
    #expect(host.sockets.count == 1 && !socket.closed)
}

@MainActor @Test func theDeadlineGrowsWithTheFrameSoASmallStalledFrameFailsQuickly() async throws {
    let host = try HermesTestHost()
    let service = host.service(requestTimeout: .milliseconds(300), attachmentUplink: 4_000)
    defer { service.disconnect() }
    let chat = try await openChat(host, service)
    let socket = try #require(host.sockets.last)
    _ = SlowUplink(host)
    let started = ContinuousClock.now

    await #expect(throws: (any Error).self) {
        _ = try await service.upload(data: Data("hello".utf8), filename: "notes.txt", mimeType: "text/plain", access: chat.access)
    }

    #expect(socket.closed)
    #expect(started.duration(to: .now) < .seconds(5), "A stalled small frame must not wait for the largest frame's allowance")
}

@MainActor @Test func aLargeFrameEarnsMoreTimeThanASmallOne() async throws {
    let host = try HermesTestHost()
    let service = host.service(requestTimeout: .milliseconds(300), attachmentUplink: 1_000)
    defer { service.disconnect() }
    let chat = try await openChat(host, service)
    let uplink = SlowUplink(host)

    // About 5.5 KiB of base64 at 1 KB/s: an allowance a small frame would not get.
    let upload = Task {
        try await service.upload(data: Data(repeating: 7, count: 4_096), filename: "notes.txt", mimeType: "text/plain", access: chat.access)
    }
    try await Task.sleep(for: .milliseconds(900))
    #expect(uplink.holdsAttachment)
    uplink.deliver()
    #expect(try await upload.value.stagingID != nil)
}

/// `service(attachmentUplink:)` of 20 B/s gives a test frame an allowance of a minute or more,
/// so these frames can only finish through what each test delivers.
@MainActor private func upload(_ name: String, _ service: HermesBotService, _ chat: OpenedConversation) -> Task<ChatAttachment, Error> {
    Task { try await service.upload(data: Data(name.utf8), filename: name, mimeType: "text/plain", access: chat.access) }
}

@MainActor @Test func anOrdinaryRequestGetsItsWholeWindowAfterTheAttachmentAheadFinishes() async throws {
    let host = try HermesTestHost()
    let service = host.service(requestTimeout: .seconds(1), attachmentUplink: 20)
    defer { service.disconnect() }
    let chat = try await openChat(host, service)
    let socket = try #require(host.sockets.last)
    let uplink = SlowUplink(host)

    let attachment = upload("notes.txt", service, chat)
    try await eventually { uplink.holdsAttachment }
    let directory = Task { try await service.conversations(profile: ExactID(host.bot.id)) }
    try await eventually { uplink.holdsOrdinaryRequest }
    // The attachment ends between whole multiples of the request timer, and the reply
    // comes later than the next multiple but inside one full window from that moment.
    try await Task.sleep(for: .milliseconds(1_500))
    uplink.deliverOldestAttachment()
    _ = try await attachment.value
    try await Task.sleep(for: .milliseconds(800))
    #expect(!socket.closed, "The reply is still within its window")
    uplink.deliverOrdinaryRequests()

    _ = try await directory.value
    #expect(host.sockets.count == 1 && !socket.closed)
}

@MainActor @Test func aQueuedAttachmentWaitsForTheFrameAheadWithoutSpendingItsOwnDeadline() async throws {
    let host = try HermesTestHost()
    // At 1 KB/s the large frame earns over 20 seconds and the small one under a second.
    let service = host.service(requestTimeout: .milliseconds(300), attachmentUplink: 1_000)
    defer { service.disconnect() }
    let chat = try await openChat(host, service)
    let socket = try #require(host.sockets.last)
    let uplink = SlowUplink(host)

    let large = Task {
        try await service.upload(data: Data(repeating: 7, count: 16 * 1_024), filename: "large.bin",
                                 mimeType: "application/octet-stream", access: chat.access)
    }
    try await eventually { uplink.heldAttachments == 1 }
    let small = upload("small.txt", service, chat)
    try await eventually { uplink.heldAttachments == 2 }

    try await Task.sleep(for: .seconds(2))
    #expect(!socket.closed, "The small frame's allowance has passed, but the large frame still holds the socket")
    uplink.deliverOldestAttachment()
    _ = try await large.value
    uplink.deliver()

    #expect(try await small.value.stagingID != nil)
    #expect(host.sockets.count == 1 && !socket.closed)
}

@MainActor @Test func aQueuedAttachmentStillTimesOutAfterTheFrameAheadFinishes() async throws {
    let host = try HermesTestHost()
    let service = host.service(requestTimeout: .milliseconds(200), attachmentUplink: 4_000)
    defer { service.disconnect() }
    let chat = try await openChat(host, service)
    let socket = try #require(host.sockets.last)
    let uplink = SlowUplink(host)

    let first = upload("first.txt", service, chat)
    try await eventually { uplink.heldAttachments == 1 }
    let second = upload("second.txt", service, chat)
    try await eventually { uplink.heldAttachments == 2 }
    uplink.deliverOldestAttachment()
    _ = try await first.value
    let finished = ContinuousClock.now

    await #expect(throws: (any Error).self) { _ = try await second.value }
    #expect(socket.closed)
    #expect(finished.duration(to: .now) < .seconds(5), "Silence after the frame ahead must still end within this frame's allowance")
}

@MainActor @Test func laterAttachmentsDoNotExtendARequestSentBeforeThem() async throws {
    let host = try HermesTestHost()
    let service = host.service(requestTimeout: .milliseconds(300), attachmentUplink: 20)
    defer { service.disconnect() }
    let chat = try await openChat(host, service)
    let socket = try #require(host.sockets.last)
    let uplink = SlowUplink(host)
    let started = ContinuousClock.now

    let directory = Task { try await service.conversations(profile: ExactID(host.bot.id)) }
    try await eventually { uplink.holdsOrdinaryRequest }
    let attachment = upload("notes.txt", service, chat)
    try await eventually { uplink.holdsAttachment }

    await #expect(throws: (any Error).self) { _ = try await directory.value }
    _ = await attachment.result
    #expect(socket.closed)
    #expect(started.duration(to: .now) < .seconds(5), "A stalled earlier request must not borrow the later frame's minute-long allowance")
}
