---
name: create-release
description: Create a new release for CodexBar. Use when the user says "create a release", "new release", "cut a release", "ship it", or wants to bump/publish a CodexBar version.
---

# Create Release

Create a new GitHub release for CodexBar. Publishing the release triggers the CI pipeline that signs, notarizes, and ships the DMG plus the Homebrew cask.

## Steps

1. Pull latest: `but pull`
2. Confirm nothing is unmerged into `main` — this list of open PRs should be empty:
   ```bash
   gh pr list --repo gordonbeeming/codex-bar --state open
   ```
3. Determine the next version by checking existing releases:
   ```bash
   gh release list --repo gordonbeeming/codex-bar --limit 5
   ```
4. Bump the minor version (e.g. v0.3 → v0.4). Never use a patch number in the tag.
5. Create the release:

````bash
gh release create v{major}.{minor} \
  --repo gordonbeeming/codex-bar \
  --target main \
  --title "CodexBar v{major}.{minor} — {short description}" \
  --fail-on-no-commits \
  --notes "$(cat <<'EOF'
# CodexBar v{major}.{minor} — {short description}

## What's New

- {list changes since last release using git log}

## Install

```bash
brew upgrade --cask gordonbeeming/tap/codex-bar
```

Or download the DMG from the assets below.
EOF
)"
````

   Publish it (no `--draft`) — the pipeline runs on `release: published`.
6. The release pipeline (`.github/workflows/build.yml`) automatically:
   - Build + test
   - Sign with Developer ID
   - Notarize + staple with Apple
   - Create + sign the DMG
   - Upload the DMG asset to the release
   - Update the Homebrew tap cask (`GordonBeeming/homebrew-tap/Casks/codex-bar.rb`)
7. Watch it finish, then report the release URL + run: `gh run watch --repo gordonbeeming/codex-bar`

## Version Format

- Tags: `v{major}.{minor}` (e.g. `v0.4`) — NO patch number; the workflow guard rejects any tag whose (optionally `v`-prefixed) remainder isn't `major.minor`. Always use the `v` prefix in practice: the Homebrew cask template hardcodes `.../download/v#{version}/...`, so a tag without it would upload correctly but break the `brew upgrade` download URL.
- CI sets `CFBundleShortVersionString` to `{major}.{minor}` and `CFBundleVersion` to the run number separately — they're not combined into a single dotted bundle version.
- The tag `v0.4` with run number 45 sets `CFBundleShortVersionString=0.4` and `CFBundleVersion=45`.

## Generating Release Notes

```bash
LAST_TAG=$(gh release list --repo gordonbeeming/codex-bar --limit 1 --json tagName --jq '.[0].tagName')
git log ${LAST_TAG}..origin/main --oneline
```

With no prior release, use:
```bash
git log origin/main --oneline
```

Run any hand-written notes through the `humanizer:humanizer` skill (Skill tool) before publishing — it strips AI-writing patterns from release-note prose. It's a globally-installed Claude Code plugin skill, not a file in this repo, so don't look for it under `.claude/skills/`.

## Important

- Never reuse or delete existing release tags.
- Always bump the minor version; never use a `.0` patch in tags (v0.4, not v0.4.0).
- Don't use `--draft` — a draft doesn't fire `release: published`, so CI won't build.
- The release triggers the full CI pipeline (notarization takes a few minutes) — wait for it to go green before telling anyone to `brew upgrade`.
- The release event re-runs `build-and-test` (it's not skipped just because the branch already built on every push), and the signing job only starts once that passes — check both jobs' logs with `gh run view --log-failed --repo gordonbeeming/codex-bar`. A failure in signing specifically usually means an expired notarization app-password / Developer ID cert in the `prod` environment, or a bad tag.
