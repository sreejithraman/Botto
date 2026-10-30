# Project workflow

Launch and check commands live in [README](../../README.md);
[setup](../setup.md) owns connection requirements. Use the checked-in Xcode
project; [project.yml](../../project.yml) owns its generated settings.

## Checks and acceptance

- [Local checks](../local-checks.md) owns the fast core runner and optional
  repository-local pre-push hook. Use [owned process control](../dev-process.md)
  when a background job needs a recorded identity and safe teardown.
- [scripts/check.sh](../../scripts/check.sh) owns the full local check sequence:
  core tests, a MainActor-default compatibility build, serial Xcode tests, and
  independent artifact-export readback. It selects the first available iPhone
  Simulator, disables signing, and writes to `.artifacts/`. On a shared machine, use an explicit owned
  destination for native checks and provider readback.
- [Contributor CI](../../scripts/check-ci.sh) covers package, MainActor,
  Python tooling, and unsigned Simulator/native unit-test checks. The
  [workflow](../../.github/workflows/ios.yml) runs automatically for public
  repositories and supports manual dispatch once Actions is enabled. Private
  repositories use manual dispatch. Hosted results appear in the repository's
  Actions tab.
- Before selecting a Simulator, preparing fixtures, or investigating test
  startup, read [shared setup and readiness](verification/index.md#shared-setup-and-readiness).
  [Hosted native accessibility setup](../local-checks.md#hosted-native-accessibility-tests)
  explains the test-only runtime and exact Swift Testing selectors.
- Before Keychain-dependent sign-in checks, read
  [credentials, state, and proof](verification/index.md#credentials-state-and-proof)
  for signed-build requirements, test deadlines, and durable readback.

The [verification map](verification/index.md) owns acceptance recipes;
[verification.md](../verification.md) owns recorded results and their limits.

## Live Hermes tests

The isolated [authority host](../dev-host.md) and [sidecar host](../dev-host-sidecar.md)
guides own source pins, prerequisites, opt-in test variables, and teardown.
Their temporary paths are run-owned examples. Live probes create profiles and
mutate host data; use the documented disposable runtimes and read their current
process records before teardown.

## Performance work

Workloads live in the [streaming replay test](../../Tests/BottoCoreTests/StreamingReplayPerformanceTests.swift),
[native performance tests](../../AppUITests/ConversationUITests.swift), and
[scrolling, typing and sending benchmarks](../../AppUITests/ConversationPerformanceUITests.swift).
The [verification record](../verification.md) records checked workloads,
results, and limits. Compare the same workload before and after a performance
change, and keep its behavior intact.

## Review base

The default review base is `main` from `origin`. A dependent stack layer uses
its intended parent as the review base.
