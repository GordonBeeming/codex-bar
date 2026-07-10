<p align="center">
  <img src="docs/icon.png" width="128" alt="CodexBar icon" />
</p>

<h1 align="center">CodexBar</h1>

<p align="center">
  Your Codex usage limits, in the macOS menu bar, in your timezone.
</p>

<p align="center">
  <a href="https://github.com/GordonBeeming/codex-bar/actions/workflows/build.yml"><img src="https://github.com/GordonBeeming/codex-bar/actions/workflows/build.yml/badge.svg" alt="Build status" /></a>
  <a href="https://github.com/GordonBeeming/codex-bar/releases/latest"><img src="https://img.shields.io/github/v/release/GordonBeeming/codex-bar" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B%20(Apple%20Silicon)-blue" alt="macOS 15+ Apple Silicon" />
</p>

---

CodexBar shows your Codex plan limits in the menu bar—the same session and weekly percentages reported by Codex, nothing more. The menu-bar item shows the highest usage percentage; the dropdown lists each limit with a progress bar, its reset time in your local timezone, and whether you're ahead of a steady pace through the window.

That's the whole app. No cost tracking, charts, token copying, account switching, or provider abstraction.

> Looking for the same simple menu bar experience for Claude? See [ClaudeBar](https://github.com/GordonBeeming/claude-bar).

## Install

```sh
brew install --cask gordonbeeming/tap/codex-bar
open -a CodexBar
```

CodexBar needs macOS 15 or later on Apple Silicon, plus the [Codex CLI](https://developers.openai.com/codex/cli) installed and signed in with ChatGPT.

The app launches at login by default. You can turn that off in Settings.

### From source

```sh
make install
open ~/Applications/CodexBar.app
```

`make install` builds a release binary and signs it with an available Apple Development identity, falling back to ad-hoc signing.

## Settings

Open **Settings…** from the dropdown:

- **Usage colours** — use the default 75% warning and 90% critical levels, or drag the two splitters to choose your own.
- **Pace flame** — show a flame beside the menu-bar percentage when usage is ahead of a steady pace through a window.
- **Celebrations** — choose full-screen reactions for session resets, weekly resets, and crossing the weekly pace line, or turn them off individually.
- **Launch at login** — on by default for an installed app.

## How it works

CodexBar starts `codex app-server` locally and reads its `account/read` and `account/rateLimits/read` responses once a minute, plus when the menu opens with stale data. Codex remains responsible for authentication and token refresh; CodexBar never reads `~/.codex/auth.json`.

The app guards against temporary usage regressions before updating the display or firing a reset celebration. A suspicious drop must persist across three readings, while a real window reset or a Codex plan change is accepted immediately. Plan changes also reseed the celebration baseline, so upgrading doesn't create a fake reset signal.

If Codex isn't on the app's inherited `PATH`, CodexBar checks common Homebrew, fnm, Volta, nvm, and `~/.local/bin` locations. Set `CODEX_PATH` to an explicit executable path if your installation lives somewhere else.

## Dev loop

```sh
make run    # Run directly from source
make test   # Build and run the unit tests
```

The testable usage mapping, formatting, thresholds, celebration detection, and snapshot stabilization live in `CodexBarCore`. The app target is a small SwiftUI `MenuBarExtra` on top.

## Releasing

Publish a GitHub release tagged `vX.Y` and CI handles the rest: tests, Developer ID signing, notarization, stapling, DMG upload, and the signed Homebrew cask update.

For local setup, packaging details, CI secrets, and the full release process, see the [development and release guide](docs/development.md).
