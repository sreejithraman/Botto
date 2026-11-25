import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


CLI = Path(__file__).resolve().parents[1] / 'dev-process.py'


class ForegroundProcessTests(unittest.TestCase):
    def test_group_permission_failure_stays_unconfirmed_for_live_or_unreadable_members(self):
        spec = importlib.util.spec_from_file_location('dev_process_group_control', CLI)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for listing in ('45678 Z\n45678 S\n', '', 'unexpected output'):
            with self.subTest(listing=listing):
                child = mock.Mock(pid=45678, returncode=None)
                def snapshot(*args, **kwargs):
                    self.assertIsNone(child.returncode, 'group anchor was reaped before inspection')
                    return subprocess.CompletedProcess(args, 0, listing, '')
                def reap(*args, **kwargs):
                    child.returncode = -15
                child.wait.side_effect = reap
                with mock.patch.object(module.os, 'killpg', side_effect=PermissionError), \
                        mock.patch.object(module.subprocess, 'run', side_effect=snapshot):
                    warnings = module.stop_child(child, 0)
                self.assertEqual(len(warnings), 2)
                self.assertTrue(all('delivery unconfirmed' in warning for warning in warnings))

    def test_exited_owned_group_does_not_report_unconfirmed_delivery(self):
        spec = importlib.util.spec_from_file_location('dev_process_zombie_control', CLI)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
        try:
            warnings = module.stop_child(child, 0.1)
            self.assertIsNotNone(child.returncode)
            self.assertEqual(warnings, [])
        finally:
            if child.returncode is None:
                child.kill()
                child.wait(timeout=5)

    def test_run_streams_output_and_preserves_native_exit_status(self):
        source = 'import sys; print("native stdout"); print("native stderr", file=sys.stderr); sys.exit(int(sys.argv[1]))'
        for status in (0, 65):
            with self.subTest(status=status):
                result = subprocess.run([sys.executable, str(CLI), 'run', '--',
                                         sys.executable, '-c', source, str(status)],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, status)
                self.assertEqual(result.stdout, 'native stdout\n')
                self.assertEqual(result.stderr, 'native stderr\n')

    def test_run_preserves_signal_exit_status(self):
        result = subprocess.run([sys.executable, str(CLI), 'run', '--', sys.executable,
                                 '-c', 'import os, signal; os.kill(os.getpid(), signal.SIGTERM)'],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 143, result.stderr)

    def test_run_rejects_missing_commands_and_invalid_grace(self):
        for arguments in ([], *(['--grace', grace, '--', '/bin/true'] for grace in ('-1', '31', 'nan', 'inf', 'invalid'))):
            with self.subTest(arguments=arguments):
                result = subprocess.run([sys.executable, str(CLI), 'run', *arguments],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertIn('refused:', result.stderr)

    def test_foreground_cancellation_keeps_leader_anchored_until_descendant_stops(self):
        descendant = """
import os, signal, subprocess, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
leader = os.getppid()
print('descendant-ready', flush=True)
deadline = time.monotonic() + 3
while time.monotonic() < deadline:
    state = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(leader)], capture_output=True, text=True).stdout
    if 'Z' in state:
        print('anchor-retained', flush=True)
    print('heartbeat', flush=True)
    time.sleep(0.02)
"""
        source = ('import subprocess, sys, time; '
                  f'subprocess.Popen([sys.executable, "-c", {descendant!r}]); time.sleep(60)')
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as directory:
                log_path = Path(directory) / 'foreground.log'
                with log_path.open('w') as output:
                    owner = subprocess.Popen([sys.executable, str(CLI), 'run', '--grace', '0.3', '--',
                                              sys.executable, '-c', source], stdout=output, stderr=output)
                    try:
                        deadline = time.monotonic() + 5
                        while 'descendant-ready' not in log_path.read_text() and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertIn('descendant-ready', log_path.read_text())
                        owner.send_signal(sig)
                        self.assertEqual(owner.wait(timeout=4), 128 + sig)
                        stopped = log_path.read_text()
                        self.assertIn('anchor-retained', stopped)
                        time.sleep(0.15)
                        self.assertEqual(log_path.read_text(), stopped, 'descendant outlived foreground cancellation')
                    finally:
                        if owner.poll() is None:
                            owner.terminate()
                            owner.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
