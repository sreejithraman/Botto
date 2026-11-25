#!/usr/bin/env python3
import argparse
from contextlib import suppress
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
import time


def main():
    parser = argparse.ArgumentParser(description="Run BottoCore's smoke test against an isolated T3 engine.")
    parser.add_argument("--tag", help="upstream release tag (defaults to Botto's pin)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    bundle = [root / "scripts/bundle-t3-engine.sh"]
    if args.tag:
        bundle += ["--stage", args.tag]
    staged = subprocess.check_output(bundle, text=True).strip()
    stage = Path(staged.removeprefix("T3 engine staged at "))
    tag = json.loads((stage / "pin.json").read_text())["ref"].removeprefix("refs/tags/")
    engine = stage / "t3"
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    server = None
    interrupted = None

    def stop(signum, _frame):
        nonlocal interrupted
        if interrupted is not None:
            return
        # Defer a signal during spawn until the cleanup block owns the server.
        interrupted = signum
        if server is not None:
            raise SystemExit(128 + signum)

    for sig in signals:
        signal.signal(sig, stop)

    with TemporaryDirectory(prefix="botto-t3-smoke-") as directory:
        try:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            # T3 captures PATH from a login shell. Keep provider CLIs out of that PATH.
            engine_env = {
                "HOME": directory, "TMPDIR": directory, "PATH": os.defpath,
                "SHELL": "/bin/bash", "NO_COLOR": "1",
            }
            (Path(directory) / ".bash_profile").write_text(f"export PATH={os.defpath}\n")
            log = Path(directory) / "server.log"
            with log.open("w") as output:
                server = subprocess.Popen(
                    [engine, "serve", "--host", "127.0.0.1", "--port", str(port), "--base-dir", directory],
                    cwd=directory, env=engine_env, stdin=subprocess.DEVNULL,
                    stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
                )
            if interrupted is not None:
                raise SystemExit(128 + interrupted)
            print(f"T3 {tag}: 127.0.0.1:{port}, PID {server.pid}, data {directory}", flush=True)
            deadline = time.monotonic() + 30
            while "\nPairing URL:" not in log.read_text():
                if (status := server.poll()) is not None:
                    raise ValueError(f"t3 serve exited with status {status} before it was ready")
                if time.monotonic() >= deadline:
                    raise ValueError("t3 serve did not print its startup pairing URL within 30 seconds")
                time.sleep(0.1)
            pair = subprocess.check_output(
                [engine, "pair", "--base-dir", directory], cwd=directory,
                env=engine_env, text=True, timeout=12,
            )
            pairing_url = next((line.removeprefix("Pairing URL:").strip() for line in pair.splitlines()
                                if line.startswith("Pairing URL:")), "")
            if not pairing_url.startswith(f"http://127.0.0.1:{port}/"):
                raise ValueError("t3 pair did not print a pairing URL for the disposable server")

            test = subprocess.run(
                ["swift", "test", "--scratch-path", ".artifacts/CoreTests", "--filter", "T3LiveSmokeTests"],
                cwd=root, env={**os.environ, "BOTTO_TEST_T3_PAIRING_URL": pairing_url,
                               "BOTTO_TEST_T3_WORKSPACE_ROOT": str(Path(directory) / "workspace")},
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            print(test.stdout, end="", flush=True)
            test.check_returncode()
            if not any(line.startswith("T3 live smoke completed:") for line in test.stdout.splitlines()):
                raise ValueError("T3LiveSmokeTests did not complete (skipped or not selected)")
        finally:
            for sig in signals:
                signal.signal(sig, signal.SIG_IGN)
            if server is not None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    with suppress(ProcessLookupError, PermissionError):
                        os.killpg(server.pid, signal.SIGKILL)
                    server.wait()
    print("Stopped T3 and removed disposable data.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"T3 live smoke: {error}")
