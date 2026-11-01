# Local core checks

Run the fast package checks before sharing a change:

```sh
./scripts/check-core.sh
```

The script resolves its checkout root, so an absolute script path also works
from another directory. It runs these steps in order and returns immediately
with the failing command's status:

1. `swift test --no-parallel --scratch-path .artifacts/CoreTests`
2. `swift build --target BottoCore --scratch-path .artifacts/CoreMainActor -Xswiftc -default-isolation -Xswiftc MainActor`

Use the project's Swift toolchain. Both build directories stay inside the
current checkout. The compatibility build checks BottoCore with MainActor as the
default isolation without changing the package's normal isolation setting.
Explicit serial scheduling avoids suite-wide localhost fixture contention under
heavy machine load; concurrency exercised inside individual tests stays intact.
The runner does not select a Simulator, run native/UI tests, or perform Files
export/readback. Use [the full check script](../scripts/check.sh) for that
additional coverage.

## Contributor CI and native diagnosis

The [iOS workflow](../.github/workflows/ios.yml) runs independent core, tooling,
and native jobs. Core checks use the Swift toolchain and also exercise process
ownership on macOS. The tooling job runs the complete Python suite on Linux.
On pull requests, the native job builds the app and all tests without running
the Simulator suite. After a merge to `main`, it runs all `BottoTests` serially.
The required `verify` check fails unless all three jobs succeed, including when
a dependency fails, is cancelled, or is skipped. A passing PR build cannot
authorize TestFlight: delivery requires the full successful iOS **push** run
for the exact current `main` revision.

Public repositories run automatically; private repositories use manual dispatch.
The split workflow needs fresh hosted verification. Existing native readiness
failures remain under investigation; their tests stay in the main release gate.

`./scripts/check-ci.sh` remains the full local sequence: core, tooling, then
native checks. Native-only and focused diagnosis use
[check-native.sh](../scripts/check-native.sh):

```sh
BOTTO_TEST_DESTINATION='platform=iOS Simulator,id=YOUR-SIMULATOR-UUID' \
  ./scripts/check-native.sh AppStoreAvatarTests
```

Omit the selector to run the full native suite. A selector may name a suite or
an exact `Suite/testFunction(...)`; quote parentheses. The runner checks selector
syntax before building, then uses Xcode's discovery of the built tests before
executing a focused selection. A helper, wrong signature, or empty selection
cannot claim a passing run. Discovered identifiers, build/test status and
`.xcresult` survive result finalization failures where possible. Keep local runs
on an owned device.

For an isolated hosted diagnostic run of a published branch:

```sh
gh workflow run ios.yml --ref YOUR-BRANCH -f native_test=AppStoreAvatarTests
```

Focused manual runs report `diagnostic-result`, not the required `verify`, and
cannot authorize TestFlight delivery. Their concurrency group is separate from
push checks, so even a full manual run cannot cancel the current `main` check. A focused
pass proves only the selected cases; record the actual executed test count.

The full runner disables verbose Simulator failure diagnostics by default with
`-collect-test-diagnostics never`. Test output and the `.xcresult` under
`.artifacts/DerivedData/Logs/Test` remain available. Independent Files-provider
readback still runs after a failed test and cannot mask its exit status.
To opt in to Xcode's verbose collection for a diagnostic run:

```sh
BOTTO_TEST_DIAGNOSTICS=on-failure ./scripts/check.sh
```

Verbose collection can take several minutes after a failure. The runner accepts
only `never` and `on-failure`; it does not restart Simulator services.

## Hosted native accessibility tests

The shared `RichReplyRuntime` test scope enables accessibility automation inside
the Simulator test process before mounting its SwiftUI fixtures. Without it,
painted rows can report zero accessibility elements to in-process UIKit queries.
A completed external UI-test session does not reliably enable a later test host.

[NativeAccessibilityRuntime](../AppTests/NativeAccessibilityRuntime.swift) uses
the private Simulator automation getter/setter, following the test-host setup
used by [AccessibilitySnapshot](https://github.com/cashapp/AccessibilitySnapshot/blob/main/Sources/AccessibilitySnapshot/Parser/ObjC/ASAccessibilityEnabler.m).
It records the previous setting and restores it at normal process exit. Missing runtime
support fails setup. The helper belongs only to `BottoTests`; it is not app code
and does not run on physical devices.

Use an owned Simulator, a checkout-specific build directory, and serial testing.
For an exact Swift Testing method, quote its identifier including parentheses:

```sh
xcodebuild test -project Botto.xcodeproj -scheme Botto \
  -destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID' \
  -derivedDataPath /tmp/botto-my-check/DerivedData \
  '-only-testing:BottoTests/NativeTranscriptRevisionTests/expandedRawDetailsCopyTheCurrentExactBytesAfterEquivalentUnicodeRevision()' \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO
```

Audit the named method and final Swift Testing count. Its XCTest wrapper can
report zero tests before the real Swift Testing run. Revision-test failure
screenshots are retained as `.xcresult` attachments.

## Opt in to checks before push

Cloning or checking out these files does not enable hooks. To enable the
version-controlled [.githooks/pre-push](../.githooks/pre-push), explicitly run:

```sh
python3 scripts/install-hooks.py
```

The installer only sets repository-local `core.hooksPath=.githooks`. It writes
no hook files and changes no global config. Repeat runs leave the installed
config unchanged. Git's [repository config is shared by linked worktrees](https://git-scm.com/docs/git-worktree#_configuration_file),
so this opt-in applies to the main checkout and its linked worktrees. Each
checkout must contain the hook and runner. Existing worktree-specific config
keeps its normal precedence; the installer does not enable or change the
`extensions.worktreeConfig` setting.

Git resolves a [relative hooks path](https://git-scm.com/docs/git-config#Documentation/git-config.txt-corehooksPath)
from the hook's working directory. For `pre-push` in a non-bare repository,
that is the [current worktree root](https://git-scm.com/docs/githooks#_description).
Each worktree therefore uses its own `.githooks/pre-push`, runner, sources and
build directories. A failed core step rejects the push. The hook checks the
current working tree, including local edits; it does not check out each commit
being pushed. Local hooks remain opt-in and can be bypassed by Git.

The installer refuses to proceed if any existing `core.hooksPath` value differs
from `.githooks`, including inherited global or current worktree values. It
also refuses executable non-sample files in the shared default hooks directory,
including an existing `.git/hooks/pre-push`, so enabling this path cannot
silently bypass those hooks. Disabled hook files and `.sample` files remain
untouched. The project hook and runner must already be executable.

If installation is refused, keep the existing setup and run
`./scripts/check-core.sh` directly. Inspect path settings with:

```sh
git config --show-origin --show-scope --get-all core.hooksPath
```

To remove this repository opt-in, first confirm the local value is `.githooks`,
then remove only that value:

```sh
git config --local --unset core.hooksPath '^[.]githooks$'
```

This restores the previously inherited/default path and applies to linked
worktrees too. It leaves all hook files and global config intact.

## Test the tooling without Swift or Xcode

```sh
python3 scripts/tests/test_local_checks.py
python3 scripts/tests/test_full_checks.py
```

The standard-library suite creates disposable Git repos and linked worktrees,
uses a harmless `swift` stub, and performs real pushes to local bare remotes.
It covers command order and working directory, failing-step propagation,
push rejection and success, hook/config preservation, repeat installation,
and isolation from unrelated repositories and global config. It removes its
temporary repos on completion and does not install hooks in this checkout.
The full-runner suite also uses Xcode and export-readback stubs to check
diagnostic selection and failure-status preservation without a Simulator.
