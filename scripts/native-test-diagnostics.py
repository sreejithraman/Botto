#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import threading
import uuid

TARGETS = {
    "revisionCacheRemovalAndImageFailuresStayLocal",
    "hermesPetAndImageAssetsKeepAspectAndTransparency",
}
EVENT = re.compile(r"([◇✔✘]) Test ([A-Za-z_][A-Za-z_0-9]*)\(.*\) (.*)$")


def test_event(line, targets=TARGETS):
    match = EVENT.search(line)
    if not match or match[2] not in targets:
        return None
    marker, method, suffix = match.groups()
    if marker == "◇" and suffix == "started.":
        return method, "start"
    if marker in {"✔", "✘"} and re.match(r"(?:with .* )?(?:passed|failed) after ", suffix):
        return method, "finish"
    return None


def matching_pids(output, device):
    executable = re.compile(
        r"^/\S*?/Devices/" + re.escape(device)
        + r"/data/Containers/Bundle/Application/[^/\s]+/Botto\.app/Botto(?:\s|$)"
    )
    matches = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and executable.match(fields[1]):
            matches.append(int(fields[0]))
    return matches


class Monitor:
    def __init__(self, device, output_dir, timer_factory=threading.Timer, watch_tests=None):
        self.device = device
        self.watch_tests = frozenset(watch_tests) if watch_tests is not None else TARGETS
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.timer_factory = timer_factory
        self.timers = {}
        self.active = set()
        self.lock = threading.Lock()

    def observe(self, line):
        event = test_event(line, self.watch_tests)
        if not event:
            return
        method, state = event
        with self.lock:
            if state == "start" and method not in self.timers:
                self.active.add(method)
                timer = self.timer_factory(3, lambda: self.sample(method))
                timer.daemon = True
                self.timers[method] = timer
                timer.start()
            elif state == "finish":
                self.active.discard(method)
                if method in self.timers:
                    self.timers[method].cancel()

    def sample(self, method):
        record = {"method": method, "device": self.device,
                  "startedAt": datetime.now(timezone.utc).isoformat()}
        path = self.output_dir / (method + "-" + uuid.uuid4().hex[:8])
        try:
            with self.lock:
                if method not in self.active:
                    return
            listing = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True, timeout=2)
            candidates = matching_pids(listing, self.device)
            if len(candidates) != 1:
                raise RuntimeError(f"Expected one device-scoped Botto process; found {len(candidates)}")
            pid = candidates[0]
            current = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "pid=,command="], text=True, timeout=2)
            if matching_pids(current, self.device) != [pid]:
                raise RuntimeError("Device-scoped Botto process changed before sampling")
            with self.lock:
                if method not in self.active:
                    return
            record["pid"] = pid
            result = subprocess.run(
                ["/usr/bin/sample", str(pid), "1", "-file", str(path.with_suffix(".sample.txt"))],
                capture_output=True, text=True, timeout=15,
            )
            record.update(returncode=result.returncode, stderr=result.stderr)
            with self.lock:
                record["testFinishedDuringSample"] = method not in self.active
        except Exception as error:
            record["error"] = str(error)
        record["finishedAt"] = datetime.now(timezone.utc).isoformat()
        try:
            path.with_suffix(".json").write_text(json.dumps(record, indent=2) + "\n")
        except OSError as error:
            print(f"Native sample metadata could not be saved: {error}", file=sys.stderr)

    def close(self):
        with self.lock:
            self.active.clear()
            timers = list(self.timers.values())
            for timer in timers:
                timer.cancel()
        for timer in timers:
            timer.join(timeout=20)


def run(command, monitor, stdout=None, stderr=None):
    outputs = (stdout or sys.stdout.buffer, stderr or sys.stderr.buffer)
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    for stream, output in zip((child.stdout, child.stderr), outputs):
        selector.register(stream, selectors.EVENT_READ, (output, bytearray()))
    try:
        while selector.get_map():
            for key, _ in selector.select():
                output, pending = key.data
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    if pending:
                        monitor.observe(pending.decode("utf-8", errors="replace"))
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                output.write(chunk)
                output.flush()
                pending.extend(chunk)
                while b"\n" in pending:
                    line, _, rest = pending.partition(b"\n")
                    pending[:] = rest
                    monitor.observe(line.decode("utf-8", errors="replace"))
        return child.wait()
    finally:
        selector.close()
        for stream in (child.stdout, child.stderr):
            stream.close()
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


def method_stem(value):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", value):
        raise argparse.ArgumentTypeError("A method stem must be an ASCII identifier")
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True, type=lambda value: str(uuid.UUID(value)).upper())
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--watch-test", action="append", type=method_stem)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("A child command is required after --")
    result = run(command, Monitor(args.device, args.output_dir, watch_tests=args.watch_test))
    return result if result >= 0 else 128 - result


if __name__ == "__main__":
    raise SystemExit(main())
