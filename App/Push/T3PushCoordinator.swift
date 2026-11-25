import BottoCore
import Foundation
import Observation

@MainActor @Observable final class T3PushCoordinator {
    private(set) var pairings: [T3PushPairing] = []
    private(set) var isBusy = false
    private(set) var notice: String?
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
        pairings.first { $0.invitation.scope == scope && $0.registration.target != nil }
    }

    func hasPendingRemoval(_ scope: T3PushScope?) -> Bool {
        pairings.contains { $0.invitation.scope == scope && $0.registration.target == nil }
    }

    func hasOtherPairings(than scope: T3PushScope?) -> Bool {
        pairings.contains { $0.invitation.scope != scope && $0.registration.target != nil }
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
            guard !pairings.contains(where: { $0.invitation.deviceID == invitation.deviceID }) else {
                throw T3PushRegistrationError.expiredCode
            }
            guard try await authorization.requestPermission() else { throw PushError.permissionDenied }
            let token = try await authorization.deviceToken()
            let removed = await retryRemovals(matching: { $0 == scope }, at: invitation)
            let registration = T3PushRegistration(scope: scope, generation: 1, target: target(token))
            let pairing = T3PushPairing(invitation: invitation, registration: registration, installationID: nil, confirmed: false)
            try replace(pairing)
            try await reconcile(pairing)
            notice = removed ? nil : removalNotice
        } catch { notice = error.localizedDescription }
    }

    func updateMacAddress(code: String, scope: T3PushScope) async {
        guard !isBusy, pairing(scope) != nil || hasPendingRemoval(scope) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let address = try T3PushInvitation(code: code)
            guard address.scope == scope else { throw T3PushRegistrationError.wrongMac }
            let removed = await retryRemovals(matching: { $0 == scope }, at: address)
            if let active = pairing(scope) { try await reconcile(active, at: address) }
            notice = removed ? nil : removalNotice
        } catch { notice = error.localizedDescription }
    }

    @discardableResult func disable(scope: T3PushScope) async -> Bool {
        await disablePairings { $0 == scope }
    }

    @discardableResult func disablePairings(matching: (T3PushScope) -> Bool) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            pairings = try load()
            let retired = pairings.map { pairing in
                let scope = pairing.invitation.scope
                guard matching(scope), pairing.registration.target != nil else { return pairing }
                var removal = pairing
                removal.registration = .init(scope: scope, generation: pairing.registration.generation + 1, target: nil)
                removal.confirmed = false
                return removal
            }
            if retired != pairings {
                try save(retired)
                pairings = retired
            }
            notice = await retryRemovals(matching: matching) ? nil : removalNotice
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func resume(scope: T3PushScope?) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        reload()
        let removed = await retryRemovals(matching: { _ in true })
        if let scope, pairing(scope) != nil {
            do { try await update(scope: scope, token: authorization.deviceToken()) }
            catch { notice = error.localizedDescription; return }
        }
        if !removed { notice = removalNotice }
        else if notice == removalNotice { notice = nil }
    }

    private var removalNotice: String {
        "Turned off on this iPhone. Botto will retry removal when it can reach your Mac."
    }

    private func retryRemovals(matching: (T3PushScope) -> Bool, at address: T3PushInvitation? = nil) async -> Bool {
        let removals = pairings.filter { $0.registration.target == nil && matching($0.invitation.scope) }
        var removed = true
        for removal in removals {
            do { try await reconcile(removal, at: address) }
            catch { removed = false }
        }
        return removed
    }

    func didRegister(token: String, scope: T3PushScope?) async {
        guard !isBusy, let scope, pairing(scope) != nil else { return }
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
        return pairing.installationID == intent.installationID
            && pairing.invitation.deviceID == intent.deviceID
    }

    func shouldPresent(_ envelope: PushEnvelope, scope: T3PushScope, visible: PushDestination?) -> Bool {
        guard let pairing = pairing(scope), let preview = pairing.preview(envelope) else { return false }
        return preview.destination != visible
    }

    private func target(_ token: String) -> T3PushRegistration.Target {
        .init(token: token, bundleID: bundleID, environment: environment)
    }

    private func update(scope: T3PushScope, token: String) async throws {
        guard var pairing = pairing(scope), let previous = pairing.registration.target else { return }
        let target = target(token)
        if target != previous {
            pairing.registration = .init(scope: scope, generation: pairing.registration.generation + 1, target: target)
            pairing.confirmed = false
            try replace(pairing)
        }
        do { try await reconcile(pairing) }
        catch T3PushRegistrationError.bridgeUnavailable where pairing.confirmed { return }
        catch T3PushRegistrationError.relayUnavailable where pairing.confirmed { return }
        notice = nil
    }

    private func reconcile(_ original: T3PushPairing, at address: T3PushInvitation? = nil) async throws {
        var pairing = original
        if let address {
            let identity = original.invitation
            pairing.invitation = .init(host: address.host, port: address.port, scope: identity.scope,
                                       deviceID: identity.deviceID, expiresAt: identity.expiresAt, secret: identity.secret)
        }
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
            if enabled != self.pairing(pairing.invitation.scope) { try replace(enabled) }
        case .removed where pairing.registration.target == nil:
            try remove(pairing)
        case .retired:
            try remove(pairing)
            if pairing.registration.target != nil {
                throw pairing.installationID == nil ? T3PushRegistrationError.expiredCode : T3PushRegistrationError.targetRetired
            }
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
        var next = pairings.filter { $0.invitation.deviceID != pairing.invitation.deviceID }
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
