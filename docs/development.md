# Development and release guide

This document covers the contributor and maintainer details that don't need to sit in the consumer-focused README.

## Requirements

- macOS 15 or later on Apple Silicon
- Xcode with Swift 6.1 or later
- Codex CLI installed and signed in with ChatGPT for live usage data

## Build and test

Run the normal development checks with:

```sh
swift build --build-tests
swift test --parallel
```

The Makefile also provides a release build target and a standard test target:

```sh
make build  # swift build -c release
make test   # swift test
```

## Run and install

Run the executable directly from source with:

```sh
make run
```

`swift run` doesn't create an app bundle, so launch-at-login controls are only available in an installed build.

After any code change that affects the app, install and relaunch it:

```sh
make install
open ~/Applications/CodexBar.app
```

`make install` builds the release executable, creates `dist/CodexBar.app`, signs it with an available Apple Development identity or ad-hoc identity, stops the running installed copy, and copies the new bundle to `~/Applications`.

To create the signed bundle without installing it:

```sh
make bundle
```

You can override the bundle metadata and signing options when packaging:

```sh
make bundle VERSION=0.3 BUILD=42 CODESIGN_IDENTITY="Developer ID Application: YOUR_NAME (TEAM_ID)" CODESIGN_OPTS="--options runtime --timestamp"
```

## Project structure

- `Sources/CodexBarCore` contains the testable protocol models, usage mapping, formatting, severity thresholds, celebration detection, and snapshot stabilization.
- `Sources/CodexBar` contains the app-server client, settings, menu-bar UI, reactions, launch-at-login support, and icon rendering.
- `Tests/CodexBarCoreTests` covers the core behavior.
- `Packaging/Info.plist` and `Makefile` build the distributable app bundle.
- `.github/workflows/build.yml` runs CI and publishes releases.

## Release process

Releases use `vX.Y` tags. Publishing a GitHub release triggers the release job, which:

1. Builds and tests all targets.
2. Imports the Developer ID certificate into a temporary keychain.
3. Builds and signs `CodexBar.app` with the hardened runtime and timestamping.
4. Verifies the signature, submits the app for notarization, and staples the ticket.
5. Creates and uploads `CodexBar-X.Y.dmg`.
6. Updates `gordonbeeming/homebrew-tap` with the matching version and SHA-256 checksum.
7. Signs the Homebrew cask commit before pushing it through the repository-specific deploy key.

The `prod` GitHub environment provides these secrets:

- `DEVELOPER_ID_CERTIFICATE`
- `DEVELOPER_ID_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`
- `HOMEBREW_TAP_DEPLOY_KEY`
- `COMMIT_SIGNING_KEY`

The certificate secret contains the base64-encoded `.p12`. `COMMIT_SIGNING_KEY` must contain an OpenSSH-formatted private key because Git's SSH signing helper doesn't accept the PKCS#8 export produced by some password managers.
