from __future__ import annotations

import asyncio
from pathlib import Path
import sys
import tempfile
import unittest

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from botto_push.api import create_router
from botto_push.service import PushService
from test_plugin import Relay, enrollment


class HTTPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.relay = Relay()
        self.service = PushService(Path(self.temp.name), "default", "https://push.example", self.relay)
        self.service.mark_runtime(1)
        self.app = FastAPI()

        def require_owner(authorization: str | None = Header(default=None)):
            if authorization != "Bearer fixture-owner":
                raise HTTPException(401)

        self.app.include_router(create_router(lambda: self.service), prefix="/api/plugins/botto-push", dependencies=[Depends(require_owner)])
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="https://hermes.example")
        self.addAsyncCleanup(self.client.aclose)

    async def test_mounted_boundary_preserves_auth_and_never_returns_keys(self):
        denied = await self.client.get("/api/plugins/botto-push/status")
        self.assertEqual(denied.status_code, 401)
        request = enrollment()
        enrolled = await self.client.post("/api/plugins/botto-push/devices", json=request, headers={"Authorization": "Bearer fixture-owner"})
        self.assertEqual(enrolled.status_code, 200)
        self.assertEqual(enrolled.json()["generation"], 1)
        self.assertEqual(enrolled.headers["Cache-Control"], "no-store")
        status = await self.client.get("/api/plugins/botto-push/status", headers={"Authorization": "Bearer fixture-owner"})
        self.assertTrue(status.json()["supported"])
        self.assertEqual(status.json()["capabilities"], {"native_session_events": 1})
        self.assertNotIn(self.service.token, status.text)
        self.assertNotIn(request["preview_key"], status.text)

    async def test_invalid_fields_or_profile_cannot_enroll(self):
        request = enrollment()
        request["visible_chat"] = {"profile_id": "other", "root_id": "root", "stored_id": "stored"}
        denied = await self.client.post("/api/plugins/botto-push/devices", json=request, headers={"Authorization": "Bearer fixture-owner"})
        self.assertEqual(denied.status_code, 403)
        request.pop("visible_chat")
        request["unexpected"] = "value"
        invalid = await self.client.post("/api/plugins/botto-push/devices", json=request, headers={"Authorization": "Bearer fixture-owner"})
        self.assertEqual(invalid.status_code, 400)
        self.assertEqual(len(self.relay.requests), 0)

    async def test_invalid_json_size_and_unpatched_runtime_have_explicit_errors(self):
        headers = {"Authorization": "Bearer fixture-owner", "Content-Type": "application/json"}
        duplicate = await self.client.post("/api/plugins/botto-push/devices", content=b'{"v":1,"v":1}', headers=headers)
        self.assertEqual(duplicate.status_code, 400)
        self.assertEqual(duplicate.headers["Cache-Control"], "no-store")
        large = await self.client.post("/api/plugins/botto-push/devices", content=b" " * 32769, headers=headers)
        self.assertEqual(large.status_code, 413)
        self.service.mark_runtime(0)
        unavailable = await self.client.post("/api/plugins/botto-push/devices", json=enrollment(), headers=headers)
        self.assertEqual(unavailable.status_code, 409)
        self.assertEqual(len(self.relay.requests), 0)

    async def test_completed_removal_remains_visible_and_blocks_initial_replay(self):
        import uuid
        headers = {"Authorization": "Bearer fixture-owner"}
        original = enrollment()
        enrolled = await self.client.post("/api/plugins/botto-push/devices", json=original, headers=headers)
        self.assertEqual(enrolled.status_code, 200)
        removed = await self.client.post("/api/plugins/botto-push/devices/" + original["device_id"] + "/remove",
                                         json={"v": 1, "operation_id": str(uuid.uuid4())}, headers=headers)
        self.assertEqual(removed.json()["status"], "revoked")
        status = await self.client.get("/api/plugins/botto-push/status", headers=headers)
        record = status.json()["devices"][0]
        self.assertEqual((record["state"], record["active"], record["pending_removal"]), ("removed", False, False))
        replay = await self.client.post("/api/plugins/botto-push/devices", json=original, headers=headers)
        self.assertEqual(replay.status_code, 409)

    async def test_enrollment_requires_integer_generation_precondition(self):
        headers = {"Authorization": "Bearer fixture-owner"}
        original = enrollment()
        for value in (None, True, -1, 0.0, "0"):
            request = {**original, "expected_generation": value}
            response = await self.client.post("/api/plugins/botto-push/devices", json=request, headers=headers)
            self.assertEqual(response.status_code, 400)
        original.pop("expected_generation")
        response = await self.client.post("/api/plugins/botto-push/devices", json=original, headers=headers)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(len(self.relay.requests), 0)


if __name__ == "__main__":
    unittest.main()
