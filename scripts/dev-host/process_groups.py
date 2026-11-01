"""Signal a launched child group only while its unreaped leader anchors ownership."""

import errno
import os
import select
import signal
import sys
import time


def child_exited(process):
    """Observe an owned child's exit without releasing its group identity."""
    if process.returncode is not None:
        raise RuntimeError("Child was reaped before its process group was retired")
    if hasattr(os, "waitid"):
        return os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
    # Python on macOS exposes kqueue, but not waitid. NOTE_EXIT does not reap.
    queue = select.kqueue()
    try:
        change = select.kevent(process.pid, filter=select.KQ_FILTER_PROC,
                               flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                               fflags=select.KQ_NOTE_EXIT)
        events = queue.control([change], 1, 0)
        for event in events:
            if event.flags & select.KQ_EV_ERROR:
                if event.data == errno.ESRCH:
                    # A departed child can no longer be watched, but remains unreaped.
                    return True
                raise OSError(event.data, os.strerror(event.data))
        return any(event.fflags & select.KQ_NOTE_EXIT for event in events)
    except ProcessLookupError:
        return True
    finally:
        queue.close()


def wait_for_exit(process):
    while not child_exited(process):
        time.sleep(.25)


def stop_group(process, grace=15):
    if process.returncode is not None:
        raise RuntimeError("Cannot drain a process group after reaping its leader")
    try:
        for sig, delay in ((signal.SIGTERM, grace), (signal.SIGKILL, 0)):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass
            except PermissionError:
                # Darwin can deny delivery when only the unreaped zombie remains.
                sys.stderr.write(sig.name + ": EPERM (group delivery unconfirmed)\n")
            if delay:
                time.sleep(delay)
    finally:
        # Every group signal precedes the only reap, even on a delivery error.
        process.wait(timeout=2)
