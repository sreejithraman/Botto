import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct AvatarGenerationModelTests {
    private let cat = #"{"version":1,"id":"cat","name":"Cat","body":{"path":"M18 30 L18 14 Q18 10 24 14 L34 24 L66 24 L76 14 Q82 10 82 18 L82 72 Q82 86 68 86 L32 86 Q18 86 18 72 Z"},"eyes":{"x":50,"y":48,"spacing":16,"scale":1}}"#

    @Test func failureKeepsTheDescriptionAndAllowsADeliberateRetry() async throws {
        let model = AvatarGenerationModel()
        model.description = "A sleepy cat"
        var accepted: [String] = []
        await model.generate(using: { prompt in
            #expect(prompt == "A sleepy cat")
            throw GenerationFailure()
        }, accept: { accepted.append($0.name) })
        #expect(model.description == "A sleepy cat")
        #expect(model.error == "The provider is unavailable.")
        #expect(!model.isGenerating && accepted.isEmpty)

        let geometry = try BotAvatarGeometry(json: cat)
        await model.generate(using: { _ in geometry }, accept: { accepted.append($0.name) })
        #expect(model.error == nil && accepted == ["Cat"])
    }

    @Test func duplicateGenerateDoesNotStartAnotherRequest() async throws {
        let model = AvatarGenerationModel()
        model.description = "A cat"
        let barrier = StoreTestBarrier()
        let geometry = try BotAvatarGeometry(json: cat)
        var requests = 0, accepted = 0
        let first = Task {
            await model.generate(using: { _ in
                requests += 1
                await barrier.wait()
                return geometry
            }, accept: { _ in accepted += 1 })
        }
        #expect(await barrier.waitUntilEntered(timeout: .seconds(2)))
        await model.generate(using: { _ in requests += 1; return geometry }, accept: { _ in accepted += 1 })
        #expect(requests == 1 && model.isGenerating)
        barrier.release()
        await first.value
        #expect(accepted == 1 && !model.isGenerating)
    }

    @Test(arguments: [false, true])
    func cancellationAndPromptReplacementRejectALateSuccess(replacePrompt: Bool) async throws {
        let model = AvatarGenerationModel()
        model.description = "A cat"
        let barrier = StoreTestBarrier()
        let geometry = try BotAvatarGeometry(json: cat)
        var accepted = 0
        let run = Task {
            await model.generate(using: { _ in
                await barrier.wait()
                return geometry
            }, accept: { _ in accepted += 1 })
        }
        #expect(await barrier.waitUntilEntered(timeout: .seconds(2)))
        if replacePrompt { model.description = "A dragon" }
        else { model.cancel() }
        #expect(!model.isGenerating)
        barrier.release()
        await run.value
        #expect(accepted == 0 && model.error == nil)
        #expect(model.description == (replacePrompt ? "A dragon" : "A cat"))
    }

    @Test func aRetiredFailureCannotReplaceANewerSuccess() async throws {
        let model = AvatarGenerationModel()
        model.description = "A cat"
        let barrier = StoreTestBarrier()
        let geometry = try BotAvatarGeometry(json: cat)
        var accepted: [String] = []
        let old = Task {
            await model.generate(using: { _ in
                await barrier.wait()
                throw GenerationFailure()
            }, accept: { accepted.append($0.name) })
        }
        #expect(await barrier.waitUntilEntered(timeout: .seconds(2)))
        model.cancel()
        await model.generate(using: { _ in geometry }, accept: { accepted.append($0.name) })
        barrier.release()
        await old.value
        #expect(accepted == ["Cat"] && model.error == nil && !model.isGenerating)
    }

    private struct GenerationFailure: LocalizedError {
        var errorDescription: String? { "The provider is unavailable." }
    }
}
