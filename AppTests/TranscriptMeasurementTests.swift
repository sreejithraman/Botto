#if DEBUG
import Testing
import SwiftUI
import UIKit
import CryptoKit
import BottoCore
import Darwin
@testable import Botto

/// Explicitly opt in through a copied xctestrun environment. Ordinary AppTests
/// skip this measurement; no benchmark control enters the product UI.
@Suite(.serialized, RichReplyRuntime()) @MainActor struct TranscriptMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTTO_TRANSCRIPT_BENCH"] == "1"))
    func matchedMixedRichHistory() async throws {
        let env = ProcessInfo.processInfo.environment
        let count = try #require(Int(env["BOTTO_TRANSCRIPT_COUNT"] ?? ""))
        try #require([100, 1000, 10000].contains(count))
        let native = env["BOTTO_TRANSCRIPT_NATIVE"] == "1"
        let repetition = env["BOTTO_TRANSCRIPT_REPETITION"] ?? "0"
        let output = try #require(env["BOTTO_TRANSCRIPT_OUTPUT"])
        var result: [String: Any] = ["count": count, "native": native, "repetition": repetition,
            "configuration": "Debug/-Onone; identical opt-in instrumentation; verbose geometry logs disabled",
            "viewport_points": [380, 434], "pid": ProcessInfo.processInfo.processIdentifier,
            "start_utc": Date().ISO8601Format(), "process_cache": "fresh test process; OS WebKit process/cache may be warm"]
        let demo = DemoBotService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://transcript-measurement.invalid")!)
        _ = try await demo.connect(configuration: configuration)
        let opened = try await demo.openChat(.canonical(profile: ExactID("canvas"), expectedRoot: nil))
        let rich = try #require(opened.snapshot.messages.first { ReplyContent(message: $0).blocks.contains { $0.filePreview?.isHTML == true } })
        let file = try #require(ReplyContent(message: rich).blocks.first { $0.filePreview?.isHTML == true }?.filePreview)
        let html = try await demo.downloadArtifact(file.attachment, access: opened.access)
        demo.disconnect()
        let construction = ContinuousClock.now
        let messages = TranscriptMeasurementFixture.messages(count: count, rich: rich)
        result["construction_ms"] = milliseconds(since: construction)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(messages)
        result["message_bytes"] = encoded.count
        result["snapshot_sha256"] = digest(encoded); result["html_sha256"] = digest(html.data)
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.snapshots[identity.root] = .init(id: identity.root.text, storedID: identity.stored.text,
            profileID: identity.profile.text, messages: messages)
        service.downloadData = html.data
        let memoryBefore = memory()
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        let ingest = ContinuousClock.now
        try #require(await store.connect(configuration)); let bot = try #require(store.bots.first)
        await store.open(bot)
        let screen = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(screen.owner); store.chats.displayed(screen.owner)
        result["ingestion_ms"] = milliseconds(since: ingest)
        result["memory_before_ingestion"] = memoryBefore; result["memory_after_ingestion"] = memory()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let measurement = TranscriptMeasurements(); TranscriptMeasurements.current = measurement; measurement.start()
        let viewport = Viewport(), window = UIWindow(windowScene: scene)
        var host: UIHostingController<Host>? = UIHostingController(rootView: Host(store: store, bot: bot, native: native, viewport: viewport))
        let mount = ContinuousClock.now
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { measurement.stop(); TranscriptMeasurements.current = nil; window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let last = try #require(messages.last)
        let initial = await endpoint(measurement, message: last)
        result["initial_endpoint_success"] = initial; result["mount_to_actual_tail_ms"] = milliseconds(since: mount)
        result["initial_counts"] = measurement.counts(); result["memory_initial"] = memory()
        if let gate = env["BOTTO_TRANSCRIPT_HEAP_HOLD"] {
            // Profiling only: let the external native heap tool capture this
            // exact mounted state. This gate is outside all timing comparisons.
            print("TRANSCRIPT_HEAP_READY pid=\(ProcessInfo.processInfo.processIdentifier) count=\(count) initial=\(initial)")
            NSLog("TRANSCRIPT_HEAP_READY pid=%d count=%d initial=%d", ProcessInfo.processInfo.processIdentifier, count, initial ? 1 : 0)
            let ready: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "count": count,
                "actual_model_count": store.chats.screen(profile: service.profile)?.snapshot?.messages.count ?? -1,
                "initial_endpoint": initial]
            try JSONSerialization.data(withJSONObject: ready).write(to: URL(fileURLWithPath: gate + ".ready"))
            let deadline = ContinuousClock.now + .seconds(90)
            while !FileManager.default.fileExists(atPath: gate), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(FileManager.default.fileExists(atPath: gate), "external heap capture must explicitly release its fixture")
        }
        if initial {
            var append = ChatMessage(id: "bench-append", role: .assistant,
                text: "Measured native append.\n\nThe delivered reply is actually visible.", timestamp: Date(timeIntervalSince1970: 1_700_100_000))
            service.snapshots[identity.root]?.messages.append(append)
            let appendStart = ContinuousClock.now
            service.onEvent?(.conversation(try service.publication(identity)))
            let appended = await endpoint(measurement, message: append)
            result["append_endpoint_success"] = appended; result["append_ms"] = milliseconds(since: appendStart)
            var stream: [[String: Any]] = []
            for index in 0..<3 where appended {
                append.text += "\nIncrement \(index): exact current text after same-message self sizing."
                service.snapshots[identity.root]?.messages[count] = append
                service.snapshots[identity.root]?.isWorking = index < 2
                let start = ContinuousClock.now
                service.onEvent?(.conversation(try service.publication(identity)))
                let success = await endpoint(measurement, message: append)
                stream.append(["index": index, "ms": milliseconds(since: start), "success": success])
            }
            result["same_message_updates"] = stream
            let beforeResizeFrame = measurement.frame
            let resize = ContinuousClock.now; viewport.height = 240
            let reflow = await wait(measurement) {
                measurement.frame > beforeResizeFrame + 1 && measurement.point(.terminal)?.viewport?.bounds.height == 240 && measurement.terminalVisible()
            }
            result["viewport_reflow_success"] = reflow; result["viewport_reflow_ms"] = milliseconds(since: resize)
        }
        result["final_counts"] = measurement.counts(); result["memory_final"] = memory(); result["downloads"] = service.downloads
        result["display_frame_intervals_ms"] = measurement.frameIntervals.map { $0 * 1000 }
        result["display_expected_budgets_ms"] = measurement.frameBudgets.map { $0 * 1000 }
        result["memory_scope"] = "App TASK_VM_INFO only; WebContent process RSS not attributed. Live renderer and WK allocations include detached/prefetched instances, not only the mounted tree."
        window.isHidden = true; window.rootViewController = nil; host = nil
        store.forgetConnection()
        for _ in 0..<3 { await measurement.nextFrame() }
        result["after_teardown_counts"] = measurement.counts(); result["memory_after_teardown"] = memory()
        result["finish_utc"] = Date().ISO8601Format()
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        print("TRANSCRIPT_MEASUREMENT \(output) endpoint=\(initial)")
    }
    @MainActor @Observable final class Viewport { var height: CGFloat = 434 }
    private struct Host: View {
        let store: AppStore
        let bot: BotProfile
        let native: Bool
        let viewport: Viewport
        @State private var presentation = WorkspacePresentation()
        var body: some View {
            transcriptFixture(store: store, bot: bot, presentation: presentation, native: native)
                .frame(width: 380, height: viewport.height)
                .environment(\.scenePhase, .active).environment(\.dynamicTypeSize, .large)
                .environment(\.colorScheme, .light).environment(\.layoutDirection, .leftToRight)
        }
    }
    private func endpoint(_ measurement: TranscriptMeasurements, message: ChatMessage) async -> Bool {
        await wait(measurement) {
            measurement.visible(.row(Data(message.id.utf8)), revision: Data(message.text.utf8)) && measurement.terminalVisible()
        }
    }
    private func wait(_ measurement: TranscriptMeasurements, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await measurement.nextFrame()
        }
        return condition()
    }
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func memory() -> [String: UInt64] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? ["phys_footprint_bytes": info.phys_footprint, "resident_bytes": info.resident_size] : [:]
    }
}
#endif
