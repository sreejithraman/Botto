import Foundation

/// The fixed schedule, prompt and existing Space the owner can approve together.
public struct T3WorkflowRoutineProposal: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let prompt: String
    public let schedule: T3RoutineSchedule
    public let threadID: String
    let environmentID: String
    let projectID: String
}

public enum T3WorkflowRoutineError: LocalizedError, Equatable, Sendable {
    case unavailable
    case emptyPrompt
    case changed
    case updating
    case questionChanged
    case definition(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Turn on Workflows on your T3 Code host to try this Routine."
        case .emptyPrompt: "Enter what Botto should do."
        case .changed: "This Routine changed on the host. Refresh Routines and try again."
        case .updating: "This Routine is already updating."
        case .questionChanged: "That Routine question changed or has already been answered."
        case .definition(let message): message
        }
    }
}

public struct T3WorkflowRoutine: Identifiable, Equatable, Sendable {
    public let proposal: T3WorkflowRoutineProposal
    public var id: UUID { proposal.id }
    public var enabled: Bool { version.isMultiple(of: 2) == false }
    let version: Int

    var workflowName: String { "botto-routine-" + id.uuidString.lowercased() }
    var fileName: String { workflowName + ".ts" }
    var versionName: String { "\(workflowName)@\(version)" }

    // Recreate the source on read. A matching file name or comment alone does
    // not make an externally authored workflow a Botto Routine.
    init?(file: JSONValue, scope: T3PushScope) {
        guard file["name"].text?.hasPrefix("botto-routine-") == true,
              file["problems"].list?.isEmpty == true,
              let source = file["source"].text,
              let line = source.split(separator: "\n", maxSplits: 1).first,
              line.hasPrefix(Self.marker),
              let bytes = Data(base64Encoded: String(line.dropFirst(Self.marker.count))),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: bytes),
              let proposal = metadata.proposal,
              metadata.version > 0, proposal.scope == scope else { return nil }
        self.init(proposal: proposal, version: metadata.version)
        guard file["name"].text == fileName,
              file["workflows"].list?.contains(.string(versionName)) == true,
              let expected = try? definitionSource(),
              source.utf8.elementsEqual(expected.utf8) else { return nil }
    }

    init(proposal: T3WorkflowRoutineProposal, version: Int) {
        self.proposal = proposal
        self.version = version
    }

    func definitionSource() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func literal<T: Encodable>(_ value: T) throws -> String {
            try String(decoding: encoder.encode(value), as: UTF8.self)
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        let schedule = proposal.schedule
        let time = String(format: "%02d:%02d", schedule.hour, schedule.minute)
        let marker = Self.marker + (try encoder.encode(Metadata(self))).base64EncodedString()
        return """
        \(marker)
        for (let version = 1; version <= \(version); version++) {
          const enabled = version % 2 === 1;
          T3.workflow(\(try literal(workflowName)), {
            version, payload: T3.Tick, returns: Schema.String,
            triggers: enabled ? [T3.daily(\(try literal(time)), { weekdays: \(try literal(schedule.days.sorted())) })] : [],
            asks: { routine: "Routine" },
          }, () => enabled ? Effect.gen(function* () {
            const answer = yield* T3.ask("run-routine", {
              title: \(try literal("Run “\(proposal.name)” in this Space?")),
              choices: ["Run", "Skip"], kind: "routine", timeout: "24 hours",
              data: { threadId: \(try literal(proposal.threadID)) },
            });
            if (Option.isNone(answer) || answer.value.choice !== "Run") return "Skipped";
            yield* T3.agent("routine-work", {
              brief: \(try literal(proposal.prompt)),
              thread: { threadId: \(try literal(proposal.threadID)) },
            });
            return "Finished in this Space";
          }) : T3.skip("Routine paused"));
        }

        """
    }

    private static let marker = "// Botto Routine v1 "

    private struct Metadata: Codable {
        let id: UUID
        let name: String
        let prompt: String
        let threadID: String
        let environmentID: String
        let projectID: String
        let hour: Int
        let minute: Int
        let days: [Int]
        let version: Int

        init(_ routine: T3WorkflowRoutine) {
            let proposal = routine.proposal
            id = proposal.id
            name = proposal.name
            prompt = proposal.prompt
            threadID = proposal.threadID
            environmentID = proposal.environmentID
            projectID = proposal.projectID
            hour = proposal.schedule.hour
            minute = proposal.schedule.minute
            days = proposal.schedule.days.sorted()
            version = routine.version
        }

        var proposal: T3WorkflowRoutineProposal? {
            guard let schedule = T3RoutineSchedule(hour: hour, minute: minute, days: Set(days)) else { return nil }
            return .init(id: id, name: name, prompt: prompt, schedule: schedule, threadID: threadID,
                         environmentID: environmentID, projectID: projectID)
        }
    }
}

extension T3WorkflowRoutineProposal {
    var scope: T3PushScope { .init(environmentID: environmentID, projectID: projectID) }
}

public struct T3WorkflowRoutineQuestion: Equatable, Sendable {
    public let title: String
    public let choices: [String]
    let runID: String
    let name: String
    let proposal: T3WorkflowRoutineProposal
}

public struct T3WorkflowRoutineActivity: Identifiable, Equatable, Sendable {
    public let id: String
    public let routineName: String
    public let question: T3WorkflowRoutineQuestion?
    public let result: String?

    static func read(_ snapshot: JSONValue, routines: [T3WorkflowRoutine]) throws -> [Self] {
        guard let runs = snapshot["runs"].list, let questions = snapshot["questions"].list else {
            throw T3ServiceError.invalidResponse
        }
        var result: [Self] = []
        var recent: Set<UUID> = []
        for run in runs {
            guard let id = run["runId"].nonempty, let version = run["version"].integer,
                  version > 0, !version.isMultiple(of: 2),
                  let routine = routines.first(where: {
                      run["workflow"].text == $0.workflowName && version <= $0.version
                  }) else { continue }
            let question = questions.first { $0["runId"].text == id && $0["name"].text == "run-routine" }
            if let question {
                let request = question["request"]
                guard request["data"]["threadId"].text?.utf8.elementsEqual(routine.proposal.threadID.utf8) == true,
                      let title = request["title"].nonempty,
                      request["choices"].list == [.string("Run"), .string("Skip")] else { continue }
                result.append(.init(id: id, routineName: routine.proposal.name,
                                    question: .init(title: title, choices: ["Run", "Skip"], runID: id,
                                                    name: "run-routine", proposal: routine.proposal),
                                    result: nil))
            } else if !recent.contains(routine.id), let value = run["result"].nonempty {
                result.append(.init(id: id, routineName: routine.proposal.name, question: nil, result: value))
                recent.insert(routine.id)
            }
        }
        return result
    }
}
