import Foundation
import JavaScriptCore

nonisolated public enum BotAvatarEngineError: Error, LocalizedError, Equatable, Sendable {
    case invalidDefinition([String]), unavailable, invalidFrame

    public var errorDescription: String? {
        switch self {
        case .invalidDefinition: "This character does not meet the Open Bot Avatar format. Try another description."
        case .unavailable: "The character renderer is unavailable."
        case .invalidFrame: "The character could not be drawn."
        }
    }
}

nonisolated protocol AvatarEngineWorker: Actor {
    var executedOnMainThread: Bool { get }
    func validate(_ geometry: BotAvatarGeometry) async throws -> BotAvatarGeometry
    func prepare(_ geometry: BotAvatarGeometry, depth: Double) async throws -> BotAvatarDrawingAsset
    func frame(_ geometry: BotAvatarGeometry, options: BotAvatarFrameOptions) async throws -> BotAvatarRenderFrame
    func release(instanceID: String) async
}

nonisolated private final class AvatarDemandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    var isCancelled: Bool { lock.withLock { canceled } }
    func cancel() { lock.withLock { canceled = true } }
}

/// Owns playback leases and cancellable demand; only running cold jobs allocate VMs.
public actor BotAvatarEngine {
    public static let shared = BotAvatarEngine()
    public nonisolated static let revision = "3a5119877844165eebafe57d3100da475f67d0a8"
    nonisolated struct Key: Hashable, Sendable {
        let definition: String
        let depth: UInt64
    }
    private struct Slot {
        let id = UUID()
        let key: Key
        var worker: (any AvatarEngineWorker)?
        var asset: BotAvatarDrawingAsset?
        var owners: Set<String> = []
        var operations = 0
        var lastUse = 0
    }
    private struct Instance {
        let key: Key
        var consumers: Set<UUID> = []
        var slotID: UUID?
    }
    private enum Demand: Sendable {
        case asset
        case playback(String?)
    }
    private struct Consumer {
        let key: Key
        let geometry: BotAvatarGeometry
        let depth: Double
        let demand: Demand
        let cancellation: AvatarDemandCancellation
        let continuation: CheckedContinuation<Delivery, Error>
        var jobID: UUID?
    }
    private struct Job {
        let id: UUID
        let key: Key
        let geometry: BotAvatarGeometry
        let depth: Double
        var consumers: Set<UUID> = []
        var slotID: UUID?
        var task: Task<Void, Never>?
        var abandoned = false
    }
    private struct Lease: Sendable {
        let key: Key
        let slotID: UUID
        let worker: any AvatarEngineWorker
    }
    private enum Delivery: Sendable {
        case asset(BotAvatarDrawingAsset)
        case lease(Lease)
    }
    private let capacity: Int
    private let factory: @Sendable (Key) -> any AvatarEngineWorker
    private let validator: any AvatarEngineWorker
    private var slots: [Key: Slot] = [:]
    private var instances: [String: Instance] = [:]
    private var consumers: [UUID: Consumer] = [:]
    private var jobs: [UUID: Job] = [:]
    private var pendingByKey: [Key: UUID] = [:]
    private var coldQueue: [UUID] = []
    private var admissionQueue: [UUID] = []
    private var assets: [Key: BotAvatarDrawingAsset] = [:]
    private var assetOrder: [Key] = []
    private var running = 0
    private var sequence = 0
    private(set) var executedOnMainThread = false
    var waitingAdmissionCount: Int { admissionQueue.count }
    var queuedPreparationCount: Int { coldQueue.count }
    var residentWorkerCount: Int { slots.values.filter { $0.worker != nil }.count }
    var activePreparationCount: Int { running }
    var pendingConsumerCount: Int { consumers.count }

    public init() {
        capacity = 12
        factory = { _ in JavaScriptAvatarWorker() }
        validator = JavaScriptAvatarWorker()
    }

    init(capacity: Int = 12, validator: (any AvatarEngineWorker)? = nil,
         factory: @escaping @Sendable (Key) -> any AvatarEngineWorker) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.factory = factory
        self.validator = validator ?? JavaScriptAvatarWorker()
    }

    public func validate(_ geometry: BotAvatarGeometry) async throws -> BotAvatarGeometry {
        let value = try await validator.validate(geometry)
        let ranOnMain = await validator.executedOnMainThread
        executedOnMainThread = executedOnMainThread || ranOnMain
        return value
    }

    /// Returns native paths without requiring an available playback slot.
    public func prepare(_ geometry: BotAvatarGeometry, depth: Double = 6) async throws -> BotAvatarDrawingAsset {
        try Task.checkCancellation()
        let key = try key(for: geometry, depth: depth)
        if let asset = slots[key]?.asset ?? assets[key] { return asset }
        let delivery = try await request(geometry, depth: depth, key: key, demand: .asset)
        guard case .asset(let asset) = delivery else { throw BotAvatarEngineError.invalidFrame }
        try Task.checkCancellation()
        return asset
    }

    /// An instance ID pins this definition/depth until release. Use a fresh ID per view task.
    public func frame(_ geometry: BotAvatarGeometry, options: BotAvatarFrameOptions = .init()) async throws -> BotAvatarRenderFrame {
        let key = try key(for: geometry, depth: options.depth)
        let owner = options.reducedMotion ? nil : options.instanceID
        let delivery = try await request(geometry, depth: options.depth, key: key, demand: .playback(owner))
        guard case .lease(let lease) = delivery else { throw BotAvatarEngineError.invalidFrame }
        defer { endOperation(lease.key, slotID: lease.slotID) }
        try Task.checkCancellation()
        var rendering = options
        if owner == nil { rendering.instanceID = nil }
        let result = try await lease.worker.frame(geometry, options: rendering)
        let ranOnMain = await lease.worker.executedOnMainThread
        executedOnMainThread = executedOnMainThread || ranOnMain
        try Task.checkCancellation()
        return result
    }

    public func release(instanceID: String) async {
        guard let instance = instances.removeValue(forKey: instanceID) else { return }
        var cleanup: Lease?
        if let slot = slots[instance.key], slot.id == instance.slotID, let worker = slot.worker {
            slots[instance.key]?.owners.remove(instanceID)
            slots[instance.key]?.operations += 1
            cleanup = Lease(key: instance.key, slotID: slot.id, worker: worker)
        }
        for token in instance.consumers { cancel(token, schedule: false) }
        drainAdmissions()
        startJobs()
        if let cleanup {
            await cleanup.worker.release(instanceID: instanceID)
            endOperation(cleanup.key, slotID: cleanup.slotID)
        }
    }

    private func key(for geometry: BotAvatarGeometry, depth: Double) throws -> Key {
        guard depth.isFinite else { throw BotAvatarEngineError.invalidFrame }
        return Key(definition: geometry.json, depth: depth.bitPattern)
    }

    private func request(_ geometry: BotAvatarGeometry, depth: Double, key: Key, demand: Demand) async throws -> Delivery {
        let token = UUID()
        let cancellation = AvatarDemandCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if case .playback(let owner?) = demand {
                    if let instance = instances[owner], instance.key != key {
                        continuation.resume(throwing: BotAvatarEngineError.invalidFrame)
                        return
                    }
                    if instances[owner] == nil { instances[owner] = Instance(key: key) }
                    instances[owner]?.consumers.insert(token)
                }
                consumers[token] = Consumer(key: key, geometry: geometry, depth: depth, demand: demand, cancellation: cancellation, continuation: continuation)
                switch demand {
                case .asset: attach(token)
                case .playback: admissionQueue.append(token); drainAdmissions()
                }
                startJobs()
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(token) }
        }
    }

    private func finish(_ token: UUID, _ result: Result<Delivery, Error>) {
        guard let consumer = consumers.removeValue(forKey: token) else { return }
        if case .playback(let owner?) = consumer.demand {
            instances[owner]?.consumers.remove(token)
            if let instance = instances[owner], instance.slotID == nil, instance.consumers.isEmpty { instances[owner] = nil }
        }
        consumer.continuation.resume(with: result)
    }

    private func cancel(_ token: UUID, schedule: Bool = true) {
        guard let consumer = consumers[token] else { return }
        admissionQueue.removeAll { $0 == token }
        if let id = consumer.jobID, var job = jobs[id] {
            job.consumers.remove(token)
            let hasPlayback = job.consumers.contains { id in
                guard let demand = consumers[id]?.demand else { return false }
                if case .playback = demand { return true }
                return false
            }
            if !hasPlayback, let slotID = job.slotID {
                if slots[job.key]?.id == slotID, slots[job.key]?.worker == nil { slots[job.key] = nil }
                job.slotID = nil
            }
            if job.consumers.isEmpty {
                if pendingByKey[job.key] == id { pendingByKey[job.key] = nil }
                if let task = job.task { job.abandoned = true; task.cancel(); jobs[id] = job }
                else { jobs[id] = nil; coldQueue.removeAll { $0 == id } }
            } else { jobs[id] = job }
        }
        finish(token, .failure(CancellationError()))
        if schedule { drainAdmissions(); startJobs() }
    }

    private func availableSlot(for key: Key) -> UUID? {
        if let slot = slots[key] { return slot.id }
        if slots.count >= capacity {
            guard let victim = slots.values.filter({ $0.worker != nil && $0.owners.isEmpty && $0.operations == 0 })
                .min(by: { $0.lastUse < $1.lastUse }) else { return nil }
            slots[victim.key] = nil
        }
        sequence += 1
        slots[key] = Slot(key: key, lastUse: sequence)
        return slots[key]?.id
    }

    private func drainAdmissions() {
        let waiting = admissionQueue
        admissionQueue.removeAll()
        for token in waiting {
            guard let consumer = consumers[token] else { continue }
            if consumer.cancellation.isCancelled { cancel(token, schedule: false); continue }
            guard availableSlot(for: consumer.key) != nil else { admissionQueue.append(token); continue }
            if slots[consumer.key]?.worker != nil { deliverLease(token) }
            else { attach(token) }
        }
    }

    private func attach(_ token: UUID) {
        guard let consumer = consumers[token] else { return }
        let id: UUID
        if let pending = pendingByKey[consumer.key], jobs[pending]?.abandoned == false { id = pending }
        else {
            id = UUID()
            jobs[id] = Job(id: id, key: consumer.key, geometry: consumer.geometry, depth: consumer.depth)
            pendingByKey[consumer.key] = id
            coldQueue.append(id)
        }
        jobs[id]?.consumers.insert(token)
        consumers[token]?.jobID = id
        if case .playback = consumer.demand { jobs[id]?.slotID = slots[consumer.key]?.id }
    }

    private func deliverLease(_ token: UUID) {
        guard let consumer = consumers[token], var slot = slots[consumer.key], let worker = slot.worker else { return }
        if consumer.cancellation.isCancelled { cancel(token, schedule: false); return }
        if case .playback(let owner?) = consumer.demand {
            guard instances[owner]?.key == consumer.key else { finish(token, .failure(CancellationError())); return }
            slot.owners.insert(owner)
            instances[owner]?.slotID = slot.id
        }
        sequence += 1
        slot.lastUse = sequence
        slot.operations += 1
        slots[consumer.key] = slot
        finish(token, .success(.lease(Lease(key: slot.key, slotID: slot.id, worker: worker))))
    }

    private func startJobs() {
        while running < 2, !coldQueue.isEmpty {
            let id = coldQueue.removeFirst()
            guard let job = jobs[id], !job.consumers.isEmpty, !job.abandoned else { continue }
            running += 1
            jobs[id]?.task = Task {
                // Cancellation can precede its actor callback. Read the synchronous flags
                // before allocating a worker, so canceled queued demand starts no JS.
                for token in self.jobs[id]?.consumers ?? [] where self.consumers[token]?.cancellation.isCancelled == true {
                    self.cancel(token, schedule: false)
                }
                guard let current = self.jobs[id], !current.abandoned, !current.consumers.isEmpty else {
                    self.jobs[id] = nil
                    self.executionEnded()
                    return
                }
                var worker: (any AvatarEngineWorker)? = self.factory(current.key)
                let result: Result<BotAvatarDrawingAsset, Error>
                do { result = .success(try await worker!.prepare(current.geometry, depth: current.depth)) }
                catch { result = .failure(error) }
                let ranOnMain = await worker!.executedOnMainThread
                self.executedOnMainThread = self.executedOnMainThread || ranOnMain
                self.complete(id, result: result, worker: worker!)
                worker = nil
                self.executionEnded()
            }
        }
    }

    private func complete(_ id: UUID, result: Result<BotAvatarDrawingAsset, Error>, worker: any AvatarEngineWorker) {
        for token in jobs[id]?.consumers ?? [] where consumers[token]?.cancellation.isCancelled == true {
            cancel(token, schedule: false)
        }
        guard let job = jobs.removeValue(forKey: id) else { return }
        if pendingByKey[job.key] == id { pendingByKey[job.key] = nil }
        guard !job.abandoned, !job.consumers.isEmpty else { return }
        switch result {
        case .failure(let error):
            if let slotID = job.slotID, slots[job.key]?.id == slotID { slots[job.key] = nil }
            for token in job.consumers { finish(token, .failure(error)) }
        case .success(let asset):
            if assets[job.key] == nil { assetOrder.append(job.key) }
            assets[job.key] = asset
            if assetOrder.count > 32 { assets[assetOrder.removeFirst()] = nil }
            if job.slotID == nil { _ = availableSlot(for: job.key) }
            if let slot = slots[job.key], job.slotID == nil || slot.id == job.slotID {
                slots[job.key]?.worker = worker
                slots[job.key]?.asset = asset
            }
            for token in job.consumers {
                guard let consumer = consumers[token] else { continue }
                switch consumer.demand {
                case .asset: finish(token, .success(.asset(asset)))
                case .playback:
                    if slots[job.key]?.worker != nil { deliverLease(token) }
                    else { finish(token, .failure(CancellationError())) }
                }
            }
        }
        drainAdmissions()
    }

    private func executionEnded() {
        running -= 1
        drainAdmissions()
        startJobs()
    }

    private func endOperation(_ key: Key, slotID: UUID) {
        guard slots[key]?.id == slotID else { return }
        slots[key]?.operations -= 1
        drainAdmissions()
        startJobs()
    }

    public nonisolated static func bundledAsset(for geometry: BotAvatarGeometry) -> BotAvatarDrawingAsset? {
        Bundled.assets.first { $0.geometry == geometry }
    }

    private enum Bundled {
        static let assets: [BotAvatarDrawingAsset] = {
            guard let url = Bundle.module.url(forResource: "HermesAvatarFrames", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let assets = try? JSONDecoder().decode([BotAvatarDrawingAsset].self, from: data) else { return [] }
            return assets
        }()
    }

}

actor JavaScriptAvatarWorker: AvatarEngineWorker {
    private var context: JSContext?
    private var module: JSValue?
    private let transformSource: @Sendable (String) -> String
    private(set) var executedOnMainThread = false

    init(transformSource: @escaping @Sendable (String) -> String = { $0 }) {
        self.transformSource = transformSource
    }

    func validate(_ geometry: BotAvatarGeometry) throws -> BotAvatarGeometry {
        try invoke("validate", [geometry.json], as: BotAvatarGeometry.self)
    }

    func prepare(_ geometry: BotAvatarGeometry, depth: Double) throws -> BotAvatarDrawingAsset {
        try invoke("prepare", [geometry.json, depth], as: BotAvatarDrawingAsset.self)
    }

    func frame(_ geometry: BotAvatarGeometry, options: BotAvatarFrameOptions) throws -> BotAvatarRenderFrame {
        let input = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        return try invoke("frame", [geometry.json, input], as: BotAvatarRenderFrame.self)
    }

    func release(instanceID: String) {
        guard let module else { return }
        _ = module.invokeMethod("release", withArguments: [instanceID])
    }

    private func load() throws -> JSValue {
        if let module { return module }
        guard let url = Bundle.module.url(forResource: "OpenBotAvatarEngine", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { throw BotAvatarEngineError.unavailable }
        context.evaluateScript(transformSource(source))
        guard context.exception == nil, let module = context.objectForKeyedSubscript("BottoAvatarEngine"), !module.isUndefined else {
            throw BotAvatarEngineError.unavailable
        }
        self.context = context; self.module = module
        return module
    }

    private struct Answer<Value: Decodable>: Decodable {
        let ok: Bool
        let value: Value?
        let errorKind: String?
        let errors: [String]?
    }

    private func invoke<Value: Decodable>(_ function: String, _ arguments: [Any], as type: Value.Type) throws -> Value {
        try Task.checkCancellation()
        executedOnMainThread = executedOnMainThread || Thread.isMainThread
        let module = try load()
        context?.exception = nil
        guard let text = module.invokeMethod(function, withArguments: arguments)?.toString(),
              context?.exception == nil, text.utf8.count <= 32 * 1024 * 1024 else { throw BotAvatarEngineError.invalidFrame }
        let answer: Answer<Value>
        do { answer = try JSONDecoder().decode(Answer<Value>.self, from: Data(text.utf8)) }
        catch { throw BotAvatarEngineError.invalidFrame }
        try Task.checkCancellation()
        guard answer.ok else {
            if answer.errorKind == "invalidDefinition" { throw BotAvatarEngineError.invalidDefinition(answer.errors ?? []) }
            throw BotAvatarEngineError.invalidFrame
        }
        guard let value = answer.value else { throw BotAvatarEngineError.invalidFrame }
        return value
    }
}
