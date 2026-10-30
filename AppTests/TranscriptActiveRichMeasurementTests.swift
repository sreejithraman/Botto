#if DEBUG
import Testing
import SwiftUI
import UIKit
import WebKit
import CryptoKit
import Darwin
import BottoCore
@testable import Botto

/// An opt-in rich-content workload, separate from the baseline transcript measurements.
@Suite(.serialized, RichReplyRuntime()) @MainActor struct TranscriptActiveRichMeasurementTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTTO_TRANSCRIPT_ACTIVE_RICH"] == "1"))
    func actualVisibleFileAtTheEndOfMixedHistory() async throws {
        let env = ProcessInfo.processInfo.environment
        let count = try #require(Int(env["BOTTO_TRANSCRIPT_COUNT"] ?? ""))
        try #require([100, 1000, 10000].contains(count))
        let native = env["BOTTO_TRANSCRIPT_NATIVE"] == "1"
        let output = try #require(env["BOTTO_TRANSCRIPT_OUTPUT"])
        let demo = DemoBotService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://active-rich-measurement.invalid")!)
        _ = try await demo.connect(configuration: configuration)
        let opened = try await demo.openChat(.canonical(profile: ExactID("canvas"), expectedRoot: nil))
        let rich = try #require(opened.snapshot.messages.first { ReplyContent(message: $0).blocks.contains { $0.filePreview?.isHTML == true } })
        let file = try #require(ReplyContent(message: rich).blocks.first { $0.filePreview?.isHTML == true })
        let bytes = try await demo.downloadArtifact(try #require(file.filePreview?.attachment), access: opened.access)
        demo.disconnect()
        let messages = TranscriptMeasurementFixture.messages(count: count, rich: rich, activeRichTail: true)
        let last = try #require(messages.last)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(messages)
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        service.snapshots[identity.root] = .init(id: identity.root.text, storedID: identity.stored.text,
            profileID: identity.profile.text, messages: messages)
        service.downloadData = bytes.data
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration)); let bot = try #require(store.bots.first)
        await store.open(bot)
        let screen = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(screen.owner); store.chats.displayed(screen.owner)
        let ingestedMemory = memory()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
        let meter = TranscriptMeasurements(); TranscriptMeasurements.current = meter; meter.start()
        var host: UIHostingController<Host>? = UIHostingController(rootView: Host(store: store, bot: bot, native: native))
        defer { meter.stop(); TranscriptMeasurements.current = nil; window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let start = ContinuousClock.now
        window.rootViewController = host; window.makeKeyAndVisible()
        var complete = false, samples = 0
        var oracleWindows: [[Double]] = []
        var finalImage: UIImage?, finalWords: [String] = []
        var finalRegion = CGRect.null
        var memoryBeforePixelOracle: [String: UInt64]?
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if meter.terminalVisible(), let marker = meter.point(.block(Data(last.id.utf8), file.id)),
               let viewport = marker.viewport, meter.visible(.row(Data(last.id.utf8))), let view = host?.view,
               let document = webViews(view).first(where: {
                   $0.window === window && $0.convert($0.bounds, to: window).intersects(marker.convert(marker.bounds, to: window))
               }) {
                var visible = document.convert(document.bounds, to: window)
                var ancestor: UIView? = document
                while let current = ancestor {
                    if current.clipsToBounds { visible = visible.intersection(current.convert(current.bounds, to: window)) }
                    ancestor = current.superview
                }
                visible = visible.intersection(viewport.convert(viewport.bounds, to: window)).intersection(window.bounds)
                if meter.isReady(document), !visible.isNull, visible.width > 0, visible.height > 0 {
                    if memoryBeforePixelOracle == nil { memoryBeforePixelOracle = memory() }
                    let oracleStart = CACurrentMediaTime()
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    let observation = try RenderedTranscriptFile.observe(image, in: visible)
                    oracleWindows.append([oracleStart, CACurrentMediaTime()]); samples += 1
                    finalImage = image; finalWords = observation.text; finalRegion = visible
                    if observation.isComplete { complete = true; break }
                }
            }
            await meter.nextFrame()
        }
        let elapsed = milliseconds(since: start)
        let initialMemory = memory(), initialCounts = meter.counts()
        if finalImage == nil {
            finalImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        }
        if let finalImage { try finalImage.pngData()?.write(to: URL(fileURLWithPath: output + ".png")) }
        var result: [String: Any] = ["count": count, "native": native, "repetition": env["BOTTO_TRANSCRIPT_REPETITION"] ?? "0",
            "pid": ProcessInfo.processInfo.processIdentifier, "configuration": "Debug/-Onone; fresh process; OS WebKit cache may be warm",
            "snapshot_sha256": digest(encoded), "html_sha256": digest(bytes.data), "message_bytes": encoded.count,
            "viewport_points": [380, 434], "rendered_endpoint_success": complete, "mount_to_rendered_endpoint_ms": elapsed,
            "endpoint_words": finalWords, "endpoint_region": NSCoder.string(for: finalRegion), "oracle_samples": samples,
            "oracle_windows_uptime_seconds": oracleWindows, "initial_counts": initialCounts, "memory_initial": initialMemory,
            "downloads": service.downloads, "memory_after_ingestion": ingestedMemory, "frame_intervals_ms": meter.frameIntervals.map { $0 * 1000 },
            "frame_sample_times_uptime_seconds": meter.frameSampleTimes, "frame_budgets_ms": meter.frameBudgets.map { $0 * 1000 },
            "measurement_limits": "Endpoint latency includes window snapshot/OCR work, measured separately. No pure layout-latency or unfiltered hitch-rate claim. External RSS sample is outside timed endpoint; app physical footprint and process RSS remain separate units."]
        result["memory_before_pixel_oracle"] = memoryBeforePixelOracle ?? [:]
        result["memory_cost_limits"] = "Use pre-oracle app footprint only for completed endpoints; post-validation app memory includes Vision and snapshot caches. External WebContent RSS is sampled after completed validation and excludes the app OCR process."
        if let gate = env["BOTTO_TRANSCRIPT_RSS_GATE"] {
            let ready: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "count": count,
                "rendered_endpoint": complete, "phase": "active", "counts": initialCounts]
            try JSONSerialization.data(withJSONObject: ready).write(to: URL(fileURLWithPath: gate + ".ready"))
            try await externalCapture(gate)
        }
        window.isHidden = true; window.rootViewController = nil; host = nil; store.forgetConnection()
        for _ in 0..<3 { await meter.nextFrame() }
        result["after_teardown_counts"] = meter.counts(); result["memory_after_teardown"] = memory()
        if let gate = env["BOTTO_TRANSCRIPT_RSS_GATE"] {
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier, "phase": "teardown"]).write(to: URL(fileURLWithPath: gate + ".teardown.ready"))
            try await externalCapture(gate + ".teardown")
        }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        print("ACTIVE_RICH_MEASUREMENT \(output) rendered=\(complete)")
    }
    @Test func sharedFactoryPreservesTheFrozenOriginal100MessageCorpus() async throws {
        let demo = DemoBotService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://corpus-invariance.invalid")!)
        _ = try await demo.connect(configuration: configuration)
        let opened = try await demo.openChat(.canonical(profile: ExactID("canvas"), expectedRoot: nil))
        defer { demo.disconnect() }
        let rich = try #require(opened.snapshot.messages.first { ReplyContent(message: $0).blocks.contains { $0.filePreview?.isHTML == true } })
        let messages = TranscriptMeasurementFixture.messages(count: 100, rich: rich)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
        #expect(digest(try encoder.encode(messages)) == "9220de10fe35de4f5c73ecf971967d1384dacf4cb14326a79791f7cff5286007")
    }
    private struct Host: View {
        let store: AppStore
        let bot: BotProfile
        let native: Bool
        @State private var presentation = WorkspacePresentation()
        var body: some View {
            transcriptFixture(store: store, bot: bot, presentation: presentation, native: native)
                .frame(width: 380, height: 434).environment(\.scenePhase, .active)
                .environment(\.dynamicTypeSize, .large).environment(\.colorScheme, .light)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
    private func externalCapture(_ path: String) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !FileManager.default.fileExists(atPath: path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25)) // Test-only external sampling gate, after timing.
        }
        try #require(FileManager.default.fileExists(atPath: path), "owned external RSS capture must release its fixture")
    }
    private func webViews(_ view: UIView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func memory() -> [String: UInt64] {
        var value = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? ["phys_footprint_bytes": value.phys_footprint, "resident_bytes": value.resident_size] : [:]
    }
}
#endif
