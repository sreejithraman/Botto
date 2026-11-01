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


def stamp():
    return {"unix_seconds": time.time(), "monotonic_seconds": time.monotonic()}


def wait_until_exit(process, seconds):
    deadline = time.monotonic() + seconds
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
    receipt = {"device": device, "started": stamp(), "command": command,
               "limits": "First-frame time is the observed log marker, not video PTS. Recording changes host workload. No paint or repair claim follows from a green test.",
               "budgets_seconds": {"boot": 60, "first_frame": 5, "test": 360, "video_finalize": 5},
               "first_frame_observed": False, "video_complete": False}
    boot = recorder = test = None
    native_status = None
    status = 1
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        try:
            with (args.output / "boot.log").open("wb") as boot_log:
                boot = subprocess.Popen(["xcrun", "simctl", "bootstatus", device, "-b"],
                                        stdout=boot_log, stderr=subprocess.STDOUT, start_new_session=True)
                boot_finished = wait_until_exit(boot, 60)
                stop_group(boot, grace=0)
                receipt["boot_status"] = boot.returncode if boot_finished else 124
            if receipt["boot_status"] == 0:
                with log.open("wb") as recorder_log:
                    recorder = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo",
                        "--codec=h264", "--force", str(video)], stdout=subprocess.DEVNULL,
                        stderr=recorder_log, start_new_session=True)
                receipt["recorder_started"] = stamp()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if b"Recording started" in log.read_bytes():
                        receipt["first_frame_observed"] = True
                        receipt["first_frame_observed_at"] = stamp()
                        break
                    if child_exited(recorder):
                        break
                    time.sleep(.05)
        except Exception as error:
            receipt["recording_setup_error"] = {"type": type(error).__name__, "message": str(error)}

        receipt["test_started"] = stamp()
        test = subprocess.Popen(command, start_new_session=True)
        finished = wait_until_exit(test, 360)
        stop_group(test, grace=0)
        native_status = test.returncode if finished else 124
        receipt["test_finished"] = stamp()
        receipt["test_status"] = native_status
        receipt["test_timed_out"] = not finished

        if recorder is not None:
            ended_early = child_exited(recorder)
            receipt["recorder_ended_before_stop"] = ended_early
            receipt["recorder_stop_requested"] = stamp()
            if not ended_early:
                os.killpg(recorder.pid, signal.SIGINT)
            finalized = wait_until_exit(recorder, 5)
            stop_group(recorder, grace=0)
            receipt["recorder_status"] = recorder.returncode
            receipt["recorder_finalized"] = stamp()
            receipt["video_bytes"] = video.stat().st_size if video.exists() else 0
            receipt["video_complete"] = (receipt["first_frame_observed"] and not ended_early
                and finalized and recorder.returncode == 0 and receipt["video_bytes"] > 0)
        status = native_status or (0 if receipt["video_complete"] else 1)
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
        # Each leader stays unreaped until its own group has been drained.
        for name, process in (("test", test), ("recorder", recorder), ("boot", boot)):
            if process is not None and process.returncode is None:
                try:
                    stop_group(process, grace=0)
                except Exception as error:
                    receipt.setdefault("cleanup_errors", []).append({"process": name, "error": str(error)})
                    if status == 0:
                        status = 1
        status = status if status >= 0 else 128 - status
        receipt["finished"] = stamp()
        receipt["exit_status"] = status
        (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return status


if __name__ == "__main__":
    sys.exit(main())
