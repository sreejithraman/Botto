from __future__ import annotations

import base64
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import uuid

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from botto_push.service import PushService
from botto_push.contracts import PushError
from botto_push.runtime import Runtime, configured_service
from botto_push.__main__ import main as plugin_cli


class Relay:
    def __init__(self):
        self.requests = []
        self.available = True

    def send(self, method, path, body, token):
        self.requests.append((method, path, body, token))
        if not self.available:
            raise OSError("offline")
        return {"v": 1, "status": "accepted"}


def enrollment(device="a" * 32, operation=None):
    return {
        "v": 1, "operation_id": operation or str(uuid.uuid4()),
        "expected_generation": 0,
        "device_id": device, "token": "ab" * 32, "bundle_id": "com.sree.botto",
        "environment": "sandbox", "preview_key": base64.b64encode(bytes(range(32))).decode(),
        "preferences": {"replies": True, "requests": True, "failures": True, "previews": True},
        "visible_chat": None, "visible_until": 0,
    }


def native_event(**changes):
    return {"v": 1, "type": "turn.completed", "event_id": "source-turn-one", "profile_id": "default",
            "root_id": "root", "stored_id": "stored", "execution_generation": 3, "turn_id": "turn-one",
            "is_subagent": False, "title": "Milo", "created_at": 1_800_000_000, "request_id": None,
            "kind": "reply", "meaningful": True, "preview": "The private reply is ready.", **changes}


class PluginTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.relay = Relay()
        self.now = 1_800_000_000
        self.service = PushService(Path(self.temp.name), "default", "https://push.example", self.relay, now=lambda: self.now)
        self.service.mark_runtime(1)

    def test_enrollment_is_idempotent_and_profile_bound(self):
        request = enrollment()
        first = self.service.enroll(request)
        retry = self.service.enroll(request)
        self.assertEqual(first, retry)
        self.assertEqual(first["status"], "accepted")
        self.assertEqual(first["generation"], 1)
        self.assertEqual(len(self.relay.requests), 1)
        record = self.relay.requests[0][2]
        self.assertNotIn("preview_key", json.dumps(record))
        self.assertEqual(record["generation"], 1)
        self.assertEqual(self.service.status()["devices"][0]["device_id"], "a" * 32)

    def test_shared_payload_boundary_keeps_preview_or_falls_back_before_admission(self):
        fixture = json.loads((Path(__file__).resolve().parents[2] / "fixtures" / "payload-boundary.json").read_text())
        self.service.enroll(enrollment())
        preview = fixture["plaintext"]
        for index, body in enumerate([preview["body"], "\n" * 1024]):
            self.service.produce(native_event(event_id=f"boundary-{index}", title=preview["title"], preview=body,
                root_id=preview["root_id"], stored_id=preview["stored_id"]))
            self.service.flush()
            event = self.relay.requests[-1][2]
            target = event["targets"][0]
            sealed = base64.b64decode(target["sealed"])
            aad = f"botto-push:v1\n{self.service.installation}\n{target['device_id']}\n1\n{event['event_id']}".encode()
            clear = json.loads(AESGCM(bytes(range(32))).decrypt(sealed[:12], sealed[12:], aad))
            self.assertEqual(clear["root_id"], preview["root_id"])
            self.assertEqual(clear["stored_id"], preview["stored_id"])
            self.assertEqual(clear["title"], preview["title"] if index == 0 else "")
            self.assertEqual(clear["body"], body if index == 0 else "")
            if index == 0:
                self.assertEqual(len(target["sealed"]), fixture["expected"]["sealed_characters"])
                self.assertEqual(len(sealed), fixture["expected"]["combined_bytes"])

    def test_remove_is_durable_and_old_enrollment_cannot_restore_it(self):
        request = enrollment()
        self.service.enroll(request)
        removal = {"v": 1, "operation_id": str(uuid.uuid4())}
        self.relay.available = False
        self.assertEqual(self.service.remove("a" * 32, removal)["status"], "pending")
        pending = self.service.status()["devices"]
        self.assertEqual(len(pending), 1)
        self.assertFalse(pending[0]["active"])
        self.assertTrue(pending[0]["pending_removal"])
        restarted = PushService(Path(self.temp.name), "default", "https://push.example", self.relay, now=lambda: self.now)
        self.relay.available = True
        self.now += 2
        restarted.flush()
        self.assertEqual(restarted.remove("a" * 32, removal)["status"], "revoked")
        with self.assertRaises(PushError):
            restarted.enroll(request)
        changed = enrollment("b" * 32)
        self.assertEqual(restarted.enroll(changed)["generation"], 1)
        self.assertEqual(restarted.status()["devices"][0]["state"], "removed")

    def test_presence_renewal_keeps_generation_and_key(self):
        request = enrollment()
        self.service.enroll(request)
        request["operation_id"] = str(uuid.uuid4())
        request["expected_generation"] = 1
        request.pop("preview_key")
        request["visible_chat"] = {"profile_id": "default", "root_id": "root", "stored_id": "stored"}
        request["visible_until"] = self.now + 999
        result = self.service.enroll(request)
        self.assertEqual(result["generation"], 1)
        self.assertTrue(self.relay.requests[-1][1].endswith("/presence"))
        presence = self.relay.requests[-1][2]
        self.assertEqual(presence["revision"], 1)
        self.assertEqual(presence["visible_until"], self.now + 90)
        self.assertNotIn("profile", json.dumps(presence))

    def test_expired_receipt_retry_recovers_rejected_or_expired_registration(self):
        for mode in ("exhausted", "expired"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                clock = [1_800_000_000]
                relay = Relay()
                service = PushService(Path(directory), "default", "https://push.example", relay, now=lambda: clock[0])
                service.mark_runtime(1)
                other = enrollment("b" * 32)
                service.enroll(other)
                request = enrollment()
                relay.available = False
                self.assertEqual(service.enroll(request)["status"], "pending")
                if mode == "exhausted":
                    for _ in range(7):
                        clock[0] += 61
                        service.flush()
                clock[0] += 86401
                service.mark_runtime(1)
                relay.available = True
                # A matching read collects receipts without draining old jobs.
                other["operation_id"] = str(uuid.uuid4())
                self.assertEqual(service.enroll(other)["status"], "accepted")
                before = len(relay.requests)

                recovered = service.enroll(request)

                self.assertEqual((recovered["status"], recovered["generation"]), ("accepted", 1))
                self.assertEqual(len(relay.requests), before + 1)
                self.assertTrue(relay.requests[-1][1].endswith("/devices/" + request["device_id"]))
                self.assertEqual(relay.requests[-1][2]["generation"], 1)

    def test_setup_readiness_requires_the_loaded_producer_configuration(self):
        directory = Path(self.temp.name) / "unconfigured"
        producer = PushService(directory, "default", None)
        producer.mark_runtime(1)
        with redirect_stdout(io.StringIO()):
            self.assertEqual(plugin_cli(["--data-dir", str(directory), "--profile", "default", "configure", "https://push.example"]), 0)
        dashboard = configured_service(directory, profile="default")

        status = dashboard.status()

        self.assertFalse(status["supported"])
        self.assertIn("Reload", status["reason"])
        with self.assertRaises(PushError):
            dashboard.enroll(enrollment())
        with self.assertRaises(PushError):
            producer.produce(native_event(created_at=int(time.time())))
        reloaded = configured_service(directory, profile="default")
        reloaded.mark_runtime(1)
        self.assertTrue(dashboard.status()["supported"])
        self.assertEqual(reloaded.produce(native_event(created_at=int(time.time())))["status"], "accepted")

    def test_revoked_presence_cannot_confirm_enrollment_or_produce_for_dead_target(self):
        request = enrollment()
        self.service.enroll(request)
        self.relay.send = lambda *_: {"v": 1, "status": "revoked"}
        request["operation_id"] = str(uuid.uuid4())
        request["expected_generation"] = 1
        self.assertEqual(self.service.enroll(request)["status"], "revoked")
        self.assertFalse(self.service.status()["devices"][0]["active"])
        self.service.produce(native_event())
        self.assertEqual(self.service.status()["delivery"]["queued"], 0)
        self.assertEqual(self.service.enroll(request)["status"], "revoked")
        self.relay.send = lambda *_: {"v": 1, "status": "accepted"}
        request["operation_id"] = str(uuid.uuid4())
        request["token"] = "cd" * 32
        recovered = self.service.enroll(request)
        self.assertEqual((recovered["status"], recovered["generation"]), ("accepted", 2))

    def test_revoked_registration_is_not_success(self):
        self.relay.send = lambda *_: {"v": 1, "status": "revoked"}
        self.assertEqual(self.service.enroll(enrollment())["status"], "revoked")
        self.assertFalse(self.service.status()["devices"][0]["active"])

    def test_event_outcomes_keep_wire_spelling_and_retire_invalid_targets(self):
        self.service.enroll(enrollment())
        self.relay.send = lambda *_: {"v": 1, "status": "permanent_failure"}
        self.service.produce(native_event())
        self.service.flush()
        self.assertEqual(self.service.status()["delivery"]["last_status"], "permanent_failure")
        self.relay.send = lambda *_: {"v": 1, "status": "invalid_target"}
        self.service.produce(native_event(event_id="second"))
        self.service.flush()
        self.assertEqual(self.service.status()["delivery"]["last_status"], "invalid_target")
        self.assertFalse(self.service.status()["devices"][0]["active"])

    def test_loaded_observer_keeps_admitting_events_during_slow_successful_drain(self):
        self.service.enroll(enrollment())
        runtime = Runtime(self.service, 1)
        for index in range(12):
            self.service.produce(native_event(event_id=f"backlog-{index}"))
        original = self.relay.send
        def slow_send(method, path, body, token):
            self.now += 4
            if self.now == 1_800_000_048:
                runtime.observe(event=native_event(event_id="during-drain", created_at=self.now))
            return original(method, path, body, token)
        self.relay.send = slow_send
        self.service.flush()
        events = [request for request in self.relay.requests if request[1].endswith("/events")]
        self.assertEqual(len(events), 13)
        self.assertTrue(self.service.status()["supported"])

    def test_idle_producer_stays_supported_during_another_callers_slow_bulk_drain(self):
        self.service.enroll(enrollment())
        for index in range(12):
            self.service.produce(native_event(event_id=f"backlog-{index}"))
        entered, release_first, release_last = threading.Event(), threading.Event(), threading.Event()
        initial_tick, fresh_tick = threading.Event(), threading.Event()
        delivered_after_bulk = threading.Event()
        started_at = self.now

        def clock():
            if threading.current_thread().name == "botto-push-outbox":
                if self.now == started_at:
                    initial_tick.set()
                elif self.now >= started_at + 48:
                    fresh_tick.set()
            return self.now

        producer = PushService(Path(self.temp.name), "default", "https://push.example", self.relay, now=clock)
        runtime = Runtime(producer, 1)
        original_send = self.relay.send
        calls, failures = [], []

        def slow_send(method, path, body, token):
            calls.append(body)
            if len(calls) == 1:
                entered.set()
                if not release_first.wait(5):
                    raise TimeoutError("First relay response was not released.")
            self.now += 4
            if len(calls) == 12 and not release_last.wait(5):
                raise TimeoutError("Last relay response was not released.")
            response = original_send(method, path, body, token)
            if len(calls) == 13:
                delivered_after_bulk.set()
            return response

        def drain():
            try:
                self.service.flush()
            except Exception as error:
                failures.append(error)

        self.relay.send = slow_send
        sender = threading.Thread(target=drain)
        sender.start()
        try:
            self.assertTrue(entered.wait(3))
            runtime.start()
            self.assertTrue(initial_tick.wait(3))
            release_first.set()
            fresh_tick.wait(3)
            self.assertEqual(self.now - started_at, 48)
            status = self.service.status()
            self.assertTrue(status["supported"])
            self.assertIsNone(status["reason"])
            self.assertGreater(status["delivery"]["queued"], 0)
            release_last.set()
            sender.join(timeout=5)
            self.service.produce(native_event(event_id="after-bulk", created_at=self.now))
            self.assertTrue(delivered_after_bulk.wait(3))
        finally:
            release_first.set()
            release_last.set()
            sender.join(timeout=5)
            runtime.close()
        self.assertFalse(sender.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(len(calls), 13)
        self.assertEqual(self.now - started_at, 52)
        self.assertEqual(self.service.status()["delivery"]["queued"], 0)
        self.assertFalse(self.service.status()["supported"])

    def test_native_event_encrypts_for_each_device_without_plaintext_in_relay(self):
        self.service.enroll(enrollment())
        other = enrollment("b" * 32)
        other["preview_key"] = base64.b64encode(b"x" * 32).decode()
        self.service.enroll(other)
        event = native_event()
        self.service.produce(event)
        self.service.flush()
        calls = [r for r in self.relay.requests if r[1].endswith("/events")]
        self.assertEqual(len(calls), 2)
        for _, _, body, _ in calls:
            self.assertNotIn("private", json.dumps(body))
            target = body["targets"][0]
            key = bytes(range(32)) if target["device_id"] == "a" * 32 else b"x" * 32
            sealed = base64.b64decode(target["sealed"])
            aad = f"botto-push:v1\n{self.service.installation}\n{target['device_id']}\n1\n{body['event_id']}".encode()
            preview = json.loads(AESGCM(key).decrypt(sealed[:12], sealed[12:], aad))
            self.assertEqual(preview, {"v": 1, "title": "Milo", "body": event["preview"],
                                       "profile_id": "default", "root_id": "root", "stored_id": "stored"})
        self.service.produce(event)
        self.service.flush()
        self.assertEqual(len([r for r in self.relay.requests if r[1].endswith("/events")]), 2)

    def test_silent_subagent_interrupted_and_old_events_do_not_send(self):
        self.service.enroll(enrollment())
        for event in [native_event(meaningful=False), native_event(is_subagent=True),
                      native_event(type="turn.interrupted"), native_event(created_at=self.now - 4000)]:
            self.service.produce(event)
        self.service.flush()
        self.assertEqual(len([r for r in self.relay.requests if r[1].endswith("/events")]), 0)

    def test_resolved_wait_cancels_before_send_and_cannot_reappear(self):
        self.service.enroll(enrollment())
        event = native_event(type="request.waiting", kind="approval", request_id="actual-prompt", expires_at=self.now + 300)
        self.service.produce(event)
        self.service.produce({**event, "type": "request.resolved", "event_id": "resolved", "meaningful": False})
        self.service.flush()
        self.now += 2
        self.service.flush()
        self.assertEqual(len([r for r in self.relay.requests if r[1].endswith("/events")]), 0)
        self.assertTrue(any(r[1].endswith("/cancellations") for r in self.relay.requests))
        self.assertEqual(self.service.produce(event)["status"], "cancelled")

    def test_private_preference_keeps_encrypted_route_but_removes_preview(self):
        request = enrollment()
        request["preferences"]["previews"] = False
        self.service.enroll(request)
        self.service.produce(native_event())
        self.service.flush()
        body = self.relay.requests[-1][2]
        box = base64.b64decode(body["targets"][0]["sealed"])
        aad = f"botto-push:v1\n{self.service.installation}\n{'a' * 32}\n1\n{body['event_id']}".encode()
        plaintext = json.loads(AESGCM(bytes(range(32))).decrypt(box[:12], box[12:], aad))
        self.assertEqual(plaintext["title"], "")
        self.assertEqual(plaintext["body"], "")
        self.assertEqual(plaintext["root_id"], "root")

    def test_unknown_outcome_never_claims_success_or_failure(self):
        self.service.enroll(enrollment())
        self.service.produce(native_event(type="turn.unknown", kind="failure", preview="The turn's outcome is unknown."))
        self.service.flush()
        body = self.relay.requests[-1][2]
        box = base64.b64decode(body["targets"][0]["sealed"])
        aad = f"botto-push:v1\n{self.service.installation}\n{'a' * 32}\n1\n{body['event_id']}".encode()
        plaintext = json.loads(AESGCM(bytes(range(32))).decrypt(box[:12], box[12:], aad))
        self.assertEqual(plaintext["body"], "The turn's outcome is unknown.")

    def test_pairing_keys_do_not_survive_removal_and_other_device_keeps_working(self):
        self.service.enroll(enrollment())
        self.service.enroll(enrollment("b" * 32))
        self.service.remove("a" * 32, {"v": 1, "operation_id": str(uuid.uuid4())})
        self.service.produce(native_event())
        self.service.flush()
        targets = [r[2]["targets"][0]["device_id"] for r in self.relay.requests if r[1].endswith("/events")]
        self.assertEqual(targets, ["b" * 32])
        with self.service.storage.transaction() as db:
            self.assertIsNone(db.execute("SELECT key FROM devices WHERE id=?", ("a" * 32,)).fetchone()[0])

    def test_unpatched_or_unloaded_runtime_does_not_offer_enrollment(self):
        self.service.mark_runtime(0)
        self.assertFalse(self.service.status()["supported"])
        with self.assertRaises(PushError):
            self.service.enroll(enrollment())
        self.assertEqual(self.relay.requests, [])

    def test_conflicting_operation_and_oversized_identity_are_rejected(self):
        request = enrollment()
        self.service.enroll(request)
        request["token"] = "cd" * 32
        with self.assertRaises(PushError) as context:
            self.service.enroll(request)
        self.assertEqual(context.exception.status, 409)
        with self.assertRaises(PushError):
            self.service.produce(native_event(root_id="x" * 513))

    def test_restart_retries_same_ciphertext_and_expires_old_events(self):
        self.service.enroll(enrollment())
        self.service.produce(native_event())
        self.relay.available = False
        self.service.flush()
        original = self.relay.requests[-1][2]
        recovered = PushService(Path(self.temp.name), "default", "https://push.example", self.relay, now=lambda: self.now)
        self.now += 2
        self.relay.available = True
        recovered.flush()
        self.assertEqual(self.relay.requests[-1][2], original)
        self.assertEqual(len([r for r in self.relay.requests if r[1].endswith("/events")]), 2)
        recovered.mark_runtime(1)
        recovered.produce(native_event(event_id="second"))
        self.now += 3601
        recovered.flush()
        self.assertEqual(len([r for r in self.relay.requests if r[1].endswith("/events")]), 2)

    def test_storage_is_private_and_unknown_removal_is_bounded(self):
        self.assertEqual(self.service.storage.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(Path(self.temp.name).stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.service.remove("f" * 32, {"v": 1, "operation_id": str(uuid.uuid4())})["status"], "revoked")
        with self.service.storage.transaction() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM devices").fetchone()[0], 1)
        self.assertTrue(self.relay.requests[0][1].endswith("/revoke"))
        self.assertEqual(self.service.status()["devices"][0]["state"], "removed")

    def test_removed_pairing_stays_removed_after_receipt_cleanup_and_old_retry(self):
        original = enrollment()
        self.service.enroll(original)
        self.service.remove("a" * 32, {"v": 1, "operation_id": str(uuid.uuid4())})
        self.now += 86401
        self.service.mark_runtime(1)
        self.service.enroll(enrollment("b" * 32))
        calls_before = len(self.relay.requests)
        with self.assertRaises(PushError) as context:
            self.service.enroll(original)
        self.assertEqual(context.exception.status, 409)
        self.assertEqual(len(self.relay.requests), calls_before)
        self.service.produce(native_event(created_at=self.now))
        self.service.flush()
        targets = [call[2]["targets"][0]["device_id"] for call in self.relay.requests if call[1].endswith("/events")]
        self.assertEqual(targets, ["b" * 32])
        removed = next(device for device in self.service.status()["devices"] if device["device_id"] == "a" * 32)
        self.assertEqual((removed["state"], removed["generation"], removed["active"], removed["pending_removal"]),
                         ("removed", 2, False, False))
        with self.assertRaises(PushError):
            self.service.enroll({**original, "operation_id": str(uuid.uuid4()), "expected_generation": 2,
                                 "preview_key": base64.b64encode(b"z" * 32).decode()})
        fresh = enrollment("c" * 32)
        fresh["preview_key"] = base64.b64encode(b"z" * 32).decode()
        self.assertEqual(self.service.enroll(fresh)["status"], "accepted")

    def test_unknown_removal_fences_delayed_initial_enrollment(self):
        delayed = enrollment()
        removal = self.service.remove("a" * 32, {"v": 1, "operation_id": str(uuid.uuid4())})
        self.assertTrue(removal["remote_confirmed"])
        self.assertEqual(self.relay.requests[0][2], {"v": 1, "generation": 1})
        with self.assertRaises(PushError) as context:
            self.service.enroll(delayed)
        self.assertEqual(context.exception.status, 409)
        self.assertEqual(len(self.relay.requests), 1)

    def test_initial_retry_after_receipt_cleanup_is_only_an_exact_noop(self):
        original = enrollment()
        self.service.enroll(original)
        self.now += 86401
        self.service.mark_runtime(1)
        self.service.enroll(enrollment("b" * 32))
        visible = {**original, "operation_id": str(uuid.uuid4()), "expected_generation": 1,
                   "visible_chat": {"profile_id": "default", "root_id": "root", "stored_id": "stored"},
                   "visible_until": self.now + 90}
        self.service.enroll(visible)
        before = len(self.relay.requests)
        self.assertEqual(self.service.enroll(original)["generation"], 1)
        self.assertEqual(len(self.relay.requests), before)
        self.service.produce(native_event(created_at=self.now))
        self.service.flush()
        targets = [call[2]["targets"][0]["device_id"] for call in self.relay.requests if call[1].endswith("/events")]
        self.assertEqual(targets, ["b" * 32])
        stale_changed = {**original, "operation_id": str(uuid.uuid4()), "token": "cd" * 32}
        with self.assertRaises(PushError):
            self.service.enroll(stale_changed)

    def test_generation_precondition_blocks_stale_updates_and_allows_token_rotation(self):
        original = enrollment()
        self.service.enroll(original)
        rotation = {**original, "operation_id": str(uuid.uuid4()), "expected_generation": 1, "token": "cd" * 32}
        self.assertEqual(self.service.enroll(rotation)["generation"], 2)
        stale = {**original, "operation_id": str(uuid.uuid4()), "expected_generation": 1}
        before = len(self.relay.requests)
        with self.assertRaises(PushError):
            self.service.enroll(stale)
        self.assertEqual(len(self.relay.requests), before)
        with self.assertRaises(PushError):
            self.service.enroll({**original, "operation_id": str(uuid.uuid4())})
        valid = {**rotation, "operation_id": str(uuid.uuid4()), "expected_generation": 2,
                 "preferences": {**original["preferences"], "previews": False}}
        self.assertEqual(self.service.enroll(valid)["generation"], 3)

    def test_uncertain_update_after_receipt_cleanup_confirms_only_exact_current_key_state(self):
        original = enrollment()
        self.service.enroll(original)
        update = {**original, "operation_id": str(uuid.uuid4()), "expected_generation": 1, "token": "cd" * 32}
        update.pop("preview_key")
        self.assertEqual(self.service.enroll(update)["generation"], 2)
        self.now += 86401
        self.service.mark_runtime(1)
        self.service.enroll(enrollment("b" * 32))
        before = len(self.relay.requests)
        self.assertEqual(self.service.enroll(update)["generation"], 2)
        self.assertEqual(len(self.relay.requests), before)
        replacement = {**update, "operation_id": str(uuid.uuid4()), "expected_generation": 2,
                       "preview_key": base64.b64encode(b"z" * 32).decode()}
        self.assertEqual(self.service.enroll(replacement)["generation"], 3)
        before = len(self.relay.requests)
        stale_no_key = {**replacement, "operation_id": str(uuid.uuid4())}
        stale_no_key.pop("preview_key")
        with self.assertRaises(PushError):
            self.service.enroll(stale_no_key)
        self.assertEqual(len(self.relay.requests), before)

    def test_retired_same_token_never_advances_generation_with_fresh_operation(self):
        original = enrollment()
        self.service.enroll(original)
        original_send = self.relay.send
        self.relay.send = lambda *_: {"v": 1, "status": "invalid_target"}
        self.service.produce(native_event())
        self.service.flush()
        self.relay.send = original_send
        retired = self.service.status()["devices"][0]
        self.assertEqual(retired["state"], "relay_retired")
        before = len(self.relay.requests)
        retry = {**original, "expected_generation": 1, "operation_id": str(uuid.uuid4())}
        self.assertEqual(self.service.enroll(retry)["status"], "revoked")
        self.assertEqual(len(self.relay.requests), before)
        self.assertEqual(self.service.status()["devices"][0]["generation"], 1)
        retry.update(operation_id=str(uuid.uuid4()), token="cd" * 32)
        self.assertEqual(self.service.enroll(retry)["generation"], 2)

    def test_unknown_removal_requires_real_remote_ack_and_is_capacity_bounded(self):
        self.relay.available = False
        result = self.service.remove("a" * 32, {"v": 1, "operation_id": str(uuid.uuid4())})
        self.assertEqual(result["status"], "pending")
        self.assertFalse(result["remote_confirmed"])
        pending = self.service.status()["devices"][0]
        self.assertEqual((pending["state"], pending["pending_removal"]), ("removed", True))
        self.relay.available = True
        self.now += 2
        self.service.flush()
        self.assertFalse(self.service.status()["devices"][0]["pending_removal"])
        for index in range(1, self.service.MAX_DEVICE_RECORDS):
            self.service.remove(f"{index:032x}", {"v": 1, "operation_id": str(uuid.uuid4())})
        self.assertEqual(len(self.service.status()["devices"]), self.service.MAX_DEVICE_RECORDS)
        with self.assertRaises(PushError) as context:
            self.service.remove("f" * 32, {"v": 1, "operation_id": str(uuid.uuid4())})
        self.assertEqual(context.exception.status, 429)

    def test_runtime_uses_host_bot_display_title_instead_of_profile_slug(self):
        self.service.enroll(enrollment())
        runtime = Runtime(self.service, 1, title_provider=lambda: "Named Bot")
        runtime.observe(event=native_event(title="default"))
        self.service.flush()
        body = self.relay.requests[-1][2]
        box = base64.b64decode(body["targets"][0]["sealed"])
        aad = f"botto-push:v1\n{self.service.installation}\n{'a' * 32}\n1\n{body['event_id']}".encode()
        plaintext = json.loads(AESGCM(bytes(range(32))).decrypt(box[:12], box[12:], aad))
        self.assertEqual(plaintext["title"], "Named Bot")

    def test_removal_waits_for_started_send_before_confirming(self):
        self.service.enroll(enrollment())
        self.service.produce(native_event())
        started, release, removed = threading.Event(), threading.Event(), threading.Event()
        original_send = self.relay.send

        def blocked_send(method, path, body, token):
            if path.endswith("/events"):
                started.set()
                if not release.wait(5):
                    raise TimeoutError()
            return original_send(method, path, body, token)

        self.relay.send = blocked_send
        sender = threading.Thread(target=self.service.flush)
        sender.start()
        self.assertTrue(started.wait(3))
        result = []

        def remove():
            result.append(self.service.remove("a" * 32, {"v": 1, "operation_id": str(uuid.uuid4())}))
            removed.set()

        remover = threading.Thread(target=remove)
        remover.start()
        try:
            self.assertFalse(removed.wait(0.05))
        finally:
            release.set()
            sender.join(5)
            remover.join(5)
        self.assertFalse(sender.is_alive())
        self.assertFalse(remover.is_alive())
        self.assertEqual(result[0]["status"], "revoked")
        self.service.produce(native_event(event_id="later"))
        self.service.flush()
        self.assertEqual(len([r for r in self.relay.requests if r[1].endswith("/events")]), 1)


if __name__ == "__main__":
    unittest.main()
