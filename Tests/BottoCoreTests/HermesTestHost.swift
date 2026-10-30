import Foundation
import Testing
@testable import BottoCore

@MainActor final class ScriptedSocket: HermesSocket {
    var sent: [HermesJSON] = []
    var handler: ((HermesJSON) throws -> HermesJSON?)?
    var queue: [Data] = []
    var waiter: CheckedContinuation<Data, Error>?
    var closed = false
    func receive() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw HermesServiceError.disconnected }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func send(_ data: Data) async throws {
        let frame = try HermesJSON.decode(data)
        sent.append(frame)
        if let result = try handler?(frame) { push(.object(["jsonrpc": .string("2.0"), "id": frame["id"], "result": result])) }
    }
    func push(_ frame: HermesJSON) {
        let data = try! frame.data
        if let waiter { self.waiter = nil; waiter.resume(returning: data) }
        else { queue.append(data) }
    }
    func reject(_ frame: HermesJSON, code: Int) {
        push(.object(["jsonrpc": .string("2.0"), "id": frame["id"], "error": .object(["code": .number(Double(code)), "message": .string("sensitive host body")])]))
    }
    func close() {
        closed = true; let waiter = waiter; self.waiter = nil; waiter?.resume(throwing: HermesServiceError.disconnected)
    }
}

@MainActor final class HermesTestHost {
    let transport = ScriptedTransport()
    var sockets: [ScriptedSocket] = []
    var upgrades: [URLRequest] = []
    var authority: Bool
    var snapshot: HermesJSON
    var replay: HermesJSON
    var profiles: HermesJSON
    var root = "stored-1"
    var storedRows: [HermesJSON] = []
    var runtime: String { snapshot["session_id"].text! }
    var methodOverride: ((HermesJSON, ScriptedSocket) throws -> HermesJSON?)?
    var admission = "admission-1"

    init(authority: Bool = true) throws {
        self.authority = authority
        if authority {
            snapshot = try contractFixture("authority-snapshot")
            profiles = .object(["install_id": .string("fixture-install"), "profiles": .array([
                .object(["name": .string("inbox-triage"), "display_name": .string("Inbox triage")])])])
        } else {
            snapshot = try fixture("session-resume"); snapshot["messages"] = .array([])
            profiles = try fixture("profiles-list"); root = snapshot["session_key"].text!
        }
        replay = .object(["events": .array([]), "latest_seq": .number(0), "last_sequence": .number(0),
            "epoch": .string(authority ? "session-epoch" : "gateway-epoch"),
            "replay_epoch": .string("session-epoch"), "truncated": .bool(false), "snapshot_required": .bool(false), "open_requests": .array([])])
        transport.handler = { [weak self] request in
            guard let self else { throw HermesServiceError.disconnected }
            switch request.url!.path {
            case "/api/status": return try fixture("status")
            case "/api/auth/me": return .object(["provider": .string("basic"), "user_id": .string("alice")])
            case "/api/auth/ws-ticket": return .object(["ticket": .string("test-ticket")])
            case "/api/sessions":
                return .object(["sessions": .array(storedRows), "total": .number(Double(storedRows.count)),
                    "limit": .number(100), "offset": .number(0)])
            case "/api/sessions/\(root)/messages":
                let profile = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profile" }?.value
                return .object(["session_id": .string(root), "profile": .string(profile ?? bot.id), "messages": snapshot["messages"]])
            default: return .object(["ok": .bool(true)])
            }
        }
        transport.makeSocket = { [weak self] request in
            guard let self else { throw HermesServiceError.disconnected }
            upgrades.append(request)
            let socket = ScriptedSocket(); sockets.append(socket)
            socket.handler = { [weak self, weak socket] frame in
                guard let self, let socket else { throw HermesServiceError.disconnected }
                if let methodOverride { return try methodOverride(frame, socket) }
                return defaultReply(frame, socket: socket)
            }
            socket.push(.object(["jsonrpc": .string("2.0"), "method": .string("event"), "params": .object([
                "type": .string("gateway.ready"), "payload": .object(["replay_epoch": .string("gateway-epoch"), "session_authority": .bool(authority)])])]))
            return socket
        }
    }
    func defaultReply(_ frame: HermesJSON, socket: ScriptedSocket) -> HermesJSON? {
        switch frame["method"].text {
        case "client.capabilities", "gateway.ping": return .object(["ok": .bool(true)])
        case "runtime.describe": return .object(["capabilities": .array([.string("durable-admission-v1"), .string("event-replay-v1")]),
            "session_create": .object(["sources": .array([.string("gui")])])])
        case "profiles.list": return profiles
        case "session.active_list": return .object(["sessions": .array([])])
        case "session.list": return .object(["sessions": .array([.object(["id": .string(root), "resolved_id": .string(root)])])])
        case "session.resume": return snapshot
        case "session.events.since": return replay
        case "prompt.submit":
            return authority ? .object(["admission_id": .string(admission), "ref": .object(["session_id": .string(runtime), "profile_id": .string("/profiles/inbox-triage")]),
                "sequence": .number(1), "status": .string("started"), "execution_generation": .number(7), "authority_epoch": .number(2)])
                : .object(["status": .string("streaming")])
        case "session.interrupt": return authority ? .object(["ref": .object(["session_id": .string(runtime)]), "execution_generation": .number(7)])
                : .object(["status": .string("interrupted")])
        case "approval.respond", "clarify.respond": return authority
                ? .object(["status": .string("resolved"), "prompt_id": frame["params"]["prompt_id"]]) : .object(["resolved": .number(1)])
        case "clarify.lock", "request.answer": return .object(["status": .string("ok"), "remaining": .array([])])
        case "file.attach": return .object(["attached": .bool(true), "path": .string("/host/file.txt"), "ref_text": .string("@file:/host/file.txt")])
        case "image.attach_bytes": return .object(["attached": .bool(true), "path": .string("/host/cache/images/pic.png"), "mime": .string("image/png")])
        default: socket.reject(frame, code: -32601); return nil
        }
    }
    func service(requestTimeout: Duration = .seconds(1)) -> HermesBotService {
        HermesBotService(transportFactory: { [transport] in transport },
            timing: .init(request: requestTimeout, heartbeat: .seconds(10), silence: .seconds(30), reconnectDelays: [.milliseconds(10)]),
            journal: HermesSubmissionJournal(directory: nil))
    }
    var configuration: ConnectionConfiguration {
        ConnectionConfiguration(serverURL: URL(string: "https://hermes.example")!, username: "alice", password: "test-password", installID: "fixture-install")
    }
    var bot: BotProfile { BotProfile(id: "inbox-triage", name: "Inbox triage") }
    func event(_ type: String, seq: Int, payload: [String: HermesJSON] = [:], session: String? = nil) -> HermesJSON {
        var frame: [String: HermesJSON] = ["type": .string(type), "seq": .number(Double(seq)),
            "session_id": .string(session ?? runtime), "payload": .object(payload)]
        if authority { frame["replay_epoch"] = .string("session-epoch"); frame["execution_generation"] = .number(7) }
        return .object(["jsonrpc": .string("2.0"), "method": .string("event"), "params": .object(frame)])
    }
}

func contractFixture(_ name: String) throws -> HermesJSON {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/AuthorityContract")!
    return try HermesJSON.decode(Data(contentsOf: url))
}

@MainActor func eventually(_ predicate: () -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
    #expect(predicate())
}

func isFullDirectoryRead(_ request: URLRequest) -> Bool {
    guard let url = request.url, url.path == "/api/sessions" else { return false }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .contains { $0.name == "limit" && $0.value == "100" } == true
}

extension BotServiceEvent {
    var activityUpdates: [ProfileActivityUpdate] {
        switch self {
        case .activity(let profile, let observations): [.init(profile: profile, observations: observations)]
        case .activityBatch(let updates): updates
        default: []
        }
    }
}
