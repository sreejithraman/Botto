from __future__ import annotations

from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from botto_push.relay import RelayClient, RelayFailure
from botto_push.runtime import Runtime
from botto_push.service import PushService
from test_plugin import enrollment, native_event


class HTTPSRelay:
    def __init__(self, mode="accepted"):
        self.mode = mode
        self.requests = []
        self.started = threading.Event()
        self.stopped = threading.Event()
        self.aborted = threading.Event()
        self.progress = 0

    def __enter__(self):
        self.temp = tempfile.TemporaryDirectory()
        directory = Path(self.temp.name)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Botto relay test")])
        now = datetime.now(timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(days=1))
                .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), False)
                .add_extension(x509.BasicConstraints(ca=True, path_length=None), True)
                .sign(key, hashes.SHA256()))
        cert_path, key_path = directory / "cert.pem", directory / "key.pem"
        cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        key_path.chmod(0o600)
        relay = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                relay.requests.append((self.path, body, self.headers.get("Authorization")))
                slow = relay.mode == "progress" and self.path.endswith(("/events", "/probe"))
                payload = b'{"v":1,"status":"accepted"}'
                code = 200
                if relay.mode == "redirect":
                    code = 302
                elif relay.mode == "oversized":
                    payload = b" " * 32_769
                elif relay.mode == "unavailable":
                    code = 503
                self.send_response(code)
                if code == 302:
                    self.send_header("Location", relay.origin + "/must-not-follow")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                if slow:
                    relay.started.set()
                try:
                    if slow:
                        for byte in payload:
                            self.wfile.write(bytes([byte]))
                            self.wfile.flush()
                            relay.progress += 1
                            if relay.stopped.wait(0.05):
                                break
                    else:
                        self.wfile.write(payload)
                except OSError:
                    relay.aborted.set()

            def log_message(self, *_):
                pass

            do_PUT = do_POST

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert_path, key_path)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.origin = f"https://127.0.0.1:{self.server.server_port}"
        self.environment = patch.dict(os.environ, {"SSL_CERT_FILE": str(cert_path)})
        self.environment.start()
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.05))
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stopped.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.environment.stop()
        self.temp.cleanup()


class RelayTests(unittest.TestCase):
    def test_progressing_response_cannot_extend_the_total_request_budget(self):
        with HTTPSRelay("progress") as relay:
            client = RelayClient(relay.origin, timeout=0.75)
            started = time.monotonic()
            with self.assertRaises(RelayFailure) as failure:
                client.send("POST", "/probe", {"v": 1}, "a" * 64)
            self.assertTrue(failure.exception.retryable)
            self.assertLess(time.monotonic() - started, 2)
            self.assertTrue(relay.started.is_set())
            self.assertGreater(relay.progress, 1)
            self.assertEqual(relay.requests, [("/probe", {"v": 1}, "Bearer " + "a" * 64)])

    def test_success_redirect_size_and_retry_outcomes_use_the_real_transport(self):
        for mode, retryable in [("accepted", None), ("redirect", False), ("oversized", False), ("unavailable", True)]:
            with self.subTest(mode=mode), HTTPSRelay(mode) as relay:
                client = RelayClient(relay.origin, timeout=2)
                if retryable is None:
                    self.assertEqual(client.send("POST", "/probe", {"v": 1}, "a" * 64),
                                     {"v": 1, "status": "accepted"})
                else:
                    with self.assertRaises(RelayFailure) as failure:
                        client.send("POST", "/probe", {"v": 1}, "a" * 64)
                    self.assertIs(failure.exception.retryable, retryable)
                self.assertEqual(relay.requests, [("/probe", {"v": 1}, "Bearer " + "a" * 64)])

    def test_request_deadline_survives_its_owners_exit(self):
        with HTTPSRelay("progress") as relay:
            script = ("import sys; sys.path.insert(0, sys.argv[1]); "
                      "from botto_push.relay import RelayClient; "
                      "RelayClient(sys.argv[2], timeout=0.75).send('POST', '/probe', {'v':1}, 'a'*64)")
            owner = subprocess.Popen([sys.executable, "-c", script,
                str(Path(__file__).resolve().parents[1]), relay.origin],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                self.assertTrue(relay.started.wait(3))
                owner.kill()
                owner.wait(timeout=3)
                self.assertTrue(relay.aborted.wait(2))
                self.assertLess(relay.progress, len(b'{"v":1,"status":"accepted"}'))
            finally:
                if owner.poll() is None:
                    owner.kill()
                owner.wait(timeout=3)

    def test_unload_and_removal_settle_a_started_progressing_request(self):
        with HTTPSRelay("progress") as relay, tempfile.TemporaryDirectory() as directory:
            service = PushService(Path(directory), "default", relay.origin, RelayClient(relay.origin, timeout=0.75))
            service.mark_runtime(1)
            self.assertEqual(service.enroll(enrollment())["status"], "accepted")
            service.produce(native_event(created_at=int(time.time())))
            runtime = Runtime(service, 1)
            result, failures = [], []
            removed = threading.Event()

            def remove():
                try:
                    result.append(service.remove("a" * 32, {"v": 1, "operation_id": str(uuid.uuid4())}))
                except Exception as error:
                    failures.append(error)
                finally:
                    removed.set()

            remover = threading.Thread(target=remove)
            runtime.start()
            try:
                self.assertTrue(relay.started.wait(3))
                self.assertTrue(service.status()["supported"])
                remover.start()
                self.assertFalse(removed.wait(0.1))
            finally:
                started = time.monotonic()
                runtime.close()
                if remover.ident is not None:
                    remover.join(timeout=3)
            self.assertLess(time.monotonic() - started, 3)
            self.assertFalse(remover.is_alive())
            self.assertEqual(failures, [])
            self.assertTrue(result[0]["remote_confirmed"])
            self.assertEqual(result[0]["status"], "revoked")
            self.assertGreater(relay.progress, 1)
            self.assertLess(relay.progress, len(b'{"v":1,"status":"accepted"}'))
            status = service.status()
            self.assertFalse(status["supported"])
            self.assertEqual(status["delivery"]["queued"], 0)
            event_paths = [path for path, _, _ in relay.requests if path.endswith("/events")]
            self.assertEqual(len(event_paths), 1)
            self.assertTrue(relay.requests[-1][0].endswith("/revoke"))


if __name__ == "__main__":
    unittest.main()
