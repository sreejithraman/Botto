<img src="App/Resources/Assets.xcassets/BottoMark.imageset/BottoMark.svg" width="72" alt="Botto bot-face mark">

# Botto

Botto is a native Mac, iPhone, and iPad companion powered by T3 Code
Orchestrator v2. Your Mac runs the work. Pair your phone directly to the Mac
over LAN, Tailscale, or an HTTPS tunnel you operate.

[![iOS checks](https://github.com/sreejithraman/Botto/actions/workflows/ios.yml/badge.svg?branch=main)](https://github.com/sreejithraman/Botto/actions/workflows/ios.yml)

Use the **Main Space** to coordinate your work with Botto. Keep ongoing work
in named **Spaces** with their own history and drafts. Send files and photos,
answer approvals and questions, and preview the files Botto makes.

## Try it

1. Open `Botto.xcodeproj` in Xcode and run **BottoMac**. On Apple Silicon,
   **Wake Botto** starts the bundled T3 engine. See [engine setup](docs/t3-engine-bundling.md)
   for Intel Macs and custom executable paths.
2. Name your bot and choose its face, then follow the provider setup guide if shown.
3. On the Mac, open **Pair Phone…**. On iPhone or iPad, choose **Pair with your
   Mac** and scan the code or paste the link. Pairing uses a short-lived local
   credential and requires no T3 Cloud account.
4. Choose **Explore the demo** on iPhone or iPad to try sample Spaces without a
   Mac connection.

Botto supports macOS 15, iOS 18, and iPadOS 18 or later. See
[setup and signing](docs/setup.md) for prerequisites and connection recovery,
and [rich replies and files](docs/rich-content.md) for supported previews.

Optional [encrypted Space notifications](docs/push-notifications.md) use
an owner-operated relay and Apple signing.

## Development

The Xcode project is checked in. Regenerate it with XcodeGen when
[project.yml](project.yml) changes. Debug and Internal builds include
[developer tools](docs/developer-tools.md).

```sh
./scripts/check-core.sh
```

This runs the Swift package tests and a MainActor compatibility build. See
[local checks](docs/local-checks.md), [BottoCore integration](docs/core-integration.md),
and the [verification record](docs/verification.md).

## License and credits

Botto is licensed under the [MIT License](LICENSE). Botto uses
[T3 Code](https://github.com/pingdotgg/t3code) and adapts work from
[Hermex](https://github.com/uzairansaruzi/hermex) by Uzair Ansar. See
[third-party notices](THIRD_PARTY_NOTICES.md) and the bundled [licenses](LICENSES/).

See the [changelog](CHANGELOG.md) for release notes,
[Contributing](CONTRIBUTING.md) for changes, and [Security](SECURITY.md) for
sensitive reports.
