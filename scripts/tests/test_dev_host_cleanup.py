from contextlib import contextmanager
from contextlib import redirect_stderr
import io
import os
import select
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


HOST_DIRECTORY = Path(__file__).resolve().parents[1] / "dev-host"


def load_host(name):
    spec = importlib.util.spec_from_file_location("cleanup_" + name, HOST_DIRECTORY / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    with mock.patch.object(sys, "path", [str(HOST_DIRECTORY), *sys.path]):
        spec.loader.exec_module(module)
    return module


class HostGroupCleanupTests(unittest.TestCase):
    def test_final_permission_warning_still_reaps_the_child(self):
        host = load_host("host")
        child = mock.Mock(pid=12345, returncode=None)
        denied = [None, PermissionError("zombie-only group")]
        error_output = io.StringIO()
        with mock.patch.object(host.os, "killpg", side_effect=denied), redirect_stderr(error_output):
            host.stop_group(child, grace=0)
        child.wait.assert_called_once_with(timeout=2)
        self.assertIn("SIGKILL: EPERM", error_output.getvalue())

    def test_reaped_child_cannot_authorize_any_group_signal(self):
        host = load_host("host")
        child = mock.Mock(pid=12345, returncode=0)
        with mock.patch.object(host.os, "killpg") as delivery:
            with self.assertRaisesRegex(RuntimeError, "after reaping"):
                host.stop_group(child, grace=0)
        delivery.assert_not_called()

    def test_authority_keeps_child_unreaped_through_last_signal(self):
        host = load_host("host")
        events = []

        class Child:
            pid = 12345
            returncode = None

            def wait(self, timeout=None):
                events.append(("wait", timeout))
                self.returncode = 0

        child = Child()

        def signal_group(pid, sig):
            self.assertEqual(pid, child.pid)
            self.assertIsNone(child.returncode, "A reaped PID cannot authorize a later group signal")
            events.append(("signal", sig.name))

        with mock.patch.object(host.os, "killpg", side_effect=signal_group), \
                mock.patch.object(host.time, "sleep", side_effect=lambda seconds: events.append(("grace", seconds))):
            host.stop_group(child)

        self.assertEqual(events, [
            ("signal", "SIGTERM"), ("grace", 15), ("signal", "SIGKILL"), ("wait", 2),
        ])


    def test_missing_group_still_reaps_its_owned_child(self):
        host = load_host("host")
        child = mock.Mock(pid=12345, returncode=None)
        with mock.patch.object(host.os, "killpg", side_effect=ProcessLookupError), \
                mock.patch.object(host.time, "sleep"):
            host.stop_group(child)
        child.wait.assert_called_once_with(timeout=2)
        child.poll.assert_not_called()

    @contextmanager
    def host_fixture(self, kind, mode):
        host = load_host(kind)
        events = []
        child = mock.Mock(pid=12345, returncode=None)

        def poll():
            if mode == "startup_exit":
                child.returncode = 23
            return child.returncode

        def observe_exit():
            return mode == "startup_exit"

        def await_exit():
            if mode in {"interrupted", "cleanup_timeout", "signal_failure"}:
                raise KeyboardInterrupt()

        def wait(timeout=None):
            events.append(("wait", timeout))
            if timeout is None and mode in {"interrupted", "cleanup_timeout", "signal_failure"}:
                raise KeyboardInterrupt()
            if mode == "cleanup_timeout":
                raise subprocess.TimeoutExpired("owned test child", timeout)
            child.returncode = -9 if timeout is not None else 7
            return child.returncode

        def signal_group(pid, sig):
            self.assertEqual(pid, child.pid)
            self.assertIsNone(child.returncode, "No signals after reaping")
            events.append(("signal", sig.name))
            if mode == "signal_failure":
                raise PermissionError("disposable signal failure")

        child.poll.side_effect = poll
        child.wait.side_effect = wait
        peer = mock.Mock(server_port=19120)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = {"install_id": host.INSTALL_ID, "auth_required": True}
            config_name = "config" if kind == "host" else "environment"
            health_name = "status" if kind == "host" else "health"
            with mock.patch.object(host, config_name, return_value={}), \
                    mock.patch.object(host, health_name, return_value=ready), \
                    mock.patch.object(host, "ThreadingHTTPServer", return_value=peer), \
                    mock.patch.object(host.threading, "Thread"), \
                    mock.patch.object(host.socket, "socket"), \
                    mock.patch.object(host.signal, "signal"), \
                    mock.patch.object(host.subprocess, "Popen", return_value=child,
                                      side_effect=OSError("disposable exec failure") if mode == "spawn_failure" else None), \
                    mock.patch.object(host, "child_exited", side_effect=lambda _: observe_exit(), create=True), \
                    mock.patch.object(host, "wait_for_exit", side_effect=lambda _: await_exit(), create=True), \
                    mock.patch.object(host.os, "killpg", side_effect=signal_group), \
                    mock.patch.object(host.time, "sleep", side_effect=lambda seconds: events.append(("grace", seconds))), \
                    mock.patch("builtins.print"):
                if kind == "host":
                    def run():
                        return host.serve(root, 19119)
                    yield run, child, peer, events, root
                else:
                    with mock.patch.object(host, "ROOT", root):
                        yield host.run, child, peer, events, root

    def test_normal_exit_drains_the_group_before_reaping_and_keeps_result(self):
        for kind in ("host", "sidecar_host"):
            with self.subTest(kind=kind), self.host_fixture(kind, "normal") as (run, child, peer, events, root):
                child.wait.side_effect = lambda timeout=None: (
                    events.append(("wait", timeout)), setattr(child, "returncode", 7), 7)[-1]
                self.assertEqual(run(), 7)
                self.assertEqual(events, [("signal", "SIGTERM"), ("grace", 15),
                                          ("signal", "SIGKILL"), ("wait", 2)])
                peer.shutdown.assert_called_once()
                self.assertFalse((root / "ready.json").exists())
                self.assertTrue((root / "mock-stats.json").exists())

    def test_cleanup_withdraws_readiness_before_draining_the_group(self):
        for kind in ("host", "sidecar_host"):
            with self.subTest(kind=kind), self.host_fixture(kind, "normal") as (run, _, _, _, root):
                def draining(_):
                    self.assertFalse((root / "ready.json").exists(), "Cleanup cannot advertise a ready backend")
                with mock.patch("time.sleep", side_effect=draining):
                    run()

    def test_start_checks_current_health_before_accepting_a_ready_marker(self):
        for kind in ("host", "sidecar_host"):
            for healthy in (False, True):
                with self.subTest(kind=kind, healthy=healthy), tempfile.TemporaryDirectory() as directory:
                    host = load_host(kind)
                    root = Path(directory)
                    supervisor = mock.Mock()
                    supervisor.poll.side_effect = [None, 1]
                    def spawn(*args, **kwargs):
                        (root / "ready.json").write_text("{}")
                        return supervisor
                    health_name = "status" if kind == "host" else "health"
                    with mock.patch.object(host, "runtime", return_value=root, create=True), \
                            mock.patch.object(host, "ROOT", root, create=True), \
                            mock.patch.object(host.subprocess, "Popen", side_effect=spawn), \
                            mock.patch.object(host, health_name,
                                              return_value={"install_id": host.INSTALL_ID, "auth_required": True},
                                              side_effect=None if healthy else OSError("backend exited")) as health, \
                            mock.patch.object(host.socket, "socket"), \
                            mock.patch.object(host.os, "kill") as signal_process, \
                            mock.patch.object(host.time, "sleep"), \
                            mock.patch.object(sys, "argv", [kind, "start"]), \
                            mock.patch("builtins.print"):
                        if healthy:
                            host.main()
                        else:
                            with self.assertRaisesRegex(SystemExit, "failed"):
                                host.main()
                        health.assert_called_once()
                        signal_process.assert_not_called()

    def test_early_child_exit_drains_its_group_and_preserves_startup_failure(self):
        for kind in ("host", "sidecar_host"):
            with self.subTest(kind=kind), self.host_fixture(kind, "startup_exit") as (run, child, peer, events, root):
                with self.assertRaisesRegex(RuntimeError, "exited"):
                    run()
                self.assertEqual(events, [("signal", "SIGTERM"), ("grace", 15),
                                          ("signal", "SIGKILL"), ("wait", 2)])
                child.poll.assert_not_called()
                peer.shutdown.assert_called_once()
                self.assertFalse((root / "ready.json").exists())

    def test_interrupted_host_signals_before_reaping_and_shuts_down_provider(self):
        for kind in ("host", "sidecar_host"):
            with self.subTest(kind=kind), self.host_fixture(kind, "interrupted") as (run, child, peer, events, root):
                self.assertEqual(run(), 0)
                self.assertEqual(events, [
                    ("signal", "SIGTERM"), ("grace", 15),
                    ("signal", "SIGKILL"), ("wait", 2),
                ])
                peer.shutdown.assert_called_once()
                self.assertFalse((root / "ready.json").exists())

    def test_exec_failure_still_shuts_down_provider_without_signaling(self):
        for kind in ("host", "sidecar_host"):
            with self.subTest(kind=kind), self.host_fixture(kind, "spawn_failure") as (run, child, peer, events, root):
                with self.assertRaisesRegex(OSError, "disposable exec failure"):
                    run()
                self.assertEqual(events, [])
                peer.shutdown.assert_called_once()
                self.assertFalse((root / "ready.json").exists())

    def test_permission_warning_is_visible_and_does_not_skip_reaping(self):
        for kind in ("host", "sidecar_host"):
            with self.subTest(kind=kind), self.host_fixture(kind, "signal_failure") as (run, child, peer, events, root):
                error_output = io.StringIO()
                with redirect_stderr(error_output):
                    self.assertEqual(run(), 0)
                self.assertIn("EPERM", error_output.getvalue())
                self.assertIn("unconfirmed", error_output.getvalue())
                self.assertEqual(events, [("signal", "SIGTERM"), ("grace", 15),
                                          ("signal", "SIGKILL"), ("wait", 2)])
                peer.shutdown.assert_called_once()
                self.assertFalse((root / "ready.json").exists())

    def test_cleanup_timeout_still_shuts_down_the_provider(self):
        for kind in ("host", "sidecar_host"):
            with self.subTest(kind=kind), self.host_fixture(kind, "cleanup_timeout") as (run, child, peer, events, root):
                with self.assertRaises(subprocess.TimeoutExpired):
                    run()
                peer.shutdown.assert_called_once()
                self.assertFalse((root / "ready.json").exists())

class OwnedGroupIntegrationTests(unittest.TestCase):
    def test_exited_leader_stays_unreaped_until_its_descendant_is_retired(self):
        host = load_host("host")
        ready_read, ready_write = os.pipe()
        control_read, control_write = os.pipe()
        descendant = "import os,sys; os.write(int(sys.argv[1]), b'R'); os.read(int(sys.argv[2]), 1)"
        leader = (
            "import os,subprocess,sys; "
            "ready,control=map(int,sys.argv[1:]); "
            f"subprocess.Popen([sys.executable,'-I','-c',{descendant!r},str(ready),str(control)], "
            "pass_fds=(ready,control),stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
            "os.close(ready); os.close(control); sys.exit(7)"
        )
        child = None
        try:
            child = subprocess.Popen([sys.executable, "-I", "-c", leader, str(ready_write), str(control_read)],
                                     pass_fds=(ready_write, control_read), start_new_session=True,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.close(ready_write)
            ready_write = None
            os.close(control_read)
            control_read = None
            self.assertTrue(select.select([ready_read], [], [], 10)[0], "Owned descendant started")
            self.assertEqual(os.read(ready_read, 1), b"R")
            deadline = time.monotonic() + 10
            while not host.child_exited(child) and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(host.child_exited(child))
            self.assertIsNone(child.returncode, "Exit observation must retain the ownership anchor")
            self.assertFalse(select.select([ready_read], [], [], 0)[0], "Descendant still holds its lifetime pipe")
            with redirect_stderr(io.StringIO()):
                host.stop_group(child, grace=0)
            self.assertEqual(child.returncode, 7)
            self.assertTrue(select.select([ready_read], [], [], 10)[0], "Group retirement closed the descendant pipe")
            self.assertEqual(os.read(ready_read, 1), b"")
        finally:
            # Closing this owned control channel also releases the descendant on a failed assertion.
            os.close(control_write)
            if child is not None and child.returncode is None:
                with redirect_stderr(io.StringIO()):
                    host.stop_group(child, grace=0)
            for descriptor in (ready_read, ready_write, control_read):
                if descriptor is not None:
                    os.close(descriptor)


if __name__ == "__main__":
    unittest.main()
