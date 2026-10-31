#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import threading
import time
import uuid

TARGETS = {
    "revisionCacheRemovalAndImageFailuresStayLocal",
    "hermesPetAndImageAssetsKeepAspectAndTransparency",
    "actualCanvasGenerationAndSendKeepEveryHostedRowInsideItsNativeAllocation",
}


def matching_pids(output, device):
    executable = re.compile(
        r"^/\S*?/Devices/" + re.escape(device)
        + r"/data/Containers/Bundle/Application/[^/\s]+/Botto\.app/Botto(?:\s|$)"
    )
    return [int(fields[0]) for line in output.splitlines()
            if len(fields := line.strip().split(None, 1)) == 2
            and fields[0].isdigit() and executable.match(fields[1])]


class Monitor:
    def __init__(self, device, output_dir):
        self.device = device
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.container = None
        self.data_root = Path.home() / "Library/Developer/CoreSimulator/Devices" / device / "data/Containers/Data/Application"
        self.captured = set()
        self.rejected = set()
        self.observed = {}
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.watch, daemon=True)

    def watch(self):
        try:
            while not self.stopped.is_set():
                self.poll()
                self.stopped.wait(0.25 if self.container else 2)
        except Exception as error:
            self.save("collector-error.json", {"error": str(error)})

    def marker(self, path, method):
        try:
            if path.is_symlink():
                return None
            value = json.loads(path.read_text())
            if (not isinstance(value, dict) or value.get("method") != method
                    or not isinstance(value.get("pid"), int) or value["pid"] <= 0
                    or not isinstance(value.get("runID"), str) or not value["runID"]
                    or value.get("phase") not in {"started", "finished"}
                    or not isinstance(value.get("timestamp"), (int, float))
                    or not math.isfinite(value["timestamp"])):
                return None
            return value
        except (OSError, ValueError):
            return None

    def poll(self, now=None):
        if self.container is None or not self.container.is_dir():
            self.container = None
            # Read the selected Simulator's container index without competing
            # with Xcode's installation and test-manager calls to simctl.
            for metadata in self.data_root.glob("*/.com.apple.mobile_container_manager.metadata.plist"):
                try:
                    if plistlib.loads(metadata.read_bytes()).get("MCMMetadataIdentifier") == "com.sree.botto":
                        self.container = metadata.parent
                        break
                except (OSError, plistlib.InvalidFileException, ValueError):
                    continue
            if self.container is None:
                return
        instant = time.time() if now is None else now
        for method in TARGETS:
            for path in (self.container / "tmp").glob(f"botto-native-{method}-*.json"):
                marker = self.marker(path, method)
                if marker is None:
                    continue
                self.observed[marker["runID"]] = marker
                if (method not in self.captured and (method, marker["runID"]) not in self.rejected
                        and marker["phase"] == "started"
                        and instant - marker["timestamp"] >= 3 and not self.stopped.is_set()):
                    self.sample(path, method, marker)

    def sample(self, path, method, marker):
        record = {"method": method, "device": self.device, "nativeStart": marker,
                  "startedAt": datetime.now(timezone.utc).isoformat()}
        stem = method + "-" + uuid.uuid4().hex[:8]
        try:
            pid = marker["pid"]
            current = subprocess.check_output(
                ["/bin/ps", "-p", str(pid), "-o", "pid=,command="], text=True, timeout=2,
            )
            if matching_pids(current, self.device) != [pid]:
                raise RuntimeError("Marker PID does not match the device-scoped Botto process")
            if self.stopped.is_set() or self.marker(path, method) != marker:
                return
            self.captured.add(method)
            record["pid"] = pid
            result = subprocess.run(
                ["/usr/bin/sample", str(pid), "1", "-file", str(self.output_dir / (stem + ".sample.txt"))],
                capture_output=True, text=True, timeout=15,
            )
            record.update(returncode=result.returncode, stderr=result.stderr,
                          testFinishedDuringSample=self.marker(path, method) != marker)
        except Exception as error:
            self.rejected.add((method, marker["runID"]))
            record["error"] = str(error)
        record["finishedAt"] = datetime.now(timezone.utc).isoformat()
        self.save(stem + ".json", record)

    def save(self, name, value):
        try:
            (self.output_dir / name).write_text(json.dumps(value, indent=2) + "\n")
        except OSError as error:
            print(f"Native sample metadata could not be saved: {error}", file=sys.stderr)

    def close(self):
        self.stopped.set()
        if self.thread.ident is not None:
            self.thread.join(timeout=20)
        self.save("collector-summary.json", {"device": self.device, "observed": self.observed,
                  "sampledMethods": sorted(self.captured), "workerStopped": not self.thread.is_alive()})


def run(command, monitor, stdout=None, stderr=None):
    child = subprocess.Popen(command, stdout=stdout, stderr=stderr)
    try:
        monitor.thread.start()
        return child.wait()
    finally:
        try:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)
        finally:
            monitor.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True, type=lambda value: str(uuid.UUID(value)).upper())
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("A child command is required after --")
    result = run(command, Monitor(args.device, args.output_dir))
    return result if result >= 0 else 128 - result


if __name__ == "__main__":
    raise SystemExit(main())
