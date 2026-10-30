#!/usr/bin/env python3
"""Prove real native Hermes events reach the plugin's encrypted relay boundary."""

from __future__ import annotations

import argparse
import asyncio
import base64
from contextlib import suppress
import hashlib
import http.cookiejar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag
from websockets.asyncio.client import connect


REPO = Path(__file__).resolve().parents[2]
BASE = "fcc26fbd9f1641755e49793d7ed608f3b7214c3d"
INSTALL = "686f742d707573682d736d6f6b652d7631"
MODEL = "botto-local-deterministic"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def canonical(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()


class RecordingRelay(BaseHTTPRequestHandler):
    """A strict local recording boundary; never a production delivery implementation."""

    def log_message(self, *_):
        pass

    def do_PUT(self):
        self.record()

    def do_POST(self):
        self.record()

    def record(self):
        size = int(self.headers.get("Content-Length", "0"))
        token = self.headers.get("Authorization", "").removeprefix("Bearer ")
        parts = self.path.split("/")
        authorized = len(token) == 64 and len(parts) >= 5 and parts[3] == hashlib.sha256(token.encode()).hexdigest()
        status = 200 if authorized else 401
        body = None
        if not 0 < size <= 32768:
            status = 400
        else:
            try:
                body = json.loads(self.rfile.read(size))
            except (ValueError, UnicodeError):
                status = 400
        if status == 200:
            if not isinstance(body, dict) or body.get("v") != 1:
                status = 400
            elif parts[-1] == "events":
                expected = {"v", "event_id", "thread_id", "kind", "request_id", "created_at", "expires_at", "targets"}
                if set(body) != expected or not body["targets"]:
                    status = 400
                elif any(set(target) != {"device_id", "generation", "sealed"} for target in body["targets"]):
                    status = 400
            if status == 200:
                with self.server.lock:
                    self.server.records.append({"method": self.command, "path": self.path, "body": body})
        if status != 200:
            with self.server.lock:
                self.server.rejections.append({"status": status, "route": parts[-1], "size": size})
        payload = canonical({"v": 1, "status": "accepted" if status == 200 else "rejected"})
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_json(self, status, value):
        data = canonical(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_json(200, {"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "botto-smoke"}]})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self.send_json(404, {"error": {"message": "Unknown fixture route"}})
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request.get("messages", [])
        user = next((str(row.get("content", "")) for row in reversed(messages) if row.get("role") == "user"), "")
        if any(marker in user for marker in ("BOTTO_DISCONNECTED", "BOTTO_APPROVAL", "BOTTO_QUESTION")):
            self.server.disconnected_started.set()
            if not self.server.disconnected_release.wait(30):
                return self.send_json(504, {"error": {"message": "Fixture viewer did not disconnect"}})
        # Reuse the repository's deterministic provider behavior. Only provider
        # output is simulated; no Hermes dispatch, hook or state method is patched.
        sys.path.insert(0, str(REPO / "scripts/dev-host"))
        from mock_provider import reply
        message, finish = reply(request)
        base = {"id": "chatcmpl-botto-push", "model": MODEL, "created": 1}
        usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        if not request.get("stream"):
            return self.send_json(200, {**base, "object": "chat.completion", "usage": usage,
                "choices": [{"index": 0, "message": message, "finish_reason": finish}]})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        deltas = [{"role": "assistant"}]
        text = message.get("content", "")
        deltas.extend({"content": text[i:i + 12]} for i in range(0, len(text), 12))
        deltas.extend({"tool_calls": [{"index": index, **call}]} for index, call in enumerate(message.get("tool_calls", [])))
        for delta in deltas:
            self.chunk({**base, "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": delta, "finish_reason": None}]})
        self.chunk({**base, "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]})
        self.chunk({**base, "object": "chat.completion.chunk", "choices": [], "usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def chunk(self, value):
        self.wfile.write(b"data: " + canonical(value) + b"\n\n")
        self.wfile.flush()


class Client:
    def __init__(self, origin):
        self.origin = origin
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.ws = None
        self.sequence = 0
        self.events = []

    def rest(self, path, body=None):
        request = urllib.request.Request(self.origin + path, data=None if body is None else canonical(body),
            headers={"Content-Type": "application/json"})
        with self.http.open(request, timeout=20) as response:
            return json.load(response)

    async def open(self):
        self.rest("/auth/password-login", {"provider": "basic", "username": "botto-test", "password": "botto-test"})
        ticket = self.rest("/api/auth/ws-ticket", {})["ticket"]
        self.ws = await connect(self.origin.replace("http:", "ws:") + "/api/ws",
            subprotocols=["hermes-gateway-v1", "hermes-gateway-ticket." + ticket], max_size=8 * 1024 * 1024)
        frame = json.loads(await asyncio.wait_for(self.ws.recv(), 20))
        assert frame.get("params", {}).get("payload", {}).get("session_authority") is True
        await self.rpc("client.capabilities", server_requests=True)

    async def read(self):
        frame = json.loads(await asyncio.wait_for(self.ws.recv(), 60))
        if frame.get("method") == "event":
            self.events.append(frame["params"])
        return frame

    async def rpc(self, method, **params):
        self.sequence += 1
        rid = self.sequence
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        async with asyncio.timeout(60):
            while True:
                frame = await self.read()
                if frame.get("id") == rid:
                    if "error" in frame:
                        raise RuntimeError(method + " returned " + str(frame["error"].get("code")))
                    return frame["result"]

    async def complete(self, session, start):
        async with asyncio.timeout(90):
            while True:
                event = next((event for event in self.events[start:] if event.get("session_id") == session
                              and event.get("type") == "message.complete"), None)
                if event:
                    assert not event.get("payload", {}).get("error"), "Native turn failed"
                    return event
                await self.read()


def prepare_source(source, root, patch):
    head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if head != BASE:
        raise ValueError("The source checkout must match the observer patch's exact base")
    archive = root / "source.tar"
    with archive.open("wb") as output:
        subprocess.run(["git", "-C", str(source), "archive", BASE], stdout=output, check=True)
    target = root / "source"
    target.mkdir()
    with tarfile.open(archive) as package:
        package.extractall(target, filter="data")
    archive.unlink()
    subprocess.run(["git", "apply", "--check", str(patch)], cwd=target, check=True)
    subprocess.run(["git", "apply", str(patch)], cwd=target, check=True)
    return {"base_commit": head, "observer_patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest()}


def environment(root, port, provider_port, relay):
    home = root / "hermes"
    for name in ("hermes", "user", "workspace", "tmp", "cache"):
        (root / name).mkdir(mode=0o700)
    base = f"http://127.0.0.1:{provider_port}/v1"
    config = {"model": {"provider": "custom", "default": MODEL, "base_url": base, "api_mode": "chat_completions",
                        "streaming": True, "context_length": 128000}, "gateway": {"multiplex_profiles": True},
              "approvals": {"mode": "manual", "timeout": 120}, "auxiliary": {"title_generation": {"enabled": False}},
              "terminal": {"backend": "local", "cwd": str(root / "workspace")}, "security": {"tirith_enabled": False},
              "platform_toolsets": {"cli": ["terminal", "clarify"]},
              "plugins": {"enabled": ["botto-push"], "entries": {"botto-push": {"settings": {"relay_url": relay}}}}}
    (home / "config.yaml").write_text(json.dumps(config, indent=2))
    (home / "install_id").write_text(INSTALL + "\n")
    env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "TZ") if key in os.environ}
    env.update(HOME=str(root / "user"), USERPROFILE=str(root / "user"), HERMES_HOME=str(home),
        HERMES_GATEWAY_LOCK_DIR=str(home / "locks"), XDG_CONFIG_HOME=str(root / "user/config"),
        XDG_CACHE_HOME=str(root / "cache"), TMPDIR=str(root / "tmp"),
        HERMES_DASHBOARD_BASIC_AUTH_USERNAME="botto-test", HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="botto-test",
        HERMES_DASHBOARD_BASIC_AUTH_SECRET="botto-disposable-local-signing-key-only",
        HERMES_DASHBOARD_PUBLIC_URL="http://botto-push-local.invalid", OPENAI_API_KEY="botto-local-no-real-credential",
        OPENAI_BASE_URL=base, NO_PROXY="127.0.0.1,localhost,::1", no_proxy="127.0.0.1,localhost,::1",
        PYTHONPATH=str(root / "source"), PYTHONUNBUFFERED="1", BOTTO_HOST_PORT=str(port), TIRITH_ENABLED="false",
        SSL_CERT_FILE=str(root / "relay.crt"))
    return env


def configure_profiles(root, env):
    code = "from hermes_cli.profiles import create_profile; create_profile('push-research', clone_from='default', clone_config=True, no_alias=True)"
    subprocess.run([sys.executable, "-c", code], cwd=root / "workspace", env=env, check=True,
                   stdout=subprocess.DEVNULL)
    for home in (root / "hermes", root / "hermes/profiles/push-research"):
        target = home / "plugins/botto-push"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(REPO / "Push/plugin", target,
                        ignore=shutil.ignore_patterns(".venv", "__pycache__", ".pytest_cache", "tests"))
        # The dashboard runs separately from lifecycle registration. Its persistent
        # configuration is intentionally established through the owner's CLI.
        cli_env = dict(env, HERMES_HOME=str(home), PYTHONPATH=os.pathsep.join([str(target), str(root / "source")]))
        with (root / "profile-setup.log").open("a") as output:
            subprocess.run([sys.executable, "-m", "botto_push", "--profile", "default" if home == root / "hermes" else "push-research",
                            "configure", env["BOTTO_RECORDING_RELAY"]], cwd=root / "workspace", env=cli_env,
                           stdout=output, stderr=subprocess.STDOUT, check=True)


async def wait_for(predicate, timeout=90):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except (OSError, ValueError) as error:
            last = type(error).__name__
        await asyncio.sleep(.25)
    raise TimeoutError("Readiness condition did not pass" + (": " + last if last else ""))


def recorded(relay, suffix=None):
    with relay.lock:
        records = list(relay.records)
    return [record for record in records if suffix is None or record["path"].endswith(suffix)]


def decrypt(event, installation, identifier, key):
    target = next(target for target in event["targets"] if target["device_id"] == identifier)
    raw = base64.b64decode(target["sealed"], validate=True)
    aad = f"botto-push:v1\n{installation}\n{identifier}\n{target['generation']}\n{event['event_id']}".encode()
    return json.loads(AESGCM(key).decrypt(raw[:12], raw[12:], aad))


async def verify_wait(client, profile, session, relay, provider, installation, identifier, key, kind, text):
    before = len(recorded(relay, "/events"))
    provider.disconnected_started.clear(); provider.disconnected_release.clear()
    await client.rpc("prompt.submit", profile=profile, session_id=session,
                     submission_id=uuid.uuid4().hex, text=text, queued=True)
    await wait_for(lambda: provider.disconnected_started.is_set(), 20)
    await client.ws.close()
    provider.disconnected_release.set()
    event_record = await wait_for(lambda: next((record for record in recorded(relay, "/events")[before:]
        if record["body"]["kind"] == kind and any(target["device_id"] == identifier
            for target in record["body"]["targets"])), None), 60)
    waiting = event_record["body"]
    preview = decrypt(waiting, installation, identifier, key)
    assert preview["profile_id"] == profile and preview["root_id"] == session
    assert waiting["request_id"] and "python3" not in preview["body"]
    await client.open()
    state = await client.rpc("session.resume", profile=profile, session_id=session, omit_messages=True)
    prompt = next(prompt for prompt in state["prompts"] if prompt["kind"] == ("approval" if kind == "approval" else "clarify"))
    start = len(client.events)
    method = "approval.respond" if kind == "approval" else "clarify.respond"
    answer = {"choice": "once"} if kind == "approval" else {"answer": "BOTTO_NOTE_ANSWER"}
    response = await client.rpc(method, profile=profile, session_id=session,
        execution_generation=prompt["execution_generation"], prompt_id=prompt["prompt_id"], **answer)
    assert response["status"] == "resolved"
    await wait_for(lambda: any(record["body"]["request_id"] == waiting["request_id"]
        for record in recorded(relay, "/cancellations")), 30)
    await client.complete(session, start)
    provider.disconnected_started.clear(); provider.disconnected_release.clear()
    print("PASS native " + kind + " wait -> encrypted alert -> exact resolution/cancellation: " + profile, flush=True)
    return {"kind": kind, "native_request_id": prompt["prompt_id"], "resolution_cancelled_same_request": True,
            "viewer_disconnected_while_waiting": True}


async def exercise(root, port, relay, provider, report):
    origin = f"http://127.0.0.1:{port}"
    await wait_for(lambda: json.load(OPENER.open(origin + "/api/status", timeout=2)).get("auth_required") is True, 150)
    client = Client(origin)
    await client.open()
    print("PASS ordinary gateway authentication and native authority handshake", flush=True)
    try:
        capabilities = await client.rpc("runtime.describe")
        assert "durable-admission-v1" in capabilities.get("capabilities", [])
        report["native_authority"] = True
        profiles = (await client.rpc("profiles.list", include_sessions=True))["profiles"]
        assert {"default", "push-research"}.issubset({profile["name"] for profile in profiles})
        report["profiles"] = []
        for profile in ("default", "push-research"):
            status_path = "/api/plugins/botto-push/status?" + urllib.parse.urlencode({"profile": profile})
            status = await wait_for(lambda: (state if (state := client.rest(status_path)).get("supported") else None), 60)
            assert status["capabilities"].get("native_session_events") == 1
            assert status["v"] == 1 and status["plugin_version"]
            print("PASS authenticated profile-scoped plugin status: " + profile, flush=True)
            identifier = uuid.uuid4().hex
            key = bytes(range(32)) if profile == "default" else bytes(reversed(range(32)))
            enrollment = {"v": 1, "operation_id": str(uuid.uuid4()), "device_id": identifier,
                "expected_generation": 0,
                "token": "ab" * 32, "bundle_id": "com.sree.botto", "environment": "sandbox",
                "preview_key": base64.b64encode(key).decode(),
                "preferences": {"replies": True, "requests": True, "failures": True, "previews": True}}
            endpoint = "/api/plugins/botto-push/devices?" + urllib.parse.urlencode({"profile": profile})
            response = client.rest(endpoint, enrollment)
            assert response["generation"] > 0 and response["device_id"] == identifier
            assert response["status"] == "accepted"
            assert client.rest(endpoint, enrollment) == response, "Enrollment retry changed its result"
            print("PASS idempotent encrypted device enrollment over authenticated HTTP: " + profile, flush=True)
            snapshot = await client.rpc("session.create", profile=profile, request_id=uuid.uuid4().hex,
                source="gui", title="Push native smoke", hidden=True, follow_profile_config=True)
            session = snapshot["session_id"]
            start = len(client.events)
            before = len(recorded(relay, "/events"))
            await client.rpc("prompt.submit", profile=profile, session_id=session, submission_id=uuid.uuid4().hex,
                             text="BOTTO_DISCONNECTED " + profile, queued=True)
            await wait_for(lambda: provider.disconnected_started.is_set(), 20)
            await client.ws.close()
            provider.disconnected_release.set()
            event_record = await wait_for(lambda: next((record for record in recorded(relay, "/events")[before:]
                if any(target["device_id"] == identifier for target in record["body"]["targets"])), None), 90)
            event = event_record["body"]
            preview = decrypt(event, response["installation_id"], identifier, key)
            assert event["kind"] == "reply" and "BOTTO_LOCAL_ACK" in preview["body"]
            assert preview["profile_id"] == profile and preview["root_id"] == session
            assert preview["stored_id"] and preview["v"] == 1
            assert "BOTTO_LOCAL_ACK" not in json.dumps(event), "Plaintext escaped encryption"
            wrong_key_rejected = False
            try:
                decrypt(event, response["installation_id"], identifier, bytes([255]) * 32)
            except InvalidTag:
                wrong_key_rejected = True
            assert wrong_key_rejected, "Negative crypto control did not fail"
            report["profiles"].append({"profile": profile, "installation_id": response["installation_id"],
                "session_id": session, "event_kind": event["kind"], "independent_decryption": True,
                "wrong_key_rejected": True, "viewer_disconnected_before_completion": True})
            await client.open()
            await client.rpc("session.resume", profile=profile, session_id=session, omit_messages=True)
            provider.disconnected_started.clear(); provider.disconnected_release.clear()
            print("PASS native reply -> encrypted plugin relay submission with viewer disconnected: " + profile, flush=True)
            if profile == "default":
                report["waiting_requests"] = []
                for kind, text in (("approval", "BOTTO_APPROVAL"), ("question", "BOTTO_QUESTION")):
                    report["waiting_requests"].append(await verify_wait(client, profile, session, relay, provider,
                        response["installation_id"], identifier, key, kind, text))
        report["passed"] = True
        report["scope"] = "Real Hermes native gateway -> plugin -> authenticated HTTPS recording relay; no APNs or device delivery"
    finally:
        if client.ws is not None:
            await client.ws.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--patch", type=Path, default=REPO / "Push/upstream/native-session-events.patch")
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--port", type=int, default=19239)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    root = args.runtime.resolve()
    if root.parent != Path("/tmp").resolve() or not root.name.startswith("botto-runtime-push-"):
        parser.error("Use a new private /tmp/botto-runtime-push-* directory")
    root.mkdir(mode=0o700, exist_ok=False)
    report = {"passed": False, "runtime": str(root), "python": sys.version,
              "supervisor_pid": os.getpid(), "started_at": int(time.time())}
    child = None
    relay = provider = None
    def interrupted(*_):
        raise KeyboardInterrupt
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        report.update(prepare_source(args.source.resolve(), root, args.patch.resolve()))
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-keyout", str(root / "relay.key"), "-out", str(root / "relay.crt"), "-subj", "/CN=127.0.0.1",
            "-addext", "subjectAltName=IP:127.0.0.1"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.chmod(root / "relay.key", 0o600)
        relay = ThreadingHTTPServer(("127.0.0.1", 0), RecordingRelay)
        relay.records = []; relay.rejections = []; relay.lock = threading.Lock()
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(root / "relay.crt", root / "relay.key")
        relay.socket = tls.wrap_socket(relay.socket, server_side=True)
        threading.Thread(target=relay.serve_forever, daemon=True).start()
        provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        provider.disconnected_started = threading.Event(); provider.disconnected_release = threading.Event()
        threading.Thread(target=provider.serve_forever, daemon=True).start()
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", args.port))
        origin = f"https://127.0.0.1:{relay.server_port}"
        env = environment(root, args.port, provider.server_port, origin)
        env["BOTTO_RECORDING_RELAY"] = origin
        configure_profiles(root, env)
        code = "import json, gateway.session_plugin_events as e; print(json.dumps({'module':e.__file__,'version':e.NATIVE_SESSION_EVENTS_VERSION}))"
        provenance = json.loads(subprocess.check_output([sys.executable, "-c", code], cwd=root / "workspace", env=env, text=True))
        assert Path(provenance["module"]).is_relative_to(root / "source")
        report["import_provenance"] = provenance
        command = [sys.executable, str(REPO / "scripts/dev-host/gateway_entry.py")]
        with (root / "gateway.log").open("w") as output:
            child = subprocess.Popen(command, cwd=root / "workspace", env=env, stdin=subprocess.DEVNULL,
                stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        report["gateway_pid"] = child.pid
        report["gateway_command"] = command
        (root / "process.json").write_text(json.dumps(report, indent=2) + "\n")
        asyncio.run(exercise(root, args.port, relay, provider, report))
        return 0
    except BaseException as error:
        report["error"] = type(error).__name__ + ": " + str(error)
        print("FAIL " + report["error"] + "; inspect " + str(root / "gateway.log"), file=sys.stderr)
        return 1
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        if provider is not None:
            provider.disconnected_release.set()
        if child is not None and child.poll() is None:
            with suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                with suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
        if relay is not None:
            report["recorded_request_count"] = len(recorded(relay))
            report["recorded_event_count"] = len(recorded(relay, "/events"))
            report["recording_rejections"] = relay.rejections
            relay.shutdown(); relay.server_close()
        if provider is not None:
            provider.shutdown(); provider.server_close()
        report["stopped_at"] = int(time.time())
        report["gateway_stopped"] = child is None or child.poll() is not None
        output = args.report.resolve() if args.report else root / "receipt.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
