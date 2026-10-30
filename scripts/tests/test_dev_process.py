import errno
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


CLI = Path(__file__).resolve().parents[1] / 'dev-process.py'


class DevProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='botto-process-test-')
        self.root = Path(self.temp.name)
        self.record = self.root / 'job.json'
        self.log = self.root / 'job.log'
        self.original = None
        self.unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])

    def tearDown(self):
        try:
            if self.original is not None:
                self.record.write_bytes(self.original)
                self.cli('stop', '--record', self.record, '--grace', '0.1')
                runtime = Path(json.loads(self.original)['socket']).parent
                deadline = time.monotonic() + 5
                while runtime.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(runtime.exists(), 'supervisor runtime leaked')
        finally:
            survived = self.unrelated.poll() is None
            if survived:
                self.unrelated.terminate()
            self.unrelated.wait(timeout=5)
            self.temp.cleanup()
        self.assertTrue(survived, 'unrelated child was terminated')

    def cli(self, *args):
        return subprocess.run([sys.executable, str(CLI), *map(str, args)],
                              text=True, capture_output=True, timeout=15)

    def start(self, source='import time; print("ready", flush=True); time.sleep(60)', *options):
        result = self.cli('start', '--record', self.record, '--cwd', self.root,
                          '--log', self.log, *options, '--', sys.executable, '-c', source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.original = self.record.read_bytes()
        return json.loads(result.stdout)

    def wait_for_log(self, text):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.log.exists() and text in self.log.read_text():
                return
            time.sleep(0.02)
        self.fail(f'log did not contain {text!r}')

    def test_start_status_dry_run_stop_preserves_unrelated_process(self):
        run = self.start()
        self.wait_for_log('ready')
        self.assertEqual(run['argv'], [sys.executable, '-c',
                                      'import time; print("ready", flush=True); time.sleep(60)'])
        self.assertEqual(run['cwd'], str(self.root.resolve()))
        self.assertEqual(run['log'], str(self.log.resolve()))
        status = self.cli('status', '--record', self.record)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(json.loads(status.stdout)['run_id'], run['run_id'])
        dry = self.cli('stop', '--record', self.record, '--dry-run', '--grace', '0.1')
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertTrue(json.loads(dry.stdout)['dry_run'])
        self.assertEqual(self.cli('status', '--record', self.record).returncode, 0)
        stopped = self.cli('stop', '--record', self.record, '--grace', '0.1')
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        self.assertEqual(json.loads(stopped.stdout)['state'], 'completed')
        self.assertIsNone(self.unrelated.poll())
        self.assertNotEqual(self.cli('stop', '--record', self.record).returncode, 0)
        self.wait_for_completion()
        self.original = None

    def wait_for_completion(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result = self.cli('status', '--record', self.record)
            if result.returncode == 0:
                record = json.loads(result.stdout)
                if record['state'] == 'completed':
                    runtime = Path(json.loads(self.original)['socket']).parent
                    while runtime.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertFalse(runtime.exists(), 'supervisor runtime leaked')
                    return record
            time.sleep(0.02)
        self.fail('job did not complete')

    def test_altered_record_cannot_stop_either_process(self):
        run = self.start()
        for field, value in [('pid', self.unrelated.pid), ('run_id', 'another-run'),
                             ('capability', 'wrong-capability'), ('argv', ['/bin/false']),
                             ('cwd', '/'), ('log', '/tmp/foreign.log')]:
            with self.subTest(field=field):
                changed = json.loads(self.original)
                changed[field] = value
                self.record.write_text(json.dumps(changed) + '\n')
                for operation in [('status',), ('stop', '--dry-run'), ('stop',)]:
                    refused = self.cli(*operation, '--record', self.record, *(
                        ['--grace', '0.1'] if operation[0] == 'stop' else []))
                    self.assertNotEqual(refused.returncode, 0, refused.stdout)
                self.assertIsNone(self.unrelated.poll())
                self.record.write_bytes(self.original)
                status = self.cli('status', '--record', self.record)
                self.assertEqual(status.returncode, 0, status.stderr)
                self.assertEqual(json.loads(status.stdout)['pid'], run['pid'])

    def test_mismatched_run_stop_refuses_without_signaling_owner(self):
        self.start()
        self.wait_for_log('ready')
        changed = json.loads(self.original)
        changed['run_id'] = 'foreign-run'
        self.record.write_text(json.dumps(changed) + '\n')
        refused = self.cli('stop', '--record', self.record, '--grace', '0.1')
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.record.write_bytes(self.original)
        status = self.cli('status', '--record', self.record)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(json.loads(status.stdout)['state'], 'running')

    def test_unsafe_record_permissions_and_symlinks_refuse(self):
        self.start()
        self.record.chmod(0o644)
        try:
            self.assertNotEqual(self.cli('stop', '--record', self.record).returncode, 0)
        finally:
            self.record.chmod(0o600)
        link = self.root / 'alias.json'
        link.symlink_to(self.record)
        self.assertNotEqual(self.cli('stop', '--record', link).returncode, 0)
        self.assertEqual(self.cli('status', '--record', self.record).returncode, 0)

    def test_invalid_grace_cannot_signal(self):
        self.start()
        for value in ('nan', 'inf', '-1', '31', 'invalid'):
            with self.subTest(value=value):
                result = self.cli('stop', '--record', self.record, '--grace', value)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.cli('status', '--record', self.record).returncode, 0)

    def test_completed_and_stale_records_never_target_foreign_pid(self):
        self.start('print("finished", flush=True)')
        completed = self.wait_for_completion()
        self.assertEqual(completed['returncode'], 0)
        self.assertFalse(completed['verified'])
        self.assertNotEqual(self.cli('stop', '--record', self.record).returncode, 0)
        stale = json.loads(self.original)
        stale['pid'] = self.unrelated.pid
        self.record.write_text(json.dumps(stale) + '\n')
        for operation in ('status', 'stop'):
            result = self.cli(operation, '--record', self.record)
            self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(self.unrelated.poll())
        self.original = None

    def test_foreign_pid_only_record_is_not_adopted(self):
        self.record.write_text(json.dumps({'pid': self.unrelated.pid, 'state': 'running'}))
        self.record.chmod(0o600)
        refused = self.cli('stop', '--record', self.record)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIsNone(self.unrelated.poll())

    def test_record_replacement_and_copy_are_refused(self):
        self.start()
        saved = self.root / 'saved.json'
        self.record.rename(saved)
        self.record.write_bytes(self.original)
        self.record.chmod(0o600)
        try:
            self.assertNotEqual(self.cli('stop', '--record', self.record).returncode, 0)
            self.assertNotEqual(self.cli('status', '--record', saved).returncode, 0)
        finally:
            self.record.unlink()
            saved.rename(self.record)
        self.assertEqual(self.cli('status', '--record', self.record).returncode, 0)

    def test_long_paths_private_storage_and_metadata(self):
        self.root = self.root / ('worktree with spaces ' * 6) / ('nested ' * 15)
        self.root.mkdir(parents=True)
        self.record = self.root / 'job record.json'
        self.log = self.root / 'job output.log'
        run = self.start('import time; print("ready", flush=True); time.sleep(60)',
                         '--destination', 'platform=iOS Simulator,id=disposable-label',
                         '--output', 'Derived Data', '--output', 'results.xcresult')
        self.wait_for_log('ready')
        private = json.loads(self.original)
        self.assertGreater(len(str(self.record)), 108)
        self.assertLess(len(private['socket'].encode()), 104)
        for path, mode in [(self.record, 0o600), (self.log, 0o600),
                           (Path(private['socket']), 0o600),
                           (Path(private['socket']).parent, 0o700)]:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), mode)
        self.assertEqual(run['destinations'], ['platform=iOS Simulator,id=disposable-label'])
        self.assertEqual(run['outputs'], [str(self.root.resolve() / 'Derived Data'),
                                          str(self.root.resolve() / 'results.xcresult')])
        self.assertNotIn('capability', run)
        self.assertNotIn('environment', private)

    def test_startup_failure_records_failure_and_removes_listener(self):
        result = self.cli('start', '--record', self.record, '--cwd', self.root,
                          '--log', self.log, '--', self.root / 'missing-executable')
        self.assertNotEqual(result.returncode, 0)
        failed = json.loads(self.record.read_text())
        self.assertEqual(failed['state'], 'failed')
        self.assertIsNone(failed['pid'])
        self.assertFalse(Path(failed['socket']).parent.exists())
        self.assertNotEqual(self.cli('stop', '--record', self.record).returncode, 0)

    def test_start_refuses_symlink_log_without_creating_target(self):
        target = self.root / 'untouched.log'
        self.log.symlink_to(target)
        result = self.cli('start', '--record', self.record, '--cwd', self.root,
                          '--log', self.log, '--', '/bin/echo', 'disposable')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())

    def test_existing_record_or_log_is_never_overwritten(self):
        self.record.write_text('other task record')
        result = self.cli('start', '--record', self.record, '--cwd', self.root,
                          '--log', self.log, '--', '/bin/sleep', '60')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.record.read_text(), 'other task record')
        self.assertFalse(self.log.exists())
        self.record.unlink()
        self.log.write_text('other task log')
        result = self.cli('start', '--record', self.record, '--cwd', self.root,
                          '--log', self.log, '--', '/bin/sleep', '60')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text(), 'other task log')
        self.assertEqual(json.loads(self.record.read_text())['state'], 'failed')

    def test_escalation_keeps_exited_leader_unreaped_until_last_signal(self):
        descendant = """
import os, signal, subprocess, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
leader = os.getppid()
print('descendant-ready', flush=True)
deadline = time.monotonic() + 3
while time.monotonic() < deadline:
    state = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(leader)],
                           capture_output=True, text=True).stdout
    if 'Z' in state:
        print('anchor-retained', flush=True)
    print('heartbeat', flush=True)
    time.sleep(0.02)
"""
        source = ('import subprocess, sys, time; '
                  f'subprocess.Popen([sys.executable, "-c", {descendant!r}]); '
                  'time.sleep(60)')
        self.start(source)
        self.wait_for_log('descendant-ready')
        try:
            result = self.cli('stop', '--record', self.record, '--grace', '0.4')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['returncode'], -15)
            self.wait_for_log('anchor-retained')
            time.sleep(0.1)
            stopped_log = self.log.read_text()
            time.sleep(0.15)
            self.assertEqual(self.log.read_text(), stopped_log, 'descendant survived escalation')
        finally:
            # The disposable descendant also has its own three-second deadline.
            if self.cli('status', '--record', self.record).returncode != 0:
                time.sleep(3)
        self.wait_for_completion()
        self.original = None

    def test_ignoring_term_is_killed_within_bound(self):
        self.start('import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                   'print("ready", flush=True); time.sleep(60)')
        self.wait_for_log('ready')
        started = time.monotonic()
        result = self.cli('stop', '--record', self.record, '--grace', '0.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['returncode'], -9)
        self.assertLess(time.monotonic() - started, 3)
        self.wait_for_completion()
        self.original = None

    def test_exit_and_concurrent_stop_requests_serialize_safely(self):
        source = ('from pathlib import Path; import time; print("ready", flush=True); '
                  '\nwhile not Path("exit").exists(): time.sleep(0.005)')
        for attempt in range(6):
            self.record = self.root / f'job-{attempt}.json'
            self.log = self.root / f'job-{attempt}.log'
            gate = self.root / 'exit'
            gate.unlink(missing_ok=True)
            self.start(source)
            self.wait_for_log('ready')
            commands = [subprocess.Popen([sys.executable, str(CLI), 'stop', '--record',
                                         str(self.record), '--grace', '0.1'],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                        for _ in range(2)]
            gate.touch()
            for command in commands:
                stdout, stderr = command.communicate(timeout=5)
                self.assertIn(command.returncode, (0, 1), stderr)
                if command.returncode == 0:
                    self.assertEqual(json.loads(stdout)['state'], 'completed')
            self.wait_for_completion()
            self.assertIsNone(self.unrelated.poll())
            self.original = None


class SupervisorCleanupTests(unittest.TestCase):
    def test_teardown_failure_still_closes_resources(self):
        spec = importlib.util.spec_from_file_location('botto_dev_process', CLI)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for failure in ('publication', 'wait'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                record = root / 'job.json'
                record_fd = os.open(record, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
                startup = mock.Mock()
                startup.recv.return_value = b'{"ack":"lost-startup-client"}\n'
                child = mock.Mock(pid=12345, returncode=None)
                if failure == 'wait':
                    child.wait.side_effect = subprocess.TimeoutExpired('owned test child', 2)
                else:
                    def wait(timeout):
                        child.returncode = -15
                    child.wait.side_effect = wait
                config = {
                    'record': str(record), 'cwd': str(root), 'log': str(root / 'job.log'),
                    'executable': '/bin/sleep', 'argv': ['/bin/sleep', '60'],
                    'destinations': [], 'outputs': [],
                }
                original_fsync = os.fsync

                def fsync(fd):
                    if failure == 'publication' and json.loads(record.read_bytes())['state'] == 'completed':
                        raise OSError(errno.ENOSPC, 'No space left on device')
                    return original_fsync(fd)

                def signal_group(pid, sig):
                    self.assertEqual(pid, child.pid)
                    self.assertIsNone(child.returncode, 'child reaped before final signal')

                with mock.patch.object(module.signal, 'signal'), \
                        mock.patch.object(module.subprocess, 'Popen', return_value=child), \
                        mock.patch.object(module.os, 'killpg', side_effect=signal_group) as killpg, \
                        mock.patch.object(module.os, 'fsync', side_effect=fsync):
                    expected = OSError if failure == 'publication' else subprocess.TimeoutExpired
                    with self.assertRaises(expected):
                        module.Supervisor(config, record_fd).run(startup)
                runtime = Path(json.loads(record.read_bytes())['socket']).parent
                try:
                    self.assertFalse(runtime.exists(), 'private socket directory leaked')
                    with self.assertRaises(OSError) as closed:
                        os.fstat(record_fd)
                    self.assertEqual(closed.exception.errno, errno.EBADF)
                    startup.close.assert_called()
                    self.assertEqual(killpg.call_count, 2)
                finally:
                    if runtime.exists():
                        shutil.rmtree(runtime)
                    try:
                        os.close(record_fd)
                    except OSError:
                        pass


if __name__ == '__main__':
    unittest.main()
