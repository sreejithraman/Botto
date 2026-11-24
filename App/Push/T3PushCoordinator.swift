import BottoCore
import Foundation
import Observation

@MainActor @Observable final class T3PushCoordinator {
    private(set) var pairings: [T3PushPairing] = []
    private(set) var isBusy = false
    private(set) var notice: String?
    var visible: PushDestination?
    @ObservationIgnored private let load: () throws -> [T3PushPairing]
    @ObservationIgnored private let save: ([T3PushPairing]) throws -> Void
    @ObservationIgnored private let authorization: PushAuthorization
    @ObservationIgnored private let send: (T3PushRegistration, T3PushInvitation) async throws -> T3PushRegistrationReply
    @ObservationIgnored private let bundleID: String
    @ObservationIgnored private let environment: PushEnvironment

    init(load: @escaping () throws -> [T3PushPairing] = PushPairingVault.loadT3,
         save: @escaping ([T3PushPairing]) throws -> Void = PushPairingVault.saveT3,
         authorization: PushAuthorization = .system,
         bundleID: String = Bundle.main.bundleIdentifier ?? "com.sree.botto",
         environment: PushEnvironment? = nil,
         send: @escaping (T3PushRegistration, T3PushInvitation) async throws -> T3PushRegistrationReply =
            { try await T3PushRegistrationChannel.send($0, invitation: $1) }) {
        self.load = load
        self.save = save
        self.authorization = authorization
        self.send = send
        self.bundleID = bundleID
        let buildEnvironment = Bundle.main.object(forInfoDictionaryKey: "BottoPushEnvironment") as? String
        self.environment = environment ?? PushEnvironment(rawValue: buildEnvironment ?? "") ?? .sandbox
        reload()
    }

    func pairing(_ scope: T3PushScope?) -> T3PushPairing? {
        pairings.first { $0.invitation.scope == scope }
    }

    func enable(code: String, scope: T3PushScope) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            pairings = try load()
            guard pairing(scope) == nil else { return }
            let invitation = try T3PushInvitation(code: code)
            guard invitation.scope == scope else { throw T3PushRegistrationError.wrongMac }
            guard try await authorization.requestPermission() else { throw PushError.permissionDenied }
            let token = try await authorization.deviceToken()
            let registration = T3PushRegistration(scope: scope, generation: 1, target: target(token))
            let pairing = T3PushPairing(invitation: invitation, registration: registration, installationID: nil, confirmed: false)
            try replace(pairing)
            try await reconcile(pairing)
            notice = nil
        } catch { notice = error.localizedDescription }
    }

    @discardableResult func disable(scope: T3PushScope) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        var savedRemoval = false
        do {
            pairings = try load()
            guard var pairing = pairing(scope) else { return true }
            if pairing.registration.target != nil {
                pairing.registration = .init(scope: scope, generation: pairing.registration.generation + 1, target: nil)
                pairing.confirmed = false
                try replace(pairing)
            }
            savedRemoval = true
            try await reconcile(pairing)
            notice = nil
        } catch {
            notice = savedRemoval
                ? "Turned off on this iPhone. Botto will retry removal when it can reach your Mac."
                : error.localizedDescription
        }
        return savedRemoval
    }

    func resume(scope: T3PushScope?) async {
        guard !isBusy else { return }
        reload()
        for removal in pairings where removal.registration.target == nil {
            await disable(scope: removal.invitation.scope)
        }
        guard !isBusy, let scope, pairing(scope)?.registration.target != nil else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await update(scope: scope, token: authorization.deviceToken())
        } catch { notice = error.localizedDescription }
    }

    func didRegister(token: String, scope: T3PushScope?) async {
        guard !isBusy, let scope, pairing(scope)?.registration.target != nil else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await update(scope: scope, token: token) }
        catch { notice = error.localizedDescription }
    }

    func navigationIntent(_ envelope: PushEnvelope, scope: T3PushScope) -> PushNavigationIntent? {
        guard let pairing = pairing(scope), let preview = pairing.preview(envelope) else { return nil }
        return .init(t3: scope, installationID: envelope.installationID, deviceID: envelope.deviceID,
                     destination: preview.destination)
    }

    func authorizes(_ intent: PushNavigationIntent, scope: T3PushScope?) -> Bool {
        guard case .t3(let original) = intent.source, original == scope, let pairing = pairing(scope) else { return false }
        return pairing.registration.target != nil && pairing.installationID == intent.installationID
            && pairing.invitation.deviceID == intent.deviceID
    }

    func shouldPresent(_ envelope: PushEnvelope, scope: T3PushScope) -> Bool {
        guard let pairing = pairing(scope), let preview = pairing.preview(envelope) else { return false }
        return preview.destination != visible
    }

    private func target(_ token: String) -> T3PushRegistration.Target {
        .init(token: token, bundleID: bundleID, environment: environment)
    }

    private func update(scope: T3PushScope, token: String) async throws {
        guard var pairing = pairing(scope), let previous = pairing.registration.target else { return }
        let target = target(token)
        if pairing.installationID == nil, target != previous {
            try await reconcile(pairing)
            guard let initial = self.pairing(scope) else { return }
            pairing = initial
        }
        if target != previous {
            pairing.registration = .init(scope: scope, generation: pairing.registration.generation + 1, target: target)
            pairing.confirmed = false
            try replace(pairing)
        }
        if !pairing.confirmed { try await reconcile(pairing) }
        notice = nil
    }

    private func reconcile(_ pairing: T3PushPairing) async throws {
        let response = try await send(pairing.registration, pairing.invitation)
        guard PushEnvelope.validHex(response.installationID, count: 64),
              pairing.installationID == nil || pairing.installationID == response.installationID else {
            throw T3PushRegistrationError.wrongMac
        }
        switch response.status {
        case .registered where pairing.registration.target != nil:
            var enabled = pairing
            enabled.confirmed = true
            enabled.installationID = response.installationID
            try replace(enabled)
        case .removed where pairing.registration.target == nil:
            try remove(pairing)
        case .retired:
            try remove(pairing)
            if pairing.registration.target != nil { throw T3PushRegistrationError.expiredCode }
        case .differentWorkspace:
            throw T3PushRegistrationError.wrongMac
        default:
            throw T3PushRegistrationError.relayUnavailable
        }
    }

    private func reload() {
        do { pairings = try load() }
        catch { pairings = []; notice = error.localizedDescription }
    }

    private func replace(_ pairing: T3PushPairing) throws {
        var next = pairings.filter { $0.invitation.scope != pairing.invitation.scope }
        next.append(pairing)
        try save(next)
        pairings = next
    }

    private func remove(_ pairing: T3PushPairing) throws {
        let next = pairings.filter { $0.invitation.deviceID != pairing.invitation.deviceID }
        try save(next)
        pairings = next
    }
}
