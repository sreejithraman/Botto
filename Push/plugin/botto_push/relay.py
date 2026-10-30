from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
from dataclasses import dataclass

from .contracts import canonical


class RelayFailure(Exception):
    def __init__(self, retryable: bool):
        super().__init__("Notification relay request failed.")
        self.retryable = retryable


@dataclass(frozen=True)
class RelayOutcome:
    status: str
    sync_state: str | None = None
    retires_target: bool = False


def command_outcome(kind, response):
    status = response.get("status")
    if kind == "register":
        if status in {"accepted", "duplicate"}:
            return RelayOutcome(status, "accepted")
        if status in {"revoked", "stale"}:
            return RelayOutcome(status, "revoked", True)
    elif kind == "revoke":
        if status in {"accepted", "duplicate", "revoked"}:
            return RelayOutcome(status, "revoked")
    elif kind == "presence":
        if status in {"accepted", "duplicate"}:
            return RelayOutcome(status)
        if status in {"revoked", "stale"}:
            return RelayOutcome(status, "revoked", True)
    elif kind == "cancel":
        if status in {"accepted", "duplicate", "expired"}:
            return RelayOutcome(status)
    elif kind == "event":
        if status in {"revoked", "invalid_target"}:
            return RelayOutcome(status, "revoked", True)
        if status in {"accepted", "duplicate", "queued", "suppressed", "expired", "cancelled", "unknown", "permanent_failure"}:
            return RelayOutcome(status)
    raise RelayFailure(False)


class RelayClient:
    def __init__(self, origin, *, timeout=10):
        self.origin = origin
        self.timeout = timeout

    def send(self, method, path, body, token):
        try:
            request = {"url": self.origin + path, "method": method, "body": canonical(body),
                       "token": token, "timeout": self.timeout}
            # Socket timeouts do not bound progressing reads or DNS. run kills and
            # reaps this request process before the caller can release dispatch.
            completed = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("_http_request.py"))],
                input=canonical(request).encode(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=self.timeout, check=False, close_fds=True)
            if completed.returncode:
                raise RelayFailure(True)
            response = json.loads(completed.stdout)
            if "retryable" in response:
                raise RelayFailure(response["retryable"])
            return response["result"]
        except (subprocess.TimeoutExpired, OSError, ValueError, KeyError, TypeError):
            # Retrying this HTTP contract is safe because registration generations
            # and stable event IDs are retained by the relay.
            raise RelayFailure(True) from None

