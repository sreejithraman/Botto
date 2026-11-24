import Foundation
import Testing
@testable import BottoCore

actor T3TestSocket: T3WebSocketTransport {
    nonisolated let incoming: AsyncThrowingStream<Data, Error>.Continuation
    nonisolated let sent: AsyncStream<HermesJSON>
    private let outgoing: AsyncStream<HermesJSON>.Continuation
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator
    private let stalledTag: String?
    private var stalledWrites: [CheckedContinuation<Void, Error>] = []
    private(set) var isClosed = false

    init(stalledTag: String? = nil) {
        self.stalledTag = stalledTag
        let messages = AsyncThrowingStream<Data, Error>.makeStream()
        incoming = messages.continuation
        iterator = messages.stream.makeAsyncIterator()
        let frames = AsyncStream<HermesJSON>.makeStream()
        sent = frames.stream
        outgoing = frames.continuation
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw T3RPCError.closed }
        let frame = try JSONDecoder().decode(HermesJSON.self, from: data)
        outgoing.yield(frame)
        if let stalledTag, frame["_tag"].text == stalledTag {
            try await withCheckedThrowingContinuation { stalledWrites.append($0) }
        }
    }

    func receive() async throws -> Data {
        var reader = iterator
        guard let data = try await reader.next(isolation: self) else { throw T3RPCError.closed }
        iterator = reader
        return data
    }

    func close() {
        isClosed = true
        for write in stalledWrites { write.resume(throwing: T3RPCError.closed) }
        stalledWrites.removeAll()
        incoming.finish()
        outgoing.finish()
    }

    nonisolated func push(_ json: String) { incoming.yield(Data(json.utf8)) }
}

@Suite(.timeLimit(.minutes(1))) struct T3RPCClientTests {
    @Test(arguments: ["Request", "Ping"]) func stalledSocketWriteClosesAtItsDeadline(_ stalledTag: String) async throws {
        let socket = T3TestSocket(stalledTag: stalledTag)
        let client = T3RPCClient(transport: socket,
                                 heartbeatInterval: stalledTag == "Ping" ? .milliseconds(10) : .seconds(5),
                                 pongTimeout: .milliseconds(30),
                                 requestTimeout: stalledTag == "Request" ? .milliseconds(30) : .seconds(5))
        var sent = socket.sent.makeAsyncIterator()
        let call = Task { try await client.call("server.getConfig") }
        #expect(await sent.next()?["_tag"].text == "Request")
        if stalledTag == "Ping" { #expect(await sent.next()?["_tag"].text == "Ping") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await socket.isClosed)
        await client.close()
        await #expect(throws: T3RPCError.timeout) { try await call.value }
    }

    @Test func requestsReturnValuesAndTypedFailures() async throws {
        let socket = T3TestSocket()
        let client = T3RPCClient(transport: socket)
        var sent = socket.sent.makeAsyncIterator()
        let result = Task { try await client.call("server.getConfig") }
        let request = try #require(await sent.next())
        #expect(request["_tag"].text == "Request")
        #expect(request["tag"].text == "server.getConfig")
        #expect(request["headers"].list == [])
        let id = try #require(request["id"].text)
        socket.push("""
        {"_tag":"Exit","requestId":"\(id)","exit":{"_tag":"Success","value":{"cwd":"/home/host"}}}
        """)
        #expect(try await result.value["cwd"].text == "/home/host")

        let rejected = Task { try await client.call("projects.readFile") }
        let failureID = try #require(await sent.next()?["id"].text)
        socket.push("""
        {"_tag":"Exit","requestId":"\(failureID)","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"ProjectReadFileError","message":"Missing"}}]}}
        """)
        await #expect(throws: T3RPCError.remote(tag: "ProjectReadFileError", message: "Missing")) {
            try await rejected.value
        }
        await client.close()
    }

    @Test func chunksAcknowledgeOnceAndCancellationInterrupts() async throws {
        let socket = T3TestSocket()
        let client = T3RPCClient(transport: socket)
        var sent = socket.sent.makeAsyncIterator()
        let values = AsyncStream<HermesJSON>.makeStream()
        var received = values.stream.makeAsyncIterator()
        let consumer = Task {
            let stream = try await client.subscribe("orchestration.subscribeShell")
            for try await value in stream { values.continuation.yield(value) }
        }
        let id = try #require(await sent.next()?["id"].text)
        socket.push("""
        {"_tag":"Chunk","requestId":"\(id)","values":["a","b"]}
        """)
        #expect(await received.next()?.text == "a")
        #expect(await received.next()?.text == "b")
        let ack = try #require(await sent.next())
        #expect(ack["_tag"].text == "Ack")
        #expect(ack["requestId"].text == id)
        consumer.cancel()
        _ = await consumer.result
        let interrupt = try #require(await sent.next())
        #expect(interrupt["_tag"].text == "Interrupt")
        #expect(interrupt["requestId"].text == id)
        await client.close()
    }

    @Test func heartbeatTimesOutWithoutPongAndBearerFallbackUsesAHeader() async throws {
        let origin = try #require(URL(string: "http://host.example:9000"))
        let request = try T3RPCClient.socketRequest(origin: origin, ticket: nil, accessToken: "token")
        #expect(request.url?.absoluteString == "ws://host.example:9000/ws?orchestrationProtocol=2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")

        let socket = T3TestSocket()
        let client = T3RPCClient(transport: socket, heartbeatInterval: .milliseconds(10), pongTimeout: .milliseconds(15))
        var sent = socket.sent.makeAsyncIterator()
        let requestTask = Task { try await client.call("server.getConfig") }
        #expect(await sent.next()?["_tag"].text == "Request")
        #expect(await sent.next()?["_tag"].text == "Ping")
        await #expect(throws: T3RPCError.timeout) { try await requestTask.value }
    }

    @Test func pingsAreAnsweredAndDefectsFailOutstandingRequests() async throws {
        let socket = T3TestSocket()
        let client = T3RPCClient(transport: socket)
        var sent = socket.sent.makeAsyncIterator()
        let waiting = Task { try await client.call("server.getConfig") }
        _ = await sent.next()
        socket.push(#"{"_tag":"Ping"}"#)
        #expect(await sent.next()?["_tag"].text == "Pong")
        socket.push(#"{"_tag":"Defect","defect":{"message":"broken"}}"#)
        await #expect(throws: T3RPCError.defect("broken")) { try await waiting.value }
    }
}
