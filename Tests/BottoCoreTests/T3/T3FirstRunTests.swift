import Foundation
import Testing
@testable import BottoCore

struct T3FirstRunTests {
    private func space(_ title: String, main: Bool = true, preview: String = "", archived: Bool = false,
                       status: BotStatus = .idle) -> T3ChannelSummary {
        T3ChannelSummary(id: title + "\(main)", title: title, isMain: main, isPinned: false, isArchived: archived,
                         isUnread: false, status: status, preview: preview, updatedAt: nil)
    }

    @Test func onlyAnUntouchedBotNeedsSetup() {
        let fresh = BotProfile(id: "bot", name: "Botto")
        #expect(T3FirstRun.needsBotSetup(fresh, spaces: []))
        #expect(T3FirstRun.needsBotSetup(fresh, spaces: [space("Botto")]))
        // Spaces alone say nothing; bot.json does.
        #expect(T3FirstRun.needsBotSetup(fresh, spaces: [space("Miso"), space("Kyoto", main: false)]))

        #expect(!T3FirstRun.needsBotSetup(BotProfile(id: "bot", name: "Miso"), spaces: []))
        #expect(!T3FirstRun.needsBotSetup(BotProfile(id: "bot", name: "Botto", appearance: BotAppearance(shape: .drop)), spaces: []))
        // Someone has already been talking.
        #expect(!T3FirstRun.needsBotSetup(fresh, spaces: [space("Botto", preview: "Hello")]))
        #expect(!T3FirstRun.needsBotSetup(fresh, spaces: [space("Botto", status: .working)]))
        #expect(!T3FirstRun.needsBotSetup(fresh, spaces: [space("Botto"), space("Old", main: false, preview: "Hi", archived: true)]))
    }

    @Test func providersReadAsWhatSomeoneStillHasToDo() throws {
        func state(_ json: String) throws -> T3ProviderStatus.State? {
            T3ProviderStatus(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))?.state
        }
        let models = #""models":[{"slug":"m"}]"#
        #expect(try state(#"{"instanceId":"a","enabled":true,"installed":true,"status":"ready","auth":{"status":"authenticated"},\#(models)}"#) == .ready)
        // Some providers can't say whether they are signed in.
        #expect(try state(#"{"instanceId":"a","enabled":true,"installed":true,"status":"warning","auth":{"status":"unknown"},\#(models)}"#) == .ready)
        #expect(try state(#"{"instanceId":"a","enabled":true,"installed":true,"status":"error","auth":{"status":"unauthenticated"},\#(models)}"#) == .needsSignIn)
        #expect(try state(#"{"instanceId":"a","enabled":true,"installed":true,"status":"error","auth":{"status":"unknown"},\#(models)}"#) == .notWorking)
        #expect(try state(#"{"instanceId":"a","enabled":true,"installed":false,"status":"error","auth":{"status":"unknown"},\#(models)}"#) == .notInstalled)
        #expect(try state(#"{"instanceId":"a","enabled":false,"installed":false,"status":"disabled","auth":{"status":"unknown"},"models":[]}"#) == .off)
        #expect(try state("{}") == nil)
    }

    @Test func setupFailuresStayPlain() {
        #expect(T3FirstRun.message(for: T3ServiceError.invalidName) == "Enter a name.")
        let failures: [any Error] = [T3ServiceError.disconnected, ConversationServiceError.uncertain, T3RPCError.timeout, T3RPCError.transport,
                                     T3RPCError.remote(tag: "Dispatch", message: "T3 Code refused")]
        for failure in failures { #expect(!T3FirstRun.message(for: failure).contains("T3")) }
    }

    @Test func guidanceWaitsUntilNothingWorks() {
        func provider(_ driver: String, _ state: T3ProviderStatus.State) -> T3ProviderStatus {
            .init(id: driver, driver: driver, state: state)
        }
        let missing = [provider("codex", .notInstalled), provider("claudeAgent", .needsSignIn)]
        #expect(T3FirstRun.providersNeedingSetup(missing) == missing)
        #expect(T3FirstRun.providersNeedingSetup(missing + [provider("cursor", .notInstalled)]) == missing)
        #expect(T3FirstRun.providersNeedingSetup(missing + [provider("cursor", .ready)]).isEmpty)
        #expect(T3FirstRun.providersNeedingSetup([]).isEmpty)
    }
}
