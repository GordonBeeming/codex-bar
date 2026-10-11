# Telemetry

Enable **Record telemetry to disk** in Settings to start recording. The default folder is `~/Documents/CodexBar Telemetry`. You can choose another folder and open it in Finder from the same section.

Captures start when recording is enabled, then run every five minutes by default while CodexBar is running. The interval accepts 1 to 1,440 minutes. Reset-credit changes are recorded as soon as a usage poll detects them, independently of that interval. CodexBar does not collect during sleep or while it is closed, and it does not backfill missed captures.

Background collection starts at app launch, including launch at login. You don't need to open the menu or Settings to start it.

Use **Apply telemetry settings** to save the interval, retention, and destination. Editing a field or choosing a folder does not trigger recording or delete files. Interval changes preserve the credit observation baseline and schedule the next capture after the new interval.

Applying a new destination starts a capture immediately and applies the saved retention policy to existing CodexBar files in that folder.

## Files and retention

Each file contains UTF-8 [OTLP JSON](https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding), with one JSON object per line. Metrics and logs have separate files, following the [OpenTelemetry JSON file serialization](https://opentelemetry.io/docs/specs/otel/protocol/file-exporter/#json-file-serialization):

```text
codexbar-metrics-2026-10-11.jsonl
codexbar-logs-2026-10-11.jsonl
```

Dates use UTC. The default retention is 90 UTC calendar days, including today, and accepts 1 to 3,650 days. Choose **Unlimited retention** and apply the settings to keep files until you delete them; automatic cleanup is disabled. Limited retention removes expired CodexBar metrics and log files from the selected folder before each write. Other filenames and symbolic links are left alone. Turning recording off keeps existing files and pauses retention cleanup. Changing folders leaves files in the previous folder in place.

The top-level objects are `resourceMetrics` and `resourceLogs`. They identify the service as `CodexBar`, include its version, and use instrumentation scope `com.gordonbeeming.CodexBar.telemetry`, version `1`. OTLP timestamps and integer values are decimal strings. Each metric is a gauge representing a captured value.

## Account usage

CodexBar records the fields returned by `account/rateLimits/read`. Every primary and secondary window in every bucket gets a separate data point, identified by `codex.bucket.id` and `codex.window`. When a multi-bucket response is present, its legacy single-bucket mirror is excluded.

| Metric | Value |
| --- | --- |
| `codex.usage.used_percent` | Used percentage, regardless of fuel tank display mode |
| `codex.usage.reset_time` | Window reset time, Unix seconds |
| `codex.usage.bucket_observed` | Bucket present |
| `codex.usage.observation_time` | Time the source response was read, Unix seconds |
| `codex.usage.ordinary_allowed` | Included usage allowed: 1 or 0 |
| `codex.credits.has_credits`, `codex.credits.unlimited` | Credit flags: 1 or 0 |
| `codex.credits.balance` | Numeric credit balance |
| `codex.spend_control.reached` | Spend control reached: 1 or 0 |
| `codex.spend_control.remaining_percent`, `codex.spend_control.reset_time` | Individual spend limit's remaining percentage and reset time |
| `codex.spend_control.limit`, `codex.spend_control.used` | Numeric individual spend limit and usage, when parseable |
| `codex.reset_credits.available` | Backend-reported available reset-credit count |
| `codex.reset_credit.observed`, `codex.reset_credit.granted_at`, `codex.reset_credit.expires_at` | Each reported reset credit, identified by its backend identifier |

Missing fields produce no data point. Account metrics use the capture time as `timeUnixNano` and report the source observation time as a separate metric. They reflect the API response before the menu's display stabilization. If account data is older than two minutes, that capture omits account metrics and Settings reports that only local tokens were recorded.

Periodic `codex.usage.details` and `codex.reset_credit.details` logs preserve plan and model names, reported state, raw decimal strings, and credit display text. Changing values stay out of metric identity attributes, so each capture updates the same usage series.

When telemetry is enabled, CodexBar also requests the experimental `account/usage/read` method during usage refreshes. Supported versions provide `codex.account.lifetime`, `codex.account.peak_daily`, `codex.account.current_streak`, `codex.account.longest_streak`, and `codex.account.longest_running_turn` gauges. Daily usage buckets produce `codex.account.daily_tokens` points at each day's UTC start, plus `codex.account.daily_usage` logs at capture time. Historical days are emitted at the first capture and when they change; today's bucket is included at each capture. The account token metrics use `codex.token.scope=account`, separately from local totals. Older or unsupported versions can still record limits and local tokens; Settings shows the account summary error.

## Local token totals

CodexBar reads `sessions` and `archived_sessions` under `CODEX_HOME`, or `~/.codex` by default. It takes the latest completed `token_count` event with `total_token_usage` from each rollout and deduplicates copies by the canonical thread UUID. Repeated cumulative updates within a session are not added together. For forks, inherited cumulative counts are subtracted using copied history or the referenced parent prefix. Copied subagent histories use their explicit history-start ordinal because their records receive new timestamps when copied. Unchanged files and resolved fork baselines are cached; changed files are searched backwards with bounded memory.

| Metric | Value |
| --- | --- |
| `codex.tokens.input`, `codex.tokens.output`, `codex.tokens.total` | Sum of the latest cumulative counts across retained local sessions |
| `codex.tokens.cached_input`, `codex.tokens.cache_write_input`, `codex.tokens.reasoning_output` | Optional counts, summed across sessions that report each field |
| `codex.tokens.sessions` | Number of unique local sessions with token totals |
| `codex.tokens.sessions_reporting` | Number of sessions reporting each token kind, identified by `codex.token.kind` |
| `codex.tokens.files_skipped` | Unique session histories whose usage cannot be read or whose fork ancestry cannot be resolved |
| `codex.tokens.observation_time` | Latest token observation time across the included sessions, Unix seconds |

These metrics carry `codex.source=local_session_files` and `codex.token.scope=retained_local_sessions`. Reporting counts show when an optional field has narrower coverage. Cached input and reasoning output are already included in their corresponding input and output totals; adding them again would double count.

The totals cover readable retained session files on this Mac, across accounts that have used those files. They are not account-wide totals, billing amounts, or counts for a particular quota window. Deleting session files can reduce the totals, which is why they are gauges. Local tokens can still be recorded when account usage is unavailable. Unreadable files, malformed token data, or unresolved fork histories are excluded and counted in `files_skipped`; Settings reports when the totals are partial. A broken duplicate does not count as skipped if another copy supplies that thread's usage.

## Reset-credit events

Log bodies contain event names such as `codex.reset_credit.available`, `codex.reset_credit.redeeming`, and `codex.reset_credit.redeemed`. Attributes include the reported status, previous observed status, and whether this is the first observation. Count changes use `codex.reset_credits.availability_observed`.

Redemption is logged only when Codex explicitly reports a transition to `redeemed` from a previously observed status. A credit first seen as redeemed gets a status observation, not a new redemption event. A decreasing count or a credit disappearing from a capped list does not prove redemption. Some backends supply only an available count, so those accounts have count observations without individual redemption events. Timestamps record when CodexBar observed the state, rather than the exact time it changed on the server. Enabling recording or changing the destination starts a new observation baseline; interval and retention edits preserve it.

## Privacy and exporters

Telemetry excludes conversation text, tool output, account identifiers, and authentication credentials. Newly created files have owner-only permissions. Write and collection errors appear in Settings, and the next capture retries. Retention failures are reported without blocking new captures. An unfinished final record from a failed write is removed before the next append, preserving valid JSON Lines.

This version writes only to local disk. Export uses the `TelemetrySink` interface, so future exporters can use the same encoded metrics and logs without changing collection.
