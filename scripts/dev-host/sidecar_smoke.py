#!/usr/bin/env python3
"""Prove the real 0.21.5 standalone wire, including durable-ID reconnect."""

import argparse
import asyncio
from collections import Counter
import json
from pathlib import Path
import urllib.error
import uuid

from websockets.asyncio.client import connect

from smoke import Client
from sidecar_host import INSTALL_ID, ROOT


class SidecarClient(Client):
    async def open(self):
        self.rest("/auth/password-login", {"provider": "basic", "username": "botto-test", "password": "botto-test"})
        self.rest("/api/auth/me")
        ticket = self.rest("/api/auth/ws-ticket", {})["ticket"]
        self.ws = await connect(self.origin.replace("http:", "ws:") + "/api/ws",
            subprotocols=["hermes-gateway-v1", "hermes-gateway-ticket." + ticket], max_size=8 * 1024 * 1024)
        frame = json.loads(await asyncio.wait_for(self.ws.recv(), 20))
        assert frame.get("params", {}).get("type") == "gateway.ready", frame
        ready = frame["params"]["payload"]
        assert ready.get("session_authority") in (None, False), ready
        assert self.ws.subprotocol == "hermes-gateway-v1"
        await self.rpc("client.capabilities", server_requests=True)
        return ready


async def exercise(args):
    client = SidecarClient(args.origin)
    for path, body in (("/api/auth/me", None), ("/api/auth/ws-ticket", {}),
            ("/auth/password-login", {"provider": "basic", "username": "botto-test", "password": "wrong-disposable-password"})):
        try:
            client.rest(path, body)
        except urllib.error.HTTPError as error:
            assert error.code == 401, (path, error.code)
        else:
            raise AssertionError("Expected unauthenticated/invalid-password 401: " + path)
    status = client.rest("/api/status")
    assert status["install_id"] == INSTALL_ID and status["auth_required"] is True, status
    ready = await client.open()
    report = {"origin": args.origin, "status": status, "gateway_ready": ready, "negative_auth_401": True}
    try:
        report["profiles_before"] = await client.rpc("profiles.list", include_sessions=True)
        print("PASS password auth, negative 401 checks, ticket WS, sidecar handshake (authority absent)", flush=True)
        name = "botto-sidecar-" + uuid.uuid4().hex[:8]
        report["created_profile"] = await client.rpc("profiles.create", name=name, clone_from="default",
            no_alias=True, mirror_credentials=False, share_auth=False, description="Disposable Botto sidecar probe",
            soul="Use the local deterministic provider.")
        assert report["created_profile"]["ok"] is True
        report["profile"] = name
        report["profile_description"] = await client.rpc("profiles.describe", name=name)
        profiles = await client.rpc("profiles.list", include_sessions=True)
        assert any(row["name"] == name for row in profiles["profiles"]), profiles
        print("PASS real profiles.list/create/describe", flush=True)
        report["initial_title_lookup"] = await client.rpc("session.list", profile=name, title="Bot Chat", include_hidden=True)
        created = await client.rpc("session.create", profile=name, title="Bot Chat", hidden=True,
            follow_profile_config=True, source="gui", close_on_disconnect=False)
        report["created_session"] = created
        live_id = created["session_id"]
        stored_id = created.get("stored_session_id") or created.get("session_key")
        assert stored_id and stored_id != live_id, created
        report["runtime_id"] = live_id
        report["stored_id"] = stored_id
        # Persist the canonical title using the native sidecar contract.
        report["title"] = await client.rpc("session.title", profile=name, session_id=live_id, title="Bot Chat")
        report["initial_resume"] = await client.rpc("session.resume", profile=name, session_id=stored_id,
            source="gui", close_on_disconnect=False, omit_messages=True)
        assert report["initial_resume"]["session_id"] == live_id, report["initial_resume"]
        print("PASS sidecar canonical Bot Chat create/title/resume, distinct stored/runtime IDs, source=gui", flush=True)
        start = len(client.events)
        report["submit"] = await client.rpc("prompt.submit", profile=name, session_id=live_id,
            text="BOTTO_SIDECAR_HELLO", queued=True)
        assert report["submit"]["status"] in ("streaming", "queued"), report["submit"]
        report["completion"] = await client.complete(live_id, start)
        assert "BOTTO_LOCAL_ACK" in report["completion"]["payload"].get("text", ""), report["completion"]
        listing = await client.rpc("session.list", profile=name, title="Bot Chat", include_hidden=True)
        assert any(row["id"] == stored_id for row in listing["sessions"]), listing
        report["canonical_lookup"] = listing
        await client.ws.close()
        report["reopened_gateway_ready"] = await client.open()
        resumed = await client.rpc("session.resume", profile=name, session_id=stored_id, source="gui",
            close_on_disconnect=False)
        report["reopened_session"] = resumed
        live_id = resumed["session_id"]
        assert "BOTTO_LOCAL_ACK" in json.dumps(resumed["messages"]), resumed
        report["reopened_runtime_id"] = live_id
        replay = await client.rpc("session.events.since", profile=name, session_id=live_id, last_seen=0)
        report["replay"] = replay
        assert replay["count"] > 0, replay
        print("PASS prompt streaming, stored-title lookup, close/reopen with close_on_disconnect=false, history/replay", flush=True)
        start = len(client.events)
        request_start = len(client.server_requests)
        report["approval_submit"] = await client.rpc("prompt.submit", profile=name, session_id=live_id,
            text="BOTTO_APPROVAL", queued=True)
        async with asyncio.timeout(60):
            while True:
                request = next((frame for frame in client.server_requests[request_start:]
                    if frame.get("method") == "approval" and frame.get("params", {}).get("session_id") == live_id), None)
                if request:
                    break
                if any(event.get("type") == "message.complete" and event.get("session_id") == live_id
                       for event in client.events[start:]):
                    raise AssertionError("Approval turn completed without its server request")
                await client.read()
        report["approval_request"] = request
        params = request["params"]
        assert params["request_id"] and "BOTTO_APPROVAL_OK" in params["command"], request
        # Reopen while the approval is pending, to prove it belongs to the
        # persistent sidecar session rather than to one socket generation.
        await client.ws.close()
        await client.open()
        pending = await client.rpc("session.resume", profile=name, session_id=stored_id, source="gui",
            close_on_disconnect=False, omit_messages=True)
        report["pending_approval_resume"] = pending
        assert pending["pending_approval"]["request_id"] == params["request_id"], pending
        assert any(frame.get("params", {}).get("request_id") == params["request_id"]
                   for frame in pending["open_requests"]), pending
        live_id = pending["session_id"]
        report["approval_response"] = await client.rpc("approval.respond", profile=name,
            session_id=live_id, request_id=params["request_id"], choice="once")
        assert report["approval_response"].get("resolved"), report["approval_response"]
        report["approval_completion"] = await client.complete(live_id, start)
        final = json.dumps(report["approval_completion"])
        assert "BOTTO_TOOL_DONE" in final and "BOTTO_APPROVAL_OK" in final, final
        counts = Counter(event["type"] for event in client.events)
        assert counts["message.delta"] > 0 and counts["tool.complete"] > 0, counts
        report["event_counts"] = dict(counts)
        report["passed"] = True
        print("PASS real sidecar approval request, reconnect while pending, request_id response, harmless terminal execution", flush=True)
        print("PASS events: " + json.dumps(dict(counts), sort_keys=True), flush=True)
    finally:
        await client.ws.close()
        Path(args.report).write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", default="http://127.0.0.1:19121")
    parser.add_argument("--report", default=str(ROOT / "smoke-result.json"))
    asyncio.run(exercise(parser.parse_args()))
