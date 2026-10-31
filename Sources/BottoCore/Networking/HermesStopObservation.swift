import Foundation

/// Evidence for one deliberate Stop survives its automatic canonical refresh.
/// Only the socket boundary can supply a terminal; fetched replay cannot.
struct HermesStopObservation {
    let operation: UUID
    let connection: Int
    let selection: Int
    let identity: SessionIdentity
    let runtime: String
    let epoch: String
    let profileIdentity: String?
    let generation: Int?
    let admission: String?
    let sequenceBeforeDispatch: Int
    var terminalSequence: Int?

    mutating func observe(_ frame: HermesJSON, authority: Bool) -> Bool {
        guard exact(frame["session_id"].text, runtime),
              frame["profile_name"].text.map({ exact($0, identity.profile.text) }) != false,
              frame["profile_id"].text.map({ exact($0, profileIdentity) }) != false,
              !authority || exact(frame["replay_epoch"].text, epoch),
              let sequence = frame["seq"].integer, sequence > sequenceBeforeDispatch else { return true }
        let type = frame["type"].text
        let incomingGeneration = frame["execution_generation"].integer ?? frame["payload"]["execution_generation"].integer
        if authority, let generation, let incomingGeneration, incomingGeneration < generation { return true }
        if type == "message.start" {
            if authority, incomingGeneration == nil { return true }
            return false
        }
        if authority, type == "session.info", let incomingGeneration, incomingGeneration != generation { return false }
        guard type == "message.complete" else { return true }
        if authority {
            guard incomingGeneration != nil, incomingGeneration == generation,
                  let incomingAdmission = frame["admission_id"].nonempty,
                  admission.map({ exact($0, incomingAdmission) }) != false else { return true }
        }
        guard Self.isStoppedOutcome(frame["payload"]) else { return false }
        terminalSequence = sequence
        return true
    }

    static func isStoppedOutcome(_ payload: HermesJSON) -> Bool {
        let status = payload["status"].text, outcome = payload["outcome"].text
        let stopped = ["interrupted", "cancelled"]
        return (stopped.contains(status ?? "") && (outcome == nil || stopped.contains(outcome ?? "")))
            || (status == "complete" && stopped.contains(outcome ?? ""))
    }
}

extension HermesBotService {
    func observeStop(_ frame: HermesJSON) {
        guard var stop = pendingStopObservation else { return }
        guard stop.connection == connectionGeneration, stop.selection == selectionGeneration,
              stop.observe(frame, authority: adapter == .authority) else {
            pendingStopObservation = nil
            return
        }
        pendingStopObservation = stop
    }

    func projectStoppedOutcome() {
        guard let stop = pendingStopObservation else { return }
        guard stop.connection == connectionGeneration, stop.selection == selectionGeneration,
              let target = selectedTarget, sameInventoryTip(stop.identity, target),
              let current = state, exact(current.conversation.id, stop.runtime), exact(current.epoch, stop.epoch),
              exact(current.conversation.profileID, stop.identity.profile.text),
              adapter != .authority || (current.generation == stop.generation && exact(current.profileIdentity, stop.profileIdentity)) else {
            pendingStopObservation = nil
            return
        }
        guard let sequence = stop.terminalSequence, current.conversation.lastSequence >= sequence,
              !current.conversation.isWorking else { return }
        state?.motion.signal = .init(id: stop.operation, kind: .stopped)
        pendingStopObservation = nil
    }
}
