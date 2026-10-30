import SwiftUI
import BottoCore

/// Captured request ownership lives with the transcript, never its reusable host.
struct RequestCardInput {
    let row: RequestRow
    let store: AppStore
    let workspace: ConversationWorkspace
    let owner: PresentationOwner
    let profile: ExactID

    func matches(_ other: Self) -> Bool {
        store === other.store && workspace === other.workspace && owner == other.owner && profile == other.profile && row.id == other.row.id &&
            row.request.hasSameWireRevision(as: other.row.request)
    }
}

@MainActor @Observable final class RequestCardLifetime {
    let input: RequestCardInput
    private var valid = true
    private(set) var busy = false
    let modalID = UUID()
    private struct PendingConfirmation {
        let id: UUID
        let choice: RequestChoice
        let intent: RequestIntent
    }
    private var pendingConfirmation: PendingConfirmation?
    init(_ input: RequestCardInput) { self.input = input }

    private var currentRow: RequestRow? {
        guard valid else { return nil }
        return input.workspace.currentRequestRow(matching: input.row, owner: input.owner)
    }
    var isCurrent: Bool { currentRow != nil }
    var canAct: Bool { isCurrent && !busy && input.workspace.screen(profile: input.profile)?.canAct == true }
    var canEditDraft: Bool { isCurrent && !busy && input.workspace.screen(profile: input.profile)?.canEditDraft == true }
    var canAttempt: Bool { canAct || (!input.store.isConnected && canEditDraft) }
    // The workspace owns draft persistence, including offline/recovery handoff.
    // This lifetime only fences an editor against its captured unique row.
    var response: String {
        guard isCurrent else { return "" }
        return input.workspace.requestDraft(input.row, owner: input.owner)
    }
    var responseBinding: Binding<String> {
        Binding(get: { self.response }, set: { value in
            guard self.canEditDraft, self.input.row.request.kind == .question else { return }
            self.input.workspace.editRequestDraft(value, row: self.input.row, owner: self.input.owner)
        })
    }
    func invalidate() { valid = false; pendingConfirmation = nil }
    func actions(admittedBy admission: @escaping @MainActor () -> Bool) -> RequestCardActions {
        // Capture the operation at render time. Validation failures renew the
        // current row's intent without retiring its semantic lifetime.
        RequestCardActions(lifetime: self, intent: currentRow?.intent, admission: admission)
    }
    fileprivate func send(_ value: RequestResponse, intent: RequestIntent) {
        guard canAct, input.store.isConnected else { return }
        busy = true
        let workspace = input.workspace
        Task {
            await workspace.answer(intent, response: value)
            self.busy = false
        }
    }
    fileprivate func beginConfirmation(_ choice: RequestChoice, intent: RequestIntent) -> RequestCardConfirmation? {
        guard canAct, input.store.isConnected else { return nil }
        pendingConfirmation = PendingConfirmation(id: UUID(), choice: choice, intent: intent)
        return confirmation
    }
    var confirmation: RequestCardConfirmation? {
        guard let pendingConfirmation else { return nil }
        return RequestCardConfirmation(id: pendingConfirmation.id, choice: pendingConfirmation.choice,
                                       intent: pendingConfirmation.intent, lifetime: self)
    }
    func dismissConfirmation() { pendingConfirmation = nil }
    fileprivate func isCurrentConfirmation(_ id: UUID) -> Bool { pendingConfirmation?.id == id && isCurrent }
    fileprivate func dismissConfirmation(_ id: UUID) {
        if pendingConfirmation?.id == id { pendingConfirmation = nil }
    }
    fileprivate func confirm(id: UUID, choice: RequestChoice, intent: RequestIntent) {
        guard pendingConfirmation?.id == id, canAct else { return }
        pendingConfirmation = nil
        send(.choice(choice.id), intent: intent)
    }
}

/// A confirmation already admitted by a displayed row keeps its captured intent
/// through coverage and host recycling. Real request retirement still denies it.
@MainActor struct RequestCardConfirmation {
    private let id: UUID
    let choice: RequestChoice
    private let lifetime: RequestCardLifetime
    private let intent: RequestIntent
    fileprivate init(id: UUID, choice: RequestChoice, intent: RequestIntent, lifetime: RequestCardLifetime) {
        self.id = id; self.choice = choice; self.intent = intent; self.lifetime = lifetime
    }
    func confirm() { lifetime.confirm(id: id, choice: choice, intent: intent) }
    var isCurrent: Bool { lifetime.isCurrentConfirmation(id) }
    var modalID: UUID { lifetime.modalID }
    func cancel() { lifetime.dismissConfirmation(id) }
}

@MainActor struct RequestCardActions {
    let lifetime: RequestCardLifetime
    private let intent: RequestIntent?
    let admission: @MainActor () -> Bool
    fileprivate init(lifetime: RequestCardLifetime, intent: RequestIntent?, admission: @escaping @MainActor () -> Bool) {
        self.lifetime = lifetime; self.intent = intent; self.admission = admission
    }
    var enabled: Bool { intent != nil && lifetime.canAttempt && admission() }
    func choose(_ choice: RequestChoice) -> RequestCardConfirmation? {
        guard enabled, let intent else { return nil }
        if choice.id.localizedCaseInsensitiveContains("always") || choice.label.localizedCaseInsensitiveContains("always") {
            return lifetime.beginConfirmation(choice, intent: intent)
        }
        lifetime.send(.choice(choice.id), intent: intent)
        return nil
    }
    func submitText() {
        guard enabled, let intent, lifetime.input.row.request.kind == .question else { return }
        let value = lifetime.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        lifetime.send(.text(value), intent: intent)
    }
}

struct RequestCard: View {
    let canAct: Bool
    let canEditDraft: Bool
    @State private var connectionRequested = false
    private let providedLifetime: RequestCardLifetime?
    @State private var localLifetime: RequestCardLifetime
    private var lifetime: RequestCardLifetime { providedLifetime ?? localLifetime }
    private var request: PendingRequest { lifetime.input.row.request }
    private var store: AppStore { lifetime.input.store }
    init(input: RequestCardInput, canAct: Bool, canEditDraft: Bool, lifetime: RequestCardLifetime? = nil) {
        self.canAct = canAct; self.canEditDraft = canEditDraft; providedLifetime = lifetime
        _localLifetime = State(initialValue: lifetime ?? RequestCardLifetime(input))
    }
    @Environment(\.reportChatModal) private var reportModal
    @Environment(\.nativeTranscriptRow) private var nativeRow

    private var actions: RequestCardActions {
        nativeRow?.requestActions ?? lifetime.actions { canAct || (!store.isConnected && canEditDraft) }
    }
    var body: some View {
        // Button closures must retain this rendered action/operation value.
        // Resolving self.actions inside a callback would borrow a newer retry.
        let actions = self.actions
        let enabled = actions.enabled
        VStack(alignment: .leading, spacing: 14) {
            Label(request.kind == .unsupported ? "Continue on Desktop" : "Needs you",
                  systemImage: request.kind == .unsupported ? "desktopcomputer" : BottoTheme.needsYouSymbol)
                .font(.caption.weight(.semibold)).foregroundStyle(BottoTheme.attention)
            Text(request.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            if !request.detail.isEmpty {
                Text(request.detail).font(.subheadline).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if request.kind == .unsupported {
                Text("Open Hermes Desktop to handle this request. Botto can’t safely complete it here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(request.choices) { choice in
                    Button {
                        guard actions.enabled, requireConnection() else { return }
                        if let confirmation = actions.choose(choice) {
                            if let nativeRow { nativeRow.presentRequestConfirmation?(confirmation, reportModal) }
                            else { reportModal(lifetime.modalID, true) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(choice.label).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(enabled ? BottoTheme.action : BottoTheme.disabledForeground)
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minHeight: 46)
                        .background(BottoTheme.paper, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain).disabled(!enabled)
                }
                if request.kind == .question {
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Write your answer", text: lifetime.responseBinding, axis: .vertical)
                            .lineLimit(1...5).padding(12)
                            .background(BottoTheme.paper, in: RoundedRectangle(cornerRadius: 12))
                            .disabled(!canEditDraft || !lifetime.canEditDraft)
                        Button {
                            guard actions.enabled, requireConnection() else { return }
                            actions.submitText()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                        .tint(BottoTheme.action).foregroundStyle(BottoTheme.onAction)
                        .accessibilityLabel("Submit answer")
                        .disabled(!enabled || lifetime.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if connectionRequested && !store.isConnected { ConnectionStatusView(store: store) }
                if lifetime.busy { Text("Sending your answer…").font(.footnote).foregroundStyle(.secondary) }
                if request.kind == .approval && request.choices.isEmpty {
                    Text("This request has no supported mobile choices. Open Hermes Desktop to respond.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(BottoTheme.attentionSurface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(BottoTheme.attention, lineWidth: 1))
        .onChange(of: store.isConnected) { _, _ in
            connectionRequested = false
            lifetime.dismissConfirmation()
        }
        .onChange(of: lifetime.input.owner) { _, _ in lifetime.dismissConfirmation() }
        .onChange(of: lifetime.confirmation == nil) { _, dismissed in
            if dismissed && nativeRow == nil { reportModal(lifetime.modalID, false) }
        }
        .onDisappear { if nativeRow == nil { reportModal(lifetime.modalID, false) } }
        .confirmationDialog("Allow future actions?", isPresented: Binding(get: { nativeRow == nil && lifetime.confirmation != nil }, set: { if !$0 && nativeRow == nil { lifetime.dismissConfirmation() } }), titleVisibility: .visible) {
            if let confirmation = lifetime.confirmation {
                Button(confirmation.choice.label) {
                    confirmation.confirm()
                }
            }
            Button("Cancel", role: .cancel) { lifetime.dismissConfirmation() }
        } message: {
            Text("This choice can let Hermes run matching actions again without asking you. Only continue if you trust the scope described in this request.")
        }
    }
    private func requireConnection() -> Bool {
        guard lifetime.isCurrent else { return false }
        guard store.isConnected else { connectionRequested = true; return false }
        return canAct && lifetime.canAct
    }
}
