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
- **The allowance without a session log (#161, read 2026-11-11, codex 0.166.0).** `codex app-server`
  (stdio JSON-RPC: `initialize`, then `initialized`, then a request) has `account/rateLimits/read`.
  One call on a machine signed in with ChatGPT returned `rateLimits.primary` (`windowDurationMins` 300)
  and `secondary` (10080), each with `usedPercent` and `resetsAt` (Unix seconds), `credits`,
  `planType` (`plus` here) and `rateLimitReachedType`. It is the same window shape as the session
  logs, but a live reading with no model call and no earlier session needed. Codex makes the call
  with its own login, so the conductor never handles the token. It needs the Codex binary installed
  and signed in. The protocol is marked experimental (`codex app-server generate-json-schema` writes
  it); `account/usage/read` (token usage) exists and was not tried.
  **Used since #225:** `codex-usage.sh` asks the app-server when the log cannot give a window (no
  session at all, or the window reset since the last event) and Codex is installed. Its windows
  replace the log's; `source` is `codex app-server` and `snapshot_at` the time of the read. A log
  with both windows known is not replaced and nothing is started. `CODEX_BIN` names the binary,
  `CODEX_APP_SERVER=off` turns it off, `CODEX_APP_SERVER_TIMEOUT` (15 s) bounds the wait. A sessions
  directory given by `--sessions` or `CODEX_SESSIONS_DIR` never starts the codex on `PATH`, only one
  named in `CODEX_BIN`: that rule is there so a test or a replay never wakes a real Codex. A real
  install with a custom `CODEX_SESSIONS_DIR` must set `CODEX_BIN` (for example `CODEX_BIN=codex`) to
  get the live reading. The version comes from `initialize`'s `userAgent`, and the exchange runs on
  named pipes, so it needs no GNU `date` and no bash 4. Tested with a stand-in that speaks the protocol, and
  against the schema from `codex app-server generate-json-schema` (0.166.0); not run end to end
  against the real app-server from this script. **Not measured:** how long a real read takes. The
  reader runs at every worker spawn and end, so with a stale log each one now starts a Codex
  process; if that is slow, a read at most every few minutes is the next step.
  **To check it for real (#228):** `scripts/codex-app-server-check.sh` reads n times from an empty
  sessions directory, so only the app-server can answer, and prints each reading, the fastest, median
  and slowest time, the machine and bash, and four verdicts (source, windows, version, cleanup). Run it
  on Linux and on macOS with its bash 3.2, and put the numbers here.
  **The hole, decided:** with no sessions directory named and `CODEX_APP_SERVER` not `off`, any
  `codex` on `PATH` is started with `app-server`. That is kept: for a real install it is the point,
  and nothing cheap tells a real Codex from another binary. So a test that puts a stub `codex` on
  `PATH` and runs the loop or the allowance reader must set `CODEX_APP_SERVER=off` (as
  `test-codex-dispatch.sh` does), or name its sessions directory. The reader stops the app-server it
  started with TERM, and with KILL after two seconds (only if it is still there), so one that ignores
  TERM cannot hang it. **Known limit:** KILL reaches the app-server and not helper processes a real
  Codex may have started; the check script's cleanup verdict compares `app-server` pids before and
  after, by command line, so a helper under another name is not seen. The real run will show it.
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
  `usage-prices.json` gives, to the millionth of a dollar. `cost.totalFromProvider` was `false` in
  every message seen: the figure is Pi's estimate, not the provider's. On a ChatGPT plan it is not a
  charge either (see "Pi is metered only on a ChatGPT plan" below).
- **Provider.** Each assistant message has `provider` and `api` beside `model`, and a
  `model_change` line `{provider, modelId}` marks a switch. A session can mix providers: one seen
  had two `anthropic` messages and three `openai-codex` ones, so the provider is read per message,
  never per session. The log does not name the sign-in: no line mentions `oauth`, `api_key` or a
  plan.
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
- **Only for sessions with a status line.** Checked on 2026-11-06 (Claude Code 2.1.318): `claude -p`
  with a `statusLine` in `--settings` exits 0 but never runs the command, so a headless dispatch or
  worker produces no payload. Only an interactive session does.

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
reads it, five-hour and weekly only), tested on fixtures made from the capture's payload shape and, on 2026-11-06, in a real interactive
session: the wrapper saved the payload (keys `rate_limits` and `taken_at`, mode 600) and the reader
gave 0 % and 22 %, the same as the endpoint a moment later. `claude -p` runs no status line command, so
this source never covers a headless dispatch. Still unverified: whether the payload's whole-point
percentage lags or rounds down against the endpoint (19 against 20.0 in the first capture; equal in
the second, but that endpoint value was a whole number), and the gateway `spend_limit`, never seen.
What the reader settled, and what it assumed:

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
- **Pi is metered only on a ChatGPT plan.** `pi` runs on whatever provider its model needs and has no
  allowance of its own to read. Settled in #156: Pi may not declare `subscription:anthropic` (Anthropic
  does not permit a subscription login in a third-party harness) and the schema rejects it.
  `subscription:openai` is allowed (OpenAI lists Pi for ChatGPT plan usage), and since #159 a Pi run
  there is registered in the same window as Codex (`allowance.sh vendor pi --pool subscription:openai`).
  The window is still read from Codex's session logs: Pi's own hold the provider, tokens and cost per
  message, no rate limits. Read 2026-11-07 from Pi 1.4.0's logs and docs, and checked on 2026-11-11
  with real sessions (#161): a session log names the provider and not the sign-in;
  `~/.pi/agent/auth.json` has a `type` per provider, and Pi uses a runtime `--api-key`, then a stored
  `auth.json` credential, then `models.json`, then the provider's environment variable.
  - **The sign-in is in the provider's name and `type`.** After `/login` for ChatGPT, `auth.json`
    held `openai-codex` with `type: oauth` beside `openai` and `anthropic` with `type: api_key`.
    The OAuth entry's fields are `access`, `accountId`, `expires`, `refresh` and `type`; only the
    names were read, never a value, and the pool needs only the `type`.
  - **Two real runs.** On the `openai` API key (`gpt-5.3-codex`): `provider: openai`,
    `api: openai-responses`. On the plan (`gpt-5.6-luna`): `provider: openai-codex`,
    `api: openai-codex-responses`. The usage fields are the same in both. The plan run's cost
    (about $0.20 per million input tokens and $1.20 per million output) is an estimate at API rates,
    not a charge on the plan, so on a plan the tokens are what counts, against the window.
  - **So a Pi message's pool is its provider and that provider's `type`:** `openai-codex` with
    `oauth` is `subscription:openai`; `openai` with `api_key` is the API.
    `billing-mode.sh pi-pool <provider>` prints that (and `api:anthropic` for `anthropic` with
    `api_key`), reading only the `type` from `auth.json` (`PI_AUTH_FILE`). Every other pairing is
    `unknown`: a pairing nobody has seen (`openai-codex` on a key, `openai` on oauth) is not guessed,
    and `anthropic` on oauth is not what pays for a Pi run (#156). **Not wired in yet:** a Pi member's
    pool on a usage line still comes only from its declaration (`billing-mode.sh pool`), and the
    reader does not take the provider per message. A session can mix providers, so the line would
    need the pool per message, not one. `auth.json` is the best guess, not proof: a runtime
    `--api-key` outranks it and leaves no trace in the log.
  - **The window without Codex's logs.** `codex app-server` (above) reads it live, but needs Codex
    installed and signed in. A machine with only Pi has Pi's own `openai-codex` sign-in and no
    Codex. Reading the plan's usage with Pi's token directly is not done: nothing found says a
    third-party tool may reuse a ChatGPT OAuth token for it, and one third-party source quotes an
    anti-circumvention clause in OpenAI's terms (not confirmed on OpenAI's own page). Treat it as not
    allowed until OpenAI says otherwise. A machine with only Pi, and no Codex binary, has no fresh window reading: both windows are
    unknown, and the reason says there is no log and no binary to ask (#225).
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
- Pi on a ChatGPT plan, more than one short run (#161): the `openai-codex` messages seen came from two
  prompts. Not tried: a runtime `--api-key` over a stored plan login, `models.json` or an environment
  key, a Pi-only machine with no Codex, and Codex's `account/usage/read`.
- A clean `/exit` for any harness, as against a kill.
- Several sessions in one worktree (rework): the time filter is reasoned, not tried.
- Windows and macOS paths; everything here ran on Linux.
