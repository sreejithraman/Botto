#!/usr/bin/env python3
"""Run a foreground command and own its cancellation."""

import argparse
import math
import os
import signal
import subprocess
import sys
import time


class Refusal(Exception):
    pass


def group_contains_only_zombies(group_id: int) -> bool:
    try:
        result = subprocess.run(['ps', '-axo', 'pgid=,stat='], capture_output=True, text=True, timeout=1)
        if result.returncode:
            return False
        states = []
        for row in result.stdout.splitlines():
            group, state = row.split()
            if int(group) == group_id:
                states.append(state)
        return bool(states) and all(state.startswith('Z') for state in states)
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


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
            if not group_contains_only_zombies(child.pid):
                warnings.append(sig.name + ': EPERM (group delivery unconfirmed)')
        if delay:
            time.sleep(delay)
    child.wait(timeout=2)
    return warnings


def safe_error(error):
    if isinstance(error, subprocess.TimeoutExpired):
        return 'process exit deadline exceeded'
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


def run_foreground(args):
    argv = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not argv:
        raise Refusal('provide a command after --')
    grace = parse_grace(args.grace)
    interrupted = None
    child = None

    def request_shutdown(signum, _frame):
        nonlocal interrupted
        if interrupted is None:
            interrupted = signum

    handlers = {sig: signal.getsignal(sig) for sig in
                (signal.SIGCHLD, signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    try:
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, request_shutdown)
        if interrupted is not None:
            return 128 + interrupted
        child = subprocess.Popen(argv, start_new_session=True)
        while True:
            if interrupted is not None:
                for warning in stop_child(child, grace):
                    print('foreground stop warning: ' + warning, file=sys.stderr)
                return 128 + interrupted
            status = child.poll()
            if status is not None:
                if interrupted is not None:
                    return 128 + interrupted
                return status if status >= 0 else 128 - status
            time.sleep(0.05)
    finally:
        try:
            if child is not None and child.returncode is None:
                stop_child(child, grace)
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='operation', required=True)
    foreground = commands.add_parser('run', help='run a foreground command and own its cancellation')
    foreground.add_argument('--grace', default='1', help='seconds before SIGKILL, from 0 to 30 (default: 1)')
    foreground.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        return run_foreground(args)
    except (OSError, ValueError, TypeError, Refusal, subprocess.TimeoutExpired) as error:
        print('refused: ' + safe_error(error) + '; no PID lookup or fallback signal attempted', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
