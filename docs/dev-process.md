# Owned development processes

Use Python 3.9+ on macOS. This helper controls commands it launches. It cannot
attach to a PID, find jobs by name, or stop an existing backend or Simulator.
Choose a fresh record and log for each run. Their parent directories must exist.

```sh
python3 scripts/dev-process.py start \
  --record /tmp/my-task-build-01.json \
  --cwd "$PWD" \
  --log /tmp/my-task-build-01.log \
  --destination 'platform=iOS Simulator,id=YOUR-CHOSEN-DEVICE' \
  --output /tmp/my-task-derived-data \
  -- xcodebuild -project Botto.xcodeproj -scheme Botto \
     -destination 'platform=iOS Simulator,id=YOUR-CHOSEN-DEVICE' \
     -derivedDataPath /tmp/my-task-derived-data build

python3 scripts/dev-process.py status --record /tmp/my-task-build-01.json
python3 scripts/dev-process.py stop --record /tmp/my-task-build-01.json --dry-run
python3 scripts/dev-process.py stop --record /tmp/my-task-build-01.json --grace 5
```

The example does not select or prepare a device. Follow the repository's shared
setup guidance before running builds. Any executable and argv can follow `--`;
there is no shell expansion inside the helper. Quote paths with spaces.
`--cwd` is explicit. Relative record/log paths use the caller's directory;
relative command paths and repeatable `--output` paths use `--cwd`.
Repeatable `--destination` labels and `--output` paths describe the command's
actual destination and outputs; they do not configure it or prove ownership of
those resources. The full launch argv is also recorded.

Start confirms exec, not application readiness. Successful commands print JSON
and exit 0. Refusals print a short error to stderr
and exit 1; invalid CLI syntax exits 2. Running status has `verified: true` after
a supervisor round trip. Completed/failed status reads the saved result with
`verified: false`; it does not verify an independently edited terminal record.
`stop` refuses completed, failed, stale, altered, copied, or replaced records.
An existing record or log is never overwritten by `start`.

A private record stores a random run ID and control capability, the child and
supervisor PIDs, resolved launch executable, full argv, cwd, log, metadata, times,
and eventual exit result. PIDs are diagnostic, never control authority. The
capability is omitted from CLI output. Records/logs are 0600; the local Unix
socket is 0600 in a random 0700 directory under `/tmp`. The short socket path
works with long worktree paths. No TCP listener or environment snapshot exists.
Keep secrets out of argv and destination labels; children control their own log
output. This protects against accidental cross-task actions, not malicious code
running as your macOS user.

One supervisor owns one child in a new session/process group. It authenticates
the whole record, its unchanged bytes and inode, then serializes stop and reaping
on one thread. Stop sends TERM, waits the requested grace (0–30 seconds, default
5), sends KILL, then waits at most two seconds for its child. It retains the
unreaped child PID through the final signal, including when TERM exits the
leader. No later PID lookup can redirect either signal. Dry-run authenticates
ownership and describes these signals without sending them.

Stop waits the full grace so descendants can finish after their leader exits.
`signal_warnings` reports unconfirmed group delivery; macOS can return EPERM
when only a zombie remains. Completion proves the direct child's exit, not the
exit of descendants that escape its process group or change credentials. Launch
foreground commands that retain their leader until their work finishes. Normal
completion retires control immediately. No descendant discovery occurs.

The supervisor removes its socket directory when it finishes. Keep records and
logs for evidence, then remove them yourself. Loss of the supervisor (for
example, SIGKILL or a host crash) leaves a stale record; the helper refuses to
recover ownership or signal its saved PID. A lost stop reply has an uncertain
outcome: query status with the same record. Status may briefly refuse during a
record update or an in-progress stop. Do not recover by guessing a PID.

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
tests exercise that behavior and observe the unreaped leader during escalation
on macOS; they do not force system PID reuse.
