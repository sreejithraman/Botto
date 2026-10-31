import importlib.util
import json
import plistlib
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


class MonitorTests(unittest.TestCase):
    def fixture(self, *, phase="started", timestamp=100):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        container = base / "containers" / "fixture"
        (container / "tmp").mkdir(parents=True)
        marker = {"method": METHOD, "pid": 10, "runID": "fixture", "phase": phase, "timestamp": timestamp}
        path = container / "tmp" / f"botto-native-{METHOD}-fixture.json"
        path.write_text(json.dumps(marker))
        subject = monitor.Monitor(DEVICE, base / "samples")
        subject.data_root = base / "containers"
        (container / ".com.apple.mobile_container_manager.metadata.plist").write_bytes(plistlib.dumps({"MCMMetadataIdentifier": "com.sree.botto"}))
        return subject, container, path, marker

    def test_native_marker_triggers_sample_without_console_events(self):
        subject, container, _, marker = self.fixture()
        with patch.object(monitor.subprocess, "check_output", return_value=f"10 {APP}\n"), patch.object(monitor.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as sample:
            subject.poll(now=104)
            subject.poll(now=105)
        sample.assert_called_once()
        self.assertEqual(sample.call_args.args[0][:4], ["/usr/bin/sample", "10", "1", "-file"])
        self.assertEqual(sample.call_args.kwargs["timeout"], 15)
        record = json.loads(next(subject.output_dir.glob("*.json")).read_text())
        self.assertEqual(record["nativeStart"], marker)
        self.assertFalse(record["testFinishedDuringSample"])

    def test_fast_or_finished_test_does_not_sample(self):
        for phase, now in (("started", 102), ("finished", 104)):
            with self.subTest(phase=phase):
                subject, container, _, _ = self.fixture(phase=phase)
                with patch.object(monitor.subprocess, "check_output", return_value=str(container)), patch.object(monitor.subprocess, "run") as sample:
                    subject.poll(now=now)
                sample.assert_not_called()
                subject.close()
                summary = json.loads((subject.output_dir / "collector-summary.json").read_text())
                self.assertEqual(summary["observed"]["fixture"]["phase"], phase)
                self.assertTrue(summary["workerStopped"])

    def test_finished_argument_does_not_hide_another_arguments_stall(self):
        subject, _, path, marker = self.fixture()
        sibling = path.with_name(f"botto-native-{METHOD}-fast.json")
        sibling.write_text(json.dumps(dict(marker, runID="fast", phase="finished", timestamp=102)))
        with patch.object(monitor.subprocess, "check_output", return_value=f"10 {APP}\n"), patch.object(monitor.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as sample:
            subject.poll(now=104)
        sample.assert_called_once()
        record = json.loads(next(subject.output_dir.glob("*.json")).read_text())
        self.assertEqual(record["nativeStart"]["runID"], "fixture")
        self.assertEqual(set(subject.observed), {"fixture", "fast"})

    def test_finished_or_replaced_marker_before_sampling_cancels_capture(self):
        subject, container, path, marker = self.fixture()
        def output(args, **kwargs):
            path.write_text(json.dumps(dict(marker, phase="finished")))
            return f"10 {APP}\n"
        with patch.object(monitor.subprocess, "check_output", side_effect=output), patch.object(monitor.subprocess, "run") as sample:
            subject.poll(now=104)
        sample.assert_not_called()

    def test_wrong_process_is_never_sampled(self):
        subject, container, _, _ = self.fixture()
        wrong = APP.replace(DEVICE, "OTHER-DEVICE")
        with patch.object(monitor.subprocess, "check_output", return_value=f"10 {wrong}\n"), patch.object(monitor.subprocess, "run") as sample:
            subject.poll(now=104)
        sample.assert_not_called()
        record = json.loads(next(subject.output_dir.glob("*.json")).read_text())
        self.assertIn("does not match", record["error"])

    def test_stale_marker_does_not_consume_later_tests_capture(self):
        subject, _, path, marker = self.fixture()
        with patch.object(monitor.subprocess, "check_output", return_value="10 /usr/bin/other\n"):
            subject.poll(now=104)
        path.write_text(json.dumps(dict(marker, runID="next-test", timestamp=105)))
        with patch.object(monitor.subprocess, "check_output", return_value=f"10 {APP}\n"), patch.object(monitor.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as sample:
            subject.poll(now=109)
        sample.assert_called_once()

    def test_process_scope_requires_executable_and_exact_device(self):
        listing = f"10 {APP}\n11 /usr/bin/python3 -c '{APP}'\n12 {APP}-helper\n13 {APP} --fixture\n"
        self.assertEqual(monitor.matching_pids(listing, DEVICE), [10, 13])

    def test_invalid_or_missing_markers_are_ignored(self):
        subject, container, path, _ = self.fixture()
        for content in ("{", '[]', '{"method": "other"}', '{"method": "' + METHOD + '","pid":10,"runID":"x","phase":"started","timestamp":NaN}'):
            path.write_text(content)
            with patch.object(monitor.subprocess, "check_output", return_value=str(container)), patch.object(monitor.subprocess, "run") as sample:
                subject.poll(now=104)
            sample.assert_not_called()
        path.unlink()
        with patch.object(monitor.subprocess, "run") as sample:
            subject.poll(now=104)
        sample.assert_not_called()

    def test_sample_failure_and_completion_during_capture_are_recorded(self):
        for fails in (False, True):
            with self.subTest(fails=fails):
                subject, container, path, marker = self.fixture()
                def capture(*args, **kwargs):
                    path.write_text(json.dumps(dict(marker, phase="finished")))
                    if fails: raise subprocess.TimeoutExpired(args[0], 15)
                    return subprocess.CompletedProcess([], 0, "", "")
                with patch.object(monitor.subprocess, "check_output", return_value=f"10 {APP}\n"), patch.object(monitor.subprocess, "run", side_effect=capture):
                    subject.poll(now=104)
                record = json.loads(next(subject.output_dir.glob("*.json")).read_text())
                if fails: self.assertIn("error", record)
                else: self.assertTrue(record["testFinishedDuringSample"])

    def test_uninstalled_app_is_normal_before_native_launch(self):
        subject, container, _, _ = self.fixture()
        (container / ".com.apple.mobile_container_manager.metadata.plist").write_bytes(plistlib.dumps({"MCMMetadataIdentifier": "com.other.app"}))
        with patch.object(monitor.subprocess, "check_output") as ps, patch.object(monitor.subprocess, "run") as sample:
            subject.poll(now=104)
        ps.assert_not_called()
        sample.assert_not_called()
        self.assertIsNone(subject.container)

    def test_child_bytes_and_failure_exit_are_preserved(self):
        subject = Mock()
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
            code = "import os;os.write(1,b'hello\\xff\\n');os.write(2,b'error\\x00');raise SystemExit(65)"
            self.assertEqual(monitor.run([sys.executable, "-c", code], subject, out, err), 65)
            out.seek(0); err.seek(0)
            self.assertEqual(out.read(), b"hello\xff\n")
            self.assertEqual(err.read(), b"error\x00")
        subject.close.assert_called_once()

    def test_monitor_start_failure_reaps_running_child(self):
        child = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(60)"])
        subject = Mock()
        subject.thread.start.side_effect = RuntimeError("monitor failed")
        with patch.object(monitor.subprocess, "Popen", return_value=child):
            with self.assertRaisesRegex(RuntimeError, "monitor failed"):
                monitor.run(["unused"], subject)
        self.assertIsNotNone(child.poll())
        subject.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
