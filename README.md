# CodexBar

[![Build and Test](https://github.com/GordonBeeming/codex-bar/actions/workflows/build.yml/badge.svg)](https://github.com/GordonBeeming/codex-bar/actions/workflows/build.yml)

CodexBar puts your Codex plan limits in the macOS menu bar. It shows the current five-hour and weekly usage, reset times in your timezone, and whether you're ahead of a steady pace through each window.

It deliberately stops there: no cost tracking, charts, token copying, account switching, or provider abstraction.

Settings cover the parts that affect the small menu-bar experience:

- Default or custom warning and critical colours
- A pace flame beside the menu-bar percentage
- Full-screen reactions for session resets, weekly resets, and crossing weekly pace
- Launch at login

## Requirements

- macOS 15 or later on Apple Silicon
- Codex CLI installed and signed in with ChatGPT

CodexBar starts `codex app-server` locally and reads its documented `account/read` and `account/rateLimits/read` responses. Codex owns authentication and token refresh; CodexBar never reads `~/.codex/auth.json`.

If Codex isn't on the app's inherited `PATH`, CodexBar also checks common Homebrew, fnm, Volta, nvm, and `~/.local/bin` locations. Set `CODEX_PATH` to an explicit executable path when needed.

## Build and install

```sh
make test
make install
open ~/Applications/CodexBar.app
```

The installed app launches at login by default. You can turn that off in Settings.

## Development

```sh
make run
```

`swift run` doesn't produce an app bundle, so launch-at-login controls only appear in the installed app.

## Releasing

Publish a GitHub release tagged `vX.Y`. The release workflow builds and tests the app, signs it with the Developer ID certificate, notarizes and staples the bundle, uploads `CodexBar-X.Y.dmg`, then updates `gordonbeeming/homebrew-tap`.

The release job uses the `prod` environment with these secrets:

- `DEVELOPER_ID_CERTIFICATE`
- `DEVELOPER_ID_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`
- `HOMEBREW_TAP_DEPLOY_KEY`
- `COMMIT_SIGNING_KEY`
