# What each harness leaves behind for a worker

A spike for #111 (gap 1: workers are not metered), run on 2026-11-04. The workers (coder,
validator, reviewer, merger) run as interactive sessions in tmux windows started by
`worker-spawn.sh`, and they write no usage record. This finds out what each harness leaves on disk
that a reader could use, so the worker slice (#135) is written against facts.

**Method.** For each harness one real interactive session was started the way its adapter's
`adapter_launch` starts a worker (same flags, a working directory inside a worktree, a one-word
prompt, a private tmux server), left running, read, and then killed. Claude Code was killed three
ways: `kill-window` (SIGHUP), `kill-server` (SIGHUP) and `kill -9`. Codex and Pi were killed with
`kill -9`. The whole spike cost about $0.07, almost all of it three Haiku sessions. Trimmed copies of
the sessions are under `tests/worker-usage/`, and `scripts/test-worker-usage-fixtures.sh` runs
the reading recipes below against them, so none of this needs a model to re-check.

| | claude-code | codex | pi |
| --- | --- | --- | --- |
| Version checked | 2.1.318 | codex-cli 0.166.0 | 1.4.0 (session format 3) |
| Tokens | yes, per API message | yes, cumulative per turn | yes, per message |
| Cost | on exit only | none | yes, per message |
| Model that answered | yes | yes | yes |
| Start and end | yes | yes | start, and a time per message |
| Window or task name in it | the window name, from `-n` | no | no |
| Worktree path in it | yes (`cwd`) | yes (`cwd`) | yes (`cwd`) |
| Readable while running | yes | yes | yes |
| After SIGKILL | tokens yes, cost no | everything completed | everything completed |
| Format documented | no | no | yes |

## Finding the session that belongs to a worker

All three record the working directory, and a worker's working directory is its task's worktree,
which is unique to the task, so `cwd` is the key. Only Claude Code also records the window name
(`custom-title`, from the `-n` the adapter passes), and neither Codex nor Pi takes one from the
adapter today.

A worktree can have several sessions: a task sent back for rework gets a new worker in the same
worktree and with the same window name. Filter by start time (the spawn time, below), not by name.

## claude-code

- **Where.** `~/.claude/projects/<cwd with every / and . replaced by ->/<session-id>.jsonl`. Better
  to read the `cwd` field inside than to rebuild the directory name.
- **What.** One JSON object per line. `assistant` lines carry `message.model` and
  `message.usage`: `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens` (the four counts of a usage record, already disjoint). There is
  no cost on them.
- **A message can appear twice.** The same API message (same `message.id` and `requestId`, different
  `uuid`) was written twice with identical usage. A reader has to deduplicate on `message.id`
  or it doubles the count. Tool use is likely to write one message once per content block; this was
  not tested.
- **Cost.** A `cost-state` line is appended when the process exits: `totalCostUSD`, a `modelUsage`
  block with `costUSD` per model and the `cacheCreationEphemeral1hInputTokens` split,
  `totalDuration` and `startTime`. It was written after `kill-window` and `kill-server` (SIGHUP) and
  was **not** written after `kill -9`. The cost is exactly what the usage and the 1-hour cache-write
  rate give, checked by hand.
- **Killed.** After SIGKILL the assistant lines are all there, so tokens and model are known and the
  cost is not. The price table can estimate it, with the caveat below.
- **Documented.** Not in anything installed with the CLI or in `--help`. It is the harness's own
  format, so treat it as unstable and pin the version it was checked on.
- **Time.** `timestamp` on each line, `durationMs` on the `turn_duration` line, `startTime` and
  `totalDuration` on `cost-state`.

## codex

- **Where.** `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session-id>.jsonl`. Date sharded
  and not keyed by directory, so a reader finds candidates by modification time and reads the first
  line (`session_meta`) for the `cwd`.
- **What.** `event_msg` lines of type `token_count` carry `info.total_token_usage`, cumulative for
  the thread: `input_tokens` (**including** the cached part), `cached_input_tokens`,
  `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`. The last one is the total.
  The model is in `turn_context.payload.model`, not in `session_meta`. This is the same basis the
  Codex adapter already uses for headless runs: subtract the cached part from `input_tokens`.
- **The model is the account's default** when the adapter passes none, which it does not unless the
  workforce sets `params.model`. Here it was `gpt-6.1-sol`, which the price table now has (#149).
- **Cost.** None. A cost has to come from the price table.
- **The allowance.** Each `token_count` also carries `rate_limits`: the 5-hour and the weekly
  `used_percent` with their reset times, the plan type and credits. That is the data the Codex
  subscription slice (#112) wants, and it comes with every worker session at no extra cost.
- **Killed.** The file is appended as events happen, so SIGKILL left it as it was and every
  completed turn is in it. Not tested: a kill in the middle of a turn, where that turn's counts
  are probably lost.
- **Documented.** No.
- **Time.** `session_meta.payload.timestamp`, and `task_started` and `task_complete`, with
  `duration_ms`.

## pi

- **Where.** `~/.pi/agent/sessions/--<cwd with / replaced by ->--/<timestamp>_<session-id>.jsonl`.
  The leading dot of `.worktrees` is kept, unlike Claude Code's.
- **What.** Each `message` line with role `assistant` carries `model`, `provider` and `usage`:
  `input`, `output`, `cacheRead`, `cacheWrite` and `cost.total`, with the cost split by kind. The
  `session` line has the `cwd` and the format `version`. A session's usage is the sum over its
  assistant messages.
- **Cost.** Pi's own figure, per message, from its own price table. For the fixture it equals what
  `usage-prices.json` gives, to the millionth of a dollar.
- **Killed.** Appended per message; SIGKILL left every completed message. A message in flight is
  lost.
- **Documented.** Yes: `docs/session-format.md` in the package, and a session `version` field
  (3 here). A newer Pi (1.5.0 was available) could change it, so read the version.
- **Time.** `ts` on the session line and on each message, and a `timestamp` inside the message.

## The Claude Code allowance (`/usage`)

A spike for #144, run on 2026-11-05 against Claude Code 2.1.318 on a subscription plan. Question:
can a script read the figures `/usage` shows (five-hour window, week, week per model class, usage
credits) without driving the TUI? **Verdict: readable by script, from three sources, none
documented as a stable interface.** Nothing needed scraping, so a tmux read of the screen was not
tried.

| Figure | Status line payload | `/api/oauth/usage` | `cachedUsageUtilization` |
| --- | --- | --- | --- |
| Five-hour window | `rate_limits.five_hour` | `five_hour`, and `limits[kind=session]` | the same as the endpoint |
| Week, all models | `rate_limits.seven_day` | `seven_day`, and `limits[kind=weekly_all]` | the same |
| Week per model class | no | `limits[kind=weekly_scoped]`, `scope.model.display_name` (here `Fable`) | the same |
| Usage credits | no | `extra_usage` and `spend` | the same |
| Needs a model call | no, but only present after the first API response of a session | no | no |
| Needs | a running session with a status line command | the OAuth token in `~/.claude/.credentials.json` | read access to `~/.claude.json` |
| Fresh | at the last API response | at the call | **no**: a copy from whenever Claude Code last fetched |

### Source 1: the status line payload

- **Where.** Claude Code runs the configured `statusLine` command and writes a JSON object to its
  stdin. The binary's own help text documents `rate_limits`; `claude --help` does not.
- **Shape.** `rate_limits.five_hour` and `rate_limits.seven_day`, each `{used_percentage, resets_at}`
  with `resets_at` in epoch seconds. A window is left out once its `resets_at` has passed. For
  gateways there is an optional `spend_limit`. No per-model figure, no credits.
- **Not in the first payload.** The first of two payloads in the capture had `rate_limits: null`; the
  second, after the first API response, had it. A reader has to keep the last non-null one.
- **Example** (one Haiku session, one-word prompt):

  ```json
  {"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1793869800},
                  "seven_day":{"used_percentage":19,"resets_at":1794024000}}}
  ```

- **Not in the session file.** `~/.claude/projects/**/*.jsonl` holds no rate-limit fields, so unlike
  Codex the figures cannot be read after the fact. A reader has to be the status line command (or sit
  behind it) and write them somewhere.
- **Only for sessions with a status line.** `claude -p` was not tried; a headless run probably has no
  status line.

### Source 2: `GET https://api.anthropic.com/api/oauth/usage`

- **How.** `Authorization: Bearer <claudeAiOauth.accessToken>` and `anthropic-beta: oauth-2025-04-20`.
  Returned 200. This is the call the binary makes to draw `/usage` (it logs `fetchUtilization`). It
  is not a model call, so it costs no tokens and does not move the allowance.
- **Not documented, and it uses the user's subscription token.** Treat the shape as unstable and
  pin the version it was checked on. The token expires (`expiresAt`); Claude Code refreshes it, a
  script that only reads would have to be handled when it is stale (the binary re-sends once on a 401).
- **Shape (trimmed).**

  ```json
  {"five_hour":{"utilization":10.0,"resets_at":"2026-11-05T09:10:00.240293+00:00"},
   "seven_day":{"utilization":20.0,"resets_at":"2026-11-07T04:00:00.240316+00:00"},
   "limits":[{"kind":"session","percent":10},{"kind":"weekly_all","percent":20},
             {"kind":"weekly_scoped","percent":0,"scope":{"model":{"display_name":"Fable"}}}],
   "extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":0.0,"currency":"USD","decimal_places":2},
   "spend":{"used":{"amount_minor":0},"limit":{"amount_minor":10000},"percent":0},
   "seven_day_breakdown":{"rows":[{"key":"claude_code","percent":69},{"key":"chat","percent":19},{"key":"cowork","percent":12}]}}
  ```

  `monthly_limit` and `amount_minor` are in minor units: 10000 is $100.00. The old `seven_day_opus`
  and `seven_day_sonnet` keys were null; the per-model figure is in `limits`.

### Source 3: `cachedUsageUtilization` in `~/.claude.json`

- **Where.** A top-level key in `~/.claude.json`: `{fetchedAtMs, accountUuid, utilization}`.
  `utilization` is the `/api/oauth/usage` response, stored as it came back, with the same keys and
  the same shape as Source 2, so one parser reads both. It needs no token and no network.
- **Stale.** `fetchedAtMs` is when Claude Code last fetched, not now. On this machine it read
  2026-11-04 14:26 UTC, about 18 hours older than the capture, and it still did after a whole
  session had been run and the endpoint called twice. It showed 17 % for the week where the
  endpoint said 20.0, and its five-hour window had already reset. A session that ran did not
  refresh it. What does refresh it (opening `/usage` is the guess) was not found out.
- **Use.** Only as a last resort with its age shown, and the reader must compare `fetchedAtMs` with
  the window's `resets_at` and drop a window that has reset since.
- **Other content.** The file also holds `accountUuid` and much else; a reader should
  take only `cachedUsageUtilization.utilization` and not copy the rest.

### Answers to the questions in #144

- **Whole numbers?** The payload gave integers (10, 19). The endpoint gave 10.0 and 20.0 and `limits`
  integers. Fractions were not seen, so assume whole points: one small run moves the figure by 0 or 1.
- **Account-wide or this machine?** Account-wide. `seven_day_breakdown` splits the week into Claude
  Code, Chats and Cowork, so claude.ai chats count against the same window.
- **Fresh?** Not exact. In the capture the payload said `seven_day` 19 while the endpoint, read before
  and after the same run, said 20.0; `five_hour` agreed (10) and so did the reset times. The payload is
  either taken at the time of the last API response or rounds down, and this was not separated. The
  one Haiku prompt did not move the endpoint figures at all, so a run smaller than a point is not seen.
- **Is credits what is used once the windows run out?** Not tested. `extra_usage` (`used_credits`,
  `monthly_limit`) is the pool, and the page's own text says credits "cover you when you hit your plan
  limits", but no run was made that hit a limit here.
- **What does a read cost?** The endpoint: nothing. The status line: it is already running.

### Recommendation

A Claude reader in the shape of `codex-usage.sh` (windows `five_hour`, `weekly`, `weekly_by_model`,
`credits`) can be built on the endpoint, since it is the only source with all four. The status line
payload is the fallback for the first two when no token is available, and `cachedUsageUtilization`
a last resort that can be days old. The reader should take the
version it was checked on, tolerate unknown keys, and report "unavailable" rather than a guess on
a 401 or a changed shape.

**Built in #147** as `scripts/claude-usage.sh` (the endpoint, then the cached copy), with the
capture's real figures as `tests/claude-usage/endpoint.json`. The status line payload was left out of
#147: it needs a status line command that saves it, and the endpoint already covers all four windows.
**#155 added it** as the second source (`scripts/claude-statusline-save.sh` saves it, `claude-usage.sh`
reads it, five-hour and weekly only), tested on fixtures made from the capture's payload shape. Still
unverified: whether its whole-point percentage lags or rounds down against the endpoint (19 against
20.0 at one moment), whether `claude -p` has a status line payload at all, and the gateway
`spend_limit`, never seen. What the reader settled, and what it assumed:

- **Token handling.** The reader skips an expired token, does not refresh it, and on a 401 falls back to
  the cached copy; the token goes to curl on stdin only. A real call returned 200 with the figures
  `/usage` shows.
- **Stability.** The version checked (2.1.318) is in every reading; unknown keys are ignored and an
  unknown shape turns figures unknown.
- **Per-model windows.** The endpoint gives a model's percentage but no reset time of its own, so the
  reader uses the week's and marks it `resets_at_source: "weekly"`. Only Fable showed on this plan.
- **Credits** are read from `spend.*.amount_minor` (minor units), not `extra_usage.used_credits`, whose
  unit is not documented.
- **Fractions and the payload-versus-endpoint gap** stay open. The reader keeps a fraction if one
  comes (the endpoint sent `10.0`) but one has not been seen.
- **A run's difference needs two endpoint readings**, never the cached copy.
- **Pi is not metered.** `pi` runs on whatever provider its model needs and has no allowance of its
  own to read; a Pi run that spent a Claude or ChatGPT subscription would move the account's window
  unseen. Whether Pi may declare a `subscription:*` pool at all (a third-party harness using a
  subscription login may not be allowed) is a separate question for the workforce schema.
- **The window is the account's.** A person using Claude by hand moves it during a run too.

## Findings that change the price table

- **Claude Code's cache write was billed at the 1-hour rate** (`cacheCreationEphemeral1hInputTokens`
  was the whole write). The table held only the 5-minute rate, so the estimate for this
  session was $0.0156 against a reported $0.0231. Fixed in #149: the record carries
  `cache_write_1h_tokens` (from the session's `cache_creation.ephemeral_1h_input_tokens`, and from
  `modelUsage.*.cacheCreationEphemeral1hInputTokens` in `claude -p`'s JSON) and the table has a
  `cache_write_1h` price, so the estimate now equals the reported cost.
- **Codex's default model was not in the table**, so its worker lines were `unknown`. `gpt-6.1-sol`
  was added in #149 at its short-context standard rate, with its date and source.

## Recommendation

This is what the worker slice (#135) was built from; "Worker usage" in
`docs/event-driven-conductor.md` describes what it does.

**All three can be metered now**, none of them only partly:

| Harness | Tokens | Model | Cost |
| --- | --- | --- | --- |
| pi | session file | session file | reported by Pi |
| claude-code | session file | session file | reported on exit; estimated after a hard kill |
| codex | session file | session file | estimated from the price table (once the model is priced) |

**The one place in `worker-spawn.sh`** is the line after `adapter_launch` (the last step before the
`Spawned ...` message). Nothing exists to read at spawn time, so it should only write a small spawn
record under `$CONDUCTOR_DIR`: role, task, adapter, the worktree's absolute path, `params` and the
start time in UTC. That record is what lets a later reader pick the right session out of a
worktree's several.

**The reading belongs where the window closes**, not at spawn: `close_worker_window` in
`scripts/handler-steps.sh`, which every script handler already calls. Two details matter. Close the
window first and read after, with a wait of a couple of seconds, because Claude Code writes its
`cost-state` line only when it exits. And the skill handlers that still call `tmux kill-window`
inline (`skills/conductor/on-*.md`) have to be moved onto `close_worker_window`, or they would
leave unmetered workers.

**Split the worker slice per harness?** Not into separate issues. What the three share is the larger
part: the spawn record, the hook at close, and writing a line in the same `usage.jsonl` shape (with
`role` set to the worker's role, which #131 prepared). What differs is the reader, about twenty
lines of `jq` each, and the recipes in `scripts/test-worker-usage-fixtures.sh` are those readers.
Build the slice once with three small readers behind one function, in the order Pi, Claude Code,
Codex: Pi is documented and reports its own cost, Claude Code needs the deduplication and the
exit wait, Codex needs a priced model.

## Not tested

- The Claude allowance: what refreshes `cachedUsageUtilization`; credits being drawn once a window is full; a status line payload with a
  `spend_limit` (gateway); `claude -p` with a status line; fractional percentages; whether the payload
  lags the endpoint or rounds down (#144). Still untested after the reader (#147): a Claude Code
  dispatch or worker run against the real account (`claude-usage.sh` was only called live once, for a
  reading), the credits during a full window, and a plan with other per-model windows than Fable.
- A Claude Code session that used tools, subagents (sidechains), `/compact` or `--resume`: the
  message duplication, and whether subagent usage is in the same file, are unknown.
- A Codex or Pi kill in the middle of a turn.
- A clean `/exit` for any harness, as against a kill.
- Several sessions in one worktree (rework): the time filter is reasoned, not tried.
- Windows and macOS paths; everything here ran on Linux.
