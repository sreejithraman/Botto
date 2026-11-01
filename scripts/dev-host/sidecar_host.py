#!/usr/bin/env python3
"""Real pinned Hermes 0.21.5 standalone sidecar, isolated from the authority host."""

import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request

from mock_provider import Handler, MODEL
from process_groups import child_exited, stop_group, wait_for_exit
from sidecar_dependencies import REQUIREMENTS

HERE = Path(__file__).resolve().parent
ROOT = Path("/tmp/botto-runtime-sidecar")
SOURCE = Path("/tmp/botto-sidecar-source")
SHA = "ca6782850432927f33df4775cb6dd45bb51460d2"
ARCHIVE_SHA256 = "82579cb54f79350176105ad5721cb19d5284a25b4b8cd67b16d4bfd91c54e7cf"
INSTALL_ID = "11111111111111111111111111119121"
PORT = 19121
PROVIDER_PORT = 19122
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def health():
    with OPENER.open("http://127.0.0.1:%d/api/status" % PORT, timeout=3) as response:
        return json.load(response)


def setup():
    archive = ROOT / "source.tar.gz"
    if not archive.exists():
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
            "https://codeload.github.com/NousResearch/hermes-agent/tar.gz/" + SHA,
            "-o", str(archive)], check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise SystemExit("Pinned source archive digest mismatch")
    if not SOURCE.exists():
        SOURCE.mkdir(mode=0o700)
        # Strip the codeload archive's single root prefix.
        with tarfile.open(archive) as bundle:
            for member in bundle.getmembers():
                parts = Path(member.name).parts[1:]
                if not parts:
                    continue
                if member.issym() or member.islnk() or ".." in parts:
                    raise SystemExit("Unexpected archive link/path")
                member.name = str(Path(*parts))
                bundle.extract(member, SOURCE)
    if 'version = "0.21.5"' not in (SOURCE / "pyproject.toml").read_text():
        raise SystemExit("Unexpected source version")
    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            if member.isfile():
                path = SOURCE / Path(*Path(member.name).parts[1:])
                if hashlib.sha256(path.read_bytes()).digest() != hashlib.sha256(bundle.extractfile(member).read()).digest():
                    raise SystemExit("Source differs from pinned archive: " + str(path))
    (ROOT / "source-revision").write_text(SHA + "\n")
    python = ROOT / "venv/bin/python"
    if not python.exists():
        subprocess.run(["uv", "venv", "--native-tls", "--python", "3.13", str(ROOT / "venv")], check=True)
    command = ["uv", "pip", "install", "--native-tls", "--python", str(python), "-e", str(SOURCE)]
    lock = ROOT / "requirements.lock"
    lock.write_text(REQUIREMENTS)
    # Install all tested packages, including the optional imports Hermes
    # otherwise prepares lazily during a first turn.
    command.extend(["--requirement", str(lock)])
    subprocess.run(command, check=True)
    frozen = subprocess.run(["uv", "pip", "freeze", "--python", str(python)],
        check=True, capture_output=True, text=True).stdout
    lock.write_text("\n".join(line for line in frozen.splitlines() if not line.startswith("-e ")) + "\n")
    print("Prepared real Hermes " + SHA)


def environment():
    for path in (ROOT / "hermes", ROOT / "user", ROOT / "workspace", ROOT / "cache", ROOT / "tmp"):
        path.mkdir(mode=0o700, exist_ok=True)
    cfg = {
        "model": {"provider": "custom", "default": MODEL,
                  "base_url": "http://127.0.0.1:%d/v1" % PROVIDER_PORT,
                  "api_mode": "chat_completions", "streaming": True, "context_length": 256000},
        "approvals": {"mode": "manual"},
        "auxiliary": {"title_generation": {"enabled": False}},
        "terminal": {"backend": "local", "cwd": str(ROOT / "workspace")},
        "security": {"tirith_enabled": False},
        "platform_toolsets": {"cli": ["terminal"]},
    }
    (ROOT / "hermes/config.yaml").write_text(json.dumps(cfg, indent=2) + "\n")
    (ROOT / "hermes/install_id").write_text(INSTALL_ID + "\n")
    env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL", "TZ") if k in os.environ}
    env.update({
        "HOME": str(ROOT / "user"), "USERPROFILE": str(ROOT / "user"),
        "HERMES_HOME": str(ROOT / "hermes"), "HERMES_GATEWAY_LOCK_DIR": str(ROOT / "hermes/locks"),
        "TMPDIR": str(ROOT / "tmp"), "XDG_CONFIG_HOME": str(ROOT / "user/config"),
        "XDG_CACHE_HOME": str(ROOT / "cache"), "PYTHONPATH": str(SOURCE), "PYTHONUNBUFFERED": "1",
        "HERMES_DASHBOARD_BASIC_AUTH_USERNAME": "botto-test",
        "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD": "botto-test",
        "HERMES_DASHBOARD_BASIC_AUTH_SECRET": "botto-sidecar-local-disposable-signing-key",
        "HERMES_DASHBOARD_PUBLIC_URL": "http://botto-sidecar-local.invalid",
        "OPENAI_API_KEY": "botto-sidecar-local-no-real-key",
        "OPENAI_BASE_URL": "http://127.0.0.1:%d/v1" % PROVIDER_PORT,
        "NO_PROXY": "127.0.0.1,localhost,::1", "no_proxy": "127.0.0.1,localhost,::1",
        "TIRITH_ENABLED": "false",
    })
    return env


def run():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", PORT))
    peer = ThreadingHTTPServer(("127.0.0.1", PROVIDER_PORT), Handler)
    peer.stats = {"requests": 0, "streaming_requests": 0}
    threading.Thread(target=peer.serve_forever, daemon=True).start()
    command = [str(ROOT / "venv/bin/hermes"), "serve", "--host", "127.0.0.1", "--port", str(PORT), "--isolated"]
    def interrupted(*_):
        raise KeyboardInterrupt
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    child = None
    try:
        with (ROOT / "backend.log").open("a") as log:
            child = subprocess.Popen(command, env=environment(), cwd=ROOT / "workspace",
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        record = {"revision": SHA, "archive_sha256": ARCHIVE_SHA256, "source": str(SOURCE),
            "supervisor_pid": os.getpid(), "backend_pid": child.pid, "command": command,
            "origin": "http://127.0.0.1:%d" % PORT, "provider_port": PROVIDER_PORT,
            "hermes_home": str(ROOT / "hermes")}
        (ROOT / "process.json").write_text(json.dumps(record, indent=2) + "\n")
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if child_exited(child):
                raise RuntimeError("Sidecar exited; see backend.log")
            try:
                status = health()
                if status.get("install_id") == INSTALL_ID and status.get("auth_required") is True:
                    (ROOT / "ready.json").write_text(json.dumps({**record, "status": status}, indent=2) + "\n")
                    print("Ready: " + record["origin"], flush=True)
                    break
            except (OSError, ValueError):
                pass
            time.sleep(.25)
        else:
            raise RuntimeError("Sidecar readiness timeout; see backend.log")
        wait_for_exit(child)
    except KeyboardInterrupt:
        return 0
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        try:
            (ROOT / "ready.json").unlink(missing_ok=True)
        finally:
            try:
                if child:
                    stop_group(child)
            finally:
                peer.shutdown()
                (ROOT / "mock-stats.json").write_text(json.dumps(peer.stats) + "\n")
    return child.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("setup", "start", "run", "status", "stop"))
    action = parser.parse_args().action
    ROOT.mkdir(mode=0o700, exist_ok=True)
    ROOT.chmod(0o700)
    if action == "setup":
        return setup()
    if action == "status":
        print(json.dumps(health(), indent=2))
    elif action == "run":
        return run()
    elif action == "start":
        record_path = ROOT / "process.json"
        if record_path.exists():
            record = json.loads(record_path.read_text())
            try:
                os.kill(record["supervisor_pid"], 0)
            except ProcessLookupError:
                pass
            else:
                raise SystemExit("Recorded supervisor still exists; inspect it before restarting")
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", PORT))
        (ROOT / "ready.json").unlink(missing_ok=True)
        with (ROOT / "supervisor.log").open("a") as log:
            proc = subprocess.Popen([sys.executable, str(HERE / "sidecar_host.py"), "run"],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 125
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise SystemExit("Sidecar failed; inspect supervisor.log and backend.log")
            if (ROOT / "ready.json").exists():
                try:
                    current = health()
                    if current.get("install_id") == INSTALL_ID and current.get("auth_required") is True:
                        print((ROOT / "ready.json").read_text())
                        return
                except (OSError, ValueError):
                    pass
            time.sleep(.25)
        os.kill(proc.pid, signal.SIGTERM)
        raise SystemExit("Readiness timeout")
    elif action == "stop":
        record = json.loads((ROOT / "process.json").read_text())
        pid = record["supervisor_pid"]
        command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
        if str(HERE / "sidecar_host.py") not in command or not command.strip().endswith(" run"):
            raise SystemExit("Recorded PID is absent or not this sidecar supervisor; no signal sent")
        os.kill(pid, signal.SIGTERM)
        print("Stop requested for sidecar supervisor %d" % pid)


if __name__ == "__main__":
    sys.exit(main() or 0)
