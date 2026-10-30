import Foundation
import CryptoKit
import Testing
import BottoCore
@testable import Botto

@MainActor private final class PushMemoryVault {
    var state = PushSavedState()
    var failing = false
    var persistence: PushPersistence {
        .init(load: { self.state }, save: { value in
            if self.failing { throw PushError.unavailableStorage }
            self.state = value
        })
    }
}

@MainActor private final class PushFixtureService: BotService {
    var onEvent: ((BotServiceEvent) -> Void)?
    var enrollments: [(PushEnrollmentRequest, String)] = []
    var removals: [(String, UUID, String)] = []
    var failEnrollment = false
    var failRemoval = false
    var holdNextEnrollment = false
    var held: CheckedContinuation<Void, Never>?
    var holdNextRemoval = false
    var heldRemoval: CheckedContinuation<Void, Never>?
    var removalGate: WorkspaceGate?
    var onEnrollment: (() -> Void)?
    var enrollmentStatus = "accepted"
    var enrollmentGeneration = 1
    var reportedDevices: [PushDevice]?
    var statusGate: WorkspaceGate?
    var statusError: (any Error)?
    private var hostDevices: [String: [PushDevice]] = [:]
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo { .init(version: "fixture", installID: "fixture") }
    func disconnect() {}
    func bots() async throws -> [BotProfile] { [] }
    func createBot(_ draft: BotDraft) async throws -> BotProfile { throw PushError.unsupported }
    func conversations(profile: ExactID) async throws -> ConversationDirectory { throw PushError.unsupported }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw PushError.unsupported }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation { throw PushError.unsupported }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw PushError.unsupported }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw PushError.unsupported }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw PushError.unsupported }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment { throw PushError.unsupported }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact { throw PushError.unsupported }

    func installation(_ profile: String) -> String { String(repeating: profile == "bot" ? "a" : "b", count: 64) }
    func pushStatus(profileID: String) async throws -> PushHostStatus {
        let status = PushHostStatus(pluginVersion: "0.1.0", supported: true, installationID: installation(profileID),
              relayURL: URL(string: "https://relay.invalid"), capabilities: ["native_session_events": 1], devices: reportedDevices ?? hostDevices[profileID] ?? [])
        await statusGate?.wait()
        if let statusError { throw statusError }
        return status
    }
    func enrollPushDevice(_ request: PushEnrollmentRequest, profileID: String) async throws -> PushEnrollment {
        enrollments.append((request, profileID)); onEnrollment?()
        if holdNextEnrollment {
            holdNextEnrollment = false
            await withCheckedContinuation { held = $0 }
        }
        if failEnrollment { throw HermesServiceError.disconnected }
        let device = PushDevice(deviceID: request.deviceID, generation: enrollmentGeneration, preferences: request.preferences,
            active: enrollmentStatus == "accepted", state: enrollmentStatus == "revoked" ? .relayRetired : .active)
        hostDevices[profileID, default: []].removeAll { $0.deviceID == request.deviceID }
        hostDevices[profileID, default: []].append(device)
        return .init(installationID: installation(profileID), deviceID: request.deviceID, generation: enrollmentGeneration, preferences: request.preferences, status: enrollmentStatus)
    }
    func removePushDevice(deviceID: String, operationID: UUID, profileID: String) async throws -> PushRemovalResult {
        removals.append((deviceID, operationID, profileID))
        await removalGate?.wait()
        if holdNextRemoval {
            holdNextRemoval = false
            await withCheckedContinuation { heldRemoval = $0 }
        }
        if failRemoval { throw HermesServiceError.disconnected }
        return .init(status: "revoked")
    }
}

@MainActor struct PushCoordinatorTests {
    private let configuration = ConnectionConfiguration(serverURL: URL(string: "https://hermes.invalid")!, username: "owner", installID: "fixture")
    private func controller(_ vault: PushMemoryVault, authorization: PushAuthorization? = nil,
                            environment: PushEnvironment = .sandbox, bundleID: String = "com.example.botto") -> PushCoordinator {
        PushCoordinator(persistence: vault.persistence,
            authorization: authorization ?? .init(requestPermission: { true }, deviceToken: { String(repeating: "1", count: 64) }),
            bundleID: bundleID, environment: environment,
            now: { Date(timeIntervalSince1970: 1_900_000_000) }, deviceName: "Fixture iPhone")
    }
    private func bind(_ coordinator: PushCoordinator, service: PushFixtureService) async {
        coordinator.bind(service: service, configuration: configuration, isDemo: false, profileID: "bot")
        coordinator.configureProfiles([.init(id: "bot", name: "Milo"), .init(id: "other", name: "Scout")])
        await coordinator.refresh()
    }

    @Test func lostEnrollmentAcknowledgmentRetriesThePersistedOperationAndKey() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService()
        let first = controller(vault)
        await bind(first, service: service)
        service.failEnrollment = true
        service.onEnrollment = { #expect(vault.state.pairings.first?.key.count == 32) }
        await first.enable()
        #expect(!first.isEnabled)
        let original = try #require(service.enrollments.first?.0)
        #expect(Data(base64Encoded: try #require(original.previewKey))?.count == 32)
        #expect(original.bundleID == "com.example.botto" && original.environment == .sandbox)

        let restored = controller(vault)
        await bind(restored, service: service)
        service.failEnrollment = false
        await restored.resume()
        #expect(restored.isEnabled)
        #expect(service.enrollments.count == 2)
        #expect(service.enrollments.last?.0.operationID == original.operationID)
        #expect(service.enrollments.last?.0.previewKey == original.previewKey)
    }

    @Test func profilesUseSeparateKeysAndForgetRetiresEveryProfilePairing() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        await coordinator.enable()
        await coordinator.selectProfile("other")
        await coordinator.enable()
        #expect(vault.state.pairings.count == 2)
        #expect(vault.state.pairings[0].key != vault.state.pairings[1].key)
        #expect(vault.state.pairings[0].deviceID != vault.state.pairings[1].deviceID)
        await coordinator.prepareToForget()
        #expect(vault.state.pairings.isEmpty && vault.state.removals.isEmpty)
        #expect(Set(service.removals.map(\.2)) == ["bot", "other"])
    }

    @Test func activeTargetChangesEnvironmentAndBundleWithTheSameTokenButRetirementStaysFenced() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), sandbox = controller(vault)
        await bind(sandbox, service: service)
        await sandbox.enable()
        let original = try #require(service.enrollments.first?.0)

        let production = controller(vault, environment: .production)
        await bind(production, service: service)
        service.enrollmentGeneration = 2
        await production.resume()
        #expect(service.enrollments.count == 2)
        #expect(service.enrollments.last?.0.token == original.token)
        #expect(service.enrollments.last?.0.environment == .production)
        #expect(service.enrollments.last?.0.expectedGeneration == 1)

        let renamed = controller(vault, environment: .production, bundleID: "com.example.fork")
        await bind(renamed, service: service)
        service.enrollmentGeneration = 3
        await renamed.resume()
        #expect(service.enrollments.count == 3)
        #expect(service.enrollments.last?.0.bundleID == "com.example.fork")
        #expect(service.enrollments.last?.0.token == original.token)
        #expect(service.enrollments.last?.0.expectedGeneration == 2)

        service.reportedDevices = [.init(deviceID: original.deviceID, generation: 3, active: false, state: .relayRetired)]
        await renamed.refresh()
        let retired = controller(vault)
        await bind(retired, service: service)
        await retired.resume()
        #expect(service.enrollments.count == 3 && !retired.isEnabled)
    }

    @Test func offlineRemovalWipesKeysAndKeepsOnlyRetryableNonsecretRemoval() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        await coordinator.enable()
        let deviceID = try #require(vault.state.pairings.first?.deviceID)
        service.failRemoval = true
        await coordinator.disable()
        #expect(vault.state.pairings.isEmpty)
        #expect(vault.state.removals.first?.deviceID == deviceID)
        #expect(coordinator.pendingRemovalCount == 1 && !coordinator.isEnabled)
        let operation = try #require(service.removals.first?.1)
        service.failRemoval = false
        await coordinator.retryRemovals()
        #expect(vault.state.removals.isEmpty && service.removals.last?.1 == operation)
    }

    @Test func keySaveFailurePreventsAnyHostEnrollment() async {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        vault.failing = true
        await coordinator.enable()
        #expect(service.enrollments.isEmpty && !coordinator.isEnabled)
        #expect(coordinator.notice == PushError.unavailableStorage.localizedDescription)
    }

    @Test func revokedEnrollmentCannotShowNotificationsEnabled() async {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        service.enrollmentStatus = "revoked"
        await coordinator.enable()
        #expect(!coordinator.isEnabled)
        #expect(coordinator.notice?.contains("Turn off notifications") == true)
    }

    @Test func refreshInvalidatesConfirmationWhenTheHostReportsARetiredTarget() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        await coordinator.enable()
        let pairing = try #require(vault.state.pairings.first)
        service.reportedDevices = [.init(deviceID: pairing.deviceID, generation: pairing.generation, active: false, state: .relayRetired)]
        await coordinator.refresh()
        #expect(!coordinator.isEnabled)
        #expect(vault.state.pairings.first?.remoteConfirmed == false)
        await coordinator.resume()
        await coordinator.updatePreferences(.init(replies: false))
        coordinator.updateVisibility(destination: .init(profileID: "bot", rootID: "root", storedID: "stored"))
        await coordinator.resume()
        #expect(service.enrollments.count == 1 && !coordinator.isEnabled)
        #expect(vault.state.pairings.first?.retirement?.reason == .relay)
        coordinator.deactivate()
    }

    @Test(arguments: [false, true])
    func removedOrMissingAcknowledgedTargetStaysRetiredAfterRestore(missing: Bool) async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        await coordinator.enable()
        let pairing = try #require(vault.state.pairings.first)
        service.reportedDevices = missing ? [] : [.init(deviceID: pairing.deviceID,
            generation: pairing.generation + 1, active: false, state: .removed)]
        await coordinator.refresh()
        await coordinator.resume()
        #expect(!coordinator.isEnabled && service.enrollments.count == 1)

        let restored = controller(vault)
        await bind(restored, service: service)
        await restored.resume()
        await restored.didRegister(token: String(repeating: "2", count: 64))
        await restored.updatePreferences(.init(previews: false))
        #expect(!restored.isEnabled && service.enrollments.count == 1)
        #expect(vault.state.pairings.first?.retirement?.reason == .removed)
    }

    @Test func genuinelyChangedTokenCanRecoverOnlyARelayRetirement() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        await coordinator.enable()
        let pairing = try #require(vault.state.pairings.first)
        service.reportedDevices = [.init(deviceID: pairing.deviceID, generation: 1, active: false, state: .relayRetired)]
        await coordinator.refresh()
        service.enrollmentGeneration = 2
        await coordinator.didRegister(token: String(repeating: "2", count: 64))
        #expect(coordinator.isEnabled && service.enrollments.count == 2)
        #expect(service.enrollments.last?.0.expectedGeneration == 1)
        #expect(service.enrollments.last?.0.operationID != service.enrollments.first?.0.operationID)
        #expect(vault.state.pairings.first?.retirement == nil)
    }

    @Test(arguments: ["revoked", "rejected"])
    func rejectedRotatedTokenBecomesTheNewPersistentRetirementFence(result: String) async throws {
        let vault = PushMemoryVault(), service = PushFixtureService()
        var token = String(repeating: "1", count: 64)
        let auth = PushAuthorization(requestPermission: { true }, deviceToken: { token })
        let coordinator = controller(vault, authorization: auth)
        await bind(coordinator, service: service)
        await coordinator.enable()
        let pairing = try #require(vault.state.pairings.first)
        service.reportedDevices = [.init(deviceID: pairing.deviceID, generation: 1, active: false, state: .relayRetired)]
        await coordinator.refresh()
        token = String(repeating: "2", count: 64)
        service.enrollmentGeneration = 2; service.enrollmentStatus = result
        await coordinator.didRegister(token: token)
        #expect(service.enrollments.count == 2 && !coordinator.isEnabled)
        await coordinator.resume()
        #expect(service.enrollments.count == 2)
        #expect(vault.state.pairings.first?.retirement?.token == token)
        #expect(vault.state.pairings.first?.pendingEnrollment == nil)
    }

    @Test func retirementAfterALostRotationAcknowledgmentFencesTheRotatedToken() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService()
        var token = String(repeating: "1", count: 64)
        let coordinator = controller(vault, authorization: .init(requestPermission: { true }, deviceToken: { token }))
        await bind(coordinator, service: service)
        await coordinator.enable()
        let pairing = try #require(vault.state.pairings.first)
        service.reportedDevices = [.init(deviceID: pairing.deviceID, generation: 1, active: false, state: .relayRetired)]
        await coordinator.refresh()
        token = String(repeating: "2", count: 64)
        service.failEnrollment = true
        await coordinator.didRegister(token: token)
        #expect(service.enrollments.count == 2)
        #expect(vault.state.pairings.first?.pendingEnrollment?.expectedGeneration == 1)

        service.reportedDevices = [.init(deviceID: pairing.deviceID, generation: 2, active: false, state: .relayRetired)]
        await coordinator.refresh()
        service.failEnrollment = false
        await coordinator.resume()
        #expect(!coordinator.isEnabled && service.enrollments.count == 2)
        #expect(vault.state.pairings.first?.retirement?.token == token)
        #expect(vault.state.pairings.first?.pendingEnrollment == nil)
    }

    @Test func lateTokenAfterConnectionRetirementCannotDispatchOrEraseSavedPairing() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), initial = controller(vault)
        await bind(initial, service: service)
        await initial.enable()
        var waiting: CheckedContinuation<String, Error>?
        let coordinator = controller(vault, authorization: .init(requestPermission: { true }, deviceToken: {
            try await withCheckedThrowingContinuation { waiting = $0 }
        }))
        await bind(coordinator, service: service)
        let resume = Task { await coordinator.resume() }
        for _ in 0..<1_000 where waiting == nil { await Task.yield() }
        #expect(waiting != nil)
        coordinator.retireConnection()
        let callback = waiting; waiting = nil; callback?.resume(returning: String(repeating: "2", count: 64))
        await resume.value
        await coordinator.didRegister(token: String(repeating: "3", count: 64))
        #expect(service.enrollments.count == 1)
        #expect(vault.state.pairings.count == 1)
    }

    @Test func missingPluginStatusThatFinishesAfterForgetCannotRestoreTheWarning() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        service.statusError = HermesServiceError.rejected(404)
        let gate = WorkspaceGate()
        service.statusGate = gate
        let probe = Task { await coordinator.refresh() }
        await gate.entered()
        #expect(coordinator.isChecking)

        #expect(await coordinator.prepareToForget())

        #expect(!coordinator.isChecking)
        gate.release()
        await probe.value
        #expect(coordinator.notice == nil)
        #expect(vault.state.pairings.isEmpty && vault.state.removals.isEmpty)
        #expect(service.removals.isEmpty && service.enrollments.isEmpty)
    }

    @Test func unreadableConnectionCanRetireAllReadableLocalPairingsWithoutRPC() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), initial = controller(vault)
        await bind(initial, service: service)
        await initial.enable()
        let unbound = controller(vault)
        #expect(await unbound.prepareToForget())
        #expect(vault.state.pairings.isEmpty && vault.state.removals.count == 1)
        #expect(service.removals.isEmpty)
        #expect(unbound.notice?.contains("not confirmed") == true)
    }

    @Test func anAcceptedResponseCannotUndoANewerAuthoritativeRemoval() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        await coordinator.enable()
        let pairing = try #require(vault.state.pairings.first)
        service.holdNextEnrollment = true
        let update = Task { await coordinator.updatePreferences(.init(previews: false)) }
        for _ in 0..<1_000 where service.held == nil { await Task.yield() }
        #expect(service.held != nil)
        service.reportedDevices = [.init(deviceID: pairing.deviceID, generation: 2, active: false, state: .removed)]
        await coordinator.refresh()
        let callback = service.held; service.held = nil; callback?.resume()
        await update.value
        #expect(!coordinator.isEnabled)
        #expect(vault.state.pairings.first?.retirement?.reason == .removed)
        #expect(vault.state.pairings.first?.generation == 2)
    }

    @Test func statusCapturedBeforeEnrollmentCannotRetireTheAcceptedPairing() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        let gate = WorkspaceGate()
        service.statusGate = gate
        let refresh = Task { await coordinator.refresh() }
        await gate.entered()
        await coordinator.enable()
        #expect(coordinator.isEnabled)
        service.statusGate = nil
        gate.release()
        await refresh.value
        #expect(coordinator.isEnabled)
        #expect(vault.state.pairings.first?.retirement == nil)
        service.enrollmentGeneration = 2
        await coordinator.didRegister(token: String(repeating: "2", count: 64))
        #expect(service.enrollments.count == 2)
        #expect(service.enrollments.last?.0.token == String(repeating: "2", count: 64))
        await coordinator.refresh()
        #expect(coordinator.isEnabled)
    }

    @Test func forgettingCancelsAnEnableWaitingForItsTokenBeforeRemoteRemovalCompletes() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), tokenGate = WorkspaceGate()
        var tokenRequests = 0
        let coordinator = controller(vault, authorization: .init(requestPermission: { true }, deviceToken: {
            tokenRequests += 1
            if tokenRequests == 2 { await tokenGate.wait() }
            return String(repeating: "1", count: 64)
        }))
        await bind(coordinator, service: service)
        await coordinator.enable()
        await coordinator.selectProfile("other")
        let enabling = Task { await coordinator.enable() }
        await tokenGate.entered()
        let removalGate = WorkspaceGate()
        service.removalGate = removalGate
        let forgetting = Task { await coordinator.prepareToForget() }
        await removalGate.entered()
        tokenGate.release()
        await enabling.value
        #expect(vault.state.pairings.isEmpty)
        removalGate.release()
        #expect(await forgetting.value)
        coordinator.retireConnection()
        await bind(coordinator, service: service)
        await coordinator.resume()
        #expect(vault.state.pairings.isEmpty)
        #expect(service.enrollments.count == 1)
    }

    @Test func retiringDuringRemovalRetryDoesNotStartALateTokenRequest() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), initial = controller(vault)
        await bind(initial, service: service)
        await initial.enable()
        let pairing = try #require(vault.state.pairings.first)
        vault.state.removals.append(.init(id: UUID(), host: pairing.host, deviceID: String(repeating: "f", count: 32)))
        var tokenRequests = 0
        let coordinator = controller(vault, authorization: .init(requestPermission: { true }, deviceToken: {
            tokenRequests += 1; return String(repeating: "2", count: 64)
        }))
        await bind(coordinator, service: service)
        service.holdNextRemoval = true
        let resume = Task { await coordinator.resume() }
        for _ in 0..<1_000 where service.heldRemoval == nil { await Task.yield() }
        #expect(service.heldRemoval != nil)
        coordinator.retireConnection()
        let callback = service.heldRemoval; service.heldRemoval = nil; callback?.resume()
        await resume.value
        #expect(tokenRequests == 0 && service.enrollments.count == 1)
        #expect(vault.state.removals.count == 1)
    }

    @Test func forgettingCannotReportSuccessWhenKeyRemovalFails() async {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        await coordinator.enable()
        vault.failing = true
        #expect(await coordinator.prepareToForget() == false)
        #expect(vault.state.pairings.count == 1)
        #expect(service.removals.isEmpty)
    }

    @Test func clearingVisibilityWaitsForTheOlderLeaseThenClearsIt() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        await coordinator.enable()
        service.holdNextEnrollment = true
        coordinator.updateVisibility(destination: .init(profileID: "bot", rootID: "root", storedID: "stored"))
        for _ in 0..<1_000 where service.held == nil { await Task.yield() }
        #expect(service.held != nil)
        coordinator.deactivate()
        let held = service.held; service.held = nil; held?.resume()
        for _ in 0..<1_000 where service.enrollments.count < 3 { await Task.yield() }
        #expect(service.enrollments.count == 3)
        #expect(service.enrollments[1].0.visibleChat?.storedID == "stored")
        #expect(service.enrollments[2].0.visibleChat == nil && service.enrollments[2].0.visibleUntil == 0)
    }
    private func foregroundEnvelope(_ destination: PushDestination, pairing: PushPairing) throws -> PushEnvelope {
        let installation = try #require(pairing.installationID)
        let event = String(repeating: "c", count: 64)
        let aad = "botto-push:v1\n\(installation)\n\(pairing.deviceID)\n\(pairing.generation)\n\(event)"
        let preview = PushPreview(title: "Fixture", body: "Ready", destination: destination)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(preview), using: SymmetricKey(data: pairing.key),
            authenticating: Data(aad.utf8))
        return .init(installationID: installation, deviceID: pairing.deviceID, generation: pairing.generation,
            eventID: event, kind: .reply, expiresAt: 1_900_003_600,
            sealed: try #require(sealed.combined).base64EncodedString())
    }

    @Test func foregroundSuppressionUsesTheCanonicalChatAcrossCompressionTips() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        await coordinator.enable()
        let first = try #require(vault.state.pairings.first { $0.host.profileID == "bot" })
        await coordinator.selectProfile("other")
        await coordinator.enable()
        let other = try #require(vault.state.pairings.first { $0.host.profileID == "other" })
        coordinator.updateVisibility(destination: .init(profileID: "bot", rootID: "root", storedID: "new-tip"))

        #expect(!coordinator.shouldPresent(try foregroundEnvelope(.init(profileID: "bot", rootID: "root", storedID: "old-tip"), pairing: first)))
        #expect(coordinator.shouldPresent(try foregroundEnvelope(.init(profileID: "bot", rootID: "another-root", storedID: "old-tip"), pairing: first)))
        #expect(coordinator.shouldPresent(try foregroundEnvelope(.init(profileID: "other", rootID: "root", storedID: "old-tip"), pairing: other)))
    }

    @Test func foregroundSuppressionPreservesByteExactCanonicalRoots() async throws {
        let vault = PushMemoryVault(), service = PushFixtureService(), coordinator = controller(vault)
        await bind(coordinator, service: service)
        await coordinator.enable()
        let pairing = try #require(vault.state.pairings.first)
        coordinator.updateVisibility(destination: .init(profileID: "bot", rootID: "e\u{301}", storedID: "tip"))

        #expect(coordinator.shouldPresent(try foregroundEnvelope(.init(profileID: "bot", rootID: "\u{e9}", storedID: "tip"), pairing: pairing)))
    }

}
