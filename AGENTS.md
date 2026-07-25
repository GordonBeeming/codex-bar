# CodexBar — agent notes

## Automation

After a code change that affects the built app, install it locally automatically—don't wait to be asked:

```bash
make install
```

`make install` builds a release binary, signs it with the available Apple Development identity, copies it over the Homebrew cask's `/Applications/CodexBar.app` (so the dev build replaces the installed app rather than making a second copy), removes the `dist/` build output, and stops the running instance so the next launch uses the change. Relaunch it with:

```bash
open /Applications/CodexBar.app
```

Override the destination with `make install INSTALL_DIR=~/Applications` if you ever need a side-by-side copy.

Skip installation only when explicitly asked not to, or when the change is limited to documentation or tests and there is nothing new to run.

## Build and test

- Use `swift build` and `swift test` for the quick development loop.
- Use `make bundle` to produce the signed app under `dist/` without installing it.
