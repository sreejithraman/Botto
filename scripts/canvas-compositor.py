#!/usr/bin/env python3
"""Record one owned Simulator screen while preserving the original test verdict."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent / "dev-host"))
from process_groups import child_exited, stop_group

SETUP_SECONDS = 300
TEST_SECONDS = 360
POST_TEST_SECONDS = 30
FINALIZE_SECONDS = 5
DISPLAY = "primary"
MEDIA_DECODER = r'''
import Foundation
import ImageIO
import AVFoundation
import CoreGraphics

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8)); exit(1)
}
do {
    let args = CommandLine.arguments
    if args.count != 3 { fail("Expected image|video and an owned media path") }
    let url = URL(fileURLWithPath: args[2])
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let image: CGImage
    if args[1] == "image" {
        if bytes <= 0 || bytes > 16 * 1024 * 1024 { fail("Image byte bound exceeded") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = props[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= 8192, height.intValue <= 8192,
              width.int64Value * height.int64Value <= 16 * 1024 * 1024,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { fail("Image did not decode within bounds") }
        image = decoded
    } else if args[1] == "video" {
        if bytes <= 0 || bytes > 512 * 1024 * 1024 { fail("Video byte bound exceeded") }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { fail("No video track") }
        let size = try await track.load(.naturalSize)
        if !size.width.isFinite || !size.height.isFinite || size.width <= 0 || size.height <= 0 ||
           size.width > 8192 || size.height > 8192 || size.width * size.height > 16 * 1024 * 1024 {
            fail("Video track dimensions exceed bounds")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: .zero)
        image = frame.image
    } else { fail("Expected image or video") }
    let width = image.width, height = image.height
    if width <= 0 || height <= 0 || width > 8192 || height > 8192 || width * height > 16 * 1024 * 1024 {
        fail("Decoded raster dimensions exceed bounds")
    }
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("Could not allocate bounded raster") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard context.data != nil else { fail("No decoded pixels") }
    let result: [String: Any] = ["kind": args[1], "bytes": bytes, "width": width, "height": height,
                                "decoded_pixels": width * height, "decoder": args[1] == "image" ? "ImageIO/CoreGraphics" : "AVFoundation/CoreGraphics"]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
} catch { fail(error.localizedDescription) }
'''


def stamp():
    return {"unix_seconds": time.time(), "monotonic_seconds": time.monotonic()}


def wait_until_exit(process, deadline):
    while not child_exited(process):
        if time.monotonic() >= deadline:
            return False
        time.sleep(.05)
    return True


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, type=uuid.UUID)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("A test command is required after --")
    try:
        if command.count("-destination") != 1:
            raise ValueError("Expected one explicit Simulator destination")
        destination = command[command.index("-destination") + 1]
        parts = dict(part.split("=", 1) for part in destination.split(","))
        if parts.get("platform") != "iOS Simulator" or uuid.UUID(parts["id"]) != args.device:
            raise ValueError("Video device must match the test Simulator destination")
    except (ValueError, KeyError, IndexError) as error:
        parser.error(str(error))
    args.output.mkdir(parents=True, exist_ok=False)
    device = str(args.device).upper()
    video = args.output / "compositor.mp4"
    log = args.output / "recorder.log"
    receipt = {"device": device, "display": DISPLAY, "started": stamp(), "command": command,
               "developer_dir": os.environ.get("DEVELOPER_DIR"), "stages": [],
               "limits": "Documented primary alias binds screenshot and recording; enumeration is retained raw, not parsed into a concrete screen ID. Screenshot may materialize the framebuffer and recording changes host workload. First-frame time observes a stderr marker, not video PTS. No cold, paint or repair claim follows from a green test.",
               "budgets_seconds": {"setup_shared": SETUP_SECONDS, "test": TEST_SECONDS,
                                   "post_test_shared": POST_TEST_SECONDS, "video_finalize_maximum": FINALIZE_SECONDS},
               "first_frame_observed": False, "video_complete": False}
    owned = []
    recorder = None
    native_status = None
    status = 1
    setup_deadline = time.monotonic() + SETUP_SECONDS

    def retire(process, record):
        try:
            if process.returncode is None:
                stop_group(process, grace=0)
        finally:
            record["reaped"] = process.returncode is not None
            record["process_returncode"] = process.returncode
            record["retired"] = stamp()
            record.setdefault("status", process.returncode)
            record.setdefault("finished", record["retired"])

    def stage(name, invocation, deadline):
        record = {"name": name, "command": invocation, "started": stamp(),
                  "remaining_budget_seconds": max(0, deadline - time.monotonic())}
        receipt["stages"].append(record)
        if time.monotonic() >= deadline:
            record.update(status=124, timed_out=True, launched=False, finished=stamp())
            return record
        stdout = args.output / (name + ".stdout")
        stderr = args.output / (name + ".stderr")
        record.update(stdout=stdout.name, stderr=stderr.name)
        with stdout.open("wb") as out, stderr.open("wb") as err:
            try:
                process = subprocess.Popen(invocation, stdout=out, stderr=err, start_new_session=True)
            except OSError as error:
                record.update(status=127, launched=False, error=str(error), finished=stamp())
                raise
            record.update(pid=process.pid, launched=True)
            owned.append((process, record))
            try:
                finished = wait_until_exit(process, deadline)
            finally:
                retire(process, record)
        record.update(status=process.returncode if finished else 124, timed_out=not finished, finished=stamp())
        return record

    def require_stage(name, invocation, deadline):
        result = stage(name, invocation, deadline)
        if result["status"] != 0:
            raise RuntimeError(name + " failed")
        return result

    def decoded(name, kind, path, deadline):
        result = require_stage(name, [str(decoder), kind, str(path)], deadline)
        metadata = json.loads((args.output / result["stdout"]).read_text())
        if not all(isinstance(metadata.get(k), int) and metadata[k] > 0 for k in ("width", "height", "decoded_pixels")):
            raise RuntimeError(name + " returned no positive decoded raster")
        result["decoded_media"] = metadata
        return metadata

    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        policy = stage("renderer-policy", ["defaults", "read", "com.apple.CoreSimulator", "FramebufferServerRendererPolicy"], setup_deadline)
        policy_text = (args.output / policy["stdout"]).read_text().strip() if policy.get("stdout") else ""
        policy_error = (args.output / policy["stderr"]).read_text() if policy.get("stderr") else ""
        if policy["status"] == 0:
            receipt["renderer_policy"] = policy_text
            if policy_text.lower().strip('"') == "none":
                raise RuntimeError("FramebufferServerRendererPolicy is none; no global defaults were changed")
        elif policy["status"] == 1 and "does not exist" in policy_error:
            receipt["renderer_policy"] = "absent (system default; not modified)"
        else:
            raise RuntimeError("Renderer policy could not be read or identified as absent")
        require_stage("simctl-path", ["xcrun", "--find", "simctl"], setup_deadline)
        help_result = require_stage("simctl-io-help", ["xcrun", "simctl", "help", "io"], setup_deadline)
        help_text = (args.output / help_result["stdout"]).read_text() + (args.output / help_result["stderr"]).read_text()
        if not all(text in help_text for text in ('"primary"', "--display", "screenshot", "recordVideo")):
            raise RuntimeError("Selected simctl help does not document the primary screen alias")
        require_stage("boot", ["xcrun", "simctl", "bootstatus", device, "-b"], setup_deadline)
        require_stage("display-enumeration", ["xcrun", "simctl", "io", device, "enumerate"], setup_deadline)
        source = args.output / "decode-media.swift"
        source.write_text(MEDIA_DECODER)
        decoder = (args.output / "decode-media").resolve()
        require_stage("compile-media-decoder", ["xcrun", "swiftc", "-O", str(source), "-o", str(decoder)], setup_deadline)
        screenshot = args.output / "setup-screen.png"
        receipt["setup_screenshot_intervention"] = True
        require_stage("display-screenshot", ["xcrun", "simctl", "io", device, "screenshot",
            "--type=png", "--display=" + DISPLAY, str(screenshot)], setup_deadline)
        receipt["setup_screenshot"] = decoded("decode-screenshot", "image", screenshot, setup_deadline)
        if time.monotonic() >= setup_deadline:
            raise RuntimeError("Shared setup deadline expired before video startup")
        record = {"name": "recorder", "started": stamp(), "stdout": "recorder.stdout", "stderr": log.name,
                  "command": ["xcrun", "simctl", "io", device, "recordVideo", "--codec=h264", "--display=" + DISPLAY, "--force", str(video)]}
        receipt["recorder"] = record
        with (args.output / record["stdout"]).open("wb") as out, log.open("wb") as err:
            recorder = subprocess.Popen(record["command"], stdout=out, stderr=err, start_new_session=True)
        record["pid"] = recorder.pid
        owned.append((recorder, record))
        while True:
            if time.monotonic() >= setup_deadline:
                record["wait_reason"] = "deadline"
                break
            if log.stat().st_size > 1024 * 1024:
                record["wait_reason"] = "log-overflow"
                break
            marker = next((line for line in log.read_bytes().splitlines() if line.startswith(b"Recording started")), None)
            if marker is not None:
                record["wait_reason"] = "marker"
                record["marker_line"] = marker.decode(errors="replace")
                receipt["first_frame_observed"] = True
                receipt["first_frame_observed_at"] = stamp()
                break
            if child_exited(recorder):
                record["wait_reason"] = "early-exit"
                break
            time.sleep(.05)
        if not receipt["first_frame_observed"] or child_exited(recorder) or time.monotonic() >= setup_deadline:
            raise RuntimeError("Compositor did not provide a live first frame within the shared setup deadline")
        receipt["setup_finished"] = stamp()
        receipt["test_started"] = stamp()
        test_record = {"name": "native-test", "started": stamp()}
        receipt["test"] = test_record
        test = subprocess.Popen(command, start_new_session=True)
        test_record["pid"] = test.pid
        owned.append((test, test_record))
        finished = wait_until_exit(test, time.monotonic() + TEST_SECONDS)
        retire(test, test_record)
        native_status = test.returncode if finished else 124
        receipt["test_finished"] = stamp()
        receipt["test_status"] = native_status
        receipt["test_timed_out"] = not finished

        post_deadline = time.monotonic() + POST_TEST_SECONDS
        receipt["post_test_started"] = stamp()
        ended_early = child_exited(recorder)
        record["ended_before_stop"] = ended_early
        record["stop_requested"] = stamp()
        if not ended_early:
            os.killpg(recorder.pid, signal.SIGINT)
        finalized = wait_until_exit(recorder, min(post_deadline, time.monotonic() + FINALIZE_SECONDS))
        retire(recorder, record)
        record["finalized_in_budget"] = finalized
        record["video_bytes"] = video.stat().st_size if video.exists() else 0
        if ended_early or not finalized or recorder.returncode != 0:
            raise RuntimeError("Recorder did not remain active and finalize successfully")
        receipt["video_first_frame"] = decoded("decode-video", "video", video, post_deadline)
        receipt["video_complete"] = True
        receipt["post_test_finished"] = stamp()
        status = native_status
    except KeyboardInterrupt:
        status = 130
        receipt["interrupted"] = "SIGINT"
    except SystemExit as error:
        status = error.code if isinstance(error.code, int) else 1
        receipt["interrupted"] = status
    except Exception as error:
        receipt["error"] = {"type": type(error).__name__, "message": str(error)}
        status = native_status or 1
    finally:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        for process, record in reversed(owned):
            if process.returncode is None:
                try:
                    retire(process, record)
                except Exception as error:
                    receipt.setdefault("cleanup_errors", []).append({"process": record["name"], "error": str(error)})
                    if status == 0:
                        status = 1
        if "test_started" not in receipt:
            receipt["test_skipped_reason"] = "setup did not establish a recordable primary display"
        status = status if status >= 0 else 128 - status
        receipt["finished"] = stamp()
        receipt["exit_status"] = status
        setup_end = receipt.get("setup_finished", receipt["finished"])
        receipt["setup_elapsed_seconds"] = setup_end["monotonic_seconds"] - receipt["started"]["monotonic_seconds"]
        (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return status


if __name__ == "__main__":
    sys.exit(main())
