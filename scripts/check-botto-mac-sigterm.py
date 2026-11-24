#!/usr/bin/env python3
"""Exercise the macOS Quit and SIGTERM paths with the built app's engine."""

import argparse
import contextlib
import json
import os
from pathlib import Path
import plistlib
from shlex import quote
import signal
import socket
import subprocess
from tempfile import TemporaryDirectory
import time
from urllib.request import urlopen


def wait_for(condition, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return False


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def responds(port):
    try:
        with urlopen(f"http://127.0.0.1:{port}/.well-known/t3/environment", timeout=0.4) as response:
            return json.load(response)["orchestrationProtocolVersion"] == 2
    except OSError:
        return False


def listening(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.4):
            return True
    except OSError:
        return False


def processes():
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,pgid=,command="], text=True)
    for line in output.splitlines():
        fields = line.split(maxsplit=3)
        if len(fields) == 4:
            pid, parent, group, command = fields
            yield int(pid), int(parent), int(group), command


def engine_processes(base):
    argument = f"--base-dir {base}"
    return [row for row in processes() if argument in row[3] and "/T3Engine/t3 serve " in row[3]]


@contextlib.contextmanager
def launch(argv, home):
    home.mkdir()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "CFFIXED_USER_HOME": str(home), "TMPDIR": str(home)}
    with subprocess.Popen(
        argv, env=env, start_new_session=True, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ) as process:
        try:
            yield process
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)


def exercise(harness, engine, directory, action, override=None):
    directory.mkdir()
    other_port = free_port()
    other_base = directory / "independent-data"
    independent = [engine, "serve", "--host", "127.0.0.1", "--port", str(other_port), "--base-dir", other_base]
    with launch(independent, directory / "independent-home") as other:
        assert wait_for(lambda: responds(other_port), 30), "Independent engine did not start"
        assert [row[0] for row in engine_processes(other_base)] == [other.pid]
        port = free_port()
        base = directory / "owned-data"
        quit_marker = directory / "quit"
        arguments = [harness, str(port), base, quit_marker]
        if override is not None:
            arguments.append(override)
        with launch(arguments, directory / "app-home") as app:
            resistant_pid = None
            owned_group = None
            try:
                assert wait_for(lambda: responds(port), 30), "Bundled engine did not start"
                (pid, parent, group, _), = engine_processes(base)
                if override is None:
                    assert parent == app.pid and group == pid, "Listener is not the app's child group"
                else:
                    assert parent == group, "Wrapped engine is outside the owned group"
                    assert any(row[:3] == (group, app.pid, group) for row in processes())
                    child_pid = base / "resistant-pid"
                    assert wait_for(lambda: child_pid.exists() and (base / "resistant-ready").exists()), (
                        "SIGTERM-resistant child did not start"
                    )
                    resistant_pid = int(child_pid.read_text())
                    assert any(row[0] == resistant_pid and row[2] == group for row in processes())
                    print(f"Wrapped engine has a SIGTERM-responsive leader and a resistant child PID={resistant_pid}", flush=True)
                owned_group = group
                print(f"PATH=/usr/bin:/bin; {action}; app={app.pid}; bundled engine={pid}; group={group}; protocol=2", flush=True)
                if action == "SIGTERM":
                    app.send_signal(signal.SIGTERM)
                else:
                    quit_marker.touch()
                status = app.wait(timeout=5)

                def owned_engine_stopped():
                    return not any(row[2] == group for row in processes()) and not listening(port)

                stopped = wait_for(owned_engine_stopped)
                independent_alive = other.poll() is None and responds(other_port)
                print(f"{action}: app exit={status}; owned process group and listener gone={stopped}; "
                      f"independent engine PID={other.pid} still responds={independent_alive}", flush=True)
                assert stopped, f"{action} left the app-owned process group or listener"
                assert independent_alive, f"{action} stopped the independent engine"
                assert status == 0, f"{action} exited with status {status}"
            finally:
                for pid, parent, group, _ in engine_processes(base):
                    if pid == group and parent in (app.pid, 1):
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(group, signal.SIGKILL)
                if resistant_pid is not None and owned_group is not None and any(
                    row[0] == resistant_pid and row[2] == owned_group for row in processes()
                ):
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(resistant_pid, signal.SIGKILL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="path to the Apple Silicon BottoMac.app build")
    args = parser.parse_args()
    resources = args.app.resolve() / "Contents/Resources"
    engine = resources / "T3Engine/t3"
    if not os.access(engine, os.X_OK):
        parser.error(f"Missing bundled engine at {engine}")
    root = Path(__file__).resolve().parent.parent
    with TemporaryDirectory(prefix="botto-mac-sigterm-") as temp:
        contents = Path(temp) / "BottoMacTerminationHarness.app/Contents"
        macos = contents / "MacOS"
        macos.mkdir(parents=True)
        harness = macos / "BottoMacTerminationHarness"
        (contents / "Resources").symlink_to(resources, target_is_directory=True)
        with (contents / "Info.plist").open("wb") as info:
            plistlib.dump({
                "CFBundleExecutable": harness.name,
                "CFBundleIdentifier": "dev.botto.termination-test",
                "CFBundlePackageType": "APPL",
            }, info)
        subprocess.run([
            "/usr/bin/swiftc", "-swift-version", "6",
            root / "Mac/LocalT3ServerManager.swift", root / "Mac/MacBottoDelegate.swift",
            root / "scripts/tests/fixtures/BottoMacTerminationHarness.swift", "-o", harness,
        ], check=True)
        for action in ("SIGTERM", "Quit"):
            exercise(harness, engine, Path(temp) / action, action)
        override = Path(temp) / "t3-with-resistant-child"
        override.write_text(f"""#!/bin/sh
trap 'exit 0' TERM
{quote(str(engine))} "$@" &
(
    trap '' TERM
    : > resistant-ready
    exec /bin/sleep 60
) &
printf '%s\\n' "$!" > resistant-pid
wait
""")
        override.chmod(0o700)
        exercise(harness, engine, Path(temp) / "SIGTERM-with-child", "SIGTERM", override=override)


if __name__ == "__main__":
    main()
