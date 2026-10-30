#!/usr/bin/env python3
"""Launch and control only this helper's supervised development processes."""

import argparse
from contextlib import ExitStack
import json
import math
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time


MAX_MESSAGE = 1024 * 1024
TERMINAL_STATES = {'completed', 'failed'}


class Refusal(Exception):
    pass


def encode(value):
    return (json.dumps(value, sort_keys=True) + '\n').encode()


def receive(channel, timeout=2):
    deadline = time.monotonic() + timeout
    data = bytearray()
    while len(data) <= MAX_MESSAGE:
        channel.settimeout(max(0.001, deadline - time.monotonic()))
        part = channel.recv(min(65536, MAX_MESSAGE + 1 - len(data)))
        if not part:
            raise Refusal('control channel closed')
        data.extend(part)
        if data.endswith(b'\n'):
            return json.loads(data)
        if time.monotonic() >= deadline:
            break
    raise Refusal('invalid or oversized control message')


def send(channel, value):
    channel.sendall(encode(value))


def read_record(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as record:
        info = os.fstat(record.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise Refusal('record must be a private, owned regular file (0600)')
        data = record.read(MAX_MESSAGE + 1)
        if len(data) > MAX_MESSAGE:
            raise Refusal('record is too large')
        return data, (info.st_dev, info.st_ino)


def public_record(record, **extra):
    return {key: value for key, value in record.items()
            if key not in {'capability', 'socket'}} | extra


def stop_child(child: subprocess.Popen, grace: float) -> list[str]:
    # No poll/wait/reaper may release this child's PID before the last killpg.
    # Its unreaped PID anchors the session's group even if TERM exits the leader.
    warnings = []
    for sig, delay in ((signal.SIGTERM, grace), (signal.SIGKILL, 0)):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            # Darwin killpg returns EPERM for a group containing only zombies.
            warnings.append(sig.name + ': EPERM (group delivery unconfirmed)')
        if delay:
            time.sleep(delay)
    child.wait(timeout=2)
    return warnings


class Supervisor:
    def __init__(self, config, record_fd):
        self.config = config
        self.record_fd = record_fd
        info = os.fstat(record_fd)
        self.record_inode = (info.st_dev, info.st_ino)
        self.record_bytes = b''
        self.record = {
            'version': 1, 'run_id': secrets.token_hex(16),
            'capability': secrets.token_hex(32), 'state': 'starting',
            'record': config['record'], 'cwd': config['cwd'], 'log': config['log'],
            'executable': config['executable'], 'argv': config['argv'],
            'destinations': config['destinations'], 'outputs': config['outputs'],
            'started_at': time.time(), 'supervisor_pid': os.getpid(), 'pid': None,
        }
        self.shutdown = False

    def unchanged(self):
        try:
            data, inode = read_record(self.config['record'])
            return inode == self.record_inode and data == self.record_bytes
        except (OSError, Refusal):
            return False

    def publish(self, **changes):
        if not self.unchanged():
            raise Refusal('record was replaced or altered')
        self.record.update(changes)
        self.record_bytes = encode(self.record)
        os.lseek(self.record_fd, 0, os.SEEK_SET)
        remaining = self.record_bytes
        while remaining:
            remaining = remaining[os.write(self.record_fd, remaining):]
        os.ftruncate(self.record_fd, len(self.record_bytes))
        os.fsync(self.record_fd)

    def finish(self, child, stopped, warnings=None):
        self.publish(state='completed', returncode=child.returncode,
                     stopped=stopped, signal_warnings=warnings or [], finished_at=time.time())

    def request_shutdown(self, _signal, _frame):
        self.shutdown = True

    def run(self, startup):
        child = None
        runtime = None
        try:
            signal.signal(signal.SIGCHLD, signal.SIG_DFL)
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(sig, self.request_shutdown)
            os.umask(0o077)
            runtime = Path(tempfile.mkdtemp(prefix='botto-process-', dir='/tmp'))
            self.record['socket'] = str(runtime / 'control.sock')
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(self.record['socket'])
                os.chmod(self.record['socket'], 0o600)
                listener.listen(8)
                listener.settimeout(0.05)
                self.publish()
                log_fd = os.open(self.config['log'], os.O_WRONLY | os.O_CREAT
                                 | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(log_fd, 'wb') as log:
                    child = subprocess.Popen(self.config['argv'],
                                             executable=self.config['executable'],
                                             cwd=self.config['cwd'], stdin=subprocess.DEVNULL,
                                             stdout=log, stderr=log, start_new_session=True)
                self.publish(state='running', pid=child.pid)
                send(startup, {'ok': True, 'result': public_record(self.record)})
                if receive(startup, 5) != {'ack': self.record['run_id']}:
                    raise Refusal('startup acknowledgment mismatch')
                startup.close()
                while True:
                    # All ownership transitions and reaping run on this one thread.
                    if child.poll() is not None:
                        self.finish(child, stopped=False)
                        return
                    if self.shutdown:
                        warnings = stop_child(child, 1)
                        self.finish(child, stopped=True, warnings=warnings)
                        return
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(2)
                        try:
                            request = receive(connection)
                            if (not isinstance(request, dict)
                                    or request.get('record') != self.record
                                    or not self.unchanged()):
                                raise Refusal('run identity or record mismatch')
                            if child.poll() is not None:
                                self.finish(child, stopped=False)
                                raise Refusal('job already completed; no signal sent')
                            operation = request.get('operation')
                            if operation == 'status':
                                result = public_record(self.record, verified=True)
                            elif operation == 'stop':
                                grace = parse_grace(request.get('grace'))
                                if request.get('dry_run') is True:
                                    result = public_record(self.record, dry_run=True,
                                                           grace_seconds=grace,
                                                           would_signal=['SIGTERM', 'SIGKILL'])
                                elif request.get('dry_run') is False:
                                    warnings = stop_child(child, grace)
                                    self.finish(child, stopped=True, warnings=warnings)
                                    result = public_record(self.record, verified=True)
                                else:
                                    raise Refusal('invalid dry-run value')
                            else:
                                raise Refusal('unknown operation')
                            send(connection, {'ok': True, 'result': result})
                        except (OSError, ValueError, TypeError, Refusal, subprocess.TimeoutExpired) as error:
                            try:
                                send(connection, {'ok': False, 'error': safe_error(error)})
                            except OSError:
                                pass
                        if child.returncode is not None:
                            return
        except (OSError, ValueError, Refusal, subprocess.TimeoutExpired) as error:
            try:
                send(startup, {'ok': False, 'error': safe_error(error)})
            except OSError:
                pass
            if child is None:
                try:
                    self.publish(state='failed', error=safe_error(error), finished_at=time.time())
                except (OSError, Refusal):
                    pass
        finally:
            with ExitStack() as cleanup:
                cleanup.callback(startup.close)
                cleanup.callback(os.close, self.record_fd)
                if runtime is not None:
                    cleanup.callback(shutil.rmtree, runtime)
                if child is not None and child.returncode is None:
                    warnings = stop_child(child, 0.1)
                    if self.unchanged():
                        self.finish(child, stopped=True, warnings=warnings)


def safe_error(error):
    if isinstance(error, subprocess.TimeoutExpired):
        return 'process exit deadline exceeded; query status with this record'
    if isinstance(error, TimeoutError):
        return 'control operation timed out; query status with this record'
    if isinstance(error, OSError):
        return error.strerror or type(error).__name__
    return str(error)


def parse_grace(value):
    if isinstance(value, bool):
        raise Refusal('grace must be a number from 0 to 30 seconds')
    grace = float(value)
    if not math.isfinite(grace) or not 0 <= grace <= 30:
        raise Refusal('grace must be a number from 0 to 30 seconds')
    return grace


def absolute_path(value, base=None):
    path = Path(value).expanduser()
    return str(((base or Path.cwd()) / path).resolve())


def file_path(value):
    path = Path(value).expanduser()
    return str(path.parent.resolve() / path.name)


def start(args):
    cwd = absolute_path(args.cwd)
    if not Path(cwd).is_dir():
        raise Refusal('cwd must be an existing directory')
    argv = args.command
    if argv[:1] == ['--']:
        argv = argv[1:]
    if not argv:
        raise Refusal('provide a command after --')
    executable = argv[0]
    if '/' in executable:
        executable = absolute_path(executable, Path(cwd))
    else:
        search_path = os.pathsep.join(absolute_path(p or '.', Path(cwd))
                                     for p in os.get_exec_path())
        executable = shutil.which(executable, path=search_path)
    if not executable:
        raise Refusal('command executable was not found')
    record_path = file_path(args.record)
    config = {'record': record_path, 'cwd': cwd, 'log': file_path(args.log),
              'argv': argv, 'executable': str(Path(executable).resolve()),
              'destinations': args.destination,
              'outputs': [absolute_path(p, Path(cwd)) for p in args.output]}
    record_fd = os.open(record_path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    parent, child = socket.socketpair()
    try:
        supervisor = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                       '_supervise', str(child.fileno()), str(record_fd)],
                                      pass_fds=(child.fileno(), record_fd),
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, start_new_session=True)
        child.close()
        parent.settimeout(10)
        send(parent, config)
        response = receive(parent, 10)
        if not response.get('ok'):
            supervisor.wait(timeout=5)
            raise Refusal(response.get('error', 'supervisor startup failed'))
        send(parent, {'ack': response['result']['run_id']})
        return response['result']
    finally:
        parent.close()
        child.close()
        os.close(record_fd)


def control(args):
    record_path = file_path(args.record)
    data, _ = read_record(record_path)
    record = json.loads(data)
    if (not isinstance(record, dict) or record.get('version') != 1
            or record.get('record') != record_path):
        raise Refusal('invalid record')
    if record.get('state') in TERMINAL_STATES:
        if args.operation == 'status':
            return public_record(record, verified=False)
        raise Refusal('job is completed or failed; no signal sent')
    if record.get('state') != 'running':
        raise Refusal('job is not running; no signal sent')
    address = record.get('socket')
    if not isinstance(address, str):
        raise Refusal('invalid control socket')
    runtime = Path(address).parent
    try:
        info = runtime.lstat()
    except FileNotFoundError:
        raise Refusal('stale record: owning supervisor is unavailable; no signal sent') from None
    if (runtime.parent != Path('/tmp') or not runtime.name.startswith('botto-process-')
            or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise Refusal('control directory is not private')
    try:
        info = Path(address).lstat()
    except FileNotFoundError:
        raise Refusal('stale record: control socket is unavailable; no signal sent') from None
    if (not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600):
        raise Refusal('control socket is not private')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
        channel.settimeout(2)
        try:
            channel.connect(address)
        except (FileNotFoundError, ConnectionRefusedError):
            raise Refusal('stale record: owning supervisor is unavailable; no signal sent') from None
        request = {'operation': args.operation, 'record': record}
        grace = 0
        if args.operation == 'stop':
            grace = parse_grace(args.grace)
            request.update(grace=grace, dry_run=args.dry_run)
        send(channel, request)
        response = receive(channel, grace + 5)
    if not isinstance(response, dict):
        raise Refusal('invalid control response')
    if not response.get('ok'):
        raise Refusal(response.get('error', 'control request refused'))
    return response['result']


def main():
    if sys.argv[1:2] == ['_supervise']:
        channel = socket.socket(fileno=int(sys.argv[2]))
        Supervisor(receive(channel, 10), int(sys.argv[3])).run(channel)
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='operation', required=True)
    launch = commands.add_parser('start', help='launch a new supervised command')
    launch.add_argument('--record', required=True, help='new private record path; never overwritten')
    launch.add_argument('--cwd', required=True, help='command working directory')
    launch.add_argument('--log', required=True, help='new combined stdout/stderr log path')
    launch.add_argument('--destination', action='append', default=[], help='destination label (repeatable)')
    launch.add_argument('--output', action='append', default=[], help='output path relative to cwd (repeatable)')
    launch.add_argument('command', nargs=argparse.REMAINDER)
    commands.add_parser('status', help='query the owning supervisor').add_argument('--record', required=True)
    stop = commands.add_parser('stop', help='ask the owning supervisor to stop its job')
    stop.add_argument('--record', required=True)
    stop.add_argument('--dry-run', action='store_true')
    stop.add_argument('--grace', default='5', help='seconds before SIGKILL, from 0 to 30 (default: 5)')
    args = parser.parse_args()
    try:
        result = start(args) if args.operation == 'start' else control(args)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, TypeError, Refusal, subprocess.TimeoutExpired) as error:
        print('refused: ' + safe_error(error) + '; no PID lookup or fallback signal attempted', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
