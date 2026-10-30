import CryptoKit
import Foundation
import Observation
import BottoCore
import UIKit

struct PushNavigationIntent: Equatable, Sendable {
    enum Readiness { case current, retired, unavailable }
    let id = UUID()
    var recoveryRevision = UUID()
    let host: PushHostBinding
    let installationID: String
    let deviceID: String
    let destination: PushDestination
}

@MainActor @Observable final class PushCoordinator {
    private(set) var status: PushHostStatus?
    private(set) var notice: String?
    private(set) var isBusy = false
    private(set) var isChecking = false
    private(set) var preferences = PushPreferences()
    private(set) var storageUnavailable = false
    private(set) var isDemo = false
    private(set) var restartRequired = false
    private(set) var profiles: [BotProfile] = []
    @ObservationIgnored private var saved = PushSavedState()
    @ObservationIgnored private let persistence: PushPersistence
    @ObservationIgnored private let authorization: PushAuthorization
    @ObservationIgnored private let bundleID: String
    @ObservationIgnored private let environment: PushEnvironment
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var service: (any BotService)?
    @ObservationIgnored private var host: PushHostBinding?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var selectionEpoch = UUID()
    @ObservationIgnored private var statusRead = UUID()
    @ObservationIgnored private var deviceToken: String?
    @ObservationIgnored private var visible: PushDestination?
    private struct Reconciliation {
        let id: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var reconciliation: Reconciliation?
    @ObservationIgnored private var visibilityLease: Task<Void, Never>?
    @ObservationIgnored private var retiring = false
    @ObservationIgnored private var retirementOperation: UUID?
    @ObservationIgnored private var busyOperation: UUID?
    @ObservationIgnored private var enableIntent = UUID()

    init(persistence: PushPersistence = .keychain, authorization: PushAuthorization = .system,
         bundleID: String = Bundle.main.bundleIdentifier ?? "com.sree.botto",
         environment: PushEnvironment? = nil, now: @escaping () -> Date = Date.init, deviceName: String = UIDevice.current.model) {
        self.persistence = persistence; self.authorization = authorization; self.bundleID = bundleID; self.now = now
        self.environment = environment ?? Self.configuredEnvironment
        self.deviceName = deviceName
        do { saved = try persistence.load() }
        catch { storageUnavailable = true; notice = PushError.unavailableStorage.localizedDescription }
    }

    private static var configuredEnvironment: PushEnvironment {
        let value = Bundle.main.object(forInfoDictionaryKey: "BottoPushEnvironment") as? String
        return PushEnvironment(rawValue: value ?? "") ?? .sandbox
    }
    private var pairing: PushPairing? { saved.pairings.first { $0.host == host } }
    var selectedProfileID: String? { host?.profileID }
    var isEnabled: Bool { pairing?.remoteConfirmed == true && pairing?.retirement == nil }
    var hasPairing: Bool { pairing != nil }
    func isCurrentDevice(_ device: PushDevice) -> Bool { pairing?.deviceID == device.deviceID }
    var pendingRemovalCount: Int { saved.removals.count }
    var canEnable: Bool { !isDemo && !storageUnavailable && host != nil && service != nil && status?.supported == true && !isBusy && !retiring }
    var stateDescription: String {
        if isDemo { return "Demo does not send notifications." }
        if storageUnavailable { return PushError.unavailableStorage.localizedDescription }
        if let retirement = pairing?.retirement { return retirementNotice(retirement.reason) }
        if pairing?.pendingEnrollment != nil { return "Notification changes are waiting for confirmation. Retry setup when connected." }
        if isEnabled { return "Notifications are on for this bot on this device." }
        if host == nil { return "Connect to Hermes before setting up notifications." }
        if let status, !status.supported { return status.reason ?? PushError.unsupported.localizedDescription }
        return "Notifications are off for this bot on this device."
    }

    func retireConnection() {
        enableIntent = UUID()
        epoch = UUID(); selectionEpoch = UUID(); statusRead = UUID()
        service = nil; status = nil; isChecking = false
        visibilityLease?.cancel(); visibilityLease = nil; visible = nil
        reconciliation = nil; deviceToken = nil
        retirementOperation = nil; retiring = false
        busyOperation = nil; isBusy = false
    }

    func bind(service: any BotService, configuration: ConnectionConfiguration?, isDemo: Bool, profileID: String? = nil) {
        let selected = profileID ?? host?.profileID ?? profiles.first?.id ?? "default"
        let next = isDemo ? nil : configuration.flatMap { PushHostBinding($0, profileID: selected) }
        let sameConnection = host != nil && next != nil && host!.sameConnection(as: next!)
        let changed = !sameConnection || self.isDemo != isDemo || self.service.map(ObjectIdentifier.init) != ObjectIdentifier(service)
        if changed { retireConnection() }
        if next != host || changed { selectionEpoch = UUID(); status = nil; restartRequired = false }
        self.service = service; host = next; self.isDemo = isDemo
        preferences = pairing?.preferences ?? .init()
    }

    func configureProfiles(_ profiles: [BotProfile], selectedProfileID: String? = nil) {
        self.profiles = profiles
        if let selectedProfileID, let host, host.profileID != selectedProfileID {
            var next = host; next.profileID = selectedProfileID
            self.host = next; selectionEpoch = UUID(); status = nil; preferences = pairing?.preferences ?? .init()
        }
    }

    func selectProfile(_ profileID: String) async {
        guard profiles.contains(where: { $0.id.utf8.elementsEqual(profileID.utf8) }), var host else { return }
        host.profileID = profileID; self.host = host; selectionEpoch = UUID(); status = nil
        preferences = pairing?.preferences ?? .init(); notice = nil
        await refresh()
    }

    func retryStorage() {
        do { saved = try persistence.load(); preferences = pairing?.preferences ?? .init(); storageUnavailable = false; notice = nil }
        catch { notice = PushError.unavailableStorage.localizedDescription }
    }

    func refresh() async {
        guard !isDemo, let host, let service else { return }
        let owner = selectionEpoch, lifetime = epoch, read = UUID()
        let observedPairing = pairing
        statusRead = read; isChecking = true
        defer { if statusRead == read { isChecking = false } }
        do {
            let status = try await service.pushStatus(profileID: host.profileID)
            guard epoch == lifetime, selectionEpoch == owner, statusRead == read else { return }
            self.status = status
            try reconcileStatus(status, host: host, observedPairing: observedPairing)
        } catch {
            guard epoch == lifetime, selectionEpoch == owner, statusRead == read else { return }
            if case HermesServiceError.rejected(404) = error { notice = "Install the Botto push plugin for this Hermes profile to continue." }
            else { notice = error.localizedDescription }
        }
    }

    private func reconcileStatus(_ status: PushHostStatus, host: PushHostBinding, observedPairing: PushPairing?) throws {
        guard var pairing = saved.pairings.first(where: { $0.host == host }),
              status.installationID == pairing.installationID else { return }
        let reason: PushRetirement.Reason
        let generation: Int
        if let device = status.devices.first(where: { $0.deviceID == pairing.deviceID }) {
            guard device.generation >= pairing.generation else { return }
            if device.state == .relayRetired { reason = .relay }
            else if device.state == .removed || device.pendingRemoval == true || device.active == false { reason = .removed }
            else { return }
            generation = device.generation
        } else {
            guard observedPairing?.deviceID == pairing.deviceID,
                  observedPairing?.generation == pairing.generation,
                  observedPairing?.lastEnrollment == pairing.lastEnrollment,
                  observedPairing?.remoteConfirmed == pairing.remoteConfirmed else { return }
            guard pairing.lastEnrollment != nil || pairing.remoteConfirmed || pairing.retirement != nil else { return }
            reason = .removed; generation = pairing.generation
        }
        let previous = pairing.retirement
        let effectiveReason: PushRetirement.Reason = previous?.reason == .removed ? .removed : reason
        let token: String?
        if generation > pairing.generation {
            let pending = pairing.pendingEnrollment
            token = pending?.expectedGeneration == generation - 1 ? pending?.token : nil
        } else {
            token = previous?.token ?? pairing.lastEnrollment?.token ?? pairing.pendingEnrollment?.token ?? deviceToken
        }
        let keepRotationAttempt = effectiveReason == .relay && previous?.reason == .relay &&
            pairing.pendingEnrollment?.token != nil && pairing.pendingEnrollment?.token != token && generation <= pairing.generation
        pairing.generation = generation
        pairing.remoteConfirmed = false
        pairing.retirement = .init(reason: effectiveReason, token: token)
        if !keepRotationAttempt { pairing.pendingEnrollment = nil }
        try replace(pairing)
        notice = retirementNotice(effectiveReason)
    }

    private func retirementNotice(_ reason: PushRetirement.Reason) -> String {
        switch reason {
        case .relay: "The relay retired this notification target. Turn off notifications for this device, then enable them again."
        case .removed: "This notification pairing was removed. Turn off notifications for this device, then enable them again to create a new pairing."
        }
    }

    func resume() async {
        guard !isDemo, let host, service != nil, !storageUnavailable else { return }
        let owner = epoch
        await retryRemovals()
        guard epoch == owner, service != nil,
              saved.pairings.contains(where: { $0.host.sameConnection(as: host) }) else { return }
        do {
            let token = try await authorization.deviceToken()
            guard epoch == owner, service != nil else { return }
            deviceToken = token
            await reconcile()
        } catch { if epoch == owner { notice = error.localizedDescription } }
    }

    func enable() async {
        guard canEnable, let host, let installationID = status?.installationID,
              PushEnvelope.validHex(installationID, count: 64), let relay = status?.relayURL,
              relay.scheme == "https", relay.user == nil, relay.password == nil else {
            notice = status?.reason ?? PushError.unsupported.localizedDescription; return
        }
        let busy = beginBusy(); notice = nil
        let owner = epoch, selection = selectionEpoch, intent = enableIntent
        defer { endBusy(busy) }
        do {
            guard try await authorization.requestPermission() else { throw PushError.permissionDenied }
            guard epoch == owner, selectionEpoch == selection, enableIntent == intent, !retiring, service != nil else { return }
            let token = try await authorization.deviceToken()
            guard epoch == owner, selectionEpoch == selection, enableIntent == intent, !retiring, service != nil else { return }
            if pairing == nil {
                let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                let new = PushPairing(host: host, installationID: installationID,
                    deviceID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                    generation: 0, key: key, preferences: preferences, pendingEnrollment: nil,
                    remoteConfirmed: false, lastEnrollment: nil)
                try replace(new)
            }
            deviceToken = token
            await reconcile()
        } catch { if epoch == owner { notice = error.localizedDescription } }
    }

    func didRegister(token: String) async {
        guard !isDemo, service != nil, deviceToken != token else { return }
        deviceToken = token; await reconcile()
    }

    func updatePreferences(_ preferences: PushPreferences) async {
        guard !isDemo, !retiring, var pairing else { return }
        do {
            pairing.preferences = preferences
            try replace(pairing)
            self.preferences = preferences
            await reconcile()
        } catch { notice = error.localizedDescription }
    }

    func updateVisibility(destination: PushDestination?) {
        guard visible != destination else { return }
        visible = destination; visibilityLease?.cancel(); visibilityLease = nil
        guard !isDemo, service != nil, !retiring else { return }
        let owner = epoch
        Task { if self.epoch == owner { await self.reconcile() } }
        if destination != nil {
            visibilityLease = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.epoch == owner, self.visible != nil else { return }
                    await self.reconcile()
                }
            }
        }
    }

    func deactivate() { updateVisibility(destination: nil) }

    private func desiredVisible(for pairing: PushPairing) -> PushDestination? {
        visible.flatMap { $0.profileID.utf8.elementsEqual(pairing.host.profileID.utf8) ? $0 : nil }
    }

    private func needsReconciliation(_ pairing: PushPairing, token: String) -> Bool {
        if let retirement = pairing.retirement {
            guard retirement.reason == .relay, let retiredToken = retirement.token, token != retiredToken else { return false }
        }
        let desired = desiredVisible(for: pairing)
        guard let last = pairing.lastEnrollment else { return true }
        return pairing.pendingEnrollment != nil || !pairing.remoteConfirmed || last.token != token ||
            last.bundleID != bundleID || last.environment != environment ||
            last.preferences != pairing.preferences || last.visibleChat != desired ||
            (desired != nil && last.visibleUntil < Int(now().timeIntervalSince1970) + 60)
    }

    private func reconcile() async {
        guard service != nil, !isDemo else { return }
        if let reconciliation { await reconciliation.task.value; return }
        let id = UUID(), owner = epoch
        let task = Task { @MainActor [weak self] in
            await self?.reconcileLoop(owner: owner)
            if self?.reconciliation?.id == id { self?.reconciliation = nil }
        }
        reconciliation = .init(id: id, task: task)
        await task.value
    }

    private func reconcileLoop(owner: UUID) async {
        guard epoch == owner, !storageUnavailable, !isDemo, !retiring, let service, let host else { return }
        while epoch == owner, !retiring, let token = deviceToken,
              let pairing = saved.pairings.first(where: { $0.host.sameConnection(as: host) && needsReconciliation($0, token: token) }) {
            do {
                let request: PushEnrollmentRequest
                if let pending = pairing.pendingEnrollment { request = pending }
                else {
                    let visible = desiredVisible(for: pairing)
                    request = .init(deviceID: pairing.deviceID, token: token, bundleID: bundleID,
                        environment: environment, previewKey: pairing.generation == 0 ? pairing.key : nil,
                        preferences: pairing.preferences, visibleChat: visible,
                        visibleUntil: visible == nil ? 0 : Int(now().timeIntervalSince1970) + 90,
                        deviceName: deviceName, expectedGeneration: pairing.generation)
                    var next = pairing; next.pendingEnrollment = request; try replace(next)
                }
                let enrollment = try await service.enrollPushDevice(request, profileID: pairing.host.profileID).validated()
                guard epoch == owner, var latest = saved.pairings.first(where: { $0.host == pairing.host && $0.deviceID == pairing.deviceID }) else { return }
                guard latest.pendingEnrollment?.operationID == request.operationID,
                      latest.retirement?.reason != .removed, enrollment.generation >= latest.generation else { return }
                guard enrollment.installationID == latest.installationID else { throw PushError.enrollmentChanged }
                latest.generation = enrollment.generation
                latest.remoteConfirmed = enrollment.status == "accepted"
                if enrollment.status == "accepted" {
                    latest.pendingEnrollment = nil
                    latest.retirement = nil
                    var acknowledged = request; acknowledged.previewKey = nil
                    latest.lastEnrollment = acknowledged
                } else if enrollment.status == "revoked" ||
                            (enrollment.status == "rejected" && latest.retirement?.reason == .relay) {
                    latest.pendingEnrollment = nil
                    latest.retirement = .init(reason: latest.retirement?.reason == .removed ? .removed : .relay, token: request.token)
                }
                try replace(latest)
                guard enrollment.status == "accepted" else {
                    notice = latest.retirement != nil
                        ? retirementNotice(latest.retirement?.reason ?? .relay)
                        : "Your host saved notification setup, but the relay has not confirmed it yet."
                    return
                }
                notice = nil
            } catch { if epoch == owner { notice = error.localizedDescription }; return }
        }
    }

    func disable() async { if let pairing { _ = await removePairings([pairing]) } }

    func removeDevice(_ device: PushDevice) async {
        guard !isBusy, !isDemo, !retiring, let host,
              status?.devices.contains(where: { $0.deviceID == device.deviceID }) == true else { return }
        let owner = epoch
        if isCurrentDevice(device) {
            await disable()
            guard epoch == owner else { return }
            await refresh(); return
        }
        let busy = beginBusy(), removal = UUID()
        retirementOperation = removal; retiring = true
        defer {
            endBusy(busy)
            if retirementOperation == removal { retirementOperation = nil; retiring = false }
        }
        if let reconciliation { await reconciliation.task.value }
        guard epoch == owner, service != nil else { return }
        var next = saved
        if !next.removals.contains(where: { $0.host == host && $0.deviceID == device.deviceID }) {
            next.removals.append(.init(id: UUID(), host: host, deviceID: device.deviceID))
        }
        do {
            try persist(next)
            await retryRemovals()
            guard epoch == owner else { return }
            await refresh()
        } catch { if epoch == owner { notice = error.localizedDescription } }
    }

    @discardableResult func prepareToForget() async -> Bool {
        guard !storageUnavailable else { return false }
        guard let host else { return await removePairings(saved.pairings) }
        return await removePairings(saved.pairings.filter { $0.host.sameConnection(as: host) })
    }

    private func removePairings(_ pairings: [PushPairing]) async -> Bool {
        guard !storageUnavailable, !retiring else { return false }
        enableIntent = UUID()
        statusRead = UUID(); isChecking = false
        let owner = epoch, removal = UUID()
        retirementOperation = removal
        retiring = true; visibilityLease?.cancel(); visibilityLease = nil; visible = nil
        defer { if retirementOperation == removal { retirementOperation = nil; retiring = false } }
        if let reconciliation { await reconciliation.task.value }
        guard epoch == owner else { return false }
        notice = nil
        var next = saved
        for pairing in pairings {
            next.pairings.removeAll { $0.host == pairing.host && $0.deviceID == pairing.deviceID }
            if !next.removals.contains(where: { $0.host == pairing.host && $0.deviceID == pairing.deviceID }) {
                next.removals.append(.init(id: UUID(), host: pairing.host, deviceID: pairing.deviceID))
            }
        }
        do { try persist(next) }
        catch { notice = error.localizedDescription; return false }
        if (host == nil || service == nil), !pairings.isEmpty {
            notice = "Removed locally. Remote notification removal is not confirmed. Reconnect to the original Hermes host to retry."
        }
        await retryRemovals()
        return epoch == owner
    }

    func retryRemovals() async {
        guard let host, let service, !isDemo else { return }
        let owner = epoch
        for removal in saved.removals where removal.host.sameConnection(as: host) {
            guard epoch == owner else { return }
            do {
                let response = try await service.removePushDevice(deviceID: removal.deviceID, operationID: removal.id, profileID: removal.host.profileID)
                guard epoch == owner else { return }
                guard response.isConfirmed else { notice = "Removed locally. Your host is still confirming notification removal with the relay."; continue }
                var next = saved; next.removals.removeAll { $0.id == removal.id }; try persist(next)
            } catch { if epoch == owner { notice = "Removed locally. Remote notification removal is not confirmed. Reconnect to this host to retry." } }
        }
    }

    private func pairing(for envelope: PushEnvelope) -> PushPairing? {
        guard !isDemo, let host else { return nil }
        return saved.pairings.first { $0.host.sameConnection(as: host) && $0.installationID == envelope.installationID && $0.deviceID == envelope.deviceID }
    }
    func preview(_ envelope: PushEnvelope) -> PushPreview? {
        guard let pairing = pairing(for: envelope), let preview = try? envelope.decrypt(key: pairing.key, now: now()),
              preview.profileID.utf8.elementsEqual(pairing.host.profileID.utf8) else { return nil }
        return preview
    }
    func destination(envelope: PushEnvelope) -> PushDestination? { preview(envelope)?.destination }
    func navigationIntent(_ envelope: PushEnvelope) -> PushNavigationIntent? {
        guard !storageUnavailable, let pairing = pairing(for: envelope), pairing.retirement == nil,
              let destination = destination(envelope: envelope) else { return nil }
        return .init(host: pairing.host, installationID: envelope.installationID,
                     deviceID: pairing.deviceID, destination: destination)
    }
    func authorizesNavigation(_ intent: PushNavigationIntent) -> Bool {
        guard !isDemo, !storageUnavailable, let host, host.sameConnection(as: intent.host) else { return false }
        return saved.pairings.contains {
            $0.host == intent.host && $0.deviceID == intent.deviceID &&
            $0.installationID == intent.installationID && $0.retirement == nil
        }
    }
    func navigationReadiness(_ intent: PushNavigationIntent) async -> PushNavigationIntent.Readiness {
        guard authorizesNavigation(intent), let service else { return .retired }
        let lifetime = epoch
        let observed = saved.pairings.first { $0.host == intent.host && $0.deviceID == intent.deviceID }
        do {
            let status = try await service.pushStatus(profileID: intent.host.profileID)
            guard epoch == lifetime else { return .unavailable }
            guard authorizesNavigation(intent) else { return .retired }
            guard status.v == 1, status.supported, status.installationID == intent.installationID else { return .unavailable }
            try reconcileStatus(status, host: intent.host, observedPairing: observed)
            return authorizesNavigation(intent) ? .current : .retired
        } catch { return .unavailable }
    }
    func shouldPresent(_ envelope: PushEnvelope) -> Bool {
        guard let pairing = pairing(for: envelope), envelope.v == 1,
              envelope.expiresAt > Int(now().timeIntervalSince1970) else { return false }
        let enabled: Bool
        switch envelope.kind {
        case .reply: enabled = pairing.preferences.replies
        case .approval, .question: enabled = pairing.preferences.requests
        case .failure: enabled = pairing.preferences.failures
        }
        guard enabled else { return false }
        guard let preview = preview(envelope), let visible else { return true }
        return !visible.profileID.utf8.elementsEqual(preview.profileID.utf8)
            || !visible.rootID.utf8.elementsEqual(preview.rootID.utf8)
    }

    func sendTest(destination: PushDestination) async {
        guard !isBusy, let service, let pairing, pairing.remoteConfirmed, destination.profileID == pairing.host.profileID else { return }
        let busy = beginBusy(), owner = epoch
        defer { endBusy(busy) }
        do {
            try await service.testPushDevice(deviceID: pairing.deviceID, destination: destination, profileID: pairing.host.profileID)
            if epoch == owner { notice = "Test submitted. Check this device for the alert; submission does not confirm display." }
        } catch { if epoch == owner { notice = error.localizedDescription } }
    }

    func installPlugin(identifier: String, ref: String) async {
        guard !isBusy, !isDemo, let service, let host else { return }
        let busy = beginBusy(), owner = selectionEpoch, lifetime = epoch
        defer { endBusy(busy) }
        do {
            let result = try await service.installPushPlugin(identifier: identifier, ref: ref, profileID: host.profileID)
            guard epoch == lifetime, selectionEpoch == owner else { return }
            restartRequired = result.restartRequired
            notice = result.restartRequired ? "Plugin files were installed. Restart this Hermes profile when it is safe, then check again." : result.warnings.first
            await refresh()
        } catch {
            guard epoch == lifetime, selectionEpoch == owner else { return }
            if case HermesServiceError.rejected(let code) = error, code == 404 || code == 405 {
                notice = "This host requires manual installation. Use the per-profile commands, then check again."
            } else { notice = error.localizedDescription }
        }
    }

    private func beginBusy() -> UUID {
        let operation = UUID(); busyOperation = operation; isBusy = true; return operation
    }
    private func endBusy(_ operation: UUID) {
        if busyOperation == operation { busyOperation = nil; isBusy = false }
    }

    private func replace(_ pairing: PushPairing) throws {
        var next = saved
        next.pairings.removeAll { $0.host == pairing.host }
        next.pairings.append(pairing)
        try persist(next)
    }
    private func persist(_ next: PushSavedState) throws { try persistence.save(next); saved = next }
}
