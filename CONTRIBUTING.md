# Contributing to Botto

Botto focuses on a simple native experience for existing Hermes bots. Discuss
larger features before implementing them, and keep each change focused on a
clear user need.

## Build and run

Use macOS with Xcode 27.1 or later and an installed iOS Simulator runtime. Open
`Botto.xcodeproj`, select the **Botto** scheme, and run on an iPhone or iPad
Simulator. **Explore the demo** works without a Hermes server. See
[build and signing](docs/setup.md#build-and-signing) for app/extension
provisioning and [connection setup](docs/setup.md#2-choose-the-native-listener)
for real-host requirements. Signed Keychain sign-in and unsigned test runs have
different requirements; an unsigned Simulator test pass does not prove login.

The checked-in project is ready to use. Use Python 3.11
or later for repository scripts. If you change `project.yml`, install
[XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0, then regenerate it:

```sh
xcodegen generate
```

## Check a change

Run the fast package checks:

```sh
./scripts/check-core.sh
```

Run the contributor CI checks with full Xcode selected:

```sh
./scripts/check-ci.sh
```

The CI checks cover the package, MainActor compatibility, Python tooling,
and an unsigned Simulator build with native unit tests. Set
`BOTTO_TEST_DESTINATION` to an explicit xcodebuild destination when needed. The
[workflow](.github/workflows/ios.yml) runs for pull requests and pushes to `main`
in public repositories. It also supports manual dispatch. See the
[verification record](docs/verification.md) for executed checks and known gaps.

For UI or file-export changes, also run the full local suite:

```sh
BOTTO_TEST_DESTINATION='platform=iOS Simulator,id=YOUR_OWNED_UUID' ./scripts/check.sh
```

It runs UI tests serially and independently checks exported file bytes. It does
not prove physical-device behavior, signed Keychain login, or every acceptance
recipe. Use the [verification map](docs/agents/verification/index.md) to choose
relevant workflows and record what you observed. Live-host checks use the
isolated [authority](docs/dev-host.md) or [sidecar](docs/dev-host-sidecar.md)
runtimes, never a production Hermes home.

[Local checks](docs/local-checks.md) covers optional pre-push hooks.
[Owned process control](docs/dev-process.md) covers long-running development jobs.

## Submit a change

- Describe the problem, resulting behavior, and relevant checks in the pull request.
- Keep names consistent with the [glossary](GLOSSARY.md).
- Preserve per-chat drafts, connection ownership, and explicit approval boundaries.
- Test meaningful behavior changes, and state any checks you could not run.
- Use sample data in screenshots and test fixtures. Keep credentials and private
  chats out of issues, logs, and commits.
- Preserve third-party attribution when adapting code. Record new dependencies
  and copied code in [Third-party notices](THIRD_PARTY_NOTICES.md).

Report ordinary bugs with reproduction steps, expected and observed behavior,
app and Hermes versions, and sanitized logs when useful. Follow
[Security](SECURITY.md) for sensitive reports.

## License

Botto uses the [MIT License](LICENSE). Preserve existing copyrights and
third-party notices, and identify any added code that uses different terms.
