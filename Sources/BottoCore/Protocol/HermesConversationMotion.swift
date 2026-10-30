import Foundation

struct HermesConversationMotion {
    var lineage = UUID()
    var canRetain = true
    var phase: ConversationWorkPhase?
    var workStartedAt: Date?
    var phaseStartedAt: Date?
    var reaction: TurnReaction?
    private var claim: (generation: Int?, admission: String?)?
    private var tools: Set<ExactID> = []
    private var generation: Int?

    var activity: ConversationActivity {
        ConversationActivity(lineage: lineage, phase: phase, workStartedAt: workStartedAt,
                             phaseStartedAt: phaseStartedAt, reaction: reaction)
    }

    mutating func restore(working: Bool, generation: Int?, replying: Bool) {
        self.generation = generation
        setPhase(working ? (replying ? .replying : .working) : nil)
    }

    mutating func retainClock(from prior: Self) {
        guard prior.canRetain else { return }
        lineage = prior.lineage
        if phase != nil, prior.phase != nil {
            workStartedAt = prior.workStartedAt
            if phase == prior.phase { phaseStartedAt = prior.phaseStartedAt }
        }
    }

    func acceptsTranscript(_ event: HermesJSON, authority: Bool) -> Bool {
        guard authority else { return true }
        let type = event["type"].text
        let incoming = event["execution_generation"].integer ??
            (type == "session.info" ? event["payload"]["execution_generation"].integer : nil)
        if let incoming, let generation, incoming < generation { return false }
        if type == "session.info", let incoming = event["payload"]["execution_generation"].integer,
           let generation, incoming < generation { return false }
        if type == "message.complete", let incoming {
            if let generation, incoming != generation { return false }
            if let claim, let admission = event["admission_id"].nonempty,
               !exact(claim.admission, admission) { return false }
        }
        return true
    }

    mutating func reduce(_ event: HermesJSON, authority: Bool, live: Bool) {
        reaction = nil
        let type = event["type"].text, payload = event["payload"]
        let incomingGeneration = event["execution_generation"].integer
        let admission = event["admission_id"].nonempty
        if authority {
            if type == "message.start" {
                guard let incomingGeneration, generation.map({ incomingGeneration >= $0 }) != false else { return }
            } else if type != "session.info" {
                guard incomingGeneration == generation else { return }
            }
        }
        switch type {
        case "message.start":
            generation = incomingGeneration
            claim = live && (!authority || admission != nil) ? (incomingGeneration, admission) : nil
            tools = []; setPhase(.working)
        case "thinking.delta", "reasoning.delta":
            guard phase != nil else { return }
            setPhase(tools.isEmpty ? (payload["text"].nonempty == nil ? .working : .thinking) : .tools)
        case "reasoning.available":
            if phase == .thinking { setPhase(tools.isEmpty ? .working : .tools) }
        case "tool.generating":
            if phase != nil { setPhase(.tools) }
        case "tool.start":
            guard phase != nil else { return }
            if let text = payload["tool_id"].nonempty, let id = try? ExactID(text) { tools.insert(id) }
            setPhase(.tools)
        case "tool.complete":
            if let text = payload["tool_id"].nonempty, let id = try? ExactID(text) { tools.remove(id) }
            if phase != nil { setPhase(tools.isEmpty ? .working : .tools) }
        case "message.delta":
            if phase != nil { setPhase(tools.isEmpty ? (payload["text"].nonempty == nil ? .working : .replying) : .tools) }
        case "message.interim":
            if phase != nil { setPhase(tools.isEmpty ? .working : .tools) }
        case "message.complete":
            if authority, incomingGeneration == nil { return }
            if let claim, authority, (claim.generation != incomingGeneration || !exact(claim.admission, admission)) { return }
            let matched = claim != nil
            claim = nil; tools = []; setPhase(nil)
            guard live, matched else { return }
            let status = payload["status"].text, outcome = payload["outcome"].text
            if status == "complete", outcome == nil || outcome == "completed" {
                reaction = TurnReaction(kind: .succeeded, occurredAt: .now)
            } else if status == "error", outcome == nil || outcome == "failed" || outcome == "error" {
                reaction = TurnReaction(kind: .failed, occurredAt: .now)
            }
        case "session.info":
            if authority, let next = payload["execution_generation"].integer ?? incomingGeneration {
                guard generation.map({ next >= $0 }) != false else { return }
                if next != generation { claim = nil; tools = [] }
                generation = next
            }
            if let running = payload["running"].flag {
                if !running { claim = nil; tools = []; setPhase(nil) }
                else if phase == nil { setPhase(.working) }
            }
        default: break
        }
    }

    private mutating func setPhase(_ next: ConversationWorkPhase?) {
        guard next != phase else { return }
        if next != nil, phase == nil { workStartedAt = .now }
        phase = next; phaseStartedAt = next == nil ? nil : .now
        if next == nil { workStartedAt = nil }
    }
}
