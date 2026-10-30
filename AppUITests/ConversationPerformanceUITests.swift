import XCTest

final class ConversationPerformanceUITests: XCTestCase {
    @MainActor func testLongInternalHistoryOverviewPerformance() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOTTO_SCROLL_UI_BENCH"] == "1")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--performance-demo", "--mixed-history-performance-demo"]
        app.launch()
        defer { app.terminate() }
        let scout = app.buttons["pinned-bot-scout"]
        XCTAssertTrue(scout.waitForExistence(timeout: 10)); scout.tap()
        let composer = app.textViews["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let overview = app.descendants(matching: .any)["chat-picker"]
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            app.buttons["chat-picker-button"].tap()
            XCTAssertTrue(overview.waitForExistence(timeout: 10))
            app.buttons["chat-picker-button"].tap()
            XCTAssertTrue(overview.waitForNonExistence(timeout: 10))
            XCTAssertTrue(composer.isEnabled)
        }
    }

    private var nativePerformance: Bool {
        ProcessInfo.processInfo.environment["BOTTO_NATIVE_PERFORMANCE"] == "1"
    }

    @MainActor private func traceData(app: XCUIApplication, output: String) throws -> Data {
        if nativePerformance {
            let transcript = app.descendants(matching: .any)["chat-transcript"]
            let value = try XCTUnwrap(transcript.value as? String)
            return Data(value.utf8)
        }
        return try Data(contentsOf: URL(fileURLWithPath: output))
    }

    @MainActor func testTypingAndSendingStayResponsiveInLongHistory() throws {
        try XCTSkipUnless(nativePerformance || ProcessInfo.processInfo.environment["BOTTO_SCROLL_UI_BENCH"] == "1")
        continueAfterFailure = false
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        let hold = gate.appendingPathComponent("performance-stream-1.hold")
        if !nativePerformance { try Data().write(to: hold) }
        let output = ProcessInfo.processInfo.environment["BOTTO_TYPING_TRACE_OUTPUT"]
            ?? gate.appendingPathComponent("typing-trace.json").path
        if FileManager.default.fileExists(atPath: output) { try FileManager.default.removeItem(atPath: output) }
        let app = XCUIApplication()
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: gate) }
        app.launchArguments = ["--demo", "--performance-demo", "--reduce-motion"]
        if nativePerformance {
            app.launchEnvironment["BOTTO_NATIVE_PERFORMANCE_MODE"] = "typing"
            app.launchEnvironment["BOTTO_TYPING_TRACE_OUTPUT"] = "accessibility"
        } else {
            app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = gate.path
            app.launchEnvironment["BOTTO_TYPING_TRACE_OUTPUT"] = output
        }
        app.launch()
        let scout = app.buttons["pinned-bot-scout"]
        XCTAssertTrue(scout.waitForExistence(timeout: 10)); scout.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        let draft = String(repeating: "Typing should stay responsive while a conversation has a long history. ", count: 6)
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)
        app.buttons["Send message"].tap()
        if !nativePerformance {
            let marker = gate.appendingPathComponent("performance-stream-1.started")
            let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: marker.path)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 10), .completed)
        }
        XCTAssertTrue(composer.exists)
        XCTAssertEqual(composer.value as? String ?? "", "")
        if !nativePerformance { try FileManager.default.removeItem(at: hold) }
        let reply = app.staticTexts.containing(NSPredicate(format: "label ENDSWITH %@", "Performance stream 1 complete.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        app.buttons["chat-picker-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-picker"].waitForExistence(timeout: 10))

        if nativePerformance {
            app.buttons["chat-picker-button"].tap()
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            XCTAssertTrue(composer.exists)
            XCTAssertEqual(composer.value as? String ?? "", "")
        }
        let data = try traceData(app: app, output: output)
        let trace = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        trace.name = "Native typing and sending frame delivery"; trace.lifetime = .keepAlways; add(trace)
        let sessions = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let editFrames = sessions.flatMap { session -> [[String: Double]] in
            let edits = (session["events"] as? [[String: Any]] ?? [])
                .filter { $0["name"] as? String == "edit" }
                .compactMap { $0["at_ms"] as? Double }
            guard let first = edits.first, let last = edits.last else { return [] }
            return (session["frames"] as? [[String: Double]] ?? []).filter { frame in
                guard let end = frame["at_ms"], let interval = frame["callback_interval_ms"] else { return false }
                return end >= first && end - interval <= last
            }
        }
        let intervals = editFrames.compactMap { $0["callback_interval_ms"] }.sorted()
        let events = sessions.flatMap { $0["events"] as? [[String: Any]] ?? [] }
        XCTAssertGreaterThan(intervals.count, 30)
        let editCount = events.filter { $0["name"] as? String == "edit" }.count
        XCTAssertGreaterThan(editCount, 30)
        XCTAssertEqual(Int(editFrames.reduce(0) { $0 + ($1["edits"] ?? 0) }), editCount,
                       "Every edit must be followed by a measured display callback.")
        let p95 = try XCTUnwrap(intervals.isEmpty ? nil : intervals[Int(Double(intervals.count - 1) * 0.95)])
        let delays = sessions.compactMap { session -> Double? in
            let events = session["events"] as? [[String: Any]] ?? []
            guard let sent = events.first(where: { $0["name"] as? String == "send" })?["at_ms"] as? Double,
                  let cleared = events.first(where: { $0["name"] as? String == "cleared" && ($0["at_ms"] as? Double ?? 0) >= sent })?["at_ms"] as? Double else { return nil }
            return cleared - sent
        }
        let sendDelay = try XCTUnwrap(delays.first)
        print("BOTTO_TYPING_SEND frames=\(intervals.count) p95_ms=\(p95) send_to_clear_ms=\(sendDelay)")
        XCTAssertLessThan(p95, 34)
        XCTAssertLessThan(sendDelay, 200)
    }

    @MainActor func testLongTranscriptScrollPerformance() throws {
        try measureHistoryScrolling(streaming: false)
    }

    @MainActor func testLongTranscriptScrollPerformanceWhileStreaming() throws {
        try measureHistoryScrolling(streaming: true)
    }

    @MainActor func testMixedHistoryScrollPerformance() throws {
        try measureHistoryScrolling(streaming: false, mixed: true, geometry: true)
    }

    @MainActor func testMixedHistoryFrameDelivery() throws {
        try measureHistoryScrolling(streaming: false, mixed: true)
    }

    @MainActor func testHeavyHistoryFrameDelivery() throws {
        try measureHistoryScrolling(streaming: false, heavy: true)
    }

    @MainActor func testHeavyHistoryScrollGeometry() throws {
        try measureHistoryScrolling(streaming: false, geometry: true, heavy: true)
    }

    @MainActor private func measureHistoryScrolling(streaming: Bool, mixed: Bool = false, geometry: Bool = false, heavy: Bool = false) throws {
        try XCTSkipUnless(nativePerformance || ProcessInfo.processInfo.environment["BOTTO_SCROLL_UI_BENCH"] == "1")
        continueAfterFailure = false
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        if streaming && !nativePerformance {
            for iteration in 1...4 {
                try Data().write(to: gate.appendingPathComponent("performance-stream-\(iteration).hold"))
            }
        }
        let app = XCUIApplication()
        addTeardownBlock { app.terminate(); try? FileManager.default.removeItem(at: gate) }
        let output = ProcessInfo.processInfo.environment["BOTTO_SCROLL_TRACE_OUTPUT"]
            ?? gate.appendingPathComponent("scroll-trace.json").path
        if FileManager.default.fileExists(atPath: output) {
            try FileManager.default.removeItem(atPath: output)
        }
        if nativePerformance {
            app.launchEnvironment["BOTTO_NATIVE_PERFORMANCE_MODE"] = "scroll"
            app.launchEnvironment["BOTTO_SCROLL_TRACE_OUTPUT"] = "accessibility"
        } else {
            app.launchEnvironment["BOTTO_SCROLL_TRACE_OUTPUT"] = output
            app.launchEnvironment["BOTTO_UI_TEST_BOT_GATE"] = gate.path
        }
        app.launchArguments = ["--demo", "--performance-demo", "--reduce-motion"]
        if mixed {
            app.launchArguments.removeAll { $0 == "--reduce-motion" }
            app.launchArguments.append("--mixed-history-performance-demo")
            app.launchArguments.append(contentsOf: ["-botto.appearance", "dark"])
        }
        if heavy { app.launchArguments.append("--heavy-history-performance-demo") }
        if geometry {
            app.launchEnvironment["BOTTO_SCROLL_GEOMETRY_TRACE"] = "1"
        }
        app.launch()
        let scout = app.buttons["Scout, pinned"]
        XCTAssertTrue(scout.waitForExistence(timeout: 10))
        scout.tap()
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let transcript = app.descendants(matching: .any)["chat-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        var iteration = 0
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            iteration += 1
            if streaming {
                let latest = app.buttons["Latest messages"]
                if latest.exists { latest.tap() }
                composer.tap()
                composer.typeText("Scroll stream \(iteration)")
                app.buttons["Send message"].tap()
                if nativePerformance {
                    let paused = app.staticTexts.containing(NSPredicate(
                        format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", "Word 19.", "Word 20."
                    )).firstMatch
                    XCTAssertTrue(paused.waitForExistence(timeout: 10))
                } else {
                    let marker = gate.appendingPathComponent("performance-stream-\(iteration).started")
                    let waiting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        FileManager.default.fileExists(atPath: marker.path)
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [waiting], timeout: 10), .completed)
                    let hold = gate.appendingPathComponent("performance-stream-\(iteration).hold")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        try? FileManager.default.removeItem(at: hold)
                    }
                }
            }
            transcript.swipeDown(velocity: mixed ? .slow : .fast)
            transcript.swipeDown(velocity: mixed ? .slow : .fast)
            if mixed { transcript.swipeUp(velocity: .slow) }
            else { transcript.swipeDown(velocity: .fast) }
            if heavy {
                transcript.swipeDown(velocity: .fast)
                transcript.swipeDown(velocity: .fast)
            }
            if streaming { XCTAssertTrue(app.buttons["Send message"].waitForExistence(timeout: 20)) }
        }
        XCTAssertTrue(composer.isHittable)
        if streaming || mixed || heavy {
            let data = try traceData(app: app, output: output)
            let trace = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            trace.name = heavy ? "Native heavy history frame delivery" : mixed ? "Native mixed history frame delivery" : "Native scroll frame delivery"; trace.lifetime = .keepAlways
            add(trace)
            let gestures = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            let streamingFrames = gestures.flatMap { $0["frames"] as? [[String: Double]] ?? [] }
                .filter { !streaming || $0["streaming"] == 1 }
            let intervals = streamingFrames.compactMap { $0["callback_interval_ms"] }.sorted()
            if geometry {
                let geometry = gestures.compactMap { $0["geometry"] as? [String: Double] }
                let rows = geometry.reduce(0) { $0 + ($1["frame_qualifying_rows"] ?? 0) }
                let pairs = geometry.reduce(0) { $0 + ($1["frame_qualifying_pairs"] ?? 0) }
                let slip = try XCTUnwrap(geometry.compactMap { $0["max_drag_slip_points"] }.max())
                print("BOTTO_MIXED_DRAG rows=\(rows) pairs=\(pairs) max_slip_pt=\(slip)")
                XCTAssertGreaterThan(rows, 0, "Real drag frames must exercise the geometry check.")
                XCTAssertGreaterThan(pairs, 0)
                XCTAssertLessThan(slip, 2, "A retained visible row must follow finger movement across settled drag frames.")
            }
            if streaming {
                XCTAssertGreaterThan(streamingFrames.reduce(0) { $0 + ($1["stream_publications"] ?? 0) }, 30,
                                     "The measured gestures must overlap actual incoming reply publications.")
            }
            XCTAssertGreaterThan(intervals.count, 30, "The measured gestures must include enough display callbacks.")
            if heavy {
                XCTAssertEqual(gestures.count, iteration * 5, "Every requested gesture must produce a completed trace.")
                XCTAssertGreaterThan(intervals.count, 1_000)
                for gesture in gestures {
                    let start = try XCTUnwrap(gesture["start_offset_y"] as? Double)
                    let end = try XCTUnwrap(gesture["end_offset_y"] as? Double)
                    XCTAssertGreaterThan(abs(end - start), 500, "Every gesture must move the actual transcript.")
                }
                let question = app.descendants(matching: .any)["transcript-message-heavy-29-question"]
                XCTAssertTrue(question.exists)
                XCTAssertTrue(question.frame.intersects(transcript.frame), "Scrolling must cross the tool rows into the preceding long question.")
            }
            if let maximum = intervals.last {
                let p95 = intervals[Int(Double(intervals.count - 1) * 0.95)]
                let p99 = intervals[Int(Double(intervals.count - 1) * 0.99)]
                print("BOTTO_\(heavy ? "HEAVY" : mixed ? "MIXED" : "STREAM")_SCROLL frames=\(intervals.count) p95_ms=\(p95) p99_ms=\(p99) max_ms=\(maximum)")
                XCTAssertLessThan(p95, 34, "At least 95% of scroll callbacks must arrive within two 60 Hz frames.")
                if heavy {
                    XCTAssertLessThan(maximum, 100, "A long passage entering the viewport must not stall scrolling for 100 ms.")
                }
            }
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Older history after measured scrolling"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if streaming {
            let latest = app.buttons["Latest messages"]
            if latest.exists { latest.tap() }
            let completion = "Performance stream \(iteration) complete."
            let reply = app.staticTexts.containing(NSPredicate(format: "label ENDSWITH %@", completion)).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 10))
            XCTAssertTrue(reply.isHittable)
        }
    }

}
