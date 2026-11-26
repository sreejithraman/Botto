# Project workflow

Launch and check commands live in [README](../../README.md);
[setup](../setup.md) owns connection requirements. Use the checked-in Xcode
project; [project.yml](../../project.yml) owns its generated settings.

## Checks and acceptance

- [Local checks](../local-checks.md) owns the fast core runner and optional
  repository-local pre-push hook. [Owned process control](../dev-process.md)
  runs a foreground command that stops its whole process group on cancellation.
- [scripts/check.sh](../../scripts/check.sh) owns the full local check sequence:
  core tests, a MainActor-default compatibility build, serial Xcode tests, and
  independent artifact-export readback. Set `BOTTO_TEST_DESTINATION` to an
  explicit owned, clean iPhone Simulator. It disables signing and writes each
  run's export evidence to a new directory under `.artifacts/`.
- [Contributor CI](../../scripts/check-ci.sh) covers package, MainActor,
  Python tooling, and unsigned app/test builds on PRs. Main pushes also run the
  full serial native suite before TestFlight. Independent workflow jobs feed
  the required aggregate `verify` check. [Native-only
  diagnosis](../local-checks.md) uses `scripts/check-native.sh` and does not
  replace that full gate. The
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

## Live T3 tests

Use a disposable T3 environment and project. Follow
[shared setup and readiness](verification/index.md#shared-setup-and-readiness)
for route review, test isolation, and evidence.

## Performance work

Workloads live in the
[native performance tests](../../AppUITests/ConversationUITests.swift).
The [verification record](../verification.md) records checked workloads,
results, and limits. Compare the same workload before and after a performance
change, and keep its behavior intact.

## Review base

The default review base is `main` from `origin`. A dependent stack layer uses
its intended parent as the review base.
