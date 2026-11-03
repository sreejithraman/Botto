import Foundation
import Testing
#if os(macOS)
import Darwin
#endif
@testable import BottoCore

@Suite(.serialized) struct OpenBotAvatarEngineTests {
    private struct Reference: Decodable {
        let definition: BotAvatarGeometry
        let options: BotAvatarFrameOptions
        let frame: BotAvatarRenderFrame
        let paths: [String: BotAvatarVectorPath]
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/OpenBotAvatar"))
        return try Data(contentsOf: url)
    }

    @Test func canonicalDefinitionsAcceptTheCompleteOfficialExamplesAndGallery() async throws {
        let engine = BotAvatarEngine()
        let examples = try JSONDecoder().decode([BotAvatarGeometry].self, from: fixture("official-examples"))
        var definitions = examples
        for name in ["book", "brain", "bull", "bunny", "camera", "cat", "cloud", "ghost", "magnifier", "paint-brush", "palette", "rocket", "shield", "star", "witch-hat"] {
            definitions.append(try BotAvatarGeometry(json: String(decoding: fixture(name), as: UTF8.self)))
        }
        for definition in definitions {
            let normalized = try await engine.validate(definition)
            #expect(normalized.id == definition.id)
            #expect(normalized.name == definition.name)
        }
        #expect(await engine.executedOnMainThread == false)
    }

    @Test func canonicalValidationRejectsStructurallyDecodedInvalidGeometry() async throws {
        let engine = BotAvatarEngine()
        let tiny = try BotAvatarGeometry(json: #"{"version":1,"id":"tiny","name":"Tiny","body":{"path":"M40 40H45V45H40Z"},"eyes":{"x":42,"y":42,"spacing":1,"scale":1}}"#)
        await #expect(throws: BotAvatarEngineError.self) { try await engine.validate(tiny) }
        await #expect(throws: BotAvatarEngineError.self) { try await engine.prepare(tiny) }
    }

    @Test func postValidationJavaScriptFailureCanRetryWithoutRejectingTheDefinition() async throws {
        let worker = JavaScriptAvatarWorker(transformSource: { source in
            source + """
            ;const originalStringify = JSON.stringify;
            let failPreparedReply = true;
            JSON.stringify = function(value, ...args) {
              if (failPreparedReply && value?.ok === true && value.value?.restingFrame) {
                failPreparedReply = false;
                throw new Error('Injected post-validation renderer failure');
              }
              return originalStringify.call(JSON, value, ...args);
            };
            """
        })
        let engine = BotAvatarEngine(capacity: 1, factory: { _ in worker })
        let geometry = BotAvatarCatalog.geometry(for: .circle)
        let validated = try await worker.validate(geometry)
        #expect(validated.id == geometry.id)
        do {
            _ = try await engine.prepare(geometry)
            Issue.record("The injected post-validation failure must reach the worker boundary.")
        } catch {
            #expect(error as? BotAvatarEngineError == .invalidFrame,
                    "A renderer exception must remain eligible for requested-character recovery.")
        }
        #expect(try await engine.prepare(geometry).geometry == geometry)

        let tiny = try BotAvatarGeometry(json: #"{"version":1,"id":"tiny","name":"Tiny","body":{"path":"M40 40H45V45H40Z"},"eyes":{"x":42,"y":42,"spacing":1,"scale":1}}"#)
        do {
            _ = try await engine.prepare(tiny)
            Issue.record("The canonical validator must reject the invalid definition.")
        } catch {
            guard case .invalidDefinition(let errors) = error as? BotAvatarEngineError else {
                Issue.record("Actual validator rejection must preserve its error kind."); return
            }
            #expect(!errors.isEmpty)
        }
    }

    @Test func numericFramesMatchTheIndependentNodeReference() async throws {
        let references = try JSONDecoder().decode([Reference].self, from: fixture("node-reference"))
        let engine = BotAvatarEngine()
        for reference in references {
            let asset = try await engine.prepare(reference.definition)
            let actual = try await engine.frame(reference.definition, options: reference.options)
            #expect(actual.name == reference.frame.name)
            assertMatrix(actual.root, reference.frame.root)
            #expect(actual.shapes.count == reference.frame.shapes.count)
            for (received, expected) in zip(actual.shapes, reference.frame.shapes) {
                switch (received, expected) {
                case let (.slice(key, path, matrix), .slice(expectedKey, expectedPath, expectedMatrix)):
                    #expect(key == expectedKey)
                    #expect(asset.paths[path] == reference.paths[expectedPath])
                    assertMatrix(matrix, expectedMatrix)
                case let (.eye(key, matrix, mark), .eye(expectedKey, expectedMatrix, expectedMark)):
                    #expect(key == expectedKey)
                    assertMatrix(matrix, expectedMatrix)
                    #expect(mark == expectedMark)
                default: Issue.record("Canonical back-to-front shape order changed")
                }
            }
        }
    }

    @Test func bundledPresetsCoverEveryFamilyAndRetainTheCanonicalRestFrame() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var assets: [BotAvatarDrawingAsset] = []
        for shape in BotAvatarShape.allCases {
            let geometry = BotAvatarCatalog.geometry(for: shape)
            let asset = try #require(BotAvatarEngine.bundledAsset(for: geometry))
            #expect(asset.geometry == geometry)
            #expect(asset.restingBounds.maxX > asset.restingBounds.minX)
            for drawing in asset.restingFrame.shapes {
                if case .slice(_, let path, _) = drawing { #expect(asset.paths[path] != nil) }
            }
            assets.append(asset)
        }
        print("BOTTO_AVATAR_BUNDLED_DECODE \(start.duration(to: clock.now)) count=\(assets.count)")
        let engine = BotAvatarEngine()
        for asset in assets {
            let frame = try await engine.frame(asset.geometry, options: .init(reducedMotion: true))
            #expect(frame == asset.restingFrame)
        }
    }

    @Test func warmVisibleWorkloadRemainsOffMainAndUsesPreparedPathReferences() async throws {
        let engine = BotAvatarEngine()
        let definitions = BotAvatarShape.allCases.map { BotAvatarCatalog.geometry(for: $0) }
        let clock = ContinuousClock()
        let initialRSS = residentBytes()
        let coldStart = clock.now
        for definition in definitions { _ = try await engine.prepare(definition) }
        let cold = coldStart.duration(to: clock.now)
        let residentRSS = residentBytes()
        let warmStart = clock.now
        let shapeCount = try await drawVisibleWorkload(engine, definitions: definitions)
        let warm = warmStart.duration(to: clock.now)
        let cat = try BotAvatarGeometry(json: String(decoding: fixture("cat"), as: UTF8.self))
        let background = Task { try await engine.prepare(cat) }
        let contendedStart = clock.now
        let contendedShapes = try await drawVisibleWorkload(engine, definitions: definitions)
        let contended = contendedStart.duration(to: clock.now)
        _ = try await background.value
        print("BOTTO_AVATAR_11_VISIBLE cold=\(cold) warm330frames=\(warm) duringCold330frames=\(contended) shapes=\(shapeCount)/\(contendedShapes) rssBefore=\(initialRSS) rss10VMs=\(residentRSS) deltaPerVM=\((residentRSS - initialRSS) / 10)")
        #expect(shapeCount > 660)
        #expect(await engine.executedOnMainThread == false)
    }

    @Test(.timeLimit(.minutes(1))) func residentFramesBypassBlockedColdDefinitionsAndAlternateDepths() async throws {
        let geometry = BotAvatarCatalog.geometry(for: .circle)
        let preview = try #require(BotAvatarEngine.bundledAsset(for: geometry))
        let gate = ColdPreparationGate()
        let workers = WorkerRegistrations()
        let engine = BotAvatarEngine { key in
            let worker: any AvatarEngineWorker
            if key.definition == geometry.json && key.depth == Double(6).bitPattern {
                worker = JavaScriptAvatarWorker()
            } else {
                worker = GatedAvatarWorker(gate: gate, asset: preview)
            }
            workers.insert(worker, for: key)
            return worker
        }
        _ = try await engine.prepare(geometry)
        let expected = try await engine.frame(geometry, options: .init(time: 1.2, motion: .thinking))
        let first = Task { try await engine.prepare(geometry, depth: 0) }
        let duplicate = Task { try await engine.prepare(geometry, depth: 0) }
        let second = Task { try await engine.prepare(BotAvatarCatalog.geometry(for: .cloud)) }
        let third = Task { try await engine.prepare(BotAvatarCatalog.geometry(for: .triangle)) }
        await gate.waitForStarted(2)
        // This must complete before the test allows either cold worker to finish.
        let actual = try await engine.frame(geometry, options: .init(time: 1.2, motion: .thinking))
        #expect(actual == expected)
        #expect(await gate.started == 2)
        #expect(await gate.active == 2)
        await gate.open()
        _ = try await (first.value, duplicate.value, second.value, third.value)
        #expect(await gate.started == 3)
        #expect(await gate.maximumActive == 2)
        #expect(workers.count == 4)
        _ = try await engine.frame(BotAvatarCatalog.geometry(for: .cloud), options: .init(instanceID: "test-view"))
        await engine.release(instanceID: "test-view")
        #expect(await gate.releases == 1)
        #expect(await engine.executedOnMainThread == false)
    }

    @Test(.timeLimit(.minutes(1))) func slowInstanceCleanupDoesNotPinUnrelatedIdleWorkers() async throws {
        let asset = try #require(BotAvatarEngine.bundledAsset(for: BotAvatarCatalog.geometry(for: .circle)))
        let gate = ColdPreparationGate()
        await gate.open()
        let registrations = WorkerRegistrations()
        let engine = BotAvatarEngine(capacity: 2) { key in
            let worker = GatedAvatarWorker(gate: gate, asset: asset)
            registrations.insert(worker, for: key)
            return worker
        }
        _ = try await engine.frame(BotAvatarCatalog.geometry(for: .circle), options: .init(instanceID: "retiring"))
        _ = try await engine.frame(BotAvatarCatalog.geometry(for: .cloud))
        await gate.holdReleases()
        let cleanup = Task { await engine.release(instanceID: "retiring") }
        await gate.waitForRelease()
        _ = try await engine.frame(BotAvatarCatalog.geometry(for: .triangle), options: .init(instanceID: "new"))
        #expect(registrations.created == 3, "The unrelated idle worker admits a new face before slow cleanup finishes.")
        await gate.openReleases()
        await cleanup.value
    }

    @Test(.timeLimit(.minutes(1))) func fullRegistryWaitsInsteadOfEvictingExecutingWorkers() async throws {
        let preview = try #require(BotAvatarEngine.bundledAsset(for: BotAvatarCatalog.geometry(for: .circle)))
        let gate = ColdPreparationGate()
        let workers = WorkerRegistrations()
        let engine = BotAvatarEngine(capacity: 2) { key in
            let worker = GatedAvatarWorker(gate: gate, asset: preview)
            workers.insert(worker, for: key)
            return worker
        }
        let first = Task { try await engine.frame(BotAvatarCatalog.geometry(for: .circle), options: .init(instanceID: "first")) }
        let second = Task { try await engine.frame(BotAvatarCatalog.geometry(for: .cloud), options: .init(instanceID: "second")) }
        await gate.waitForStarted(2)
        let third = Task { try await engine.frame(BotAvatarCatalog.geometry(for: .triangle), options: .init(instanceID: "third")) }
        while await engine.waitingAdmissionCount == 0 { await Task.yield() }
        #expect(workers.count == 2)
        await engine.release(instanceID: "pending-view")
        #expect(workers.count == 2)
        await gate.open()
        _ = try await (first.value, second.value)
        await engine.release(instanceID: "first")
        _ = try await third.value
        #expect(workers.count == 3)
        #expect(await gate.maximumActive == 2)
    }

    @Test(.timeLimit(.minutes(1))) func thirteenActiveDefinitionsKeepTwelveStableRuntimes() async throws {
        let preview = try restingPreview()
        let gate = ColdPreparationGate()
        await gate.open()
        let workers = WorkerRegistrations()
        let engine = BotAvatarEngine { key in
            let worker = GatedAvatarWorker(gate: gate, asset: preview)
            workers.insert(worker, for: key)
            return worker
        }
        let definitions = try (0..<13).map { try namedGeometry($0) }
        for index in 0..<12 { _ = try await engine.frame(definitions[index], options: .init(instanceID: "owner-\(index)")) }
        let excess = Task { try await engine.frame(definitions[12], options: .init(instanceID: "owner-12")) }
        while await engine.waitingAdmissionCount == 0 { await Task.yield() }
        for _ in 0..<4 {
            for index in 0..<12 { _ = try await engine.frame(definitions[index], options: .init(instanceID: "owner-\(index)")) }
        }
        #expect(workers.created == 12)
        #expect(await engine.residentWorkerCount == 12)
        for worker in workers.gatedWorkers { #expect(await worker.frameCalls == 5) }
        await engine.release(instanceID: "owner-0")
        _ = try await excess.value
        #expect(workers.created == 13)
        #expect(await engine.residentWorkerCount == 12)
        #expect(await gate.started == 13)
    }

    @Test(.timeLimit(.minutes(1))) func foregroundPrepareCompletesWithTwelvePinsAndDropsItsTemporaryWorker() async throws {
        let preview = try restingPreview()
        let readyGate = ColdPreparationGate()
        await readyGate.open()
        let temporaryGate = ColdPreparationGate()
        let residentDefinitions = try (0..<12).map { try namedGeometry($0) }
        let residentKeys = Set(residentDefinitions.map(\.json))
        let probe = WeakWorkerRegistrations()
        let engine = BotAvatarEngine { key in
            let worker = GatedAvatarWorker(gate: residentKeys.contains(key.definition) ? readyGate : temporaryGate, asset: preview)
            probe.insert(worker, for: key)
            return worker
        }
        for index in 0..<12 { _ = try await engine.frame(residentDefinitions[index], options: .init(instanceID: "owner-\(index)")) }
        let generated = try namedGeometry(12)
        let first = Task { try await engine.prepare(generated) }
        let second = Task { try await engine.prepare(namedGeometry(13)) }
        await temporaryGate.waitForStarted(2)
        #expect(await engine.residentWorkerCount == 12)
        #expect(probe.aliveCount == 14)
        let queued = Task { try await engine.prepare(namedGeometry(14)) }
        while await engine.queuedPreparationCount == 0 { await Task.yield() }
        #expect(probe.aliveCount == 14)
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        await temporaryGate.open()
        #expect(try await first.value == preview)
        _ = try await second.value
        while await engine.activePreparationCount != 0 { await Task.yield() }
        #expect(await engine.residentWorkerCount == 12)
        #expect(probe.aliveCount == 12)
        #expect(probe.created == 14)
        let playback = Task { try await engine.frame(generated, options: .init(instanceID: "generated")) }
        while await engine.waitingAdmissionCount == 0 { await Task.yield() }
        #expect(probe.aliveCount == 12)
        playback.cancel()
        await #expect(throws: CancellationError.self) { try await playback.value }
        #expect(await engine.waitingAdmissionCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func lastQueuedConsumerCancelsBeforeItsWorkerIsAllocated() async throws {
        let preview = try restingPreview()
        let gate = ColdPreparationGate()
        let workers = WorkerRegistrations()
        let engine = BotAvatarEngine { key in
            let worker = GatedAvatarWorker(gate: gate, asset: preview)
            workers.insert(worker, for: key)
            return worker
        }
        let first = Task { try await engine.prepare(namedGeometry(0)) }
        let second = Task { try await engine.prepare(namedGeometry(1)) }
        await gate.waitForStarted(2)
        let abandoned = Task { try await engine.prepare(namedGeometry(2)) }
        while await engine.queuedPreparationCount == 0 { await Task.yield() }
        abandoned.cancel()
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        #expect(await engine.queuedPreparationCount == 0)
        #expect(workers.created == 2)
        let replacement = Task { try await engine.prepare(namedGeometry(3)) }
        while await engine.queuedPreparationCount == 0 { await Task.yield() }
        await gate.open()
        _ = try await (first.value, second.value, replacement.value)
        #expect(workers.created == 3)
        #expect(await gate.started == 3)
    }

    @Test(.timeLimit(.minutes(1))) func cancelingOneSharedConsumerPreservesTheOther() async throws {
        let preview = try restingPreview()
        let gate = ColdPreparationGate()
        let workers = WorkerRegistrations()
        let engine = BotAvatarEngine { key in
            let worker = GatedAvatarWorker(gate: gate, asset: preview)
            workers.insert(worker, for: key)
            return worker
        }
        let first = Task { try await engine.prepare(namedGeometry(0)) }
        let second = Task { try await engine.prepare(namedGeometry(1)) }
        await gate.waitForStarted(2)
        let canceled = Task { try await engine.prepare(namedGeometry(2)) }
        let survivor = Task { try await engine.prepare(namedGeometry(2)) }
        while await engine.pendingConsumerCount < 4 { await Task.yield() }
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(await engine.queuedPreparationCount == 1)
        await gate.open()
        _ = try await (first.value, second.value, survivor.value)
        #expect(workers.created == 3)
        #expect(await gate.started == 3)
    }

    @Test(.timeLimit(.minutes(1))) func runningCancellationFinishesItsConsumerBeforeSynchronousWorkEnds() async throws {
        let preview = try restingPreview()
        let gate = ColdPreparationGate()
        let probe = WeakWorkerRegistrations()
        let engine = BotAvatarEngine { key in
            let worker = GatedAvatarWorker(gate: gate, asset: preview)
            probe.insert(worker, for: key)
            return worker
        }
        let request = Task { try await engine.prepare(namedGeometry(0)) }
        await gate.waitForStarted(1)
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await engine.pendingConsumerCount == 0)
        #expect(await engine.activePreparationCount == 1)
        #expect(probe.aliveCount == 1)
        await gate.open()
        while await engine.activePreparationCount != 0 { await Task.yield() }
        #expect(await engine.residentWorkerCount == 0)
        #expect(probe.aliveCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func canceledAndReleasedAdmissionNeverAllocatesAWorker() async throws {
        let preview = try restingPreview()
        let gate = ColdPreparationGate()
        await gate.open()
        let workers = WorkerRegistrations()
        let engine = BotAvatarEngine { key in
            let worker = GatedAvatarWorker(gate: gate, asset: preview)
            workers.insert(worker, for: key)
            return worker
        }
        for index in 0..<12 { _ = try await engine.frame(namedGeometry(index), options: .init(instanceID: "owner-\(index)")) }
        let canceled = Task { try await engine.frame(namedGeometry(12), options: .init(instanceID: "canceled")) }
        while await engine.waitingAdmissionCount == 0 { await Task.yield() }
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        let released = Task { try await engine.frame(namedGeometry(13), options: .init(instanceID: "released")) }
        while await engine.waitingAdmissionCount == 0 { await Task.yield() }
        await engine.release(instanceID: "released")
        await #expect(throws: CancellationError.self) { try await released.value }
        #expect(workers.created == 12)
        let admitted = Task { try await engine.frame(namedGeometry(14), options: .init(instanceID: "admitted")) }
        while await engine.waitingAdmissionCount == 0 { await Task.yield() }
        await engine.release(instanceID: "owner-0")
        _ = try await admitted.value
        #expect(workers.created == 13)
    }

    @Test(.timeLimit(.minutes(1))) func staleAbandonedCompletionCannotPopulateAReplacementJob() async throws {
        let preview = try restingPreview()
        let oldGate = ColdPreparationGate()
        let newGate = ColdPreparationGate()
        let count = WorkerRegistrations()
        let oldAsset = taggedAsset(preview, key: "abandoned")
        let newAsset = taggedAsset(preview, key: "replacement")
        let engine = BotAvatarEngine { key in
            let first = count.created == 0
            let worker = GatedAvatarWorker(gate: first ? oldGate : newGate, asset: first ? oldAsset : newAsset)
            count.insert(worker, for: key)
            return worker
        }
        let geometry = try namedGeometry(0)
        let abandoned = Task { try await engine.prepare(geometry) }
        await oldGate.waitForStarted(1)
        abandoned.cancel()
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        let replacement = Task { try await engine.prepare(geometry) }
        await newGate.waitForStarted(1)
        await oldGate.open()
        while await engine.activePreparationCount != 1 { await Task.yield() }
        #expect(await engine.pendingConsumerCount == 1)
        #expect(await engine.residentWorkerCount == 0)
        await newGate.open()
        #expect(try await replacement.value.key == "replacement")
        #expect(try await engine.prepare(geometry).key == "replacement")
        #expect(count.created == 2)
    }

    @Test(.timeLimit(.minutes(1))) func sharedOwnersAndDistinctDepthsRetainIndependentPins() async throws {
        let preview = try restingPreview()
        let gate = ColdPreparationGate()
        await gate.open()
        let workers = WorkerRegistrations()
        let engine = BotAvatarEngine(capacity: 2) { key in
            let worker = GatedAvatarWorker(gate: gate, asset: preview)
            workers.insert(worker, for: key)
            return worker
        }
        let geometry = try namedGeometry(0)
        _ = try await engine.frame(geometry, options: .init(instanceID: "shared-a"))
        _ = try await engine.frame(geometry, options: .init(instanceID: "shared-b"))
        _ = try await engine.frame(geometry, options: .init(depth: 0, instanceID: "other-depth"))
        #expect(workers.created == 2)
        await #expect(throws: BotAvatarEngineError.self) {
            try await engine.frame(geometry, options: .init(depth: 0, instanceID: "shared-a"))
        }
        let waiting = Task { try await engine.frame(namedGeometry(1), options: .init(instanceID: "waiting")) }
        while await engine.waitingAdmissionCount == 0 { await Task.yield() }
        await engine.release(instanceID: "shared-a")
        #expect(workers.created == 2)
        #expect(await engine.waitingAdmissionCount == 1)
        _ = try await engine.frame(geometry, options: .init(instanceID: "shared-b"))
        await engine.release(instanceID: "shared-b")
        _ = try await waiting.value
        #expect(workers.created == 3)
    }

    @Test func completeDefinitionKeysPreventSlugCollisionsAndEvictedFramesReprepare() async throws {
        let engine = BotAvatarEngine()
        let circle = BotAvatarCatalog.geometry(for: .circle)
        let cloud = BotAvatarCatalog.geometry(for: .cloud)
        var cloudValue = try #require(JSONSerialization.jsonObject(with: Data(cloud.json.utf8)) as? [String: Any])
        cloudValue["id"] = circle.id
        let collision = try BotAvatarGeometry(json: String(decoding: JSONSerialization.data(withJSONObject: cloudValue), as: UTF8.self))
        let first = try await engine.prepare(circle, depth: 0)
        let other = try await engine.prepare(collision, depth: 0)
        #expect(first.key != other.key)
        #expect(first.outline != other.outline)
        var value = try #require(JSONSerialization.jsonObject(with: Data(circle.json.utf8)) as? [String: Any])
        for index in 0..<34 {
            value["id"] = "eviction-\(index)"
            let definition = try BotAvatarGeometry(json: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
            _ = try await engine.prepare(definition, depth: 0)
        }
        let after = try await engine.frame(circle, options: .init(reducedMotion: true, depth: 0))
        #expect(after == first.restingFrame)
    }

    private func restingPreview() throws -> BotAvatarDrawingAsset {
        try #require(BotAvatarEngine.bundledAsset(for: BotAvatarCatalog.geometry(for: .circle)))
    }

    private func namedGeometry(_ index: Int) throws -> BotAvatarGeometry {
        let original = BotAvatarCatalog.geometry(for: .circle)
        var value = try #require(JSONSerialization.jsonObject(with: Data(original.json.utf8)) as? [String: Any])
        value["id"] = "definition-\(index)"
        return try BotAvatarGeometry(json: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }

    private func taggedAsset(_ asset: BotAvatarDrawingAsset, key: String) -> BotAvatarDrawingAsset {
        BotAvatarDrawingAsset(geometry: asset.geometry, key: key, paths: asset.paths, outline: asset.outline,
            restingBounds: asset.restingBounds, restingFrame: asset.restingFrame, isRestingPreview: asset.isRestingPreview)
    }

    private func drawVisibleWorkload(_ engine: BotAvatarEngine, definitions: [BotAvatarGeometry]) async throws -> Int {
        var shapeCount = 0
        for tick in 0..<30 {
            for definition in definitions + [definitions[0]] {
                let frame = try await engine.frame(definition, options: .init(time: Double(tick) / 30, motion: .thinking))
                shapeCount += frame.shapes.count
            }
        }
        return shapeCount
    }

    private func residentBytes() -> Int64 {
        #if os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
        #else
        return 0
        #endif
    }

    private func assertMatrix(_ actual: BotAvatarAffine, _ expected: BotAvatarAffine) {
        for (a, b) in zip([actual.a, actual.b, actual.c, actual.d, actual.tx, actual.ty],
                          [expected.a, expected.b, expected.c, expected.d, expected.tx, expected.ty]) {
            #expect(abs(a - b) < 1e-10)
        }
    }
}

private actor ColdPreparationGate {
    private(set) var started = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var releases = 0
    private var isOpen = false
    private var releasesHeld = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseObservers: [CheckedContinuation<Void, Never>] = []
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func enter() async {
        started += 1
        active += 1
        maximumActive = max(maximumActive, active)
        let ready = observers.filter { $0.0 <= started }
        observers.removeAll { $0.0 <= started }
        for (_, continuation) in ready { continuation.resume() }
        if !isOpen { await withCheckedContinuation { blocked.append($0) } }
        active -= 1
    }

    func waitForStarted(_ count: Int) async {
        if started < count { await withCheckedContinuation { observers.append((count, $0)) } }
    }

    func open() {
        isOpen = true
        let continuations = blocked
        blocked.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func holdReleases() { releasesHeld = true }
    func waitForRelease() async {
        if releases == 0 { await withCheckedContinuation { releaseObservers.append($0) } }
    }
    func openReleases() {
        releasesHeld = false
        let pending = releaseWaiters; releaseWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func released() async {
        releases += 1
        let observers = releaseObservers; releaseObservers.removeAll()
        for observer in observers { observer.resume() }
        if releasesHeld { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
}

private actor GatedAvatarWorker: AvatarEngineWorker {
    let executedOnMainThread = false
    let gate: ColdPreparationGate
    let asset: BotAvatarDrawingAsset
    private(set) var frameCalls = 0

    init(gate: ColdPreparationGate, asset: BotAvatarDrawingAsset) {
        self.gate = gate; self.asset = asset
    }
    func validate(_ geometry: BotAvatarGeometry) -> BotAvatarGeometry { geometry }
    func prepare(_ geometry: BotAvatarGeometry, depth: Double) async -> BotAvatarDrawingAsset {
        await gate.enter()
        return asset
    }
    func frame(_ geometry: BotAvatarGeometry, options: BotAvatarFrameOptions) -> BotAvatarRenderFrame {
        frameCalls += 1
        return asset.restingFrame
    }
    func release(instanceID: String) async { await gate.released() }
}

private final class WorkerRegistrations: @unchecked Sendable {
    private let lock = NSLock()
    private var workers: [BotAvatarEngine.Key: any AvatarEngineWorker] = [:]
    private var creations = 0
    var count: Int { lock.withLock { workers.count } }
    var created: Int { lock.withLock { creations } }
    var gatedWorkers: [GatedAvatarWorker] { lock.withLock { workers.values.compactMap { $0 as? GatedAvatarWorker } } }
    func insert(_ worker: any AvatarEngineWorker, for key: BotAvatarEngine.Key) {
        lock.withLock { workers[key] = worker; creations += 1 }
    }
}

private final class WeakWorkerRegistrations: @unchecked Sendable {
    private final class Reference {
        weak var worker: AnyObject?
        init(_ worker: any AvatarEngineWorker) { self.worker = worker }
    }
    private let lock = NSLock()
    private var references: [Reference] = []
    var created: Int { lock.withLock { references.count } }
    var aliveCount: Int { lock.withLock { references.filter { $0.worker != nil }.count } }
    func insert(_ worker: any AvatarEngineWorker, for key: BotAvatarEngine.Key) {
        lock.withLock { references.append(Reference(worker)) }
    }
}
