#!/usr/bin/env python3
"""Exercise Hermes authority password auth and ticket WebSocket on the pinned host."""

import argparse
import asyncio
from collections import Counter
import http.cookiejar
import json
from pathlib import Path
import time
import urllib.request
import urllib.error
import uuid

from websockets.asyncio.client import connect

from host import INSTALL_ID


class Client:
    def __init__(self, origin):
        self.origin = origin
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.ws = None
        self.sequence = 0
        self.events = []
        self.server_requests = []

    def rest(self, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.origin + path, data=data,
            headers={"Content-Type": "application/json"})
        with self.http.open(req, timeout=20) as response:
            return json.load(response)

    async def open(self):
        # Never include login results, cookies or tickets in reports/output.
        self.rest("/auth/password-login", {"provider": "basic", "username": "botto-test", "password": "botto-test"})
        identity = self.rest("/api/auth/me")
        ticket = self.rest("/api/auth/ws-ticket", {})["ticket"]
        self.ws = await connect(self.origin.replace("http:", "ws:") + "/api/ws",
            subprotocols=["hermes-gateway-v1", "hermes-gateway-ticket." + ticket], max_size=8 * 1024 * 1024)
        ready = await asyncio.wait_for(self.ws.recv(), 20)
        ready = json.loads(ready)
        assert ready.get("params", {}).get("type") == "gateway.ready", ready
        assert ready["params"]["payload"].get("session_authority") is True, ready
        assert self.ws.subprotocol == "hermes-gateway-v1"
        await self.rpc("client.capabilities", server_requests=True)
        return ready["params"]["payload"], identity

    async def read(self):
        frame = json.loads(await asyncio.wait_for(self.ws.recv(), 60))
        if frame.get("method") == "event":
            self.events.append(frame["params"])
        elif frame.get("method") and "id" in frame:
            self.server_requests.append(frame)
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
                        raise RuntimeError(method + ": " + json.dumps(frame["error"]))
                    return frame["result"]

    async def complete(self, session_id, start):
        async with asyncio.timeout(90):
            while True:
                completed = next((event for event in self.events[start:] if
                    event.get("session_id") == session_id and event.get("type") == "message.complete"), None)
                if completed:
                    assert not completed["payload"].get("error"), completed
                    assert completed["payload"].get("status") != "error", completed
                    return completed
                await self.read()


async def exercise(args):
    client = Client(args.origin)
    for path, body in (("/api/auth/me", None), ("/api/auth/ws-ticket", {}),
            ("/auth/password-login", {"provider": "basic", "username": "botto-test", "password": "wrong-disposable-password"})):
        try:
            client.rest(path, body)
        except urllib.error.HTTPError as error:
            assert error.code == 401, (path, error.code)
        else:
            raise AssertionError("Expected unauthenticated/invalid-password 401: " + path)
    status = client.rest("/api/status")
    assert status["install_id"] == INSTALL_ID, status
    assert status["auth_required"] is True and "basic" in status["auth_providers"]
    ready, _ = await client.open()
    result = {"origin": args.origin, "gateway_ready": ready, "status": status, "negative_auth_401": True}
    try:
        result["runtime"] = await client.rpc("runtime.describe")
        result["profiles_before"] = await client.rpc("profiles.list", include_sessions=True)
        print("PASS password login, ws ticket, authority handshake, runtime.describe, profiles.list", flush=True)
        name = "botto-smoke-" + uuid.uuid4().hex[:8]
        result["created_profile"] = await client.rpc("profiles.create", name=name, clone_from="default",
            no_alias=True, mirror_credentials=False, share_auth=False,
            description="Disposable Botto native integration probe", soul="Use only the local deterministic provider.")
        assert result["created_profile"]["ok"] is True
        result["profile_description"] = await client.rpc("profiles.describe", name=name)
        profiles = await client.rpc("profiles.list", include_sessions=True)
        assert any(profile["name"] == name for profile in profiles["profiles"]), profiles
        result["profile"] = name
        print("PASS profiles.create + describe + list", flush=True)
        # Creation and serving are separate upstream operations. The ordinary
        # gateway's profile watcher adds the authority asynchronously.
        deadline = time.monotonic() + 65
        while name not in client.rest("/api/status").get("gateway_shared_with", []):
            assert time.monotonic() < deadline, "Created profile did not become served"
            await asyncio.sleep(.5)
        # Acquire a new socket after the served set changed.
        await client.ws.close()
        await client.open()
        request_id = uuid.uuid4().hex
        create_args = {"profile": name, "request_id": request_id, "source": "gui", "title": "Bot Chat",
                       "hidden": True, "follow_profile_config": True}
        snapshot = await client.rpc("session.create", **create_args)
        session_id = snapshot["session_id"]
        result["created_session"] = snapshot
        result["session_id"] = session_id
        same = await client.rpc("session.create", **create_args)
        assert same["session_id"] == session_id, same
        listing = await client.rpc("session.list", profile=name, title="Bot Chat", include_hidden=True)
        assert any(row.get("id") == session_id for row in listing["sessions"]), listing
        result["session_lookup"] = listing
        result["resumed"] = await client.rpc("session.resume", profile=name, session_id=session_id, omit_messages=True)
        print("PASS canonical Bot Chat create, stable request retry, exact title lookup, resume", flush=True)
        start = len(client.events)
        submission_id = uuid.uuid4().hex
        receipt = await client.rpc("prompt.submit", profile=name, session_id=session_id, submission_id=submission_id,
            text="BOTTO_HELLO", queued=True)
        result["admission"] = receipt
        result["completion"] = await client.complete(session_id, start)
        assert "BOTTO_LOCAL_ACK" in result["completion"]["payload"].get("text", ""), result["completion"]
        duplicate = await client.rpc("prompt.submit", profile=name, session_id=session_id, submission_id=submission_id,
            text="BOTTO_HELLO", queued=True)
        assert duplicate["admission_id"] == receipt["admission_id"], duplicate
        result["duplicate_receipt"] = duplicate
        result["receipt"] = await client.rpc("prompt.receipt", profile=name, session_id=session_id,
            admission_id=receipt["admission_id"], include_result=True)
        print("PASS durable prompt admission, stream completion, stable submission retry, receipt", flush=True)
        await client.ws.close()
        await client.open()
        resumed = await client.rpc("session.resume", profile=name, session_id=session_id)
        assert "BOTTO_LOCAL_ACK" in json.dumps(resumed["messages"]), resumed
        result["reconnected"] = resumed
        replay = await client.rpc("session.events.since", profile=name, session_id=session_id,
            last_sequence=snapshot["last_sequence"], replay_epoch=snapshot["replay_epoch"])
        result["replay"] = replay
        assert replay["count"] > 0, replay
        print("PASS fresh ticket reconnect, persisted transcript, session epoch replay", flush=True)
        if not args.skip_approval:
            start = len(client.events)
            admission = await client.rpc("prompt.submit", profile=name, session_id=session_id,
                submission_id=uuid.uuid4().hex, text="BOTTO_APPROVAL", queued=True)
            result["approval_admission"] = admission
            # Resume snapshots are the authority for controls. The command
            # classification/prompt is produced by real Hermes, not injected.
            deadline = time.monotonic() + 40
            prompt = None
            while time.monotonic() < deadline:
                state = await client.rpc("session.resume", profile=name, session_id=session_id, omit_messages=True)
                prompt = next((p for p in state["prompts"] if p["kind"] == "approval"), None)
                if prompt:
                    break
                if any(e.get("type") == "message.complete" and e.get("session_id") == session_id
                       for e in client.events[start:]):
                    raise AssertionError("Turn completed without an approval prompt")
                await asyncio.sleep(.2)
            assert prompt, "No approval snapshot within 40 seconds"
            result["approval_prompt"] = prompt
            answer = await client.rpc("approval.respond", profile=name, session_id=session_id,
                execution_generation=prompt["execution_generation"], prompt_id=prompt["prompt_id"], choice="once")
            result["approval_response"] = answer
            assert answer["status"] == "resolved", answer
            result["approval_completion"] = await client.complete(session_id, start)
            text = json.dumps(result["approval_completion"])
            assert "BOTTO_APPROVAL_OK" in text and "BOTTO_TOOL_DONE" in text, text
            print("PASS real approval prompt, generation-fenced approval.respond, harmless local terminal execution", flush=True)
        counts = Counter(event["type"] for event in client.events)
        result["event_counts"] = dict(counts)
        assert counts["message.delta"] > 0, counts
        result["passed"] = True
        print("PASS events: " + json.dumps(dict(counts), sort_keys=True), flush=True)
    finally:
        await client.ws.close()
        if args.report:
            Path(args.report).write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", default="http://127.0.0.1:19119")
    parser.add_argument("--report")
    parser.add_argument("--skip-approval", action="store_true")
    asyncio.run(exercise(parser.parse_args()))
