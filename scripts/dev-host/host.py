#!/usr/bin/env python3
"""Prepare and run a disposable pinned Hermes authority gateway. No user state."""

import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request

from mock_provider import Handler, MODEL
from process_groups import child_exited, stop_group, wait_for_exit

HERE = Path(__file__).resolve().parent
SHA = "4a0eaf7989b6804319ddb94fa5d96c5a716080a1"
INSTALL_ID = "486f744c6f63616c486f737430303031"
DEFAULT = "/tmp/botto-runtime-current"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def revision(source):
    head = (source / ".git/HEAD").read_text().strip()
    if head.startswith("ref: "):
        ref = head[5:]
        path = source / ".git" / ref
        if path.exists():
            return path.read_text().strip()
        for line in (source / ".git/packed-refs").read_text().splitlines():
            if line.endswith(" " + ref):
                return line.split()[0]
    return head


def runtime(path):
    root = Path(path).resolve()
    if root.parent != Path("/tmp").resolve() or not root.name.startswith("botto-runtime-"):
        raise SystemExit("Runtime must be a private /tmp/botto-runtime-* directory")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.chmod(0o700)
    return root


def setup(root, source):
    source = Path(source).resolve()
    if revision(source) != SHA:
        raise SystemExit("Source revision does not match the tested current Hermes commit")
    private = root / "source"
    if private.exists() and not (root / "source-revision").exists():
        # Unversioned source copies cannot establish the pinned revision.
        shutil.rmtree(private)
    if not private.exists():
        shutil.copytree(source, private, ignore=shutil.ignore_patterns(
            ".git", ".venv", "node_modules", "__pycache__", ".pytest_cache"))
        (root / "source-revision").write_text(SHA + "\n")
    if (root / "source-revision").read_text().strip() != SHA:
        raise SystemExit("Runtime contains another source revision; choose a fresh runtime")
    python = root / "venv/bin/python"
    if not python.exists():
        subprocess.run(["uv", "venv", "--native-tls", "--python", "3.14", str(root / "venv")], check=True)
    # Match the upstream [tool.uv] overrides. uv pip install of a local
    # project does not automatically apply that project's workspace overrides.
    (root / "overrides.txt").write_text("Pillow==13.0.0\ncryptography==50.0.1\n")
    subprocess.run(["uv", "pip", "install", "--native-tls", "--python", str(python),
        "--overrides", str(root / "overrides.txt"), "--constraint", str(HERE / "requirements.lock"),
        "-e", str(private)], check=True)
    with (root / "requirements-resolved.txt").open("w") as out:
        subprocess.run(["uv", "pip", "freeze", "--python", str(python)], stdout=out, check=True)
    print("Prepared " + str(root))


def config(root, mock_port, port):
    home = root / "hermes"
    for path in (home, root / "user", root / "workspace", root / "tmp", root / "cache"):
        path.mkdir(mode=0o700, exist_ok=True)
    base = "http://127.0.0.1:%d/v1" % mock_port
    cfg = {
        "model": {"provider": "custom", "default": MODEL, "base_url": base,
                  "api_mode": "chat_completions", "streaming": True, "context_length": 128000},
        "gateway": {"multiplex_profiles": True},
        "approvals": {"mode": "manual", "timeout": 120},
        "auxiliary": {"title_generation": {"enabled": False}},
        "terminal": {"backend": "local", "cwd": str(root / "workspace")},
        "security": {"tirith_enabled": False},
        "platform_toolsets": {"cli": ["terminal", "clarify"]},
    }
    (home / "config.yaml").write_text(json.dumps(cfg, indent=2) + "\n")
    (home / "install_id").write_text(INSTALL_ID + "\n")
    # Allowlist prevents inherited credentials, proxy settings or HERMES_*
    # selectors reaching the gateway. HOME also isolates OS fallback paths.
    env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "TZ") if key in os.environ}
    env.update({
        "HOME": str(root / "user"), "USERPROFILE": str(root / "user"),
        "XDG_CONFIG_HOME": str(root / "user/config"), "XDG_CACHE_HOME": str(root / "cache"),
        "TMPDIR": str(root / "tmp"), "HERMES_HOME": str(home),
        "HERMES_GATEWAY_LOCK_DIR": str(home / "locks"),
        "HERMES_DASHBOARD_BASIC_AUTH_USERNAME": "botto-test",
        "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD": "botto-test",
        "HERMES_DASHBOARD_BASIC_AUTH_SECRET": "botto-disposable-local-signing-key-only",
        # Upstream uses a non-loopback public_url to turn on the auth gate
        # while retaining a loopback socket (same pattern as Hermex local-hermes).
        "HERMES_DASHBOARD_PUBLIC_URL": "http://botto-local.invalid",
        "OPENAI_API_KEY": "botto-local-no-real-credential", "OPENAI_BASE_URL": base,
        "NO_PROXY": "127.0.0.1,localhost,::1", "no_proxy": "127.0.0.1,localhost,::1",
        "PYTHONPATH": str(root / "source"), "PYTHONUNBUFFERED": "1",
        "BOTTO_HOST_PORT": str(port), "TIRITH_ENABLED": "false",
    })
    return env


def status(port):
    with OPENER.open("http://127.0.0.1:%d/api/status" % port, timeout=3) as response:
        return json.load(response)


def serve(root, port):
    # Never replace a host found by name or steal an occupied port.
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", port))
    # Keep the provider URL stable across restarts: cloned profile configs
    # legitimately persist the launch profile's base_url.
    previous = root / "process.json"
    mock_port = json.loads(previous.read_text())["mock_port"] if previous.exists() else port + 1
    peer = ThreadingHTTPServer(("127.0.0.1", mock_port), Handler)
    peer.stats = {"requests": 0, "streaming_requests": 0}
    threading.Thread(target=peer.serve_forever, daemon=True).start()
    env = config(root, peer.server_port, port)
    command = [str(root / "venv/bin/python"), str(HERE / "gateway_entry.py")]
    def interrupted(*_):
        raise KeyboardInterrupt
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    child = None
    try:
        with (root / "gateway.log").open("a") as log:
            child = subprocess.Popen(command, cwd=root / "workspace", env=env,
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        record = {"revision": SHA, "supervisor_pid": os.getpid(), "gateway_pid": child.pid,
                  "origin": "http://127.0.0.1:%d" % port, "mock_port": peer.server_port,
                  "hermes_home": str(root / "hermes"), "command": command}
        (root / "process.json").write_text(json.dumps(record, indent=2) + "\n")
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if child_exited(child):
                raise RuntimeError("Gateway exited; see " + str(root / "gateway.log"))
            try:
                health = status(port)
                if health.get("install_id") == INSTALL_ID and health.get("auth_required") is True:
                    (root / "ready.json").write_text(json.dumps({**record, "status": health}, indent=2) + "\n")
                    print("Ready: " + record["origin"], flush=True)
                    break
            except (OSError, ValueError):
                pass
            time.sleep(.25)
        else:
            raise RuntimeError("Gateway readiness timeout; see gateway.log")
        wait_for_exit(child)
    except KeyboardInterrupt:
        return 0
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        try:
            if child:
                stop_group(child)
        finally:
            peer.shutdown()
            (root / "mock-stats.json").write_text(json.dumps(peer.stats) + "\n")
            (root / "ready.json").unlink(missing_ok=True)
    return child.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("setup", "run", "start", "status", "stop"))
    parser.add_argument("--runtime", default=DEFAULT)
    parser.add_argument("--source", default="/tmp/botto-protocol/hermes-agent")
    parser.add_argument("--port", type=int, default=19119)
    args = parser.parse_args()
    root = runtime(args.runtime)
    if args.action == "setup":
        return setup(root, args.source)
    if args.action == "status":
        print(json.dumps(status(args.port), indent=2))
    elif args.action == "run":
        return serve(root, args.port)
    elif args.action == "start":
        record_path = root / "process.json"
        if record_path.exists():
            record = json.loads(record_path.read_text())
            try:
                os.kill(record["supervisor_pid"], 0)
            except ProcessLookupError:
                pass
            else:
                raise SystemExit("Recorded supervisor still exists; inspect it before restarting")
        (root / "ready.json").unlink(missing_ok=True)
        with (root / "supervisor.log").open("a") as log:
            proc = subprocess.Popen([sys.executable, str(HERE / "host.py"), "run", "--runtime", str(root),
                "--port", str(args.port)], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True)
        deadline = time.monotonic() + 125
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise SystemExit("Host failed; inspect supervisor.log and gateway.log")
            if (root / "ready.json").exists():
                print((root / "ready.json").read_text())
                return
            time.sleep(.25)
        os.kill(proc.pid, signal.SIGTERM)
        raise SystemExit("Readiness timeout")
    elif args.action == "stop":
        record = json.loads((root / "process.json").read_text())
        # Check process command before signaling a saved PID that may be reused.
        pid = record["supervisor_pid"]
        command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
        if str(HERE / "host.py") not in command or " run " not in command or str(root) not in command:
            raise SystemExit("Saved PID is absent or not this supervisor; no signal sent")
        os.kill(pid, signal.SIGTERM)
        print("Stop requested for supervisor %d; gateway drains its own process group" % pid)


if __name__ == "__main__":
    sys.exit(main() or 0)
