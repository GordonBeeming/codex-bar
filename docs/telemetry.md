# Telemetry

CodexBar's telemetry follows the [Bar Telemetry Spec v1](https://github.com/GordonBeeming/bar-ui/blob/main/docs/telemetry-spec.md), the contract shared with ClaudeBar and read by Bar UI. The spec defines the file format, resource attributes, `bar.*` metrics, events and tracking settings. This page only covers what's specific to CodexBar: how Codex's data maps onto the spec, and the extra `codex.*` records CodexBar writes alongside it.

## Turning it on

Enable **Record telemetry to disk** in Settings. Files go to `~/Library/Application Support/CodexBar/Telemetry` unless you choose another folder. Recordings from earlier versions that used `~/Documents/CodexBar Telemetry` move over on first launch. CodexBar captures when recording starts and then every five minutes by default (1 to 1,440). Retention is 90 days by default (1 to 3,650, or unlimited). Reset-credit changes are recorded as soon as a usage poll sees them. Capture runs in the background from launch, including launch at login. It doesn't run during sleep or while CodexBar is closed, and missed captures aren't backfilled.

In Settings, **Apply telemetry settings** saves the interval, retention and folder.

### From a link

Any app or page can change the settings with a `codexbar://` link:

- `codexbar://telemetry?enabled=1&interval=5&retention=0&folder=<percent-encoded path>` accepts any subset of the four parameters. CodexBar shows each change, old value first, and applies it immediately when you click **Apply**. If any value is out of range, the whole link is rejected and CodexBar says why.
- `codexbar://settings` opens the Settings window.

The settings are stored under the defaults keys `telemetryEnabled`, `telemetryIntervalMinutes`, `telemetryRetentionDays` and `telemetryDirectory`, which is where Bar UI reads them.

## How Codex maps onto the spec

### Limits

Every window in every bucket that `account/rateLimits/read` reports becomes a Limit.

- `limit.id` is `<bucket id>:<window minutes>`, for example `codex:10080`. Codex can swap which window it calls primary and secondary, but the window length stays put.
- When Codex reports a window without its length, the ID falls back to `<bucket id>:primary` or `<bucket id>:secondary`, and `limit.window.duration_minutes` is left out.
- `limit.name` is the name the menu shows (`Weekly`, `Session (5h)`). Buckets other than the default `codex` one get the bucket's name added, as in `Weekly · Gpt Spark`.
- Don't count on a five-hour window. Some plans report only the weekly one.

`bar.limit.reset` fires when a Limit's Window rolls over:

- **A Window that ran to its end:** the reset time moves forward by at least half a Window.
- **An early reset:** Codex can reset a Window days before its reset time, and then the reset time only moves by what was left. A move of more than an hour also counts when usage drops sharply (the same rule the celebrations use), or when usage goes down and the new reset time is a full Window away.
- **Never when usage is 0% both before and after.** A Window nobody has used yet floats a full Window ahead of each read, so after a long gap it can look like a rollover.
- **When Codex gives no reset time:** it fires when usage drops sharply.

Switching Codex accounts starts a new baseline instead of firing, because another account's Window isn't a continuation of the last one.

### Tokens

`bar.tokens` counts tokens Codex uses on this Mac from the moment recording starts, read from the rollout files in `sessions` and `archived_sessions` under `CODEX_HOME` (`~/.codex` by default).

- CodexBar remembers how far it has read each session, keyed by the session's ID. Moving a session into `archived_sessions` doesn't count it twice, and deleting old sessions never lowers the total.
- Each turn's usage goes to the model in that turn's `turn_context`. Usage with no turn context goes to `unknown`.
- Codex writes the same running total again for rate-limit updates. CodexBar counts a turn only when that total changes.
- A forked or subagent session starts with history copied from its parent. CodexBar skips that copied history because the parent already counted it.
- Token types:
  - `input` is Codex's `input_tokens` minus `cached_input_tokens`.
  - `cache_write` comes from `cache_write_input_tokens`, which is also subtracted from `input` when Codex counts it there.
  - `cache_read` is `cached_input_tokens`.
  - `reasoning` is the reasoning part of `output` and is already included in it.

The count's position and totals live in `~/Library/Application Support/CodexBar/telemetry-state.json`. Turning recording off deletes that file, so the next start gets a new `startTimeUnixNano`, which lets Bar UI tell a restart apart from a drop.

### Perks

Codex reset credits are `perk.kind=reset_credit`.

- The `bar.perk.available` gauge has one point per available credit, each with value 1, the credit's `perk.id` and its `perk.expires_at`. The points add up to Codex's available count. If the count is higher than the credits the list names, the rest go in one point with no `perk.id`. If the list names more available credits than the count, only that many are written, soonest expiry first. With no credits, the gauge is a single 0 point.
- A credit that Codex reports as redeemed or redeeming produces `bar.perk.gone` with `perk.gone.reason=used`.
- When the count drops for any other reason, CodexBar reports the missing credit as gone. The reason is `expired` if its expiry has passed, and left out otherwise.
- A credit missing from a list while the count holds is not treated as gone, because Codex can return a capped list.
- If the count moves by more credits than CodexBar can name from the list, the rest go into one `bar.perk.available` or `bar.perk.gone` event with no `perk.id`. Its `perk.quantity` is how many credits it covers. Events for a named credit leave `perk.quantity` out, which means 1.

## Extra `codex.*` records

Bar UI ignores these. They keep detail that the spec doesn't cover.

| Metric | Value |
| --- | --- |
| `codex.usage.used_percent`, `codex.usage.reset_time` | Every window, identified by `codex.bucket.id` and `codex.window` |
| `codex.usage.bucket_observed`, `codex.usage.observation_time`, `codex.usage.ordinary_allowed` | Bucket presence, when the response was read, and whether included usage is allowed |
| `codex.credits.has_credits`, `codex.credits.unlimited`, `codex.credits.balance` | Usage-credit flags and numeric balance |
| `codex.spend_control.*` | Individual spend limit, usage, remaining percentage and reset time |
| `codex.reset_credits.available`, `codex.reset_credit.observed`, `codex.reset_credit.granted_at`, `codex.reset_credit.expires_at` | Reset credits by backend ID |
| `codex.account.lifetime`, `.peak_daily`, `.current_streak`, `.longest_streak`, `.longest_running_turn`, `.daily_tokens` | The experimental `account/usage/read` summary, when Codex supports it |

Events: `codex.usage.details` and `codex.reset_credit.details` carry plan, model and display text on each capture. `codex.reset_credit.available`, `.redeeming`, `.redeemed`, `.status_observed` and `codex.reset_credits.availability_observed` follow reset-credit status changes. `codex.account.daily_usage` covers the daily account buckets.

Account data older than two minutes is left out of a capture. Tokens are still recorded, and Settings says the account data was missing.

## Privacy

Telemetry leaves out conversation text, tool output, account identifiers and sign-in credentials. Files and the state file are readable only by you. Write errors show in Settings, and the next capture tries again.
