import SwiftUI
import BottoCore

/// A display occurrence is not an action identity. Keep every ambiguous payload
/// in order, but never pass it to the renderer or manufacture a request intent.
struct NativeTranscriptMessagePlan {
    struct Entry {
        let id: NativeTranscriptItemID
        let message: ChatMessage
        let isAmbiguous: Bool
        let sourceIndex: Int
    }
    enum DisplayRow: Identifiable {
        case message(Entry)
        case workDetails([ChatMessage])

        var id: NativeTranscriptItemID {
            switch self {
            case .message(let entry): entry.id
            case .workDetails(let messages): .workDetails(Data(messages[0].id.utf8))
            }
        }
    }
    let entries: [Entry]
    var hasAmbiguity: Bool { entries.contains(where: \.isAmbiguous) }
    var displayRows: [DisplayRow] {
        var rows: [DisplayRow] = []
        var tools: [ChatMessage] = []
        var previousIndex: Int?
        func flushTools() {
            if !tools.isEmpty { rows.append(.workDetails(tools)); tools = [] }
        }
        for entry in entries {
            if entry.message.role == .tool && !entry.isAmbiguous {
                if previousIndex.map({ entry.sourceIndex != $0 + 1 }) == true { flushTools() }
                tools.append(entry.message)
            } else {
                flushTools()
                rows.append(.message(entry))
            }
            previousIndex = entry.sourceIndex
        }
        flushTools()
        return rows
    }
    init(_ messages: [ChatMessage], queuedMessages: [QueuedMessage] = []) {
        let pending = Set(queuedMessages.compactMap { $0.submissionID.map { Data(("submission:" + $0).utf8) } })
        let repeated = repeatedIdentities(messages.map { Data($0.id.utf8) })
        entries = messages.enumerated().compactMap { index, message in
            guard message.isVisible, !pending.contains(Data(message.id.utf8)) else { return nil }
            let exact = Data(message.id.utf8), ambiguous = repeated.contains(exact)
            return Entry(id: ambiguous ? .ambiguousMessage(index) : .message(exact), message: message, isAmbiguous: ambiguous, sourceIndex: index)
        }
    }
}

struct WorkDetailsView: View {
    let messages: [ChatMessage]

    var body: some View {
        WorkDetailsRow(title: "Work details", systemImage: "wrench.and.screwdriver", count: messages.count,
            accessibilityLabel: "Work details, \(messages.count) \(messages.count == 1 ? "tool" : "tools")",
            identifier: "work-details-" + (messages.first?.id ?? ""), messages: messages)
    }
}

struct NativeTranscriptRequestPlan {
    struct Entry {
        let id: NativeTranscriptItemID
        let row: RequestRow
        let isAmbiguous: Bool
    }
    let entries: [Entry]
    var hasAmbiguity: Bool { entries.contains(where: \.isAmbiguous) }
    init(_ rows: [RequestRow]) {
        let repeatedRows = repeatedIdentities(rows.map(\.id))
        let repeatedRemoteIDs = repeatedIdentities(rows.map { Data($0.request.id.utf8) })
        entries = rows.enumerated().map { index, row in
            let ambiguous = repeatedRows.contains(row.id) || repeatedRemoteIDs.contains(Data(row.request.id.utf8))
            return Entry(id: ambiguous ? .ambiguousRequest(index) : .request(row.id), row: row, isAmbiguous: ambiguous)
        }
    }
}
private func repeatedIdentities<ID: Hashable>(_ ids: [ID]) -> Set<ID> {
    var seen = Set<ID>(), repeated = Set<ID>()
    for id in ids where !seen.insert(id).inserted { repeated.insert(id) }
    return repeated
}

struct NativeTranscriptIdentityNotice: View {
    var body: some View {
        Label("Some items share an identifier. Their original text is shown without preview, file or response actions.", systemImage: "exclamationmark.bubble")
            .font(.footnote).foregroundStyle(.secondary).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
struct NativeTranscriptAmbiguousMessage: View {
    let message: ChatMessage
    var body: some View {
        if message.notificationPresentation != nil {
            MessageView(message: message)
        } else {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: message.toolName ?? message.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: message.text).textSelection(.enabled)
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                Label { Text(verbatim: attachment.name) } icon: { Image(systemName: "doc") }
                    .font(.subheadline)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
struct NativeTranscriptAmbiguousRequest: View {
    let request: PendingRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: request.title).font(.headline)
            Text(verbatim: request.detail).textSelection(.enabled)
            ForEach(Array(request.choices.enumerated()), id: \.offset) { _, choice in Text(verbatim: choice.label) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
