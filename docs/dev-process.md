# Owned development processes

Use Python 3.9+ on macOS. This helper runs one foreground command and owns its
cancellation. It cannot attach to a PID, find jobs by name, or stop an existing
backend or Simulator. For background work, use your agent host's own background
tasks.

## Foreground commands and CI cancellation

Use `run` when the caller owns the foreground command and needs its exit status
and streaming output:

```sh
exec python3 scripts/dev-process.py run -- ./scripts/check-native.sh
```

In CI, `exec` makes this helper the step's cancellation owner. It launches the
native runner in a new process group. INT, TERM, and HUP stop that owned group:
TERM, a one-second grace, then KILL and a bounded wait for the child. The helper
does not return to artifact upload while its foreground child is still running.
`--grace` can select zero to thirty seconds. Cancellation exits with 128 plus
the signal number; normal completion preserves the command's exit status.
stdout and stderr stay attached to the caller.

Darwin can report EPERM when only zombies remain in the group. Before reaping
the leader, the helper checks that anchored group for running members. Live or
unreadable membership keeps the delivery warning.

The command must retain its leader until its work finishes. Descendants that
leave the process group or change credentials are outside this ownership
contract. SIGKILL or host loss can prevent cleanup; no later PID lookup is used
to recover control.

Run the disposable process tests without Swift, Xcode, or shared services:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s scripts/tests -p test_dev_process.py -v
```

The ownership design uses Apple's documented [new-session semantics](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setsid.2.html),
[process-group signaling](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kill.2.html),
and [child waiting](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/wait.2.html).
Apple's [group-signal implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sig.c)
excludes zombies and can return EPERM when no live member accepts a signal. The
tests exercise that behavior and observe the unreaped leader during
cancellation on macOS; they do not force system PID reuse.
