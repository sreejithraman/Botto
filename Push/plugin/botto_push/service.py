from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import secrets
import time
import uuid

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from . import PLUGIN_VERSION
from .contracts import (DEFAULT_PREFERENCES, PushError, TOKEN, canonical, destination,
                        device_id, fields, opaque, operation_id, preferences,
                        preview_key, relay_url, truncate)
from .relay import RelayClient, RelayFailure, command_outcome
from .storage import Storage


class PushService:
    MAX_DEVICES = 32
    MAX_DEVICE_RECORDS = 128
    MAX_JOBS = 1024

    def __init__(self, directory: Path, profile: str, origin: str | None, relay=None, now=time.time):
        self.storage = Storage(directory)
        self.profile = profile
        self.origin = relay_url(origin)
        self.relay = relay or (RelayClient(self.origin) if self.origin else None)
        self.now = lambda: int(now())
        with self.storage.transaction() as db:
            row = db.execute("SELECT value FROM metadata WHERE key='token'").fetchone()
            self.token = row[0] if row else secrets.token_hex(32)
            if row is None:
                db.execute("INSERT INTO metadata VALUES ('token', ?)", (self.token,))
            owner = db.execute("SELECT value FROM metadata WHERE key='profile'").fetchone()
            if owner and owner[0] != profile:
                raise PushError(409, "Notification storage belongs to another Hermes profile.")
            db.execute("INSERT OR REPLACE INTO metadata VALUES ('profile', ?)", (profile,))
        self.installation = hashlib.sha256(self.token.encode()).hexdigest()
        self.prefix = "/v1/installations/" + self.installation

    def mark_runtime(self, version):
        with self.storage.transaction() as db:
            db.execute("INSERT OR REPLACE INTO metadata VALUES ('runtime', ?)",
                       (canonical({"version": version, "seen": self.now(), "relay_url": self.origin}),))

    def status(self):
        with self.storage.transaction() as db:
            row = db.execute("SELECT value FROM metadata WHERE key='runtime'").fetchone()
            runtime = json.loads(row[0]) if row else {}
            runtime_loaded = runtime.get("version") == 1 and 0 <= self.now() - runtime.get("seen", 0) <= 45
            configuration_matches = runtime.get("relay_url") == self.origin
            supported = bool(self.origin and runtime_loaded and configuration_matches)
            devices = [self._device(row) for row in db.execute("SELECT * FROM devices ORDER BY id")]
            last = db.execute("SELECT value FROM metadata WHERE key='last_delivery'").fetchone()
            delivery = {"last_status": last[0] if last else None, "queued": db.execute("SELECT count(*) FROM jobs").fetchone()[0]}
        reason = None
        if not self.origin:
            reason = "Configure the Botto relay URL on this Hermes profile."
        elif runtime_loaded and not configuration_matches:
            reason = "Reload the Botto push plugin for this Hermes profile to apply the configured relay URL."
        elif not supported:
            reason = "Load the supported native-session observer contract and enable the Botto plugin for this profile."
        return {"v": 1, "plugin_version": PLUGIN_VERSION, "supported": supported,
                "installation_id": self.installation if self.origin else None,
                "relay_url": self.origin, "capabilities": {"native_session_events": runtime.get("version", 0)},
                "devices": devices, "reason": reason, "delivery": delivery}

    @staticmethod
    def _device(row):
        state = ("removed" if not row["active"] else "relay_retired" if row["sync_state"] == "revoked"
                 else {"accepted": "active", "pending": "pending", "rejected": "rejected"}.get(row["sync_state"], "rejected"))
        return {"device_id": row["id"], "generation": row["generation"],
                "preferences": json.loads(row["record"])["preferences"],
                "device_name": json.loads(row["record"]).get("device_name"),
                "state": state, "active": state not in {"removed", "relay_retired"},
                "pending_removal": not row["active"] and row["sync_state"] != "revoked"}

    def _confirmation(self, row):
        return {"v": 1, "status": row["sync_state"], "installation_id": self.installation,
                "device_id": row["id"], "generation": row["generation"],
                "preferences": json.loads(row["record"])["preferences"]}

    @staticmethod
    def _registration(record):
        if "_registration" in record:
            return record["_registration"]
        return {key: record[key] for key in ("v", "generation", "token", "bundle_id", "environment",
                                            "preferences", "visible_chat", "visible_until")}

    def _require_ready(self):
        if not self.status()["supported"]:
            raise PushError(409, self.status()["reason"] or "Notifications are not ready.")

    def _replay(self, db, op, request):
        digest = hashlib.sha256(canonical(request).encode()).hexdigest()
        row = db.execute("SELECT digest,result FROM operations WHERE id=?", (op,)).fetchone()
        if row:
            if row["digest"] != digest:
                raise PushError(409, "This operation was already used for another request.")
            return digest, json.loads(row["result"])
        db.execute("DELETE FROM operations WHERE created<?", (self.now() - 86400,))
        if db.execute("SELECT count(*) FROM operations").fetchone()[0] >= 4096:
            raise PushError(429, "Too many notification changes. Try again later.")
        return digest, None

    def _remember(self, db, op, digest, result):
        db.execute("INSERT INTO operations VALUES (?, ?, ?, ?)", (op, digest, canonical(result), self.now()))

    def _enqueue(self, db, method, path, body, kind, *, device=None, generation=None, expires=None):
        if db.execute("SELECT count(*) FROM jobs").fetchone()[0] >= self.MAX_JOBS:
            raise PushError(429, "The notification queue is full.")
        db.execute("INSERT INTO jobs (method,path,body,device,generation,kind,available,expires) VALUES (?,?,?,?,?,?,?,?)",
                   (method, self.prefix + path, canonical(body), device, generation, kind, self.now(), expires or self.now() + 3600))

    def enroll(self, request):
        self._require_ready()
        fields(request, {"v", "operation_id", "device_id", "expected_generation", "token", "bundle_id", "environment", "preferences"},
               {"preview_key", "visible_chat", "visible_until", "device_name"})
        op, identifier = operation_id(request["operation_id"]), device_id(request["device_id"])
        expected = request["expected_generation"]
        if type(expected) is not int or not 0 <= expected <= 9_007_199_254_740_991:
            raise PushError(400, "Invalid expected pairing generation.")
        if not isinstance(request["token"], str) or not TOKEN.fullmatch(request["token"]):
            raise PushError(400, "Invalid APNs device token.")
        if request["environment"] not in {"sandbox", "production"}:
            raise PushError(400, "Invalid APNs environment.")
        bundle = request["bundle_id"]
        if not isinstance(bundle, str) or not 1 <= len(bundle) <= 255 or not all(c.isalnum() or c in ".-" for c in bundle):
            raise PushError(400, "Invalid app bundle identity.")
        prefs = preferences(request["preferences"])
        label = request.get("device_name")
        if label is not None:
            from .contracts import identity
            label = identity(label, 80)
        visible = destination(request["visible_chat"], self.profile) if request.get("visible_chat") else None
        until = request.get("visible_until", 0)
        if type(until) is not int:
            raise PushError(400, "Invalid visibility expiry.")
        visible_until = min(max(until, 0), self.now() + 90) if visible else 0
        chat = opaque(self.token, "chat", visible["profile_id"], visible["root_id"]) if visible else None
        supplied_key = preview_key(request["preview_key"]) if request.get("preview_key") is not None else None
        with self.storage.transaction() as db:
            current = db.execute("SELECT * FROM devices WHERE id=?", (identifier,)).fetchone()
            if current and not current["active"]:
                raise PushError(409, "This device identity was removed. Deliberately pair a fresh device identity and key.")
            digest, result = self._replay(db, op, request)
            if result is not None:
                if not current or current["generation"] != result["generation"]:
                    raise PushError(409, "This enrollment was replaced or removed.")
                if current["sync_state"] in {"accepted", "revoked"}:
                    return self._confirmation(current)
            previous = json.loads(current["record"]) if current else None
            comparable = {"token": request["token"], "bundle_id": bundle, "environment": request["environment"], "preferences": prefs}
            if result is None and current and expected != current["generation"]:
                key_matches = (current["key"] == base64.b64encode(supplied_key).decode() if supplied_key is not None
                               else previous.get("_previous_generation") == expected and previous.get("_key_replaced") is False)
                exact_current = (current["generation"] == expected + 1 and key_matches
                                 and all(previous[key] == value for key, value in comparable.items()))
                if not exact_current:
                    raise PushError(409, "The expected pairing generation is no longer current.")
                result = self._confirmation(current)
                if current["sync_state"] in {"accepted", "revoked"}:
                    return result
                self._remember(db, op, digest, result)
            if result is None:
                if not current and expected != 0:
                    raise PushError(409, "This update has no existing pairing generation.")
                if current and current["sync_state"] == "revoked" and previous["token"] == request["token"]:
                    return self._confirmation(current)
                if current is None and db.execute("SELECT count(*) FROM devices WHERE active=1").fetchone()[0] >= self.MAX_DEVICES:
                    raise PushError(429, "This profile has too many notification devices.")
                if current is None and db.execute("SELECT count(*) FROM devices").fetchone()[0] >= self.MAX_DEVICE_RECORDS:
                    raise PushError(429, "Notification pairing history is full; ask the host owner to review it.")
                key = supplied_key or (base64.b64decode(current["key"]) if current and current["active"] and current["key"] else None)
                if key is None:
                    raise PushError(400, "A new pairing requires a preview key.")
                encoded_key = base64.b64encode(key).decode()
                changed = not current or current["key"] != encoded_key or any(previous[k] != v for k, v in comparable.items())
                generation = ((current["generation"] if current else 0) + 1) if changed else current["generation"]
                revision = 0 if changed else current["presence_revision"] + 1
                record = {"v": 1, "generation": generation, **comparable, "visible_chat": chat,
                          "visible_until": visible_until, "device_name": label if label is not None else (previous or {}).get("device_name")}
                record["_registration"] = ({key: value for key, value in record.items() if key != "device_name"}
                                           if changed else self._registration(previous))
                record["_previous_generation"] = (current["generation"] if current else 0) if changed else previous.get("_previous_generation")
                record["_key_replaced"] = (not current or current["key"] != encoded_key) if changed else previous.get("_key_replaced")
                sync_state = "pending" if changed else current["sync_state"]
                db.execute("INSERT OR REPLACE INTO devices (id,generation,active,record,key,presence_revision,sync_state) VALUES (?,?,?,?,?,?,?)",
                           (identifier, generation, 1, canonical(record), encoded_key, revision, sync_state))
                db.execute("DELETE FROM jobs WHERE device=? AND kind='presence'", (identifier,))
                if changed:
                    self._enqueue(db, "PUT", f"/devices/{identifier}", self._registration(record),
                                  "register", device=identifier, generation=generation)
                else:
                    self._enqueue(db, "POST", f"/devices/{identifier}/presence",
                                  {"v": 1, "generation": generation, "revision": revision, "visible_chat": chat, "visible_until": visible_until},
                                  "presence", device=identifier, generation=generation, expires=self.now() + 90)
                result = {"v": 1, "status": "accepted", "installation_id": self.installation, "device_id": identifier,
                          "generation": generation, "preferences": prefs}
                self._remember(db, op, digest, result)
            current = db.execute("SELECT * FROM devices WHERE id=?", (identifier,)).fetchone()
            if (current and current["active"] and current["generation"] == result["generation"]
                    and current["sync_state"] in {"pending", "rejected"}
                    and not db.execute("SELECT 1 FROM jobs WHERE device=? AND kind='register' AND expires>?", (identifier, self.now())).fetchone()):
                self._enqueue(db, "PUT", f"/devices/{identifier}",
                              self._registration(json.loads(current["record"])),
                              "register", device=identifier, generation=current["generation"])
                db.execute("UPDATE devices SET sync_state='pending' WHERE id=?", (identifier,))
        self.flush()
        return self._enrollment_result(result)

    def _enrollment_result(self, result):
        with self.storage.transaction() as db:
            current = db.execute("SELECT * FROM devices WHERE id=?", (result["device_id"],)).fetchone()
        if not current or not current["active"] or current["generation"] != result["generation"]:
            raise PushError(409, "This enrollment was replaced or removed.")
        return {**result, "status": current["sync_state"]}

    def remove(self, identifier, request):
        identifier = device_id(identifier)
        fields(request, {"v", "operation_id"})
        op = operation_id(request["operation_id"])
        scoped = {"operation": "remove", "device_id": identifier, **request}
        with self.storage.transaction() as db:
            digest, result = self._replay(db, op, scoped)
            current = db.execute("SELECT * FROM devices WHERE id=?", (identifier,)).fetchone()
            if result is None:
                if current is None and db.execute("SELECT count(*) FROM devices").fetchone()[0] >= self.MAX_DEVICE_RECORDS:
                    raise PushError(429, "Notification pairing history is full; ask the host owner to review it.")
                generation = (current["generation"] if current else 0) + (1 if not current or current["active"] else 0)
                previous = json.loads(current["record"]) if current else {}
                record = canonical({"preferences": previous.get("preferences", DEFAULT_PREFERENCES), "device_name": previous.get("device_name")})
                db.execute("INSERT OR REPLACE INTO devices (id,generation,active,record,key,presence_revision,sync_state) VALUES (?,?,0,?,NULL,0,'pending')",
                           (identifier, generation, record))
                db.execute("DELETE FROM jobs WHERE device=?", (identifier,))
                self._enqueue(db, "POST", f"/devices/{identifier}/revoke", {"v": 1, "generation": generation}, "revoke",
                              device=identifier, generation=generation, expires=self.now() + 7 * 86400)
                result = {"v": 1, "status": "pending", "device_id": identifier, "generation": generation}
                self._remember(db, op, digest, result)
            elif current and (current["active"] or current["generation"] != result["generation"]):
                raise PushError(409, "This removal belongs to an older pairing.")
            elif current is None:
                # Upgrade old no-op removal receipts into real durable fencing.
                if db.execute("SELECT count(*) FROM devices").fetchone()[0] >= self.MAX_DEVICE_RECORDS:
                    raise PushError(429, "Notification pairing history is full; ask the host owner to review it.")
                generation = 1
                db.execute("INSERT INTO devices (id,generation,active,record,key,presence_revision,sync_state) VALUES (?,1,0,?,NULL,0,'pending')",
                           (identifier, canonical({"preferences": DEFAULT_PREFERENCES, "device_name": None})))
                self._enqueue(db, "POST", f"/devices/{identifier}/revoke", {"v": 1, "generation": generation}, "revoke",
                              device=identifier, generation=generation, expires=self.now() + 7 * 86400)
                result = {"v": 1, "status": "pending", "device_id": identifier, "generation": generation}
                db.execute("UPDATE operations SET result=? WHERE id=?", (canonical(result), op))
            elif current and current["sync_state"] != "revoked" and not db.execute("SELECT 1 FROM jobs WHERE device=? AND kind='revoke' AND expires>?", (identifier, self.now())).fetchone():
                self._enqueue(db, "POST", f"/devices/{identifier}/revoke", {"v": 1, "generation": current["generation"]}, "revoke",
                              device=identifier, generation=current["generation"], expires=self.now() + 7 * 86400)
        self.flush()
        with self.storage.transaction() as db:
            current = db.execute("SELECT * FROM devices WHERE id=?", (identifier,)).fetchone()
            confirmed = current and not current["active"] and current["generation"] == result["generation"] and current["sync_state"] == "revoked"
        return {**result, "status": "revoked" if confirmed else "pending", "remote_confirmed": bool(confirmed)}

    def test(self, identifier, request):
        self._require_ready()
        identifier = device_id(identifier)
        fields(request, {"v", "destination"}, {"operation_id"})
        target = destination(request["destination"], self.profile)
        with self.storage.transaction() as db:
            if not db.execute("SELECT 1 FROM devices WHERE id=? AND active=1", (identifier,)).fetchone():
                raise PushError(404, "This notification device is not paired.")
            if not db.execute("SELECT 1 FROM destinations WHERE identity=?", (canonical(target),)).fetchone():
                raise PushError(409, "Complete a real chat turn on this profile before sending a test notification.")
        identifier_source = request.get("operation_id") or str(uuid.uuid4())
        operation_id(identifier_source)
        event = {"v": 1, "type": "turn.completed", "event_id": "test:" + identifier_source,
                 **target, "execution_generation": 1, "turn_id": identifier_source,
                 "is_subagent": False, "title": "Botto", "created_at": self.now(), "request_id": None,
                 "kind": "reply", "meaningful": True, "preview": "Your encrypted notifications are connected."}
        result = self.produce(event, only_device=identifier)
        self.flush()
        return result

    def produce(self, event, *, only_device=None):
        self._require_ready()
        if not isinstance(event, dict) or type(event.get("v")) is not int or event.get("v") != 1:
            raise PushError(400, "Unsupported native-session event.")
        target = destination({key: event.get(key) for key in ("profile_id", "root_id", "stored_id")}, self.profile)
        event_type = event.get("type")
        allowed = {"turn.completed": "reply", "turn.failed": "failure", "turn.unknown": "failure",
                   "request.waiting": None, "request.resolved": None}
        if event_type not in allowed:
            return {"v": 1, "status": "suppressed"}
        if type(event.get("is_subagent")) is not bool or type(event.get("meaningful")) is not bool:
            raise PushError(400, "Native event lacks authoritative presentation metadata.")
        from .contracts import identity
        source_id = identity(event.get("event_id"))
        identity(event.get("turn_id"))
        generation = event.get("execution_generation")
        created = event.get("created_at")
        if type(generation) is not int or generation <= 0 or type(created) is not int or created > self.now() + 30:
            raise PushError(400, "Invalid native event generation or time.")
        event_id = opaque(self.token, "event", self.profile, source_id)
        thread_id = opaque(self.token, "chat", target["profile_id"], target["root_id"])
        request_id = event.get("request_id")
        if event_type.startswith("request."):
            request_id = opaque(self.token, "request", self.profile, target["root_id"], generation, identity(request_id))
        elif request_id is not None:
            raise PushError(400, "Unexpected native request identity.")
        kind = event.get("kind")
        if event_type.startswith("request."):
            if kind not in {"approval", "question"}:
                raise PushError(400, "Invalid human-wait kind.")
        elif kind != allowed[event_type]:
            raise PushError(400, "Invalid turn outcome kind.")
        expires = min(created + (300 if request_id else 3600), event.get("expires_at", created + 3600))
        if type(expires) is not int:
            raise PushError(400, "Invalid native event expiry.")
        with self.storage.transaction() as db:
            db.execute("DELETE FROM events WHERE expires<=?", (self.now(),))
            db.execute("DELETE FROM cancellations WHERE expires<=?", (self.now(),))
            db.execute("INSERT OR REPLACE INTO destinations VALUES (?,?)", (canonical(target), self.now()))
            db.execute("DELETE FROM destinations WHERE identity NOT IN (SELECT identity FROM destinations ORDER BY observed DESC LIMIT 1024)")
            if event_type == "request.resolved":
                if db.execute("SELECT count(*) FROM cancellations").fetchone()[0] >= 4096 and not db.execute("SELECT 1 FROM cancellations WHERE id=?", (request_id,)).fetchone():
                    raise PushError(429, "Too many pending notification cancellations.")
                for row in db.execute("SELECT id,body FROM jobs WHERE kind='event'"):
                    if json.loads(row["body"]).get("request_id") == request_id:
                        db.execute("DELETE FROM jobs WHERE id=?", (row["id"],))
                if expires <= self.now():
                    return {"v": 1, "status": "expired"}
                previous = db.execute("SELECT expires FROM cancellations WHERE id=?", (request_id,)).fetchone()
                if previous and previous[0] >= expires:
                    return {"v": 1, "status": "cancelled"}
                expiry = max(expires, previous[0] if previous else 0)
                db.execute("INSERT OR REPLACE INTO cancellations VALUES (?,?)", (request_id, expiry))
                self._enqueue(db, "POST", "/cancellations", {"v": 1, "request_id": request_id, "expires_at": expiry},
                              "cancel", expires=expiry)
                return {"v": 1, "status": "cancelled"}
            if event.get("is_subagent") or not event.get("meaningful"):
                return {"v": 1, "status": "suppressed"}
            if expires <= self.now():
                return {"v": 1, "status": "expired"}
            if request_id and db.execute("SELECT 1 FROM cancellations WHERE id=? AND expires>?", (request_id, self.now())).fetchone():
                return {"v": 1, "status": "cancelled"}
            if db.execute("SELECT 1 FROM events WHERE id=?", (event_id,)).fetchone():
                return {"v": 1, "status": "duplicate"}
            if db.execute("SELECT count(*) FROM events").fetchone()[0] >= 4096:
                raise PushError(429, "Too many notification events.")
            for device in db.execute("SELECT * FROM devices WHERE active=1 AND sync_state!='revoked' AND (? IS NULL OR id=?)", (only_device, only_device)):
                record = json.loads(device["record"])
                prefs = record["preferences"]
                if not prefs[{"reply": "replies", "failure": "failures", "approval": "requests", "question": "requests"}[kind]]:
                    continue
                visible = record.get("visible_chat") == thread_id and record.get("visible_until", 0) > self.now()
                if visible:
                    continue
                plaintext = {"v": 1, "title": truncate(event.get("title"), 160) if prefs["previews"] else "",
                             "body": truncate(event.get("preview"), 1024) if prefs["previews"] else "", **target}
                nonce = secrets.token_bytes(12)
                aad = f"botto-push:v1\n{self.installation}\n{device['id']}\n{device['generation']}\n{event_id}".encode()
                ciphertext = AESGCM(base64.b64decode(device["key"])).encrypt(nonce, canonical(plaintext).encode(), aad)
                sealed = base64.b64encode(nonce + ciphertext).decode()
                payload = {"v": 1, "event_id": event_id, "thread_id": thread_id, "kind": kind, "request_id": request_id,
                           "created_at": created, "expires_at": expires,
                           "targets": [{"device_id": device["id"], "generation": device["generation"], "sealed": sealed}]}
                botto = {"v": 1, "installation_id": self.installation, "device_id": device["id"], "generation": device["generation"],
                       "event_id": event_id, "kind": kind, "expires_at": expires, "sealed": sealed}
                apns = {"aps": {"alert": {"title": "Botto", "body": "New activity"}, "mutable-content": 1,
                                "sound": "default", "thread-id": thread_id}, "botto": botto}
                if len(canonical(apns).encode()) > 4096:
                    # Retain authenticated routing even when an unusual destination
                    # consumes the preview budget; never truncate an identity.
                    plaintext["title"] = ""
                    plaintext["body"] = ""
                    nonce = secrets.token_bytes(12)
                    sealed = base64.b64encode(nonce + AESGCM(base64.b64decode(device["key"])).encrypt(nonce, canonical(plaintext).encode(), aad)).decode()
                    payload["targets"][0]["sealed"] = sealed
                    botto["sealed"] = sealed
                    if len(canonical(apns).encode()) > 4096:
                        raise PushError(400, "Notification destination exceeds the payload budget.")
                self._enqueue(db, "POST", "/events", payload, "event", device=device["id"], generation=device["generation"], expires=expires)
                if request_id:
                    db.execute("UPDATE jobs SET available=? WHERE id=last_insert_rowid()", (self.now() + 1,))
            db.execute("INSERT INTO events VALUES (?,?)", (event_id, expires + 3600))
        return {"v": 1, "status": "accepted", "event_id": event_id}

    def flush(self, limit=64, *, wait_for_dispatch=True):
        if self.relay is None:
            return
        with self.storage.dispatch_lock(blocking=wait_for_dispatch) as acquired:
            if not acquired:
                return
            for _ in range(limit):
                with self.storage.transaction() as db:
                    db.execute("DELETE FROM jobs WHERE expires<=?", (self.now(),))
                    row = db.execute("SELECT * FROM jobs ORDER BY CASE kind WHEN 'revoke' THEN 0 WHEN 'cancel' THEN 1 WHEN 'register' THEN 2 ELSE 3 END,id LIMIT 1").fetchone()
                    if row is None or row["available"] > self.now():
                        return
                    if row["device"] and row["kind"] != "revoke":
                        device = db.execute("SELECT * FROM devices WHERE id=?", (row["device"],)).fetchone()
                        if not device or not device["active"] or device["generation"] != row["generation"]:
                            db.execute("DELETE FROM jobs WHERE id=?", (row["id"],))
                            continue
                    job = dict(row)
                try:
                    response = self.relay.send(job["method"], job["path"], json.loads(job["body"]), self.token)
                    outcome = command_outcome(job["kind"], response)
                except (RelayFailure, OSError) as error:
                    retryable = not isinstance(error, RelayFailure) or error.retryable
                    with self.storage.transaction() as db:
                        attempts = job["attempts"] + 1
                        if retryable and attempts < 8:
                            db.execute("UPDATE jobs SET attempts=?,available=? WHERE id=?", (attempts, self.now() + min(2 ** attempts, 60), job["id"]))
                            db.execute("INSERT OR REPLACE INTO metadata VALUES ('last_delivery', 'retrying')")
                        else:
                            db.execute("DELETE FROM jobs WHERE id=?", (job["id"],))
                            if job["kind"] in {"register", "revoke"}:
                                db.execute("UPDATE devices SET sync_state='rejected' WHERE id=? AND generation=?",
                                           (job["device"], job["generation"]))
                            db.execute("INSERT OR REPLACE INTO metadata VALUES ('last_delivery', ?)", ("rejected",))
                    return
                with self.storage.transaction() as db:
                    db.execute("DELETE FROM jobs WHERE id=?", (job["id"],))
                    if outcome.sync_state is not None:
                        db.execute("UPDATE devices SET sync_state=? WHERE id=? AND generation=?",
                                   (outcome.sync_state, job["device"], job["generation"]))
                    if outcome.retires_target:
                        db.execute("DELETE FROM jobs WHERE device=? AND generation=? AND kind!='revoke'",
                                   (job["device"], job["generation"]))
                    db.execute("INSERT OR REPLACE INTO metadata VALUES ('last_delivery', ?)", (outcome.status,))
