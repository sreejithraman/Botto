import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("monitor", Path(__file__).resolve().parents[1] / "native-test-diagnostics.py")
monitor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(monitor)
DEVICE = "D631DAA3-17A3-44CD-B6E9-B66986AA7312"
METHOD = "revisionCacheRemovalAndImageFailuresStayLocal"
APP = f"/Users/test/Library/Developer/CoreSimulator/Devices/{DEVICE}/data/Containers/Bundle/Application/ABC/Botto.app/Botto"


class Timer:
    def __init__(self, interval, callback):
        self.interval, self.callback = interval, callback
        self.started = self.cancelled = self.joined = False
        self.daemon = False

    def start(self): self.started = True
    def cancel(self): self.cancelled = True
    def join(self, timeout): self.joined = True


class MonitorTests(unittest.TestCase):
    def test_process_scope_requires_actual_executable_and_exact_device(self):
        other = APP.replace(DEVICE, "OTHER-DEVICE")
        listing = f"10 {APP}\n11 {other}\n12 /usr/bin/python3 -c '{APP}'\n16 /usr/bin/echo {APP}\n13 {APP}-helper\n14 {APP} --fixture\n"
        self.assertEqual(monitor.matching_pids(listing, DEVICE), [10, 14])
        self.assertEqual(monitor.matching_pids("15 /Other/Botto.app/Botto", DEVICE), [])

    def test_parameterized_start_finish_and_issue_lines(self):
        name = "hermesPetAndImageAssetsKeepAspectAndTransparency"
        self.assertEqual(monitor.test_event(f"◇ Test {name}(mime:) started."), (name, "start"))
        self.assertIsNone(monitor.test_event(f'◇ Test case passing 1 argument mime → "image/png" to {name}(mime:) started.'))
        self.assertIsNone(monitor.test_event(f"✘ Test {name}(mime:) recorded an issue at file:5"))
        self.assertEqual(monitor.test_event(f"✔ Test {name}(mime:) with 3 test cases passed after 1.0 seconds."), (name, "finish"))
        self.assertEqual(monitor.test_event(f"✘ Test {name}(mime:) failed after 10 seconds."), (name, "finish"))
        self.assertIsNone(monitor.test_event("◇ Test unrelated() started."))

    def test_finish_cancels_timer_and_repeat_cannot_resample(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = monitor.Monitor(DEVICE, directory, Timer)
            subject.observe(f"◇ Test {METHOD}() started.")
            timer = subject.timers[METHOD]
            self.assertEqual(timer.interval, 3)
            self.assertTrue(timer.started and timer.daemon)
            subject.observe(f"✔ Test {METHOD}() passed after 0.1 seconds.")
            self.assertTrue(timer.cancelled)
            with patch.object(monitor.subprocess, "check_output") as ps:
                timer.callback()
                ps.assert_not_called()
            subject.observe(f"◇ Test {METHOD}() started.")
            self.assertIs(subject.timers[METHOD], timer)
            subject.close()
            self.assertTrue(timer.joined)

    def test_custom_watch_list_replaces_defaults_and_validates_stems(self):
        custom = "repeatedInitialAvatarReads"
        with tempfile.TemporaryDirectory() as directory:
            subject = monitor.Monitor(DEVICE, directory, Timer, watch_tests=[custom])
            subject.observe(f"◇ Test {METHOD}() started.")
            self.assertEqual(subject.timers, {})
            subject.observe(f"◇ Test {custom}() started.")
            self.assertIn(custom, subject.timers)
            subject.close()
        self.assertEqual(monitor.method_stem(custom), custom)
        with self.assertRaises(Exception):
            monitor.method_stem("../sample")

    def test_ambiguous_process_records_error_without_sampling(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = monitor.Monitor(DEVICE, directory, Timer)
            subject.observe(f"◇ Test {METHOD}() started.")
            with patch.object(monitor.subprocess, "check_output", return_value=f"10 {APP}\n11 {APP}\n"), patch.object(monitor.subprocess, "run") as sample:
                subject.timers[METHOD].callback()
                sample.assert_not_called()
            record = json.loads(next(Path(directory).glob("*.json")).read_text())
            self.assertIn("found 2", record["error"])
            subject.close()

    def test_sampling_revalidates_pid_and_uses_bounded_command(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = monitor.Monitor(DEVICE, directory, Timer)
            subject.observe(f"◇ Test {METHOD}() started.")
            result = subprocess.CompletedProcess([], 1, "", "Process exited")
            with patch.object(monitor.subprocess, "check_output", side_effect=[f"10 {APP}\n", f"10 {APP}\n"]), patch.object(monitor.subprocess, "run", return_value=result) as sample:
                subject.timers[METHOD].callback()
            args = sample.call_args
            self.assertEqual(args.args[0][:4], ["/usr/bin/sample", "10", "1", "-file"])
            self.assertEqual(args.kwargs["timeout"], 15)
            record = json.loads(next(Path(directory).glob("*.json")).read_text())
            self.assertEqual(record["returncode"], 1)
            self.assertEqual(record["pid"], 10)
            subject.close()

    def test_wrapper_error_reaps_its_running_child(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; print('ready', flush=True); time.sleep(60)"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        subject = Mock()
        subject.observe.side_effect = RuntimeError("diagnostic reader failed")
        with patch.object(monitor.subprocess, "Popen", return_value=child):
            with self.assertRaisesRegex(RuntimeError, "diagnostic reader failed"):
                monitor.run(["unused"], subject, io.BytesIO(), io.BytesIO())
        self.assertIsNotNone(child.poll())
        self.assertTrue(child.stdout.closed and child.stderr.closed)
        subject.close.assert_called_once()

    def test_child_output_bytes_and_failure_exit_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = monitor.Monitor(DEVICE, directory, Timer)
            out, err = io.BytesIO(), io.BytesIO()
            code = "import os;os.write(1,b'hello\\xff\\n');os.write(2,b'error\\x00');raise SystemExit(65)"
            self.assertEqual(monitor.run([sys.executable, "-c", code], subject, out, err), 65)
            self.assertEqual(out.getvalue(), b"hello\xff\n")
            self.assertEqual(err.getvalue(), b"error\x00")


if __name__ == "__main__":
    unittest.main()
