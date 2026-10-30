from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import unicodedata
from urllib.parse import urlsplit
import uuid

HEX32 = re.compile(r"[0-9a-f]{32}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
TOKEN = re.compile(r"(?:[0-9a-f]{2}){16,256}\Z")
DEFAULT_PREFERENCES = {"replies": True, "requests": True, "failures": True, "previews": True}


class PushError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def canonical(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True, ensure_ascii=False, allow_nan=False)


def fields(value, required, optional=()):
    if not isinstance(value, dict) or set(value) - set(required) - set(optional) or set(required) - set(value):
        raise PushError(400, "Invalid request fields.")
    if value.get("v", 1) != 1 or isinstance(value.get("v"), bool):
        raise PushError(400, "Unsupported notification protocol.")
    return value


def identity(value, limit=512):
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > limit:
        raise PushError(400, "Invalid destination identity.")
    if any(unicodedata.category(c) in {"Cc", "Cf"} for c in value):
        raise PushError(400, "Invalid destination identity.")
    return value


def destination(value, profile):
    fields(value, {"profile_id", "root_id", "stored_id"})
    result = {name: identity(value[name]) for name in ("profile_id", "root_id", "stored_id")}
    if result["profile_id"].encode() != profile.encode():
        raise PushError(403, "This destination belongs to a different Hermes profile.")
    return result


def operation_id(value):
    try:
        parsed = uuid.UUID(value)
    except (ValueError, TypeError, AttributeError):
        raise PushError(400, "Invalid operation identity.") from None
    if str(parsed) != value.lower():
        raise PushError(400, "Invalid operation identity.")
    return value.lower()


def device_id(value):
    if not isinstance(value, str) or not HEX32.fullmatch(value):
        raise PushError(400, "Invalid device identity.")
    return value


def preview_key(value):
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise PushError(400, "Invalid preview key.") from None
    if len(decoded) != 32:
        raise PushError(400, "Invalid preview key.")
    return decoded


def preferences(value):
    fields(value, set(DEFAULT_PREFERENCES))
    if any(type(item) is not bool for item in value.values()):
        raise PushError(400, "Invalid notification preferences.")
    return dict(value)


def relay_url(value):
    if not value:
        return None
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise PushError(400, "Configure an HTTPS relay URL without credentials, query, or fragment.")
    if parsed.path not in {"", "/"}:
        raise PushError(400, "Configure the relay origin, without a path.")
    return value.rstrip("/")


def opaque(token, kind, *parts):
    message = canonical([kind, *parts]).encode()
    return hmac.new(bytes.fromhex(token), message, hashlib.sha256).hexdigest()


def truncate(value, maximum):
    if not isinstance(value, str):
        return ""
    return value.encode("utf-8")[:maximum].decode("utf-8", "ignore")

